"""cctvguard (owner CCTV order G): the per-account / per-camera traffic meter
and the relay cap. Pure rules live in core/logic/cctv_traffic.py; this file
only reads/writes rows and answers "may this live view use the relay?".

Storage: one generic PaCollectionItem row per account per month
(collection "cctv_traffic", data {"month": "YYYY-MM", "cams": {...},
"sess": {...}, "vsess": {...}, "turn_bytes": n}) — no migration.

Limits come from Owner Admin -> Pricing -> cctv_plan (agent/cctvprice):
`relay_mb_per_camera` (default 300) and `limits_owner_confirmed` (default
OFF = the meter counts and shows, nothing is ever blocked).
"""
import logging
import uuid
from datetime import timedelta

from django.core.cache import cache
from django.db import transaction
from django.utils import timezone

from .logic import cctv_traffic as T

log = logging.getLogger("assisto.cctvguard")

COLLECTION = "cctv_traffic"
EMERGENCY_WINDOW_H = 2
DEFAULT_RELAY_MB = 300


# ---------------------------------------------------------------- config
def cfg():
    """{confirmed, relay_mb} from the cctv_plan pricing block; any failure =
    the safe default (not confirmed -> nothing enforced)."""
    raw = {}
    try:
        from . import billing
        raw = billing.cfg().get("cctv_plan") or {}
    except Exception:
        raw = {}
    try:
        mb = int(raw.get("relay_mb_per_camera", DEFAULT_RELAY_MB))
    except (TypeError, ValueError):
        mb = DEFAULT_RELAY_MB
    return {"confirmed": raw.get("limits_owner_confirmed") is True,
            "relay_mb": max(0, min(5000, mb))}


def feature_on(user):
    try:
        from . import feature_flags as FF
        return FF.is_on("cctv_watchman", user, False)
    except Exception:
        return True


# ---------------------------------------------------------------- rows
def _row(owner_id, month, lock=False, create=False):
    from .models import PaCollectionItem
    qs = PaCollectionItem.objects.filter(user_id=owner_id, collection=COLLECTION,
                                         data__month=month)
    if lock:
        qs = qs.select_for_update()
    row = qs.first()
    if row is None and create:
        row = PaCollectionItem.objects.create(user_id=owner_id, collection=COLLECTION,
                                              data={"month": month})
    return row


def month_doc(owner_id, now=None):
    row = _row(owner_id, T.month_key(now or timezone.now()))
    return dict(row.data or {}) if row else {"month": T.month_key(now or timezone.now())}


def _update(owner_id, now, fn, month=None):
    """Read-modify-write of this month's (or `month`'s) row under a lock."""
    month = month or T.month_key(now)
    with transaction.atomic():
        row = _row(owner_id, month, lock=True, create=True)
        doc = fn(dict(row.data or {}))
        doc["month"] = month
        row.data = doc
        row.save(update_fields=["data", "updated_at"])
    return doc


def n_cameras(owner_id):
    from .models import ShopCamera
    return ShopCamera.objects.filter(site__owner_id=owner_id, enabled=True).count()


def extra_relay_mb(doc):
    """cctvcap: relay MB of the extra packs bought for this month."""
    from .logic import cctv_cap as C
    return C.extra(doc)["relay_mb"]


def account_state(owner_id, now=None, doc=None, c=None):
    c = c or cfg()
    doc = doc if doc is not None else month_doc(owner_id, now)
    cap = T.pool_mb(c["relay_mb"], n_cameras(owner_id)) + extra_relay_mb(doc)
    st = T.cap_state(T.account_relay_bytes(doc), cap, c["confirmed"])
    st["cap_mb"] = cap
    return st


# ---------------------------------------------------------------- emergency
def _arm_sos(viewer, site, now):
    """cctvcap: an active cctvarm SOS grant on this site (an SOS at Home
    opened the home cameras to the family) — the owner or a granted viewer."""
    if site is None:
        return False
    try:
        from .logic import cctv_arm as ARM
        arm = ARM.arm_of(site)
        if not ARM.sos_active(arm, now):
            return False
        vid = getattr(viewer, "pk", viewer)
        return vid == site.owner_id or vid in (arm["sos"].get("viewers") or [])
    except Exception:
        log.exception("arm sos check failed")
        return False


def emergency_active(viewer, owner_id, now=None, site=None):
    """An unresolved SOS / fall alert (last 2 h) sent BY the viewer or the
    camera owner, or sent TO the viewer, or an active SOS-at-Home grant on
    the camera's site — then a live view is never cut."""
    now = now or timezone.now()
    if _arm_sos(viewer, site, now):
        return True
    try:
        from django.db.models import Q
        from .models import FamilyAlertDelivery
        now = now or timezone.now()
        since = now - timedelta(hours=EMERGENCY_WINDOW_H)
        vid = getattr(viewer, "pk", viewer)
        rows = (FamilyAlertDelivery.objects.filter(
            kind__in=("sos", "fall"), created_at__gte=since)
            .filter(Q(sender_id=vid) | Q(sender_id=owner_id) | Q(recipient_id=vid))
            .values_list("sender_id", "created_at"))
        for sender_id, at in rows:
            if sender_id is None:
                continue
            if not FamilyAlertDelivery.objects.filter(
                    sender_id=sender_id, kind="sos_resolved", created_at__gte=at).exists():
                return True
    except Exception:
        log.exception("emergency check failed")
    return False


def _ekey(session_id):
    return "cctvguard:emerg:%s" % session_id


def relay_decision(viewer, owner_id, now=None, lang="bn", site=None):
    """May a NEW live view use the TURN relay? -> dict for the API."""
    now = now or timezone.now()
    st = account_state(owner_id, now)
    emergency = False
    if st["level"] == "paused":
        emergency = emergency_active(viewer, owner_id, now, site=site)
    allow = T.gate(st, emergency)
    level = "emergency" if (emergency and st["level"] == "paused") else st["level"]
    return {"allow": allow, "level": level, "pct": st["pct"],
            "enforced": st["enforced"], "cap_mb": st["cap_mb"],
            "used_mb": T.mb(st["used_bytes"]), "emergency": emergency,
            "message": T.messages(st["level"] if not emergency else "", st["pct"], lang)}


def mark_emergency(session_id):
    cache.set(_ekey(session_id), 1, 3 * 3600)


def session_relay_allowed(session):
    """The device side of a session: relay only if the start allowed it."""
    if cache.get(_ekey(session.pk)):
        return True
    st = account_state(session.site.owner_id)
    if T.gate(st):
        return True
    # cctvcap: an SOS that started AFTER the live view began still wins
    if emergency_active(session.owner_id, session.site.owner_id, site=session.site):
        mark_emergency(session.pk)
        return True
    return False


# ---------------------------------------------------------------- recording
def record_live(session, total_bytes, seconds, path, now=None):
    """Fold a cumulative client report of one WebRTC live session into the
    camera owner's month; returns the account state after it."""
    now = now or timezone.now()
    owner_id = session.site.owner_id

    def fn(doc):
        doc, _r, _d = T.add_live(doc, session.camera_id, session.pk,
                                 total_bytes, seconds, path)
        return doc
    try:
        doc = _update(owner_id, now, fn)
    except Exception:
        log.exception("traffic record failed")
        doc = None
    st = account_state(owner_id, now, doc=doc)
    _relay_after(owner_id, st, now)
    return st


def _relay_after(owner_id, st, now=None):
    """cctvcap: one push per month when the relay cap is reached."""
    try:
        from . import cctv_cap as CC
        CC.relay_after(owner_id, st, now)
    except Exception:
        log.exception("relay cap push failed")


def note_turn_usage(user_id, bytes_out, at=None):
    """core.turn_monitor hook: a closed coturn session of this user that no
    call claimed. Counted only if the user had a relayed live view around
    then (so a call's relay is never billed as CCTV)."""
    from .models import ShopLiveSession
    try:
        if not user_id or int(bytes_out or 0) <= 0:
            return False
        at = at or timezone.now()
        win = at - timedelta(minutes=20)
        hit = ShopLiveSession.objects.filter(
            site__owner_id=user_id, relayed=True, created__lte=at).filter(
            ended_at__isnull=True).exists() or ShopLiveSession.objects.filter(
            site__owner_id=user_id, relayed=True, created__lte=at,
            ended_at__gte=win).exists()
        if not hit:
            return False

        def fn(doc):
            doc["turn_bytes"] = int(doc.get("turn_bytes") or 0) + int(bytes_out)
            return doc
        doc = _update(user_id, at, fn)
        _relay_after(user_id, account_state(user_id, at, doc=doc), at)
        return True
    except Exception:
        log.exception("turn usage note failed")
        return False


# ---------------------------------------------------------------- vendor live
def vendor_open(cam, viewer, hd, ref="", now=None):
    now = now or timezone.now()
    vid = uuid.uuid4().hex[:16]
    ts = now.timestamp()

    def fn(doc):
        vs = dict(doc.get("vsess") or {})
        # forget stale ones (never more than ~20 kept)
        for k in sorted(vs, key=lambda k: vs[k].get("start", 0))[:max(0, len(vs) - 19)]:
            vs.pop(k, None)
        vs[vid] = {"cam": cam.pk, "viewer": getattr(viewer, "pk", None), "hd": bool(hd),
                   "start": ts, "touch": ts, "ref": str(ref)[:120], "open": True}
        doc["vsess"] = vs
        return doc
    _update(cam.site.owner_id, now, fn)
    return vid


def _vendor_month(cam, vid, now=None):
    """(month, session) of a vendor live view — this month or, for a view
    opened just before midnight on the 1st, last month. (None, None) if
    unknown or another camera's."""
    now = now or timezone.now()
    for at in (now, now - timedelta(hours=T.VENDOR_MAX_S / 3600.0 + 1)):
        doc = month_doc(cam.site.owner_id, at)
        v = (doc.get("vsess") or {}).get(str(vid))
        if v and int(v.get("cam") or 0) == cam.pk:
            return doc.get("month"), v
    return None, None


def vendor_get(cam, vid, now=None):
    return _vendor_month(cam, vid, now)[1]


def vendor_touch(cam, vid, now=None):
    """-> (ok, seconds_left). A touch after the idle stop is refused."""
    now = now or timezone.now()
    ts = now.timestamp()
    out = {"ok": False, "left": 0}

    def fn(doc):
        vs = dict(doc.get("vsess") or {})
        v = dict(vs.get(str(vid)) or {})
        if (not v or int(v.get("cam") or 0) != cam.pk or not v.get("open")
                or ts > float(v.get("touch", 0)) + T.VENDOR_IDLE_S
                or ts > float(v.get("start", 0)) + T.VENDOR_MAX_S):
            return doc
        v["touch"] = ts
        vs[str(vid)] = v
        doc["vsess"] = vs
        out["ok"] = True
        out["left"] = int(min(T.VENDOR_IDLE_S, float(v["start"]) + T.VENDOR_MAX_S - ts))
        return doc
    month, v = _vendor_month(cam, vid, now)
    if month:
        _update(cam.site.owner_id, now, fn, month=month)
    return out["ok"], out["left"]


def vendor_end(cam, vid, reported_s, hd=None, now=None):
    """Close a vendor live view: clamp the seconds, add the estimate.
    Idempotent (a second end adds nothing). -> (seconds_counted, ref)."""
    now = now or timezone.now()
    out = {"s": 0, "ref": ""}

    def fn(doc):
        vs = dict(doc.get("vsess") or {})
        v = dict(vs.get(str(vid)) or {})
        if not v or int(v.get("cam") or 0) != cam.pk or not v.get("open"):
            return doc
        secs = T.vendor_seconds(v["start"], v.get("touch"), now.timestamp(), reported_s)
        use_hd = bool(v.get("hd")) if hd is None else bool(hd)
        doc = T.add_vendor(doc, cam.pk, secs, use_hd)
        v["open"] = False
        v["secs"] = secs
        vs[str(vid)] = v
        doc["vsess"] = vs
        out["s"], out["ref"] = secs, v.get("ref", "")
        return doc
    month, v = _vendor_month(cam, vid, now)
    if month:
        _update(cam.site.owner_id, now, fn, month=month)
        if out["s"]:
            _relay_after(cam.site.owner_id, account_state(cam.site.owner_id, now), now)
    return out["s"], out["ref"]


def vendor_set_hd(cam, vid, hd, now=None):
    def fn(doc):
        vs = dict(doc.get("vsess") or {})
        v = vs.get(str(vid))
        if v and int(v.get("cam") or 0) == cam.pk and v.get("open"):
            v = dict(v, hd=bool(hd))
            vs[str(vid)] = v
            doc["vsess"] = vs
        return doc
    month, v = _vendor_month(cam, vid, now)
    if month:
        _update(cam.site.owner_id, now or timezone.now(), fn, month=month)


# ---------------------------------------------------------------- views
def usage_for(owner, now=None, lang="bn"):
    """The app's "this month" view for the camera owner."""
    from .models import ShopCamera
    now = now or timezone.now()
    c = cfg()
    doc = month_doc(owner.pk, now)
    cams = list(ShopCamera.objects.filter(site__owner=owner)
                .order_by("id").values_list("id", "name"))
    st = account_state(owner.pk, now, doc=doc, c=c)
    return {"month": doc.get("month"), "cameras": T.summary_rows(doc, cams),
            "relay_used_mb": T.mb(st["used_bytes"]), "relay_cap_mb": st["cap_mb"],
            "relay_pct": st["pct"], "level": st["level"],
            "enforced": st["enforced"], "per_camera_mb": c["relay_mb"],
            "message": T.messages(st["level"], st["pct"], lang),
            "turn_measured_mb": T.mb((doc or {}).get("turn_bytes")),
            "vendor_is_estimate": True}


def admin_rows(month, limit=200):
    """Owner Admin: every account's month, heaviest relay first."""
    from .models import PaCollectionItem
    c = cfg()
    out = []
    for r in (PaCollectionItem.objects.filter(collection=COLLECTION, data__month=month)
              .select_related("user")[:2000]):
        d = r.data or {}
        cams = d.get("cams") or {}
        relay = T.account_relay_bytes(d)
        agg = {k: sum(int((x or {}).get(k) or 0) for x in cams.values())
               for k in ("direct_bytes", "live_s", "relay_s", "vendor_s", "vendor_est_bytes")}
        n = n_cameras(r.user_id)
        cap = T.pool_mb(c["relay_mb"], n) + extra_relay_mb(d)
        st = T.cap_state(relay, cap, c["confirmed"])
        out.append({"user_id": r.user_id, "name": getattr(r.user, "name", "") or "",
                    "cameras": n, "relay_mb": T.mb(relay),
                    "client_relay_mb": T.mb(sum(int((x or {}).get("relay_bytes") or 0)
                                                for x in cams.values())),
                    "turn_mb": T.mb(d.get("turn_bytes")),
                    "direct_mb": T.mb(agg["direct_bytes"]),
                    "live_min": (agg["live_s"] + agg["vendor_s"] + 59) // 60,
                    "relay_min": (agg["relay_s"] + 59) // 60,
                    "vendor_min": (agg["vendor_s"] + 59) // 60,
                    "vendor_est_mb": T.mb(agg["vendor_est_bytes"]),
                    "cap_mb": cap, "pct": st["pct"], "level": st["level"],
                    "per_camera": T.summary_rows(d, [(k, "") for k in sorted(cams, key=str)])})
    out.sort(key=lambda x: (-x["relay_mb"], -x["vendor_est_mb"]))
    return out[:limit], c
