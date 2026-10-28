"""
views_probashi.py — PROBASHI FAMILY PLAN API (flag `probashi_plan`, default
OFF: every endpoint answers 403 `feature_off` while hidden; owner / staff /
allow-listed testers preview it). Token auth. Engine: core/probashi_plan.py.

  GET   probashi                          plan facts + my role (payer / member),
                                          seats, pool, invites to me
  GET   probashi/candidates               my accepted My Circle people who can
                                          get a seat (with the reason if not)
  POST  probashi/seats                    {member_id}         payer invites
  POST  probashi/seats/<id>/respond       {accept, consent}   member answers
  POST  probashi/seats/<id>/remove        payer removes (or cancels an invite)
  POST  probashi/seats/<id>/leave         member leaves
  POST  probashi/seats/<id>/transfer      {member_id}         payer swaps
  POST  probashi/seats/<id>/cap           {cap}               payer: monthly cap
  POST  probashi/seats/<id>/consent       {consent}           member: what to share
  GET   probashi/pool                     who spent what this month (payer)
  GET   probashi/family                   family dashboard (payer)
  GET   probashi/reports                  my monthly reports
  POST  probashi/reports/<id>/read
"""
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import probashi_plan as PB
from .i18n import is_play_flavour, pick, req_lang
from .logic import probashi_plan as L

_ERR = {
    "feature_off": ("এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet."),
    "not_probashi": ("এর জন্য প্রবাসী প্ল্যান লাগবে।", "This needs the Probashi plan."),
    "member_not_found": ("এই মানুষটিকে পাওয়া যায়নি।", "We could not find this person."),
    "self": ("নিজেকে সিট দেওয়া যায় না।", "You cannot give a seat to yourself."),
    "not_in_circle": ("আগে দুজনকে আমার সার্কেলে যুক্ত হতে হবে।",
                      "You both need to be connected in My Circle first."),
    "bd_phone_required": ("সিট শুধু বাংলাদেশি (+৮৮০) নম্বরের পরিবারের সদস্যের জন্য।",
                          "Seats are only for family members with a Bangladesh (+880) number."),
    "already_invited": ("এই মানুষটি আগেই আমন্ত্রিত বা যুক্ত আছেন।",
                        "This person is already invited or in your family."),
    "seats_full": ("সব সিট ভরা। কাউকে সরালে সিটটি কিছুদিন পরে খালি হবে।",
                   "All seats are taken. A removed seat frees up after the waiting period."),
    "member_is_payer": ("ইনি নিজেই প্রবাসী প্ল্যান কিনেছেন।", "This person has their own Probashi plan."),
    "person_seated": ("ইনি অন্য একটি প্রবাসী পরিবারে আছেন। এক মানুষ একটাই সিট পান।",
                      "This person is already in a Probashi family. One person, one seat."),
    "person_cooldown": ("ইনি কিছুদিন আগে একটি পরিবার ছেড়েছেন — অপেক্ষার সময় শেষ হলে আবার চেষ্টা করুন।",
                        "This person left a family recently — try again after the waiting period."),
    "seat_not_found": ("সিটটি পাওয়া যায়নি।", "Seat not found."),
    "not_pending": ("এই আমন্ত্রণ আর খোলা নেই।", "This invite is no longer open."),
    "payer_plan_off": ("আমন্ত্রণকারীর প্ল্যান এখন সক্রিয় নেই।", "The inviter's plan is not active now."),
    "not_active": ("সিটটি সক্রিয় নেই।", "This seat is not active."),
    "transfer_limit": ("এই সময়ে আর সিট বদলানো যাবে না — অপেক্ষার সময় শেষ হলে আবার চেষ্টা করুন।",
                       "No more seat swaps right now — try again after the waiting period."),
    "bad_cap": ("সীমাটি ০ বা তার বেশি পূর্ণ সংখ্যা দিন।", "Enter a whole number, 0 or more."),
    "bad_input": ("তথ্যগুলো ঠিক নেই — আবার দেখুন।", "Some details are not right — please check."),
}


def err(lang, code, status=400, **extra):
    bn, en = _ERR.get(code, _ERR["bad_input"])
    d = {"error": code, "detail": pick(lang, bn, en)}
    d.update(extra)
    return Response(d, status=status)


class _Gated(APIView):
    permission_classes = [IsAuthenticated]

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        try:
            from . import feature_flags as FF
            on = FF.is_on(PB.FLAG, request.user, is_play_flavour(request))
        except Exception:
            on = False
        if not on:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied(detail={"error": "feature_off",
                                           "detail": pick(req_lang(request), *_ERR["feature_off"])})

    def handle_exception(self, exc):
        if isinstance(exc, PB.SeatError):
            return err(req_lang(self.request), exc.code, exc.status, **exc.extra)
        return super().handle_exception(exc)

    @property
    def lang(self):
        return req_lang(self.request)


class OverviewView(_Gated):
    def get(self, request):
        return Response(PB.overview(request.user, self.lang))


class CandidatesView(_Gated):
    def get(self, request):
        from .models import CircleMember, ProbashiSeat
        u = request.user
        c = PB.cfg()
        taken = set(ProbashiSeat.objects.filter(payer=u, status__in=PB.LIVE_INVITE)
                    .values_list("member_id", flat=True))
        out, seen = [], set()
        for e in (CircleMember.objects.filter(user=u, state="accepted", blocked=False,
                                              peer_user__isnull=False)
                  .select_related("peer_user")):
            p = e.peer_user
            if p.pk in seen or p.pk == u.pk:
                continue
            seen.add(p.pk)
            reason = ""
            if p.pk in taken:
                reason = "already_invited"
            elif not PB._circle_ok(u, p):
                reason = "not_in_circle"
            elif c["bd_members_only"] and not L.is_bd_phone(PB._canon(p)):
                reason = "bd_phone_required"
            out.append({"id": p.pk, "name": PB._name(p), "relation": e.relation,
                        "eligible": not reason, "reason": reason,
                        "reason_text": pick(self.lang, *_ERR[reason]) if reason else ""})
        return Response({"candidates": out})


class SeatsView(_Gated):
    def post(self, request):
        s = PB.invite(request.user, (request.data or {}).get("member_id"))
        return Response(PB.seat_dict(s, self.lang), status=201)


class SeatActionView(_Gated):
    def post(self, request, pk, action):
        u, d = request.user, (request.data or {})
        if action == "respond":
            s = PB.respond(u, pk, d.get("accept") is True, d.get("consent"))
        elif action == "remove":
            s = PB.remove(u, pk)
        elif action == "leave":
            s = PB.leave(u, pk)
        elif action == "transfer":
            s = PB.transfer(u, pk, d.get("member_id"))
        elif action == "cap":
            s = PB.set_cap(u, pk, d.get("cap"))
        elif action == "consent":
            s = PB.set_consent(u, pk, d.get("consent"))
        else:
            return err(self.lang, "bad_input", 404)
        return Response(PB.seat_dict(s, self.lang))


class PoolView(_Gated):
    def get(self, request):
        if not PB.payer_paid(request.user):
            return err(self.lang, "not_probashi", 402)
        return Response(PB.pool_ledger(request.user, self.lang))


class FamilyView(_Gated):
    def get(self, request):
        return Response(PB.dashboard(request.user, self.lang))


class ReportsView(_Gated):
    def get(self, request):
        from .models import ProbashiReport
        rows = ProbashiReport.objects.filter(recipient=request.user)[:24]
        return Response({"reports": [PB.report_dict(r, self.lang) for r in rows]})


class ReportReadView(_Gated):
    def post(self, request, pk):
        from django.utils import timezone
        from .models import ProbashiReport
        n = ProbashiReport.objects.filter(pk=pk, recipient=request.user, read_at__isnull=True) \
            .update(read_at=timezone.now())
        return Response({"ok": True, "updated": n})
