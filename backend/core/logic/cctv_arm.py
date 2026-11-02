"""cctvarm (owner CCTV order 3 Nov, audit package W5) — the camera guard
follows the family, the shop day and an SOS. Builds ON the existing pieces,
never instead of them:

  B13  auto-ARM when every consenting family member has left Home
  B14  auto-DISARM for privacy when someone is back: the cameras the owner
       marked "indoor" stop alerts and live view
  E3   no-movement check: by a set time (e.g. 10:00) no movement seen on a
       chosen camera -> the chosen family is told (never a medical claim)
  E8   shop closed (day-end done in Shop Box, or outside the shop hours) ->
       guard on, with a notice
  E9   SOS while the person is at Home -> the site's allowed viewers get
       "open home camera live" for 30 minutes (video only, never audio)

Where the state lives: ShopSite.away["arm"] (a JSON key next to the owner's
own away mode — no migration). The auto-armed state is read by
shop_views.away_now(), so every existing alert path (schedule, quiet hours,
high priority, "You are away" wording) behaves exactly as the manual away
mode does.

Location rules (privacy first):
  * a member's location is used ONLY after that member said yes (their own
    switch, off by default, withdrawable any time);
  * the phone sends only "how far from Home" (+ GPS accuracy) — never its
    coordinates; the Always-on protection heartbeat (already on the server,
    anti-theft) is the only other source, and only for consenting members;
  * only the derived home / away state + its time is kept, never a trail;
  * hysteresis: inside ENTER_M = home, beyond radius + EXIT_EXTRA_M = away,
    in between = the previous state — GPS jitter does not flap the guard;
  * a member last heard more than STALE_MIN ago is "unknown": nothing is
    armed or disarmed on a guess; after HOLD_MIN of unknown the automatic
    layer lets go and the owner's own schedule decides again.

Pure helpers first (unit-tested without a DB), then the small DB layer the
views, the minute job and the hooks call. Every DB entry point is
best-effort: a failure here can never break an alert, a live view, an SOS
or a day-end.
"""
import logging
import math
from datetime import datetime, timedelta

log = logging.getLogger("assisto.shop")

FLAG = "home_watchman"

RADIUS_DEFAULT_M = 150
RADIUS_BOUNDS_M = (80, 500)
EXIT_EXTRA_M = 150          # away only beyond radius + this (hysteresis band)
MAX_ACCURACY_M = 250        # a worse fix is ignored (neither home nor away)
STALE_MIN = 30              # a member not heard for this long = unknown
ARM_DWELL_MIN = 5           # everyone away this long before the guard arms
HOLD_MIN = 60               # unknown this long -> back to the schedule
SOS_LIVE_MIN = 30           # how long an SOS opens the home camera to family
SOS_HOME_EXTRA_M = 150      # SOS counts as "at home" within radius + this
LOG_MAX = 40
MAX_MEMBERS = 12
MAX_NOMOVE_PEOPLE = 5
NOMOVE_FROM_DEFAULT = "06:00"
NOMOVE_BY_DEFAULT = "10:00"

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(v):
    return str(v).translate(_BN)


# ====================================================================== pure
def iso(dt):
    return dt.isoformat() if dt is not None else None


def parse_iso(v):
    if not isinstance(v, str) or not v:
        return None
    try:
        d = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo is not None else None


def hm(v):
    """'HH:MM' -> minutes of the day, else None."""
    try:
        h, m = str(v).split(":")
        h, m = int(h), int(m)
    except (TypeError, ValueError):
        return None
    if 0 <= h <= 23 and 0 <= m <= 59:
        return h * 60 + m
    return None


def distance_m(lat1, lng1, lat2, lng2):
    """Great-circle distance in metres (haversine)."""
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def clamp_radius(v):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return RADIUS_DEFAULT_M
    lo, hi = RADIUS_BOUNDS_M
    return max(lo, min(hi, v))


def classify(dist_m, accuracy_m, prev, radius_m=RADIUS_DEFAULT_M):
    """One location reading -> 'home' | 'away' | prev (hysteresis).

    home: the reading is inside the radius. away: even the nearest point the
    accuracy allows is beyond radius + EXIT_EXTRA_M (we only say "away" when
    sure). Anything in between, or a fix worse than MAX_ACCURACY_M, keeps the
    previous state (which may itself be 'unknown')."""
    prev = prev if prev in ("home", "away") else "unknown"
    try:
        d = float(dist_m)
    except (TypeError, ValueError):
        return prev
    if d < 0 or math.isnan(d):
        return prev
    try:
        acc = float(accuracy_m) if accuracy_m is not None else 50.0
    except (TypeError, ValueError):
        acc = 50.0
    if math.isnan(acc) or acc < 0:
        acc = 50.0
    if acc > MAX_ACCURACY_M:
        return prev
    if d <= radius_m:
        return "home"
    if d - acc >= radius_m + EXIT_EXTRA_M:
        return "away"
    return prev


def member_state(m, now):
    """A consenting member's state right now: home | away | unknown."""
    if not isinstance(m, dict) or not m.get("consent"):
        return "unknown"
    at = parse_iso(m.get("at"))
    st = m.get("state")
    if at is None or st not in ("home", "away"):
        return "unknown"
    if (now - at).total_seconds() > STALE_MIN * 60:
        return "unknown"
    return st


def summarize(members, now):
    """(summary, home_uids) over the CONSENTING members.

    off           nobody consented
    someone_home  at least one fresh 'home' (a definite fact)
    all_away      every consenting member freshly 'away'
    unknown       otherwise (someone stale / never heard) — no guess"""
    members = members if isinstance(members, dict) else {}
    states = {uid: member_state(m, now) for uid, m in members.items()
              if isinstance(m, dict) and m.get("consent")}
    if not states:
        return "off", []
    home = sorted(uid for uid, s in states.items() if s == "home")
    if home:
        return "someone_home", home
    if all(s == "away" for s in states.values()):
        return "all_away", []
    return "unknown", []


def decide_family(state, summary, now, home_uids=(), privacy_on=False,
                  has_indoor=False):
    """The family layer's next state + the changes to log/notify.

    state keys: fam_armed, privacy, privacy_by, all_away_since,
    last_definite, summary. Returns (new_state, [event, ...]) where an event
    is {"what": ..., "uids": [...]}. Pure."""
    st = dict(state or {})
    ev = []
    was_armed = bool(st.get("fam_armed"))
    was_priv = bool(st.get("privacy"))
    st["summary"] = summary
    if summary == "off":
        if was_armed or was_priv:
            ev.append({"what": "family_off", "uids": []})
        st.update(fam_armed=False, privacy=False, privacy_by=None,
                  all_away_since=None, privacy_paused=False)
        return st, ev
    if summary == "all_away":
        st["last_definite"] = iso(now)
        st["privacy"], st["privacy_by"] = False, None
        st["privacy_paused"] = False      # the owner's pause lasts one stay
        since = parse_iso(st.get("all_away_since")) or now
        st["all_away_since"] = iso(since)
        if not was_armed and (now - since).total_seconds() >= ARM_DWELL_MIN * 60:
            st["fam_armed"] = True
            ev.append({"what": "armed_family", "uids": []})
        return st, ev
    if summary == "someone_home":
        st["last_definite"] = iso(now)
        st["all_away_since"] = None
        uids = list(home_uids or [])
        if was_armed:
            st["fam_armed"] = False
            ev.append({"what": "disarmed_return", "uids": uids[:1]})
        # the owner turned the indoor cameras back on for this stay
        want_priv = bool(privacy_on and has_indoor and not st.get("privacy_paused"))
        if want_priv and not was_priv:
            ev.append({"what": "privacy_on", "uids": uids[:1]})
        st["privacy"] = want_priv
        st["privacy_by"] = uids[0] if (want_priv and uids) else None
        return st, ev
    # unknown: never arm or disarm on a guess. Hold what we had; after
    # HOLD_MIN without a definite fact, let the owner's schedule decide.
    st["all_away_since"] = None
    if was_armed or was_priv:
        last = parse_iso(st.get("last_definite"))
        if last is None or (now - last).total_seconds() >= HOLD_MIN * 60:
            st.update(fam_armed=False, privacy=False, privacy_by=None)
            ev.append({"what": "unknown_fallback", "uids": []})
    return st, ev


def shop_closed(hours, closed_days, local_dt, eod_until=None, now=None):
    """Is the shop closed right now? True / False, or None when we cannot
    tell (no hours and no day-end today). A finished day-end counts until
    `eod_until`; a closed weekday counts all day; else the opening hours."""
    if eod_until is not None and now is not None and eod_until > now:
        return True
    if local_dt.weekday() in (closed_days or []):
        return True
    if not isinstance(hours, dict):
        return None
    o, c = hm(hours.get("open")), hm(hours.get("close"))
    if o is None or c is None:
        return None
    if o == c:
        return False                       # open all day
    lm = local_dt.hour * 60 + local_dt.minute
    if o < c:
        return not (o <= lm < c)
    return not (lm >= o or lm < c)


def next_open(hours, local_dt):
    """The next local opening time after local_dt (None without hours)."""
    o = hm((hours or {}).get("open")) if isinstance(hours, dict) else None
    if o is None:
        return None
    cand = local_dt.replace(hour=o // 60, minute=o % 60, second=0, microsecond=0)
    if cand <= local_dt:
        cand += timedelta(days=1)
    return cand


def nomove_due(cfg, seen_at, local_dt, offline):
    """The no-movement check for one camera, once a day.

    Returns None (nothing to do yet / already done today), 'moved' (movement
    was seen inside today's window — mark done quietly), 'no_movement' or
    'offline' (the camera was not reachable, so we honestly cannot tell)."""
    if not isinstance(cfg, dict) or not cfg.get("on"):
        return None
    f, b = hm(cfg.get("from")), hm(cfg.get("by"))
    if f is None or b is None or b <= f:
        return None
    today = local_dt.date().isoformat()
    if cfg.get("last_day") == today:
        return None
    lm = local_dt.hour * 60 + local_dt.minute
    start = local_dt.replace(hour=f // 60, minute=f % 60, second=0, microsecond=0)
    if seen_at is not None and seen_at >= start and lm >= f:
        return "moved"
    if lm < b:
        return None
    return "offline" if offline else "no_movement"


def normalize(raw):
    """The bounded config + state. Unknown keys are dropped."""
    a = raw if isinstance(raw, dict) else {}
    out = {
        "family_on": bool(a.get("family_on")),
        "radius_m": clamp_radius(a.get("radius_m", RADIUS_DEFAULT_M)),
        "privacy_on": bool(a.get("privacy_on", True)),
        "indoor": [int(x) for x in (a.get("indoor") or [])
                   if isinstance(x, int) and not isinstance(x, bool)][:32],
        "closed_on": bool(a.get("closed_on")),
        "sos_live": bool(a.get("sos_live")),
    }
    h = a.get("home") if isinstance(a.get("home"), dict) else {}
    try:
        out["home"] = {"lat": float(h["lat"]), "lng": float(h["lng"]),
                       "name": str(h.get("name") or "")[:80],
                       "place_id": h.get("place_id")}
    except (KeyError, TypeError, ValueError):
        out["home"] = None
    mem = a.get("members") if isinstance(a.get("members"), dict) else {}
    out["members"] = {str(k): dict(v) for k, v in list(mem.items())[:MAX_MEMBERS]
                      if isinstance(v, dict)}
    nm = a.get("nomove") if isinstance(a.get("nomove"), dict) else {}
    out["nomove"] = {str(k): dict(v) for k, v in nm.items() if isinstance(v, dict)}
    seen = a.get("seen") if isinstance(a.get("seen"), dict) else {}
    out["seen"] = {str(k): v for k, v in seen.items() if isinstance(v, str)}
    out["state"] = dict(a.get("state") or {}) if isinstance(a.get("state"), dict) else {}
    out["sos"] = dict(a.get("sos") or {}) if isinstance(a.get("sos"), dict) else {}
    out["log"] = [x for x in (a.get("log") or []) if isinstance(x, dict)][:LOG_MAX]
    return out


def auto_active(arm, now):
    """Is the automatic layer arming the site right now? (pure)"""
    if not isinstance(arm, dict):
        return False
    st = arm.get("state") if isinstance(arm.get("state"), dict) else {}
    if st.get("fam_armed") and arm.get("family_on"):
        return True
    if st.get("closed_armed") and arm.get("closed_on"):
        return True
    return False


def sos_active(arm, now):
    sos = arm.get("sos") if isinstance(arm, dict) and isinstance(arm.get("sos"), dict) else {}
    until = parse_iso(sos.get("until"))
    return until is not None and until > now


# ------------------------------------------------------------------ wording
def _who(names, lang):
    n = [x for x in (names or []) if x]
    if not n:
        return "একজন সদস্য" if lang == "bn" else "A family member"
    return n[0]


def event_text(what, lang, names=(), site_name=""):
    """(title, body) in plain words for one automatic change."""
    who = _who(names, lang)
    place = site_name or ("বাড়ি" if lang == "bn" else "Home")
    T = {
        "armed_family": (
            ("সবাই বাড়ির বাইরে — পাহারা চালু: %s" % place,
             "সম্মতি দেওয়া সবাই বাড়ি থেকে দূরে, তাই ক্যামেরার পাহারা নিজে চালু হয়েছে। "
             "কেউ ফিরলে নিজে বন্ধ হবে।"),
            ("Everyone is out — guard on: %s" % place,
             "Everyone who agreed is away from Home, so the camera guard turned "
             "itself on. It turns off when someone is back.")),
        "disarmed_return": (
            ("%s বাড়ি ফিরেছেন — পাহারা বন্ধ" % who,
             "অটো পাহারা বন্ধ হয়েছে। আপনার রাতের সময়সূচি আগের মতোই চলবে।"),
            ("%s is back home — guard off" % who,
             "The automatic guard turned off. Your night schedule still works "
             "as before.")),
        "privacy_on": (
            ("ঘরে কেউ আছেন — ভিতরের ক্যামেরা চুপ",
             "প্রাইভেসির জন্য ভিতরের ক্যামেরার সতর্কতা ও লাইভ দেখা বন্ধ, "
             "যতক্ষণ কেউ বাড়িতে আছেন।"),
            ("Someone is home — indoor cameras private",
             "For privacy, indoor camera alerts and live view are off while "
             "someone is at home.")),
        "unknown_fallback": (
            ("কে কোথায় জানা নেই — সময়সূচিতে ফিরল",
             "এক ঘণ্টা ধরে কারও অবস্থান জানা যায়নি। আন্দাজে কিছু করা হয়নি — "
             "এখন আপনার নিজের পাহারার সময়সূচি চলবে।"),
            ("Not known who is where — back to your schedule",
             "No one's location was known for an hour. Nothing was guessed — "
             "your own guard schedule decides now.")),
        "family_off": (
            ("পরিবারভিত্তিক অটো পাহারা বন্ধ",
             "এখন শুধু আপনার নিজের পাহারার সময়সূচি চলবে।"),
            ("Family auto-guard is off",
             "Only your own guard schedule works now.")),
        "armed_closed": (
            ("দোকান বন্ধ — পাহারা চালু: %s" % place,
             "দোকান বন্ধের সময় (বা দিনশেষ জমা) তাই সব ক্যামেরার পাহারা চালু। "
             "খোলার সময় নিজে বন্ধ হবে।"),
            ("Shop closed — guard on: %s" % place,
             "It is closing time (or the day-end was done), so every camera is "
             "on guard. It turns off at opening time.")),
        "open_again": (
            ("দোকান খোলার সময় — অটো পাহারা বন্ধ: %s" % place,
             "দোকানের সময় শুরু হয়েছে, বন্ধের পাহারা থামল।"),
            ("Opening time — closed-shop guard off: %s" % place,
             "Shop hours started, so the closed-shop guard stopped.")),
        "privacy_paused": (
            ("ভিতরের ক্যামেরার প্রাইভেসি এখন বন্ধ",
             "মালিক নিজে ভিতরের ক্যামেরা আবার চালু করেছেন।"),
            ("Indoor privacy paused",
             "The owner turned the indoor cameras back on.")),
    }
    bn, en = T.get(what, (("পাহারা বদলেছে", ""), ("Guard changed", "")))
    return bn if lang == "bn" else en


def nomove_text(lang, cam_name, by, kind):
    t = by or ""
    if lang == "bn":
        t = bn_digits(t)
        if kind == "offline":
            return ("%s ক্যামেরা বন্ধ/অফলাইন — নড়াচড়া জানা যায়নি" % cam_name,
                    "%s পর্যন্ত ক্যামেরাটি সংযুক্ত ছিল না, তাই আজ নড়াচড়া দেখা "
                    "হয়েছে কি না বলা যাচ্ছে না। একবার ফোন করে খোঁজ নিন।" % t)
        return ("%s-এ আজ %s পর্যন্ত নড়াচড়া দেখা যায়নি" % (cam_name, t),
                "একবার ফোন করে খোঁজ নিন। এটা শুধু ক্যামেরার নড়াচড়া দেখে — "
                "কোনো চিকিৎসা-যন্ত্র নয়, ভুলও হতে পারে।")
    if kind == "offline":
        return ("%s camera offline — movement unknown" % cam_name,
                "The camera was not connected until %s, so we cannot tell "
                "whether anyone moved today. Please call and check." % t)
    return ("No movement seen on %s by %s today" % (cam_name, t),
            "Please call and check. This only looks at camera movement — it "
            "is not a medical device and can be wrong.")


def sos_text(lang, who, site_name):
    if lang == "bn":
        return ("%s বাড়িতে SOS চাপলেন — ঘরের ক্যামেরা লাইভ দেখুন" % who,
                "%s-এর ক্যামেরা আপনি %s মিনিট লাইভ দেখতে পারবেন (শুধু ছবি, শব্দ "
                "নিজে চালু হয় না)। জরুরি হলে ৯৯৯-এ কল করুন।"
                % (site_name or "বাড়ি", bn_digits(SOS_LIVE_MIN)))
    return ("%s pressed SOS at home — open the home camera live" % who,
            "You can watch %s's cameras live for %d minutes (picture only, "
            "sound never starts by itself). In an emergency call 999."
            % (site_name or "Home", SOS_LIVE_MIN))


# ================================================================= DB layer
def _now():
    from django.utils import timezone
    return timezone.now()


def _local(now):
    from django.utils import timezone
    return timezone.localtime(now)


def flag_on(user):
    try:
        from .. import feature_flags as FF
        return FF.is_on(FLAG, user, False)
    except Exception:
        return True


def arm_of(site):
    away = site.away if isinstance(getattr(site, "away", None), dict) else {}
    return normalize(away.get("arm"))


def mutate(site, fn):
    """Lock the site row, fn(arm) edits the normalized arm dict in place,
    save it back. Returns the new arm. Keeps every other `away` key."""
    from django.db import transaction
    from ..models import ShopSite
    with transaction.atomic():
        s = ShopSite.objects.select_for_update().get(pk=site.pk)
        away = dict(s.away) if isinstance(s.away, dict) else {}
        arm = normalize(away.get("arm"))
        fn(arm)
        away["arm"] = arm
        ShopSite.objects.filter(pk=s.pk).update(away=away)
    site.away = away
    return arm


def add_log(arm, now, what, names=(), site_name=""):
    bn = event_text(what, "bn", names, site_name)
    en = event_text(what, "en", names, site_name)
    arm["log"] = ([{"at": iso(now), "what": what, "bn": bn[0], "en": en[0]}]
                  + list(arm.get("log") or []))[:LOG_MAX]


def _names(uids):
    from ..models import User
    out = []
    for u in User.objects.filter(pk__in=[int(x) for x in uids if str(x).isdigit()]):
        out.append(u.name or "")
    return out


def _notify_owner(site, what, names=(), data=None):
    """One plain-words notice of an automatic change to the OWNER only."""
    try:
        from .. import cctvx_views as CXV
        tb, bb = event_text(what, "bn", names, site.name)
        te, be = event_text(what, "en", names, site.name)
        CXV.notice(site.owner, site, "auto_" + what, tb, te, bb, be,
                   severity="info", data=dict({"route": "watchman"}, **(data or {})))
    except Exception:
        log.exception("cctvarm notice failed")


def auto_armed(site, now=None):
    """Seam for shop_views.away_now: the automatic layer arms the site."""
    try:
        return auto_active(arm_of(site), now or _now())
    except Exception:
        return False


def privacy_blocks(site, cam, now=None):
    """Seam for ingest + live view: an indoor camera while privacy is on
    (someone is home) and no SOS opened it."""
    if site is None or cam is None:
        return False
    try:
        arm = arm_of(site)
        if not arm.get("family_on") or not arm.get("privacy_on"):
            return False
        if cam.id not in arm.get("indoor", []):
            return False
        if not (arm.get("state") or {}).get("privacy"):
            return False
        return not sos_active(arm, now or _now())
    except Exception:
        return False


def note_motion(site, cam, now):
    """Seam for ingest: remember the first movement inside each day's
    no-movement window (at most a couple of writes per camera per day; only
    for cameras with the check on)."""
    if site is None or cam is None:
        return
    try:
        arm = arm_of(site)
        cfg = arm["nomove"].get(str(cam.id))
        if not cfg or not cfg.get("on"):
            return
        local = _local(now)
        f = hm(cfg.get("from")) or 0
        start = local.replace(hour=f // 60, minute=f % 60, second=0, microsecond=0)
        if local < start:
            return
        prev = parse_iso(arm["seen"].get(str(cam.id)))
        if prev is not None and prev >= start:
            return
        mutate(site, lambda a: a["seen"].__setitem__(str(cam.id), iso(now)))
    except Exception:
        log.exception("cctvarm note_motion failed")


def home_point(arm):
    h = arm.get("home") if isinstance(arm, dict) else None
    if isinstance(h, dict) and h.get("lat") is not None:
        return h["lat"], h["lng"]
    return None


def set_member_reading(arm, uid, dist, accuracy, at, src):
    m = arm["members"].get(str(uid))
    if not m or not m.get("consent"):
        return False
    prev = m.get("state") if member_state(m, at) != "unknown" else "unknown"
    st = classify(dist, accuracy, prev, arm["radius_m"])
    m["state"] = st if st in ("home", "away") else None
    m["at"] = iso(at) if st in ("home", "away") else m.get("at")
    m["src"] = src
    return True


def pull_heartbeats(site, arm, now):
    """Consenting members' Always-on protection heartbeats newer than what we
    know -> a reading (server-side distance; coordinates never stored here)."""
    hp = home_point(arm)
    if hp is None:
        return []
    from ..models import ProtectedPhone
    out = []
    for uid, m in arm["members"].items():
        if not m.get("consent"):
            continue
        known = parse_iso(m.get("at"))
        q = ProtectedPhone.objects.filter(owner_id=int(uid), last_heartbeat_at__isnull=False,
                                          last_lat__isnull=False)
        if known is not None:
            q = q.filter(last_heartbeat_at__gt=known)
        p = q.order_by("-last_heartbeat_at").first()
        if p is None or (now - p.last_heartbeat_at).total_seconds() > STALE_MIN * 60:
            continue
        out.append((uid, distance_m(hp[0], hp[1], p.last_lat, p.last_lng),
                    50.0, p.last_heartbeat_at))
    return out


def tick_site(site, now):
    """One site's automatic layer. Returns the events it produced."""
    arm0 = arm_of(site)
    if not (arm0["family_on"] or arm0["closed_on"] or arm0["nomove"] or arm0["sos"]):
        return []
    if not flag_on(site.owner):
        return []
    readings = pull_heartbeats(site, arm0, now) if arm0["family_on"] else []
    local = _local(now)
    events = []

    def apply(arm):
        del events[:]
        for uid, d, acc, at in readings:
            set_member_reading(arm, uid, d, acc, at, "hb")
        st = dict(arm.get("state") or {})
        # ---- family layer (B13/B14)
        if arm["family_on"]:
            summary, home = summarize(arm["members"], now)
        else:
            summary, home = "off", []
        st, evs = decide_family(st, summary, now, home, arm["privacy_on"],
                                bool(arm["indoor"]))
        events.extend(evs)
        # ---- shop closed layer (E8)
        if arm["closed_on"]:
            from . import cctv_extras as CX
            closed_days = CX.settings_of(site.guard if isinstance(site.guard, dict)
                                         else {}).get("closed_days", [])
            eod = parse_iso(st.get("eod_until"))
            c = shop_closed(site.hours, closed_days, local, eod, now)
            if c and not st.get("closed_armed"):
                st["closed_armed"] = True
                events.append({"what": "armed_closed", "uids": []})
            elif c is False and st.get("closed_armed"):
                st["closed_armed"] = False
                st["eod_until"] = None
                events.append({"what": "open_again", "uids": []})
        elif st.get("closed_armed"):
            st["closed_armed"] = False
        arm["state"] = st
        # ---- SOS grant expiry
        if arm["sos"] and not sos_active(arm, now):
            arm["sos"] = {}
        for e in events:
            add_log(arm, now, e["what"], _names(e["uids"]), site.name)

    import copy
    trial = copy.deepcopy(arm0)
    apply(trial)
    if trial != arm0:                     # write only when something changed
        mutate(site, apply)
    for e in events:
        _notify_owner(site, e["what"], _names(e["uids"]))
    events = list(events) + run_nomove(site, now)
    return events


def run_nomove(site, now):
    """E3: per camera, once a day."""
    from .. import shop_views as SV
    arm = arm_of(site)
    if not arm["nomove"]:
        return []
    local = _local(now)
    out = []
    for cam in site.cameras.filter(enabled=True):
        cfg = arm["nomove"].get(str(cam.id))
        kind = nomove_due(cfg, parse_iso(arm["seen"].get(str(cam.id))), local,
                          offline=not SV.is_online(cam.last_seen, now))
        if kind is None:
            continue
        today = local.date().isoformat()

        def mark(a, cid=str(cam.id)):
            if cid in a["nomove"]:
                a["nomove"][cid]["last_day"] = today
        mutate(site, mark)
        if kind == "moved":
            continue
        out.append({"what": "nomove_" + kind, "camera": cam.id})
        _send_nomove(site, cam, cfg, kind)
    return out


def _send_nomove(site, cam, cfg, kind):
    from .. import cctvx_views as CXV
    from ..models import User
    people = [site.owner]
    want = [int(x) for x in (cfg.get("people") or []) if str(x).isdigit()]
    allowed = allowed_people(site)
    for u in User.objects.filter(pk__in=want):
        if u.pk in allowed and u.pk != site.owner_id:
            people.append(u)
    name = cam.name or ("ক্যামেরা")
    tb, bb = nomove_text("bn", name, cfg.get("by"), kind)
    te, be = nomove_text("en", cam.name or "camera", cfg.get("by"), kind)
    for u in people:
        CXV.notice(u, site, "nomove", tb, te, bb, be, severity="high",
                   data={"route": "watchman", "camera_id": cam.id}, high=True)


def allowed_people(site):
    """uids that may be told / picked: the owner, the site's viewers and the
    owner's accepted My Circle people."""
    out = {site.owner_id}
    try:
        out |= set(site.viewers.values_list("user_id", flat=True))
    except Exception:
        pass
    try:
        from .. import family_alerts as FA
        out |= {u.pk for u, _m in FA.consenting_members(site.owner)}
    except Exception:
        pass
    return out


def tick(now=None, limit=500):
    """The minute job's part (called from shop_guard_tick). Never raises."""
    from ..models import ShopSite
    now = now or _now()
    out = {"sites": 0, "events": 0}
    try:
        qs = ShopSite.objects.filter(away__has_key="arm").select_related(
            "owner").order_by("id")[:limit]
        sites = list(qs)
    except Exception:
        log.exception("cctvarm tick query failed")
        return out
    for site in sites:
        out["sites"] += 1
        try:
            out["events"] += len(tick_site(site, now))
        except Exception:
            log.exception("cctvarm tick failed for site %s", site.pk)
    return out


def on_day_closed(site, now=None):
    """E8 seam (Shop Box day-end saved): guard on until the next opening
    time (or 12 h without shop hours). Returns the notice text pair, or None."""
    try:
        now = now or _now()
        arm = arm_of(site)
        if not arm["closed_on"] or not flag_on(site.owner):
            return None
        nxt = next_open(site.hours, _local(now))
        until = nxt if nxt is not None else now + timedelta(hours=12)
        was = bool((arm.get("state") or {}).get("closed_armed"))

        def apply(a):
            st = dict(a.get("state") or {})
            st["eod_until"] = iso(until)
            st["closed_armed"] = True
            a["state"] = st
            if not was:
                add_log(a, now, "armed_closed", (), site.name)
        mutate(site, apply)
        if not was:
            _notify_owner(site, "armed_closed")
        return (event_text("armed_closed", "bn", (), site.name)[0],
                event_text("armed_closed", "en", (), site.name)[0])
    except Exception:
        log.exception("cctvarm on_day_closed failed")
        return None


def _member_sites(user):
    """Sites where `user` is the owner or a consenting member."""
    from ..models import ShopSite
    out = []
    for s in ShopSite.objects.filter(away__has_key="arm").select_related("owner")[:500]:
        arm = arm_of(s)
        if s.owner_id == user.pk or (arm["members"].get(str(user.pk)) or {}).get("consent"):
            out.append((s, arm))
    return out


def on_sos(sender, lat=None, lng=None, now=None):
    """E9 seam (after family_alerts.sos): if the sender is at the Home of a
    site that allows it, its allowed viewers who also got the SOS may open
    the home cameras live for SOS_LIVE_MIN. Video only. Never raises."""
    try:
        now = now or _now()
        if sender is None:
            return 0
        from .. import family_alerts as FA
        from .. import cctvx_views as CXV
        from .. import push as P
        circle = {u.pk: u for u, _m in FA.consenting_members(sender)}
        sent = 0
        for site, arm in _member_sites(sender):
            if not arm["sos_live"] or not flag_on(site.owner):
                continue
            at_home = False
            hp = home_point(arm)
            if lat is not None and lng is not None and hp is not None:
                try:
                    at_home = distance_m(hp[0], hp[1], float(lat), float(lng)) <= \
                        arm["radius_m"] + SOS_HOME_EXTRA_M
                except (TypeError, ValueError):
                    at_home = False
            if not at_home:
                at_home = member_state(arm["members"].get(str(sender.pk)), now) == "home"
            if not at_home:
                continue
            people = [site.owner] + [v.user for v in site.viewers.select_related("user")]
            viewers = [u for u in people if u.pk != sender.pk and u.pk in circle]
            if not viewers:
                continue
            until = now + timedelta(minutes=SOS_LIVE_MIN)

            def apply(a, vids=[u.pk for u in viewers]):
                a["sos"] = {"until": iso(until), "by": sender.pk, "viewers": vids,
                            "at": iso(now)}
            mutate(site, apply)
            for u in viewers:
                who = P.seen_name(u, sender) or (sender.name or "")
                tb, bb = sos_text("bn", who, site.name)
                te, be = sos_text("en", who, site.name)
                CXV.notice(u, site, "sos_live", tb, te, bb, be, severity="high",
                           data={"route": "watchman/sos_live", "site_id": site.id},
                           high=True)
                sent += 1
        return sent
    except Exception:
        log.exception("cctvarm on_sos failed")
        return 0


def sos_camera(user, cam_id, now=None):
    """A camera this NON-owner may open live because of an active SOS grant."""
    try:
        from ..models import ShopCamera
        cam = ShopCamera.objects.filter(pk=int(cam_id)).select_related("site").first()
    except (TypeError, ValueError):
        return None
    if cam is None:
        return None
    arm = arm_of(cam.site)
    if sos_active(arm, now or _now()) and user.pk in (arm["sos"].get("viewers") or []):
        return cam
    return None


def sos_grants(user, now=None):
    """Active SOS live grants for `user`: [(site, arm)]."""
    from ..models import ShopSite
    now = now or _now()
    out = []
    for s in ShopSite.objects.filter(away__has_key="arm").select_related("owner")[:500]:
        arm = arm_of(s)
        if sos_active(arm, now) and user.pk in (arm["sos"].get("viewers") or []):
            out.append((s, arm))
    return out
