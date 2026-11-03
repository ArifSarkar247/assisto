"""safeplans — Safety plans API (behind the `safe_plans` switch, default OFF).

  GET  safe-plans                         plan, balances, packs, ads progress,
                                          prices + Play ids (server numbers)
  POST safe-plans/use                     {action, child_id} -> 200 charged /
                                          402 {reason: safe_credits_out, sheet}
  POST safe-plans/child                   {child_id} the Child Plan's child
  POST safe-plans/ad/ticket               {goal: day|request} one SSV ticket
  GET  safe-plans/ad/ticket/<nonce>       verified yet?
  POST safe-plans/school/redeem           {code, child_id}
  GET  safe-plans/school/<code>/attendance   school staff only (times only)
  POST safe-plans/school/<code>/broadcast    school staff only {text}
  GET/POST safe-plans/school/<code>/bus      parents read / driver posts
Purchases go through the EXISTING /payments/play/verify (and RTDN)."""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import safe_plans as S
from .i18n import pick, req_lang

ACTIONS = ("location_request", "live_trip")


def _play(request):
    try:
        from .i18n import is_play_flavour
        return is_play_flavour(request)
    except Exception:
        return False


def _off(request):
    return not S.feature_on(request.user, _play(request))


def _feature_off(lang):
    return Response({"error": "feature_off",
                     "detail": pick(lang, "এই ফিচারটি এখনো চালু হয়নি।",
                                    "This feature is not available yet.")}, status=403)


class SafePlansView(APIView):
    def get(self, request):
        if _off(request):
            return _feature_off(req_lang(request))
        return Response(S.status(request.user, play=_play(request)))


class SafePlansUseView(APIView):
    def post(self, request):
        lang = req_lang(request)
        if _off(request):
            return _feature_off(lang)
        d = request.data or {}
        action = str(d.get("action") or "")
        if action not in ACTIONS:
            return Response({"error": "bad_action"}, status=400)
        res = S.charge(request.user, action, child=d.get("child_id") or None,
                       play=_play(request))
        if not res["ok"]:
            return Response({"ok": False, "reason": "safe_credits_out",
                             "sheet": S.out_payload(request.user, lang, res.get("plan"),
                                                    _play(request))}, status=402)
        res.pop("took", None)
        return Response({"ok": True, "charged": res["charged"],
                         "status": S.status(request.user)})


class SafePlansChildView(APIView):
    def post(self, request):
        if _off(request):
            return _feature_off(req_lang(request))
        try:
            cid = int((request.data or {}).get("child_id"))
        except (TypeError, ValueError):
            return Response({"error": "pick_child"}, status=400)
        if cid not in S._children_ids(request.user):
            return Response({"error": "not_your_child"}, status=400)
        from django.db import transaction
        with transaction.atomic():
            row = S._row(request.user, lock=True)
            data = dict(row.data or {})
            data["child_id"] = cid
            S._save(row, data)
        return Response(S.status(request.user))


class SafeAdTicketView(APIView):
    def post(self, request):
        lang = req_lang(request)
        if _off(request):
            return _feature_off(lang)
        r = S.ad_ticket(request.user, str((request.data or {}).get("goal") or ""))
        if not r["ok"]:
            msgs = {"capped": ("আজকের সীমা শেষ — কাল আবার দেখুন।",
                               "Today's limit is reached — try again tomorrow."),
                    "child_account": ("শিশুর অ্যাকাউন্টে কোনো বিজ্ঞাপন নেই।",
                                      "Child accounts never get ads."),
                    "not_guardian": ("শুধু অভিভাবকরা বিজ্ঞাপন দেখে আনলক করতে পারেন।",
                                     "Only guardians can unlock with ads."),
                    "paid_plan": ("আপনার প্ল্যানে কোনো বিজ্ঞাপন নেই।", "Your plan has no ads."),
                    "ads_not_configured": ("এখন কোনো বিজ্ঞাপন নেই — AdMob যুক্ত হলে চালু হবে।",
                                           "No ads available yet — this starts once AdMob is linked.")}
            bn, en = msgs.get(r["reason"], ("এখন সম্ভব নয়।", "Not possible right now."))
            r["msg"] = pick(lang, bn, en)
            return Response(r)
        return Response(r, status=201)


class SafeAdTicketStateView(APIView):
    def get(self, request, nonce):
        r = S.ticket_state(request.user, nonce)
        if r is None:
            return Response({"ok": False, "reason": "not_found"}, status=404)
        r["status_now"] = S.status(request.user)
        return Response(r)


class SchoolRedeemView(APIView):
    def post(self, request):
        if _off(request):
            return _feature_off(req_lang(request))
        d = request.data or {}
        r = S.redeem_school(request.user, d.get("code"), d.get("child_id"))
        return Response(r, status=200 if r["ok"] else 400)


class SchoolAttendanceView(APIView):
    def get(self, request, code):
        if _off(request):
            return _feature_off(req_lang(request))
        r = S.attendance(request.user, code)
        if r is None:
            return Response({"error": "not_school_staff"}, status=404)
        return Response(r)


class SchoolBroadcastView(APIView):
    def post(self, request, code):
        if _off(request):
            return _feature_off(req_lang(request))
        r = S.broadcast(request.user, code, (request.data or {}).get("text"))
        if not r["ok"]:
            return Response(r, status=404 if r["reason"] == "not_school_staff" else
                            429 if r["reason"] == "capped" else 400)
        return Response(r)


class SchoolBusView(APIView):
    def get(self, request, code):
        if _off(request):
            return _feature_off(req_lang(request))
        r = S.bus_get(request.user, code)
        if r is None:
            return Response({"error": "not_found"}, status=404)
        return Response(r)

    def post(self, request, code):
        if _off(request):
            return _feature_off(req_lang(request))
        d = request.data or {}
        r = S.bus_post(request.user, code, d.get("lat"), d.get("lng"))
        return Response(r, status=200 if r["ok"] else
                        404 if r["reason"] == "not_school_staff" else 400)
