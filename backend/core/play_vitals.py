"""play-vitals: daily Google Play Vitals feed (Play Developer Reporting API
v1beta1) → PlayVitalDaily / PlayErrorIssue → Owner Admin → Play Vitals.

* Auth: the Play service account (settings.PLAY_SERVICE_ACCOUNT_JSON, server
  only, never in git) signs a JWT locally (cryptography) and swaps it for a
  bearer token with plain `requests` — same recipe as bin/play_upload.py.
* Google's DAILY data lags several days: every query's timelineSpec.endTime is
  clamped to the metric set's freshnessInfo (and uses the time zone it reports),
  otherwise Google answers 400 "end_date should be at most the current
  freshness".
* Never raises: HTTP 4xx/5xx/timeouts are logged and skipped; a missing key is
  a quiet no-op. Idempotent upserts, so re-running a day changes nothing.
* Alerts (owner ADMIN notification + push, deduped): a NEW Google error issue
  (once per issue), and the 28-day user-weighted user-perceived crash / ANR
  rate above Google's bad-behaviour threshold (at most once per 7 days each).
"""
import base64
import json
import time
from datetime import date, timedelta

from django.conf import settings
from django.utils import timezone
from django.utils.dateparse import parse_datetime

API = "https://playdeveloperreporting.googleapis.com/v1beta1"
SCOPE = "https://www.googleapis.com/auth/playdeveloperreporting"
TOKEN_URI = "https://oauth2.googleapis.com/token"
TIMEOUT = 30
DAYS = 28
MAX_PAGES = 40
STACK_MAX = 4096

# Google's "bad behaviour" thresholds (overall, user-perceived, 28-day)
THRESHOLDS = {"user_perceived_crash": 0.0109, "user_perceived_anr": 0.0047}

# metric set → {our metric name: Google metric name}
METRIC_SETS = {
    "crashRateMetricSet": {"crash": "crashRate",
                           "user_perceived_crash": "userPerceivedCrashRate"},
    "anrRateMetricSet": {"anr": "anrRate",
                         "user_perceived_anr": "userPerceivedAnrRate"},
}
# our dimension kind → Google dimension (None = overall, no dimension)
DIMENSIONS = {"overall": None, "device": "deviceModel", "api": "apiLevel",
              "version": "versionCode"}


def _say(log, msg):
    if log:
        log(msg)


def package():
    return (getattr(settings, "PLAY_PACKAGE_NAME", "") or "com.assisto.assisto").strip()


def load_key(path=None, log=None):
    """The service-account dict, or None (missing / unreadable / incomplete).
    Never logs the key's contents."""
    path = path or getattr(settings, "PLAY_SERVICE_ACCOUNT_JSON", "")
    if not path:
        _say(log, "play_vitals: no PLAY_SERVICE_ACCOUNT_JSON configured; skipping")
        return None
    try:
        with open(path) as f:
            sa = json.load(f)
    except FileNotFoundError:
        _say(log, "play_vitals: service-account key not found; skipping")
        return None
    except Exception as e:  # noqa: BLE001 — permission / bad JSON
        _say(log, "play_vitals: service-account key unreadable (%s); skipping"
             % type(e).__name__)
        return None
    if not (isinstance(sa, dict) and sa.get("client_email") and sa.get("private_key")):
        _say(log, "play_vitals: service-account key incomplete; skipping")
        return None
    return sa


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def signed_assertion(sa, now=None):
    """RS256 JWT for the jwt-bearer grant (pure local crypto, no network)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    now = int(now or time.time())
    head = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64(json.dumps({"iss": sa["client_email"], "scope": SCOPE,
                              "aud": sa.get("token_uri") or TOKEN_URI,
                              "iat": now, "exp": now + 3600}).encode())
    pk = serialization.load_pem_private_key(sa["private_key"].encode(), password=None)
    sig = pk.sign(("%s.%s" % (head, claims)).encode(), padding.PKCS1v15(), hashes.SHA256())
    return "%s.%s.%s" % (head, claims, _b64(sig))


def mint_token(sa, http, log=None):
    """Bearer token string, or None (logged)."""
    try:
        r = http.post(sa.get("token_uri") or TOKEN_URI, data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": signed_assertion(sa)}, timeout=TIMEOUT)
    except Exception as e:  # noqa: BLE001
        _say(log, "play_vitals: token request failed (%s)" % type(e).__name__)
        return None
    if r.status_code >= 300:
        _say(log, "play_vitals: token HTTP %s" % r.status_code)
        return None
    try:
        return r.json()["access_token"]
    except Exception:  # noqa: BLE001
        _say(log, "play_vitals: token response had no access_token")
        return None


class Client:
    """Tiny JSON client: returns the decoded body, or None after logging."""

    def __init__(self, http, token, log=None):
        self.http, self.log = http, log
        self.headers = {"Authorization": "Bearer " + token}
        self.errors = 0

    def call(self, method, url, **kw):
        try:
            r = getattr(self.http, method)(url, headers=self.headers, timeout=TIMEOUT, **kw)
        except Exception as e:  # noqa: BLE001 — timeouts, DNS, ...
            self.errors += 1
            _say(self.log, "play_vitals: %s %s failed (%s)"
                 % (method.upper(), url.rsplit("/", 1)[-1], type(e).__name__))
            return None
        if r.status_code >= 300:
            self.errors += 1
            body = " ".join(str(getattr(r, "text", "") or "").split())[:300]
            _say(self.log, "play_vitals: %s %s HTTP %s %s"
                 % (method.upper(), url.rsplit("/", 1)[-1], r.status_code, body))
            return None
        try:
            return r.json()
        except Exception:  # noqa: BLE001
            return {}


# ----------------------------------------------------------------- parsing
def _gdate(d):
    """Google Date/DateTime dict → date, or None."""
    try:
        return date(int(d["year"]), int(d["month"]), int(d["day"]))
    except Exception:  # noqa: BLE001
        return None


def _num(v):
    if isinstance(v, dict):
        v = v.get("value")
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _int(v):
    n = _num(v)
    return int(n) if n is not None else None


def freshness(meta):
    """(latest DAILY end date, time-zone id) from a metric set's GET body."""
    for f in ((meta or {}).get("freshnessInfo") or {}).get("freshnesses") or []:
        if f.get("aggregationPeriod") == "DAILY":
            t = f.get("latestEndTime") or {}
            d = _gdate(t)
            if d:
                tz = (t.get("timeZone") or {}).get("id") or "America/Los_Angeles"
                return d, tz
    return None, None


def _gd(d, tz):
    return {"year": d.year, "month": d.month, "day": d.day, "timeZone": {"id": tz}}


def query_body(metrics, dim, end, tz, days=DAYS, page_token=None):
    """timelineSpec with endTime clamped to freshness `end` (never later)."""
    body = {"timelineSpec": {"aggregationPeriod": "DAILY",
                             "startTime": _gd(end - timedelta(days=days), tz),
                             "endTime": _gd(end, tz)},
            "metrics": list(metrics) + ["distinctUsers"], "pageSize": 1000}
    if dim:
        body["dimensions"] = [dim]
    if page_token:
        body["pageToken"] = page_token
    return body


def parse_row(row):
    """(date, dim_value, label, {google metric: float}, users)"""
    d = _gdate(row.get("startTime") or {})
    value, label = "", ""
    for dm in row.get("dimensions") or []:
        value = str(dm.get("stringValue") or dm.get("int64Value") or "")[:120]
        label = str(dm.get("valueLabel") or "")[:120]
    vals = {m.get("metric"): _num(m.get("decimalValue")) for m in row.get("metrics") or []}
    users = vals.pop("distinctUsers", None)
    return d, value, label, vals, (int(users) if users is not None else None)


def pull_metrics(client, pkg, log=None, days=DAYS):
    """All metric sets × dimension kinds → upserted rows. Returns
    {"rows": n, "fresh": {set: date}}."""
    from .models import PlayVitalDaily
    out = {"rows": 0, "fresh": {}}
    for set_name, names in METRIC_SETS.items():
        url = "%s/apps/%s/%s" % (API, pkg, set_name)
        end, tz = freshness(client.call("get", url))
        if not end:
            _say(log, "play_vitals: %s has no DAILY freshness; skipped" % set_name)
            continue
        out["fresh"][set_name] = end.isoformat()
        g2ours = {g: ours for ours, g in names.items()}
        for kind, dim in DIMENSIONS.items():
            token, pages = None, 0
            while pages < MAX_PAGES:
                pages += 1
                body = client.call("post", url + ":query",
                                   json=query_body(names.values(), dim, end, tz, days, token))
                if body is None:
                    break
                for row in body.get("rows") or []:
                    d, value, label, vals, users = parse_row(row)
                    if not d:
                        continue
                    for g, rate in vals.items():
                        ours = g2ours.get(g)
                        if not ours:
                            continue
                        PlayVitalDaily.objects.update_or_create(
                            date=d, metric=ours, dim_kind=kind,
                            dim_value=value if dim else "",
                            defaults={"rate": rate, "users": users, "label": label})
                        out["rows"] += 1
                token = body.get("nextPageToken")
                if not token:
                    break
    return out


def _issue_id(issue):
    return str(issue.get("name") or "").rsplit("/", 1)[-1][:64]


def _device(rep):
    dm = rep.get("deviceModel")
    if isinstance(dm, dict):
        did = dm.get("deviceId") or {}
        s = dm.get("marketingName") or "/".join(
            x for x in (did.get("buildBrand"), did.get("buildDevice")) if x)
        return str(s)[:120]
    return str(dm or "")[:120]


def _ver(v, key):
    if isinstance(v, dict):
        return str(v.get(key) or "")
    return str(v or "")


def pull_issues(client, pkg, log=None):
    """errorIssues:search (paged) → PlayErrorIssue upserts; one sample report
    (stack, device, OS, version) per new / sample-less / changed issue.
    Returns {"issues": n, "new": [PlayErrorIssue]}."""
    from .models import PlayErrorIssue
    url = "%s/apps/%s/errorIssues:search" % (API, pkg)
    out = {"issues": 0, "new": []}
    token, pages = None, 0
    while pages < MAX_PAGES:
        pages += 1
        params = {"pageSize": 50}
        if token:
            params["pageToken"] = token
        body = client.call("get", url, params=params)
        if body is None:
            break
        for issue in body.get("errorIssues") or []:
            iid = _issue_id(issue)
            if not iid:
                continue
            fields = {
                "type": str(issue.get("type") or "")[:24],
                "cause": str(issue.get("cause") or "")[:400],
                "location": str(issue.get("location") or "")[:400],
                "first_version": _ver(issue.get("firstAppVersion"), "versionCode")[:24],
                "last_version": _ver(issue.get("lastAppVersion"), "versionCode")[:24],
                "first_api": _int(_ver(issue.get("firstOsVersion"), "apiLevel")),
                "last_api": _int(_ver(issue.get("lastOsVersion"), "apiLevel")),
                "users": _int(issue.get("distinctUsers")) or 0,
                "reports": _int(issue.get("errorReportCount")) or 0,
                "issue_uri": str(issue.get("issueUri") or "")[:400],
                "last_seen": parse_datetime(str(issue.get("lastErrorReportTime") or "")),
            }
            obj, created = PlayErrorIssue.objects.get_or_create(issue_id=iid, defaults=fields)
            changed = not created and obj.last_version != fields["last_version"]
            if not created:
                for k, v in fields.items():
                    setattr(obj, k, v)
            if created or changed or not obj.sample_stack:
                _sample(client, pkg, obj)
            obj.save()
            out["issues"] += 1
            if created:
                out["new"].append(obj)
        token = body.get("nextPageToken")
        if not token:
            break
    return out


def _sample(client, pkg, obj):
    body = client.call("get", "%s/apps/%s/errorReports:search" % (API, pkg),
                       params={"filter": "errorIssueId = %s" % obj.issue_id, "pageSize": 1})
    reps = (body or {}).get("errorReports") or []
    if not reps:
        return
    rep = reps[0]
    obj.sample_stack = str(rep.get("reportText") or "")[:STACK_MAX]
    obj.sample_device = _device(rep)
    obj.sample_os = _ver(rep.get("osVersion"), "apiLevel")[:24]
    obj.sample_version = _ver(rep.get("appVersion"), "versionCode")[:24]


# ----------------------------------------------------------------- summary
def weighted_rate(metric, days=DAYS):
    """User-weighted overall rate over the last `days` of stored data, or None."""
    from .models import PlayVitalDaily
    latest = (PlayVitalDaily.objects.filter(metric=metric, dim_kind="overall")
              .order_by("-date").values_list("date", flat=True).first())
    if not latest:
        return None
    rows = PlayVitalDaily.objects.filter(metric=metric, dim_kind="overall",
                                         date__gt=latest - timedelta(days=days))
    num = den = 0.0
    for r in rows:
        if r.rate is None:
            continue
        w = r.users or 0
        num += r.rate * w
        den += w
    if den:
        return num / den
    rates = [r.rate for r in rows if r.rate is not None]
    return sum(rates) / len(rates) if rates else None


# ----------------------------------------------------------------- alerts
def _owners():
    from .models import User
    return list(User.objects.filter(is_superuser=True, is_active=True)[:5])


def _admin_event(kind, t_en, t_bn, b_en, b_bn, meta):
    from .models import NotifEvent
    for o in _owners():
        NotifEvent.objects.create(user=o, type="admin", title_en=t_en[:200],
                                  title_bn=t_bn[:200], body_en=b_en, body_bn=b_bn,
                                  route="owner", meta=dict(meta, kind=kind,
                                                           source="play_vitals"),
                                  at=timezone.now())
    try:
        from .push import notify_owner
        notify_owner(t_en, b_en)
    except Exception:  # noqa: BLE001 — alerting never breaks the pull
        pass


def alert_new_issues(log=None):
    """One owner alert covering every not-yet-notified issue; each issue is
    flagged so it is never announced twice."""
    from .models import PlayErrorIssue
    fresh = list(PlayErrorIssue.objects.filter(notified=False).order_by("-users")[:20])
    if not fresh:
        return 0
    top = fresh[0]
    what = ("%s %s" % (top.type, top.cause or top.location)).strip()[:120]
    n = len(fresh)
    _admin_event(
        "play_new_issue",
        "Google Play: %d new error issue%s" % (n, "" if n == 1 else "s"),
        "Google Play: %d টি নতুন ত্রুটি" % n,
        "Top: %s (%d users). See Owner Admin → Play Vitals." % (what, top.users),
        "সবচেয়ে বড়: %s (%d জন ব্যবহারকারী)। Owner Admin → Play Vitals দেখুন।" % (what, top.users),
        {"issues": [i.issue_id for i in fresh]})
    PlayErrorIssue.objects.filter(pk__in=[i.pk for i in fresh]).update(notified=True)
    _say(log, "play_vitals: alerted %d new issue(s)" % n)
    return n


def alert_thresholds(log=None):
    from .models import NotifEvent
    sent = 0
    since = timezone.now() - timedelta(days=7)
    for metric, limit in THRESHOLDS.items():
        rate = weighted_rate(metric)
        if rate is None or rate <= limit:
            continue
        if NotifEvent.objects.filter(type="admin", meta__kind="play_threshold",
                                     meta__metric=metric, at__gte=since).exists():
            continue
        name = "crash" if "crash" in metric else "ANR"
        pct, lim = "%.2f%%" % (rate * 100), "%.2f%%" % (limit * 100)
        _admin_event(
            "play_threshold",
            "Google Play: user-perceived %s rate %s (limit %s)" % (name, pct, lim),
            "Google Play: %s রেট %s (সীমা %s)" % (name, pct, lim),
            "28-day user-weighted rate is above Google's bad-behaviour threshold. "
            "See Owner Admin → Play Vitals.",
            "২৮ দিনের রেট Google-এর খারাপ-আচরণ সীমার উপরে। Owner Admin → Play Vitals দেখুন।",
            {"metric": metric, "rate": rate, "limit": limit})
        sent += 1
        _say(log, "play_vitals: threshold alert %s %s" % (metric, pct))
    return sent


# ----------------------------------------------------------------- entry
def run(http=None, key_path=None, log=None, alerts=True):
    """The daily pull. Never raises. Returns a summary dict."""
    summary = {"ok": False, "rows": 0, "issues": 0, "new": 0, "errors": 0}
    try:
        sa = load_key(key_path, log)
        if not sa:
            summary["skipped"] = "no_key"
            return summary
        if http is None:
            import requests
            http = requests.Session()
        token = mint_token(sa, http, log)
        if not token:
            summary["skipped"] = "no_token"
            return summary
        client = Client(http, token, log)
        pkg = package()
        m = pull_metrics(client, pkg, log)
        i = pull_issues(client, pkg, log)
        summary.update(rows=m["rows"], fresh=m["fresh"], issues=i["issues"],
                       new=len(i["new"]), errors=client.errors, ok=True)
        if alerts:
            alert_new_issues(log)
            alert_thresholds(log)
    except Exception as e:  # noqa: BLE001 — a cron job must never crash
        _say(log, "play_vitals: unexpected %s: %s" % (type(e).__name__, str(e)[:200]))
    return summary
