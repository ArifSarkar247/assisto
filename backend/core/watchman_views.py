"""
watchman_views.py — Home & shop watchman, phase 1 (cctv1). Builds on the
Shop Box / CCTV backend (shop_views.py, shop_ops_views.py) and is NOT tied to
the POS: a personal user protects a HOME, a Business user a SHOP.

Behind the server feature flag `home_watchman` (default ON: a launch feature, owner 27 Oct) (core.feature_flags, when that
module is deployed): owner endpoints answer 403 `feature_off` while hidden.
Device (gateway) endpoints are never flag-gated — a paired gateway keeps
working whatever the app shows.

OWNER (Token auth)
  GET    shop/watchman                    overview: sites I own or view, cameras,
                                          gateway online / "offline since", limits
  POST   shop/watchman/setup              first-time wizard: {kind, gateway, name}
  POST   shop/cameras/<id>/check          queue a compatibility check on the
                                          gateway (secret handed over ONCE)
  POST   shop/sites/<id>/discover         queue an ONVIF LAN scan on the gateway
  GET    shop/gateway/tasks/<id>/status   result card (never a secret)
  PUT    shop/cameras/<id>/zones          zones v2 + schedule + sensitivity + quiet
  GET    shop/cameras/<id>/preview        signed link to the check still
  POST   shop/cameras/<id>/imou           link an Imou camera's cloud alarms
  GET/POST shop/sites/<id>/viewers        family viewers (read-only)
  DELETE shop/sites/<id>/viewers/<uid>    remove a viewer (or leave as viewer)
DEVICE (site enrollment token, X-Shop-Token)
  GET    shop/gateway/tasks               hand out pending tasks (wipes secrets)
  POST   shop/gateway/tasks/<id>/result   check / scan result (+ one JPEG)
VENDOR CLOUD
  POST   shop/imou/callback/<token>       Imou Open Platform alarm push

NO VIDEO EVER: every file path here goes through shop_views.clean_snapshot().
"""
import json
import logging
from datetime import timedelta

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from . import shop_views as SV
from .logic import watchman as WM

log = logging.getLogger("assisto.shop")

FLAG = "home_watchman"
TASK_PENDING_TTL_S = 10 * 60      # a task nobody picked up expires (secret wiped)
TASK_RUNNING_TTL_S = 5 * 60       # a gateway that never answered
MAX_VIEWERS = 5
STEP_KEYS = ("reachable", "auth", "stream", "snapshot", "events")


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def feature_on(request):
    """The server flag (owner/staff + testers always see it). Until the
    feature-flag module is deployed, the registry default applies (on)."""
    try:
        from . import feature_flags as FF
    except ImportError:
        return True
    try:
        from .i18n import is_play_flavour
        return FF.is_on(FLAG, request.user, is_play_flavour(request))
    except Exception:
        return True


class _OwnerBase(APIView):
    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not feature_on(request):
            from rest_framework.exceptions import PermissionDenied
            lang = req_lang(request)
            raise PermissionDenied(detail={
                "error": "feature_off",
                "detail": pick(lang, "এই ফিচারটি এখনো চালু হয়নি।",
                               "This feature is not available yet.")})


# ---------------------------------------------------------------- helpers
def _plan(user):
    from . import plans
    try:
        return plans.effective_plan(user)
    except Exception:
        return "free"


def _can_shop(user):
    # existing gating: shop protection is a Business feature; a home is not
    return _plan(user) in ("business",)


def _limits(user):
    return {"included_cameras": SV._included_cameras(user),
            "credits_per_extra_camera": SV._extra_camera_credits(),
            "period_days": SV.BILLING_PERIOD_DAYS,
            "daily_alert_cap": SV.watchman_cfg("watchman_daily_alert_cap", 30),
            "group_min": SV.watchman_cfg("watchman_group_min", 10),
            "checks_per_hour": SV.watchman_cfg("watchman_tasks_per_hour", 20),
            "snapshot_kb": SV.snapshot_limit_bytes() // 1024,
            "retention_max_days": 30}


def imou_cloud_on():
    try:
        from . import integrations as I
        return I.is_enabled("imou")
    except Exception:
        return False


def _gateway_state(site, now):
    online = SV.is_online(site.last_seen, now)
    return {"online": online, "last_seen": SV._iso(site.last_seen),
            "offline_since": None if online else SV._iso(site.last_seen),
            "never_seen": site.last_seen is None}


def _site_overview(site, role, now):
    row = SV._site_row(site, reveal_token=(role == "owner"))
    cams = []
    for c in site.cameras.all():
        cr = SV._camera_row(c)
        if role != "owner":
            # viewers see status + names only
            cr = {k: cr[k] for k in ("id", "name", "vendor", "online",
                                     "last_seen", "enabled")}
        cams.append(cr)
    start = timezone.localtime(now).replace(hour=0, minute=0, second=0,
                                            microsecond=0)
    row.update({
        "role": role, "cameras_list": cams,
        "gateway_state": _gateway_state(site, now),
        "open_alerts": site.events.filter(status="open", pending=False).count(),
        "today_alerts": site.events.filter(created__gte=start).count(),
        "held_today": SV.held_today(site, now),
    })
    if role != "owner":
        row.pop("enrollment_token", None)
        row["owner_name"] = getattr(site.owner, "name", "") or ""
    return row


def employee_notice(lang, place=""):
    """The shareable CCTV notice (staff / household helpers / visitors)."""
    place = (place or "").strip()[:80]
    bn = ("বিজ্ঞপ্তি: এই %s সিসিটিভি ক্যামেরা দিয়ে নজরে রাখা হয়। ক্যামেরা শুধু "
          "নিরাপত্তার জন্য — কোনো কিছু সন্দেহজনক মনে হলে মালিকের ফোনে একটি ছবি "
          "যায়, যা %s দিনের মধ্যে মুছে যায়। কোনো ভিডিও আমাদের সার্ভারে রাখা হয় না, "
          "কোনো শব্দ রেকর্ড হয় না, আর মুখ চেনার কোনো ব্যবস্থা নেই। প্রশ্ন থাকলে "
          "মালিকের সাথে কথা বলুন।")
    en = ("Notice: this %s is watched by CCTV cameras. They are used only for "
          "safety — if something looks unusual, one still photo goes to the "
          "owner's phone and is deleted within %s days. No video is kept on any "
          "server, no sound is recorded, and there is no face recognition. "
          "Please talk to the owner if you have any questions.")
    return {"bn": bn % (place or "জায়গাটি", "৩০"),
            "en": en % (place or "place", "30")}


def pending_task_count(site, now=None):
    from .models import ShopGatewayTask
    now = now or timezone.now()
    _expire_tasks(site, now)
    return ShopGatewayTask.objects.filter(site=site, status="pending").count()


def _expire_tasks(site, now):
    """Expire stale tasks and WIPE any secret they still hold."""
    from .models import ShopGatewayTask
    stale = ShopGatewayTask.objects.filter(
        site=site, status="pending",
        created__lt=now - timedelta(seconds=TASK_PENDING_TTL_S))
    stale_run = ShopGatewayTask.objects.filter(
        site=site, status="running",
        picked_at__lt=now - timedelta(seconds=TASK_RUNNING_TTL_S))
    for t in list(stale) + list(stale_run):
        req = dict(t.request or {})
        req.pop("secret", None)
        req.pop("rtsp_url", None)
        t.request = req
        t.status = "expired"
        t.done_at = now
        t.result = t.result or {"ok": False, "code": "gateway_no_answer"}
        t.save(update_fields=["request", "status", "done_at", "result"])


def _task_row(t, now=None):
    """Owner view of a task — NEVER the secret."""
    now = now or timezone.now()
    req = {k: v for k, v in (t.request or {}).items()
           if k not in ("secret", "rtsp_url")}
    return {"id": t.id, "action": t.action, "status": t.status,
            "camera": t.camera_id, "request": req, "result": t.result or {},
            "created": t.created.isoformat(), "done_at": SV._iso(t.done_at),
            "gateway": _gateway_state(t.site, now)}


def _rate_ok(site, now):
    from .models import ShopGatewayTask
    cap = SV.watchman_cfg("watchman_tasks_per_hour", 20)
    n = ShopGatewayTask.objects.filter(
        site=site, created__gte=now - timedelta(hours=1)).count()
    return n < cap


def _rate_err(lang):
    return _err(lang, "এক ঘণ্টায় অনেকবার পরীক্ষা হয়েছে — একটু পরে আবার চেষ্টা করুন।",
                "Too many checks this hour — please try again a little later.",
                status=429, code="rate_limited")


def _owner_cam(request, pk):
    from .models import ShopCamera
    try:
        pk = int(pk)
    except (TypeError, ValueError):
        return None
    return ShopCamera.objects.filter(pk=pk, site__owner=request.user).select_related(
        "site").first()


# ======================================================== OVERVIEW + SETUP
class WatchmanOverviewView(_OwnerBase):
    def get(self, request):
        from .models import ShopSite
        lang = req_lang(request)
        now = timezone.now()
        own = list(ShopSite.objects.filter(owner=request.user))
        viewed = list(ShopSite.objects.filter(viewers__user=request.user)
                      .exclude(owner=request.user).select_related("owner"))
        sites = [_site_overview(s, "owner", now) for s in own] + \
                [_site_overview(s, "viewer", now) for s in viewed]
        return Response({
            "feature_on": True, "sites": sites,
            "setup_needed": not own and not viewed,
            "plan": _plan(request.user), "can_shop": _can_shop(request.user),
            "credits": int(request.user.ai_credits or 0),
            "limits": _limits(request.user),
            "imou_cloud": imou_cloud_on(),
            "notice": employee_notice(lang),
        })


class WatchmanSetupView(_OwnerBase):
    """POST {kind: home|shop, gateway: phone|shopbox|pc, name} — creates the
    site (short default snapshot retention: 3 days) and answers what to do
    next on the gateway. A shop needs the Business plan (existing gating)."""

    def post(self, request):
        from .models import ShopSite
        lang = req_lang(request)
        kind = request.data.get("kind")
        gateway = request.data.get("gateway")
        if kind not in ("home", "shop"):
            return _err(lang, "বাড়ি না দোকান — একটি বাছুন।",
                        "Choose home or shop.", status=422, code="bad_kind")
        if gateway not in ("phone", "shopbox", "pc"):
            return _err(lang, "গেটওয়ে বাছুন।", "Choose a gateway.",
                        status=422, code="bad_gateway")
        if kind == "shop" and not _can_shop(request.user):
            return _err(lang, "দোকান পাহারা Business প্ল্যানে আছে। বাড়ির জন্য যেকোনো প্ল্যানে চলবে।",
                        "Shop protection is part of the Business plan. A home works on any plan.",
                        status=402, code="plan_required", plan_needed="business")
        if ShopSite.objects.filter(owner=request.user).count() >= 10:
            return _err(lang, "সর্বোচ্চ ১০টি জায়গা যোগ করা যায়।",
                        "You can add up to 10 places.", status=409,
                        code="too_many_sites")
        name = (request.data.get("name") or "").strip()[:120] or pick(
            lang, "আমার বাড়ি" if kind == "home" else "আমার দোকান",
            "My home" if kind == "home" else "My shop")
        s = ShopSite.objects.create(owner=request.user, name=name, kind=kind,
                                    gateway=gateway, snapshot_retention_days=3,
                                    pos_link=(kind == "shop"))
        out = _site_overview(s, "owner", timezone.now())
        out["next"] = {"phone": "pair_phone", "shopbox": "pair_pc",
                       "pc": "pair_pc"}[gateway]
        return Response(out, status=201)


# ======================================================== GATEWAY TASKS (owner)
class CameraCheckView(_OwnerBase):
    """POST shop/cameras/<id>/check {secret, username?, host, port?, channel?,
    stream?, onvif_port?, rtsp_url? (vendor rtsp)} — the gateway runs the
    compatibility check. The secret rides in the task ONLY until the gateway
    picks it up (wiped at hand-out / expiry); the camera row keeps none."""

    def post(self, request, pk):
        from .models import ShopGatewayTask
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if cam.vendor in ("", "phone"):
            return _err(lang, "এই ক্যামেরাটি ফোনের নিজের ক্যামেরা — পরীক্ষা লাগবে না।",
                        "This is the phone's own camera — no check needed.",
                        status=409, code="no_check_needed")
        if cam.site.gateway == "phone":
            return _err(lang, "পুরনো ফোন গেটওয়ে এখনো বাড়ির নেটওয়ার্কের ক্যামেরা পড়তে পারে না — "
                              "Shop Box PC বা কম্পিউটার গেটওয়ে লাগবে।",
                        "The old-phone gateway can't read network cameras yet — "
                        "use a Shop Box PC or computer gateway.",
                        status=409, code="gateway_cannot_check")
        now = timezone.now()
        if not _rate_ok(cam.site, now):
            return _rate_err(lang)
        d = request.data
        src = SV.clean_source(dict(cam.source or {}, **{
            k: d.get(k) for k in ("host", "port", "channel", "stream",
                                  "onvif_port", "username", "rtsp_path")
            if d.get(k) not in (None, "")}))
        secret = str(d.get("secret") or "")[:128]
        rtsp_url = str(d.get("rtsp_url") or "")[:400] if cam.vendor == "rtsp" else ""
        if cam.vendor == "rtsp":
            if not rtsp_url.lower().startswith(("rtsp://", "rtsps://")):
                return _err(lang, "rtsp:// দিয়ে শুরু পুরো ঠিকানা দিন।",
                            "Enter the full address starting with rtsp://.",
                            status=422, code="bad_rtsp_url")
        elif not src.get("host"):
            return _err(lang, "ক্যামেরার IP ঠিকানা দিন (যেমন 192.168.1.20)।",
                        "Enter the camera's IP address (e.g. 192.168.1.20).",
                        status=422, code="host_required")
        if cam.vendor in ("imou", "ezviz") and not secret:
            return _err(lang, "ক্যামেরার নিচের লেবেলে লেখা নিরাপত্তা কোড (safety/verification code) দিন।",
                        "Enter the safety / verification code printed on the camera's label.",
                        status=422, code="code_required")
        cam.source = src
        cam.save(update_fields=["source"])
        req = dict(src, vendor=cam.vendor, name=cam.name or "")
        if secret:
            req["secret"] = secret
        if rtsp_url:
            req["rtsp_url"] = rtsp_url
        # one open check per camera: replace an older pending one
        for old in ShopGatewayTask.objects.filter(camera=cam, status="pending"):
            old.request = {k: v for k, v in old.request.items()
                           if k not in ("secret", "rtsp_url")}
            old.status = "expired"
            old.done_at = now
            old.result = {"ok": False, "code": "replaced"}
            old.save(update_fields=["request", "status", "done_at", "result"])
        t = ShopGatewayTask.objects.create(site=cam.site, camera=cam,
                                           action="check", request=req)
        return Response(_task_row(t, now), status=201)


class SiteDiscoverView(_OwnerBase):
    def post(self, request, pk):
        from .models import ShopGatewayTask
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if s.gateway == "phone":
            return _err(lang, "পুরনো ফোন গেটওয়ে এখনো নেটওয়ার্কে ক্যামেরা খুঁজতে পারে না।",
                        "The old-phone gateway can't scan the network yet.",
                        status=409, code="gateway_cannot_check")
        now = timezone.now()
        if not _rate_ok(s, now):
            return _rate_err(lang)
        t = ShopGatewayTask.objects.create(site=s, action="discover",
                                           request={"timeout_s": 4})
        return Response(_task_row(t, now), status=201)


class TaskStatusView(_OwnerBase):
    def get(self, request, pk):
        from .models import ShopGatewayTask
        lang = req_lang(request)
        t = ShopGatewayTask.objects.filter(pk=pk, site__owner=request.user).select_related(
            "site").first()
        if t is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()
        _expire_tasks(t.site, now)
        t.refresh_from_db()
        return Response(_task_row(t, now))


# ======================================================== ZONES
class CameraZonesView(_OwnerBase):
    """PUT shop/cameras/<id>/zones — zones v2 (drawn on the snapshot),
    schedule, sensitivity, quiet hours. Saved to ShopCamera.zone_config; the
    gateway pulls it with shop/config (its config_version changes)."""

    def get(self, request, pk):
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        v2 = WM.zone_v2(cam.zone_config) or WM.default_zone_config(cam.site.kind)
        return Response({"camera": cam.id, "zone_config": v2,
                         "tuning": WM.tuning_of(cam.tuning)})

    def put(self, request, pk):
        from .shop_ops_views import device_config
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        raw = request.data.get("zone_config", request.data)
        try:
            clean = WM.normalize_zone_config(raw, legacy=cam.zone_config)
        except WM.ZoneError as e:
            bn, en = ZONE_ERRORS.get(e.code, ZONE_ERRORS["bad_zone"])
            return _err(lang, bn, en, status=422, code=e.code)
        cam.zone_config = clean
        cam.save(update_fields=["zone_config"])
        return Response({"camera": cam.id, "zone_config": clean,
                         "config_version": device_config(cam.site)["version"]})

    post = put     # the app's JSON client speaks POST


ZONE_ERRORS = {
    "bad_zone": ("জোনের তথ্য ঠিক নেই।", "The zone data is not valid."),
    "too_many_zones": ("সর্বোচ্চ ৮টি জোন আঁকা যায়।", "You can draw up to 8 zones."),
    "too_many_points": ("একটি জোনে সর্বোচ্চ ১৬টি বিন্দু।", "A zone can have up to 16 points."),
    "bad_zone_type": ("জোনের ধরন ঠিক নেই।", "Unknown zone type."),
    "bad_point": ("একটি বিন্দু ছবির বাইরে।", "A point is outside the picture."),
    "line_needs_two_points": ("প্রবেশ-রেখায় ঠিক ২টি আলাদা বিন্দু লাগে।",
                              "An entry line needs exactly 2 different points."),
    "zone_needs_three_points": ("জোনে অন্তত ৩টি বিন্দু লাগে (খুব ছোট নয়)।",
                                "A zone needs at least 3 points (not too small)."),
    "bad_schedule": ("পাহারার সময় ঠিক নেই — দিন ও শুরু/শেষ সময় দিন।",
                     "The guard schedule is not valid — pick days and start/end times."),
    "bad_sensitivity": ("সংবেদনশীলতা ঠিক নেই।", "Unknown sensitivity."),
    "bad_quiet_hours": ("নীরব সময় ঠিক নেই।", "The quiet hours are not valid."),
}


class CameraPreviewView(_OwnerBase):
    """GET — a signed link to the camera's check still (else its latest event
    snapshot), for drawing zones. 404 `no_preview` when none is kept."""

    def get(self, request, pk):
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        url, src = None, None
        if cam.preview:
            url, src = cam.preview.url, "check"
        else:
            ev = cam.events.exclude(snapshot="").exclude(snapshot=None).first()
            if ev is not None:
                url, src = ev.snapshot.url, "event"
        if not url:
            return _err(lang, "এখনো কোনো ছবি নেই — আগে ক্যামেরা পরীক্ষা চালান।",
                        "No picture yet — run the camera check first.",
                        status=404, code="no_preview")
        return Response({"url": request.build_absolute_uri(url), "source": src})


# ======================================================== IMOU CLOUD
class CameraImouView(_OwnerBase):
    """POST {device_serial, safety_code, channel?} — link an Imou camera's own
    alarms through the Imou Open Platform (key-gated). The safety code is
    used for this one call and NEVER stored."""

    def post(self, request, pk):
        from .logic import imou as IM
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if cam.vendor != "imou":
            return _err(lang, "এটি Imou ক্যামেরা নয়।", "This is not an Imou camera.",
                        status=409, code="not_imou")
        client = IM.ImouClient.from_integration() if imou_cloud_on() else None
        if client is None:
            return _err(lang, "Imou ক্লাউড সতর্কতা এখনো চালু হয়নি — ক্যামেরা গেটওয়ে দিয়ে ঠিকই চলবে।",
                        "Imou cloud alarms are not switched on yet — the camera still "
                        "works through your gateway.", status=503, code="imou_not_configured")
        serial = str(request.data.get("device_serial") or "").strip().upper()[:40]
        code = str(request.data.get("safety_code") or "").strip()[:32]
        try:
            ch = max(0, min(63, int(request.data.get("channel") or 0)))
        except (TypeError, ValueError):
            ch = 0
        if not serial or not serial.replace("-", "").isalnum():
            return _err(lang, "ক্যামেরার লেবেলের সিরিয়াল নম্বর (SN) দিন।",
                        "Enter the serial number (SN) from the camera's label.",
                        status=422, code="serial_required")
        if not code:
            return _err(lang, "লেবেলের নিরাপত্তা কোড (Safety Code) দিন।",
                        "Enter the Safety Code from the camera's label.",
                        status=422, code="code_required")
        try:
            try:
                client.bind_device(serial, code)
            except IM.ImouError as e:
                if e.code == "network":
                    raise
                # maybe it is already in this account: proven only if the
                # account can query it — otherwise the bind error stands.
                try:
                    client.device_online(serial)
                except IM.ImouError:
                    raise e
            client.set_callback(imou_callback_url(client.app_id))
        except IM.ImouError as e:
            bn, en = IMOU_ERRORS["network" if e.code == "network" else "_"]
            return _err(lang, bn, en, status=502, code="imou_error",
                        imou_code=e.code, imou_msg=e.msg)
        from .models import ShopCamera
        if ShopCamera.objects.filter(vendor_ref="%s:%d" % (serial, ch)).exclude(
                pk=cam.pk).exists():
            return _err(lang, "এই Imou ক্যামেরা অন্য একটি অ্যাকাউন্টে যুক্ত আছে।",
                        "This Imou camera is already linked to another account.",
                        status=409, code="imou_taken")
        cam.vendor_ref = "%s:%d" % (serial, ch)
        src = dict(cam.source or {}, device_serial=serial)
        cam.source = SV.clean_source(src)
        cam.save(update_fields=["vendor_ref", "source"])
        return Response({"ok": True, "camera": SV._camera_row(cam)})


IMOU_ERRORS = {
    "network": ("Imou সার্ভারে পৌঁছানো যায়নি — একটু পরে আবার চেষ্টা করুন।",
                "Could not reach Imou — please try again shortly."),
    "_": ("Imou যুক্ত করা যায়নি। সিরিয়াল (SN) ও Safety Code আবার মিলিয়ে দেখুন; "
          "ক্যামেরাটি অন্য Imou অ্যাকাউন্টে থাকলে Imou Life অ্যাপ থেকে আগে সরান। "
          "ক্যামেরা গেটওয়ে দিয়ে ঠিকই চলবে।",
          "Could not link Imou. Check the serial (SN) and Safety Code; if the camera "
          "is in another Imou account, remove it in the Imou Life app first. The "
          "camera still works through your gateway."),
}


def imou_callback_url(app_id):
    from .logic import imou as IM
    tok = IM.callback_token(app_id, settings.SECRET_KEY)
    return "%s/api/v1/shop/imou/callback/%s" % (
        getattr(settings, "ASSISTO_BASE_URL", "").rstrip("/"), tok)


class ImouCallbackView(APIView):
    """POST shop/imou/callback/<token> — the Imou cloud pushes alarms here.
    Always answers 200 fast (except a wrong token → 404). One still per alarm
    (downloaded from an allowed Imou host, shrunk); never video."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request, token):
        import hmac
        from .logic import imou as IM
        from .models import ShopCamera
        from . import integrations as I
        cfg = I.get("imou") if imou_cloud_on() else {}
        app_id = cfg.get("app_id") or ""
        expect = IM.callback_token(app_id, settings.SECRET_KEY) if app_id else ""
        if not expect or not hmac.compare_digest(expect, str(token)):
            return Response({"ok": False}, status=404)
        try:
            body = json.loads(request.body[:256 * 1024] or b"{}")
        except ValueError:
            return Response({"ok": True, "ignored": "bad_json"})
        msgs = body if isinstance(body, list) else [body]
        out = []
        now = timezone.now()
        for m in msgs[:20]:
            a = IM.parse_alarm(m)
            if a is None:
                out.append({"ignored": "not_alarm"})
                continue
            ref = "%s:%s" % (a["device_id"].upper(), a["channel"])
            cam = ShopCamera.objects.filter(vendor_ref=ref, enabled=True).select_related(
                "site").first()
            if cam is None:
                out.append({"ignored": "unknown_camera"})
                continue
            ShopCamera.objects.filter(pk=cam.pk).update(last_seen=now)
            snap = None
            raw = None
            if a["pic"] and cam.site.snapshot_retention_days > 0:
                raw = IM.fetch_snapshot(a["pic"])
                if raw and not SV.looks_like_video(raw):
                    snap = SV._small_jpeg(raw, "imou%d.jpg" % cam.id)
            etype, sig = SV.vendor_alarm_event(
                cam, raw if snap is not None else None,
                {"human": a["human"], "vendor": "imou",
                 "alarm_type": "human" if a["human"] else "motion"}, now)
            decision, ev = SV._ingest_event(
                cam.site, cam, {"type": etype, "at": now.timestamp(),
                                "signals": sig}, now, snap)
            out.append({"raised": ev is not None,
                        "grouped": bool(decision.get("grouped"))})
        return Response({"ok": True, "events": out})


# ======================================================== VIEWERS
class SiteViewersView(_OwnerBase):
    def _site(self, request, pk):
        return SV._owner_site(request, pk)

    def get(self, request, pk):
        lang = req_lang(request)
        s = self._site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response({"viewers": [_viewer_row(v) for v in
                                     s.viewers.select_related("user")],
                         "max": MAX_VIEWERS})

    def post(self, request, pk):
        from .models import ShopSiteViewer
        from .phone import find_user, mask
        lang = req_lang(request)
        s = self._site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        u = find_user(request.data.get("phone"))
        if u is None or not u.is_active:
            return _err(lang, "এই নম্বরে কোনো Assisto অ্যাকাউন্ট পাওয়া যায়নি — তাঁকে আগে Assisto খুলতে বলুন।",
                        "No Assisto account with this number — ask them to open Assisto first.",
                        status=404, code="user_not_found")
        if u.pk == s.owner_id:
            return _err(lang, "আপনি নিজেই মালিক।", "You are the owner already.",
                        status=409, code="is_owner")
        if s.viewers.count() >= MAX_VIEWERS:
            return _err(lang, "সর্বোচ্চ ৫ জন দেখতে পারেন।", "Up to 5 people can view.",
                        status=409, code="too_many_viewers")
        v, created = ShopSiteViewer.objects.get_or_create(site=s, user=u)
        if created:
            try:
                from . import push
                push.safe_push(
                    u, "shop_alert",
                    "%s আপনাকে ক্যামেরা সতর্কতা দেখার অনুমতি দিয়েছেন" % (s.owner.name or "একজন"),
                    "%s shared camera alerts with you" % (s.owner.name or "Someone"),
                    s.name, s.name, data={"site_id": s.id, "route": "watchman"})
            except Exception:
                pass
        return Response(_viewer_row(v), status=201 if created else 200)


class SiteViewerDeleteView(APIView):
    """DELETE — the owner removes a viewer, or a viewer leaves (uid = self)."""

    def delete(self, request, pk, uid):
        from .models import ShopSiteViewer
        lang = req_lang(request)
        qs = ShopSiteViewer.objects.filter(site_id=pk, user_id=uid)
        if not (qs.filter(site__owner=request.user).exists() or
                (int(uid) == request.user.pk and qs.exists())):
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        qs.delete()
        return Response({"ok": True})


def _viewer_row(v):
    from .phone import mask
    return {"user_id": v.user_id, "name": getattr(v.user, "name", "") or "",
            "phone": mask(v.user.phone or ""), "since": v.created.isoformat()}


# ======================================================== DEVICE (gateway)
def _gateway_site(request):
    """The site for a GATEWAY call — only the SITE enrollment token counts (a
    single camera's token, e.g. an old phone in Shop Box mode, may never pull
    another camera's secret)."""
    site, _cam = SV._resolve_device_site(request)
    if site is None:
        return None
    tok = str((request.data.get("site_token") if hasattr(request.data, "get") else "")
              or request.META.get("HTTP_X_SHOP_TOKEN") or "").strip()
    import hmac
    return site if hmac.compare_digest(tok, site.enrollment_token) else None


class GatewayTasksView(APIView):
    """GET shop/gateway/tasks (X-Shop-Token = SITE token) — hands out pending
    tasks and WIPES the camera secret from our DB in the same transaction."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from .models import ShopGatewayTask
        lang = req_lang(request)
        site = _gateway_site(request)
        if site is None:
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")
        now = timezone.now()
        SV._touch_seen(site, None, now)
        _expire_tasks(site, now)
        out = []
        with transaction.atomic():
            rows = list(ShopGatewayTask.objects.select_for_update().filter(
                site=site, status="pending").order_by("created")[:5])
            for t in rows:
                out.append({"id": t.id, "action": t.action,
                            "camera_id": t.camera_id, "request": dict(t.request)})
                t.request = {k: v for k, v in (t.request or {}).items()
                             if k not in ("secret", "rtsp_url")}
                t.status = "running"
                t.picked_at = now
                t.save(update_fields=["request", "status", "picked_at"])
        return Response({"tasks": out})


def _clean_steps(steps):
    out = []
    if not isinstance(steps, list):
        return out
    for st in steps[:8]:
        if not isinstance(st, dict) or st.get("key") not in STEP_KEYS:
            continue
        ok = st.get("ok")
        out.append({"key": st["key"],
                    "ok": ok if ok in (True, False, None) else None,
                    "code": str(st.get("code") or "")[:32],
                    "detail": _redact(str(st.get("detail") or ""))[:160]})
    return out


def _redact(text):
    import re
    return re.sub(r"(rtsps?|https?)://[^/@\s]+@", r"\1://***@", text)


def _clean_info(info):
    if not isinstance(info, dict):
        return {}
    out = {}
    for k in ("width", "height"):
        try:
            n = int(info.get(k))
            if 0 < n <= 10000:
                out[k] = n
        except (TypeError, ValueError):
            pass
    try:
        fps = float(info.get("fps"))
        if 0 < fps <= 240:
            out["fps"] = round(fps, 1)
    except (TypeError, ValueError):
        pass
    for k in ("codec", "manufacturer", "model"):
        if info.get(k):
            out[k] = str(info[k])[:40]
    for k in ("onvif", "events_supported"):
        if info.get(k) in (True, False):
            out[k] = info[k]
    path = str(info.get("rtsp_path") or "")
    if path and "@" not in path and "://" not in path:
        out["rtsp_path"] = path[:200]
    return out


def _clean_discovered(rows):
    import re
    out = []
    if not isinstance(rows, list):
        return out
    for r in rows[:32]:
        if not isinstance(r, dict):
            continue
        host = str(r.get("host") or "")[:64]
        if not re.fullmatch(r"[A-Za-z0-9.\-:\[\]]+", host or "-"):
            continue
        out.append({"host": host,
                    "xaddr": _redact(str(r.get("xaddr") or ""))[:200],
                    "manufacturer": str(r.get("manufacturer") or "")[:40] or None,
                    "model": str(r.get("model") or "")[:40] or None,
                    "name": str(r.get("name") or "")[:60] or None})
    return out


class GatewayTaskResultView(APIView):
    """POST shop/gateway/tasks/<id>/result — multipart `result` (JSON) + at
    most one `snapshot` (still image only; a video is refused 415)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request, pk):
        from .models import ShopGatewayTask
        lang = req_lang(request)
        site = _gateway_site(request)
        if site is None:
            return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                        status=401, code="bad_token")
        t = ShopGatewayTask.objects.filter(pk=pk, site=site).select_related(
            "camera").first()
        if t is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if t.status not in ("running", "pending"):
            return _err(lang, "এই কাজটি শেষ হয়ে গেছে।", "This task is closed.",
                        status=410, code="task_closed")
        for name in request.FILES:
            if name != "snapshot":
                return SV._snapshot_refused(lang, "extra_file")
        snap = None
        if request.FILES.get("snapshot") is not None:
            snap, why = SV.clean_snapshot(request.FILES["snapshot"], "preview.jpg")
            if snap is None:
                return SV._snapshot_refused(lang, why)
        raw = request.data.get("result")
        if isinstance(raw, str):
            try:
                raw = json.loads(raw[:64 * 1024])
            except ValueError:
                raw = None
        if not isinstance(raw, dict):
            return _err(lang, "ফলাফল ঠিক নেই।", "Invalid result.", status=422,
                        code="bad_result")
        now = timezone.now()
        SV._touch_seen(site, None, now)
        if t.action == "check":
            res = {"ok": bool(raw.get("ok")), "steps": _clean_steps(raw.get("steps")),
                   "info": _clean_info(raw.get("info")), "at": now.isoformat()}
        elif t.action == "siren":
            # cctvx: what the camera answered (no secrets, short codes only)
            import re as _re
            res = {"ok": bool(raw.get("ok")),
                   "code": _re.sub(r"[^a-z0-9_]", "", str(raw.get("code") or "").lower())[:32],
                   "method": str(raw.get("method") or "")[:24],
                   "seconds": max(0, min(60, int(raw.get("seconds") or 0)))
                   if str(raw.get("seconds") or "0").isdigit() else 0,
                   "at": now.isoformat()}
        else:
            res = {"ok": bool(raw.get("ok", True)),
                   "discovered": _clean_discovered(raw.get("discovered")),
                   "at": now.isoformat()}
        t.result = res
        t.status = "done"
        t.done_at = now
        t.request = {k: v for k, v in (t.request or {}).items()
                     if k not in ("secret", "rtsp_url")}
        t.save(update_fields=["result", "status", "done_at", "request"])
        cam = t.camera
        if cam is not None and t.action == "check":
            fields = ["compat"]
            cam.compat = res
            if res["info"].get("rtsp_path"):
                cam.source = SV.clean_source(dict(cam.source or {},
                                                  rtsp_path=res["info"]["rtsp_path"]))
                fields.append("source")
            if snap is not None and site.snapshot_retention_days > 0:
                if cam.preview:
                    try:
                        cam.preview.delete(save=False)
                    except Exception:
                        pass
                cam.preview.save("cam%d.jpg" % cam.id, snap, save=False)
                fields.append("preview")
            cam.save(update_fields=fields)
        return Response({"ok": True, "task": t.id, "status": t.status})
