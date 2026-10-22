"""mr1 — My Circle message requests (see core/msgreq.py).

POST /circle/message-request/start {phone | to_user_id}
     -> {ok, member, state: accepted|pending}. Opens the 1:1 chat with ANY
     Assisto user found by phone (ANY format, core.phone.find_user) and lets
     the sender text right away. Refusals carry a machine `reason` + a
     bilingual `detail`: bad_phone, not_found, self, you_blocked,
     strangers_refused, rate_limited.
POST /circle/request/<id>/msgreq {action: block|report|delete, reason?}
     -> the RECIPIENT's Block / Report / Delete on an incoming request
     (Accept stays POST /circle/request/<id>/act {event: accept}). Delete is
     silent (the sender is not told — WhatsApp semantics); Block drops every
     further message; Report files a report AND blocks.
"""
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import msgreq
from .i18n import pick, req_lang
from .models import CircleMember, CircleReport, ModerationReport, User

_REFUSALS = {
    "bad_phone": ("নম্বরটি সঠিক নয়। যেমন: ০১৭১২৩৪৫৬৭৮",
                  "That number doesn't look right. Example: 01712345678",
                  status.HTTP_400_BAD_REQUEST),
    "not_found": ("এই নম্বরে কেউ Assisto ব্যবহার করেন না।",
                  "Nobody uses Assisto with this number.",
                  status.HTTP_404_NOT_FOUND),
    "self": ("এটি আপনার নিজের নম্বর।", "That's your own number.",
             status.HTTP_400_BAD_REQUEST),
    "you_blocked": ("আপনি এই মানুষটিকে ব্লক করেছেন। মেসেজ পাঠাতে আগে আনব্লক করুন।",
                    "You blocked this person. Unblock them to send a message.",
                    status.HTTP_403_FORBIDDEN),
    "strangers_refused": ("এই মানুষটি শুধু তাঁর সার্কেলের লোকজনের মেসেজ নেন।",
                          "This person only takes messages from their circle.",
                          status.HTTP_403_FORBIDDEN),
    "rate_limited": ("আজ অনেক নতুন মানুষকে মেসেজ পাঠিয়েছেন। কাল আবার চেষ্টা করুন।",
                     "You've messaged many new people today. Try again tomorrow.",
                     status.HTTP_429_TOO_MANY_REQUESTS),
}


def refusal(lang, reason):
    bn, en, code = _REFUSALS.get(reason, _REFUSALS["not_found"])
    return Response({"ok": False, "reason": reason,
                     "detail": pick(lang, bn, en)}, status=code)


class MessageRequestStartView(APIView):
    def post(self, request):
        from .phone import canonical_phone, find_user, is_discoverable
        from .views_module5 import _member_dict
        lang = req_lang(request)
        d = request.data or {}
        peer = None
        to_id = d.get("to_user_id")
        if to_id not in (None, ""):
            try:
                peer = User.objects.filter(pk=int(to_id), is_active=True).first()
            except (TypeError, ValueError):
                peer = None
        else:
            raw = str(d.get("phone", "")).strip()[:40]
            canon = canonical_phone(raw)
            if not canon:
                return refusal(lang, "bad_phone")
            peer = find_user(canon)
            if peer is not None and peer.id != request.user.id \
                    and not is_discoverable(peer):
                peer = None
        if peer is None:
            return refusal(lang, "not_found")
        edge, reason = msgreq.start(request.user, peer,
                                    str(d.get("relation", "friend")))
        if edge is None:
            return refusal(lang, reason)
        return Response({"ok": True, "state": edge.state,
                         "member": _member_dict(edge)},
                        status=status.HTTP_200_OK)


class MessageRequestActView(APIView):
    def post(self, request, pk):
        lang = req_lang(request)
        edge = CircleMember.objects.filter(user=request.user, pk=pk,
                                           direction="incoming").first()
        if edge is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        d = request.data or {}
        action = str(d.get("action", "")).strip().lower()
        if action not in ("block", "report", "delete"):
            return Response({"detail": "bad action"},
                            status=status.HTTP_400_BAD_REQUEST)
        if edge.state == "accepted" and action == "delete":
            return Response({"detail": "already accepted"},
                            status=status.HTTP_400_BAD_REQUEST)
        reported = False
        if action == "report":
            reason = str(d.get("reason", "spam"))[:20] or "spam"
            note = str(d.get("note", ""))[:1000]
            CircleReport.objects.create(reporter=request.user, target=edge,
                                        reason=reason, note=note)
            ModerationReport.objects.create(
                reporter=request.user, target_kind="person",
                target_id=str(edge.peer_user_id or ""),
                categories=["message_request", reason], note=note, valid=True)
            reported = True
        fields = []
        if action in ("block", "report"):
            edge.blocked = True
            fields.append("blocked")
        if edge.state != "accepted":
            edge.state = "declined"
            fields.append("state")
        if fields:
            edge.save(update_fields=fields)
        done = {
            "delete": ("অনুরোধটি মুছে ফেলা হয়েছে।", "Request deleted."),
            "block": ("ব্লক করা হয়েছে। এই মানুষটি আর মেসেজ পাঠাতে পারবেন না।",
                      "Blocked. This person can't message you any more."),
            "report": ("রিপোর্ট করা হয়েছে এবং ব্লক করা হয়েছে।",
                       "Reported and blocked."),
        }[action]
        return Response({"ok": True, "action": action, "state": edge.state,
                         "blocked": bool(edge.blocked), "reported": reported,
                         "detail": pick(lang, *done)})
