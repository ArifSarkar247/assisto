"""fcbrain — the notification budget (Family Care v3, BRAIN 7, owner 9 Nov).

Assisto speaks only when needed: at most LIMIT (3) NON-SAFETY notifications
per user per local day. ONE central gate, called from the two places every
tray notification leaves the server:

  * core.push.push_to_user          (every push kind)
  * core.family_alerts._push        (family alert kinds, incl. held releases)

Safety ALWAYS passes and is never counted: SOS, fall, check-in overdue,
wellness, crisis, family arrival / low-battery last location, Care Call
rings + statuses, calls, the anti-theft engine. Person-to-person traffic
(messages, calls, a stranger's first message) and things the user asked for
themselves (their own reminders, an agent approval they started) are not
"Assisto speaking" and are not counted either. Silent data pushes draw
nothing and are never counted.

Counted (Assisto-initiated, non-safety): agent nudges, offers, prepaid meter,
document expiry, budget alerts, channel posts, community joins, market, shop
dues, the night news card and every non-urgent family alert kind.

Reserve: while the user's night news is on and not yet sent today, ordinary
kinds may use only LIMIT-1 slots so the one card the user chose to get is
never crowded out by an offer.

Over budget: the push is skipped (the in-app card / feed row is still
written by the caller — nothing is lost, it just does not ring). Counter
rows live in the generic PaCollectionItem store (no migration):
collection "notif_budget", one row per user, {day, n, kinds}. Never raises.
"""
import logging
from datetime import timedelta, timezone as dt_timezone

from django.db import transaction
from django.utils import timezone

log = logging.getLogger(__name__)

LIMIT = 3
COLLECTION = "notif_budget"
NIGHT_NEWS = "night_news"

# push kinds that are never counted (safety / person-to-person / user-asked /
# silent). Anything not listed here and not in BUDGETED is treated as
# budgeted — a new nudge kind can never silently escape the cap.
EXEMPT_PUSH_KINDS = frozenset({
    "sos", "call", "call_cancel", "missed_call", "message", "message_request",
    "msg_sync", "key_request", "key_ready", "at_command", "shop_alert",
    "owner_alert", "reminder", "agent_approval", "carecall", "carecall_invite",
    "carecall_status",
    # family_alert pushes are gated per family-alert kind inside
    # core.family_alerts._push (so a held release is gated too) — never twice
    "family_alert",
})
# family alert kinds (core.family_alerts.KINDS) that are SAFETY
SAFETY_FAMILY_KINDS = frozenset({
    "sos", "sos_resolved", "checkin_overdue", "wellness_alert", "crisis_support",
    "fall", "auto_arrived", "auto_left", "battery_low_loc", "dest_arrived",
    "scam_report",
    "watch_amber", "carecall_missed",
})


def is_safety(kind, family_kind=""):
    """True when `kind` (push kind, or 'family_alert' + family_kind) is never
    counted against the budget."""
    k = str(kind or "")
    if k == "family_alert":
        return str(family_kind or "") in SAFETY_FAMILY_KINDS
    if k.startswith("family:"):
        return k[7:] in SAFETY_FAMILY_KINDS
    return k in EXEMPT_PUSH_KINDS


def _tz_for(user):
    """The user's local clock: the offset their phone reported to the
    family brain (Probashi), else Asia/Dhaka."""
    try:
        from . import family_brain
        off = family_brain.tz_offset_min(user)
        if off is not None:
            return dt_timezone(timedelta(minutes=off))
    except Exception:  # noqa: BLE001
        pass
    from zoneinfo import ZoneInfo
    return ZoneInfo("Asia/Dhaka")


def local_day(user, now=None):
    now = now or timezone.now()
    return now.astimezone(_tz_for(user)).date().isoformat()


def _night_news_pending(user, day):
    try:
        from . import family_brain
        return family_brain.night_news_pending(user, day)
    except Exception:  # noqa: BLE001
        return False


def _row(user, lock=False):
    from .models import PaCollectionItem
    qs = PaCollectionItem.objects.filter(user=user, collection=COLLECTION)
    if lock:
        qs = qs.select_for_update()
    row = qs.order_by("id").first()
    if row is None:
        row = PaCollectionItem.objects.create(user=user, collection=COLLECTION,
                                              data={"day": "", "n": 0, "kinds": []})
    return row


def used_today(user, now=None):
    """How many budgeted notifications rang today (0..LIMIT)."""
    try:
        from .models import PaCollectionItem
        row = PaCollectionItem.objects.filter(user=user, collection=COLLECTION).first()
        d = (row.data or {}) if row else {}
        return int(d.get("n") or 0) if d.get("day") == local_day(user, now) else 0
    except Exception:  # noqa: BLE001
        return 0


def allow(user, kind, safety=None, family_kind="", now=None):
    """The ONE gate. Returns True when this notification may ring. Safety is
    always True (and not counted). For a budgeted kind the slot is taken
    atomically. Never raises: on an internal error a safety-or-not unknown
    defaults to allowing (a broken counter must never mute the family)."""
    try:
        if user is None:
            return False
        if safety is None:
            safety = is_safety(kind, family_kind)
        if safety:
            return True
        label = (str(family_kind or kind) or "?")[:24]
        day = local_day(user, now)
        with transaction.atomic():
            row = _row(user, lock=True)
            d = dict(row.data or {})
            if d.get("day") != day:
                d = {"day": day, "n": 0, "kinds": []}
            n = int(d.get("n") or 0)
            cap = LIMIT
            if label != NIGHT_NEWS and _night_news_pending(user, day):
                cap = LIMIT - 1
            if n >= cap:
                d["skipped"] = int(d.get("skipped") or 0) + 1
                row.data = d
                row.save(update_fields=["data", "updated_at"])
                log.info("notif_budget: over budget kind=%s", label)
                return False
            d["n"] = n + 1
            d["kinds"] = (list(d.get("kinds") or []) + [label])[-10:]
            row.data = d
            row.save(update_fields=["data", "updated_at"])
            return True
    except Exception as e:  # noqa: BLE001
        log.warning("notif_budget: gate error %s", type(e).__name__)
        return True


def status(user, now=None):
    """For the settings screen: {limit, used, left, skipped}."""
    used = used_today(user, now)
    skipped = 0
    try:
        from .models import PaCollectionItem
        row = PaCollectionItem.objects.filter(user=user, collection=COLLECTION).first()
        d = (row.data or {}) if row else {}
        if d.get("day") == local_day(user, now):
            skipped = int(d.get("skipped") or 0)
    except Exception:  # noqa: BLE001
        pass
    return {"limit": LIMIT, "used": used, "left": max(0, LIMIT - used), "skipped": skipped}
