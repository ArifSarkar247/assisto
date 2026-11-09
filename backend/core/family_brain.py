"""fcbrain — Family Care v3 BRAIN 2-7 (owner order 9 Nov 10:50).

Assisto watches the family quietly, speaks only when needed and never gives
false comfort. This module is the SERVER half of:

  2  AUTO ARRIVE / LEAVE — the phone itself decides "inside Home / School"
     with on-phone geofences (FamilyWatchService.kt + fc_geofence.dart, the
     same rule as the old Safe-Journey/School arrival radius). The server
     only receives the EVENT ("arrived Home 8:05", no coordinates) and tells
     the family through core.family_alerts (consent, idempotency, quiet
     hours, audit). Zero Google cost: no Maps / Places / Geocoding call.
  3  15 % BATTERY — the phone shares its last location ONCE per discharge
     (re-armed when it charges or climbs back over 30 %).
  4  NIGHT NEWS — one short card per family member per night (default 21:30,
     changeable, can be off), written by the Normal model from STRUCTURED
     facts only (never chat text, never coordinates), FREE (ai free-list
     "family.night_news"), with a template when AI is down. Each member
     chooses what about THEM goes in.
  5  TRUST — every member sees who can see them (+ a monthly in-app
     reminder); pause sharing 1 / 2 / 8 h shows "Paused" (never a fake
     location; SOS is a different path and still works); anyone can leave
     a family any time; nothing here is reachable from an admin page — the
     only reader is member_brain_state(viewer, member), which needs the
     viewer to share a family with the member.
  6  PROBASHI — both clocks; Care Call times in the receiver's time zone
     (core.carecall uses receiver_tz()).
  7  NOTIFICATION BUDGET — core.notif_budget (night news holds the reserved
     slot; arrival + battery are safety).

ASK BAR — ask(): the same offline parser as the phone (fc_ask_parser.dart),
answering from family status; the AI (free-listed "family.ask", Normal
model) only when the parser cannot.

Storage: the generic PaCollectionItem store (no migration), collection
"fc_brain", one row per user. Never raises into a view.
"""
import hashlib
import json
import logging
import re
from datetime import datetime, timedelta, timezone as dt_timezone
from zoneinfo import ZoneInfo

from django.db import transaction
from django.utils import timezone

log = logging.getLogger(__name__)

COLLECTION = "fc_brain"
DHAKA = ZoneInfo("Asia/Dhaka")
PAUSE_HOURS = (1, 2, 8)
DEFAULT_INTERVAL_S = 3 * 3600
WATCH_INTERVAL_S = 3600          # FamilyWatchService heartbeat promise (30 min + slack)
LOW_BATTERY = 15
REARM_BATTERY = 30
NIGHT_DEFAULT = "21:30"
NIGHT_WINDOW_MIN = 180           # a missed tick still sends within 3 h, never later
NIGHT_ITEMS = ("place", "arrivals", "battery", "carecall", "tasks")
EVENT_KINDS = ("arrive", "leave", "battery_low", "heartbeat")
PLACE_KINDS = ("home", "school", "office", "place")
NETS = ("none", "wifi", "cell", "")
MAX_TIMELINE = 60
MAX_SEEN_IDS = 80
MAX_LATENCY = 200
REMINDER_DAYS = 30
LOC_TTL_H = 24                   # a 15 % last location is shown for one day

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_num(v):
    return str(v).translate(_BN)


def _now(now=None):
    return now or timezone.now()


def _iso(dt):
    return dt.astimezone(dt_timezone.utc).isoformat().replace("+00:00", "Z") if dt else None


def _parse(v):
    if not v:
        return None
    try:
        s = str(v).strip().replace("Z", "+00:00")
        d = datetime.fromisoformat(s)
        return d if d.tzinfo else d.replace(tzinfo=dt_timezone.utc)
    except (TypeError, ValueError):
        return None


def _int(v, lo=None, hi=None):
    try:
        i = int(v)
    except (TypeError, ValueError):
        return None
    if (lo is not None and i < lo) or (hi is not None and i > hi):
        return None
    return i


def _coord(v, lim):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f, 6) if -lim <= f <= lim else None


def _hhmm(s):
    m = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", str(s or "").strip())
    return "%02d:%s" % (int(m.group(1)), m.group(2)) if m else None


# ------------------------------------------------------------------ store
def _row(user, lock=False, create=True):
    from .models import PaCollectionItem
    qs = PaCollectionItem.objects.filter(user=user, collection=COLLECTION)
    if lock:
        qs = qs.select_for_update()
    row = qs.order_by("id").first()
    if row is None and create:
        row = PaCollectionItem.objects.create(user=user, collection=COLLECTION, data={})
    return row


def state_of(user):
    try:
        row = _row(user, create=False)
        return dict(row.data or {}) if row else {}
    except Exception:  # noqa: BLE001
        return {}


def _save(row, d):
    row.data = d
    row.save(update_fields=["data", "updated_at"])


def prefs_of(st):
    """Normalized prefs (defaults filled)."""
    p = dict(st.get("prefs") or {})
    night = dict(p.get("night") or {})
    items = [i for i in (night.get("items") if isinstance(night.get("items"), list)
                         else list(NIGHT_ITEMS)) if i in NIGHT_ITEMS]
    return {
        # auto arrive: OFF until the member turns it on on their OWN phone
        "auto_arrive": bool(p.get("auto_arrive")),
        "auto_arrive_at": p.get("auto_arrive_at") or None,
        "auto_arrive_by": p.get("auto_arrive_by") or None,   # self / guardian id
        "leave_news": bool(p.get("leave_news")),
        "night": {"on": night.get("on", True) is not False,
                  "time": _hhmm(night.get("time")) or NIGHT_DEFAULT,
                  "voice": bool(night.get("voice")),
                  "items": items},
    }


# --------------------------------------------------------------- family
def _v3():
    try:
        from . import family_v3
        return family_v3
    except Exception:  # noqa: BLE001 — fcscreen not merged yet
        return None


def peer_ids(user):
    """Everyone who may see `user`'s family status: active co-members of any
    of their families (fcscreen); before fcscreen lands, the consenting
    family circle (accepted, unblocked, both sides)."""
    v3 = _v3()
    if v3 is not None:
        try:
            ids = list(v3.co_member_ids(user))
            if ids:
                return ids
        except Exception:  # noqa: BLE001
            pass
    try:
        from . import family_alerts as FA
        return [u.pk for u, _m in FA.consenting_members(user)]
    except Exception:  # noqa: BLE001
        return []


def can_view(viewer, member):
    """The ONLY read check. Staff / admin status grants nothing."""
    if viewer is None or member is None:
        return False
    if viewer.pk == member.pk:
        return True
    v3 = _v3()
    if v3 is not None:
        try:
            if v3.shares_family(viewer, member):
                return True
        except Exception:  # noqa: BLE001
            pass
    return viewer.pk in peer_ids(member)


# --------------------------------------------------------------- time zone
def tz_offset_min(user):
    st = state_of(user)
    return _int(st.get("tz_offset_min"), -720, 840)


def receiver_tz(user):
    """Probashi: the clock a person lives by — their family membership's
    abroad zone (fcscreen), else the zone their phone reports, else Dhaka."""
    v3 = _v3()
    if v3 is not None:
        try:
            for f in v3.families_of(user):
                m = v3.membership(user, f.pk)
                tzname = getattr(m, "abroad_tz", "") if m else ""
                if tzname:
                    return ZoneInfo(tzname)
        except Exception:  # noqa: BLE001
            pass
    st = state_of(user)
    name = str(st.get("tz") or "")
    if name and "/" in name:
        try:
            return ZoneInfo(name)
        except Exception:  # noqa: BLE001
            pass
    off = _int(st.get("tz_offset_min"), -720, 840)
    if off is not None and off != 360:
        return dt_timezone(timedelta(minutes=off))
    return DHAKA


def local(user, now=None):
    return _now(now).astimezone(receiver_tz(user))


def _clock(dt, lang):
    h, m = dt.hour, dt.minute
    h12 = h % 12 or 12
    if lang == "en":
        return "%d:%02d %s" % (h12, m, "AM" if h < 12 else "PM")
    part = ("রাত" if h < 4 else "ভোর" if h < 6 else "সকাল" if h < 12 else
            "দুপুর" if h < 15 else "বিকাল" if h < 18 else "সন্ধ্যা" if h < 20 else "রাত")
    return "%s %s" % (part, bn_num("%d:%02d" % (h12, m)))


def clocks(viewer, member, now=None):
    """Probashi: both clocks — the viewer's and the member's."""
    now = _now(now)
    a, b = now.astimezone(receiver_tz(viewer)), now.astimezone(receiver_tz(member))
    diff = int((b.utcoffset() - a.utcoffset()).total_seconds() // 60)
    return {"mine": a.strftime("%H:%M"), "theirs": b.strftime("%H:%M"),
            "diff_min": diff, "different": diff != 0}


# ------------------------------------------------------------------ texts
PLACE_BN = {"home": "বাড়ি", "school": "স্কুল", "office": "অফিস"}
PLACE_EN = {"home": "Home", "school": "School", "office": "Office"}


def place_name(kind, label, lang):
    lab = str(label or "").strip()[:40]
    if lab:
        return lab
    return (PLACE_EN if lang == "en" else PLACE_BN).get(kind, "Saved place" if lang == "en" else "সেভ করা জায়গা")


def _event_texts(kind, place_kind, place_label, at_local):
    def f(name, lang):
        pl = place_name(place_kind, place_label, lang)
        t = _clock(at_local, lang)
        if kind == "auto_arrived":
            if lang == "en":
                return ("%s reached %s" % (name, pl), "Arrived %s (automatic)." % t)
            return ("%s %s পৌঁছেছেন" % (name, pl), "%s-এ পৌঁছেছেন (স্বয়ংক্রিয়)।" % t)
        if kind == "auto_left":
            if lang == "en":
                return ("%s left %s" % (name, pl), "Left at %s (automatic)." % t)
            return ("%s %s থেকে বের হয়েছেন" % (name, pl), "%s-এ বের হয়েছেন (স্বয়ংক্রিয়)।" % t)
        return ("", "")
    return f


def _battery_texts(pct, has_loc):
    def f(name, lang):
        if lang == "en":
            return ("%s's phone is at %d%%" % (name, pct),
                    "Their last location is shared once, in case the phone turns off."
                    if has_loc else "The phone may turn off soon. Location was not available.")
        return ("%s-এর ফোনে চার্জ %s%%" % (name, bn_num(pct)),
                "ফোন বন্ধ হয়ে যেতে পারে, তাই শেষ অবস্থান একবার জানানো হলো।"
                if has_loc else "ফোন শিগগির বন্ধ হতে পারে। অবস্থান পাওয়া যায়নি।")
    return f


# ------------------------------------------------------------------- ping
def _clean_event(e, now):
    if not isinstance(e, dict):
        return None
    kind = str(e.get("kind") or "")
    if kind not in EVENT_KINDS:
        return None
    eid = re.sub(r"[^A-Za-z0-9_.:-]", "", str(e.get("id") or ""))[:48]
    if not eid:
        return None
    at = _parse(e.get("at")) or now
    if at > now + timedelta(minutes=5):
        at = now                       # a wrong phone clock never lands in the future
    crossed = _parse(e.get("crossed_at"))
    pk = str(e.get("place_kind") or "place")
    return {
        "id": eid, "kind": kind, "at": at,
        "crossed_at": crossed if crossed and crossed <= at else None,
        "place_id": _int(e.get("place_id"), 0),
        "place_kind": pk if pk in PLACE_KINDS else "place",
        "place_label": str(e.get("place_label") or "").strip()[:40],
        "lat": _coord(e.get("lat"), 90), "lng": _coord(e.get("lng"), 180),
        "acc": _int(e.get("acc"), 0, 50000),
    }


def ping(user, data, now=None):
    """POST family/brain/ping — the phone's report. Body:
      {battery, charging, net, bg_restricted, interval_s, tz_offset_min, tz,
       watch_on, events:[{id, kind arrive|leave|battery_low|heartbeat, at,
       crossed_at?, place_id?, place_kind?, place_label?, lat?, lng?, acc?}]}
    Returns {ok, paused, alerts, accepted, duplicate}. Coordinates are kept
    ONLY for the 15 % battery share; arrive/leave carry the place name."""
    now = _now(now)
    d = data if isinstance(data, dict) else {}
    out = {"ok": True, "paused": False, "alerts": 0, "accepted": 0, "duplicate": 0}
    fan = []                              # alerts sent after the row lock is released
    with transaction.atomic():
        row = _row(user, lock=True)
        st = dict(row.data or {})
        st["last_seen"] = _iso(now)
        b = _int(d.get("battery"), 0, 100)
        if b is not None:
            st["battery"] = b
        if "charging" in d:
            st["charging"] = d.get("charging") is True
        net = str(d.get("net") or "")
        if net in NETS and "net" in d:
            st["net"] = net
        if "bg_restricted" in d:
            st["bg_restricted"] = d.get("bg_restricted") is True
        if "watch_on" in d:
            st["watch_on"] = d.get("watch_on") is True
        iv = _int(d.get("interval_s"), 900, 86400)
        st["interval_s"] = iv or (WATCH_INTERVAL_S if st.get("watch_on") else DEFAULT_INTERVAL_S)
        off = _int(d.get("tz_offset_min"), -720, 840)
        if off is not None:
            st["tz_offset_min"] = off
        tzname = str(d.get("tz") or "")[:48]
        if tzname:
            st["tz"] = tzname
        paused = _paused_until(st, now)
        out["paused"] = paused is not None
        prefs = prefs_of(st)
        seen = list(st.get("seen_ids") or [])
        tl = list(st.get("timeline") or [])
        lat_list = list(st.get("latency") or [])
        events = d.get("events") if isinstance(d.get("events"), list) else []
        for raw in events[:20]:
            e = _clean_event(raw, now)
            if e is None:
                continue
            if e["id"] in seen:
                out["duplicate"] += 1
                continue
            seen.append(e["id"])
            out["accepted"] += 1
            if paused is not None:
                continue          # PAUSED: nothing is recorded or shared
            if e["kind"] in ("arrive", "leave"):
                ak = "auto_arrived" if e["kind"] == "arrive" else "auto_left"
                st["place"] = ({"kind": e["place_kind"], "label": e["place_label"],
                                "at": _iso(e["at"])} if e["kind"] == "arrive" else None)
                st["last_event"] = {"kind": e["kind"], "place_kind": e["place_kind"],
                                    "place_label": e["place_label"], "at": _iso(e["at"])}
                tl.append({"at": _iso(e["at"]), "kind": e["kind"],
                           "place_kind": e["place_kind"], "place_label": e["place_label"]})
                if e["kind"] == "arrive" and e["crossed_at"] is not None:
                    lat_list.append(int((now - e["crossed_at"]).total_seconds()))
                if prefs["auto_arrive"] and (e["kind"] == "arrive" or prefs["leave_news"]):
                    fan.append(("event", ak, e))
            elif e["kind"] == "battery_low":
                if e["lat"] is not None and e["lng"] is not None:
                    st["_pending_loc"] = {"lat": e["lat"], "lng": e["lng"],
                                          "acc": e["acc"], "at": _iso(e["at"])}
        # 15 %: once per discharge, re-armed by charging or > 30 %
        bat, chg = st.get("battery"), st.get("charging") is True
        if chg or (bat is not None and bat >= REARM_BATTERY):
            st["low_batt_armed"] = True
        pend = st.pop("_pending_loc", None)
        if (paused is None and bat is not None and bat <= LOW_BATTERY and not chg
                and st.get("low_batt_armed", True)):
            st["low_batt_armed"] = False
            st["low_batt"] = {"pct": bat, "at": _iso(now), **(pend or {})}
            tl.append({"at": _iso(now), "kind": "battery_low", "pct": bat})
            fan.append(("battery", bat, pend))
        st["seen_ids"] = seen[-MAX_SEEN_IDS:]
        st["timeline"] = tl[-MAX_TIMELINE:]
        st["latency"] = lat_list[-MAX_LATENCY:]
        _save(row, st)
    peers = peer_ids(user)
    if peers:
        from . import family_alerts as FA
        from .models import User
        rec = list(User.objects.filter(pk__in=peers))
        for item in fan:
            try:
                if item[0] == "event":
                    _, ak, e = item
                    st_ = FA.alert(user, ak, "fcb:%s" % e["id"], recipients=rec,
                                   payload={"place_kind": e["place_kind"],
                                            "event": ak, "member_id": user.pk},
                                   texts=_event_texts(ak, e["place_kind"], e["place_label"],
                                                      e["at"].astimezone(receiver_tz(user))),
                                   now=now)
                else:
                    _, pct, loc = item
                    st_ = FA.alert(user, "battery_low_loc",
                                   "fcb:batt:%s" % now.strftime("%Y%m%d%H%M"),
                                   recipients=rec,
                                   payload={"event": "battery_low_loc", "member_id": user.pk,
                                            "battery": pct},
                                   texts=_battery_texts(pct, bool(loc)),
                                   lat=(loc or {}).get("lat"), lng=(loc or {}).get("lng"),
                                   now=now)
                out["alerts"] += st_.get("recipients", 0)
            except Exception as ex:  # noqa: BLE001
                log.warning("family_brain: fan-out failed %s", type(ex).__name__)
    return out


# ------------------------------------------------------------------ pause
def _paused_until(st, now):
    p = _parse(st.get("paused_until"))
    return p if p and p > now else None


def pause(user, hours, now=None):
    """Pause sharing 1 / 2 / 8 h. Returns the end (ISO) or None for a bad value."""
    now = _now(now)
    h = _int(hours)
    if h not in PAUSE_HOURS:
        return None
    with transaction.atomic():
        row = _row(user, lock=True)
        st = dict(row.data or {})
        until = now + timedelta(hours=h)
        st["paused_until"] = _iso(until)
        st["place"] = None            # never a stale "Home" under a pause
        tl = list(st.get("timeline") or [])
        tl.append({"at": _iso(now), "kind": "paused", "hours": h})
        st["timeline"] = tl[-MAX_TIMELINE:]
        _save(row, st)
    return _iso(until)


def resume(user, now=None):
    now = _now(now)
    with transaction.atomic():
        row = _row(user, lock=True)
        st = dict(row.data or {})
        was = _paused_until(st, now) is not None
        st["paused_until"] = None
        if was:
            tl = list(st.get("timeline") or [])
            tl.append({"at": _iso(now), "kind": "resumed"})
            st["timeline"] = tl[-MAX_TIMELINE:]
        _save(row, st)
    return was


# ------------------------------------------------------------------ prefs
def set_prefs(actor, member, data, now=None):
    """Update `member`'s prefs. Adults: only on their OWN phone (actor ==
    member). A child: their guardian may switch auto-arrive / leave news.
    Night news "what about me" is always the member's own choice.
    Returns (ok, error_code)."""
    now = _now(now)
    d = data if isinstance(data, dict) else {}
    self_ = actor.pk == member.pk
    guardian = False
    if not self_:
        try:
            from . import guardian_links
            guardian = guardian_links.is_guardian(actor, member) and _is_child(member)
        except Exception:  # noqa: BLE001
            guardian = False
        if not guardian:
            return False, "consent_own_phone"
        if set(d) - {"auto_arrive", "leave_news"}:
            return False, "consent_own_phone"
    with transaction.atomic():
        row = _row(member, lock=True)
        st = dict(row.data or {})
        p = dict(st.get("prefs") or {})
        if "auto_arrive" in d:
            on = d.get("auto_arrive") is True
            if on and not p.get("auto_arrive"):
                p["auto_arrive_at"] = _iso(now)
                p["auto_arrive_by"] = "self" if self_ else actor.pk
            p["auto_arrive"] = on
        if "leave_news" in d:
            p["leave_news"] = d.get("leave_news") is True
        if self_ and isinstance(d.get("night"), dict):
            n = dict(p.get("night") or {})
            nd = d["night"]
            if "on" in nd:
                n["on"] = nd.get("on") is True
            if "time" in nd:
                t = _hhmm(nd.get("time"))
                if not t:
                    return False, "bad_time"
                n["time"] = t
            if "voice" in nd:
                n["voice"] = nd.get("voice") is True
            if isinstance(nd.get("items"), list):
                n["items"] = [i for i in nd["items"] if i in NIGHT_ITEMS]
            p["night"] = n
        st["prefs"] = p
        _save(row, st)
    return True, ""


def _is_child(member):
    v3 = _v3()
    if v3 is None:
        return True        # guardian_links already proves the guardian relation
    try:
        return any(v3.role_of(member, f.pk) == "child" for f in v3.families_of(member))
    except Exception:  # noqa: BLE001
        return False


# -------------------------------------------------------------- read side
def member_brain_state(viewer, member, now=None):
    """fcscreen's card data for `member` as `viewer` sees it, or None when
    the viewer may not see them. While paused: only paused_until +
    last_seen (alive) — no place, battery, events or location."""
    try:
        if not can_view(viewer, member):
            return None
        now = _now(now)
        st = state_of(member)
        prefs = prefs_of(st)
        paused = _paused_until(st, now)
        base = {"last_seen": st.get("last_seen"),
                "interval_s": st.get("interval_s") or DEFAULT_INTERVAL_S,
                "paused_until": _iso(paused) if paused else None,
                "auto_arrive": prefs["auto_arrive"],
                "watch_on": bool(st.get("watch_on"))}
        if paused:
            return base
        place = st.get("place") or None
        lb = st.get("low_batt") or {}
        loc = None
        lb_at = _parse(lb.get("at"))
        if lb.get("lat") is not None and lb_at and now - lb_at < timedelta(hours=LOC_TTL_H):
            loc = {"lat": lb["lat"], "lng": lb["lng"], "acc": lb.get("acc"),
                   "at": lb.get("at"), "why": "battery_low"}
        base.update({
            "battery": st.get("battery"), "charging": bool(st.get("charging")),
            "net": st.get("net") or "", "bg_restricted": bool(st.get("bg_restricted")),
            "place_kind": (place or {}).get("kind"),
            "place_label": ((place or {}).get("label") or None) if place else None,
            "place_since": (place or {}).get("at"),
            "last_event": st.get("last_event"),
            "last_location": loc,
        })
        return base
    except Exception as e:  # noqa: BLE001
        log.warning("family_brain: state failed %s", type(e).__name__)
        return None


def member_timeline(viewer, member, day=None, lang="bn", now=None):
    """[{at, kind, text}] for `member`'s local `day` (date; default today)."""
    if not can_view(viewer, member):
        return []
    now = _now(now)
    tz = receiver_tz(member)
    day = day or now.astimezone(tz).date()
    out = []
    for t in state_of(member).get("timeline") or []:
        at = _parse(t.get("at"))
        if at is None or at.astimezone(tz).date() != day:
            continue
        loc = at.astimezone(tz)
        k = t.get("kind")
        pl = place_name(t.get("place_kind"), t.get("place_label"), lang)
        if k == "arrive":
            text = ("Arrived %s" % pl) if lang == "en" else ("%s পৌঁছেছেন" % pl)
        elif k == "leave":
            text = ("Left %s" % pl) if lang == "en" else ("%s থেকে বের হয়েছেন" % pl)
        elif k == "battery_low":
            pct = t.get("pct")
            text = ("Battery %s%%" % pct) if lang == "en" else ("চার্জ %s%%" % bn_num(pct))
        elif k == "paused":
            text = "Paused sharing" if lang == "en" else "শেয়ারিং বিরতি"
        elif k == "resumed":
            text = "Sharing on again" if lang == "en" else "শেয়ারিং আবার চালু"
        else:
            continue
        out.append({"at": _iso(at), "kind": k, "time": _clock(loc, lang), "text": text})
    return out


def visibility(user, now=None):
    """Who can see me + what they see; reminder_due monthly."""
    now = _now(now)
    st = state_of(user)
    prefs = prefs_of(st)
    from .models import User
    v3 = _v3()
    fam_names = {}
    if v3 is not None:
        try:
            for f in v3.families_of(user):
                for uid in v3.member_ids(f.pk):
                    fam_names.setdefault(uid, []).append(f.name)
        except Exception:  # noqa: BLE001
            fam_names = {}
    from . import push
    people = []
    for u in User.objects.filter(pk__in=peer_ids(user)):
        people.append({"user_id": u.pk, "name": push.seen_name(user, u),
                       "families": fam_names.get(u.pk, [])})
    people.sort(key=lambda r: r["name"].lower())
    last = _parse(st.get("vis_seen_at"))
    return {
        "people": people,
        "sees": {"status": True, "battery": True, "place": True,
                 "arrivals": prefs["auto_arrive"],
                 "night_items": prefs["night"]["items"]},
        "paused_until": _iso(_paused_until(st, now)) if _paused_until(st, now) else None,
        "reminder_due": bool(people) and (last is None or now - last > timedelta(days=REMINDER_DAYS)),
        "admin_sees_location": False,
    }


def mark_visibility_seen(user, now=None):
    now = _now(now)
    with transaction.atomic():
        row = _row(user, lock=True)
        st = dict(row.data or {})
        st["vis_seen_at"] = _iso(now)
        _save(row, st)


def leave(user, family_id):
    v3 = _v3()
    if v3 is None:
        return False
    try:
        return bool(v3.leave(user, int(family_id)))
    except Exception:  # noqa: BLE001
        return False


def latency_stats():
    """Arrival news latency (crossed the fence -> server got the event), over
    every member's last MAX_LATENCY arrivals: {n, p50_s, p95_s, within_2min_pct}."""
    from .models import PaCollectionItem
    xs = []
    for d in PaCollectionItem.objects.filter(collection=COLLECTION).values_list("data", flat=True):
        xs.extend(int(v) for v in (d or {}).get("latency") or [] if isinstance(v, (int, float)))
    xs = sorted(x for x in xs if x >= 0)
    if not xs:
        return {"n": 0, "p50_s": None, "p95_s": None, "within_2min_pct": None}
    pct = lambda q: xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]  # noqa: E731
    return {"n": len(xs), "p50_s": pct(0.5), "p95_s": pct(0.95),
            "within_2min_pct": round(100.0 * sum(1 for x in xs if x <= 120) / len(xs), 1)}


# ------------------------------------------------------------- night news
def night_news_pending(user, day):
    st = state_of(user)
    if not st or not prefs_of(st)["night"]["on"] or not peer_ids(user):
        return False
    return (st.get("night_last") or {}).get("day") != day


def night_facts(viewer, now=None, lang="bn"):
    """STRUCTURED facts about the viewer's family for tonight — only what
    each member chose to include, never coordinates, never chat text."""
    now = _now(now)
    from .models import User
    from . import push
    facts = []
    for u in User.objects.filter(pk__in=peer_ids(viewer)).order_by("pk"):
        st = state_of(u)
        items = prefs_of(st)["night"]["items"]
        b = member_brain_state(viewer, u, now) or {}
        f = {"name": push.seen_name(viewer, u)}
        if b.get("paused_until"):
            f["paused"] = True
            facts.append(f)
            continue
        if "place" in items and b.get("place_kind"):
            f["place"] = place_name(b.get("place_kind"), b.get("place_label"), lang)
        if "arrivals" in items:
            arr = [t for t in member_timeline(viewer, u, None, lang, now)
                   if t["kind"] in ("arrive", "leave")]
            if arr:
                f["moves"] = ["%s %s" % (t["time"], t["text"]) for t in arr[-3:]]
        if "battery" in items and b.get("battery") is not None:
            f["battery"] = b["battery"]
        if "carecall" in items:
            cc = _carecall_today(u, now)
            if cc:
                f["carecall"] = cc
        seen = _parse(b.get("last_seen"))
        if seen is None or now - seen > timedelta(seconds=int(b.get("interval_s") or DEFAULT_INTERVAL_S)):
            f["no_news"] = True
        facts.append(f)
    return facts


def _carecall_today(receiver, now):
    try:
        from .models import CareCallRing
        start = local(receiver, now).replace(hour=0, minute=0, second=0, microsecond=0)
        qs = CareCallRing.objects.filter(care_call__receiver=receiver, due_at__gte=start,
                                         due_at__lte=now)
        done = qs.filter(status="done").count()
        missed = qs.filter(status="missed").count()
        return {"done": done, "missed": missed} if (done or missed) else None
    except Exception:  # noqa: BLE001
        return None


def night_template(facts, lang):
    """The no-AI card: one short line per member, plain words."""
    en = lang == "en"
    if not facts:
        return ("No family members yet." if en else "পরিবারে এখনো কেউ নেই।")
    lines = []
    for f in facts[:6]:
        n = f["name"]
        if f.get("paused"):
            lines.append("%s paused sharing." % n if en else "%s শেয়ারিং বিরতিতে রেখেছেন।" % n)
            continue
        if f.get("no_news"):
            lines.append("No fresh news from %s." % n if en else "%s-এর কাছ থেকে নতুন খবর নেই।" % n)
            continue
        bits = []
        if f.get("place"):
            bits.append(("at %s" % f["place"]) if en else ("%s আছেন" % ASK.at_bn(f["place"])))
        if f.get("battery") is not None and f["battery"] <= LOW_BATTERY:
            bits.append(("battery %d%%" % f["battery"]) if en else ("চার্জ %s%%" % bn_num(f["battery"])))
        cc = f.get("carecall") or {}
        if cc.get("missed"):
            bits.append(("missed %d Care Call" % cc["missed"]) if en
                        else ("%sটি কেয়ার কল ধরেননি" % bn_num(cc["missed"])))
        elif cc.get("done"):
            bits.append("Care Call done" if en else "কেয়ার কল হয়েছে")
        if not bits:
            bits.append("all OK" if en else "সব ঠিক আছে")
        lines.append(("%s: %s." % (n, ", ".join(bits))) if en else ("%s: %s।" % (n, ", ".join(bits))))
    head = "Tonight: " if en else "আজ রাতের খবর — "
    return head + " ".join(lines)


NIGHT_TASK = (
    "You write ONE short evening family update card for a Bangladeshi family app. "
    "Use ONLY the JSON facts given; never invent places, times, numbers, health or "
    "feelings; never mention coordinates. Warm, calm, plain words, at most 3 short "
    "sentences, no greeting, no emoji. If someone has no_news say so honestly, never "
    "say they are fine. Language: {lang}.")


def night_text(facts, lang):
    """(text, source) — AI from structured facts, else the template."""
    tpl = night_template(facts, lang)
    if not facts:
        return tpl, "template"
    try:
        from . import ai
        task = NIGHT_TASK.format(lang="natural Bangla (Bangla digits)" if lang != "en" else "English")
        txt, _cost = ai.generate(task, data=json.dumps(facts, ensure_ascii=False),
                                 tier="cheap", max_tokens=220, feature="family.night_news",
                                 user=None, task_class="cheap", level="normal",
                                 digits="bn" if lang != "en" else None)
        txt = (txt or "").strip()
        if _night_ok(txt, facts):
            return txt[:600], "ai"
    except Exception as e:  # noqa: BLE001 — AI down / no key -> template
        log.info("family_brain: night AI fallback %s", type(e).__name__)
    return tpl, "template"


def _night_ok(txt, facts):
    """Guard against a made-up card: non-empty, short, every member named,
    no coordinates, and never "OK/ঠিক" for someone with no news."""
    if not txt or len(txt) > 600 or re.search(r"\d+\.\d{3,}", txt):
        return False
    for f in facts:
        if f["name"] and f["name"] not in txt:
            return False
    stale = [f["name"] for f in facts if f.get("no_news") or f.get("paused")]
    if stale and len(facts) == 1 and re.search(r"\b(ok|fine|safe)\b|ঠিক আছে|নিরাপদ", txt, re.I):
        return False
    return True


def night_card(user, now=None, lang=None, build=True):
    """Tonight's card for `user` (cached per local day)."""
    now = _now(now)
    from . import push
    lang = lang or push.user_lang(user)
    st = state_of(user)
    day = local(user, now).date().isoformat()
    last = st.get("night_last") or {}
    if last.get("day") == day and last.get("lang") == lang:
        return last
    if not build:
        return None
    facts = night_facts(user, now, lang)
    text, source = night_text(facts, lang)
    return {"day": day, "lang": lang, "text": text, "source": source,
            "members": len(facts), "at": _iso(now)}


def send_night_news(user, now=None):
    """Write tonight's card (in-app) and ring once if the budget allows."""
    now = _now(now)
    from . import push
    from .models import FamilyAlert
    card = night_card(user, now)
    if not card:
        return False
    with transaction.atomic():
        row = _row(user, lock=True)
        st = dict(row.data or {})
        if (st.get("night_last") or {}).get("day") == card["day"]:
            return False
        st["night_last"] = card
        _save(row, st)
    en = card["lang"] == "en"
    title = "Family tonight" if en else "আজ রাতের পরিবারের খবর"
    payload = {"route": "family/alerts", "alert_kind": "night_news", "event": "night_news",
               "voice": prefs_of(st)["night"]["voice"]}
    FamilyAlert.objects.create(user=user, kind="night_news", title=title,
                               body=card["text"], severity="info", payload=payload)
    from . import notif_budget
    if notif_budget.allow(user, "family_alert", family_kind="night_news", now=now):
        push.safe_push(user, "family_alert", title, title, card["text"], card["text"],
                       data=payload)
    return True


def tick(now=None):
    """Per-minute (minute_jobs: family_brain_tick): night news at each
    member's chosen local time; the monthly 'who can see you' card."""
    now = _now(now)
    from .models import FamilyAlert, PaCollectionItem
    stats = {"night_sent": 0, "reminders": 0}
    for row in PaCollectionItem.objects.filter(collection=COLLECTION).select_related("user"):
        u, st = row.user, dict(row.data or {})
        try:
            prefs = prefs_of(st)
            loc = local(u, now)
            day = loc.date().isoformat()
            if prefs["night"]["on"] and (st.get("night_last") or {}).get("day") != day:
                h, m = (int(x) for x in prefs["night"]["time"].split(":"))
                due = loc.replace(hour=h, minute=m, second=0, microsecond=0)
                if due <= loc <= due + timedelta(minutes=NIGHT_WINDOW_MIN) and peer_ids(u):
                    if send_night_news(u, now):
                        stats["night_sent"] += 1
            last = _parse(st.get("vis_seen_at")) or _parse(st.get("vis_reminded_at"))
            if last is None:
                # first month: start the clock, no card on day one
                st["vis_reminded_at"] = _iso(now)
                _save(row, st)
            elif now - last > timedelta(days=REMINDER_DAYS):
                n = len(peer_ids(u))
                if n:
                    from . import push
                    en = push.user_lang(u) == "en"
                    FamilyAlert.objects.create(
                        user=u, kind="visibility", severity="info",
                        title=("Who can see you" if en else "কে আপনাকে দেখতে পারেন"),
                        body=(("%d family members can see your status. Check or pause." % n) if en
                              else ("পরিবারের %s জন আপনার অবস্থা দেখতে পারেন। দেখুন বা বিরতি দিন।" % bn_num(n))),
                        payload={"route": "family/alerts", "alert_kind": "visibility"})
                    stats["reminders"] += 1
                st["vis_reminded_at"] = _iso(now)
                st.pop("vis_seen_at", None)
                _save(row, st)
        except Exception as e:  # noqa: BLE001
            log.warning("family_brain: tick row failed %s", type(e).__name__)
    return stats


# -------------------------------------------------------------------- ask
from .logic import fc_ask as ASK  # noqa: E402  (pure parser, mirrors fc_ask_parser.dart)


def _status_for(viewer, member, now):
    b = member_brain_state(viewer, member, now) or {}
    try:
        from .logic import family_status as FS
        s = FS.member_status(b, now, {})
    except Exception:  # noqa: BLE001 — fcscreen not merged: same honest rule
        s = ASK.simple_status(b, now)
    return b, s


def ask(user, q, family_id=None, lang=None, now=None):
    """POST family/brain/ask {q, family_id} -> {text, member_user_id, action, source}."""
    now = _now(now)
    from . import push
    from .models import User
    lang = lang or push.user_lang(user)
    ids = peer_ids(user)
    v3 = _v3()
    if family_id and v3 is not None:
        try:
            fam = set(v3.member_ids(int(family_id)))
            if user.pk in fam:
                ids = [i for i in ids if i in fam]
        except Exception:  # noqa: BLE001
            pass
    members = []
    for u in User.objects.filter(pk__in=ids):
        b, s = _status_for(user, u, now)
        lab = ""
        rel = ""
        if v3 is not None:
            try:
                for f in v3.families_of(user):
                    m = v3.membership(u, f.pk)
                    if m:
                        lab, rel = lab or (m.label or ""), rel or (m.relation or "")
            except Exception:  # noqa: BLE001
                pass
        members.append({"user_id": u.pk, "name": push.seen_name(user, u), "label": lab,
                        "relation": rel, "state": s.get("state"), "reason": s.get("reason"),
                        "place_label": place_name(b.get("place_kind"), b.get("place_label"), lang)
                        if b.get("place_kind") else "",
                        "last_seen": b.get("last_seen"), "battery": b.get("battery"),
                        "paused": bool(b.get("paused_until"))})
    ans = ASK.answer(q, members, lang, now)
    if ans is not None:
        return dict(ans, source="parser")
    return dict(_ask_ai(q, members, lang), source="ai")


ASK_TASK = (
    "You answer a family member's short question about their family in a safety app. "
    "Use ONLY the JSON member facts; if they do not answer the question, say plainly "
    "that Assisto does not know. Never say someone is OK unless their state is ok. "
    "One or two short sentences. Language: {lang}.")


def _ask_ai(q, members, lang):
    fallback = ("I can answer things like \"Is Ammu OK?\" or \"Where is my son?\"." if lang == "en"
                else "আমি এমন প্রশ্নের উত্তর দিতে পারি: \"আম্মু ঠিক আছেন?\" বা \"আমার ছেলে কোথায়?\"")
    try:
        from . import ai
        facts = [{k: m[k] for k in ("name", "label", "relation", "state", "reason",
                                     "place_label", "last_seen", "battery", "paused")}
                 for m in members]
        txt, _c = ai.generate(ASK_TASK.format(lang="natural Bangla" if lang != "en" else "English"),
                              data=json.dumps({"question": str(q)[:300], "members": facts},
                                              ensure_ascii=False),
                              tier="cheap", max_tokens=160, feature="family.ask", user=None,
                              task_class="cheap", level="normal",
                              digits="bn" if lang != "en" else None)
        txt = (txt or "").strip()
        if txt:
            return {"text": txt[:400], "member_user_id": None, "action": "none"}
    except Exception as e:  # noqa: BLE001
        log.info("family_brain: ask AI fallback %s", type(e).__name__)
    return {"text": fallback, "member_user_id": None, "action": "none"}


def digest(user):
    """Short hash of the state (tests / debugging; never shown)."""
    return hashlib.sha1(json.dumps(state_of(user), sort_keys=True).encode()).hexdigest()[:10]
