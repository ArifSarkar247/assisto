"""famcare (owner review 28 Oct) — Family Care endpoints. Logic lives in
core/famcare.py; every route is per-user and server-checked."""
from django.utils.dateparse import parse_datetime
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import famcare as FC
from .i18n import pick, req_lang

_MSG = {
    "family_limit": ("পরিবারে সর্বোচ্চ {n} জন রাখা যায়।",
                     "You can keep up to {n} family members."),
    "not_in_circle": ("এই মানুষটি আপনার My Circle-এ নেই।",
                      "This person is not in your My Circle."),
    "not_linked": ("এই সদস্য My Circle-এ যুক্ত নন। আগে তাঁকে My Circle-এ যোগ করুন।",
                   "This member is not linked to My Circle. Add them to My Circle first."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "title_required": ("একটা শিরোনাম লিখুন।", "Write a title."),
    "text_required": ("কী কিনতে হবে লিখুন।", "Write what to buy."),
    "rate_limited": ("আজ এই সদস্যকে অনেক কাজ দেওয়া হয়েছে। কাল আবার চেষ্টা করুন।",
                     "Too many tasks for this member today. Try again tomorrow."),
    "list_full": ("লিস্ট ভরে গেছে — কেনা জিনিসগুলো মুছে দিন।",
                  "The list is full — clear the bought items."),
    "forbidden": ("এই লিস্টে আপনার অনুমতি নেই।", "You can't use this list."),
    "no_members": ("অন্তত একজন সদস্য বাছুন।", "Pick at least one member."),
}

_CODE = {"family_limit": status.HTTP_403_FORBIDDEN,
         "forbidden": status.HTTP_403_FORBIDDEN,
         "not_found": status.HTTP_404_NOT_FOUND,
         "not_in_circle": status.HTTP_404_NOT_FOUND,
         "rate_limited": status.HTTP_429_TOO_MANY_REQUESTS}


def refuse(request, reason, **extra):
    bn, en = _MSG.get(reason, _MSG["not_found"])
    n = extra.get("limit", FC.SAFETY_FAMILY_FREE)
    if reason == "family_limit":
        from .family_alerts import bn_num
        bn, en = bn.format(n=bn_num(n)), en.format(n=n)
    return Response({"ok": False, "reason": reason,
                     "detail": pick(req_lang(request), bn, en), **extra},
                    status=_CODE.get(reason, status.HTTP_400_BAD_REQUEST))


class FamilyLimitsView(APIView):
    """GET /family/limits — {limit, used, left, safety_free}."""
    def get(self, request):
        return Response(FC.limits(request.user))


class FamilyCirclePickView(APIView):
    """GET /family/circle-pick — my accepted Circle members, each with the
    family entry it is already linked to (family_id) so the picker shows a
    tick instead of letting the same person be added twice."""
    def get(self, request):
        return Response({"results": FC.circle_candidates(request.user),
                         **FC.limits(request.user)})


class FamilyFromCircleView(APIView):
    """POST /family/from-circle {circle_member_id} — one tap, idempotent."""
    def post(self, request):
        try:
            cid = int((request.data or {}).get("circle_member_id"))
        except (TypeError, ValueError):
            return refuse(request, "not_in_circle")
        fm, created, err = FC.from_circle(request.user, cid)
        if err:
            return refuse(request, err, limit=FC.family_cap(request.user))
        return Response({"ok": True, "created": created, "member": FC.member_dict(fm)},
                        status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


def _due(v):
    if not v:
        return None
    dt = parse_datetime(str(v))
    if dt is None:
        return None
    from django.utils import timezone
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt)
    return dt


class FamilyTasksView(APIView):
    """GET /family/reminders — tasks I assigned (with the member's done state)
    + tasks assigned to me. POST {member_id, title, due_at?, notes?}."""
    def get(self, request):
        return Response(FC.tasks(request.user))

    def post(self, request):
        d = request.data or {}
        try:
            mid = int(d.get("member_id"))
        except (TypeError, ValueError):
            return refuse(request, "not_found")
        r, err = FC.assign_reminder(request.user, mid, d.get("title"),
                                    _due(d.get("due_at")), d.get("notes") or "")
        if err:
            return refuse(request, err)
        return Response({"ok": True, "task": FC.task_dict(r, request.user)},
                        status=status.HTTP_201_CREATED)


class FamilyTaskCancelView(APIView):
    def post(self, request, pk):
        if not FC.cancel_task(request.user, pk):
            return refuse(request, "not_found")
        return Response({"ok": True})


class FamilyShoppingView(APIView):
    """GET /family/shopping — my list + the lists of households I belong to.
    POST {text, qty?, owner_id?} adds an item."""
    def get(self, request):
        return Response({"lists": FC.lists_for(request.user)})

    def post(self, request):
        d = request.data or {}
        it, err = FC.add_item(request.user, d.get("owner_id"), d.get("text"), d.get("qty"))
        if err:
            return refuse(request, err)
        return Response({"ok": True, "item": FC.item_dict(it, request.user)},
                        status=status.HTTP_201_CREATED)


class FamilyShoppingToggleView(APIView):
    def post(self, request, pk):
        done = (request.data or {}).get("done")
        it = FC.toggle_item(request.user, pk, None if done is None else bool(done))
        if it is None:
            return refuse(request, "not_found")
        return Response({"ok": True, "item": FC.item_dict(it, request.user)})


class FamilyShoppingDeleteView(APIView):
    def post(self, request, pk):
        if not FC.delete_item(request.user, pk):
            return refuse(request, "not_found")
        return Response({"ok": True})


class FamilyShoppingClearView(APIView):
    def post(self, request):
        n = FC.clear_done(request.user, (request.data or {}).get("owner_id"))
        if n is None:
            return refuse(request, "forbidden")
        return Response({"ok": True, "removed": n})


class FamilyDocsView(APIView):
    """GET /family/docs — what I shared (with audit) + what is shared with me.
    POST {document_id, member_ids:[...]} — the phone asks for the vault PIN
    before calling this (the PIN never leaves the phone)."""
    def get(self, request):
        return Response(FC.doc_shares(request.user))

    def post(self, request):
        d = request.data or {}
        try:
            did = int(d.get("document_id"))
        except (TypeError, ValueError):
            return refuse(request, "not_found")
        ids = d.get("member_ids") or []
        if not isinstance(ids, list):
            ids = [ids]
        shares, err = FC.share_docs(request.user, did, ids)
        if err:
            return refuse(request, err)
        return Response({"ok": True, "shares": [FC.share_dict(s, request.user) for s in shares]},
                        status=status.HTTP_201_CREATED)


class FamilyDocRevokeView(APIView):
    def post(self, request, pk):
        s = FC.revoke_share(request.user, pk)
        if s is None:
            return refuse(request, "not_found")
        return Response({"ok": True, "share": FC.share_dict(s, request.user)})


class FamilyDocOpenView(APIView):
    """GET /family/docs/<id>/open — the recipient's read: metadata + details;
    /file streams the attachment. 404 once revoked or out of the Circle."""
    def get(self, request, pk):
        s = FC.open_share(request.user, pk)
        if s is None:
            return refuse(request, "not_found")
        d = s.document
        return Response({**FC.share_dict(s, request.user), "note": d.note,
                         "details": d.details or {}})


class FamilyDocFileView(APIView):
    def get(self, request, pk):
        from django.http import FileResponse
        s = FC.open_share(request.user, pk)
        if s is None or not s.document.file:
            return refuse(request, "not_found")
        return FileResponse(s.document.file.open("rb"))
