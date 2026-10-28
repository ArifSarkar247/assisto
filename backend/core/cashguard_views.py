"""
cashguard_views.py — CCTV Smart Cash Guard (owner order 28 Oct, part A).
Builds on the watchman (watchman_views.py) and the Shop Box ingest
(shop_views.py); the rules are pure in core/logic/cash_guard.py.

DEVICE (site / camera token, like shop/ingest)
  POST shop/clips                     the edge uploads ONE encrypted clip for
                                      an event it named with `clip_ref`:
                                      multipart `blob` (ciphertext) + `meta`
                                      (public envelope JSON). Plain media is
                                      refused; kept <= 24 h.
OWNER / VIEWER (Token auth)
  GET  shop/events/<id>/clip          the clip envelope for ME (only my wrap)
                                      + a short-lived signed link to the
                                      ciphertext; 410 once deleted
  POST shop/events/<id>/clip/viewed   the OWNER watched it -> bytes deleted now
                                      (a viewer's view is only acknowledged)
  GET/PUT shop/sites/<id>/away        owner-away mode {on, hours | until,
                                      schedule}
  GET  shop/cashguard                 plan caps + today's usage + away state +
                                      the hand-to-pocket label state ("not
                                      measured" — OFF)

THE SERVER NEVER SEES A READABLE CLIP: the content key is sealed on the edge
for the recipients' X25519 public keys; this server stores ciphertext only,
deletes it after 24 h or once the owner watched it (purge_clips(), hourly
command shop_clip_purge, and lazily on every clip request).
"""
import hashlib
import json
import logging
from datetime import timedelta

from django.core.files.base import ContentFile
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from . import shop_views as SV
from .logic import cash_guard as CG
from .watchman_views import _OwnerBase

log = logging.getLogger("assisto.shop")


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


# ---------------------------------------------------------------- purge
def _drop_blob(clip, status):
    try:
        if clip.blob:
            clip.blob.delete(save=False)
    except Exception:
        pass
    clip.blob = None
    clip.status = status
    clip.meta = {k: v for k, v in (clip.meta or {}).items() if k != "wraps"}
    clip.save(update_fields=["blob", "status", "meta"])


def purge_clips(now=None):
    """Delete every clip past its 24 h window (bytes + wrapped keys; the row
    stays as a tombstone). Returns the count. Never raises."""
    from .models import ShopEventClip
    now = now or timezone.now()
    n = 0
    try:
        for c in ShopEventClip.objects.filter(status="ready", expires_at__lte=now):
            _drop_blob(c, "expired")
            n += 1
    except Exception:
        log.exception("clip purge failed")
    return n


def _fresh(clip, now=None):
    """Lazy expiry: a clip past its window is deleted before anyone gets it."""
    if clip.status == "ready" and clip.expires_at <= (now or timezone.now()):
        _drop_blob(clip, "expired")
    return clip


# ---------------------------------------------------------------- device
class ShopClipUploadView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []        # device token, not a user session

    def post(self, request):
        from .models import ShopEvent, ShopEventClip
        lang = req_lang(request)
        site, _cam = SV._resolve_device_site(request)
        if site is None:
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")
        ref = CG.clean_clip_ref(request.data.get("clip_ref"))
        if not ref:
            return _err(lang, "ক্লিপের রেফারেন্স ঠিক নেই।", "Bad clip reference.",
                        status=422, code="bad_clip_ref")
        now = timezone.now()
        purge_clips(now)
        ev = (ShopEvent.objects.filter(
            site=site, signals__clip_ref=ref,
            created__gte=now - timedelta(seconds=CG.CLIP_UPLOAD_WINDOW_S * 4))
            .order_by("-created").first())
        if ev is None:
            # the event may not have reached us yet (edge retries) — or it
            # was never raised (then the edge gives up after its window)
            return _err(lang, "এই ক্লিপের সতর্কতা পাওয়া যায়নি।",
                        "No alert for this clip.", status=404, code="no_event")
        last = ev.last_at or ev.created
        if (now - last).total_seconds() > CG.CLIP_UPLOAD_WINDOW_S:
            return _err(lang, "ক্লিপ পাঠানোর সময় পেরিয়ে গেছে।",
                        "Too late to send this clip.", status=410,
                        code="clip_window_over")
        if SV.hasattr_clip(ev):
            return Response({"ok": True, "duplicate": True, "event_id": ev.id})
        caps = SV.owner_caps(site.owner)
        if SV.clips_today(site, now) >= caps["clips_day"]:
            return _err(lang, "আজকের ক্লিপের সীমা শেষ — শুধু ছবি থাকবে।",
                        "Today's clip limit is used up — the photo stays.",
                        status=429, code="clip_cap", limit=caps["clips_day"])
        raw_meta = request.data.get("meta")
        if isinstance(raw_meta, str):
            try:
                raw_meta = json.loads(raw_meta)
            except ValueError:
                raw_meta = None
        probs = CG.clip_meta_problems(raw_meta)
        if probs:
            return _err(lang, "ক্লিপের তথ্য ঠিক নেই।", "The clip envelope is not valid.",
                        status=422, code="bad_clip_meta", problems=probs)
        # a wrap for someone who may not see this site is refused
        allowed = {str(r["uid"]) for r in SV.clip_recipients(site)}
        if not set(raw_meta["wraps"]).issubset(allowed) or \
                str(site.owner_id) not in raw_meta["wraps"]:
            return _err(lang, "ক্লিপটি মালিকের জন্য সিল করা নয়।",
                        "The clip is not sealed for the owner.", status=422,
                        code="bad_recipients")
        up = request.FILES.get("blob")
        for extra in request.FILES:
            if extra != "blob":
                return _err(lang, "শুধু একটি এনক্রিপ্টেড ক্লিপ পাঠানো যায়।",
                            "Only one encrypted clip is accepted.", status=415,
                            code="extra_file")
        if up is None:
            return _err(lang, "ক্লিপ নেই।", "No clip.", status=422, code="no_blob")
        limit = caps["clip_kb"] * 1024
        if (getattr(up, "size", 0) or 0) > limit:
            return _err(lang, "ক্লিপটি খুব বড়।", "The clip is too large.",
                        status=413, code="clip_too_large")
        raw = up.read(limit + 1)
        if len(raw) > limit:
            return _err(lang, "ক্লিপটি খুব বড়।", "The clip is too large.",
                        status=413, code="clip_too_large")
        if len(raw) < 1024 or CG.looks_like_plain_media(raw):
            # NO READABLE VIDEO EVER: only ciphertext may be kept
            return _err(lang, "শুধু এনক্রিপ্ট করা ক্লিপ নেওয়া হয় — খোলা ভিডিও কখনো নয়।",
                        "Only an encrypted clip is accepted — never open video.",
                        status=415, code="not_encrypted")
        digest = hashlib.sha256(raw).hexdigest()
        if raw_meta.get("sha256") and raw_meta["sha256"] != digest:
            return _err(lang, "ক্লিপটি পথে নষ্ট হয়েছে।", "The clip was damaged on the way.",
                        status=422, code="bad_digest")
        meta = dict(raw_meta, sha256=digest)
        clip = ShopEventClip(event=ev, meta=meta, size=len(raw), sha256=digest,
                             expires_at=now + timedelta(seconds=CG.CLIP_TTL_S))
        clip.blob.save("e%d_%s.bin" % (ev.id, ref[:12]), ContentFile(raw), save=False)
        try:
            clip.save()
        except Exception:
            # lost a race with a duplicate upload — keep the first one
            try:
                clip.blob.delete(save=False)
            except Exception:
                pass
            return Response({"ok": True, "duplicate": True, "event_id": ev.id})
        return Response({"ok": True, "event_id": ev.id, "size": len(raw),
                         "expires_at": SV._iso(clip.expires_at)}, status=201)


# ---------------------------------------------------------------- owner
def _event_for(request, pk):
    """(event, role) for the site owner, a family viewer — and (cctvx) a
    person the alert was escalated to or the clip was shared with."""
    from . import cctvx_views as CXV
    return CXV.event_access(request, pk)


GONE = {"viewed": ("মালিক ক্লিপটি দেখেছেন, তাই মুছে ফেলা হয়েছে। ছবিটি আছে।",
                   "The owner watched this clip, so it was deleted. The photo stays."),
        "expired": ("২৪ ঘণ্টা পেরিয়ে যাওয়ায় ক্লিপটি মুছে গেছে। ছবিটি আছে।",
                    "The clip was deleted after 24 hours. The photo stays.")}


class EventClipView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        ev, role = _event_for(request, pk)
        if ev is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if not SV.hasattr_clip(ev):
            if (ev.signals or {}).get("clip_ref"):
                return Response({"status": "pending", "event_id": ev.id})
            return _err(lang, "এই সতর্কতার কোনো ক্লিপ নেই।",
                        "This alert has no clip.", status=404, code="no_clip")
        clip = _fresh(ev.clip)
        if clip.status != "ready" or not clip.blob:
            bn, en = GONE.get(clip.status, GONE["expired"])
            return Response({"status": clip.status, "event_id": ev.id,
                             "error": "clip_gone", "detail": pick(lang, bn, en)},
                            status=410)
        meta = CG.meta_for(clip.meta, request.user.pk)
        if meta.get("wrap") is None:
            return _err(lang, "এই ক্লিপটি আপনার ফোনের চাবির জন্য সিল করা হয়নি "
                              "(চাবি পরে তৈরি হয়েছে)। ছবিটি দেখুন।",
                        "This clip was not sealed for your phone's key (the key "
                        "was made later). Please look at the photo.",
                        status=409, code="not_sealed_for_you")
        try:
            url = request.build_absolute_uri(clip.blob.url)
        except Exception:
            url = clip.blob.url
        return Response({"status": "ready", "event_id": ev.id, "role": role,
                         "url": url, "meta": meta, "size": clip.size,
                         "expires_at": SV._iso(clip.expires_at),
                         "delete_on_view": role in ("owner", "shared"),
                         # cctvx: a shared wrap was made by the owner's phone
                         "shared": role == "shared"})


class EventClipViewedView(_OwnerBase):
    def post(self, request, pk):
        lang = req_lang(request)
        ev, role = _event_for(request, pk)
        if ev is None or not SV.hasattr_clip(ev):
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        clip = _fresh(ev.clip)
        if role not in ("owner", "shared"):
            return Response({"ok": True, "deleted": False, "status": clip.status})
        # cctvx: a clip the owner SHARED stays until that person watched it
        # too (or 24 h); each watcher's own wrapped key goes at once.
        meta = dict(clip.meta or {})
        share = dict(meta.get("share") or {})
        uid = str(request.user.pk)
        if role == "shared":
            if uid in share:
                share[uid] = dict(share[uid], viewed=True)
        else:
            meta["owner_viewed"] = True
        meta["share"] = share
        waiting = [u for u, r in share.items() if not r.get("viewed")]
        if clip.status == "ready" and (waiting or (role == "shared" and
                                                   not meta.get("owner_viewed"))):
            wraps = dict(meta.get("wraps") or {})
            wraps.pop(uid, None)
            meta["wraps"] = wraps
            clip.meta = meta
            if role == "owner":
                clip.viewed_at = timezone.now()
            clip.save(update_fields=["meta", "viewed_at"])
            return Response({"ok": True, "deleted": False, "status": clip.status,
                             "kept_for": len(waiting)})
        if clip.status == "ready":
            clip.meta = meta
            clip.viewed_at = clip.viewed_at or timezone.now()
            clip.save(update_fields=["viewed_at", "meta"])
            _drop_blob(clip, "viewed")
        return Response({"ok": True, "deleted": True, "status": clip.status})


def away_row(site, now=None):
    now = now or timezone.now()
    a = site.away if isinstance(site.away, dict) else {}
    return {"site": site.id, "active": SV.away_now(site, now),
            "until": a.get("until"), "schedule": a.get("schedule")}


class SiteAwayView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(away_row(s))

    def put(self, request, pk):
        from .logic import watchman as WM
        from .models import ShopSite
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data
        now = timezone.now()
        away = dict(s.away) if isinstance(s.away, dict) else {}
        if "on" in d:
            on = SV._coerce_bool(d.get("on"))
            if on:
                until = CG.away_until_from_hours(d.get("hours", 12), now)
                if until is None:
                    return _err(lang, "কত ঘণ্টা দূরে থাকবেন, ঠিক নেই।",
                                "The away time is not valid.", status=422,
                                code="bad_away_hours")
                away["until"] = until.isoformat()
            else:
                away["until"] = None
        if "schedule" in d:
            raw = d.get("schedule")
            if raw in (None, "", {}):
                away["schedule"] = None
            else:
                try:
                    clean = WM.normalize_zone_config({"schedule": raw})
                except WM.ZoneError:
                    return _err(lang, "দূরে থাকার সময়সূচি ঠিক নেই — দিন ও শুরু/শেষ সময় দিন।",
                                "The away schedule is not valid — pick days and start/end times.",
                                status=422, code="bad_schedule")
                away["schedule"] = clean["schedule"]
        ShopSite.objects.filter(pk=s.pk).update(away=away)
        s.away = away
        return Response(away_row(s, now))

    post = put     # the app's JSON client speaks POST


class CashGuardOverviewView(_OwnerBase):
    def get(self, request):
        from .models import ShopSite
        now = timezone.now()
        caps = SV.owner_caps(request.user)
        sites = list(ShopSite.objects.filter(owner=request.user))
        clips = SV.clips_today(sites[0], now) if sites else 0
        start = timezone.localtime(now).replace(hour=0, minute=0, second=0,
                                                microsecond=0)
        rows = []
        for s in sites:
            rows.append(dict(away_row(s, now),
                             name=s.name, kind=s.kind,
                             alerts_today=s.events.filter(created__gte=start).count(),
                             held_today=SV.held_today(s, now),
                             clip_recipients=len(SV.clip_recipients(s))))
        return Response({
            "caps": caps,
            "usage": {"cameras": SV.owner_enabled_cameras(request.user).count(),
                      "clips_today": clips},
            "sites": rows,
            "clip": {"seconds": [CG.CLIP_MIN_S, CG.CLIP_MAX_S],
                     "ttl_hours": CG.CLIP_TTL_S // 3600,
                     "end_to_end": True, "scheme": CG.CLIP_SCHEME},
            # owner rule: only with MEASURED precision on real clips
            "hand_to_pocket": {"enabled": CG.HAND_TO_POCKET_LABEL,
                               "precision": None, "measured": False,
                               "min_precision": CG.HAND_TO_POCKET_MIN_PRECISION},
            "ads": False})


# ======================================================== EZVIZ CLOUD
def ezviz_on():
    try:
        from . import integrations as I
        return I.is_enabled("ezviz")
    except Exception:
        return False


EZVIZ_ERRORS = {
    "wrong_code": ("লেবেলের Verification Code মেলেনি — ক্যামেরার নিচের স্টিকারের ৬ অক্ষরের কোডটি আবার দিন।",
                   "The Verification Code did not match — enter the 6-letter code from the camera's sticker again."),
    "taken": ("এই ক্যামেরা অন্য একটি EZVIZ অ্যাকাউন্টে আছে — EZVIZ অ্যাপ থেকে আগে সরান।",
              "This camera is in another EZVIZ account — remove it in the EZVIZ app first."),
    "offline": ("ক্যামেরাটি এখন অফলাইন — Wi-Fi ও বিদ্যুৎ দেখে আবার চেষ্টা করুন।",
                "The camera is offline — check its Wi-Fi and power, then try again."),
    "network": ("EZVIZ সার্ভারে পৌঁছানো যায়নি — একটু পরে আবার চেষ্টা করুন।",
                "Could not reach EZVIZ — please try again shortly."),
    "_": ("EZVIZ যুক্ত করা যায়নি। সিরিয়াল ও Verification Code মিলিয়ে দেখুন। ক্যামেরা গেটওয়ে দিয়ে ঠিকই চলবে।",
          "Could not link EZVIZ. Check the serial and Verification Code. The camera still works through your gateway."),
}


class CameraEzvizView(_OwnerBase):
    """POST {device_serial, verification_code, channel?} — link an EZVIZ
    camera's OWN alarms through the EZVIZ Open Platform (key-gated). The
    verification code is used for this one call and NEVER stored."""

    def post(self, request, pk):
        from .logic import ezviz as EZ
        from .models import ShopCamera
        from .watchman_views import _owner_cam
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if cam.vendor != "ezviz":
            return _err(lang, "এটি EZVIZ ক্যামেরা নয়।", "This is not an EZVIZ camera.",
                        status=409, code="not_ezviz")
        client = EZ.EzvizClient.from_integration() if ezviz_on() else None
        if client is None:
            return _err(lang, "EZVIZ ক্লাউড সতর্কতা এখনো চালু হয়নি — ক্যামেরা গেটওয়ে দিয়ে ঠিকই চলবে।",
                        "EZVIZ cloud alarms are not switched on yet — the camera still "
                        "works through your gateway.", status=503,
                        code="ezviz_not_configured")
        serial = str(request.data.get("device_serial") or "").strip().upper()[:40]
        code = str(request.data.get("verification_code") or "").strip().upper()[:16]
        try:
            ch = max(1, min(64, int(request.data.get("channel") or 1)))
        except (TypeError, ValueError):
            ch = 1
        if not serial or not serial.isalnum():
            return _err(lang, "ক্যামেরার লেবেলের সিরিয়াল নম্বর (SN) দিন।",
                        "Enter the serial number (SN) from the camera's label.",
                        status=422, code="serial_required")
        if not code:
            return _err(lang, "লেবেলের Verification Code দিন।",
                        "Enter the Verification Code from the camera's label.",
                        status=422, code="code_required")
        ref = "EZ:%s:%d" % (serial, ch)
        if ShopCamera.objects.filter(vendor_ref=ref).exclude(pk=cam.pk).exists():
            bn, en = EZVIZ_ERRORS["taken"]
            return _err(lang, bn, en, status=409, code="ezviz_taken")
        try:
            client.add_device(serial, code)
        except EZ.EzvizError as e:
            if e.hint != "already_mine":
                bn, en = EZVIZ_ERRORS.get(e.hint, EZVIZ_ERRORS["_"])
                return _err(lang, bn, en, status=502, code="ezviz_error",
                            ezviz_code=e.code, hint=e.hint)
        cam.vendor_ref = ref
        cam.source = SV.clean_source(dict(cam.source or {}, device_serial=serial))
        cam.compat = dict(cam.compat or {},
                          cloud_last_alarm_ms=int(timezone.now().timestamp() * 1000))
        cam.save(update_fields=["vendor_ref", "source", "compat"])
        return Response({"ok": True, "camera": SV._camera_row(cam),
                         "delivery": "poll_60s"})


def _fetch_ezviz_pic(url, getter=None):
    from .logic import ezviz as EZ
    if not url or not EZ.snapshot_url_allowed(url):
        return None
    try:
        if getter is not None:
            return getter(url)
        import requests
        r = requests.get(url, timeout=EZ.TIMEOUT_S, stream=True, allow_redirects=False)
        if r.status_code != 200:
            return None
        if not (r.headers.get("Content-Type") or "image/").lower().startswith("image/"):
            return None
        raw = r.raw.read(2 * 1024 * 1024 + 1, decode_content=True)
        return raw if raw and len(raw) <= 2 * 1024 * 1024 else None
    except Exception:
        return None


def poll_ezviz(client=None, now=None, getter=None):
    """One polling pass over every linked EZVIZ camera (command
    ezviz_poll_alarms, every minute). New alarms -> the same guard as every
    other source (camera_alarm, or a cash-zone event after the optional
    snapshot check). Returns the number of alarms ingested. Never raises."""
    from .logic import ezviz as EZ
    from .models import ShopCamera
    if client is None:
        if not ezviz_on():
            return 0
        client = EZ.EzvizClient.from_integration()
        if client is None:
            return 0
    now = now or timezone.now()
    now_ms = int(now.timestamp() * 1000)
    n = 0
    for cam in ShopCamera.objects.filter(vendor="ezviz", enabled=True,
                                         vendor_ref__startswith="EZ:").select_related("site"):
        try:
            _, serial, ch = cam.vendor_ref.split(":")
        except ValueError:
            continue
        last = int((cam.compat or {}).get("cloud_last_alarm_ms") or (now_ms - 10 * 60_000))
        last = max(last, now_ms - 10 * 60_000)        # never more than 10 min back
        try:
            rows = client.alarms(serial, last + 1, now_ms)
        except EZ.EzvizError:
            continue
        newest = last
        for row in sorted(rows, key=lambda r: str(r.get("alarmTime") or "")):
            a = EZ.parse_alarm(row)
            if a is None or a["at_ms"] <= last or a["channel"] != ch:
                continue
            newest = max(newest, a["at_ms"])
            snap, raw = None, None
            if a["pic"] and cam.site.snapshot_retention_days > 0:
                raw = _fetch_ezviz_pic(a["pic"], getter)
                if raw and not SV.looks_like_video(raw):
                    snap = SV._small_jpeg(raw, "ezviz%d.jpg" % cam.id)
            etype, sig = SV.vendor_alarm_event(
                cam, raw if snap is not None else None,
                {"human": a["human"], "vendor": "ezviz",
                 "alarm_type": "human" if a["human"] else "motion"}, now)
            SV._ingest_event(cam.site, cam, {"type": etype, "signals": sig,
                                             "at": a["at_ms"] / 1000.0}, now, snap)
            n += 1
        ShopCamera.objects.filter(pk=cam.pk).update(
            last_seen=now, compat=dict(cam.compat or {}, cloud_last_alarm_ms=newest))
    return n
