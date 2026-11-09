"""fcelder — Silent Watch + Elder setup endpoints (rules in core/silent_watch.py).

  GET  family/silent-watch                    {mine:{config, alert}|null, watching:[...]}
  POST family/silent-watch                    elder {enabled?, hours?, day_start?, day_end?, nearby_user_id?}
  POST family/silent-watch/token              elder: a fresh alert token for this phone
  POST family/silent-watch/ok                 elder "I am OK" (account OR {token}: the phone's
                                              native "I am OK" button has no account token)
  POST family/silent-watch/alert              PHONE {token, kind, silent_min} — the ONE event
  POST family/silent-watch/alerts/<id>/ack    family "I am checking"
  POST family/silent-watch/test               setter {elder_user_id}: two-phone test
  POST family/elder-setup                     child {elder_user_id, hours?, day_start?, day_end?,
                                              nearby_user_id?, easy_home?, silent_watch?, carecall?}
  GET  family/elder-setup/<code>              elder: what will be set up (consent screen)
  POST family/elder-setup/<code>/accept       elder: the one big YES
"""
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle
from rest_framework.views import APIView

from . import silent_watch as SW
from .i18n import pick, req_lang

_MSG = {
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "not_set_up": ("নীরব পাহারা এখনো সেটআপ হয়নি। পরিবারের কেউ আপনার ফোনে QR দিয়ে সেটআপ করে দিতে পারেন।",
                   "Silent Watch is not set up yet. A family member can set it up on your phone with a QR."),
    "not_family": ("এই মানুষটি আপনার পরিবারে নেই। আগে পরিবারে যোগ করুন।",
                   "This person is not in your family. Add them to your family first."),
    "nearby_not_family": ("কাছের মানুষ হিসেবে পরিবারের বা My Circle-এর কাউকে বেছে নিন।",
                          "Pick someone from your family or My Circle as the nearby person."),
    "bad_hours": ("২ থেকে ১২ ঘণ্টার মধ্যে বেছে নিন।", "Pick between 2 and 12 hours."),
    "bad_day": ("দিনের শুরু ও শেষের সময় দিন।", "Give the day's start and end time."),
    "bad_code": ("কোডটা মিলছে না। সন্তানের ফোনে নতুন QR দেখে আবার চেষ্টা করুন।",
                 "That code does not match. Show a new QR on your child's phone and try again."),
    "code_expired": ("কোডের সময় শেষ (১৫ মিনিট)। সন্তানের ফোনে নতুন QR বানান।",
                     "The code expired (15 minutes). Make a new QR on your child's phone."),
    "wrong_phone": ("এই কোডটা অন্য একজনের ফোনের জন্য বানানো। সঠিক ফোনে, তাঁর নিজের অ্যাকাউন্টে খুলুন।",
                    "This code was made for someone else's phone. Open it on their phone, in their own account."),
    "not_setter": ("শুধু যিনি সেটআপ করেছেন তিনি টেস্ট করতে পারেন।", "Only the person who set it up can run a test."),
    "already_open": ("এখন একটা সতর্কতা চলছে।", "An alert is already running."),
    "off": ("নীরব পাহারা বন্ধ আছে।", "Silent Watch is off."),
}
_CODE = {"not_found": 404, "not_set_up": 404, "not_family": 404, "bad_code": 404,
         "code_expired": 410, "wrong_phone": 403, "not_setter": 403, "already_open": 409,
         "off": 409}


def refuse(request, reason):
    bn, en = _MSG.get(reason, _MSG["not_found"])
    return Response({"ok": False, "reason": reason, "detail": pick(req_lang(request), bn, en)},
                    status=_CODE.get(reason, status.HTTP_400_BAD_REQUEST))


class SilentWatchView(APIView):
    def get(self, request):
        return Response(SW.status_for(request.user))

    def post(self, request):
        cfg, err = SW.set_config(request.user, request.data or {})
        if err:
            return refuse(request, err)
        return Response({"ok": True, "config": cfg})


class SilentWatchTokenView(APIView):
    def post(self, request):
        tok = SW.rotate_token(request.user)
        if tok is None:
            return refuse(request, "not_set_up")
        return Response({"ok": True, "token": tok})


class _TokenThrottle(AnonRateThrottle):
    rate = "30/hour"


class SilentWatchOkView(APIView):
    """Account auth from the app; the native notification button sends the
    phone's alert token instead (no account token outside Flutter)."""
    permission_classes = [AllowAny]
    throttle_classes = [_TokenThrottle]

    def post(self, request):
        elder = request.user if getattr(request.user, "is_authenticated", False) else None
        if elder is None:
            elder = SW.elder_for_token((request.data or {}).get("token"))
        if elder is None:
            return refuse(request, "not_found")
        r = SW.resolve(elder, by="elder")
        return Response({"ok": True, "resolved": r is not None})


class SilentWatchAlertView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    throttle_classes = [_TokenThrottle]

    def post(self, request):
        data = request.data or {}
        elder = SW.elder_for_token(data.get("token"))
        if elder is None:
            return refuse(request, "not_found")
        r, err = SW.raise_alert(elder, data.get("kind") or "inactivity", data.get("silent_min"))
        if err:
            return refuse(request, err)
        return Response({"ok": True, "alert_id": r.pk, "step": int((r.data or {}).get("step") or 0)})


class SilentWatchAckView(APIView):
    def post(self, request, pk):
        r, err = SW.ack(request.user, pk)
        if err:
            return refuse(request, err)
        return Response({"ok": True, "alert": SW.alert_dict(r, request.user)})


class SilentWatchTestView(APIView):
    def post(self, request):
        elder = SW._user((request.data or {}).get("elder_user_id"))
        if elder is None:
            return refuse(request, "not_found")
        r, err = SW.start_test(request.user, elder)
        if err:
            return refuse(request, err)
        return Response({"ok": True, "alert": SW.alert_dict(r, request.user)})


class ElderSetupView(APIView):
    def post(self, request):
        out, err = SW.start_pair(request.user, request.data or {})
        if err:
            return refuse(request, err)
        return Response({"ok": True, **out}, status=status.HTTP_201_CREATED)


class ElderSetupCodeView(APIView):
    def get(self, request, code):
        out, err = SW.preview_pair(request.user, code)
        if err:
            return refuse(request, err)
        return Response({"ok": True, **out})


class ElderSetupAcceptView(APIView):
    def post(self, request, code):
        if not (request.data or {}).get("yes"):
            return refuse(request, "not_found")
        out, err = SW.accept_pair(request.user, code)
        if err:
            return refuse(request, err)
        return Response({"ok": True, **out})
