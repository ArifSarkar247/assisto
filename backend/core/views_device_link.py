"""circle-extras (row 50) — QR device linking endpoints. Logic + design in
core/device_link.py. The new phone's two calls (claim, poll) need no sign-in;
everything else is the signed-in primary."""
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import device_link as DL
from .i18n import pick, req_lang

_MSG = {
    "unknown": ("এই কোড মেলেনি। প্রধান ফোনে নতুন কোড নিন।",
                "This code did not match. Get a new code on your main phone."),
    "expired": ("কোডের সময় শেষ (২ মিনিট)। প্রধান ফোনে আবার \"ডিভাইস লিংক করুন\" চাপুন।",
                "The code expired (2 minutes). Tap \"Link a device\" again on your main phone."),
    "used": ("এই কোড আগেই ব্যবহার হয়েছে। প্রধান ফোনে নতুন কোড নিন।",
             "This code was already used. Get a new code on your main phone."),
    "bad_key": ("ফোনের নিরাপত্তা কী তৈরি হয়নি। আবার চেষ্টা করুন।",
                "This phone could not make its security key. Try again."),
    "rate": ("অনেকবার চেষ্টা হয়েছে। ১০ মিনিট পরে আবার চেষ্টা করুন।",
             "Too many tries. Try again in 10 minutes."),
    "gone": ("লিংকের অনুরোধ আর নেই। আবার শুরু করুন।",
             "This link request is gone. Start again."),
    "not_claimed": ("নতুন ফোন এখনো কোড দেয়নি।",
                    "The new phone has not entered the code yet."),
    "bad_sealed": ("কী পাঠানো যায়নি। আবার চেষ্টা করুন।",
                   "The keys could not be sent. Try again."),
}


def _err(request, reason, code=status.HTTP_400_BAD_REQUEST):
    bn, en = _MSG.get(reason, _MSG["gone"])
    msg = pick(req_lang(request), bn, en)
    return Response({"ok": False, "reason": reason, "detail": msg, "message": msg},
                    status=code)


class LinkStartView(APIView):
    """POST e2/link/start -> {token, code, qr, ttl_sec, expires_at} (primary)."""

    def post(self, request):
        return Response(DL.start(request.user))


class LinkStatusView(APIView):
    """GET e2/link/status[?pair=] -> {state, name?, platform?, verify?}."""

    def get(self, request):
        pair = request.query_params.get("pair")
        if pair:
            return Response(DL.status(request.user, pair))
        return Response(DL.status_latest(request.user))


class LinkApproveView(APIView):
    """POST e2/link/approve {pair, sealed:{epk,nonce,ct}} | {pair, reject:true}."""

    def post(self, request):
        d = request.data or {}
        ok, why = DL.approve(request.user, d.get("pair"), sealed=d.get("sealed"),
                             reject=bool(d.get("reject")))
        if not ok:
            return _err(request, why, status.HTTP_410_GONE if why in ("gone", "expired")
                        else status.HTTP_400_BAD_REQUEST)
        return Response({"ok": True, "state": "rejected" if d.get("reject") else "approved"})


class LinkClaimView(APIView):
    """POST e2/link/claim {code|token, eph_pub, name?, platform?} (new phone,
    no sign-in) -> {pair, poll, verify, expires_in}."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        if not DL.claim_rate_ok(request):
            return _err(request, "rate", status.HTTP_429_TOO_MANY_REQUESTS)
        d = request.data or {}
        dev = (request.META.get("HTTP_X_DEVICE_ID", "") or "").strip()[:64]
        name = d.get("name") or (request.META.get("HTTP_X_DEVICE_NAME", "") or "").strip()
        out, why = DL.claim(d.get("code") or d.get("token"), d.get("eph_pub"),
                            name=name, platform=d.get("platform") or "android",
                            device_id=dev)
        if why:
            return _err(request, why, status.HTTP_410_GONE if why in ("expired", "used")
                        else status.HTTP_400_BAD_REQUEST)
        return Response(out)


class LinkPollView(APIView):
    """POST e2/link/poll {pair, poll} (new phone, no sign-in). Guarded by the
    poll secret, so it is not under the 30/min anonymous throttle (the new
    phone asks every 3 s for up to 5 minutes)."""
    permission_classes = [AllowAny]
    authentication_classes = []
    throttle_classes = []

    def post(self, request):
        d = request.data or {}
        out, code = DL.poll(d.get("pair"), d.get("poll"), request)
        return Response(out, status=code)
