"""
b6-antitheft — PURE logic for the native Lost/Stolen engine (no DB writes, no
network). Views in core/views_antitheft.py call these.

HONESTY RULES baked in here:
  * alert wording is "please check", never an accusation;
  * we never claim the phone number of a new SIM (Android does not give it to
    normal apps on most phones) — we report what IS known: that the SIM
    changed, when, and the carrier name if the phone could read it;
  * airplane mode / power-off cannot be blocked by any app — we only say WHEN
    it happened and the last location we had;
  * an event delivered late (store-and-forward) says so, with its real time.
"""
import base64
import hashlib
import secrets
from datetime import timedelta

from django.conf import settings
from django.utils import timezone
from django.utils.dateparse import parse_datetime

# --- ingestion ------------------------------------------------------------
MAX_ITEMS_PER_POST = 100
CLOCK_SKEW_TOLERANCE_S = 120     # beyond this we correct the device clock
MAX_EVENT_AGE_DAYS = 30          # older store-and-forward items are refused
LATE_AFTER_S = 600               # delivered > 10 min after it happened = late
EVENT_RETENTION_DAYS = 30        # events + photos are pruned after this
RECENT_IDS_KEEP = 300            # heartbeat dedupe ring size
ALERT_COOLDOWN_MIN = 10          # at most one alert per kind per phone per 10 min
MAX_PHOTO_BYTES = 2 * 1024 * 1024
MAX_PHOTOS_PER_DAY = 20
THRESHOLD_MIN, THRESHOLD_MAX = 2, 10

EVENT_KINDS = {"snatch", "snatch_cleared", "sim_change", "offline", "online",
               "low_battery", "shutdown", "boot", "failed_unlock",
               "intruder_photo", "test"}
# Kinds that are a theft SIGNAL (freeze Section-8 sensitive actions for 48h).
SIGNAL_KINDS = {"snatch": "snatch", "sim_change": "sim_change"}
# Kinds that never alert anyone (just stored for the timeline).
SILENT_KINDS = {"online"}
# Kinds that alert the OWNER only (never family).
OWNER_ONLY_KINDS = {"test"}

# Battery-aware heartbeat policy the engine follows (minutes). Mirrored in
# app/android_overlay/.../antitheft/HeartbeatPolicy.kt — keep in sync.
INTERVAL_CHARGING = 10
INTERVAL_NORMAL = 15
INTERVAL_LOW = 30      # battery <= 30%
INTERVAL_CRITICAL = 60  # battery <= 15%
INTERVAL_LOST = 5      # lost mode on (unless battery critical)


def heartbeat_interval_min(battery, charging, lost_mode):
    """The interval the engine should use next. Pure; mirrored natively."""
    b = battery if isinstance(battery, int) else None
    if charging:
        return INTERVAL_CHARGING if not lost_mode else INTERVAL_LOST
    if b is not None and b <= 15:
        return INTERVAL_CRITICAL
    if lost_mode:
        return INTERVAL_LOST
    if b is not None and b <= 30:
        return INTERVAL_LOW
    return INTERVAL_NORMAL


# --- went dark (at-heartbeat) ---------------------------------------------
# "Stopped checking in" must survive Doze, OEM battery savers and a slow
# network: a phone's heartbeat can easily arrive one or two intervals late.
# We only call a phone dark after SEVERAL missed check-ins AND a minimum
# silence AND a grace window. A phone the engine reports as battery-optimised
# (Android may delay it much more) gets an even longer wait.
WENT_DARK_MISSED = 4            # missed check-ins (intervals) before "dark"
WENT_DARK_FLOOR_MIN = 45        # never "dark" after less silence than this
WENT_DARK_GRACE_MIN = 10        # extra slack on top (late heartbeats)
WENT_DARK_MISSED_OPTIMISED = 6  # battery-optimised phones: wait longer
WENT_DARK_FLOOR_OPTIMISED_MIN = 90
HEARTBEAT_INTERVAL_MAX = 120    # sanity cap for a device-reported interval


def went_dark_threshold_min(interval_min, battery_optimised=False):
    """Minutes of silence after which a protected phone counts as dark."""
    try:
        iv = int(interval_min or 0)
    except (TypeError, ValueError):
        iv = 0
    if iv <= 0:
        iv = INTERVAL_NORMAL
    iv = min(iv, HEARTBEAT_INTERVAL_MAX)
    if battery_optimised:
        base = max(iv * WENT_DARK_MISSED_OPTIMISED, WENT_DARK_FLOOR_OPTIMISED_MIN)
    else:
        base = max(iv * WENT_DARK_MISSED, WENT_DARK_FLOOR_MIN)
    return base + WENT_DARK_GRACE_MIN


def last_seen_at(*stamps):
    """The newest of the given datetimes (heartbeat, any ingest...), or None."""
    xs = [s for s in stamps if s is not None]
    return max(xs) if xs else None


def battery_optimised(capabilities):
    """True only when the engine REPORTED that Android battery optimisation is
    on for Assisto (unknown -> False: the normal thresholds apply)."""
    if not isinstance(capabilities, dict):
        return False
    return capabilities.get("batteryOptimised") is True


def reported_interval(item, lost_mode=False):
    """The heartbeat interval the engine says it is using now (newer engines
    send `interval`), else the policy estimate from the battery it sent."""
    v = i_or_none(item.get("interval")) if isinstance(item, dict) else None
    if v is not None and 1 <= v <= HEARTBEAT_INTERVAL_MAX:
        return v
    if not isinstance(item, dict):
        return None
    b = i_or_none(item.get("battery"))
    if b is None:
        return None
    return heartbeat_interval_min(b, item.get("charging") is True, lost_mode)


# --- tokens ---------------------------------------------------------------

def new_engine_token():
    """(raw, sha256-hex). Only the hash is stored."""
    raw = secrets.token_urlsafe(32)
    return raw, hash_token(raw)


def hash_token(raw):
    return hashlib.sha256(("assisto-engine:" + str(raw or "")).encode()).hexdigest()


# --- timestamps -----------------------------------------------------------

def _parse(raw):
    if not raw:
        return None
    if hasattr(raw, "tzinfo"):
        dt = raw
    else:
        try:
            dt = parse_datetime(str(raw))
        except Exception:
            dt = None
        if dt is None:
            # epoch millis (what the Kotlin engine sends)
            try:
                ms = int(raw)
                from datetime import datetime, timezone as _tz
                dt = datetime.fromtimestamp(ms / 1000.0, tz=_tz.utc)
            except Exception:
                return None
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt, timezone.utc)
    return dt


def clock_offset(sent_at_raw, now):
    """Server-minus-device clock offset (timedelta) from the batch `sent_at`.
    Zero when the device clock is within tolerance or sent_at is missing."""
    sent = _parse(sent_at_raw)
    if sent is None:
        return timedelta(0)
    off = now - sent
    if abs(off.total_seconds()) <= CLOCK_SKEW_TOLERANCE_S:
        return timedelta(0)
    return off


def corrected_at(at_raw, offset, now):
    """Original event time on the server clock. Returns (dt, ok). Future times
    are clamped to now; items older than MAX_EVENT_AGE_DAYS are rejected."""
    at = _parse(at_raw)
    if at is None:
        return now, True
    at = at + offset
    if at > now:
        at = now
    if at < now - timedelta(days=MAX_EVENT_AGE_DAYS):
        return at, False
    return at, True


def is_late(at, now):
    return (now - at).total_seconds() > LATE_AFTER_S


# --- coercion -------------------------------------------------------------

def f_or_none(v):
    if v in (None, ""):
        return None
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    if x != x:  # NaN
        return None
    return x


def i_or_none(v):
    if v in (None, ""):
        return None
    try:
        return int(float(v))
    except (TypeError, ValueError, OverflowError):   # qs: "inf" was a 500
        return None


def valid_latlng(lat, lng):
    return (lat is not None and lng is not None
            and -90 <= lat <= 90 and -180 <= lng <= 180)


def clean_data(d, limit=40):
    """Keep a small, JSON-safe, flat-ish dict (no huge blobs from a device)."""
    if not isinstance(d, dict):
        return {}
    out = {}
    for k, v in list(d.items())[:limit]:
        k = str(k)[:40]
        if isinstance(v, (int, float, bool)) or v is None:
            out[k] = v
        elif isinstance(v, str):
            out[k] = v[:300]
        elif isinstance(v, (list, dict)):
            try:
                import json
                enc = json.dumps(v)
                out[k] = v if len(enc) <= 1500 else enc[:1500]
            except Exception:
                out[k] = str(v)[:300]
        else:
            out[k] = str(v)[:300]
    return out


# --- encryption at rest (intruder photos) ---------------------------------

def _fernet():
    from cryptography.fernet import Fernet
    raw = getattr(settings, "ANTITHEFT_PHOTO_KEY", "") or ""
    if raw:
        material = hashlib.sha256(("assisto-at-photo:" + raw).encode()).digest()
    else:
        material = hashlib.sha256(
            ("assisto-at-photo:" + settings.SECRET_KEY).encode()).digest()
    return Fernet(base64.urlsafe_b64encode(material))


def encrypt_photo(data: bytes) -> bytes:
    return _fernet().encrypt(data)


def decrypt_photo(token: bytes) -> bytes:
    return _fernet().decrypt(token)


def looks_like_jpeg(data: bytes) -> bool:
    return len(data) > 4 and data[:3] == b"\xff\xd8\xff"


# --- signed photo links (owner / approved family only) ---------------------
PHOTO_LINK_TTL_S = 600


def _link_sig(event_id, viewer_id, exp):
    import hmac
    key = hashlib.sha256(b"assisto-at-link:" + settings.SECRET_KEY.encode()).digest()
    msg = ("%d|%d|%d" % (int(event_id), int(viewer_id), int(exp))).encode()
    return hmac.new(key, msg, hashlib.sha256).hexdigest()[:40]


def photo_link_params(event_id, viewer_id, now_ts=None):
    import time
    now_ts = int(now_ts if now_ts is not None else time.time())
    exp = now_ts + PHOTO_LINK_TTL_S
    return {"v": int(viewer_id), "e": exp, "s": _link_sig(event_id, viewer_id, exp)}


def verify_photo_link(event_id, viewer_id, exp, sig, now_ts=None):
    import hmac
    import time
    try:
        viewer_id = int(viewer_id)
        exp = int(exp)
    except (TypeError, ValueError):
        return False
    if exp < int(now_ts if now_ts is not None else time.time()):
        return False
    return hmac.compare_digest(_link_sig(event_id, viewer_id, exp), str(sig or ""))


# --- alert wording (bn + en; "please check") -------------------------------

def _when(dt):
    return timezone.localtime(dt).strftime("%d %b %Y, %I:%M %p")


def _map(lat, lng):
    if lat is None or lng is None:
        return None
    return "https://www.google.com/maps/search/?api=1&query=%.6f,%.6f" % (lat, lng)


def alert_text(kind, owner_name, ev_at, data, lat, lng, battery, late, now,
               loc=None):
    """(title_en, body_en, title_bn, body_bn) for one event kind.

    antitheft2: `loc` (from pick_location) carries the best location we have —
    the event's own fix, else the server's last stored fix — with its accuracy
    and fix time; a stale fix says "last seen at <time>". Without `loc` the
    event's lat/lng are used as before."""
    name = owner_name or "Assisto user"
    w = _when(ev_at)
    if loc is None:
        loc = pick_location(lat, lng, None, None, ev_at)
    loc_en, loc_bn = location_text(loc, ev_at)
    late_en = ("(Delivered late: this happened at %s, while the phone was offline.) "
               % w) if late else ""
    late_bn = ("(দেরিতে পৌঁছেছে: ঘটনাটি %s সময়ের, তখন ফোনটি অফলাইন ছিল।) "
               % w) if late else ""
    d = data or {}

    if kind == "snatch":
        locked = bool(d.get("locked"))
        te = "Please check on %s's phone" % name
        tb = "%s-এর ফোনটি একবার দেখে নিন" % name
        be = ("At %s the phone felt a sudden grab followed by fast movement%s. "
              "It may be nothing (a drop or a quick run). %s" %
              (w, " and Assisto locked the screen" if locked else "", loc_en))
        bb = ("%s সময়ে ফোনটিতে হঠাৎ টান ও দ্রুত নড়াচড়া টের পাওয়া গেছে%s। "
              "এটা সাধারণ কিছুও হতে পারে (পড়ে যাওয়া বা দৌড়ানো)। %s" %
              (w, " এবং Assisto স্ক্রিন লক করে দিয়েছে" if locked else "", loc_bn))
    elif kind == "snatch_cleared":
        te = "Update about %s's phone" % name
        tb = "%s-এর ফোন সম্পর্কে আপডেট" % name
        be = ("The phone was unlocked with its own screen lock shortly after the "
              "earlier alert, so it was probably a false alarm.")
        bb = ("আগের সতর্কবার্তার কিছুক্ষণ পরেই ফোনটি তার নিজের স্ক্রিন লক দিয়ে খোলা "
              "হয়েছে, তাই সম্ভবত এটি ভুল সংকেত ছিল।")
    elif kind == "sim_change":
        state = str(d.get("state") or "changed")
        carrier = str(d.get("carrier") or "").strip()
        number = str(d.get("number") or "").strip()
        st_en = {"removed": "the SIM was removed", "inserted": "a SIM was inserted"}.get(
            state, "the SIM card changed")
        st_bn = {"removed": "সিম খুলে ফেলা হয়েছে", "inserted": "নতুন সিম ঢোকানো হয়েছে"}.get(
            state, "সিম কার্ড বদলানো হয়েছে")
        car_en = ("New carrier: %s. " % carrier) if carrier else "New carrier: not readable. "
        car_bn = ("নতুন অপারেটর: %s। " % carrier) if carrier else "নতুন অপারেটর পড়া যায়নি। "
        num_en = ("Number reported by the SIM: %s. " % number) if number else (
            "Android does not let apps read the new phone number on most phones. ")
        num_bn = ("সিম থেকে পাওয়া নম্বর: %s। " % number) if number else (
            "বেশিরভাগ ফোনে অ্যান্ড্রয়েড অ্যাপকে নতুন নম্বর পড়তে দেয় না। ")
        te = "SIM change on %s's phone" % name
        tb = "%s-এর ফোনে সিম পরিবর্তন" % name
        be = "At %s %s. %s%sPlease check. %s" % (w, st_en, car_en, num_en, loc_en)
        bb = "%s সময়ে %s। %s%sএকবার খোঁজ নিন। %s" % (w, st_bn, car_bn, num_bn, loc_bn)
    elif kind == "offline":
        reason = str(d.get("reason") or "")
        r_en = {"airplane": "airplane mode was turned on",
                "no_network": "it lost all network connection"}.get(
            reason, "it lost its connection")
        r_bn = {"airplane": "এয়ারপ্লেন মোড চালু করা হয়েছে",
                "no_network": "সব নেটওয়ার্ক সংযোগ হারিয়েছে"}.get(
            reason, "সংযোগ হারিয়েছে")
        te = "%s's phone went offline" % name
        tb = "%s-এর ফোন অফলাইন হয়ে গেছে" % name
        be = ("At %s %s. No app can stop airplane mode or power-off; this is the "
              "last we heard. %s Please check." % (w, r_en, loc_en))
        bb = ("%s সময়ে %s। কোনো অ্যাপ এয়ারপ্লেন মোড বা ফোন বন্ধ করা আটকাতে পারে না; "
              "এটাই শেষ খবর। %s একবার খোঁজ নিন।" % (w, r_bn, loc_bn))
    elif kind == "low_battery":
        pct = battery if battery is not None else d.get("battery")
        p = ("%s%%" % pct) if pct is not None else "low"
        te = "%s's phone battery is low (%s)" % (name, p)
        tb = "%s-এর ফোনের চার্জ কম (%s)" % (name, p)
        be = "At %s the battery was %s. The phone may switch off soon. %s" % (w, p, loc_en)
        bb = "%s সময়ে চার্জ ছিল %s। ফোনটি শিগগির বন্ধ হয়ে যেতে পারে। %s" % (w, p, loc_bn)
    elif kind == "shutdown":
        te = "%s's phone is switching off" % name
        tb = "%s-এর ফোন বন্ধ হচ্ছে" % name
        be = ("At %s the phone started to power off. Assisto cannot block "
              "power-off. %s Please check." % (w, loc_en))
        bb = ("%s সময়ে ফোনটি বন্ধ হতে শুরু করেছে। Assisto ফোন বন্ধ করা আটকাতে পারে না। "
              "%s একবার খোঁজ নিন।" % (w, loc_bn))
    elif kind == "boot":
        te = "%s's phone restarted" % name
        tb = "%s-এর ফোন রিস্টার্ট হয়েছে" % name
        be = ("At %s the phone was restarted. If that was not expected, please "
              "check." % w)
        bb = "%s সময়ে ফোনটি রিস্টার্ট হয়েছে। এটা অপ্রত্যাশিত হলে একবার খোঁজ নিন।" % w
    elif kind in ("failed_unlock", "intruder_photo"):
        n = d.get("count")
        n_en = ("%s wrong" % n) if n else "several wrong"
        n_bn = ("%sবার ভুল" % n) if n else "কয়েকবার ভুল"
        photo = kind == "intruder_photo"
        te = "Wrong unlock attempts on %s's phone" % name
        tb = "%s-এর ফোনে ভুল আনলক চেষ্টা" % name
        be = ("At %s there were %s screen-unlock attempts. %s%s" % (
            w, n_en,
            "A front-camera photo was saved; open Assisto > My lost phone. "
            if photo else "", loc_en))
        bb = ("%s সময়ে %s স্ক্রিন আনলকের চেষ্টা হয়েছে। %s%s" % (
            w, n_bn, "সামনের ক্যামেরার একটি ছবি সংরক্ষিত হয়েছে; Assisto > আমার হারানো "
            "ফোন খুলে দেখুন। " if photo else "", loc_bn))
    elif kind == "test":
        te = "Test alert from your phone"
        tb = "আপনার ফোন থেকে পরীক্ষামূলক সতর্কবার্তা"
        be = "Protection is working: this test reached Assisto at %s. %s" % (
            _when(now), loc_en)
        bb = "সুরক্ষা কাজ করছে: এই পরীক্ষাটি %s সময়ে Assisto-তে পৌঁছেছে। %s" % (
            _when(now), loc_bn)
    else:
        te = "Please check on %s's phone" % name
        tb = "%s-এর ফোনটি একবার দেখে নিন" % name
        be = "Something happened on the phone at %s. %s" % (w, loc_en)
        bb = "%s সময়ে ফোনে কিছু ঘটেছে। %s" % (w, loc_bn)
    return te, late_en + be, tb, late_bn + bb


# --- antitheft2 (owner 27 Oct): honest last location on EVERY alert ----------
# A fix older than this (relative to the event) is shown as "last seen at".
STALE_FIX_S = 15 * 60


def pick_location(ev_lat, ev_lng, ev_acc, ev_fix_at, ev_at,
                  last_lat=None, last_lng=None, last_acc=None, last_fix_at=None,
                  caps=None):
    """The best location for an alert, newest first:
      1. the fix the phone attached to the event (fused / fresh / last-known);
      2. the server's last stored fix for the phone (heartbeats + events).
    Returns {lat, lng, acc, fix_at, source, missing}. With no fix at all,
    `missing` says why, from what the engine reported: "permission" (location
    permission off), "location_off" (location switched off) or "no_fix"."""
    if valid_latlng(ev_lat, ev_lng):
        return {"lat": ev_lat, "lng": ev_lng, "acc": ev_acc,
                "fix_at": ev_fix_at, "source": "event", "missing": None}
    if valid_latlng(last_lat, last_lng):
        return {"lat": last_lat, "lng": last_lng, "acc": last_acc,
                "fix_at": last_fix_at, "source": "last_known", "missing": None}
    c = caps if isinstance(caps, dict) else {}
    if c.get("locationPermission") is False:
        why = "permission"
    elif c.get("locationEnabled") is False:
        why = "location_off"
    else:
        why = "no_fix"
    return {"lat": None, "lng": None, "acc": None, "fix_at": None,
            "source": None, "missing": why}


def _acc_txt(acc):
    try:
        a = float(acc)
    except (TypeError, ValueError):
        return ""
    if a != a or a <= 0:
        return ""
    return "±%d m" % int(round(a))


def location_text(loc, ev_at):
    """(en, bn) location sentence for an alert. Never claims more than we
    know: accuracy and fix time are shown when known; an old fix is "last
    seen at <time>"; no fix says why."""
    loc = loc or {}
    m = _map(loc.get("lat"), loc.get("lng"))
    if not m:
        why = loc.get("missing") or "no_fix"
        if why == "permission":
            return ("Last location: not known (location permission is off on "
                    "this phone).",
                    "শেষ অবস্থান জানা নেই (এই ফোনে লোকেশনের অনুমতি বন্ধ)।")
        if why == "location_off":
            return ("Last location: not known (location is switched off on "
                    "this phone).",
                    "শেষ অবস্থান জানা নেই (এই ফোনে লোকেশন বন্ধ করা আছে)।")
        return ("Last location: not known (the phone has not got a location "
                "fix yet).",
                "শেষ অবস্থান জানা নেই (ফোনটি এখনো লোকেশন পায়নি)।")
    acc = _acc_txt(loc.get("acc"))
    fix_at = loc.get("fix_at")
    stale = False
    if fix_at is not None and ev_at is not None:
        try:
            stale = (ev_at - fix_at).total_seconds() > STALE_FIX_S
        except Exception:
            stale = False
    if fix_at is not None and stale:
        when = _when(fix_at)
        return ("Last seen at %s%s: %s" % (when, (", " + acc) if acc else "", m),
                "শেষ দেখা গেছে %s সময়ে%s: %s" % (when, (", " + acc) if acc else "", m))
    if fix_at is not None:
        when = _when(fix_at)
        return ("Location at %s%s: %s" % (when, (", " + acc) if acc else "", m),
                "অবস্থান (%s%s): %s" % (when, (", " + acc) if acc else "", m))
    return ("Last known location%s: %s" % ((" (" + acc + ")") if acc else "", m),
            "সর্বশেষ জানা অবস্থান%s: %s" % ((" (" + acc + ")") if acc else "", m))


# --- antitheft2: fewer false "grab" alerts + "Are you OK?" -----------------
# The owner's phone asks "Are you OK?" first; with no answer in this window
# the grab is escalated to the trusted contacts (server-side, so a thief who
# switches the phone off cannot stop it).
CONFIRM_WINDOW_S = 60
NIGHT_START_HOUR, NIGHT_END_HOUR = 23, 6
HOME_WIFI_MAX = 3
WIFI_SEEN_FRESH_MIN = 30


def is_night(hour):
    try:
        h = int(hour)
    except (TypeError, ValueError):
        return False
    return h >= NIGHT_START_HOUR or h < NIGHT_END_HOUR


def wifi_hash_ok(h):
    """A Wi-Fi network is only ever stored as a sha256 hex of its name."""
    return (isinstance(h, str) and len(h) == 64
            and all(c in "0123456789abcdef" for c in h))


def grab_suppression(data, ev_at, night_guard=False, home_wifi=None):
    """Why a detected grab is NOT a theft signal, or None (= alert). Pure.
      * "charging"         — the phone was on the charger;
      * "face_down_still"  — it lay face-down and still right before;
      * "home_wifi_night"  — night (23:00-06:00) on the owner's saved home
                             Wi-Fi, unless Night guard is ON.
    `data` is what the engine attached to the event (device local `hour`,
    `charging`, `face_down_still`, `wifi` hash)."""
    d = data if isinstance(data, dict) else {}
    if d.get("charging") is True:
        return "charging"
    if d.get("face_down_still") is True:
        return "face_down_still"
    hour = d.get("hour")
    if hour is None and ev_at is not None:
        try:
            hour = timezone.localtime(ev_at).hour
        except Exception:
            hour = None
    wifi = d.get("wifi")
    homes = home_wifi if isinstance(home_wifi, list) else []
    if (not night_guard and is_night(hour) and wifi_hash_ok(wifi)
            and wifi in homes):
        return "home_wifi_night"
    return None


def back_online_text(owner_name, lat, lng):
    name = owner_name or "Assisto user"
    m = _map(lat, lng)
    loc_en = ("Current location: %s" % m) if m else "Location not shared yet."
    loc_bn = ("বর্তমান অবস্থান: %s" % m) if m else "অবস্থান এখনো পাওয়া যায়নি।"
    return ("%s's phone is reporting again" % name,
            "The phone came back online and is sending check-ins again. %s" % loc_en,
            "%s-এর ফোন আবার তথ্য পাঠাচ্ছে" % name,
            "ফোনটি আবার অনলাইনে এসেছে এবং নিয়মিত তথ্য পাঠাচ্ছে। %s" % loc_bn)


def went_dark_text(owner_name, dark_since, lat, lng, battery, loc=None):
    name = owner_name or "Assisto user"
    w = _when(dark_since)
    if loc is None:
        loc = pick_location(lat, lng, None, None, dark_since)
    loc_en, loc_bn = location_text(loc, dark_since)
    bat_en = (" The battery was %s%% then, so it may simply have run out." % battery
              if battery is not None and battery <= 15 else "")
    bat_bn = (" তখন চার্জ ছিল %s%%, তাই হয়তো চার্জ শেষ হয়ে গেছে।" % battery
              if battery is not None and battery <= 15 else "")
    return ("%s's phone stopped checking in" % name,
            ("Assisto has not heard from the phone since %s. It may be switched "
             "off, in airplane mode, or out of signal.%s %s Please check." %
             (w, bat_en, loc_en)),
            "%s-এর ফোন থেকে আর তথ্য আসছে না" % name,
            ("%s সময়ের পর থেকে ফোনটি থেকে কোনো তথ্য আসেনি। এটি বন্ধ, এয়ারপ্লেন "
             "মোডে বা নেটওয়ার্কের বাইরে থাকতে পারে।%s %s একবার খোঁজ নিন।" %
             (w, bat_bn, loc_bn)))
