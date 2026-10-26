"""
shop_ops_views.py — CCTV Part 4, round 2 (a2-cctv): camera settings, device
heartbeat/config/pair, Assisto-POS mirroring + void/discount spikes, the
end-of-day cash check, and WebRTC live-view SIGNALING.

Same two auth worlds as shop_views.py:
  * DEVICE calls (heartbeat, config, pair/check, live pending/signal/end) use
    the site enrollment token or a camera token (body, or `X-Shop-Token`
    header) — never a user login, and they only ever see their own site.
  * OWNER calls use normal Token auth and are scoped to request.user.

LIVE VIEW: the server relays ONLY signaling (SDP + ICE candidates). Video goes
peer-to-peer, or through our TURN server when P2P is impossible. The server
never sees media and nothing is recorded. P2P is free; relayed minutes are
charged with the admin-editable `shop_live_relay_min` action.

Owner-facing wording is always "please check", never "theft".
"""
import hashlib
import json
import logging
import math
from datetime import timedelta

from django.db import transaction
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from .logic import shop_guard as SG
from . import shop_views as SV

log = logging.getLogger("assisto.shop")

# ---------------------------------------------------------------------------
# config knobs
# ---------------------------------------------------------------------------
SPIKE_BASELINE_DAYS = 14
LIVE_PENDING_TIMEOUT_S = 45        # device must answer within this
LIVE_MAX_MESSAGES = 300
LIVE_MAX_PAYLOAD_BYTES = 16 * 1024
LIVE_KINDS = ("offer", "answer", "candidate", "bye")


def _shop_cfg():
    from . import billing
    try:
        return billing.cfg().get("shop") or {}
    except Exception:
        return {}


def eod_tolerance():
    return int(_shop_cfg().get("eod_tolerance_poisha", 5000))


def live_max_s():
    return int(_shop_cfg().get("live_max_session_s", 600))


def relay_min_credits():
    from . import billing
    from .logic import pricing
    try:
        return pricing.credits_for("shop_live_relay_min", 1, billing.cfg())
    except Exception:
        return 1


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def _bad_token(lang):
    return _err(lang, "ডিভাইস টোকেন ভুল।", "Invalid device token.",
                status=401, code="bad_token")


def _local_day_bounds(now=None):
    """(start, end) aware datetimes of TODAY in the server's local tz."""
    now = now or timezone.now()
    local = timezone.localtime(now)
    start = local.replace(hour=0, minute=0, second=0, microsecond=0)
    return start, start + timedelta(days=1)


def _owner_lang(user):
    lang = getattr(user, "language", None)
    return lang if lang in ("bn", "en") else "bn"


# ===========================================================================
# CAMERA SETTINGS — PATCH / DELETE shop/cameras/<id> (owner only)
# ===========================================================================

class ShopCameraDetailView(APIView):
    def _cam(self, request, pk):
        from .models import ShopCamera
        return ShopCamera.objects.filter(pk=pk, site__owner=request.user).select_related(
            "site").first()

    def get(self, request, pk):
        """Owner-only: the camera row WITH its token (for the webhook URL /
        pairing a Shop Box phone)."""
        lang = req_lang(request)
        cam = self._cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        out = SV._camera_row(cam, reveal_token=True)
        out["webhook_paths"] = {
            v: "shop/hook/%s/%s" % (v, cam.camera_token)
            for v in ("hikvision", "dahua")}
        return Response(out)

    def patch(self, request, pk):
        lang = req_lang(request)
        cam = self._cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data
        fields = set()
        zc = dict(cam.zone_config) if isinstance(cam.zone_config, dict) else {}
        reveal = False

        if "name" in d:
            cam.name = (d.get("name") or "").strip()[:120]
            fields.add("name")
        if "zone_config" in d:
            new = d.get("zone_config")
            if not isinstance(new, dict):
                return _err(lang, "জোন সেটিং ভুল।", "Invalid zone config.",
                            status=422, code="bad_zone")
            # keep hours/restricted_zone unless the new dict sets them
            for k in ("hours", "restricted_zone"):
                if k in zc and k not in new:
                    new[k] = zc[k]
            zc = dict(new)
            fields.add("zone_config")
        if "hours" in d:
            h = SV.coerce_hours(d.get("hours"))
            if h is False:
                return _err(lang, "সময় HH:MM আকারে দিন।",
                            "Give hours as HH:MM.", status=422, code="bad_hours")
            if h:
                zc["hours"] = h
            else:
                zc.pop("hours", None)     # fall back to the site's hours
            fields.add("zone_config")
        if "restricted_zone" in d:
            zc["restricted_zone"] = SV._coerce_bool(d.get("restricted_zone"))
            fields.add("zone_config")
        if "zone_config" in fields:
            cam.zone_config = zc
        if SV._coerce_bool(d.get("rotate_token")):
            from .models import _gen_token
            cam.camera_token = _gen_token()
            fields.add("camera_token")
            reveal = True

        charged = 0
        if "enabled" in d:
            want = SV._coerce_bool(d.get("enabled"))
            if want and not cam.enabled:
                # re-enabling an EXTRA camera whose paid period lapsed needs credits
                need, is_extra = _reenable_charge(request.user, cam)
                if need:
                    charged = SV._debit_camera_credits(
                        request.user, need, note="shop camera #%d re-enable" % cam.id)
                    if charged < need:
                        return _err(
                            lang,
                            "এই ক্যামেরা চালু করতে %d ক্রেডিট দরকার (এখন যথেষ্ট নেই)।" % need,
                            "Turning this camera on needs %d credits (not enough now)." % need,
                            status=402, code="camera_cap", credits_needed=need,
                            balance=int(request.user.ai_credits or 0))
                    cam.billed_until = timezone.now() + timedelta(
                        days=SV.BILLING_PERIOD_DAYS)
                    fields.add("billed_until")
            cam.enabled = want
            fields.add("enabled")

        if fields:
            cam.save(update_fields=sorted(fields))
        out = SV._camera_row(cam, reveal_token=reveal)
        out["charged_credits"] = charged
        return Response(out)

    def delete(self, request, pk):
        lang = req_lang(request)
        cam = self._cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        cam.delete()
        return Response({"ok": True, "deleted": int(pk)})


def _reenable_charge(user, cam):
    """Credits needed to switch `cam` back ON: 0 when it would fall inside the
    plan's included count, or its paid period is still running."""
    included = SV._included_cameras(user)
    # its 0-based rank among the owner's enabled cameras once switched back on
    rank = SV.owner_enabled_cameras(user).exclude(pk=cam.pk).filter(
        created__lte=cam.created).count()
    is_extra = rank >= included
    if not is_extra:
        return 0, False
    if cam.billed_until and cam.billed_until > timezone.now():
        return 0, True
    return SV._extra_camera_credits(), True


# ===========================================================================
# DEVICE: pair check · heartbeat · config
# ===========================================================================

def _cam_config(cam):
    from .logic import watchman as WM
    zc = SV.effective_zone_config(cam)
    out = {"id": cam.id, "name": cam.name, "kind": cam.kind,
           "enabled": cam.enabled, "zone_config": cam.zone_config or {},
           "hours": zc.get("hours") or None,
           "restricted_zone": bool(zc.get("restricted_zone", True))}
    # cctv1 additions (older Shop Box clients simply ignore them). The camera
    # password / safety code is NEVER here — it lives on the gateway only.
    v2 = WM.zone_v2(cam.zone_config)
    if cam.vendor:
        out["source"] = dict(cam.source or {}, vendor=cam.vendor)
    if v2 is not None:
        out["zones"] = {"v": WM.SCHEMA_V, "zones": v2.get("zones") or [],
                        "schedule": v2.get("schedule"),
                        "sensitivity": v2.get("sensitivity") or "medium",
                        "quiet_hours": v2.get("quiet_hours")}
    out["tuning"] = WM.device_tuning(cam.tuning)
    return out


def device_config(site, cam=None):
    cams = [cam] if cam is not None else list(site.cameras.all())
    body = {"site": {"id": site.id, "name": site.name, "hours": site.hours or {},
                     "pos_link": site.pos_link},
            "cameras": [_cam_config(c) for c in cams]}
    version = hashlib.sha1(json.dumps(body, sort_keys=True, default=str)
                           .encode()).hexdigest()[:12]
    body["version"] = version
    return body


class ShopPairCheckView(APIView):
    """POST shop/pair/check {site_token|camera_token} — validates a token and
    returns the site name (and cameras) WITHOUT creating anything."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        lang = req_lang(request)
        site, cam = SV._resolve_device_site(request)
        if site is None:
            return _bad_token(lang)
        out = {"ok": True, "site": {"id": site.id, "name": site.name},
               "camera": ({"id": cam.id, "name": cam.name, "kind": cam.kind}
                          if cam else None),
               "token_kind": "camera" if (cam and str(
                   request.data.get("camera_token") or request.META.get(
                       "HTTP_X_SHOP_TOKEN") or "") == cam.camera_token) else "site"}
        if cam is None:
            out["cameras"] = [{"id": c.id, "name": c.name, "kind": c.kind,
                               "enabled": c.enabled} for c in site.cameras.all()]
        return Response(out)


class ShopHeartbeatView(APIView):
    """POST shop/heartbeat {token, camera_ids?, caps?, platform?, version?} —
    marks the device (and its camera[s]) seen; answers the config version so the
    device only pulls shop/config when it changed, plus any pending live-view
    session the device should answer."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        from .models import ShopSite, ShopCamera
        lang = req_lang(request)
        site, cam = SV._resolve_device_site(request)
        if site is None:
            return _bad_token(lang)
        now = timezone.now()
        d = request.data
        cams = [cam] if cam is not None else []
        if cam is None and isinstance(d.get("camera_ids"), list):
            ids = [int(x) for x in d.get("camera_ids") if str(x).isdigit()][:64]
            cams = list(site.cameras.filter(pk__in=ids))
        caps = d.get("caps") if isinstance(d.get("caps"), list) else []
        info = {"caps": [str(c)[:16] for c in caps][:8],
                "platform": str(d.get("platform") or "")[:24],
                "version": str(d.get("version") or "")[:24], "at": now.isoformat()}
        ShopSite.objects.filter(pk=site.pk).update(last_seen=now)
        for c in cams:
            ShopCamera.objects.filter(pk=c.pk).update(last_seen=now, device_info=info)
        _sweep_live(now)
        cfg = device_config(site, cam)
        from . import watchman_views as WV
        return Response({"ok": True, "config_version": cfg["version"],
                         "tasks_pending": WV.pending_task_count(site, now),
                         "server_time": now.isoformat(),
                         "live_pending": [_live_device_row(s) for s in
                                          _pending_for(site, cams, now)]})


class ShopDeviceConfigView(APIView):
    """GET shop/config (X-Shop-Token) — zones, hours, enabled, restricted_zone
    for the device's camera(s)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        lang = req_lang(request)
        site, cam = SV._resolve_device_site(request)
        if site is None:
            return _bad_token(lang)
        return Response(device_config(site, cam))


# ===========================================================================
# ASSISTO POS -> ShopPosEvent mirror (explicit calls from business views)
# ===========================================================================

def mirror_pos(prof, kind, amount, at=None):
    """Mirror one Assisto POS action into every site of the business OWNER that
    has pos_link on, then run the void/discount spike check. NEVER raises."""
    try:
        from .models import ShopSite, ShopPosEvent
        owner = prof.user
        at = at or timezone.now()
        sites = list(ShopSite.objects.filter(owner=owner, pos_link=True))
        for site in sites:
            ShopPosEvent.objects.create(site=site, kind=kind,
                                        amount=int(amount or 0), at=at)
            if kind in (SG.POS_VOID, SG.POS_DISCOUNT):
                try:
                    pos_spike_check(site, kind, timezone.now())
                except Exception:
                    log.exception("shop spike check failed")
        return len(sites)
    except Exception:
        log.exception("shop POS mirror failed")
        return 0


def mirror_sale(prof, sale):
    """Checkout hook: a `sale` row, plus a `discount` row when discount > 0."""
    try:
        n = mirror_pos(prof, SG.POS_SALE, sale.total, sale.created_at)
        if int(sale.discount or 0) > 0:
            mirror_pos(prof, SG.POS_DISCOUNT, sale.discount, sale.created_at)
        return n
    except Exception:
        log.exception("shop sale mirror failed")
        return 0


_SPIKE_TYPE = {SG.POS_VOID: SG.VOID_SPIKE, SG.POS_DISCOUNT: SG.DISCOUNT_SPIKE}


def spike_baseline(site, kind, day_start):
    """Average per-day count of `kind` over the previous 14 days (min 1.0)."""
    since = day_start - timedelta(days=SPIKE_BASELINE_DAYS)
    n = site.pos_events.filter(kind=kind, at__gte=since, at__lt=day_start).count()
    return max(1.0, n / float(SPIKE_BASELINE_DAYS))


def pos_spike_check(site, kind, now):
    """When today's count of voids/discounts spikes vs the 14-day baseline, run
    shop_guard VOID_SPIKE / DISCOUNT_SPIKE with the real baseline and raise via
    _ingest_event — at most ONE such alert per site+type per day."""
    from .models import ShopEvent
    etype = _SPIKE_TYPE.get(kind)
    if etype is None:
        return None
    start, end = _local_day_bounds(now)
    if ShopEvent.objects.filter(site=site, type=etype, created__gte=start).exists():
        return None
    rows = [{"kind": p.kind, "amount": p.amount, "at": p.at.timestamp()}
            for p in site.pos_events.filter(kind=kind, at__gte=start, at__lt=end)]
    baseline = spike_baseline(site, kind, start)
    cam_event = {"type": etype, "at": now.timestamp(),
                 "signals": {"baseline": round(baseline, 2),
                             "source": "assisto_pos", "today": len(rows)}}
    decision, ev = SV._ingest_event(site, None, cam_event, now, pos_rows=rows)
    return ev


# ===========================================================================
# END-OF-DAY cash vs sales — POST/GET shop/sites/<id>/eod (owner)
# ===========================================================================

def _poisha(v, default=None):
    try:
        if isinstance(v, bool):
            return default
        n = int(v)
    except (TypeError, ValueError):
        return default
    return n


def todays_cash_sales(owner, now=None, business_id=None):
    """Sum of (paid - change) of today's (local tz) NON-voided CASH sales across
    the owner's businesses. POISHA."""
    from django.db.models import Q
    from .models import Sale
    start, end = _local_day_bounds(now)
    # the owner's businesses, plus legacy single-shop sales without a business
    qs = Sale.objects.filter(Q(business__user=owner) |
                             Q(business__isnull=True, user=owner),
                             payment_method="cash",
                             voided_at__isnull=True,
                             created_at__gte=start, created_at__lt=end)
    if business_id:
        qs = qs.filter(business_id=business_id)
    total = 0
    count = 0
    for s in qs.only("paid", "change"):
        total += max(0, int(s.paid or 0) - int(s.change or 0))
        count += 1
    return total, count


def _eod_row(e):
    return {"id": e.id, "day": e.day.isoformat(), "counted": e.counted,
            "expected": e.expected, "opening_float": e.opening_float,
            "cash_sales": e.cash_sales, "tolerance": e.tolerance,
            "difference": e.counted - e.expected, "status": e.status,
            "note": e.note, "event_id": e.event_id,
            "created": e.created.isoformat()}


class ShopEodView(APIView):
    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        cash, count = todays_cash_sales(request.user)
        return Response({"checks": [_eod_row(e) for e in s.eod_checks.all()[:30]],
                         "today_cash_sales": cash, "today_cash_sale_count": count,
                         "tolerance": eod_tolerance()})

    def post(self, request, pk):
        from .models import ShopEodCheck
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        counted = _poisha(request.data.get("counted_cash"))
        if counted is None or counted < 0:
            return _err(lang, "গোনা ক্যাশের পরিমাণ দিন (পয়সায়)।",
                        "Enter the counted cash (in poisha).", status=422,
                        code="bad_amount")
        opening = _poisha(request.data.get("opening_float"), 0) or 0
        if opening < 0:
            opening = 0
        now = timezone.now()
        cash, _n = todays_cash_sales(request.user, now,
                                     _poisha(request.data.get("business")))
        expected = cash + opening
        tol = eod_tolerance()
        decision = SG.combine({"type": SG.EOD_MISMATCH, "at": now.timestamp(),
                               "signals": {"counted": counted, "expected": expected,
                                           "tolerance": tol}}, [], now=now.timestamp())
        diff = counted - expected
        status_v = "ok" if not decision["raise"] else ("short" if diff < 0 else "over")
        ev = None
        if decision["raise"]:
            _d, ev = SV._ingest_event(
                s, None, {"type": SG.EOD_MISMATCH, "at": now.timestamp(),
                          "signals": {"counted": counted, "expected": expected,
                                      "tolerance": tol, "source": "eod_check"}},
                now, pos_rows=[])
        row = ShopEodCheck.objects.create(
            site=s, day=timezone.localtime(now).date(), counted=counted,
            expected=expected, opening_float=opening, cash_sales=cash,
            tolerance=tol, status=status_v,
            note=(request.data.get("note") or "").strip()[:200], event=ev,
            created_by=request.user)
        out = _eod_row(row)
        if status_v == "ok":
            out["message"] = pick(lang, "ক্যাশ হিসাব মিলেছে।", "Cash count matches.")
        elif status_v == "short":
            out["message"] = pick(
                lang, "ক্যাশ হিসাবের চেয়ে কম — অনুগ্রহ করে একটু দেখে নিন।",
                "Cash is below the expected amount — please check.")
        else:
            out["message"] = pick(
                lang, "ক্যাশ হিসাবের চেয়ে বেশি — অনুগ্রহ করে একটু দেখে নিন।",
                "Cash is above the expected amount — please check.")
        return Response(out, status=201)


# ===========================================================================
# LIVE VIEW SIGNALING (owner <-> device). Media NEVER touches the server.
# ===========================================================================

def ice_config(user_id, allow_relay=True):
    """The same ICE decision RtcTurnView makes (configured / throttled / servers),
    reused for live view. With allow_relay=False only the STUN entry is handed
    out, so the session can only ever be P2P (free)."""
    import os
    from django.conf import settings
    from .logic import rtc as RTC
    secret = getattr(settings, "TURN_STATIC_SECRET", "")
    host = getattr(settings, "TURN_HOST", "")
    port = getattr(settings, "TURN_PORT", 3478)
    if not secret or not host:
        return {"configured": False, "throttled": False, "ice_servers": [],
                "reason": "not_configured"}
    try:
        load1 = os.getloadavg()[0]
    except (OSError, AttributeError):
        load1 = 0.0
    try:
        from .views_build61 import _mem_available_mb
        mem = _mem_available_mb()
    except Exception:
        mem = 10 ** 6
    thr = RTC.throttle_decision(load1, os.cpu_count() or 1, mem)
    if thr["throttled"]:
        return {"configured": True, "throttled": True, "ice_servers": [],
                "reason": thr["reason"]}
    creds = RTC.turn_credentials(secret, user_id, timezone.now().timestamp())
    servers = RTC.ice_servers(host, port, creds)
    if not allow_relay:
        servers = [x for x in servers if not any(
            str(u).startswith("turn") for u in x.get("urls", []))]
    return {"configured": True, "throttled": False, "ice_servers": servers,
            "ttl": creds["ttl"]}


def _sweep_live(now):
    """Expire stale sessions: pending not answered in time, or past the cap."""
    from .models import ShopLiveSession
    ShopLiveSession.objects.filter(
        status="pending",
        created__lt=now - timedelta(seconds=LIVE_PENDING_TIMEOUT_S)).update(
        status="expired", ended_at=now, end_reason="not_answered")
    ShopLiveSession.objects.filter(
        status__in=("pending", "active"), expires_at__lte=now).update(
        status="expired", ended_at=now, end_reason="max_duration")


def _pending_for(site, cams, now):
    from .models import ShopLiveSession
    qs = ShopLiveSession.objects.filter(site=site, status="pending",
                                        expires_at__gt=now)
    if cams:
        qs = qs.filter(camera__in=cams)
    return list(qs.select_related("camera")[:5])


def _live_device_row(s):
    return {"id": s.id, "camera": s.camera_id, "camera_name": s.camera.name,
            "expires_at": s.expires_at.isoformat(),
            "ice": ice_config("shopdev%d" % s.site_id,
                              allow_relay=_relay_allowed(s.owner))}


def _relay_allowed(owner):
    return int(getattr(owner, "ai_credits", 0) or 0) >= relay_min_credits()


def _live_row(s, side=None, after=0):
    out = {"id": s.id, "camera": s.camera_id, "status": s.status,
           "expires_at": s.expires_at.isoformat(),
           "max_seconds": live_max_s(), "relayed": s.relayed,
           "seconds": s.seconds, "charged_credits": s.charged_credits,
           "end_reason": s.end_reason}
    if side is not None:
        other = "device" if side == "owner" else "owner"
        out["messages"] = [m for m in (s.messages or [])
                           if m.get("side") == other and int(m.get("seq", 0)) > after]
        out["seq"] = s.seq
    return out


class ShopLiveStartView(APIView):
    """POST shop/live/start {camera} — owner opens a live view. Returns the ICE
    config (STUN always; TURN only if the owner can pay for relayed minutes)."""
    def post(self, request):
        from .models import ShopCamera, ShopLiveSession
        lang = req_lang(request)
        cam = ShopCamera.objects.filter(pk=_poisha(request.data.get("camera")),
                                        site__owner=request.user).select_related(
            "site").first()
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()
        if not cam.enabled:
            return _err(lang, "ক্যামেরাটি বন্ধ আছে।", "This camera is turned off.",
                        status=409, code="camera_disabled")
        caps = (cam.device_info or {}).get("caps") or []
        if not SV.is_online(cam.last_seen, now):
            return _err(
                lang, "শপ বক্স ডিভাইসটি এখন অফলাইন — ফোন/পিসি চালু ও ইন্টারনেটে আছে কিনা দেখুন।",
                "The Shop Box device is offline right now — check that the phone/PC "
                "is on and connected.", status=409, code="device_offline",
                last_seen=SV._iso(cam.last_seen))
        if "live" not in caps:
            return _err(
                lang, "এই ক্যামেরার ডিভাইস এখনো লাইভ ভিউ সমর্থন করে না।",
                "This camera's device does not support live view yet.",
                status=409, code="live_unsupported")
        _sweep_live(now)
        # one live session per camera: close any earlier one of this owner
        ShopLiveSession.objects.filter(camera=cam, status__in=("pending", "active")
                                       ).update(status="ended", ended_at=now,
                                                end_reason="replaced")
        relay_ok = _relay_allowed(request.user)
        ice = ice_config(request.user.id, allow_relay=relay_ok)
        if ice.get("throttled"):
            return _err(lang, "সার্ভার এখন ব্যস্ত, একটু পরে আবার চেষ্টা করুন।",
                        "The server is busy, please try again shortly.",
                        status=503, code="throttled")
        s = ShopLiveSession.objects.create(
            site=cam.site, camera=cam, owner=request.user,
            expires_at=now + timedelta(seconds=live_max_s()))
        out = _live_row(s)
        out.update({"ice": ice, "relay_allowed": relay_ok,
                    "relay_credits_per_min": relay_min_credits(),
                    "turn_configured": bool(ice.get("configured"))})
        return Response(out, status=201)


class ShopLivePendingView(APIView):
    """GET shop/live/pending (X-Shop-Token) — sessions the device should answer.
    The device polls this (outbound only) or reads it from the heartbeat."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        lang = req_lang(request)
        site, cam = SV._resolve_device_site(request)
        if site is None:
            return _bad_token(lang)
        now = timezone.now()
        _sweep_live(now)
        return Response({"sessions": [_live_device_row(s) for s in
                                      _pending_for(site, [cam] if cam else [], now)]})


def _session_side(request, pk):
    """(session, side) — side 'owner' for the logged-in owner, 'device' for a
    token that belongs to the session's site/camera; (None, None) otherwise."""
    from .models import ShopLiveSession
    s = ShopLiveSession.objects.filter(pk=pk).select_related("camera", "owner").first()
    if s is None:
        return None, None
    user = getattr(request, "user", None)
    if user is not None and getattr(user, "is_authenticated", False) and \
            s.owner_id == user.id:
        return s, "owner"
    site, cam = SV._resolve_device_site(request)
    if site is not None and site.id == s.site_id and (cam is None or cam.id == s.camera_id):
        return s, "device"
    return None, None


class _LiveBase(APIView):
    # owner (Token auth) OR device (shop token) — resolved per request
    permission_classes = [AllowAny]

    def initial(self, request, *args, **kwargs):
        # an invalid/absent user token must not 401 a device call: fall back to
        # anonymous and let _session_side decide.
        try:
            super().initial(request, *args, **kwargs)
        except Exception:
            from django.contrib.auth.models import AnonymousUser
            request._user = AnonymousUser()
            request._auth = None


class ShopLiveSignalView(_LiveBase):
    """POST shop/live/<id>/signal {kind, payload} — append an SDP/ICE message.
    GET ?after=<seq> — the OTHER side's messages after seq + session status."""
    def get(self, request, pk):
        lang = req_lang(request)
        s, side = _session_side(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        _sweep_live(timezone.now())
        s.refresh_from_db()
        try:
            after = int(request.query_params.get("after") or 0)
        except (TypeError, ValueError):
            after = 0
        return Response(_live_row(s, side=side, after=after))

    def post(self, request, pk):
        from .models import ShopLiveSession
        lang = req_lang(request)
        s, side = _session_side(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        kind = (request.data.get("kind") or "").strip()
        if kind not in LIVE_KINDS:
            return _err(lang, "সিগন্যাল ধরন ভুল।", "Invalid signal kind.",
                        status=422, code="bad_kind")
        payload = request.data.get("payload")
        if len(json.dumps(payload, default=str)) > LIVE_MAX_PAYLOAD_BYTES:
            return _err(lang, "সিগন্যাল খুব বড়।", "Signal too large.",
                        status=413, code="too_large")
        now = timezone.now()
        _sweep_live(now)
        with transaction.atomic():
            s = ShopLiveSession.objects.select_for_update().get(pk=s.pk)
            if s.status not in ("pending", "active"):
                return _err(lang, "সেশন শেষ হয়ে গেছে।", "This session has ended.",
                            status=410, code="session_closed", status_now=s.status)
            msgs = list(s.messages or [])
            if len(msgs) >= LIVE_MAX_MESSAGES:
                return _err(lang, "অনেক বেশি সিগন্যাল।", "Too many signals.",
                            status=429, code="too_many")
            s.seq += 1
            msgs.append({"seq": s.seq, "side": side, "kind": kind,
                         "payload": payload})
            s.messages = msgs
            upd = ["messages", "seq"]
            if side == "device" and kind == "answer" and s.status == "pending":
                s.status = "active"
                s.answered_at = now
                upd += ["status", "answered_at"]
            s.save(update_fields=upd)
        return Response({"ok": True, "seq": s.seq, "status": s.status})


class ShopLiveEndView(_LiveBase):
    """POST shop/live/<id>/end {relayed, seconds} — either side closes. The
    client reports whether the selected ICE pair used TURN; relayed minutes are
    charged (shop_live_relay_min), P2P is free. Seconds are clamped to the real
    wall-clock span and the hard cap — never trusted beyond that."""
    def post(self, request, pk):
        from .models import ShopLiveSession
        lang = req_lang(request)
        s, side = _session_side(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        now = timezone.now()
        relayed = SV._coerce_bool(request.data.get("relayed"))
        reported = _poisha(request.data.get("seconds"), 0) or 0
        with transaction.atomic():
            s = ShopLiveSession.objects.select_for_update().get(pk=s.pk)
            began = s.answered_at or s.created
            wall = max(0, int((min(now, s.expires_at) - began).total_seconds())) \
                if s.answered_at else 0
            secs = max(0, min(reported, wall + 5, live_max_s()))
            upd = set()
            if s.status in ("pending", "active"):
                s.status = "ended"
                s.ended_at = now
                s.end_reason = ("%s_ended" % side)[:24]
                upd |= {"status", "ended_at", "end_reason"}
            if secs > s.seconds:
                s.seconds = secs
                upd.add("seconds")
            if relayed and not s.relayed:
                s.relayed = True
                upd.add("relayed")
            charge = 0
            if s.relayed and s.charged_credits == 0 and s.seconds > 0:
                mins = int(math.ceil(s.seconds / 60.0))
                need = relay_min_credits() * mins
                charge = need
            if upd:
                s.save(update_fields=sorted(upd))
        charged = 0
        if charge:
            # pay what the balance covers; never block the end of a session
            owner = s.owner
            bal = int(owner.ai_credits or 0)
            take = min(bal, charge)
            if take > 0:
                charged = SV._debit_camera_credits(
                    owner, take, note="shop live relay %d min" % int(
                        math.ceil(s.seconds / 60.0)))
            ShopLiveSession.objects.filter(pk=s.pk).update(charged_credits=charged)
            s.charged_credits = charged
        out = _live_row(s)
        out["charged_credits"] = charged
        out["unpaid_credits"] = max(0, charge - charged) if charge else 0
        return Response(out)
