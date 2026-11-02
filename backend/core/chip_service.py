"""
chip_service.py — tracker chip for a child's school bag / shoe (chipbuy,
owner 2 Nov). NOT a fork of vehicle tracking: a chip IS a VehicleTracker
(kind='chip') on the same tracker daemon, the same decoders (GT06 / H02 /
TK103 / Teltonika, JT808 when merged), the same pairing window, the same
ingest, alarm and silent-tracker logic. This module only adds what a CHILD
device needs on top:

  * battery percent (GT06 voltage level 0..6 or internal battery volts);
  * child wording for alerts ("Rafi's bag tracker battery is low");
  * School Mode feed — a chip can drive a SchoolPlan exactly like a kids
    watch (left home / reached school / left the school area / late), via
    kidswatch_service.plan_fixes (the same state machine, no copy);
  * viewers = owner + guardians (VehicleAccessGrant kind='family'), each
    re-checked as an accepted, unblocked Circle peer on every delivery
    (core.guardianship.chip_guardians); ALERTS go to
    guardianship.alert_audience — the viewers + every other guardian of the
    child from any feature (the other parent's watch / school plan), exactly
    like a kids watch alert (finish1);
  * the CHILD (if they have Assisto) sees that a chip is on and WHO can see
    it — never the location history (guardian only).

SAFETY IS FREE: a chip is never charged, never refused for credits. History
is kept HISTORY_HOURS (chip retention, shorter than a vehicle's).
"""
import logging
from datetime import timedelta

from django.utils import timezone

log = logging.getLogger(__name__)

MAX_CHIPS_PER_USER = 5
MAX_GUARDIANS = 6
HISTORY_HOURS = 48
MOVING_INTERVAL_S = 60       # a walking child: one fix a minute
PARKED_INTERVAL_S = 600      # at home / school: every 10 min (battery)
LOW_PCT = 20
# Chip alert defaults: non-safety kinds quiet at night; "silent" only after 3 h
# (mini trackers sleep when still; a dead battery is the usual cause).
CHIP_PREFS = {"silent_min": 180, "quiet_start": "22:00", "quiet_end": "06:30",
              "ignition_on": False, "ignition_off": False, "stop_alert_min": 0}
# GT06 0x13 voltage level -> approximate percent (Concox protocol doc:
# 0 no power, 1 extremely low, 2 very low / low-battery alarm, 3 low,
# 4 medium, 5 high, 6 full).
GT06_LEVEL_PCT = {0: 0, 1: 5, 2: 15, 3: 35, 4: 60, 5: 85, 6: 100}
LIION_EMPTY_V = 3.45
LIION_FULL_V = 4.15


def battery_pct(voltage_level=None, battery_v=None):
    """Best-effort percent from what the model sends; None when unknown
    (the app then says 'battery: not reported' — never a made-up number)."""
    if voltage_level is not None:
        try:
            return GT06_LEVEL_PCT.get(int(voltage_level))
        except (TypeError, ValueError):
            pass
    if battery_v is not None:
        try:
            v = float(battery_v)
        except (TypeError, ValueError):
            return None
        if v <= 0:
            return None
        pct = (v - LIION_EMPTY_V) / (LIION_FULL_V - LIION_EMPTY_V) * 100.0
        return int(max(0, min(100, round(pct))))
    return None


# --------------------------------------------------------------- audience

def guardian_users(t):
    """Guardians the owner chose that are STILL accepted, unblocked Circle
    peers (someone who left the Circle stops getting the location at once).
    One source of truth: core.guardianship.chip_guardians."""
    from . import guardianship
    return [u for u in guardianship.chip_guardians(t) if u.id != t.child_user_id]


def viewers(t):
    """Who may SEE the chip's location: owner + its valid guardians."""
    return [t.owner] + guardian_users(t)


def alert_users(t):
    """Who is TOLD about a chip alert: owner + its guardians + every other
    guardian of the child (core.guardianship.alert_audience), never the
    child. Falls back to the viewers if the lookup fails."""
    from . import guardianship
    try:
        ids = [u.id for u in guardian_users(t)]
        out = guardianship.alert_audience(t.owner, ids, t.child_user)
        return out or viewers(t)
    except Exception:  # noqa: BLE001 — an alert must never be lost
        log.exception("chip alert_users %s failed", t.pk)
        return viewers(t)


def can_view(user, t):
    """Owner + valid guardians. The child is NOT a viewer of the location."""
    if not user or not user.is_authenticated:
        return False
    if t.owner_id == user.id:
        return True
    return any(u.id == user.id for u in guardian_users(t))


def set_guardians(t, ids):
    """Replace the family grants with the owner's accepted Circle peers in
    `ids` (never the owner, never the child, at most MAX_GUARDIANS)."""
    from . import kidswatch_service as KW
    from .models import VehicleAccessGrant, User
    keep = [u for u in KW.clean_guardians(t.owner, ids) if u != t.child_user_id]
    keep = keep[:MAX_GUARDIANS]
    VehicleAccessGrant.objects.filter(tracker=t, kind="family").exclude(
        grantee_id__in=keep).delete()
    have = set(VehicleAccessGrant.objects.filter(tracker=t).values_list(
        "grantee_id", flat=True))
    for u in User.objects.filter(pk__in=[k for k in keep if k not in have]):
        VehicleAccessGrant.objects.create(tracker=t, grantee=u, kind="family",
                                          can_command=False)
    return keep


# --------------------------------------------------------------- texts

def _name(t, lang):
    n = t.child_name or t.name
    if n:
        return n
    return "আপনার সন্তান" if lang == "bn" else "Your child"


def alert_text(alert, t):
    """((title_bn, body_bn), (title_en, body_en)) in child wording; vehicle
    words (engine, ignition) never reach a parent about a school bag."""
    from .logic import vehicle_tracking as VT
    k, al = alert.get("kind"), alert.get("alarm")
    nb, ne = _name(t, "bn"), _name(t, "en")
    pct = t.battery_pct
    if k == "device_alarm" and al == "low_battery":
        pb = (" (%s%%)" % VT._bn(pct)) if pct is not None else ""
        pe = (" (%d%%)" % pct) if pct is not None else ""
        return (("%s-এর ট্র্যাকার চিপে চার্জ কম%s" % (nb, pb),
                 "আজ রাতে চিপটি চার্জে দিন, না হলে কাল অবস্থান পাওয়া যাবে না।"),
                ("%s's tracker chip battery is low%s" % (ne, pe),
                 "Please charge the chip tonight, or there will be no location tomorrow."))
    if k == "tracker_silent":
        m = int(alert.get("minutes") or 0)
        return (("%s-এর ট্র্যাকার চিপ সাড়া দিচ্ছে না" % nb,
                 "%s মিনিট ধরে চিপ থেকে কোনো সংকেত আসেনি। চার্জ শেষ, সিমে ডাটা নেই বা "
                 "নেটওয়ার্ক নেই হতে পারে। শেষ জানা অবস্থান অ্যাপে আছে।" % VT._bn(m)),
                ("%s's tracker chip is not responding" % ne,
                 "No signal from the chip for %d minutes. The battery may be empty, the "
                 "SIM may have no data, or there is no network. The last known location "
                 "is in the app." % m))
    if k == "device_alarm" and al == "sos":
        return (("%s চিপের SOS চেপেছে" % nb,
                 "চিপের SOS বোতাম চাপা হয়েছে। এখনই খোঁজ নিন।"),
                ("%s pressed SOS on the chip" % ne,
                 "The chip's SOS button was pressed. Please check right now."))
    if k == "device_alarm" and al in ("tamper", "power_off", "power_cut"):
        return (("%s-এর ট্র্যাকার চিপ বন্ধ বা খোলা হয়েছে" % nb,
                 "চিপ বন্ধ করা হয়েছে বা খোলা হয়েছে। দয়া করে খোঁজ নিন।"),
                ("%s's tracker chip was switched off or opened" % ne,
                 "The chip was switched off or opened. Please check in."))
    return (VT.alert_text(alert, nb, "bn"), VT.alert_text(alert, ne, "en"))


# --------------------------------------------------------------- ingest

def after_ingest(batch, trackers, now=None):
    """Called at the end of vehicle_service.ingest for batches that hold a
    chip: store battery percent, then feed fresh fixes into the chip's
    School Mode plan. Never raises (tracking must not stop for this)."""
    from .models import VehicleTracker
    now = now or timezone.now()
    for tid, item in batch.items():
        t = trackers.get(tid)
        if t is None or t.kind != "chip":
            continue
        try:
            st = item.get("status") or {}
            pct = None
            fixes = item.get("fixes") or []
            for f in fixes:
                p = battery_pct(None, f.get("battery_v"))
                if f.get("battery") is not None:
                    p = int(f["battery"])
                pct = p if p is not None else pct
            p = battery_pct(st.get("voltage_level"), st.get("battery_v"))
            pct = p if p is not None else pct
            if pct is not None:
                VehicleTracker.objects.filter(pk=t.pk).update(battery_pct=pct)
                t.battery_pct = pct
            if fixes:
                feed_school_plan(t, fixes, now)
        except Exception:
            log.exception("chip after_ingest %s failed", tid)


def feed_school_plan(t, fixes, now):
    from .models import SchoolPlan
    from . import kidswatch_service as KW
    plan = SchoolPlan.objects.filter(chip=t).select_related(
        "owner", "child_user").first()
    if plan is None:
        return 0
    return KW.plan_fixes(plan, [
        {"at": f.get("at") or now, "lat": f.get("lat"), "lng": f.get("lng"),
         "valid": f.get("valid", True), "blind": f.get("buffered", False)}
        for f in fixes], now)


# --------------------------------------------------------------- json

def chip_json(t, user, now=None):
    now = now or timezone.now()
    from . import vehicle_service as VS
    cfg = VS.vcfg()
    online = bool(t.last_seen_at and (now - t.last_seen_at).total_seconds()
                  < cfg.get("online_window_s", 900))
    plan = getattr(t, "school_plan", None) if t.pk else None
    mine = t.owner_id == user.id
    out = {"id": t.id, "kind": "chip", "child_name": t.child_name or t.name,
           "imei_tail": t.imei[-4:], "protocol": t.protocol, "state": t.state,
           "mine": mine, "online": online, "last_seen_at": _iso(t.last_seen_at),
           "pair_expires_at": _iso(t.pair_expires_at),
           "battery": t.battery_pct,
           "battery_low": t.battery_pct is not None and t.battery_pct <= LOW_PCT,
           "live": None if t.last_lat is None else {
               "lat": t.last_lat, "lng": t.last_lng, "at": _iso(t.last_fix_at),
               "source": "gps"},
           "school_plan_id": plan.id if plan else None,
           "child_has_app": t.child_user_id is not None,
           "guardians": [{"id": u.id, "name": u.name or ""} for u in guardian_users(t)]}
    if mine:
        out["imei"] = t.imei
        out["child_user_id"] = t.child_user_id
    return out


def worn_json(t):
    """What the CHILD sees: it is on, who set it up, who can see — no
    location, no history."""
    return {"id": t.id, "kind": "chip", "state": t.state,
            "owner_name": t.owner.name or "",
            "watchers": [u.name or "" for u in viewers(t)],
            "battery": t.battery_pct}


def _iso(dt):
    return dt.isoformat() if dt else None


def history(t, hours, now=None):
    now = now or timezone.now()
    hours = max(1, min(HISTORY_HOURS, int(hours)))
    pts = t.positions.filter(at__gte=now - timedelta(hours=hours),
                             valid=True).order_by("at")[:3000]
    return [{"at": _iso(p.at), "lat": p.lat, "lng": p.lng} for p in pts]


def prune(now=None):
    """Chip history older than HISTORY_HOURS is deleted (privacy first)."""
    from .models import VehiclePosition
    now = now or timezone.now()
    return VehiclePosition.objects.filter(
        tracker__kind="chip", at__lt=now - timedelta(hours=HISTORY_HOURS)).delete()[0]
