"""Disk-usage owner alert (owner decision 2026-10: alert at 80 percent).

One small module used by TWO surfaces so they can never disagree:

  * the Owner Admin dashboard (/owner/) shows a red banner while the root
    filesystem is at/over the threshold (nothing at all under it);
  * the uptime_check cron (every 2 min) raises an owner alert — push/email via
    core.push.notify_owner + a FamilyAlert row (kind "disk_alert") for each
    superuser — de-duplicated to at most once per DEDUPE_HOURS.

The threshold is admin-editable: PricingConfig limits.disk_alert_pct (Owner
Admin -> Pricing & plans -> limits), default 80, clamped 50..99.
"""
import shutil
from datetime import datetime, timedelta, timezone as dt_tz

DEFAULT_PCT = 80
DEDUPE_HOURS = 6
PATH = "/"


def disk_usage(path=PATH):
    """Indirection so tests can mock it (core.disk_alert.disk_usage)."""
    return shutil.disk_usage(path)


def threshold_pct():
    try:
        from . import billing
        return int(billing.cfg()["limits"].get("disk_alert_pct", DEFAULT_PCT))
    except Exception:
        return DEFAULT_PCT


def status(path=PATH, threshold=None):
    """{used_pct, free_gb, total_gb, threshold, alert}. Never raises (an
    unreadable disk -> alert False with error set)."""
    t = int(threshold if threshold is not None else threshold_pct())
    try:
        u = disk_usage(path)
        total = float(u.total or 0)
        used_pct = (float(u.used) / total * 100.0) if total else 0.0
        return {"used_pct": round(used_pct, 1),
                "free_gb": round(float(u.free) / 1e9, 1),
                "total_gb": round(total / 1e9, 1),
                "threshold": t, "alert": used_pct >= t, "error": ""}
    except Exception as e:  # noqa: BLE001
        return {"used_pct": 0.0, "free_gb": 0.0, "total_gb": 0.0,
                "threshold": t, "alert": False, "error": type(e).__name__}


_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(v):
    return str(v).translate(_BN)


def message(st, lang="en"):
    """(title, body) for the owner alert, in one language."""
    if lang == "bn":
        pct, free, lim = (bn_digits(st["used_pct"]), bn_digits(st["free_gb"]),
                          bn_digits(st["threshold"]))
        return ("সার্ভারের ডিস্ক %s%% ভরে গেছে" % pct,
                "ডিস্ক %s%% ব্যবহার হয়েছে (সীমা %s%%), খালি আছে %s GB। "
                "নিরাপদে জায়গা খালি করুন: পুরোনো লগ ও ব্যাকআপ মুছুন, "
                "`sudo journalctl --vacuum-size=200M` ও `sudo apt-get clean` চালান। "
                "ডাটাবেস বা media ফোল্ডারের ফাইল মুছবেন না।"
                % (pct, lim, free))
    return ("Server disk %s%% full" % st["used_pct"],
            "Disk is %s%% used (alert at %s%%), %s GB free. Safe cleanup: "
            "remove old logs and old backups, run "
            "`sudo journalctl --vacuum-size=200M` and `sudo apt-get clean`. "
            "Do not delete the database or the media folder."
            % (st["used_pct"], st["threshold"], st["free_gb"]))


def _parse(iso):
    try:
        d = datetime.fromisoformat(iso)
        return d if d.tzinfo else d.replace(tzinfo=dt_tz.utc)
    except Exception:
        return None


def check_and_alert(state, now=None, notify=None):
    """Run from uptime_check with its persisted `state` dict (mutated in place).

    At/over the threshold: alert the owner unless one was already sent within
    DEDUPE_HOURS (state["disk_alert_at"]). Under it: nothing is sent and the
    dedupe marker is cleared, so a NEW crossing alerts straight away.
    Returns the status dict with "alerted": bool. Never raises."""
    now = now or datetime.now(dt_tz.utc)
    st = status()
    st["alerted"] = False
    if not st["alert"]:
        state.pop("disk_alert_at", None)
        return st
    last = _parse(state.get("disk_alert_at") or "")
    if last and now - last < timedelta(hours=DEDUPE_HOURS):
        return st
    title, body = message(st, "en")
    try:
        if notify is None:
            from .push import notify_owner as notify
        notify(title, body)
    except Exception:  # noqa: BLE001 — alerting must never crash the check
        pass
    _alert_rows(st)
    state["disk_alert_at"] = now.isoformat(timespec="seconds")
    st["alerted"] = True
    return st


def _alert_rows(st):
    """An ADMIN notification per owner (notification centre), in Bangla +
    English. Best-effort."""
    try:
        from django.utils import timezone
        from .models import User, NotifEvent
        t_bn, b_bn = message(st, "bn")
        t_en, b_en = message(st, "en")
        # owner 25 Oct: an ADMIN notification, not a Family alert
        for o in User.objects.filter(is_superuser=True, is_active=True)[:5]:
            NotifEvent.objects.create(
                user=o, type="admin", title_en=t_en[:200], title_bn=t_bn[:200],
                body_en=b_en, body_bn=b_bn, route="owner",
                meta={"source": "uptime_check", "kind": "disk_alert",
                      "used_pct": st["used_pct"], "free_gb": st["free_gb"],
                      "threshold": st["threshold"]},
                at=timezone.now())
    except Exception:
        pass
