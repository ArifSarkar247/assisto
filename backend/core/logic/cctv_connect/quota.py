"""
quota.py — stay inside a brand cloud's FREE monthly quota (owner 9 Nov
16:50). Imou free tier: 30 000 API calls, 30 000 messages, 2 GB traffic a
calendar month (owner's console figures; overridable in Owner Admin →
Integrations → Imou → "monthly free quota" fields).

  bump(provider, api=1)        one Open API call (logic/imou.ImouClient.call)
  bump(provider, msg=1)        one pushed message (the Imou callback)
  bump(provider, mb=x)         estimated cloud-live traffic
  usage(provider)              {"api_calls", "messages", "traffic_mb", "limits", "pct", "warn"}
  saving(provider)             True from 80 %: optional polling backs off
  stop(provider)               True from 100 %: optional polling stops (push,
                               owner-tapped live and linking still work)

ONE warning per counter per month at 80 % (and at 100 %) to the owner
(push.notify_owner) + red text on the Owner Admin card. Never raises —
counting must never break a camera alert.
"""
import logging

log = logging.getLogger("assisto.shop")

FREE = {"imou": {"api_calls": 30000, "messages": 30000, "traffic_mb": 2048.0},
        # EZVIZ free trial (isaopen.ezviz.com/price, 9 Nov): 10 devices, 1 Mbps,
        # 10 000 API calls A DAY for 120 days, no message subscription -> a
        # month is counted as 30 x 10 000; alarms are polled (no push)
        "ezviz": {"api_calls": 300000, "traffic_mb": 1024.0},
        # DoLynk free tier (public price page, China; international not
        # confirmed): 10 000 general calls a day
        "dolynk": {"api_calls": 300000, "messages": 300000, "traffic_mb": 1024.0}}
WARN_PCT = 80
COUNTERS = ("api_calls", "messages", "traffic_mb")


def _month(now=None):
    from django.utils import timezone
    return timezone.localtime(now or timezone.now()).strftime("%Y-%m")


def limits(provider):
    base = dict(FREE.get(provider) or {})
    if not base:
        return {}
    try:
        from ... import integrations as I
        cfg = I.get(provider) or {}
        for k, key in (("api_calls", "quota_api_calls"), ("messages", "quota_messages"),
                       ("traffic_mb", "quota_traffic_mb")):
            v = cfg.get(key)
            if v not in (None, ""):
                base[k] = max(1.0, float(v))
    except Exception:
        pass
    return base


def bump(provider, api=0, msg=0, mb=0.0, now=None):
    if provider not in FREE:
        return None
    try:
        from django.db.models import F
        from ...models import CctvVendorUsage
        m = _month(now)
        row, _ = CctvVendorUsage.objects.get_or_create(provider=provider, month=m)
        CctvVendorUsage.objects.filter(pk=row.pk).update(
            api_calls=F("api_calls") + int(api), messages=F("messages") + int(msg),
            traffic_mb=F("traffic_mb") + float(mb))
        row.refresh_from_db()
        _maybe_warn(provider, row)
        return row
    except Exception:
        log.debug("quota bump failed", exc_info=True)
        return None


def usage(provider, now=None):
    lim = limits(provider)
    out = {"provider": provider, "limits": lim, "api_calls": 0, "messages": 0,
           "traffic_mb": 0.0, "pct": {}, "warn": False, "month": _month(now)}
    if not lim:
        return out
    try:
        from ...models import CctvVendorUsage
        row = CctvVendorUsage.objects.filter(provider=provider, month=out["month"]).first()
    except Exception:
        row = None
    if row is not None:
        out.update(api_calls=row.api_calls, messages=row.messages,
                   traffic_mb=round(row.traffic_mb, 1))
    for k in COUNTERS:
        out["pct"][k] = int(100 * float(out[k]) / float(lim[k])) if lim.get(k) else 0
    out["warn"] = max(out["pct"].values() or [0]) >= WARN_PCT
    return out


def saving(provider):
    u = usage(provider)
    return bool(u["limits"]) and max(u["pct"].values() or [0]) >= WARN_PCT


def stop(provider):
    u = usage(provider)
    return bool(u["limits"]) and max(u["pct"].values() or [0]) >= 100


def _maybe_warn(provider, row):
    lim = limits(provider)
    warned = dict(row.warned or {})
    fired = []
    for k in COUNTERS:
        if not lim.get(k):
            continue
        pct = 100.0 * float(getattr(row, k)) / float(lim[k])
        for step in (WARN_PCT, 100):
            key = "%s_%d" % (k, step)
            if pct >= step and not warned.get(key):
                warned[key] = True
                fired.append((k, step, int(pct)))
    if not fired:
        return
    from ...models import CctvVendorUsage
    CctvVendorUsage.objects.filter(pk=row.pk).update(warned=warned)
    names = {"api_calls": "API calls", "messages": "messages", "traffic_mb": "traffic (MB)"}
    body = "\n".join("%s %s: %d%% of the free monthly quota used (%s of %s). %s" % (
        provider.upper(), names[k], p, int(getattr(row, k)), int(lim[k]),
        "Optional polling now backs off; alerts still arrive by push." if step < 100 else
        "Optional polling STOPPED until next month; push alerts and live still work.")
        for k, step, p in fired)
    try:
        from ... import push
        push.notify_owner("Assisto CCTV: %s free quota warning" % provider.upper(), body)
    except Exception:
        pass


def text(provider, lang="bn"):
    """One line for the Owner Admin integration card ('' = nothing to show)."""
    u = usage(provider)
    lim = u["limits"]
    if not lim:
        return ""

    def n(v):
        v = str(int(v))
        return v.translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")) if lang == "bn" else v
    names = {"bn": {"api_calls": "API কল", "messages": "মেসেজ", "traffic_mb": "ট্রাফিক (MB)"},
             "en": {"api_calls": "API calls", "messages": "messages", "traffic_mb": "traffic MB"}}
    nm = names["bn" if lang == "bn" else "en"]
    parts = ["%s %s/%s (%s%%)" % (nm[k], n(u[k]), n(lim[k]), n(u["pct"][k]))
             for k in COUNTERS if lim.get(k)]
    head = "এই মাসের ফ্রি কোটা: " if lang == "bn" else "Free quota this month: "
    s = head + ", ".join(parts)
    if u["warn"]:
        s += (" — ৮০%-এর বেশি: ঐচ্ছিক পোলিং কমানো হয়েছে" if lang == "bn"
              else " — over 80%: optional polling reduced")
    return s
