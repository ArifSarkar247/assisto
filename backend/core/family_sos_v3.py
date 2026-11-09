"""fcsos — Family Care v3 SCREEN 2 (SOS sender) + SCREEN 3 (SOS receiver).

Built ON the existing SOS path (core/family_alerts.py: one FamilyAlertDelivery
per event+recipient, FCM push kind "sos" = full-screen alarm) and guardian2's
"I am going" (guardian_links.responding). No new model, no migration:

  * live location — while the SOS is active the sender's phone posts its
    position; it is written into each recipient's FamilyAlert payload
    (lat/lng/loc_at), the same place the first position already lives.
  * 30 s audio — recorded on the sender's phone ONLY after the SOS went out
    (the screen says so, with Stop). Stored at a path derived from the event
    (default_storage "sos_audio/<sender>/<hash>.m4a"), played only by the
    event's recipients and the sender, deleted after AUDIO_KEEP_DAYS.
  * emergency info — blood group + emergency contacts from the sender's own
    EmergencyCard, shown ONLY when the sender switched "share in SOS" on
    (EmergencyCard.card["sos_share_info"]).
  * nearest police + hospital — Assisto's own Nearby list (OSM + owner
    edits, core/nearby_list.py), never Google; country = our own lookup.

Everything here is free on every plan and never shows ads (safety).
"""
import base64
import binascii
import hashlib
import logging
from datetime import timedelta

from django.core.files.base import ContentFile
from django.core.files.storage import default_storage
from django.utils import timezone

log = logging.getLogger(__name__)

ACTIVE_S = 30 * 60            # an SOS is "active" for 30 min unless resolved
LOC_MIN_GAP_S = 8             # live-location writes at most every 8 s
AUDIO_MAX_SEC = 30
AUDIO_MAX_BYTES = 700 * 1024  # 30 s AAC-LC mono 48 kbps ~ 180 KB; generous cap
AUDIO_KEEP_DAYS = 7
NEARBY_BOX_DEG = 0.35         # ~35-40 km around the sender
NEARBY_MAX_M = 40000
SOS_KINDS = ("sos", "fall")


def _iso(dt):
    return dt.isoformat() if dt else None


def _float(v, lim):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f, 6) if -lim <= f <= lim else None


# ------------------------------------------------------------- the event
def latest_event(sender, now=None):
    """The sender's newest SOS / fall delivery inside the active window (any
    recipient's row — they share the event_key), or None."""
    from .models import FamilyAlertDelivery
    now = now or timezone.now()
    return (FamilyAlertDelivery.objects
            .filter(sender=sender, kind__in=SOS_KINDS,
                    created_at__gte=now - timedelta(seconds=ACTIVE_S))
            .order_by("-created_at").first())


def _resolution(sender_id, since):
    """("safe"|"mistake", at) when the sender ended the SOS after `since`."""
    from .models import FamilyAlertDelivery
    r = (FamilyAlertDelivery.objects
         .filter(sender_id=sender_id, kind="sos_resolved", created_at__gte=since)
         .select_related("alert").order_by("created_at").first())
    if r is None:
        return None, None
    p = (r.alert.payload if r.alert else {}) or {}
    return ("mistake" if p.get("reason") == "mistake" else "safe"), r.created_at


def state_of(d, now=None):
    now = now or timezone.now()
    st, _at = _resolution(d.sender_id, d.created_at)
    if st:
        return st
    if (now - d.created_at).total_seconds() > ACTIVE_S:
        return "ended"
    return "active"


def active_sos_user_ids(family_id, now=None):
    """fcscreen hook: members of `family_id` with an active (unresolved, <30
    min) SOS — the Family screen paints them red. Never raises."""
    try:
        from . import family_v3
        ids = set(family_v3.member_ids(family_id) or [])
    except Exception:  # noqa: BLE001
        return set()
    if not ids:
        return set()
    from .models import FamilyAlertDelivery
    now = now or timezone.now()
    out = set()
    rows = (FamilyAlertDelivery.objects
            .filter(sender_id__in=ids, kind__in=SOS_KINDS,
                    created_at__gte=now - timedelta(seconds=ACTIVE_S))
            .order_by("sender_id", "-created_at")
            .values_list("sender_id", "created_at"))
    seen = set()
    for sid, at in rows:
        if sid in seen:
            continue
        seen.add(sid)
        st, _ = _resolution(sid, at)
        if not st:
            out.add(sid)
    return out


def _event_alerts(sender, event_key):
    from .models import FamilyAlert, FamilyAlertDelivery
    ids = list(FamilyAlertDelivery.objects.filter(sender=sender, event_key=event_key)
               .exclude(alert__isnull=True).values_list("alert_id", flat=True))
    return FamilyAlert.objects.filter(pk__in=ids)


# ------------------------------------------------------- live location
def post_location(sender, lat, lng, now=None):
    """Sender's phone during an active SOS. Returns {"ok", "updated"} or
    {"ok": False, "reason": "no_active_sos"|"bad_location"}."""
    now = now or timezone.now()
    lat, lng = _float(lat, 90), _float(lng, 180)
    if lat is None or lng is None:
        return {"ok": False, "reason": "bad_location"}
    d = latest_event(sender, now)
    if d is None or state_of(d, now) != "active":
        return {"ok": False, "reason": "no_active_sos"}
    n = 0
    for fa in _event_alerts(sender, d.event_key):
        p = dict(fa.payload or {})
        last = p.get("loc_at_epoch")
        if last and now.timestamp() - float(last) < LOC_MIN_GAP_S:
            return {"ok": True, "updated": 0, "throttled": True}
        p.update({"lat": lat, "lng": lng, "loc_at": _iso(now),
                  "loc_at_epoch": int(now.timestamp())})
        fa.payload = p
        fa.save(update_fields=["payload"])
        n += 1
    # the first position may have been missing: every row now carries one
    from .models import FamilyAlertDelivery
    FamilyAlertDelivery.objects.filter(sender=sender, event_key=d.event_key,
                                       with_location=False).update(with_location=True)
    return {"ok": True, "updated": n}


# ---------------------------------------------------------------- audio
def _audio_path(sender_id, event_key):
    h = hashlib.sha256(("%s|%s" % (sender_id, event_key)).encode()).hexdigest()[:24]
    return "sos_audio/%d/%s.m4a" % (sender_id, h)


def save_audio(sender, audio_b64, sec, now=None):
    now = now or timezone.now()
    d = latest_event(sender, now)
    if d is None:
        return {"ok": False, "reason": "no_active_sos"}
    try:
        raw = base64.b64decode(str(audio_b64 or ""), validate=True)
    except (binascii.Error, ValueError):
        return {"ok": False, "reason": "bad_audio"}
    try:
        sec = int(float(sec or 0))
    except (TypeError, ValueError):
        sec = 0
    if not raw or len(raw) > AUDIO_MAX_BYTES or sec > AUDIO_MAX_SEC + 1 or sec < 0:
        return {"ok": False, "reason": "bad_audio"}
    path = _audio_path(sender.pk, d.event_key)
    try:
        if default_storage.exists(path):
            default_storage.delete(path)
        default_storage.save(path, ContentFile(raw))
    except Exception as e:  # noqa: BLE001
        log.warning("fcsos audio save failed %s", type(e).__name__)
        return {"ok": False, "reason": "storage"}
    for fa in _event_alerts(sender, d.event_key):
        p = dict(fa.payload or {})
        p["audio_sec"] = max(1, sec)
        fa.payload = p
        fa.save(update_fields=["payload"])
    return {"ok": True, "sec": max(1, sec)}


def audio_for(user, delivery_id):
    """(file, None) for the event's recipient or its sender, else (None, why)."""
    from django.db.models import Q
    from .models import FamilyAlertDelivery
    d = (FamilyAlertDelivery.objects
         .filter(Q(recipient=user) | Q(sender=user), pk=delivery_id, kind__in=SOS_KINDS)
         .first())
    if d is None or d.sender_id is None:
        return None, "not_found"
    path = _audio_path(d.sender_id, d.event_key)
    if not default_storage.exists(path):
        return None, "no_audio"
    return default_storage.open(path, "rb"), None


def purge_audio(now=None):
    """Delete SOS recordings older than AUDIO_KEEP_DAYS (minute cron, cheap)."""
    now = now or timezone.now()
    n = 0
    try:
        dirs, _files = default_storage.listdir("sos_audio")
    except Exception:  # noqa: BLE001 — nothing recorded yet
        return 0
    cut = now - timedelta(days=AUDIO_KEEP_DAYS)
    for sub in dirs:
        try:
            _d, files = default_storage.listdir("sos_audio/%s" % sub)
        except Exception:  # noqa: BLE001
            continue
        for f in files:
            p = "sos_audio/%s/%s" % (sub, f)
            try:
                if default_storage.get_modified_time(p) < cut:
                    default_storage.delete(p)
                    n += 1
            except Exception:  # noqa: BLE001
                continue
    return n


# ------------------------------------------------- emergency info / settings
def _card(user):
    from .models import EmergencyCard
    return EmergencyCard.objects.filter(user=user).first()


def get_settings(user):
    c = _card(user)
    card = (c.card if c else {}) or {}
    return {"share_info": bool(card.get("sos_share_info")),
            "blood_group": (c.blood_group if c else "") or "",
            "contacts": len((c.contacts if c else []) or [])}


def set_settings(user, share_info):
    from .models import EmergencyCard
    c, _ = EmergencyCard.objects.get_or_create(user=user)
    card = dict(c.card or {})
    card["sos_share_info"] = bool(share_info)
    c.card = card
    c.save(update_fields=["card", "updated_at"])
    return get_settings(user)


def shared_info(sender):
    c = _card(sender)
    if c is None or not ((c.card or {}).get("sos_share_info")):
        return None
    contacts = []
    for x in (c.contacts or [])[:3]:
        if not isinstance(x, dict):
            continue
        ph = str(x.get("phone") or "").strip()[:24]
        if ph:
            contacts.append({"name": str(x.get("name") or "")[:60], "phone": ph,
                             "relation": str(x.get("relation") or "")[:30]})
    info = {"blood_group": (c.blood_group or "")[:8],
            "allergies": (c.allergies or "")[:200],
            "conditions": (c.conditions or "")[:200],
            "contacts": contacts}
    return info if any([info["blood_group"], info["allergies"], info["conditions"],
                        contacts]) else None


# ---------------------------------------------------------------- nearby
def nearest(lat, lng):
    """{police:[...], hospital:[...], country, attribution} — Assisto's own
    Nearby list around the sender, nearest first, 2 of each."""
    from . import nearby_list as NL
    from .models import NearbyPlace
    out = {"police": [], "hospital": [], "country": "", "attribution": NL.ATTRIBUTION}
    if lat is None or lng is None:
        return out
    b = NEARBY_BOX_DEG
    try:
        qs = (NearbyPlace.objects.filter(category__in=("police", "hospital"), hidden=False)
              .filter(NL._in_box(lat - b, lat + b, lng - b, lng + b))
              .exclude(source="biz")[:4000])
        rows = []
        off, world = NL.disabled_countries(), NL.world_on()
        for p in qs:
            if not NL.country_allowed(p.country, world, off):
                continue
            e = NL.eff(p)
            m = NL.haversine_m(lat, lng, e["lat"], e["lon"])
            if m <= NEARBY_MAX_M:
                rows.append((m, p.category, e))
        rows.sort(key=lambda x: x[0])
        for m, cat, e in rows:
            if len(out[cat]) < 2:
                out[cat].append({"name": e["name"] or e["name_en"] or "",
                                 "name_en": e["name_en"] or e["name"] or "",
                                 "phone": e["phone"] or "", "lat": round(e["lat"], 6),
                                 "lng": round(e["lon"], 6), "distance_m": int(m)})
        out["country"] = NL.country_at(lat, lng)
    except Exception as e:  # noqa: BLE001 — the alarm page never fails on this
        log.warning("fcsos nearby failed %s", type(e).__name__)
    return out


# ------------------------------------------------------- receiver screen
def event_detail(viewer, delivery_id, now=None):
    """SCREEN 3 for one received SOS / fall: who, when, where (live), audio,
    who is going, nearest police + hospital, emergency info, state."""
    from . import push
    from .models import FamilyAlertDelivery
    now = now or timezone.now()
    d = (FamilyAlertDelivery.objects.select_related("alert", "sender")
         .filter(pk=delivery_id, recipient=viewer, kind__in=SOS_KINDS).first())
    if d is None or d.sender is None:
        return None
    s = d.sender
    p = (d.alert.payload if d.alert else {}) or {}
    lat = _float(p.get("lat"), 90) if d.with_location else None
    lng = _float(p.get("lng"), 180) if d.with_location else None
    st = state_of(d, now)
    try:
        from . import guardian_links
        going = guardian_links.responders(d.event_key, viewer)
    except Exception:  # noqa: BLE001
        going = []
    # the phone number the viewer already has for the sender (their circle
    # row), else the account phone — both are family
    phone = ""
    try:
        from .family_alerts import _edge
        e = _edge(viewer, s)
        phone = ((e.phone if e else "") or s.phone or "").strip()
    except Exception:  # noqa: BLE001
        phone = (s.phone or "").strip()
    near = nearest(lat, lng)
    return {
        "id": d.id, "kind": d.kind, "state": st,
        "sender": {"id": s.pk, "name": push.seen_name(viewer, s), "phone": phone},
        "sent_at": _iso(d.created_at), "server_now": _iso(now),
        "age_s": int((now - d.created_at).total_seconds()),
        "location": ({"lat": lat, "lng": lng,
                      "at": p.get("loc_at") or _iso(d.created_at),
                      "live": bool(p.get("loc_at"))} if lat is not None else None),
        "audio_sec": int(p.get("audio_sec") or 0),
        "going": going, "me_going": d.responding_at is not None,
        "info": shared_info(s),
        "nearby": near, "country": near.get("country") or "",
        "duress": bool(p.get("duress")),
        "timing": {"created": _iso(d.created_at), "pushed": _iso(d.pushed_at),
                   "received": _iso(d.received_at)},
    }


def sender_status(sender, now=None):
    """SCREEN 2 after sending: the event's state + who is going (the ladder
    card already shows per-person receipts)."""
    now = now or timezone.now()
    d = latest_event(sender, now)
    if d is None:
        return {"state": "none"}
    try:
        from . import guardian_links
        going = guardian_links.responders(d.event_key, sender)
    except Exception:  # noqa: BLE001
        going = []
    return {"state": state_of(d, now), "sent_at": _iso(d.created_at),
            "going": going,
            "audio": default_storage.exists(_audio_path(sender.pk, d.event_key))}
