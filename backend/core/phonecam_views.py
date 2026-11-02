"""cctvphone — an old Android phone as an Assisto camera (owner CCTV order
3 Nov, part A). Built ON the existing Shop Box world, nothing rewritten:

* the camera phone is a normal ShopCamera (vendor "phone", kind "shopbox"),
  so plan caps, alerts (shop/ingest), heartbeat, live-view signaling, viewers
  and the watchman schedule all work unchanged;
* pairing (new): the viewer gets a short code + QR link (logic/phonecam.py,
  HMAC, no table); the camera phone claims it once and receives its camera
  token. Unbind any time from either side;
* health (new): the heartbeat's battery/view state -> pushed warnings to the
  owner and the family viewers (charger unplugged, battery low, hot, dark).

Behind the CCTV switch `cctv_watchman` (Shop Box). No migration.
"""
import logging

from django.conf import settings
from django.core.cache import cache
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang
from .logic import phonecam as PC
from . import shop_views as SV

log = logging.getLogger("assisto.shop")

FLAG = "cctv_watchman"
CLAIM_MAX_FAILS = 20          # per client IP per 10 minutes (brute-force guard)


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def _secret():
    return getattr(settings, "SECRET_KEY", "") or "assisto"


def flag_on(user, request=None):
    try:
        from . import feature_flags as FF
        play = False
        if request is not None:
            try:
                from .i18n import is_play_flavour
                play = is_play_flavour(request)
            except Exception:
                play = False
        return FF.is_on(FLAG, user, play)
    except Exception:
        return True


def _flag_off(lang):
    return _err(lang, "এই সুবিধা এখন বন্ধ আছে।", "This feature is switched off.",
                status=403, code="feature_off")


def is_phone_cam(cam):
    return cam is not None and cam.vendor == "phone"


def pair_nonce(site):
    """The site's newest phone-camera id (0 = none) — part of the code, so a
    claimed code is spent and the next phone gets a fresh one."""
    last = site.cameras.filter(vendor="phone").order_by("-id").values_list(
        "id", flat=True).first()
    return int(last or 0)


def viewers_live(cam):
    # owner order I: only the owner and people they ALLOW — family live view
    # of a phone camera is OFF until the owner turns it on per camera
    return bool((cam.source or {}).get("viewers_live", False))


def _phone_cam_row(cam):
    row = SV._camera_row(cam)
    src = cam.source or {}
    row["health"] = src.get("health") or {}
    row["viewers_live"] = viewers_live(cam)
    row["source"] = {k: v for k, v in src.items() if k != "pair_sha"}
    return row


class PhoneCamPairView(APIView):
    """GET shop/phonecam/pair?site=<id> (owner) — the code + App Link the
    viewer shows as a QR, how long it stays valid, the plan's camera room and
    the phone cameras this site already has (the screen polls this to see the
    new camera appear)."""

    def get(self, request):
        lang = req_lang(request)
        if not flag_on(request.user, request):
            return _flag_off(lang)
        site = SV._owner_site(request, request.query_params.get("site"))
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()
        code, valid_s = PC.pair_code(_secret(), site.id, site.owner_id,
                                     now.timestamp(), pair_nonce(site))
        included = SV._included_cameras(request.user)
        used = SV.owner_enabled_cameras(request.user).count()
        cams = [_phone_cam_row(c) for c in
                site.cameras.filter(vendor="phone").order_by("-created")[:20]]
        return Response({
            "code": code, "link": PC.pair_link(code), "valid_s": valid_s,
            "site": {"id": site.id, "name": site.name},
            "included": included, "used": used,
            "extra_needs_credits": used >= included,
            "extra_camera_credits": SV._extra_camera_credits(),
            "cameras": cams})


def _claim_fail(request):
    ip = (request.META.get("REMOTE_ADDR") or "")[:64]
    key = "phonecam_fail:%s" % ip
    try:
        n = cache.get(key) or 0
        cache.set(key, n + 1, 600)
        return n + 1
    except Exception:
        return 0


def _claim_blocked(request):
    ip = (request.META.get("REMOTE_ADDR") or "")[:64]
    try:
        return (cache.get("phonecam_fail:%s" % ip) or 0) >= CLAIM_MAX_FAILS
    except Exception:
        return False


class PhoneCamClaimView(APIView):
    """POST shop/phonecam/claim {code, name?, model?, platform?} — the CAMERA
    phone (no login needed) claims a pairing code once and becomes a camera
    of the code owner's site. Answers the camera token the phone keeps in
    secure storage. Counts as a camera for the plan (same cap + credits rule
    as adding any camera)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        from .models import ShopSite, ShopCamera
        from .logic import watchman as WM
        lang = req_lang(request)
        if _claim_blocked(request):
            return _err(lang, "অনেকবার ভুল কোড। ১০ মিনিট পরে আবার চেষ্টা করুন।",
                        "Too many wrong codes. Try again in 10 minutes.",
                        status=429, code="rate_limited")
        code = PC.normalize_code(request.data.get("code"))
        site = None
        if code:
            site = ShopSite.objects.filter(pk=PC.code_site(code)).select_related(
                "owner").first()
        now = timezone.now()
        if site is None or not PC.code_valid(_secret(), code, site.id,
                                             site.owner_id, now.timestamp(),
                                             pair_nonce(site)):
            _claim_fail(request)
            return _err(lang, "কোডটি ভুল বা মেয়াদ শেষ। মালিকের ফোনে নতুন কোড দেখুন।",
                        "Wrong or expired code. Check the new code on the owner's phone.",
                        status=400, code="bad_code")
        owner = site.owner
        if not flag_on(owner):
            return _flag_off(lang)
        sha = PC.code_sha(code)
        if ShopCamera.objects.filter(site=site, source__pair_sha=sha).exists():
            return _err(lang, "এই কোড আগেই ব্যবহার হয়েছে। মালিকের ফোনে নতুন কোড নিন।",
                        "This code was already used. Get a new code on the owner's phone.",
                        status=409, code="code_used")
        # the SAME plan cap as adding any camera (a phone camera IS a camera)
        included = SV._included_cameras(owner)
        existing = SV.owner_enabled_cameras(owner).count()
        need = SV._extra_camera_credits() if existing >= included else 0
        if need and int(owner.ai_credits or 0) < need:
            return _err(
                lang,
                "মালিকের প্ল্যানে %d টি ক্যামেরা; আরেকটি যোগ করতে মালিকের প্ল্যান "
                "বাড়াতে হবে বা ক্রেডিট লাগবে।" % included,
                "The owner's plan includes %d cameras; adding another needs a "
                "bigger plan or credits on the owner's account." % included,
                status=402, code="camera_cap", included=included, used=existing)
        charged = 0
        if need:
            charged = SV._debit_camera_credits(owner, need,
                                               note="phone camera #%d" % (existing + 1))
            if charged < need:
                return _err(lang, "যথেষ্ট ক্রেডিট নেই।", "Not enough credits.",
                            status=402, code="camera_cap")
        olang = getattr(owner, "language", None) or "bn"
        name = str(request.data.get("name") or "").strip()[:120] or (
            "Phone camera" if olang == "en" else "ফোন ক্যামেরা")
        model = str(request.data.get("model") or "")[:60]
        from datetime import timedelta
        cam = ShopCamera.objects.create(
            site=site, name=name, kind="shopbox", vendor="phone",
            zone_config=WM.default_zone_config(site.kind),
            source={"pair_sha": sha, "viewers_live": False, "model": model,
                    "paired_at": now.isoformat()},
            billed_until=(now + timedelta(days=SV.BILLING_PERIOD_DAYS)
                          if charged else None))
        _notify(site, cam, "paired")
        return Response({"ok": True, "camera_token": cam.camera_token,
                         "camera": {"id": cam.id, "name": cam.name},
                         "site": {"id": site.id, "name": site.name},
                         "charged_credits": charged}, status=201)


class PhoneCamUnbindView(APIView):
    """POST shop/phonecam/unbind (X-Shop-Token = the camera token) — the
    camera phone removes itself (same effect as the owner's camera delete:
    the camera row and its own alerts go; the plan slot is free again)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        lang = req_lang(request)
        site, cam = SV._resolve_device_site(request)
        if site is None or not is_phone_cam(cam):
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        _notify(site, cam, "unbound")
        cid = cam.id
        cam.delete()
        return Response({"ok": True, "deleted": cid})


class PhoneCamSettingsView(APIView):
    """PATCH shop/phonecam/<id> {viewers_live, name} (owner) — whether the
    family viewers may open live view of this phone camera."""

    def patch(self, request, pk):
        from .models import ShopCamera
        lang = req_lang(request)
        if not flag_on(request.user, request):
            return _flag_off(lang)
        cam = ShopCamera.objects.filter(pk=pk, site__owner=request.user,
                                        vendor="phone").first()
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        fields = []
        if "viewers_live" in request.data:
            src = dict(cam.source or {})
            src["viewers_live"] = SV._coerce_bool(request.data.get("viewers_live"))
            cam.source = src
            fields.append("source")
        if "name" in request.data:
            cam.name = str(request.data.get("name") or "").strip()[:120]
            fields.append("name")
        if fields:
            cam.save(update_fields=fields)
        return Response(_phone_cam_row(cam))


# ---------------------------------------------------------------- health
def note_health(cam, raw, now):
    """Heartbeat hook (shop_ops_views.ShopHeartbeatView): store the phone
    camera's battery/view state and push the warnings that are due. Never
    raises."""
    try:
        if not is_phone_cam(cam):
            return []
        h = PC.clean_health(raw)
        if h is None:
            return []
        from .models import ShopCamera
        cam.refresh_from_db(fields=["source", "name"])
        src = dict(cam.source or {})
        old = src.get("health") if isinstance(src.get("health"), dict) else {}
        kinds, warned = PC.health_warnings(h, old.get("warned"), now.timestamp())
        src["health"] = dict(h, warned=warned, at=now.isoformat())
        ShopCamera.objects.filter(pk=cam.pk).update(source=src)
        cam.source = src
        for k in kinds:
            _notify(cam.site, cam, k, health=h)
        return kinds
    except Exception:
        log.exception("phonecam health failed")
        return []


_EVENT_TEXT = {
    "paired": ("ফোন ক্যামেরা যুক্ত হয়েছে", "Phone camera added",
               "%s এখন আপনার ক্যামেরা। চালু করতে ওই ফোনে \"চালু করুন\" চাপুন।",
               "%s is now your camera. Tap \"Start\" on that phone to start watching."),
    "unbound": ("ফোন ক্যামেরা সরানো হয়েছে", "Phone camera removed",
                "%s আর ক্যামেরা নয় (ওই ফোন থেকেই সরানো হয়েছে)।",
                "%s is no longer a camera (it was removed on that phone)."),
}


def _recipients(site, cam=None):
    out = [site.owner]
    try:
        out += [v.user for v in site.viewers.select_related("user")]
    except Exception:
        pass
    return out


def _notify(site, cam, kind, health=None):
    """Owner (+ family viewers for health warnings): an in-app feed row and a
    push, in each person's language. Best-effort."""
    name = cam.name or "Phone camera"
    if kind in PC.WARN_TEXT:
        tbn, ten, bbn, ben = PC.warning_text(kind, name, health)
        people = _recipients(site, cam)
    else:
        a, b, c, d = _EVENT_TEXT[kind]
        tbn, ten, bbn, ben = a, b, c % name, d % name
        people = [site.owner]
    meta = {"source": "phonecam", "kind": kind, "site_id": site.id,
            "camera_id": cam.id}
    for user in people:
        try:
            from .models import NotifEvent
            NotifEvent.objects.create(
                user=user, type="business", title_bn=tbn[:200], title_en=ten[:200],
                body_bn=bbn, body_en=ben, route="business", meta=meta)
        except Exception:
            pass
        try:
            from . import push
            push.safe_push(user, "shop_alert", tbn, ten, bbn, ben,
                           data=dict(meta, route="watchman", camera_name=name),
                           high_priority=kind in ("unplugged", "dark"))
        except Exception:
            pass
