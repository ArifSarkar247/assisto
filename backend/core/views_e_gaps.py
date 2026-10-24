"""e-gaps (owner order E) endpoints. Logic: core/e_gaps.py."""
from django.db.models import Q
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import CircleMessage


class ViewOnceOpenView(APIView):
    """POST /circle/messages/<id>/view-once-open — the RECIPIENT's phone
    opened a view-once photo: blank the ciphertext + delete the blob."""

    def post(self, request, pk):
        from . import e_gaps
        x = CircleMessage.objects.filter(
            Q(member__user=request.user) | Q(member__peer_user=request.user),
            pk=pk, group__isnull=True).first()
        if x is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        ok, code = e_gaps.open_view_once(x, request.user)
        if not ok:
            return Response({"ok": False, "reason": code},
                            status=status.HTTP_400_BAD_REQUEST)
        return Response({"ok": True, "state": code,
                         "opened_at": x.view_once_opened_at.isoformat()})


class GroupOrganiseView(APIView):
    """POST /circle/groups/<id>/organise {pinned?: bool, archived?: bool} —
    WhatsApp-style pin / archive for a GROUP chat, per user and synced to
    every device of that user (ChatOrganiseState, chat_kind='group'). The
    pin cap (msg_organise.PIN_CAP_PER_USER) counts 1:1 + group pins."""

    def post(self, request, pk):
        from django.utils import timezone
        from .logic import msg_organise as MO
        from .models import ChatOrganiseState, CircleGroupMember
        if not CircleGroupMember.objects.filter(
                group_id=pk, member=request.user, status="active").exists():
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        d = request.data or {}
        row, _ = ChatOrganiseState.objects.get_or_create(
            user=request.user, chat_kind="group", chat_id=str(pk))
        if "pinned" in d:
            want = bool(d.get("pinned"))
            if want:
                count = ChatOrganiseState.objects.filter(
                    user=request.user, chat_kind__in=("member", "group"),
                    pinned=True).exclude(pk=row.pk).count()
                ok, reason = MO.can_pin_chat(count, row.pinned)
                if not ok:
                    return Response({"ok": False, "code": reason},
                                    status=status.HTTP_400_BAD_REQUEST)
            row.pinned = want
            row.pin_at = timezone.now() if want else None
            if want:
                row.archived = False
        if "archived" in d:
            row.archived = bool(d.get("archived"))
            if row.archived:
                row.pinned = False
                row.pin_at = None
        row.save()
        return Response({"ok": True, "pinned": row.pinned,
                         "archived": row.archived,
                         "pin_at": row.pin_at.isoformat() if row.pin_at
                         else None})


def group_organise_map(user):
    """{group_id(str): {pinned, pin_at, archived}} for the chat list."""
    from .models import ChatOrganiseState
    return {s.chat_id: {"pinned": s.pinned,
                        "pin_at": s.pin_at.isoformat() if s.pin_at else None,
                        "archived": s.archived}
            for s in ChatOrganiseState.objects.filter(user=user,
                                                      chat_kind="group")}
