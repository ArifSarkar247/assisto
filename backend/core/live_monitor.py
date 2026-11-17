"""livemon (owner 17 Nov — Assisto is LIVE on Google Play): READ-ONLY daily
live-health snapshot for the morning STATUS line and Owner Admin → Live health.

What it collects (aggregate counts only — never a phone number, name, email,
message text or IP; nothing is written anywhere but the two report files):

1. play     — Google Play vitals via the Play Developer Reporting API
              (read-only; scope playdeveloperreporting; the same service-account
              file the Play upload / play_vitals_pull already use, never printed):
              user-perceived crash + ANR rate, latest day and 7 days, by app version.
2. crashes  — Google's top error issues (errorIssues:search) + our own in-app
              crash reports (ClientErrorReport via core.crash_rate). Crashlytics:
              the server has no read path (no Firebase admin scope) — not used.
3. server   — 5xx count and the top 5 failing endpoints over the last 24 h from
              the nginx timing log (time status method uri ...; no IPs in it).
4. users    — new accounts in 24 h, DAU (yesterday) / WAU (7 days) from
              ActiveDay, signup OTP: identifiers that got a code vs. that verified.
5. payments — verified vs failed payment facts in 24 h (PaymentEvent /
              PaymentOrder) + Play verify calls by HTTP result (nginx log).

P0 flags (owner): Play crash rate > 1 % (crash-free users < 99 %), ANR > 0.47 %,
signup success < 70 % with >= 10 attempts, a 5xx spike.

Output: <LIVE_MONITOR_DIR>/live_monitor_latest.json + live_monitor_bn.txt
(one ready Bangla line). Runs inside `manage.py minute_jobs` (owner: no new
cron lines), gated to once a day from 06:00 Asia/Dhaka.
"""
import gzip
import json
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta

from django.conf import settings
from django.utils import timezone

FROM_HOUR = 6                      # Dhaka local
CRASH_P0 = 0.01                    # owner: crash rate > 1 % is P0
ANR_P0 = 0.0047                    # Google's bad-behaviour bar
SIGNUP_P0 = 0.70                   # success below 70 % ...
SIGNUP_MIN_ATTEMPTS = 10           # ... with at least 10 attempts
OWN_MIN_USERS = 100                # own crash data: P0 only with >= 100 user-days
SPIKE_MIN_5XX = 20                 # 5xx spike: >= 20 errors AND >= 1 % of requests,
SPIKE_SHARE = 0.01
SPIKE_HOUR = 30                    # ... or >= 30 in one clock hour
NGINX_LOGS = ("/var/log/nginx/api_timing.log", "/var/log/nginx/api_timing.log.1")
PAY_OK_KINDS = ("play.charge", "order.paid")
PAY_FAIL_KINDS = ("order.verify_error", "order.init_failed", "order.refused",
                  "gateway.ipn_rejected", "play.rtdn_rejected")
PLAY_VERIFY_PATH = "/api/v1/payments/play/verify"
REGISTER_PATH = "/api/v1/auth/register"

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_ID_SEG = re.compile(r"^(\d+|[0-9a-fA-F-]{16,}|[A-Za-z0-9_-]{24,})$")


def out_dir():
    return str(getattr(settings, "LIVE_MONITOR_DIR", "") or
               os.path.join(str(settings.BASE_DIR), "logs"))


def _say(log, msg):
    if log:
        log(msg)


def _pct(x, nd=2):
    return None if x is None else round(x * 100, nd)


# ================================================================ 1+2 Play
def _weighted(rows, metric):
    num = den = 0.0
    rates = []
    for r in rows:
        v = r["vals"].get(metric)
        if v is None:
            continue
        rates.append(v)
        w = r["users"] or 0
        num += v * w
        den += w
    if den:
        return num / den
    return (sum(rates) / len(rates)) if rates else None


def play_vitals(http=None, key_path=None, log=None, days=7):
    """Read-only Play Reporting pull. Never raises; never stores rows."""
    from . import play_vitals as PV
    out = {"ok": False, "skipped": "", "latest_day": None, "errors": 0,
           "crash_1d": None, "crash_7d": None, "anr_1d": None, "anr_7d": None,
           "users_1d": None, "by_version": [], "top_issues": []}
    try:
        sa = PV.load_key(key_path, log)
        if not sa:
            out["skipped"] = "no_key"
            return out
        if http is None:
            import requests
            http = requests.Session()
        token = PV.mint_token(sa, http, log)
        if not token:
            out["skipped"] = "no_token"
            return out
        client = PV.Client(http, token, log)
        pkg = PV.package()
        overall, versions = [], defaultdict(list)
        for set_name, names in PV.METRIC_SETS.items():
            url = "%s/apps/%s/%s" % (PV.API, pkg, set_name)
            end, tz = PV.freshness(client.call("get", url))
            if not end:
                continue
            for dim in (None, "versionCode"):
                body = client.call("post", url + ":query",
                                   json=PV.query_body(names.values(), dim, end, tz, days))
                for row in (body or {}).get("rows") or []:
                    d, value, label, vals, users = PV.parse_row(row)
                    if not d:
                        continue
                    rec = {"date": d, "vals": vals, "users": users}
                    if dim:
                        versions[(value, label)].append(rec)
                    else:
                        overall.append(rec)
        # merge the two metric sets' overall rows per day
        by_day = {}
        for r in overall:
            m = by_day.setdefault(r["date"], {"date": r["date"], "vals": {}, "users": None})
            m["vals"].update(r["vals"])
            if r["users"] is not None:
                m["users"] = max(m["users"] or 0, r["users"])
        days_rows = [by_day[k] for k in sorted(by_day)]
        if days_rows:
            last = days_rows[-1]
            out["latest_day"] = last["date"].isoformat()
            out["users_1d"] = last["users"]
            out["crash_1d"] = last["vals"].get("userPerceivedCrashRate")
            out["anr_1d"] = last["vals"].get("userPerceivedAnrRate")
            out["crash_7d"] = _weighted(days_rows, "userPerceivedCrashRate")
            out["anr_7d"] = _weighted(days_rows, "userPerceivedAnrRate")
        vrows = []
        for (code, label), recs in versions.items():
            users = max((r["users"] or 0) for r in recs) if recs else 0
            vrows.append({"version": code, "label": label or code, "users_max_day": users,
                          "crash_7d": _weighted(recs, "userPerceivedCrashRate"),
                          "anr_7d": _weighted(recs, "userPerceivedAnrRate")})
        vrows.sort(key=lambda v: -(v["users_max_day"] or 0))
        out["by_version"] = vrows[:5]
        out["top_issues"] = play_top_issues(client, pkg)
        out["errors"] = client.errors
        out["ok"] = bool(days_rows) or bool(out["top_issues"])
        if not out["ok"]:
            out["skipped"] = "no_data"
    except Exception as e:  # noqa: BLE001 — a monitor must never crash
        out["skipped"] = "error:%s" % type(e).__name__
        _say(log, "live_monitor: play %s" % type(e).__name__)
    return out


def play_top_issues(client, pkg, limit=5):
    """Google's error issues, worst (most users) first. Code-level fields only."""
    from . import play_vitals as PV
    body = client.call("get", "%s/apps/%s/errorIssues:search" % (PV.API, pkg),
                       params={"pageSize": 50})
    rows = []
    for i in (body or {}).get("errorIssues") or []:
        rows.append({"type": str(i.get("type") or "")[:24],
                     "cause": str(i.get("cause") or "")[:160],
                     "location": str(i.get("location") or "")[:160],
                     "users": PV._int(i.get("distinctUsers")) or 0,
                     "reports": PV._int(i.get("errorReportCount")) or 0,
                     "last_version": PV._ver(i.get("lastAppVersion"), "versionCode")[:24]})
    rows.sort(key=lambda r: (-r["users"], -r["reports"]))
    return rows[:limit]


def own_crashes():
    """Our own in-app crash reports (ClientErrorReport) — rate + top signatures.
    No message text (only type / source / counts)."""
    from . import crash_rate as CR
    out = {}
    try:
        d1, d7 = CR.window(1), CR.window(7)
        out = {"crash_1d": d1["crash_rate"], "anr_1d": d1["anr_rate"],
               "user_days_1d": d1["user_days"],
               "crash_7d": d7["crash_rate"], "anr_7d": d7["anr_rate"],
               "user_days_7d": d7["user_days"],
               "top": [{"fingerprint": g["fingerprint"], "type": g.get("type", "")[:80],
                        "source": g.get("source", ""), "users": g["users"],
                        "events": g["events"] or 0}
                       for g in CR.top_signatures(days=2, limit=5)]}
    except Exception as e:  # noqa: BLE001
        out = {"error": type(e).__name__}
    return out


# ================================================================ 3 server
def norm_path(uri):
    """/api/v1/chats/123/messages?x -> /api/v1/chats/{id}/messages"""
    p = str(uri or "").split("?", 1)[0]
    segs = [("{id}" if _ID_SEG.match(s) else s) for s in p.split("/")]
    return "/".join(segs)[:120]


def _open(path):
    return gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else \
        open(path, errors="replace")


def nginx_stats(now=None, paths=None, hours=24):
    """Parse the nginx `timed` log ('$time_iso8601 $status $request_method $uri
    $request_time $upstream_response_time') for the last `hours`."""
    now = now or timezone.now()
    paths = NGINX_LOGS if paths is None else paths
    since = now - timedelta(hours=hours)
    out = {"ok": False, "requests": 0, "errors_5xx": 0, "share_5xx": None,
           "max_5xx_hour": 0, "top_failing": [], "files": 0,
           "play_verify": {"ok": 0, "refused": 0, "error": 0},
           "register": {"ok": 0, "client": 0, "server": 0}}
    fails, hours_5xx = Counter(), Counter()
    for path in paths:
        try:
            fh = _open(path)
        except OSError:
            continue
        out["files"] += 1
        with fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 4:
                    continue
                try:
                    t = datetime.fromisoformat(parts[0])
                    status = int(parts[1])
                except ValueError:
                    continue
                if t < since or t > now + timedelta(minutes=5):
                    continue
                out["requests"] += 1
                path_n = norm_path(parts[3])
                if status >= 500:
                    out["errors_5xx"] += 1
                    fails[(parts[2][:8], path_n)] += 1
                    hours_5xx[t.strftime("%Y-%m-%dT%H")] += 1
                if path_n == PLAY_VERIFY_PATH and parts[2] == "POST":
                    k = "ok" if status < 400 else ("refused" if status < 500 else "error")
                    out["play_verify"][k] += 1
                if path_n == REGISTER_PATH and parts[2] == "POST":
                    k = "ok" if status < 400 else ("client" if status < 500 else "server")
                    out["register"][k] += 1
    out["ok"] = out["files"] > 0
    if out["requests"]:
        out["share_5xx"] = out["errors_5xx"] / out["requests"]
    out["max_5xx_hour"] = max(hours_5xx.values()) if hours_5xx else 0
    out["top_failing"] = [{"method": m, "path": p, "count": n}
                          for (m, p), n in fails.most_common(5)]
    return out


# ================================================================ 4 users
def users_stats(now=None):
    from django.contrib.auth import get_user_model
    from .models import ActiveDay, OtpChallenge, OtpProof
    now = now or timezone.now()
    since = now - timedelta(hours=24)
    today = timezone.localtime(now).date()
    yday = today - timedelta(days=1)
    U = get_user_model()
    ch = OtpChallenge.objects.filter(purpose="signup", created_at__gte=since)

    def _ids(qs):
        # distinct identifiers counted in the DB; values never leave this function
        return (qs.exclude(phone="").values("phone").distinct().count()
                + qs.filter(phone="").exclude(email="").values("email").distinct().count())

    attempts = _ids(ch.filter(sent=True))
    verified = _ids(OtpProof.objects.filter(purpose="signup", created_at__gte=since))
    return {
        "signups_24h": U.objects.filter(date_joined__gte=since).count(),
        "dau": ActiveDay.objects.filter(day=yday).count(),
        "dau_day": yday.isoformat(),
        "wau": ActiveDay.objects.filter(day__gt=yday - timedelta(days=7), day__lte=yday)
        .values("user_id").distinct().count(),
        "signup_otp_attempts": attempts,
        "signup_otp_verified": min(verified, attempts) if attempts else verified,
        "signup_otp_not_sent": ch.filter(sent=False).count(),
        "signup_success": (min(verified, attempts) / attempts) if attempts else None,
    }


# ================================================================ 5 payments
def payments_stats(now=None):
    from django.db.models import Count, Sum
    from .models import PaymentEvent, PaymentOrder
    now = now or timezone.now()
    since = now - timedelta(hours=24)
    ev = PaymentEvent.objects.filter(created_at__gte=since)
    by = {r["kind"]: r["n"] for r in ev.order_by().values("kind").annotate(n=Count("id"))}
    ok = sum(by.get(k, 0) for k in PAY_OK_KINDS)
    failed_orders = PaymentOrder.objects.filter(status="failed", updated_at__gte=since).count()
    return {
        "verified": ok,
        "verified_bdt": float(ev.filter(kind__in=PAY_OK_KINDS)
                              .aggregate(s=Sum("amount_bdt"))["s"] or 0),
        "failed_events": sum(by.get(k, 0) for k in PAY_FAIL_KINDS),
        "failed_orders": failed_orders,
        "test_charges": by.get("play.test_charge", 0),
        "refunds": by.get("play.refund", 0) + by.get("order.refunded", 0),
        "by_kind": {k: by[k] for k in sorted(by) if k in PAY_OK_KINDS + PAY_FAIL_KINDS},
    }


# ================================================================ P0 + text
def p0_flags(rep):
    flags = []
    play = rep.get("play") or {}
    for key, label in (("crash_1d", "play_crash_1d"), ("crash_7d", "play_crash_7d")):
        v = play.get(key)
        if v is not None and v > CRASH_P0:
            flags.append({"code": label, "value_pct": _pct(v), "limit_pct": _pct(CRASH_P0)})
    for key, label in (("anr_1d", "play_anr_1d"), ("anr_7d", "play_anr_7d")):
        v = play.get(key)
        if v is not None and v > ANR_P0:
            flags.append({"code": label, "value_pct": _pct(v), "limit_pct": _pct(ANR_P0)})
    own = rep.get("own_crashes") or {}
    if (own.get("crash_1d") is not None and (own.get("user_days_1d") or 0) >= OWN_MIN_USERS
            and own["crash_1d"] > CRASH_P0):
        flags.append({"code": "own_crash_1d", "value_pct": _pct(own["crash_1d"]),
                      "limit_pct": _pct(CRASH_P0)})
    u = rep.get("users") or {}
    if (u.get("signup_success") is not None and
            (u.get("signup_otp_attempts") or 0) >= SIGNUP_MIN_ATTEMPTS and
            u["signup_success"] < SIGNUP_P0):
        flags.append({"code": "signup_broken", "value_pct": _pct(u["signup_success"]),
                      "limit_pct": _pct(SIGNUP_P0)})
    reg = ((rep.get("server") or {}).get("register") or {})
    done = reg.get("ok", 0) + reg.get("server", 0)
    if done >= SIGNUP_MIN_ATTEMPTS and reg.get("ok", 0) / done < SIGNUP_P0:
        flags.append({"code": "register_5xx", "value_pct": _pct(reg["ok"] / done),
                      "limit_pct": _pct(SIGNUP_P0)})
    s = rep.get("server") or {}
    if (s.get("errors_5xx", 0) >= SPIKE_MIN_5XX and (s.get("share_5xx") or 0) >= SPIKE_SHARE) \
            or s.get("max_5xx_hour", 0) >= SPIKE_HOUR:
        flags.append({"code": "server_5xx_spike", "count": s.get("errors_5xx", 0),
                      "max_hour": s.get("max_5xx_hour", 0)})
    return flags


P0_BN = {"play_crash_1d": "ক্র্যাশ ১%-এর বেশি (শেষ দিন)", "play_crash_7d": "ক্র্যাশ ১%-এর বেশি (৭ দিন)",
         "play_anr_1d": "ANR ০.৪৭%-এর বেশি (শেষ দিন)", "play_anr_7d": "ANR ০.৪৭%-এর বেশি (৭ দিন)",
         "own_crash_1d": "অ্যাপের নিজের হিসাবে ক্র্যাশ ১%-এর বেশি",
         "signup_broken": "সাইনআপ ভাঙা (সফল ৭০%-এর কম)",
         "register_5xx": "অ্যাকাউন্ট খোলায় সার্ভার এরর",
         "server_5xx_spike": "সার্ভার এরর হঠাৎ বেড়েছে"}


def bn(v):
    return str(v).translate(_BN)


def _bp(rate):
    return "—" if rate is None else bn("%.2f%%" % (rate * 100))


def bangla_line(rep):
    """One ready Bangla line for the top of STATUS (Bangla digits)."""
    d = timezone.localtime(timezone.now()).date()
    play, u = rep.get("play") or {}, rep.get("users") or {}
    s, p = rep.get("server") or {}, rep.get("payments") or {}
    parts = []
    if play.get("ok"):
        parts.append("ক্র্যাশ %s (৭ দিনে %s), ANR %s" % (
            _bp(play.get("crash_1d")), _bp(play.get("crash_7d")), _bp(play.get("anr_1d"))))
    else:
        own = rep.get("own_crashes") or {}
        parts.append("Play ভাইটালস পাওয়া যায়নি; অ্যাপের নিজের হিসাবে ক্র্যাশ %s"
                     % _bp(own.get("crash_1d")))
    parts.append("নতুন ব্যবহারকারী %s জন, সক্রিয় গতকাল %s / ৭ দিনে %s" % (
        bn(u.get("signups_24h", 0)), bn(u.get("dau", 0)), bn(u.get("wau", 0))))
    if u.get("signup_otp_attempts"):
        parts.append("সাইনআপ সফল %s (%s-এর মধ্যে %s)" % (
            bn("%d%%" % round(u["signup_success"] * 100)), bn(u["signup_otp_attempts"]),
            bn(u["signup_otp_verified"])))
    if s.get("ok"):
        parts.append("সার্ভার এরর (৫xx) %sটি" % bn(s.get("errors_5xx", 0)))
    parts.append("পেমেন্ট সফল %s, ব্যর্থ %s" % (
        bn(p.get("verified", 0)), bn(p.get("failed_events", 0) + p.get("failed_orders", 0))))
    flags = rep.get("p0") or []
    tail = ("P0: " + "; ".join(P0_BN.get(f["code"], f["code"]) for f in flags)
            + " — আগে ঠিক করতে হবে") if flags else "সব ঠিক আছে"
    return "লাইভ %s/%s: %s — %s" % (bn(d.day), bn(d.month), "; ".join(parts), tail)


# ================================================================ run
def _safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:  # noqa: BLE001 — one failing source never hides the rest
        return {"error": type(e).__name__}


def collect(now=None, http=None, key_path=None, log_paths=None, log=None):
    now = now or timezone.now()
    if log_paths is None:
        log_paths = NGINX_LOGS
    rep = {"generated_at": now.isoformat(timespec="seconds"),
           "window_hours": 24,
           "play": _safe(play_vitals, http=http, key_path=key_path, log=log),
           "own_crashes": _safe(own_crashes),
           "crashlytics": "not_used: no server-side read path",
           "server": _safe(nginx_stats, now=now, paths=log_paths),
           "users": _safe(users_stats, now=now),
           "payments": _safe(payments_stats, now=now)}
    rep["p0"] = p0_flags(rep)
    rep["p0_any"] = bool(rep["p0"])
    rep["bn_line"] = bangla_line(rep)
    return rep


def write(rep, directory=None):
    directory = directory or out_dir()
    os.makedirs(directory, exist_ok=True)
    for name, body in (("live_monitor_latest.json",
                        json.dumps(rep, ensure_ascii=False, indent=1, default=str)),
                       ("live_monitor_bn.txt", rep["bn_line"] + "\n")):
        tmp = os.path.join(directory, name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(body)
        os.replace(tmp, os.path.join(directory, name))
    return directory


def latest(directory=None):
    """The last written report (Owner Admin card), or None."""
    try:
        with open(os.path.join(directory or out_dir(), "live_monitor_latest.json"),
                  encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def is_due(now, last):
    """Once a local (Dhaka) day, from 06:00."""
    loc = timezone.localtime(now)
    if loc.hour < FROM_HOUR:
        return False
    return last is None or timezone.localtime(last).date() != loc.date()
