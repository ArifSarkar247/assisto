"""owneradmin (18 Nov): the Owner Admin home "Today" card — six numbers the
owner checks every morning from his phone. COUNTS ONLY: no names, phone
numbers, messages or places, ever.

  1. production build share: % of phones (seen in 30 days) on OWNER_PROD_BUILD+
  2. last-24 h call ring delivery, overall + per phone brand (core.call_ack)
  3. server 5xx in the last 24 h (nginx timing log, core.live_monitor)
  4. new signups in the last 24 h
  5. app crash / error reports in the last 24 h (ClientErrorReport)
  6. CI queue (queued / running GitHub Actions runs of the public repo)

Each part is cached a few minutes and fails soft to "—" on its own."""
import json
import urllib.request
from datetime import timedelta

from django.conf import settings
from django.core.cache import cache
from django.utils import timezone

PROD_BUILD_DEFAULT = 10378
CACHE_S = 300
CI_CACHE_S = 600
CI_FAIL_CACHE_S = 180
QUEUED = ("queued", "waiting", "pending", "requested")


def prod_build():
    return int(getattr(settings, "OWNER_PROD_BUILD", PROD_BUILD_DEFAULT) or PROD_BUILD_DEFAULT)


def _cached(key, fn, ttl=CACHE_S):
    v = cache.get(key)
    if v is None:
        try:
            v = {"ok": True, **fn()}
        except Exception:
            v = {"ok": False}
        cache.set(key, v, ttl)
    return v


def build_share(now=None):
    from core.call_ack import app_build
    from core.models import Device
    now = now or timezone.now()
    target = prod_build()
    on = known = total = 0
    builds = {}
    for v in Device.objects.filter(last_seen__gte=now - timedelta(days=30)) \
            .values_list("app_version", flat=True).iterator():
        total += 1
        b = app_build(v)
        if not b:
            continue
        known += 1
        builds[b] = builds.get(b, 0) + 1
        if b >= target:
            on += 1
    top = sorted(builds.items(), key=lambda kv: (-kv[1], -kv[0]))[:3]
    return {"target": target, "on": on, "known": known, "total": total,
            "pct": round(100.0 * on / known) if known else None,
            "top": [{"build": b, "n": n} for b, n in top]}


def calls_24h():
    from core import call_ack
    s = call_ack.delivery_stats(hours=24)
    brands = [{"brand": b["brand"] or "", "attempts": b["attempts"], "pct": b["pct"],
               "below": b["below"]} for b in s["brands"][:6]]
    return {"attempts": s["attempts"], "delivered": s["delivered"], "pct": s["pct"],
            "below": s["below"], "target": s["target"], "brands": brands}


def server_5xx():
    from core import live_monitor as LM
    s = LM.nginx_stats(hours=24)
    if not s.get("ok"):
        raise RuntimeError("no log")
    share = s.get("share_5xx")
    return {"errors": s["errors_5xx"], "requests": s["requests"],
            "share": round(share * 100, 2) if share is not None else None,
            "bad": s["errors_5xx"] >= LM.SPIKE_MIN_5XX}


def signups_24h(now=None):
    from core.models import User
    now = now or timezone.now()
    return {"n": User.objects.filter(date_joined__gte=now - timedelta(hours=24)).count()}


def crashes_24h(now=None):
    from django.db.models import Count, Sum
    from core.models import ClientErrorReport
    now = now or timezone.now()
    qs = ClientErrorReport.objects.filter(last_at__gte=now - timedelta(hours=24))
    agg = qs.aggregate(n=Sum("count"), groups=Count("fingerprint", distinct=True))
    fatal = qs.filter(fatal=True).aggregate(n=Sum("count"))["n"] or 0
    return {"n": agg["n"] or 0, "groups": agg["groups"] or 0, "fatal": fatal}


def ci_repo():
    return getattr(settings, "OWNER_CI_REPO", "ArifSarkar247/assisto") or ""


def _fetch_ci():
    """{queued, running} from the public GitHub Actions API (no token; the
    newest 100 runs cover any real queue). Raises on any failure."""
    repo = ci_repo()
    if not repo:
        raise RuntimeError("off")
    req = urllib.request.Request(
        "https://api.github.com/repos/%s/actions/runs?per_page=100" % repo,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "assisto-owner-admin"})
    with urllib.request.urlopen(req, timeout=3) as r:   # noqa: S310 (fixed https URL)
        runs = json.loads(r.read().decode("utf-8")).get("workflow_runs") or []
    return {"queued": sum(1 for x in runs if x.get("status") in QUEUED),
            "running": sum(1 for x in runs if x.get("status") == "in_progress")}


def ci_queue():
    v = cache.get("owner_today_ci")
    if v is None:
        try:
            v = {"ok": True, **_fetch_ci(), "at": timezone.now()}
            cache.set("owner_today_ci", v, CI_CACHE_S)
        except Exception:
            v = {"ok": False}
            cache.set("owner_today_ci", v, CI_FAIL_CACHE_S)
    return v


def today_ctx():
    return {"today": {
        "build": _cached("owner_today_build", build_share),
        "calls": _cached("owner_today_calls", calls_24h),
        "s5xx": _cached("owner_today_5xx", server_5xx),
        "signups": _cached("owner_today_signups", signups_24h, 60),
        "crashes": _cached("owner_today_crashes", crashes_24h, 60),
        "ci": ci_queue(),
        "ci_url": ("https://github.com/%s/actions" % ci_repo()) if ci_repo() else "",
    }}
