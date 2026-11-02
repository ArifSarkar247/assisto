"""adminsafe: the user's own Account status + appeal endpoints.

  GET  account/standing               (signed in) -> standing dict
  POST account/appeal                 (signed in) {action_id, text}
  POST account/standing/blocked       {appeal_token} -> standing (suspended/banned)
  POST account/appeal/blocked         {appeal_token, action_id, text}

A suspended / banned account has no session; sign-in answers 403 with an
`appeal_token` (signed, 7 days) that only these two blocked endpoints accept.
"""
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import admin_safety as AS
from .i18n import pick, req_lang

_MSG = {
    "bad_text": ("আপিলে অন্তত ১০ অক্ষর লিখুন (সর্বোচ্চ ১০০০)।",
                 "Please write at least 10 characters (up to 1000)."),
    "not_found": ("এই সিদ্ধান্তটি পাওয়া যায়নি।", "That decision was not found."),
    "not_appealable": ("এই সিদ্ধান্তের বিরুদ্ধে আপিল করা যায় না।",
                       "This decision cannot be appealed."),
    "already_appealed": ("এই সিদ্ধান্তে আপনার আপিল আগেই জমা আছে।",
                         "You already appealed this decision."),
    "bad_token": ("লিংকের মেয়াদ শেষ। আবার সাইন-ইন করার চেষ্টা করুন।",
                  "This link expired. Please try signing in again."),
    "ok": ("আপিল জমা হয়েছে। আমাদের টিম দেখে উত্তর দেবে।",
           "Appeal sent. Our team will review it and reply."),
}


def _m(lang, key):
    bn, en = _MSG[key]
    return pick(lang, bn, en)


def _appeal(request, user):
    lang = req_lang(request)
    d = request.data or {}
    ap, err = AS.create_appeal(user, d.get("action_id"), d.get("text"))
    if err:
        code = status.HTTP_409_CONFLICT if err == "already_appealed" else (
            status.HTTP_404_NOT_FOUND if err == "not_found" else status.HTTP_400_BAD_REQUEST)
        return Response({"ok": False, "reason": err, "detail": _m(lang, err)}, status=code)
    return Response({"ok": True, "id": ap.id, "state": ap.state, "detail": _m(lang, "ok"),
                     "standing": AS.standing(user)}, status=status.HTTP_201_CREATED)


class AccountStandingView(APIView):
    def get(self, request):
        return Response(AS.standing(request.user))


class AccountAppealView(APIView):
    def post(self, request):
        return _appeal(request, request.user)


def _blocked_user(request):
    u = AS.user_from_appeal_token((request.data or {}).get("appeal_token"))
    if u is None:
        return None, Response({"ok": False, "reason": "bad_token",
                               "detail": _m(req_lang(request), "bad_token")},
                              status=status.HTTP_403_FORBIDDEN)
    return u, None


class BlockedStandingView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        u, bad = _blocked_user(request)
        return bad or Response(AS.standing(u))


class BlockedAppealView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        u, bad = _blocked_user(request)
        return bad or _appeal(request, u)
