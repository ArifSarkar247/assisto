"""chat-actions — WhatsApp-style chat actions for My Circle (owner 26 Oct).

  * Delete chat   POST /circle/<pk>/delete-chat          {delete_media?}
                  POST /circle/groups/<pk>/delete-chat   {delete_media?}
      A PER-USER hide: every message up to now is cleared FOR ME and the row
      leaves MY chat list (MsgChatPref.deleted_at) until a newer message
      arrives. The circle membership / group membership is NEVER touched.
  * Clear chat    POST /circle/<pk>/clear {keep_starred?}  (existing route,
                  extended here) — same marker, the row stays.
  * Delete for me / for everyone — the existing message action views, now
      with a server-configurable window (settings.CIRCLE_DELETE_EVERYONE_
      WINDOW_MIN) and REAL server deletion (see `reap`).
  * Default message timer  GET/POST /circle/settings/default-timer {ttl}
      Applied to a NEW 1:1 conversation (first message ever) and to a group
      the user creates.

E2E: the server never sees plaintext. Every action here is metadata on rows
that already hold ciphertext only; deletion removes ciphertext rows, the
per-user re-shared copies (CircleMessageCopy) and the encrypted blobs.

"Removed from the server too": a message nobody in the chat can still see
(each participant deleted it for themselves or cleared / deleted the chat) is
deleted for real — row + encrypted blob — by `reap`. A user's own re-shared
copy is dropped at once on delete-for-me, so a restore never re-delivers it.
"""
from django.conf import settings
from django.utils import timezone

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang

DEFAULT_WINDOW_MIN = 60 * 24 * 2  # WhatsApp: about two days
TTL_TOKENS = {"off": 0, "24h": 86400, "7d": 604800, "90d": 7776000}
TTL_BY_SEC = {v: k for k, v in TTL_TOKENS.items()}
REAP_LIMIT = 2000   # rows examined per action (a huge chat reaps over time)


def delete_window_min():
    """Delete-for-everyone window (minutes), server-configurable."""
    try:
        v = int(getattr(settings, "CIRCLE_DELETE_EVERYONE_WINDOW_MIN",
                        DEFAULT_WINDOW_MIN))
    except (TypeError, ValueError):
        v = DEFAULT_WINDOW_MIN
    return max(1, v)


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _bad(detail):
    return Response({"detail": detail}, status=status.HTTP_400_BAD_REQUEST)


def _truthy(v):
    return v is True or str(v).strip().lower() in ("1", "true", "yes", "on")


# ---------------------------------------------------------------------------
# real server deletion
# ---------------------------------------------------------------------------
def _hidden_for_user(x, uid, pref):
    if uid in (x.hidden_for or []):
        return True
    if pref is not None and pref.cleared_at is not None and \
            x.created_at <= pref.cleared_at:
        if pref.cleared_keep_starred and uid in (x.starred_by or []):
            return False
        return True
    return False


def _participants(x, cache):
    """[(user_id, pref)] of everyone who could still see row `x`."""
    from .models import CircleGroupMember
    from .views_m1_messenger import chat_pref, reverse_edge
    if x.group_id:
        key = ("g", x.group_id)
        if key not in cache:
            uids = list(CircleGroupMember.objects.filter(
                group_id=x.group_id, status="active").values_list(
                "member_id", flat=True))
            from django.contrib.auth import get_user_model
            users = {u.id: u for u in get_user_model().objects.filter(
                id__in=uids)}
            cache[key] = [(uid, chat_pref(users[uid], "group", x.group_id))
                          for uid in uids if uid in users]
        return cache[key]
    edge = x.member
    if edge is None:
        return []
    key = ("m", edge.id)
    if key not in cache:
        out = [(edge.user_id, chat_pref(edge.user, "member", edge.id))]
        rev = reverse_edge(edge)
        if rev is not None:
            out.append((rev.user_id, chat_pref(rev.user, "member", rev.id)))
        elif edge.peer_user_id:
            out.append((edge.peer_user_id, None))   # unknown edge: keep row
        cache[key] = out
    return cache[key]


def reap(rows):
    """Delete for real (row + encrypted blob) every row in `rows` that NO
    participant can still see. Never raises; returns the number deleted."""
    try:
        from . import e_gaps
        cache, gone = {}, []
        for x in list(rows)[:REAP_LIMIT]:
            parts = _participants(x, cache)
            if not parts:
                continue
            if all(_hidden_for_user(x, uid, pref) for uid, pref in parts):
                gone.append(x)
        return e_gaps.purge_rows(gone) if gone else 0
    except Exception:  # noqa: BLE001 — an action never fails because of reap
        return 0


def drop_my_copies(user, rows):
    """e2e-recover copies re-shared to MY key for these rows — gone, so a
    reinstall/restore never re-delivers what I deleted."""
    try:
        from .models import CircleMessageCopy
        ids = [x.id for x in rows]
        if ids:
            CircleMessageCopy.objects.filter(message_id__in=ids,
                                             for_user=user).delete()
    except Exception:  # noqa: BLE001
        pass


def drop_all_copies(x):
    try:
        from .models import CircleMessageCopy
        CircleMessageCopy.objects.filter(message_id=x.id).delete()
    except Exception:  # noqa: BLE001
        pass


def delete_for_me(user, x):
    """Hide `x` for `user`; drop the user's own sealed copy (group fan-out
    entry / re-shared copy); reap it if nobody can see it any more."""
    hidden = set(x.hidden_for or [])
    hidden.add(user.id)
    x.hidden_for = sorted(hidden)
    fields = ["hidden_for"]
    if x.group_id and x.sender_id != user.id and isinstance(
            x.per_recipient, dict) and x.per_recipient:
        from .models import CircleGroupMember
        gm = CircleGroupMember.objects.filter(
            group_id=x.group_id, member=user).first()
        pr = dict(x.per_recipient)
        for k in {str(user.id), str(gm.id) if gm else None} - {None}:
            pr.pop(k, None)
        if pr:   # never leave the map empty (the sender opens their own
            x.per_recipient = pr   # message through one of the copies)
            fields.append("per_recipient")
    x.save(update_fields=fields)
    drop_my_copies(user, [x])
    reap([x])


def delete_for_everyone(x):
    """Tombstone: the ciphertext, link preview, fan-out map, every re-shared
    copy and the encrypted blob are removed from the server."""
    x.deleted = "everyone"
    x.ciphertext = ""
    x.nonce = ""
    x.link_preview = None
    x.per_recipient = None
    x.reactions = {}
    x.save(update_fields=["deleted", "ciphertext", "nonce", "link_preview",
                          "per_recipient", "reactions"])
    drop_all_copies(x)
    if x.blob_ref:
        from . import circle_blobs as CB
        CB.release(x.blob_ref)


# ---------------------------------------------------------------------------
# clear / delete chat (shared by 1:1 + groups)
# ---------------------------------------------------------------------------
def clear_for(user, kind, chat_id, visible_rows, keep_starred=False,
              delete_chat=False):
    """Per-user clear marker at NOW. Returns the response body. The rows that
    vanish for this user are reaped (deleted for real when nobody else can
    see them) and their blob refs are returned so the phone can delete its
    decrypted media files ("Also delete media")."""
    from .models import ChatOrganiseState
    from .views_m1_messenger import chat_pref
    now = timezone.now()
    keep = bool(keep_starred) and not delete_chat
    gone = [x for x in visible_rows
            if not (keep and user.id in (x.starred_by or []))]
    p = chat_pref(user, kind, chat_id, create=True)
    p.cleared_at = now
    p.cleared_keep_starred = keep
    fields = ["cleared_at", "cleared_keep_starred", "updated_at"]
    if delete_chat:
        p.deleted_at = now
        fields.append("deleted_at")
    p.save(update_fields=fields)
    if delete_chat:   # WhatsApp: a deleted chat is no longer pinned/archived
        ChatOrganiseState.objects.filter(
            user=user, chat_kind=kind, chat_id=str(chat_id)).update(
            pinned=False, pin_at=None, archived=False)
    refs = sorted({x.blob_ref for x in gone if x.blob_ref})
    drop_my_copies(user, gone)
    reap(gone)
    return {"ok": True, "cleared_at": now.isoformat(),
            "deleted_at": now.isoformat() if delete_chat else None,
            "keep_starred": keep, "removed": len(gone), "media_refs": refs}


def chat_hidden(user, kind, chat_id, visible_rows):
    """A deleted chat stays out of MY list until a newer message arrives
    (visible_rows are already filtered by the clear marker)."""
    from .views_m1_messenger import chat_pref
    p = chat_pref(user, kind, chat_id)
    return bool(p and p.deleted_at and not visible_rows)


class ChatDeleteView(APIView):
    """POST /circle/<pk>/delete-chat {delete_media?} — my edge only."""

    def post(self, request, pk):
        from .models import CircleMember
        from .views_m1_messenger import visible_conversation
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return _nf()
        rows = visible_conversation(request.user, m)
        body = clear_for(request.user, "member", m.id, rows, delete_chat=True)
        body["delete_media"] = _truthy((request.data or {}).get(
            "delete_media", False))
        return Response(body)


class GroupDeleteChatView(APIView):
    """POST /circle/groups/<pk>/delete-chat — hides the group's chat for me;
    I stay a member (leaving is its own, explicit action)."""

    def post(self, request, pk):
        from .views_m1_messenger import _group_and_me, visible_group_messages
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        rows = visible_group_messages(g, request.user)
        body = clear_for(request.user, "group", g.id, rows, delete_chat=True)
        body["delete_media"] = _truthy((request.data or {}).get(
            "delete_media", False))
        return Response(body)


# ---------------------------------------------------------------------------
# default timer for new chats (Settings > Privacy)
# ---------------------------------------------------------------------------
def default_timer_sec(user):
    try:
        from .models import MsgUserSettings
        row = MsgUserSettings.objects.filter(user=user).first()
        sec = int(row.default_disappearing_sec) if row else 0
    except Exception:  # noqa: BLE001
        return 0
    return sec if sec in TTL_BY_SEC else 0


def apply_default_timer(user, edge):
    """Called BEFORE the first message of a brand-new 1:1 conversation is
    stored. Returns the seconds applied (0 = nothing done)."""
    sec = default_timer_sec(user)
    if not sec:
        return 0
    from .models import ChatSettings
    from .views_m1_messenger import apply_chat_settings, chat_pref
    cs = ChatSettings.objects.filter(user=user, peer=edge).first()
    if cs is not None and cs.disappearing_sec:
        return 0
    p = chat_pref(user, "member", edge.id)
    if p is not None and (p.cleared_at or p.deleted_at):
        return 0   # an old chat I cleared/deleted is not a "new chat"
    apply_chat_settings(user, edge, {"disappearing_sec": sec})
    return sec


def apply_default_group_timer(user, group):
    sec = default_timer_sec(user)
    if not sec:
        return 0
    from .models import MsgGroupTimer
    t, _ = MsgGroupTimer.objects.get_or_create(group=group)
    t.disappearing_sec = sec
    t.since = timezone.now()
    t.set_by = user
    t.save()
    return sec


class DefaultTimerView(APIView):
    """GET/POST /circle/settings/default-timer {ttl: off|24h|7d|90d}."""

    def _body(self, request, sec):
        from .logic import circle_extras as X
        lang = req_lang(request)
        return {"ttl": TTL_BY_SEC.get(sec, "off"), "disappearing_sec": sec,
                "label": X.disappearing_label(sec, lang),
                "choices": [{"ttl": k, "sec": v,
                             "label": X.disappearing_label(v, lang)}
                            for k, v in TTL_TOKENS.items()]}

    def get(self, request):
        return Response(self._body(request, default_timer_sec(request.user)))

    def post(self, request):
        from .views_m1_messenger import user_settings
        d = request.data or {}
        if "ttl" in d:
            ttl = str(d.get("ttl") or "").strip()
            if ttl not in TTL_TOKENS:
                return _bad("bad_ttl")
            sec = TTL_TOKENS[ttl]
        else:
            try:
                sec = int(d.get("disappearing_sec", -1))
            except (TypeError, ValueError):
                sec = -1
            if sec not in TTL_BY_SEC:
                return _bad("bad_ttl")
        row = user_settings(request.user)
        row.default_disappearing_sec = sec
        row.save(update_fields=["default_disappearing_sec", "updated_at"])
        return Response({"ok": True, **self._body(request, sec)})
