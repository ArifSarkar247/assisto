"""cctvguard (owner CCTV order G): traffic meter + vendor live endpoints.

  GET  cctv/usage                                  — "this month" for the owner
  POST shop/live/<id>/usage {bytes, seconds, path} — a WebRTC live view reports
       its cumulative getStats bytes (every ~60 s and at the end); the answer
       says whether the relay must stop (cap reached, no emergency)
  POST watchman/cameras/<id>/vendor_live {hd}      — Imou / EZVIZ cloud HLS
       address, SD by default, HD only on tap; max live views per account
  POST watchman/cameras/<id>/vendor_live/<vid>/touch {hd?} — 5-min idle stop
  POST watchman/cameras/<id>/vendor_live/<vid>/end {seconds}

Behind the CCTV switch (watchman _OwnerBase). Nothing here sees video.
"""
import logging

from django.utils import timezone
from rest_framework.response import Response

from . import cctv_traffic as CT
from .i18n import req_lang
from .logic import cctv_traffic as T
from .shop_ops_views import _LiveBase, _err, _session_side
from .watchman_views import _OwnerBase

log = logging.getLogger("assisto.cctvguard")


class CctvUsageView(_OwnerBase):
    def get(self, request):
        lang = req_lang(request)
        out = CT.usage_for(request.user, lang=lang)
        try:
            from . import cctv_cap as CC
            out["cap"] = CC.status(request.user, lang=lang)    # cctvcap
        except Exception:
            log.exception("cap status failed")
        return Response(out)


class CctvExtraPackView(_OwnerBase):
    """POST cctv/extra-pack {kind: relay|ai} — cctvcap: one-tap extra pack for
    THIS month (relay +1 GB / AI +100 checks by default), paid with credits.
    A Play one-time product per pack is the later seam (owner_actions/
    CCTV_PRICING_BN.md)."""

    def post(self, request):
        from . import cctv_cap as CC
        lang = req_lang(request)
        kind = str((request.data or {}).get("kind") or "")
        ok, info = CC.buy_pack(request.user, kind)
        if not ok:
            code = info.get("code")
            if code == "bad_kind":
                return _err(lang, "প্যাক ঠিক নেই।", "Unknown pack.", status=422, code=code)
            if code == "no_credits":
                return _err(lang, "যথেষ্ট ক্রেডিট নেই — আগে ক্রেডিট নিন।",
                            "Not enough credits — add credits first.", status=402,
                            code=code, credits_needed=info.get("credits_needed"))
            return _err(lang, "প্যাক যোগ করা যায়নি — ক্রেডিট ফেরত দেওয়া হয়েছে।",
                        "The pack could not be added — your credits were returned.",
                        status=503, code="failed")
        request.user.refresh_from_db()
        out = CT.usage_for(request.user, lang=lang)
        out["cap"] = CC.status(request.user, lang=lang)
        out["bought"] = info
        return Response(out, status=201)


class ShopLiveUsageView(_LiveBase):
    def post(self, request, pk):
        from .models import ShopLiveSession
        lang = req_lang(request)
        s, side = _session_side(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data or {}
        path = T.norm_path(d.get("path"))
        now = timezone.now()
        began = s.answered_at or s.created
        wall = max(0, int((now - began).total_seconds()))
        secs = min(T._int(d.get("seconds")), wall + 5)
        if path == "relay" and not s.relayed:
            ShopLiveSession.objects.filter(pk=s.pk).update(relayed=True)
            s.relayed = True
        st = CT.record_live(s, d.get("bytes"), secs, path, now)
        emergency = bool(CT.cache.get(CT._ekey(s.pk)))
        if (not emergency and s.relayed and st["level"] == "paused"
                and CT.emergency_active(s.owner_id, s.site.owner_id, now, site=s.site)):
            # cctvcap: an SOS / fall that began during this live view
            CT.mark_emergency(s.pk)
            emergency = True
        stop = (s.relayed and st["level"] == "paused" and not emergency
                and s.status in ("pending", "active"))
        if stop:
            # end it here too, so the other side stops on its next poll
            ShopLiveSession.objects.filter(pk=s.pk, status__in=("pending", "active")).update(
                status="ended", ended_at=now, end_reason="relay_cap")
        return Response({"level": "emergency" if (emergency and st["level"] == "paused")
                         else st["level"], "pct": st["pct"], "stop": stop,
                         "message": T.messages("paused" if stop else
                                               (st["level"] if not emergency else ""),
                                               st["pct"], lang)})


# ---------------------------------------------------------------- vendor live
def _camera_for(user, pk):
    """Owner only: family viewers see alerts + snapshots, not live (order I —
    live for others is an explicit owner switch, phone cameras only today)."""
    from .models import ShopCamera
    return ShopCamera.objects.filter(pk=pk, site__owner=user).select_related("site").first()


def _live_limit():
    try:
        from . import shop_ops_views as SO
        fn = getattr(SO, "live_max_per_account", None)   # agent/cctvphone
        if fn:
            return int(fn())
        return max(1, int(SO._shop_cfg().get("live_max_per_account", 2)))
    except Exception:
        return 2


def _open_live_count(owner_id, now, except_cam=None):
    from .models import ShopLiveSession
    n = ShopLiveSession.objects.filter(site__owner_id=owner_id,
                                       status__in=("pending", "active"),
                                       expires_at__gt=now)
    if except_cam:
        n = n.exclude(camera_id=except_cam)
    n = n.count()
    ts = now.timestamp()
    for v in (CT.month_doc(owner_id, now).get("vsess") or {}).values():
        if (v.get("open") and int(v.get("cam") or 0) != except_cam
                and ts <= float(v.get("touch", 0)) + T.VENDOR_IDLE_S
                and ts <= float(v.get("start", 0)) + T.VENDOR_MAX_S):
            n += 1
    return n


def _vendor_url(cam, hd):
    """-> (url, ref) or raises. Imou vendor_ref "<deviceId>:<channelId>",
    EZVIZ "EZ:<serial>:<channel>"."""
    if cam.vendor == "imou":
        from .logic import imou as IM
        from .watchman_views import imou_cloud_on
        client = IM.ImouClient.from_integration() if imou_cloud_on() else None
        if client is None:
            raise LookupError("not_configured")
        dev, _, ch = cam.vendor_ref.partition(":")
        if not dev:
            raise LookupError("not_linked")
        return client.live_hls(dev, ch or "0", hd)
    if cam.vendor == "ezviz":
        from .cashguard_views import ezviz_on
        from .logic import ezviz as EZ
        client = EZ.EzvizClient.from_integration() if ezviz_on() else None
        if client is None:
            raise LookupError("not_configured")
        parts = cam.vendor_ref.split(":")
        if len(parts) < 2 or not parts[1]:
            raise LookupError("not_linked")
        ch = parts[2] if len(parts) > 2 and parts[2].isdigit() else "1"
        return client.live_address(parts[1], int(ch), hd, expire_s=T.VENDOR_MAX_S), ""
    raise LookupError("not_vendor")


def _vendor_stop(cam, ref):
    if cam.vendor != "imou" or not ref:
        return
    try:
        from .logic import imou as IM
        client = IM.ImouClient.from_integration()
        if client:
            client.unbind_live(ref)
    except Exception:
        log.info("imou unbindLive failed (best effort)")


class VendorLiveStartView(_OwnerBase):
    def post(self, request, pk):
        lang = req_lang(request)
        cam = _camera_for(request.user, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if cam.vendor not in ("imou", "ezviz"):
            return _err(lang, "এই ক্যামেরার ক্লাউড লাইভ নেই।",
                        "This camera has no cloud live view.", status=409,
                        code="not_vendor")
        if not cam.enabled:
            return _err(lang, "ক্যামেরাটি বন্ধ আছে।", "This camera is turned off.",
                        status=409, code="camera_disabled")
        now = timezone.now()
        owner_id = cam.site.owner_id
        n = _live_limit()
        if _open_live_count(owner_id, now, except_cam=cam.pk) >= n:
            return _err(lang,
                        "একসাথে %s টির বেশি লাইভ দেখা যায় না। আগে অন্য লাইভটি বন্ধ করুন।"
                        % T.bn(n),
                        "At most %d live views at once. Close another live view first." % n,
                        status=429, code="live_limit", limit=n)
        dec = CT.relay_decision(request.user, owner_id, now, lang)
        if not dec["allow"]:
            return _err(lang, *[T.messages("paused_vendor", dec["pct"], x)
                                for x in ("bn", "en")],
                        status=402, code="relay_cap", pct=dec["pct"])
        hd = request.data.get("hd") is True
        try:
            url, ref = _vendor_url(cam, hd)
        except LookupError as e:
            code = str(e.args[0]) if e.args else "not_configured"
            return _err(lang, "এই ক্যামেরার ক্লাউড লাইভ এখনো চালু করা যায়নি (ক্যামেরা কোম্পানির অ্যাকাউন্ট সংযোগ বাকি)।",
                        "Cloud live is not set up for this camera yet (camera maker "
                        "account not linked).", status=409, code=code)
        except Exception as e:  # vendor error codes -> honest message
            log.info("vendor live failed: %s", getattr(e, "code", e))
            return _err(lang, "ক্যামেরা কোম্পানির ক্লাউড এখন লাইভ দিচ্ছে না — ক্যামেরা অনলাইনে আছে কিনা দেখুন, একটু পরে আবার চেষ্টা করুন।",
                        "The camera maker's cloud did not give a live view — check the "
                        "camera is online and try again shortly.", status=502,
                        code="vendor_error", vendor_code=str(getattr(e, "code", ""))[:24])
        vid = CT.vendor_open(cam, request.user, hd, ref, now)
        return Response({"id": vid, "url": url, "hd": hd, "vendor": cam.vendor,
                         "idle_seconds": T.VENDOR_IDLE_S, "max_seconds": T.VENDOR_MAX_S,
                         "kbps": T.VENDOR_KBPS["hd" if hd else "sd"],
                         "level": dec["level"], "pct": dec["pct"],
                         "message": dec["message"], "estimate": True}, status=201)


class VendorLiveTouchView(_OwnerBase):
    def post(self, request, pk, vid):
        lang = req_lang(request)
        cam = _camera_for(request.user, pk)
        if cam is None or CT.vendor_get(cam, vid) is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if "hd" in (request.data or {}):
            CT.vendor_set_hd(cam, vid, request.data.get("hd") is True)
        ok, left = CT.vendor_touch(cam, vid)
        if not ok:
            return _err(lang, "লাইভ শেষ হয়ে গেছে।", "This live view has ended.",
                        status=410, code="session_closed")
        return Response({"ok": True, "left": left})


class VendorLiveEndView(_OwnerBase):
    def post(self, request, pk, vid):
        lang = req_lang(request)
        cam = _camera_for(request.user, pk)
        if cam is None or CT.vendor_get(cam, vid) is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        secs, ref = CT.vendor_end(cam, vid, (request.data or {}).get("seconds"))
        now = timezone.now().timestamp()
        others = [v for v in (CT.month_doc(cam.site.owner_id).get("vsess") or {}).values()
                  if v.get("open") and int(v.get("cam") or 0) == cam.pk
                  and now <= float(v.get("touch", 0)) + T.VENDOR_IDLE_S]
        if not others:          # Imou shares one live address per channel
            _vendor_stop(cam, ref)
        return Response({"ok": True, "seconds": secs, "estimate": True})
