"""e-gaps (owner order E) endpoints. Logic: core/e_gaps.py."""
from django.db.models import Q
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import CircleMessage


class ViewOnceOpenView(APIView):
    """POST /circle/messages/<id>/view-once-open — a recipient opens a
    view-once photo / video / voice (1:1 or group; viewonce).

    {want_url: true} (viewonce builds): the open is claimed on the SERVER
    first — a second open is refused (409 already_opened, Bangla + English
    detail) — and the one signed download link comes back.
    No want_url (older builds ack AFTER they downloaded): idempotent."""

    def post(self, request, pk):
        from . import e_gaps
        from . import circle_blobs as CB
        from .i18n import req_lang
        from .models import CircleGroupMember
        x = CircleMessage.objects.filter(pk=pk).select_related("member").first()
        ok_access = False
        if x is not None:
            if x.group_id:
                ok_access = x.sender_id == request.user.id or \
                    CircleGroupMember.objects.filter(
                        group_id=x.group_id, member=request.user,
                        status="active").exists()
            elif x.member is not None:
                ok_access = request.user.id in (x.member.user_id,
                                                 x.member.peer_user_id)
        if not ok_access:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        lang = req_lang(request)
        if not (request.data or {}).get("want_url"):
            ok, code = e_gaps.open_view_once(x, request.user)
            if not ok:
                return Response({"ok": False, "reason": code,
                                 "detail": e_gaps.refusal_text(code, lang)},
                                status=status.HTTP_400_BAD_REQUEST)
            x.refresh_from_db()
            at = (x.view_once_opens or {}).get(str(request.user.id))
            return Response({"ok": True, "state": code, "opened_at": at})
        ref = x.blob_ref
        ok, code = e_gaps.claim_open(x, request.user)
        if not ok:
            http = (status.HTTP_409_CONFLICT if code == "already_opened"
                    else status.HTTP_410_GONE if code == "expired"
                    else status.HTTP_400_BAD_REQUEST)
            return Response({"ok": False, "reason": code,
                             "detail": e_gaps.refusal_text(code, lang)},
                            status=http)
        x.refresh_from_db()
        out = {"ok": True, "state": code,
               "opened_at": (x.view_once_opens or {}).get(str(request.user.id))}
        if ref and CB.valid_ref(ref):
            out.update({"url": CB.signed_url(ref, request.user.id),
                        "expires_in": CB.URL_TTL_S})
        return Response(out)


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
