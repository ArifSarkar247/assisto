"""fcscreen (Family Care v3) — /family/v3/* endpoints. Logic in core/family_v3.py.
Every route is per-user and checks family membership on the server."""
from django.utils.dateparse import parse_date
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import family_v3 as F3
from .i18n import pick, req_lang

_MSG = {
    "forbidden": ("এটা করার অনুমতি আপনার নেই।", "You can't do this in this family."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "not_in_circle": ("এই মানুষটি আপনার My Circle-এ নেই — আগে My Circle-এ যোগ করুন।",
                      "This person is not in your My Circle — add them there first."),
    "not_guardian": ("শিশুকে যোগ করতে পারেন শুধু তার অনুমোদিত অভিভাবক।",
                     "Only an approved guardian can add a child."),
    "family_limit": ("একজন সর্বোচ্চ ৫টি পরিবারে থাকতে পারেন।",
                     "A person can be in up to 5 families."),
    "member_limit": ("এই পরিবারে আর সদস্য যোগ করা যাবে না (সর্বোচ্চ ২০)।",
                     "This family is full (20 members)."),
    "name_required": ("পরিবারের একটা নাম লিখুন।", "Write a family name."),
    "title_required": ("কাজটা কী, লিখুন।", "Write what needs doing."),
    "task_limit": ("খোলা কাজ অনেক হয়ে গেছে — কিছু কাজ শেষ করুন।",
                   "Too many open tasks — finish some first."),
    "already_taken": ("আরেকজন আগেই কাজটা নিয়েছেন।", "Someone already took this task."),
    "already_done": ("কাজটা আগেই শেষ হয়েছে।", "This task is already done."),
    "use_leave": ("নিজেকে সরাতে 'পরিবার ছাড়ুন' চাপুন।", "To remove yourself, use Leave family."),
    "bad_tz": ("সময় অঞ্চল ঠিক নেই।", "That time zone is not valid."),
    "bad_action": ("অজানা কাজ।", "Unknown action."),
}
_CODE = {"forbidden": 403, "not_guardian": 403, "family_limit": 403, "member_limit": 403,
         "task_limit": 403, "not_found": 404, "not_in_circle": 404,
         "already_taken": 409, "already_done": 409}


def _refuse(request, reason):
    bn, en = _MSG.get(reason, _MSG["not_found"])
    return Response({"ok": False, "reason": reason, "detail": pick(req_lang(request), bn, en)},
                    status=_CODE.get(reason, status.HTTP_400_BAD_REQUEST))


def _d(request):
    return request.data if isinstance(request.data, dict) else {}


class FamiliesView(APIView):
    """GET my families (+ pending invites); POST {name} -> new family."""
    def get(self, request):
        return Response(F3.families_payload(request.user))

    def post(self, request):
        f, err = F3.create_family(request.user, _d(request).get("name"))
        if err:
            return _refuse(request, err)
        return Response({"ok": True, "family": {"id": f.id, "name": f.name, "role": "admin"}},
                        status=status.HTTP_201_CREATED)


class FamilyRenameView(APIView):
    def post(self, request, fid):
        err = F3.rename_family(request.user, fid, _d(request).get("name"))
        return _refuse(request, err) if err else Response({"ok": True})


class FamilyInviteView(APIView):
    """POST {circle_member_id, role, label?, relation?} — invite from My Circle."""
    def post(self, request, fid):
        d = _d(request)
        try:
            cid = int(d.get("circle_member_id"))
        except (TypeError, ValueError):
            return _refuse(request, "not_in_circle")
        m, err = F3.invite(request.user, fid, cid, role=str(d.get("role") or "adult"),
                           label=str(d.get("label") or ""),
                           relation=str(d.get("relation") or ""))
        if err:
            return _refuse(request, err)
        return Response({"ok": True, "state": m.state, "membership_id": m.id})


class InviteAnswerView(APIView):
    def post(self, request, mid, answer):
        if answer not in ("accept", "decline"):
            return _refuse(request, "bad_action")
        m, err = F3.answer_invite(request.user, mid, answer == "accept")
        if err:
            return _refuse(request, err)
        return Response({"ok": True, "state": m.state, "family_id": m.family_id})


class FamilyLeaveView(APIView):
    def post(self, request, fid):
        if not F3.leave(request.user, fid):
            return _refuse(request, "not_found")
        return Response({"ok": True})


class FamilyRemoveView(APIView):
    def post(self, request, fid, uid):
        err = F3.remove_member(request.user, fid, uid)
        return _refuse(request, err) if err else Response({"ok": True})


class FamilyMemberEditView(APIView):
    """POST {label?, relation?, abroad_tz? (self), role? (admin)}"""
    def post(self, request, fid, uid):
        err = F3.update_member(request.user, fid, uid, _d(request))
        return _refuse(request, err) if err else Response({"ok": True})


class FamilyBoardView(APIView):
    def get(self, request, fid):
        b = F3.board(request.user, fid)
        if b is None:
            return _refuse(request, "not_found")
        return Response(b)


class MemberPageView(APIView):
    def get(self, request, uid):
        try:
            fid = int(request.query_params.get("family") or 0)
        except (TypeError, ValueError):
            fid = 0
        p = F3.member_page(request.user, uid, fid)
        if p is None:
            return _refuse(request, "not_found")
        return Response(p)


class FamilyTasksView(APIView):
    def get(self, request, fid):
        if F3.membership(request.user, fid) is None:
            return _refuse(request, "not_found")
        return Response({"tasks": F3.open_tasks(request.user, fid)})

    def post(self, request, fid):
        d = _d(request)
        due = parse_date(str(d.get("due_date") or "")) if d.get("due_date") else None
        t, err = F3.add_task(request.user, fid, d.get("title"), str(d.get("kind") or "other"),
                             due)
        if err:
            return _refuse(request, err)
        return Response({"ok": True, "task": F3.task_dict(request.user, t)},
                        status=status.HTTP_201_CREATED)


class FamilyTaskActionView(APIView):
    def post(self, request, tid, action):
        t, err = F3.task_action(request.user, tid, action)
        if err:
            return _refuse(request, err)
        return Response({"ok": True, "task": F3.task_dict(request.user, t) if t else None})
