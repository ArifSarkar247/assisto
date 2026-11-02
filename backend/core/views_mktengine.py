"""mktengine — Marketing Engine v1 API (flag `marketing_engine`, shop owner only).

  GET    mkt                       overview: questions, saved answers, plan,
                                   real facts, publish + follow-up readiness
  PUT    mkt/profile               save answers ({"answers": {...}, "partial": bool})
  POST   mkt/generate              build / rebuild the plan (approved items kept)
  PATCH  mkt/items/<id>            {"status": draft|approved|rejected, "body": "..."}
  POST   mkt/items/<id>/polish     AI personalise (credits; never adds numbers)
  POST   mkt/items/<id>/activate   approved follow-up -> retention automation (really sends)
  POST   mkt/items/<id>/publish    approved post -> Facebook Page (only when Meta allows)

While the flag is off the server answers 403 feature_off and the app says so.
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import mktengine_service as S
from .i18n import pick, req_lang
from .logic import mktengine as M

_MSG = {
    "owner_only": ("শুধু দোকানের মালিক এটি ব্যবহার করতে পারেন।", "Only the shop owner can use this."),
    "questionnaire_incomplete": ("আগে প্রশ্নমালার সব প্রশ্নের উত্তর দিন।", "Answer every question first."),
    "not_found": ("পাওয়া যায়নি। প্ল্যান আবার বানান।", "Not found. Build the plan again."),
    "bad_status": ("ঠিক হয়নি, আবার চেষ্টা করুন।", "That did not work, please try again."),
    "empty": ("কিছু লিখুন।", "Write something."),
    "too_long": ("লেখা অনেক বড় হয়ে গেছে।", "The text is too long."),
    "approve_first": ("আগে এটি অনুমোদন দিন।", "Approve it first."),
    "not_followup": ("এটি ফলো-আপ নয়।", "This is not a follow-up."),
    "not_polishable": ("এই অংশটি AI দিয়ে বদলানো যায় না।", "This part can't be rewritten by AI."),
    "retention_off": ("ফলো-আপ পাঠাতে 'রিটেনশন অটোমেশন' চালু থাকা দরকার — এখনো চালু হয়নি।",
                      "Sending follow-ups needs Retention automation, which is not on yet."),
    "upgrade_required": ("ফলো-আপ পাঠাতে বিজনেস প্ল্যান দরকার।", "Sending follow-ups needs the Business plan."),
    "too_many": ("অটোমেশনের সর্বোচ্চ সংখ্যা হয়ে গেছে। রিটেনশন স্ক্রিন থেকে একটা মুছুন।",
                 "You have the most automations allowed. Delete one in Retention first."),
    "channel_not_connected": ("এই চ্যানেল এখনো সংযুক্ত নয়।", "That channel is not connected yet."),
    "template_too_long": ("মেসেজ ৪০০ অক্ষরের মধ্যে রাখুন।", "Keep the message under 400 characters."),
    "unknown_variable": ("মেসেজে অচেনা {…} আছে। শুধু {name}, {shop}, {product}, {days} ব্যবহার করুন।",
                         "The message has an unknown {…}. Use only {name}, {shop}, {product}, {days}."),
    "template_required": ("মেসেজ লিখুন।", "Write the message."),
    "meta_review_pending": ("Facebook-এ সরাসরি পোস্ট চালু হবে Meta-র অনুমোদন পেলে। এখন কপি করে নিজের পেজে পোস্ট করুন।",
                            "Direct Facebook posting starts once Meta approves it. For now, copy and post on your Page."),
    "page_not_connected": ("আপনার Facebook পেজ এখনো সংযুক্ত নয়। AI সেলস এজেন্ট → চ্যানেল থেকে সংযুক্ত করুন।",
                           "Your Facebook Page is not connected yet. Connect it in AI sales agent → Channels."),
    "publish_failed": ("Facebook পোস্ট নেয়নি। কিছুক্ষণ পরে আবার চেষ্টা করুন, বা কপি করে পোস্ট করুন।",
                       "Facebook did not accept the post. Try later, or copy and post it yourself."),
    "ai_no_key": ("AI এখনো চালু নেই — টেমপ্লেটের লেখাটাই ব্যবহার করুন।", "AI is not on yet — use the template text."),
    "ai_budget": ("আজকের AI সীমা শেষ। কাল আবার চেষ্টা করুন।", "Today's AI limit is reached. Try tomorrow."),
    "ai_user_limit": ("আজকের AI সীমা শেষ। কাল আবার চেষ্টা করুন।", "Today's AI limit is reached. Try tomorrow."),
    "ai_credits": ("ক্রেডিট যথেষ্ট নেই।", "Not enough credits."),
    "ai_queued": ("AI এখন ব্যস্ত, একটু পরে চেষ্টা করুন।", "AI is busy, try again shortly."),
    "ai_failed": ("AI উত্তর দেয়নি, আবার চেষ্টা করুন।", "AI did not answer, please try again."),
    "ai_changed_numbers": ("AI দাম বা সংখ্যা বদলে ফেলছিল, তাই নেওয়া হয়নি। আগের লেখাই আছে।",
                           "The AI changed a price or number, so it was rejected. The original text stays."),
}


def _err(request, code, status=400, **extra):
    bn, en = _MSG.get(code, ("ঠিক হয়নি, আবার চেষ্টা করুন।", "That did not work, please try again."))
    d = {"error": code, "detail": pick(req_lang(request), bn, en)}
    d.update(extra)
    return Response(d, status=status)


def _play(request):
    try:
        from .i18n import is_play_flavour
        return is_play_flavour(request)
    except Exception:  # noqa: BLE001
        return False


def _lang(request):
    return "en" if req_lang(request) == "en" else "bn"


class _Owner(APIView):
    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        from rest_framework.exceptions import PermissionDenied
        lang = req_lang(request)
        if not S.flag_on(request.user, _play(request)):
            raise PermissionDenied(detail={"error": "feature_off", "detail": pick(
                lang, "এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet.")})
        from .business_views import is_owner, resolve_business
        biz, role = resolve_business(request)
        if biz is None or not is_owner(role):
            raise PermissionDenied(detail={"error": "owner_only", "detail": pick(lang, *_MSG["owner_only"])})
        self.biz = biz


def _plan_payload(request, biz, plan):
    if not plan:
        return None
    live = S.automation_status(biz, plan)
    items = []
    for it in plan.get("items") or []:
        row = dict(it)
        if it.get("automation_id"):
            row["automation_on"] = bool(live.get(it["automation_id"]))
        items.append(row)
    return {"lang": plan.get("lang"), "start": plan.get("start"),
            "generated_at": plan.get("generated_at"), "items": items,
            "facts": plan.get("facts") or []}


class OverviewView(_Owner):
    def get(self, request):
        user, biz, lang = request.user, self.biz, _lang(request)
        answers = S.get_answers(user, biz)
        return Response({
            "shop": (biz.shop_name or "").strip(),
            "questions": M.questions_for(lang),
            "steps": M.N_STEPS,
            "answers": answers,
            "complete": M.is_complete(answers),
            "plan": _plan_payload(request, biz, S.get_plan(user, biz)),
            "publish": S.publish_state(biz),
            "followups": S.retention_state(user, _play(request)),
            "ai_available": _ai_available(),
        })


def _ai_available():
    try:
        from . import ai
        return bool(ai.key_present())
    except Exception:  # noqa: BLE001
        return False


class ProfileView(_Owner):
    def put(self, request):
        partial = bool(request.data.get("partial"))
        clean, problems = S.save_answers(request.user, self.biz, request.data.get("answers"),
                                         partial=partial)
        if problems:
            return _err(request, "questionnaire_incomplete" if problems[0].startswith("missing_")
                        else "bad_status", problems=problems)
        return Response({"answers": clean, "complete": M.is_complete(clean)})


class GenerateView(_Owner):
    def post(self, request):
        plan, problem = S.generate(request.user, self.biz, _lang(request))
        if problem:
            return _err(request, problem)
        return Response({"plan": _plan_payload(request, self.biz, plan)})


class ItemView(_Owner):
    def patch(self, request, item_id):
        data = {k: request.data[k] for k in ("status", "body") if k in request.data}
        it, probs = S.edit_item(request.user, self.biz, item_id, data)
        if probs:
            return _err(request, probs[0], status=404 if probs[0] == "not_found" else 400)
        return Response({"item": it})


class PolishView(_Owner):
    def post(self, request, item_id):
        it, problem = S.polish(request.user, self.biz, item_id, _lang(request))
        if problem:
            status = {"not_found": 404, "ai_credits": 402}.get(problem, 400)
            if problem.startswith("ai_") and problem not in ("ai_credits", "ai_changed_numbers"):
                status = 503
            return _err(request, problem, status=status)
        return Response({"item": it})


class ActivateView(_Owner):
    def post(self, request, item_id):
        a, problem = S.activate_followup(request.user, self.biz, item_id,
                                         channel=request.data.get("channel") or "in_app",
                                         lang=_lang(request), play=_play(request))
        if problem:
            status = {"not_found": 404, "upgrade_required": 402, "retention_off": 409}.get(problem, 400)
            return _err(request, problem, status=status)
        return Response({"automation": a})


class PublishView(_Owner):
    def post(self, request, item_id):
        r, problem = S.publish(request.user, self.biz, item_id)
        if problem:
            status = {"not_found": 404, "meta_review_pending": 409, "page_not_connected": 409,
                      "publish_failed": 502}.get(problem, 400)
            return _err(request, problem, status=status)
        return Response({"published": r})
