"""cctvplay — remote playback of PHONE-camera alert clips (owner order 9 Nov
14:45, item 3) + the store the continuous-recording timeline (item 4) uses.
Rules: core/logic/phonecam_clips.py. No migration: per-camera state lives in
one generic PaCollectionItem row (collection "phonecam_rec", user = owner).

DEVICE (camera token, like shop/ingest)
  heartbeat reply  + "phonecam": {clip: {enabled, recipients, max_kb, fps,
                   width, left_today}, video_requests: [{key, kind, ref|start}]}
  POST shop/clips  (existing) a SEALED preview (ACG1 frames, <= 12.5 s) for an
                   alert that named its clip_ref — phone cameras get their own
                   per-camera daily cap and are never deleted by one view
  POST shop/phonecam/video   {key, meta, blob} the sealed full MP4 a viewer
                   asked for — or {key, missing: true} when it rolled over
VIEWER (owner / family viewer of the place)
  GET  shop/events/<id>/clip/full   state + (ready) signed link + MY wrap
  POST shop/events/<id>/clip/full   ask the camera phone for the full video

The server never holds a readable clip: ciphertext only, 24 h, then deleted.
"""
import hashlib
import json
import logging
from datetime import datetime, timedelta, timezone as dtz

from django.core.files.base import ContentFile
from django.db import transaction
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang
from .logic import cash_guard as CG
from .logic import phonecam_clips as P
from . import shop_views as SV

log = logging.getLogger("assisto.shop")

COLLECTION = "phonecam_rec"
PREVIEW_FPS, PREVIEW_WIDTH = 1.5, 320


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def is_phone(cam):
    return cam is not None and getattr(cam, "vendor", "") == "phone"


def _now_ts(now=None):
    return (now or timezone.now()).timestamp()


# ---------------------------------------------------------------- store
def _row(owner_id, cam_id, lock=False, create=False):
    from .models import PaCollectionItem
    qs = PaCollectionItem.objects.filter(user_id=owner_id, collection=COLLECTION,
                                         data__cam=int(cam_id))
    if lock:
        qs = qs.select_for_update()
    row = qs.order_by("id").first()
    if row is None and create:
        row = PaCollectionItem.objects.create(user_id=owner_id, collection=COLLECTION,
                                              data={"cam": int(cam_id)})
    return row


def data_for(cam):
    row = _row(cam.site.owner_id, cam.pk)
    return dict(row.data or {}) if row else {"cam": cam.pk}


def update(cam, fn):
    """Read-modify-write of the camera's row under a lock; returns the data."""
    with transaction.atomic():
        row = _row(cam.site.owner_id, cam.pk, lock=True, create=True)
        d = fn(dict(row.data or {}))
        d["cam"] = cam.pk
        row.data = d
        row.save(update_fields=["data", "updated_at"])
    return d


def _drop_file(name):
    if not name:
        return
    try:
        from .logic.cctv_store import vault_storage
        vault_storage().delete(name)
    except Exception:
        log.exception("phonecam video delete failed")


def _expire(reqs, now_ts):
    """Lazy expiry: a ready video past 24 h loses its bytes now."""
    changed = False
    for k, r in list((reqs or {}).items()):
        if isinstance(r, dict) and r.get("status") == "ready" and \
                P.request_state(r, now_ts) == "expired":
            _drop_file(r.get("name"))
            reqs[k] = {kk: vv for kk, vv in r.items()
                       if kk not in ("name", "meta")}
            reqs[k]["status"] = "expired"
            changed = True
    return changed


def purge_videos(now=None):
    """Hourly (shop_clip_purge) + lazy: delete every full video past 24 h."""
    from .models import PaCollectionItem
    now_ts = _now_ts(now)
    n = 0
    try:
        for row in PaCollectionItem.objects.filter(collection=COLLECTION):
            d = dict(row.data or {})
            reqs = dict(d.get("reqs") or {})
            before = sum(1 for r in reqs.values()
                         if isinstance(r, dict) and r.get("status") == "ready")
            if _expire(reqs, now_ts):
                after = sum(1 for r in reqs.values()
                            if isinstance(r, dict) and r.get("status") == "ready")
                n += before - after
                d["reqs"] = P.prune(reqs, now_ts)
                row.data = d
                row.save(update_fields=["data", "updated_at"])
    except Exception:
        log.exception("phonecam video purge failed")
    return n


def forget_camera(owner_id, cam_id):
    """Unbind: the camera's stored videos + timeline go with it."""
    row = _row(owner_id, cam_id)
    if row is None:
        return
    for r in ((row.data or {}).get("reqs") or {}).values():
        if isinstance(r, dict):
            _drop_file(r.get("name"))
    row.delete()


# ---------------------------------------------------------------- caps
def previews_day():
    try:
        from . import billing
        v = int(((billing.cfg().get("shop") or {}).get("phonecam_previews_day",
                                                        P.PREVIEWS_DAY_DEFAULT)))
        return max(0, min(200, v))
    except Exception:
        return P.PREVIEWS_DAY_DEFAULT


def previews_today(cam, now=None):
    from .models import ShopEventClip
    start = timezone.localtime(now or timezone.now()).replace(
        hour=0, minute=0, second=0, microsecond=0)
    return ShopEventClip.objects.filter(event__camera=cam, created__gte=start).count()


def preview_left(cam, now=None):
    return max(0, previews_day() - previews_today(cam, now))


def budget(owner_id, now=None):
    from . import cctv_traffic as CT
    try:
        c = CT.cfg()
        return P.budget_view(CT.account_state(owner_id, now, c=c), c["confirmed"])
    except Exception:
        return P.budget_view({}, False)


def count_bytes(cam, nbytes, now=None):
    try:
        from . import cctv_traffic as CT
        CT.record_clip(cam.site.owner_id, cam.pk, nbytes, now)
    except Exception:
        log.exception("phonecam clip meter failed")


# ---------------------------------------------------------------- heartbeat
def heartbeat_block(site, cams, now=None):
    """What a camera PHONE needs on every heartbeat (None for other edges)."""
    cam = next((c for c in cams if is_phone(c)), None)
    if cam is None:
        return None
    now = now or timezone.now()
    try:
        recips = SV.clip_recipients(site)
        left = preview_left(cam, now)
        d = data_for(cam)
        reqs = dict(d.get("reqs") or {})
        return {"camera_id": cam.pk,
                "clip": {"enabled": bool(recips) and left > 0,
                         "recipients": recips, "max_kb": P.PREVIEW_MAX_KB,
                         "fps": PREVIEW_FPS, "width": PREVIEW_WIDTH,
                         "left_today": left, "scheme": CG.CLIP_SCHEME,
                         "full_aad": P.FULL_AAD,
                         "full_max_mb": P.FULL_MAX_BYTES // (1024 * 1024)},
                "video_requests": P.pending_for_device(reqs, _now_ts(now))}
    except Exception:
        log.exception("phonecam heartbeat block failed")
        return {"camera_id": cam.pk, "clip": {"enabled": False, "recipients": []},
                "video_requests": []}


# ---------------------------------------------------------------- viewer
def _camera_online(cam, now):
    ls = getattr(cam, "last_seen", None)
    return P.online(ls.timestamp() if ls else None, _now_ts(now))


def _state_body(request, ev, cam, req, now, count=True):
    now_ts = _now_ts(now)
    st = P.request_state(req, now_ts)
    body = {"event_id": ev.id, "status": st,
            "camera_online": _camera_online(cam, now),
            "clip_s": P.CLIP_S, "keep_h": P.FULL_TTL_S // 3600,
            "est_mb": P.EST_FULL_MB, "budget": budget(cam.site.owner_id, now),
            "has_ref": bool((ev.signals or {}).get("clip_ref"))}
    if st == "missing":
        body["reason"] = (req or {}).get("reason") or "rolled_over"
    if st == "ready":
        from .logic.cctv_store import vault_storage
        name = req.get("name")
        try:
            url = request.build_absolute_uri(vault_storage().url(name))
        except Exception:
            url = vault_storage().url(name)
        meta = CG.meta_for(req.get("meta") or {}, request.user.pk)
        body.update({"url": url, "meta": meta, "size": int(req.get("size") or 0),
                     "expires_at": SV._iso(datetime.fromtimestamp(
                         float(req.get("expires") or 0), tz=dtz.utc)),
                     "sealed_for_you": meta.get("wrap") is not None})
        if count and meta.get("wrap") is not None:
            count_bytes(cam, int(req.get("size") or 0), now)
    return body


def _phone_event(request, pk):
    from . import cctvx_views as CXV
    ev, role = CXV.event_access(request, pk)
    if ev is None or not is_phone(ev.camera):
        return None, None
    return ev, role


class EventFullClipView(APIView):
    """GET/POST shop/events/<id>/clip/full — the camera phone's full video."""

    def get(self, request, pk):
        lang = req_lang(request)
        ev, _role = _phone_event(request, pk)
        if ev is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()
        d = data_for(ev.camera)
        reqs = dict(d.get("reqs") or {})
        if _expire(reqs, _now_ts(now)):
            update(ev.camera, lambda x: dict(x, reqs=reqs))
        return Response(_state_body(request, ev, ev.camera,
                                    reqs.get(P.event_key(ev.id)), now))

    def post(self, request, pk):
        lang = req_lang(request)
        ev, _role = _phone_event(request, pk)
        if ev is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        cam, now = ev.camera, timezone.now()
        ref = CG.clean_clip_ref((ev.signals or {}).get("clip_ref"))
        if not ref:
            return _err(lang,
                        "এই সতর্কতাটি ক্যামেরা-ফোনের পুরনো Assisto থেকে এসেছে — পুরো "
                        "ভিডিও আনা যায় না। ক্যামেরা-ফোনে Assisto আপডেট করুন।",
                        "This alert came from an older Assisto on the camera phone — "
                        "its full video can't be fetched. Update Assisto on the "
                        "camera phone.", status=404, code="no_clip_ref")
        key = P.event_key(ev.id)
        now_ts = _now_ts(now)
        cur = (data_for(cam).get("reqs") or {}).get(key)
        st = P.request_state(cur, now_ts)
        if st in ("requested", "ready"):
            return Response(_state_body(request, ev, cam, cur, now))
        if st == "missing":
            return Response(_state_body(request, ev, cam, cur, now))
        b = budget(cam.site.owner_id, now)
        if b["paused"]:
            return _err(lang,
                        "এই মাসের ভিডিও/রিলে সীমা শেষ — পুরো ভিডিও আনা যাবে না। "
                        "ছবি আর ছোট ভিডিও (প্রিভিউ) আগের মতোই আসবে। প্ল্যান থেকে "
                        "বাড়তি প্যাক নেওয়া যায়।",
                        "This month's video/relay budget is used up — full videos "
                        "can't be fetched. Photos and short previews still come. "
                        "An extra pack can be added from the plan.",
                        status=402, code="budget_paused", budget=b)
        req = {"status": "requested", "at": now_ts, "by": request.user.pk,
               "ref": ref}

        def fn(d):
            reqs = dict(d.get("reqs") or {})
            if P.request_state(reqs.get(key), now_ts) not in ("requested", "ready"):
                reqs[key] = req
            d["reqs"] = P.prune(reqs, now_ts)
            return d
        d = update(cam, fn)
        return Response(_state_body(request, ev, cam, (d.get("reqs") or {}).get(key),
                                    now), status=202)


# ---------------------------------------------------------------- device
class PhoneCamVideoUploadView(APIView):
    """POST shop/phonecam/video — the camera phone answers one request."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        lang = req_lang(request)
        site, cam = SV._resolve_device_site(request)
        if site is None or not is_phone(cam):
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")
        key = P.clean_key(request.data.get("key"))
        now = timezone.now()
        now_ts = _now_ts(now)
        cur = (data_for(cam).get("reqs") or {}).get(key) if key else None
        st = P.request_state(cur, now_ts)
        if not key or st == "none":
            return _err(lang, "এই ভিডিও কেউ চায়নি।", "Nobody asked for this video.",
                        status=404, code="no_request")
        if st == "ready":
            return Response({"ok": True, "duplicate": True, "key": key})
        if st != "requested":
            return _err(lang, "অনুরোধের সময় পেরিয়ে গেছে।", "The request is over.",
                        status=410, code="request_over")
        if SV._coerce_bool(request.data.get("missing")):
            reason = str(request.data.get("reason") or "rolled_over")[:24]

            def gone(d):
                reqs = dict(d.get("reqs") or {})
                reqs[key] = dict(reqs.get(key) or {}, status="missing",
                                 reason=reason, done=now_ts)
                d["reqs"] = reqs
                return d
            update(cam, gone)
            return Response({"ok": True, "key": key, "status": "missing"})
        raw_meta = request.data.get("meta")
        if isinstance(raw_meta, str):
            try:
                raw_meta = json.loads(raw_meta)
            except ValueError:
                raw_meta = None
        probs = P.full_meta_problems(raw_meta)
        if probs:
            return _err(lang, "ভিডিওর তথ্য ঠিক নেই।", "The video envelope is not valid.",
                        status=422, code="bad_clip_meta", problems=probs)
        allowed = {str(r["uid"]) for r in SV.clip_recipients(site)}
        if not set(raw_meta["wraps"]).issubset(allowed) or \
                str(site.owner_id) not in raw_meta["wraps"]:
            return _err(lang, "ভিডিওটি মালিকের জন্য সিল করা নয়।",
                        "The video is not sealed for the owner.", status=422,
                        code="bad_recipients")
        for extra in request.FILES:
            if extra != "blob":
                return _err(lang, "শুধু একটি এনক্রিপ্টেড ভিডিও পাঠানো যায়।",
                            "Only one encrypted video is accepted.", status=415,
                            code="extra_file")
        up = request.FILES.get("blob")
        if up is None:
            return _err(lang, "ভিডিও নেই।", "No video.", status=422, code="no_blob")
        limit = P.FULL_MAX_BYTES
        if (getattr(up, "size", 0) or 0) > limit:
            return _err(lang, "ভিডিওটি খুব বড়।", "The video is too large.",
                        status=413, code="clip_too_large")
        raw = up.read(limit + 1)
        if len(raw) > limit:
            return _err(lang, "ভিডিওটি খুব বড়।", "The video is too large.",
                        status=413, code="clip_too_large")
        if len(raw) < 1024 or CG.looks_like_plain_media(raw):
            return _err(lang, "শুধু এনক্রিপ্ট করা ভিডিও নেওয়া হয় — খোলা ভিডিও কখনো নয়।",
                        "Only an encrypted video is accepted — never open video.",
                        status=415, code="not_encrypted")
        digest = hashlib.sha256(raw).hexdigest()
        if raw_meta.get("sha256") and raw_meta["sha256"] != digest:
            return _err(lang, "ভিডিওটি পথে নষ্ট হয়েছে।", "The video was damaged on the way.",
                        status=422, code="bad_digest")
        from .logic.cctv_store import vault_storage
        name = vault_storage().save("shop/clip/pc%d_%s.bin" % (cam.pk, key),
                                    ContentFile(raw))
        meta = dict(raw_meta, sha256=digest)
        expires = now_ts + P.FULL_TTL_S
        old = {}

        def done(d):
            reqs = dict(d.get("reqs") or {})
            prev = reqs.get(key) or {}
            if prev.get("status") == "ready":
                old["name"] = name          # lost a race: keep the first one
                return d
            reqs[key] = dict(prev, status="ready", name=name, size=len(raw),
                             meta=meta, expires=expires, done=now_ts)
            d["reqs"] = reqs
            return d
        update(cam, done)
        if old.get("name"):
            _drop_file(old["name"])
            return Response({"ok": True, "duplicate": True, "key": key})
        count_bytes(cam, len(raw), now)
        return Response({"ok": True, "key": key, "size": len(raw),
                         "expires_at": SV._iso(now + timedelta(seconds=P.FULL_TTL_S))},
                        status=201)


# ---------------------------------------------------------------- preview hooks
def preview_envelope_extra(request, ev, now=None):
    """Added to shop/events/<id>/clip for a phone camera: honest limits +
    the full video's state, so the viewer's sheet needs one call."""
    now = now or timezone.now()
    cam = ev.camera
    req = (data_for(cam).get("reqs") or {}).get(P.event_key(ev.id))
    body = _state_body(request, ev, cam, req, now, count=False)
    return {"full": {k: body[k] for k in ("status", "camera_online", "est_mb",
                                          "budget", "has_ref") if k in body},
            "clip_s": P.CLIP_S, "preview_keep_h": P.PREVIEW_TTL_S // 3600,
            "full_keep_h": P.FULL_TTL_S // 3600}
