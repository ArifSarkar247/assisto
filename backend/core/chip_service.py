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
    if k == "left_behind":
        return left_text(alert, t)
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
        try:                                   # chipbuy2
            end_find_if_due(t, now)
            check_left_behind(t, item.get("fixes") or [], now)
        except Exception:
            log.exception("chip left/find %s failed", tid)


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
           "guardians": [{"id": u.id, "name": u.name or ""} for u in guardian_users(t)],
           # chipbuy2: honest range, left-behind, find now
           "range": "gps_network",
           "left_behind": _left_json(t, now),
           "find": find_state(t, now)}
    if mine:
        out["imei"] = t.imei
        out["child_user_id"] = t.child_user_id
    return out


def _left_json(t, now):
    cfg = left_cfg(t)
    still = (t.alert_state or {}).get("chip_still") or {}
    out = {"on": cfg["on"], "min": cfg["min"], "choices": list(LEFT_MIN_CHOICES),
           "safe": cfg["safe"], "safe_max": SAFE_MAX, "alerted_spot": None}
    if cfg["on"] and still.get("alerted") and still.get("lat") is not None and \
            not _in_safe(cfg["safe"], still["lat"], still["lng"]):
        out["alerted_spot"] = {"lat": still["lat"], "lng": still["lng"],
                               "since": still.get("since")}
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


# ===================================================================
# chipbuy2 (owner 3 Nov): LEFT-BEHIND alert + FIND NOW.
#
# HONEST RANGE: a GPS chip reports over the mobile network from anywhere
# with coverage; a Bluetooth tag (AirTag / SmartTag / Tile) is NOT supported
# (no open API, and a background BLE scanner is a native crash/battery risk).
#
# Left-behind: the chip stays within STILL_M of one spot for `min` minutes
# and that spot is not a SAFE place (school-plan home / school + places the
# owner marked safe) -> one alert per spot to the chip's alert audience.
# Opt-in (default OFF); never at night (a bag at rest at night is normal).
# Settings live in t.alert_prefs (written only by the API); the runtime
# anchor lives in t.alert_state["chip_still"] (written only here, after the
# ingest's own alert_state write, from the serial tracker daemon).
# ===================================================================
STILL_M = 100                    # moved more than this = a new spot
LEFT_MIN_CHOICES = (30, 60, 120)
LEFT_MIN_DEFAULT = 60
SAFE_MAX = 8
SAFE_RADIUS_M = 150
LEFT_QUIET = ("22:00", "06:30")
LEFT_DAY_CAP = 4
FIND_MIN = 10                    # find mode lasts this long
FIND_INTERVAL_S = 10             # one fix every 10 s while finding
FIND_COOLDOWN_S = 600


def left_cfg(t):
    """{"on", "min", "safe": [{lat,lng,radius_m,name}]} with defaults."""
    raw = (t.alert_prefs or {}).get("left_behind") or {}
    m = raw.get("min")
    if m not in LEFT_MIN_CHOICES:
        m = LEFT_MIN_DEFAULT
    safe = [p for p in (_clean_safe(x) for x in (raw.get("safe") or [])) if p][:SAFE_MAX]
    return {"on": bool(raw.get("on")), "min": m, "safe": safe}


def _clean_safe(p):
    from .logic import school_mode as SM
    c = SM.clean_place(dict(p or {}, radius_m=(p or {}).get("radius_m") or SAFE_RADIUS_M)) \
        if isinstance(p, dict) else None
    if c is None:
        return None
    return {"lat": c["lat"], "lng": c["lng"], "radius_m": c["radius_m"], "name": c["name"]}


def set_left_cfg(t, d):
    """Owner PATCH: {"on"?, "min"?, "safe_add"?: {lat,lng,name}, "safe_remove"?: i}.
    Returns the new cfg or raises ValueError(reason)."""
    cur = left_cfg(t)
    if "on" in d:
        cur["on"] = bool(d.get("on"))
    if "min" in d:
        try:
            m = int(d.get("min"))
        except (TypeError, ValueError):
            raise ValueError("bad_minutes")
        if m not in LEFT_MIN_CHOICES:
            raise ValueError("bad_minutes")
        cur["min"] = m
    if d.get("safe_add") is not None:
        p = _clean_safe(d.get("safe_add"))
        if p is None:
            raise ValueError("bad_place")
        if len(cur["safe"]) >= SAFE_MAX:
            raise ValueError("safe_limit")
        cur["safe"].append(p)
    if d.get("safe_remove") is not None:
        try:
            i = int(d.get("safe_remove"))
            cur["safe"].pop(i)
        except (TypeError, ValueError, IndexError):
            raise ValueError("bad_place")
    prefs = dict(t.alert_prefs or {})
    prefs["left_behind"] = cur
    t.alert_prefs = prefs
    type(t).objects.filter(pk=t.pk).update(alert_prefs=prefs)
    if d.get("safe_add") is not None:      # the alerted spot is now safe
        st = dict(t.alert_state or {})
        if st.get("chip_still"):
            st["chip_still"] = dict(st["chip_still"], alerted=True)
            type(t).objects.filter(pk=t.pk).update(alert_state=st)
    return cur


def safe_places(t):
    """Owner-marked safe places + the School Mode plan's home and school."""
    out = list(left_cfg(t)["safe"])
    plan = None
    try:
        plan = getattr(t, "school_plan", None)
    except Exception:  # noqa: BLE001 — RelatedObjectDoesNotExist
        plan = None
    cfg = (plan.config or {}) if plan is not None else {}
    for key in ("home", "school"):
        p = cfg.get(key)
        if isinstance(p, dict) and p.get("lat") is not None:
            out.append({"lat": p["lat"], "lng": p["lng"],
                        "radius_m": int(p.get("radius_m") or SAFE_RADIUS_M),
                        "name": key})
    return out


def _in_safe(places, lat, lng):
    from .logic import school_mode as SM
    for p in places:
        try:
            if SM.dist_m(float(p["lat"]), float(p["lng"]), lat, lng) <= \
                    float(p.get("radius_m") or SAFE_RADIUS_M) + 30:
                return True
        except (TypeError, ValueError, KeyError):
            continue
    return False


def step_still(still, fixes):
    """Pure: advance the stationary anchor with valid fixes (sorted).
    still = {lat,lng,since(iso),alerted} or {}. Returns the new anchor."""
    from .logic import school_mode as SM
    st = dict(still or {})
    for f in sorted(fixes or [], key=lambda f: f.get("at")):
        if not f.get("valid", True) or f.get("lat") is None or f.get("at") is None:
            continue
        at = f["at"]
        if st.get("lat") is None or SM.dist_m(st["lat"], st["lng"], f["lat"], f["lng"]) > STILL_M:
            st = {"lat": f["lat"], "lng": f["lng"], "since": at.isoformat(),
                  "alerted": False}
    return st


def left_due(cfg, still, places, now):
    """Pure decision: should a left-behind alert go out now?"""
    from datetime import datetime
    from .logic import vehicle_tracking as VT
    from .vehicle_service import LOCAL_TZ
    if not cfg.get("on") or not still or still.get("alerted") or still.get("lat") is None:
        return False
    try:
        since = datetime.fromisoformat(still["since"])
    except (TypeError, ValueError, KeyError):
        return False
    if (now - since).total_seconds() < cfg["min"] * 60:
        return False
    if VT.in_quiet(now.astimezone(LOCAL_TZ), *LEFT_QUIET):
        return False
    return not _in_safe(places, still["lat"], still["lng"])


def check_left_behind(t, fixes, now):
    """Called from after_ingest for every batch item of a chip (heartbeats
    included, so a still chip is checked every parked interval)."""
    from .models import VehicleTracker
    from . import vehicle_service as VS
    row = VehicleTracker.objects.filter(pk=t.pk).values_list("alert_state", flat=True).first()
    st = dict(row or {})
    still = step_still(st.get("chip_still"), fixes)
    sent = False
    cfg = left_cfg(t)
    if left_due(cfg, still, safe_places(t), now):
        day = now.astimezone(VS.LOCAL_TZ).date().isoformat()
        cap = st.get("chip_left_cap") or {}
        if cap.get("day") != day:
            cap = {"day": day, "n": 0}
        still["alerted"] = True
        if cap["n"] < LEFT_DAY_CAP:
            cap["n"] += 1
            from datetime import datetime
            mins = int((now - datetime.fromisoformat(still["since"])).total_seconds() // 60)
            VS.deliver_alert(t, {"kind": "left_behind", "minutes": mins,
                                 "lat": still["lat"], "lng": still["lng"]}, push=True)
            sent = True
        st["chip_left_cap"] = cap
    if still != st.get("chip_still") or sent:
        st["chip_still"] = still
        VehicleTracker.objects.filter(pk=t.pk).update(alert_state=st)
        t.alert_state = st
    return sent


def left_text(alert, t):
    nb, ne = _name(t, "bn"), _name(t, "en")
    from .logic import vehicle_tracking as VT
    m = int(alert.get("minutes") or 0)
    return (("%s-এর ব্যাগ/জুতা কোথাও ফেলে আসেনি তো?" % nb,
             "ট্র্যাকার চিপ %s মিনিট ধরে একই জায়গায়, যেটা বাসা বা স্কুল নয়। ম্যাপে দেখে "
             "খোঁজ নিন। জায়গাটা নিরাপদ হলে অ্যাপে 'নিরাপদ জায়গা' চাপুন।" % VT._bn(m)),
            ("Did %s leave the bag/shoes somewhere?" % ne,
             "The tracker chip has stayed in one place for %d minutes, and it is not "
             "home or school. Check the map. If the place is safe, tap 'Safe place' "
             "in the app." % m))


# --------------------------------------------------------------- find now

def find_state(t, now=None):
    """{"active", "until", "command": queued|sent|acked|failed|..., "can_find"}"""
    from .models import VehicleCommand
    now = now or timezone.now()
    f = (t.alert_prefs or {}).get("find") or {}
    out = {"active": False, "until": None, "command": None, "can_find": True}
    if not f.get("until"):
        return out
    from datetime import datetime
    try:
        until = datetime.fromisoformat(f["until"])
        started = datetime.fromisoformat(f["at"])
    except (TypeError, ValueError, KeyError):
        return out
    cmd = VehicleCommand.objects.filter(pk=f.get("cmd")).values_list("state", flat=True).first()
    out.update(active=now < until and not f.get("ended"), until=until.isoformat(),
               command=cmd,
               can_find=(now - started).total_seconds() >= FIND_COOLDOWN_S)
    return out


def start_find(t, actor, now=None):
    """Ask the chip for a fix every FIND_INTERVAL_S for FIND_MIN minutes.
    Returns (ok, reason)."""
    from .models import VehicleCommand
    now = now or timezone.now()
    if t.state != "paired":
        return False, "not_paired"
    if not find_state(t, now)["can_find"]:
        return False, "too_soon"
    VehicleCommand.objects.filter(tracker=t, kind="set_interval",
                                  state="queued").update(state="cancelled")
    cmd = VehicleCommand.objects.create(
        tracker=t, kind="set_interval", state="queued", requested_by=actor,
        payload={"moving_s": FIND_INTERVAL_S, "parked_s": FIND_INTERVAL_S, "find": True})
    prefs = dict(t.alert_prefs or {})
    prefs["find"] = {"at": now.isoformat(), "cmd": cmd.id,
                     "until": (now + timedelta(minutes=FIND_MIN)).isoformat()}
    t.alert_prefs = prefs
    type(t).objects.filter(pk=t.pk).update(alert_prefs=prefs)
    from . import vehicle_service as VS
    VS.audit(t, "chip_find", actor=actor)
    return True, ""


def end_find_if_due(t, now=None):
    """After FIND_MIN: queue the chip's normal intervals again (once)."""
    from datetime import datetime
    from . import vehicle_service as VS
    now = now or timezone.now()
    f = (t.alert_prefs or {}).get("find") or {}
    if not f.get("until") or f.get("ended"):
        return False
    try:
        if now < datetime.fromisoformat(f["until"]):
            return False
    except (TypeError, ValueError):
        pass
    prefs = dict(t.alert_prefs or {})
    prefs["find"] = dict(f, ended=True)
    t.alert_prefs = prefs
    type(t).objects.filter(pk=t.pk).update(alert_prefs=prefs)
    VS.queue_interval(t)
    return True
