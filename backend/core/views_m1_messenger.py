"""m1-messenger — real backends for every Messenger ⋮ / settings item that the
client used to call against routes that did not exist.

PRIVACY MODEL (unchanged, and respected by every view here):
  * 1:1 + group message BODIES are end-to-end encrypted; the server holds
    ciphertext only and never decrypts. So:
      - "Clear chat" is a PER-USER marker (MsgChatPref.cleared_at): the rows
        stay for the other side, the clearing user never sees them again.
      - "Export chat" builds a file of what the server LEGITIMATELY holds —
        group name, members, and for every message: time, sender, type and the
        REQUESTER'S OWN ciphertext envelope. The device decrypts it locally to
        produce the readable .txt it shares. The file is served only through a
        signed, expiring media link (core/media_sign.py) and purged later.
      - Group AI (summarise / translate / reminder) runs ONLY on text the user
        already decrypted on their device and explicitly sends with the tap —
        the same consent model as Report-last-5. It goes through ai.generate,
        so credits (pricing actions ai_msg_*), the daily budget and the
        no-key state are the existing ones.
  * Two-step PIN and the change-number OTP are stored only as Django password
    hashes; PIN verify is rate-limited (5 tries, then a 15-minute lock).

Every route checks ownership/membership server-side; a non-member gets 404.
"""
import json
import uuid
from datetime import timedelta

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.hashers import check_password, make_password
from django.core.files.base import ContentFile
from django.db import models as dj_models
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang
from .logic import circle_extras as X
from .logic import circle_groups as G
from .logic import circle_messaging as CMSG
from .logic import msg_community as mcom
from .logic import msg_organise as MO
from .models import (ChatOrganiseState, ChatSettings, CircleGroup,
                     CircleGroupMember, CircleMember, CircleMessage,
                     CirclePrivacy, Community, CommunityMember,
                     CommunityMessageRequest, ModerationReport, MsgChatPref,
                     MsgExport, MsgGroupTimer, MsgUserSettings)

User = get_user_model()

# ---------------------------------------------------------------------------
# defaults (also the documented response shapes)
# ---------------------------------------------------------------------------
NOTIF_DEFAULTS = {"messages": True, "groups": True, "calls": True,
                  "show_preview": True, "in_app_sound": True,
                  "in_app_vibrate": True}
CALL_DEFAULTS = {"incoming_calls": True, "silence_unknown": False}
AUTODL_DEFAULTS = {"photos": True, "audio": False, "video": False,
                   "docs": False}
TTL_TOKENS = {"off": 0, "24h": 86400, "7d": 604800, "90d": 7776000}
TTL_BY_SEC = {v: k for k, v in TTL_TOKENS.items()}
GROUP_THEMES = ("default", "ocean", "sunset", "forest")
TWO_STEP_MAX_FAILS = 5
TWO_STEP_LOCK_MIN = 15
OTP_TTL_MIN = 10
OTP_MAX_ATTEMPTS = 5
OTP_RESEND_SEC = 60
EXPORT_TTL_H = 2
AI_TASKS = ("summarise", "translate", "reminder")
AI_MAX_MESSAGES = 200
AI_MAX_CHARS = 12000


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _bad(detail):
    return Response({"detail": detail}, status=status.HTTP_400_BAD_REQUEST)


# ---------------------------------------------------------------------------
# shared helpers (also imported by push.py / views_m2 / views_module5)
# ---------------------------------------------------------------------------
def user_settings(user):
    row, _ = MsgUserSettings.objects.get_or_create(user=user)
    return row


def notif_prefs(user):
    """Effective notification prefs (defaults merged). Never raises."""
    try:
        row = MsgUserSettings.objects.filter(user=user).first()
        stored = (row.notifications or {}) if row else {}
    except Exception:
        stored = {}
    return {k: bool(stored.get(k, v)) for k, v in NOTIF_DEFAULTS.items()}


def call_prefs(user):
    try:
        row = MsgUserSettings.objects.filter(user=user).first()
        stored = (row.calls or {}) if row else {}
    except Exception:
        stored = {}
    return {k: bool(stored.get(k, v)) for k, v in CALL_DEFAULTS.items()}


def chat_pref(user, kind, chat_id, create=False):
    if create:
        row, _ = MsgChatPref.objects.get_or_create(
            user=user, chat_kind=kind, chat_id=str(chat_id))
        return row
    return MsgChatPref.objects.filter(
        user=user, chat_kind=kind, chat_id=str(chat_id)).first()


def reverse_edge(edge):
    """The peer's own CircleMember row pointing back at edge.user, or None."""
    if edge is None:
        return None
    from . import push
    peer = push.member_peer_user(edge)
    if peer is None or peer.pk == edge.user_id:
        return None
    return push._reverse_edge(peer, edge.user)


def organise_muted(user, kind, chat_id):
    """Is (kind, chat_id) muted by `user` via the per-user organise row?"""
    s = ChatOrganiseState.objects.filter(
        user=user, chat_kind=kind, chat_id=str(chat_id)).first()
    if s is None or not (s.mute_until or s.muted_duration):
        return False
    return MO.is_muted({
        "mute_until": s.mute_until.isoformat() if s.mute_until else None,
        "duration": s.muted_duration,
        "muted_at": s.updated_at.isoformat()})


def _organise_mute_state(user, kind, chat_id):
    s = ChatOrganiseState.objects.filter(
        user=user, chat_kind=kind, chat_id=str(chat_id)).first()
    if s is None or not organise_muted(user, kind, chat_id):
        return {"mute": "off", "muted_until": None}
    return {"mute": s.muted_duration or "always",
            "muted_until": s.mute_until.isoformat() if s.mute_until else None}


def _visible(user, rows, cleared_at=None, ttl=0, since=None, now=None):
    """Drop rows the viewer cleared, deleted-for-me, or that are past the
    disappearing TTL (sent at/after the timer started) — the purge job deletes
    those for real; this keeps them invisible between purge runs."""
    now = now or timezone.now()
    out = []
    for x in rows:
        if cleared_at is not None and x.created_at <= cleared_at:
            continue
        if user.id in (x.hidden_for or []):
            continue
        if ttl and since is not None and x.created_at >= since and \
                X.is_expired(x.created_at, ttl, now=now):
            continue
        out.append(x)
    return out


def conversation_rows(edge):
    """Every 1:1 message of the conversation `edge` belongs to: the ones sent
    on this edge AND the ones the peer sent on their reverse edge."""
    # Same thread rule as m2-reality's views_module5._thread_q (mirror edge =
    # owner is my peer, peer_user is me), plus the phone-matched reverse edge.
    q = dj_models.Q(member=edge)
    if getattr(edge, "peer_user_id", None):
        q |= dj_models.Q(member__user_id=edge.peer_user_id,
                         member__peer_user_id=edge.user_id)
    rev = reverse_edge(edge)
    if rev is not None:
        q |= dj_models.Q(member=rev)
    return CircleMessage.objects.filter(q, group=None).order_by(
        "created_at", "id")


def visible_conversation(user, edge):
    pref = chat_pref(user, "member", edge.id)
    cs = ChatSettings.objects.filter(user=user, peer=edge).first()
    ttl = X.normalize_disappearing(cs.disappearing_sec) if cs else 0
    return _visible(user, conversation_rows(edge),
                    cleared_at=pref.cleared_at if pref else None,
                    ttl=ttl, since=pref.disappearing_since if pref else None)


def group_timer(group):
    return MsgGroupTimer.objects.filter(group=group).first()


def visible_group_messages(group, user):
    pref = chat_pref(user, "group", group.id)
    t = group_timer(group)
    return _visible(user, CircleMessage.objects.filter(group=group)
                    .order_by("created_at"),
                    cleared_at=pref.cleared_at if pref else None,
                    ttl=t.disappearing_sec if t else 0,
                    since=t.since if t else None)


def group_prefs_for(group, user):
    """Per-viewer ⋮ state merged into the group dict so a reload shows the
    truth: mute token, disappearing token, theme, favourite."""
    pref = chat_pref(user, "group", group.id)
    t = group_timer(group)
    m = _organise_mute_state(user, "group", group.id)
    return {
        "mute": m["mute"], "muted_until": m["muted_until"],
        "disappearing": TTL_BY_SEC.get(t.disappearing_sec if t else 0, "off"),
        "disappearing_sec": t.disappearing_sec if t else 0,
        "theme": (pref.theme if pref and pref.theme else "default"),
        "favourite": bool(pref and pref.favourite),
    }


def member_favourite(user, edge_id):
    p = chat_pref(user, "member", edge_id)
    return bool(p and p.favourite)


def apply_chat_settings(user, edge, data):
    """PARTIAL per-chat settings update (only keys present change). A
    disappearing change is mirrored onto the peer's reverse edge — a chat has
    ONE timer, like WhatsApp — and stamps `disappearing_since` on both sides so
    only messages sent after it expire. Raises ValueError on a bad value."""
    row, _ = ChatSettings.objects.get_or_create(user=user, peer=edge)
    d = data or {}
    built = X.build_chat_settings(
        disappearing_sec=d.get("disappearing_sec", row.disappearing_sec),
        wallpaper=d.get("wallpaper", row.wallpaper or "default"),
        theme=d.get("theme", row.theme or "system"),
        wallpaper_blob_ref=d.get("wallpaper_blob_ref",
                                 row.wallpaper_blob_ref or None),
        bubble_scheme=d.get("bubble_scheme", row.bubble_scheme or None))
    changed_timer = ("disappearing_sec" in d and
                     built["disappearing_sec"] != row.disappearing_sec)
    row.disappearing_sec = built["disappearing_sec"]
    row.wallpaper = built.get("wallpaper", "default")
    row.wallpaper_blob_ref = built.get("wallpaper_blob_ref", "") or ""
    row.theme = built.get("theme", "system")
    row.bubble_scheme = built.get("bubble_scheme", "") or ""
    row.save()
    if changed_timer:
        now = timezone.now()
        since = now if row.disappearing_sec else None
        p = chat_pref(user, "member", edge.id, create=True)
        p.disappearing_since = since
        p.save(update_fields=["disappearing_since", "updated_at"])
        rev = reverse_edge(edge)
        if rev is not None:
            rrow, _ = ChatSettings.objects.get_or_create(user=rev.user, peer=rev)
            rrow.disappearing_sec = row.disappearing_sec
            rrow.save(update_fields=["disappearing_sec", "updated_at"])
            rp = chat_pref(rev.user, "member", rev.id, create=True)
            rp.disappearing_since = since
            rp.save(update_fields=["disappearing_since", "updated_at"])
    return row


def parse_mute_until(value):
    """controls {muted_until}: an ISO instant (the client's choice, 'Always'
    = far future), a duration token (8h|1w|always), or null/'' to unmute.
    Returns (aware datetime | None)."""
    if value in (None, "", False, "off"):
        return None
    s = str(value).strip()
    if s in MO.MUTE_DURATIONS:
        if s == "always":
            return timezone.now() + timedelta(days=365 * 100)
        secs = MO.MUTE_8H_SEC if s == "8h" else MO.MUTE_1W_SEC
        return timezone.now() + timedelta(seconds=secs)
    dt = parse_datetime(s)
    if dt is None:
        raise ValueError("bad_muted_until")
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt, timezone.utc)
    return dt if dt > timezone.now() else None


def _fingerprint(public_key):
    import hashlib
    if not public_key:
        return ""
    h = hashlib.sha256(public_key.encode()).hexdigest()
    digits = str(int(h[:30], 16))[:30].rjust(30, "0")
    return " ".join(digits[i:i + 5] for i in range(0, 30, 5))


# ===========================================================================
# 1:1 — contact info + clear chat
# ===========================================================================
_MEDIA_TYPES = ("image", "photo", "video", "audio", "voice", "gif", "sticker")
_DOC_TYPES = ("file", "doc", "document", "pdf")


class ChatInfoView(APIView):
    """GET /circle/<pk>/info — contact-info facts for the viewer's own edge."""

    def get(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return _nf()
        from . import push
        peer = push.member_peer_user(m)
        rows = visible_conversation(request.user, m)
        uid = request.user.id
        media = sum(1 for x in rows if x.content_type in _MEDIA_TYPES)
        docs = sum(1 for x in rows if x.content_type in _DOC_TYPES)
        links = sum(1 for x in rows if x.link_preview)
        starred = sum(1 for x in rows if uid in (x.starred_by or []))
        common = []
        if peer is not None:
            mine = set(CircleGroupMember.objects.filter(
                member=request.user, status="active").values_list(
                "group_id", flat=True))
            theirs = CircleGroupMember.objects.filter(
                member=peer, status="active", group_id__in=mine
            ).select_related("group")
            common = [{"id": r.group_id, "name": r.group.name} for r in theirs]
        # phone: visible inside an accepted circle; otherwise only if the peer
        # did not hide it (CirclePrivacy.phone_hidden, default hidden).
        phone = m.phone or ""
        if m.state != "accepted" and peer is not None:
            pv = CirclePrivacy.objects.filter(user=peer).first()
            if pv is None or pv.phone_hidden:
                phone = ""
        cs = ChatSettings.objects.filter(user=request.user, peer=m).first()
        mu = m.muted_until if (m.muted_until and
                               m.muted_until > timezone.now()) else None
        if mu is None and organise_muted(request.user, "member", m.id):
            st = _organise_mute_state(request.user, "member", m.id)
            mu = st["muted_until"] or "always"
        name = (m.name or "").strip() or (
            (getattr(peer, "name", "") or "").strip() if peer else "")
        return Response({
            "id": m.id, "name": name,
            "photo": getattr(peer, "photo_url", "") if peer else "",
            "phone": phone, "about": "",
            "relation": m.relation, "custom_label": m.custom_label,
            "state": m.state,
            "media_count": media, "link_count": links, "doc_count": docs,
            "starred_count": starred, "message_count": len(rows),
            "groups_in_common": common,
            "encryption": {"scheme": m.scheme or "x25519",
                           "fingerprint": _fingerprint(m.public_key)},
            "muted_until": mu.isoformat() if hasattr(mu, "isoformat") else mu,
            "disappearing_sec": cs.disappearing_sec if cs else 0,
            "blocked": bool(m.blocked),
            "favourite": member_favourite(request.user, m.id),
        })


class ChatClearView(APIView):
    """POST /circle/<pk>/clear — hide every message up to now FOR THIS USER
    ONLY (keeps the chat entry; the peer's copy is untouched)."""

    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return _nf()
        p = chat_pref(request.user, "member", m.id, create=True)
        p.cleared_at = timezone.now()
        p.save(update_fields=["cleared_at", "updated_at"])
        return Response({"ok": True, "cleared_at": p.cleared_at.isoformat()})


# ===========================================================================
# GROUP ⋮
# ===========================================================================
def _group_and_me(request, pk):
    g = CircleGroup.objects.filter(pk=pk).first()
    if g is None:
        return None, None
    mine = CircleGroupMember.objects.filter(
        group=g, member=request.user, status=G.MEMBERSHIP_ACTIVE).first()
    if mine is None:
        return None, None
    return g, mine


class GroupMuteView(APIView):
    """POST /circle/groups/<pk>/mute {duration: 8h|1w|always|off}. Stored on the
    per-user organise row; push.hook_group_message skips a muted member."""

    def post(self, request, pk):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        dur = str((request.data or {}).get("duration", "")).strip()
        if dur not in MO.MUTE_DURATIONS + ("off",):
            return _bad("bad_duration")
        row, _ = ChatOrganiseState.objects.get_or_create(
            user=request.user, chat_kind="group", chat_id=str(g.id))
        if dur == "off":
            row.mute_until = None
            row.muted_duration = None
        else:
            rec = MO.build_mute(str(g.id), dur)
            row.mute_until = parse_datetime(rec["mute_until"]) \
                if rec["mute_until"] else None
            row.muted_duration = rec["duration"]
        row.save()
        st = _organise_mute_state(request.user, "group", g.id)
        return Response({"ok": True, "muted": st["mute"] != "off", **st})


class GroupDisappearingView(APIView):
    """POST /circle/groups/<pk>/disappearing {ttl: off|24h|7d|90d}. ONE timer for
    the whole group (any active member may change it, WhatsApp default);
    enforced by purge_disappearing + the message read."""

    def post(self, request, pk):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        ttl = str((request.data or {}).get("ttl", "")).strip()
        if ttl not in TTL_TOKENS:
            return _bad("bad_ttl")
        sec = TTL_TOKENS[ttl]
        t, _ = MsgGroupTimer.objects.get_or_create(group=g)
        if sec != t.disappearing_sec:
            t.disappearing_sec = sec
            t.since = timezone.now() if sec else None
            t.set_by = request.user
            t.save()
        return Response({"ok": True, "ttl": ttl, "disappearing_sec": sec,
                         "label": X.disappearing_label(sec, req_lang(request))})


class GroupThemeView(APIView):
    """POST /circle/groups/<pk>/theme {color?, wallpaper?} — the viewer's own
    presentation pref for this group."""

    def post(self, request, pk):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        d = request.data or {}
        p = chat_pref(request.user, "group", g.id, create=True)
        if "color" in d:
            c = str(d.get("color") or "default")
            if c not in GROUP_THEMES:
                return _bad("bad_color")
            p.theme = c
        if "wallpaper" in d:
            w = str(d.get("wallpaper") or "")
            if w and w not in {i for (i, _b, _e) in X.BUILTIN_WALLPAPERS}:
                return _bad("bad_wallpaper")
            p.wallpaper = w
        p.save()
        return Response({"ok": True, "theme": p.theme or "default",
                         "wallpaper": p.wallpaper})


class GroupFavouriteView(APIView):
    """POST /circle/groups/<pk>/favourite {on} — feeds the hub Favourites chip."""

    def post(self, request, pk):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        p = chat_pref(request.user, "group", g.id, create=True)
        p.favourite = bool((request.data or {}).get("on", True))
        p.save(update_fields=["favourite", "updated_at"])
        return Response({"ok": True, "favourite": p.favourite})


class GroupClearView(APIView):
    """POST /circle/groups/<pk>/clear — per-user clear marker."""

    def post(self, request, pk):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        p = chat_pref(request.user, "group", g.id, create=True)
        p.cleared_at = timezone.now()
        p.save(update_fields=["cleared_at", "updated_at"])
        return Response({"ok": True, "cleared_at": p.cleared_at.isoformat()})


class GroupMessageActView(APIView):
    """POST /circle/groups/<pk>/messages/<mid>/<action> — the path the group
    chat screen uses. react|pin delegate to the existing group action view;
    star toggles the viewer's star; delete = for-me (hidden_for) or, for the
    sender inside the window, for-everyone."""

    def post(self, request, pk, mid, action):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        x = CircleMessage.objects.filter(pk=mid, group=g).first()
        if x is None:
            return _nf()
        if action in ("react", "pin"):
            from .views_m2 import CircleGroupMessageActionView
            return CircleGroupMessageActionView().post(request, mid, action)
        d = request.data or {}
        uid = request.user.id
        if action == "star":
            starred = set(x.starred_by or [])
            want = bool(d.get("starred", uid not in starred))
            (starred.add if want else starred.discard)(uid)
            x.starred_by = sorted(starred)
            x.save(update_fields=["starred_by"])
            return Response({"ok": True, "starred": want})
        if action == "delete":
            scope = str(d.get("scope", "me"))
            if scope == "everyone":
                env = {"sender_id": x.sender_id, "created_at": x.created_at,
                       "deleted": x.deleted or ""}
                if not CMSG.can_delete_for_everyone(env, uid):
                    return Response({"ok": False, "detail": "delete_window"},
                                    status=status.HTTP_403_FORBIDDEN)
                x.deleted = "everyone"
                x.ciphertext = ""
                x.nonce = ""
                x.per_recipient = None
                x.save(update_fields=["deleted", "ciphertext", "nonce",
                                      "per_recipient"])
                return Response({"ok": True, "deleted": "everyone"})
            hidden = set(x.hidden_for or [])
            hidden.add(uid)
            x.hidden_for = sorted(hidden)
            x.save(update_fields=["hidden_for"])
            return Response({"ok": True, "deleted": "me"})
        return _bad("unknown action")


class GroupExportView(APIView):
    """GET /circle/groups/<pk>/export?media=false -> {url, filename, expires_at,
    message_count, encrypted:true}. The JSON file holds only what the server
    legitimately has (see module doc); `url` is a signed, expiring media link.
    Media blobs are never bundled (media=true is reported back as
    media_included:false — the server has only opaque blob refs)."""

    def get(self, request, pk):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        uid = request.user.id
        names = {r.member_id: (r.member.name or "").strip()
                 for r in CircleGroupMember.objects.filter(group=g)
                 .select_related("member")}
        msgs = []
        for x in visible_group_messages(g, request.user):
            own = None
            if x.sender_id == uid and isinstance(x.per_recipient, dict) \
                    and x.per_recipient:
                # my own message: the copy sealed to one recipient — my device
                # opens it with MY private key + THAT recipient's public key.
                k, ent = next(iter(x.per_recipient.items()))
                if isinstance(ent, dict):
                    own = {"ciphertext": ent.get("ciphertext", ""),
                           "nonce": ent.get("nonce", ""),
                           "peer_member_id": str(k)}
            elif isinstance(x.per_recipient, dict):
                ent = (x.per_recipient.get(str(mine.id))
                       or x.per_recipient.get(str(uid)))
                if isinstance(ent, dict):
                    own = {"ciphertext": ent.get("ciphertext", ""),
                           "nonce": ent.get("nonce", "")}
            msgs.append({
                "id": x.id, "at": x.created_at.isoformat(),
                "sender_id": x.sender_id,
                "sender_name": names.get(x.sender_id, ""),
                "type": x.content_type,
                "deleted": x.deleted == "everyone",
                "sender_key_id": x.sender_key_id,
                "envelope": own,
            })
        doc = {
            "format": "assisto.group-export.v1",
            "encrypted": True,
            "note": "Message bodies are end-to-end encrypted; only the "
                    "requester's own device can decrypt the envelopes.",
            "group": {"id": g.id, "name": g.name},
            "members": [{"user_id": k, "name": v} for k, v in names.items()],
            "exported_at": timezone.now().isoformat(),
            "messages": msgs,
        }
        fname = "group-%d-%s.json" % (g.id, uuid.uuid4().hex[:12])
        exp = MsgExport(user=request.user, group=g, message_count=len(msgs),
                        expires_at=timezone.now() + timedelta(hours=EXPORT_TTL_H))
        exp.file.save(fname, ContentFile(json.dumps(doc, ensure_ascii=False)
                                         .encode("utf-8")), save=False)
        exp.save()
        return Response({"ok": True, "url": exp.file.url,
                         "filename": "%s.txt" % (g.name or "group"),
                         "expires_at": exp.expires_at.isoformat(),
                         "message_count": len(msgs), "encrypted": True,
                         "media_included": False})


def _ai_task_prompt(task, lang, target_lang):
    out_lang = "Bangla" if lang == "bn" else "English"
    if task == "summarise":
        return ("Summarise this group chat in 3-6 short bullet points in %s. "
                "Only use what is in the messages." % out_lang)
    if task == "translate":
        tl = "English" if target_lang == "en" else "Bangla"
        return ("Translate each message into %s, one line per message, "
                "keeping the order. Output only the translations." % tl)
    return ("From these chat messages, extract ONE reminder the user should "
            "set. Reply on ONE line exactly as: TITLE | YYYY-MM-DD HH:MM "
            "(24h, Asia/Dhaka) — or TITLE | none if no time is mentioned. "
            "If there is nothing to remind, reply exactly: NONE. Write the "
            "title in %s." % out_lang)


def _parse_reminder_line(text):
    line = (text or "").strip().splitlines()[0].strip() if text else ""
    if not line or line.upper().startswith("NONE"):
        return None
    title, _, when = line.partition("|")
    title = title.strip()[:200]
    if not title:
        return None
    due = None
    when = when.strip()
    if when and when.lower() != "none":
        from datetime import datetime
        try:
            naive = datetime.strptime(when[:16], "%Y-%m-%d %H:%M")
            import zoneinfo
            due = naive.replace(tzinfo=zoneinfo.ZoneInfo("Asia/Dhaka"))
        except Exception:
            due = None
    return {"title": title, "due_at": due}


class GroupAiView(APIView):
    """POST /circle/groups/<pk>/ai/<task> {messages:[str], target_lang?}.
    task ∈ summarise|translate|reminder. Honest states, always 200:
      {allowed:true, result, reminder?}        AI answered
      {allowed:false, reason:'no_key'|...}      AI off / budget / limit
      {allowed:false, needs_plan:true}          not enough credits
    'reminder' books a real Reminder (source=ai) from the AI's one-line draft."""

    def post(self, request, pk, task):
        g, mine = _group_and_me(request, pk)
        if g is None:
            return _nf()
        if task not in AI_TASKS:
            return _bad("unknown task")
        lang = req_lang(request)
        d = request.data or {}
        raw = d.get("messages") or []
        if not isinstance(raw, list):
            return _bad("messages must be a list")
        lines = [str(s).strip() for s in raw[-AI_MAX_MESSAGES:]
                 if str(s).strip()]
        if not lines:
            return _bad("nothing_to_process")
        data = "\n".join(lines)[-AI_MAX_CHARS:]
        from . import ai
        try:
            text, _cost = ai.generate(
                _ai_task_prompt(task, lang, str(d.get("target_lang", ""))),
                data=data, tier="cheap", max_tokens=700,
                feature="group_ai_%s" % task, user=request.user)
        except ai.AIUnavailable as e:
            reason = e.reason
            body = {"allowed": False, "reason": reason,
                    "needs_plan": reason == "credits",
                    "message": _ai_reason_text(reason, lang)}
            return Response(body)
        out = {"allowed": True, "task": task, "result": (text or "").strip()}
        if task == "reminder":
            draft = _parse_reminder_line(text)
            if draft is None:
                out["reminder"] = None
                out["result"] = pick(lang, "এই মেসেজগুলোতে মনে করানোর মতো কিছু পাওয়া যায়নি।",
                                     "Nothing to remind was found in these messages.")
            else:
                from .models import Reminder
                r = Reminder.objects.create(
                    user=request.user, title=draft["title"],
                    due_at=draft["due_at"], date_only=False, source="ai",
                    notes=pick(lang, "গ্রুপ চ্যাট থেকে: %s", "From group chat: %s")
                    % (g.name or ""))
                out["reminder"] = {"id": r.id, "title": r.title,
                                   "due_at": r.due_at.isoformat()
                                   if r.due_at else None}
                out["result"] = r.title
        return Response(out)


def _ai_reason_text(reason, lang):
    table = {
        "no_key": ("AI এখনো চালু নেই — সার্ভারে AI কী যোগ করা হয়নি।",
                   "AI isn't switched on yet — no AI key is set on the server."),
        "budget": ("আজকের AI সীমা শেষ। পরে আবার চেষ্টা করুন।",
                   "Today's AI budget is used up. Please try again later."),
        "user_limit": ("আজ আপনার AI ব্যবহারের সীমা শেষ।",
                       "You've reached today's AI limit."),
        "credits": ("এই কাজের জন্য যথেষ্ট ক্রেডিট নেই।",
                    "Not enough credits for this."),
        "queued": ("AI এখন সাড়া দিচ্ছে না, ক্রেডিট কাটা হয়নি। পরে চেষ্টা করুন।",
                   "AI isn't responding right now; no credits were used. "
                   "Please try later."),
    }
    bn, en = table.get(reason, table["queued"])
    return pick(lang, bn, en)


# ===========================================================================
# COMMUNITY ⋮
# ===========================================================================
def community_notifications_muted(user, community_id):
    return organise_muted(user, "community", community_id)


class CommunityNotificationsView(APIView):
    """POST /community/<pk>/notifications {muted} — the member's community-wide
    alert switch (stored per user). NOTE: community posts are not relayed or
    pushed by the server yet, so the client shows this as an honest disabled
    item; the switch is stored and returned for when they are."""

    def post(self, request, pk):
        c = Community.objects.filter(pk=pk).first()
        if c is None or not CommunityMember.objects.filter(
                community=c, member=request.user, status="active").exists():
            return _nf()
        muted = bool((request.data or {}).get("muted", True))
        row, _ = ChatOrganiseState.objects.get_or_create(
            user=request.user, chat_kind="community", chat_id=str(c.id))
        row.mute_until = None
        row.muted_duration = MO.MUTE_ALWAYS if muted else None
        row.save()
        return Response({"ok": True, "notifications_muted": muted})


class CommunityLeaveView(APIView):
    """POST /community/<pk>/leave -> {left, allowed, reason?}. Leaves every
    group of the community. LAST-ADMIN protected: if the caller is the only
    admin of a group that still has other members, refuse (200, allowed:false,
    reason 'promote_before_leaving') so the client can explain."""

    def post(self, request, pk):
        c = Community.objects.filter(pk=pk).first()
        if c is None:
            return _nf()
        mine = list(CommunityMember.objects.filter(
            community=c, member=request.user, status="active"))
        if not mine:
            return _nf()
        for m in mine:
            if m.role != "admin":
                continue
            others = CommunityMember.objects.filter(
                group=m.group, status="active").exclude(member=request.user)
            if others.exists() and not others.filter(role="admin").exists():
                return Response({"ok": False, "left": False, "allowed": False,
                                 "reason": "promote_before_leaving",
                                 "group_id": m.group_id})
        for m in mine:
            m.status = "left"
            m.save(update_fields=["status"])
        return Response({"ok": True, "left": True, "allowed": True,
                         "groups_left": len(mine)})


# ===========================================================================
# ACCOUNT — two-step PIN + change number
# ===========================================================================
def _two_step_lock_state(row):
    now = timezone.now()
    if row.two_step_locked_until and row.two_step_locked_until > now:
        return int((row.two_step_locked_until - now).total_seconds()) + 1
    return 0


def verify_two_step(row, pin):
    """(ok, http_status, body). Rate-limited: TWO_STEP_MAX_FAILS wrong PINs ->
    TWO_STEP_LOCK_MIN-minute lock (429). A correct PIN resets the counter."""
    wait = _two_step_lock_state(row)
    if wait:
        return False, 429, {"ok": False, "locked": True,
                            "retry_after_sec": wait}
    if row.two_step_hash and check_password(str(pin or ""), row.two_step_hash):
        if row.two_step_failures:
            row.two_step_failures = 0
            row.two_step_locked_until = None
            row.save(update_fields=["two_step_failures",
                                    "two_step_locked_until", "updated_at"])
        return True, 200, {"ok": True}
    row.two_step_failures += 1
    fields = ["two_step_failures", "updated_at"]
    if row.two_step_failures >= TWO_STEP_MAX_FAILS:
        row.two_step_locked_until = timezone.now() + timedelta(
            minutes=TWO_STEP_LOCK_MIN)
        row.two_step_failures = 0
        fields.append("two_step_locked_until")
        row.save(update_fields=fields)
        return False, 429, {"ok": False, "locked": True,
                            "retry_after_sec": TWO_STEP_LOCK_MIN * 60}
    row.save(update_fields=fields)
    return False, 403, {"ok": False, "reason": "bad_pin",
                        "attempts_left": TWO_STEP_MAX_FAILS
                        - row.two_step_failures}


def _valid_pin(pin):
    s = str(pin or "")
    return len(s) == 6 and s.isdigit()


class TwoStepView(APIView):
    """GET  /circle/account/two-step -> {enabled, email_set, locked, retry_after_sec}
       POST /circle/account/two-step {enabled, pin?, current_pin?, recovery_email?}
    Changing or turning off an ENABLED PIN requires current_pin (rate-limited)."""

    def get(self, request):
        row = user_settings(request.user)
        wait = _two_step_lock_state(row)
        return Response({"enabled": row.two_step_enabled,
                         "email_set": bool(row.recovery_email),
                         "locked": bool(wait), "retry_after_sec": wait})

    def post(self, request):
        d = request.data or {}
        row = user_settings(request.user)
        enabled = bool(d.get("enabled", False))
        if row.two_step_enabled:
            ok, code, body = verify_two_step(row, d.get("current_pin"))
            if not ok:
                if code == 403:
                    body["reason"] = "current_pin_required" if not \
                        d.get("current_pin") else "bad_pin"
                return Response(body, status=code)
        if enabled:
            pin = d.get("pin")
            if not _valid_pin(pin):
                return _bad("pin_must_be_6_digits")
            row.two_step_hash = make_password(str(pin))
            row.two_step_enabled = True
        else:
            row.two_step_hash = ""
            row.two_step_enabled = False
        if "recovery_email" in d:
            row.recovery_email = str(d.get("recovery_email") or "")[:254]
        row.two_step_failures = 0
        row.two_step_locked_until = None
        row.save()
        return Response({"ok": True, "enabled": row.two_step_enabled})


class TwoStepVerifyView(APIView):
    """POST /circle/account/two-step/verify {pin} -> 200 {ok} | 403 {ok:false,
    attempts_left} | 429 {locked, retry_after_sec} | 400 when not enabled."""

    def post(self, request):
        row = user_settings(request.user)
        if not row.two_step_enabled:
            return _bad("two_step_not_enabled")
        ok, code, body = verify_two_step(row, (request.data or {}).get("pin"))
        return Response(body, status=code)


def _otp():
    """The shared OTP service (core/otp.py, built by slot o1-otp: purpose-bound
    issue/verify, key-gated). Import-guarded: until it exists, number change
    honestly reports "SMS not configured"."""
    try:
        from . import otp  # noqa: F401
        if hasattr(otp, "issue") and hasattr(otp, "verify"):
            return otp
    except Exception:
        pass
    return None


def _otp_ok(res):
    if isinstance(res, dict):
        return bool(res.get("ok", res.get("sent", res.get("valid", False))))
    return bool(res)


def sms_configured():
    """True only when the OTP service exists AND says it can send."""
    o = _otp()
    if o is None:
        return False
    try:
        fn = getattr(o, "available", None) or getattr(o, "is_available", None)
        if fn is not None:
            return bool(fn())
        return bool(getattr(settings, "SMS_ENABLED", False))
    except Exception:
        return False


OTP_PURPOSE = "change_number"


def _sms_off(lang):
    return Response({
        "ok": False, "sent": False, "sms_enabled": False,
        "code": "sms_not_configured",
        "detail": pick(lang,
                       "নম্বর বদলাতে SMS কোড লাগে, কিন্তু সার্ভারে এখনো SMS সেবা "
                       "যুক্ত করা হয়নি।",
                       "Changing your number needs an SMS code, but no SMS "
                       "service is connected on the server yet.")},
        status=status.HTTP_503_SERVICE_UNAVAILABLE)


def _norm_phone(raw):
    """c1-contacts: THE canonical form (core.phone); "" when invalid."""
    from .phone import canonical_phone
    return canonical_phone(raw) or ""


def _phone_taken(phone, me):
    from .phone import variants
    return User.objects.filter(phone__in=variants(phone)).exclude(
        pk=me.pk).exists()


class ChangeNumberStatusView(APIView):
    """GET /circle/account/change-number -> {sms_enabled, two_step_required,
    pending_phone}."""

    def get(self, request):
        row = user_settings(request.user)
        pending = row.pending_phone if (
            row.pending_expires and row.pending_expires > timezone.now()) else ""
        return Response({"sms_enabled": sms_configured(),
                         "two_step_required": row.two_step_enabled,
                         "current_phone": request.user.phone or "",
                         "pending_phone": pending})


class ChangeNumberRequestView(APIView):
    """POST /circle/account/change-number/request {new_phone} -> {ok, sent}.
    503 {code:'sms_not_configured'} while no SMS gateway exists."""

    def post(self, request):
        lang = req_lang(request)
        phone = _norm_phone((request.data or {}).get("new_phone"))
        if not phone:
            return _bad("invalid_phone")
        if phone == (request.user.phone or ""):
            return _bad("same_number")
        if _phone_taken(phone, request.user):
            return Response({"ok": False, "detail": "number_in_use"},
                            status=status.HTTP_409_CONFLICT)
        if not sms_configured():
            return _sms_off(lang)
        row = user_settings(request.user)
        now = timezone.now()
        if row.pending_sent_at and \
                (now - row.pending_sent_at).total_seconds() < OTP_RESEND_SEC:
            return Response({"ok": False, "detail": "wait_before_resend",
                             "retry_after_sec": OTP_RESEND_SEC - int(
                                 (now - row.pending_sent_at).total_seconds())},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        try:
            res = _otp().issue(phone, OTP_PURPOSE, request)
        except Exception:
            res = False
        if not _otp_ok(res):
            if isinstance(res, dict) and res.get("status") == 429:
                return Response({"ok": False, "detail": "wait_before_resend"},
                                status=status.HTTP_429_TOO_MANY_REQUESTS)
            return _sms_off(lang)
        row.pending_phone = phone
        row.pending_code_hash = ""
        row.pending_expires = now + timedelta(minutes=OTP_TTL_MIN)
        row.pending_attempts = 0
        row.pending_sent_at = now
        row.save()
        return Response({"ok": True, "sent": True,
                         "expires_in_sec": OTP_TTL_MIN * 60})


class ChangeNumberConfirmView(APIView):
    """POST /circle/account/change-number/confirm {new_phone, code, pin?}
    -> {ok, phone}. Requires the two-step PIN when enabled. Moves the account
    phone (and a phone-based username) and re-points other people's circle
    edges that referenced the old number."""

    def post(self, request):
        d = request.data or {}
        phone = _norm_phone(d.get("new_phone"))
        row = user_settings(request.user)
        now = timezone.now()
        if not row.pending_phone or not row.pending_expires or \
                row.pending_expires <= now or phone != row.pending_phone:
            return _bad("no_pending_request")
        if row.pending_attempts >= OTP_MAX_ATTEMPTS:
            return Response({"ok": False, "detail": "too_many_attempts"},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        if row.two_step_enabled:
            ok, code, body = verify_two_step(row, d.get("pin"))
            if not ok:
                return Response(body, status=code)
        o = _otp()
        try:
            good = o is not None and _otp_ok(
                o.verify(phone, OTP_PURPOSE, str(d.get("code", "")).strip()))
        except Exception:
            good = False
        if not good:
            row.pending_attempts += 1
            row.save(update_fields=["pending_attempts", "updated_at"])
            return Response({"ok": False, "detail": "bad_code",
                             "attempts_left": OTP_MAX_ATTEMPTS
                             - row.pending_attempts},
                            status=status.HTTP_403_FORBIDDEN)
        if _phone_taken(phone, request.user):
            return Response({"ok": False, "detail": "number_in_use"},
                            status=status.HTTP_409_CONFLICT)
        u = request.user
        old = u.phone or ""
        fields = ["phone"]
        u.phone = phone
        if old and u.username == old and not User.objects.filter(
                username=phone).exclude(pk=u.pk).exists():
            u.username = phone
            fields.append("username")
        u.save(update_fields=fields)
        from .phone import sync_phone_hash, variants as _variants
        if old:
            CircleMember.objects.filter(phone__in=_variants(
                _norm_phone(old)) or [old]).exclude(user=u).update(phone=phone)
        # c1-contacts: the UserPhoneHash is created/updated by the User
        # post_save signal (core.signals_c1_phone); call it explicitly too so
        # a number change is matchable immediately.
        sync_phone_hash(u)
        row.pending_phone = ""
        row.pending_code_hash = ""
        row.pending_expires = None
        row.pending_attempts = 0
        row.save()
        return Response({"ok": True, "phone": phone})


# ===========================================================================
# PRIVACY — message requests (stranger first messages, ciphertext only)
# ===========================================================================
def _req_dict(mr):
    s = mr.sender
    return {
        "id": mr.id, "sender_id": s.id,
        "name": (s.name or "").strip() or s.username,
        "phone": (s.phone or "") if s.show_phone else "",
        "photo": s.photo_url,
        "preview": "",           # E2E: the device decrypts `ciphertext`
        "ciphertext": mr.first_ciphertext, "nonce": mr.first_nonce,
        "sender_key_id": mr.sender_key_id,
        "community_id": mr.community_id,
        "community_name": mr.community.name if mr.community else "",
        "at": mr.created_at.isoformat(),
    }


class MessageRequestsView(APIView):
    """GET  /circle/message-requests -> {requests:[...]} pending only.
       POST /circle/message-requests/<id> {action: accept|decline|block|report,
            reason?, also_block?} — recipient-only. Accept lets the sender
            message directly (can_direct_message sees prior 'accepted');
            decline is silent; block also blocks any circle edge to them and
            makes CommunityMessageView refuse them; report files a moderation
            report (harsh reasons / also_block also block)."""

    def get(self, request, pk=None):
        rows = (CommunityMessageRequest.objects
                .filter(recipient=request.user, state="pending")
                .select_related("sender", "community"))
        if pk is not None:
            r = rows.filter(pk=pk).first()
            return Response(_req_dict(r)) if r else _nf()
        return Response({"requests": [_req_dict(r) for r in rows]})

    def post(self, request, pk=None):
        if pk is None:
            return Response({"detail": "method not allowed"},
                            status=status.HTTP_405_METHOD_NOT_ALLOWED)
        lang = req_lang(request)
        mr = CommunityMessageRequest.objects.filter(
            pk=pk, recipient=request.user).first()
        if mr is None:
            return _nf()
        d = request.data or {}
        action = str(d.get("action", "")).strip()
        if action not in ("accept", "decline", "block", "report"):
            return _bad("bad action")
        block = action == "block"
        if action == "report":
            payload = mcom.report_sender(
                request.user.id, mr.sender_id, mr.community_id,
                d.get("reason", "other"), note=str(d.get("note", ""))[:1000],
                also_block=bool(d.get("also_block")), lang=lang)
            ModerationReport.objects.create(
                reporter=request.user, target_kind="person",
                target_id=str(mr.sender_id),
                categories=[str(d.get("reason", "other"))[:40]],
                note=str(d.get("note", ""))[:1000], valid=True)
            block = bool(payload.get("also_block"))
            if not block:
                new_state, _ = mcom.apply_msgreq_event(mr.state, "decline")
                mr.state = new_state
                mr.save(update_fields=["state"])
        if action in ("accept", "decline") or block:
            new_state, changed = mcom.apply_msgreq_event(
                mr.state, "block" if block else action)
            if changed:
                mr.state = new_state
                mr.save(update_fields=["state"])
        if block:
            CircleMember.objects.filter(
                user=request.user, peer_user=mr.sender).update(blocked=True)
        return Response({"ok": True, "action": action, "state": mr.state,
                         "blocked": block})


def stranger_message_refusal(sender, recipient):
    """Extra server gate for CommunityMessageView: returns a refusal reason or
    None. Honors the recipient's Messenger privacy (who_can_message) and a
    block made from the requests inbox."""
    if CommunityMessageRequest.objects.filter(
            sender=sender, recipient=recipient, state="blocked").exists():
        return "blocked"
    pv = CirclePrivacy.objects.filter(user=recipient).first()
    who = (pv.who_can_message if pv else "my_circle") or "my_circle"
    if who != "everyone":
        return "who_my_circle"
    return None


# ===========================================================================
# SETTINGS — notifications / calls / storage
# ===========================================================================
class _PrefsView(APIView):
    field = ""
    defaults = {}

    def get(self, request):
        row = user_settings(request.user)
        stored = getattr(row, self.field) or {}
        return Response({k: bool(stored.get(k, v))
                         for k, v in self.defaults.items()})

    def post(self, request):
        d = request.data or {}
        row = user_settings(request.user)
        stored = dict(getattr(row, self.field) or {})
        for k in self.defaults:
            if k in d:
                stored[k] = bool(d[k])
        setattr(row, self.field, stored)
        row.save(update_fields=[self.field, "updated_at"])
        return Response({"ok": True, **{k: bool(stored.get(k, v))
                                        for k, v in self.defaults.items()}})


class NotificationPrefsView(_PrefsView):
    """messages/groups/calls gate pushes in core/push.py; show_preview=false
    sends a name-free push. in_app_sound/in_app_vibrate are device-side."""
    field = "notifications"
    defaults = NOTIF_DEFAULTS


class CallPrefsView(_PrefsView):
    """incoming_calls=false: placement is refused for callers
    (views_build61.CirclePlaceCallView). silence_unknown=true: no ring push
    unless the caller is in the callee's accepted circle."""
    field = "calls"
    defaults = CALL_DEFAULTS


class StoragePrefsView(APIView):
    """GET  /circle/settings/storage -> REAL server usage from the existing
         storage accounting (billing.storage_state + the same sources
         storage_recompute counts) + auto_download prefs.
       POST {auto_download:{photos,audio,video,docs}}."""

    def get(self, request):
        from . import billing
        from .models import ChatBackup, CircleStatus, Document
        u = request.user
        st = billing.storage_state(u)
        docs = 0
        for d in Document.objects.filter(user=u).only("file"):
            docs += _fsize(d.file)
        media = _fsize(u.photo)
        for s in CircleStatus.objects.filter(
                author=u, expires_at__gt=timezone.now()).only("kind", "meta"):
            if s.kind in ("photo", "video"):
                try:
                    media += int((s.meta or {}).get("byte_size", 0) or 0)
                except (TypeError, ValueError):
                    pass
        backups = sum(int(b.size_bytes or 0)
                      for b in ChatBackup.objects.filter(owner=u))
        row = user_settings(u)
        ad = row.auto_download or {}
        return Response({
            "total_bytes": st["used"], "quota_bytes": st["quota_bytes"],
            "pct": st["pct"], "full": st["full"],
            "media_bytes": media, "docs_bytes": docs,
            "backup_bytes": backups,
            "auto_download": {k: bool(ad.get(k, v))
                              for k, v in AUTODL_DEFAULTS.items()},
        })

    def post(self, request):
        ad_in = (request.data or {}).get("auto_download")
        if not isinstance(ad_in, dict):
            return _bad("auto_download must be an object")
        row = user_settings(request.user)
        ad = dict(row.auto_download or {})
        for k in AUTODL_DEFAULTS:
            if k in ad_in:
                ad[k] = bool(ad_in[k])
        row.auto_download = ad
        row.save(update_fields=["auto_download", "updated_at"])
        return Response({"ok": True, "auto_download": {
            k: bool(ad.get(k, v)) for k, v in AUTODL_DEFAULTS.items()}})


def _fsize(f):
    try:
        return int(f.size) if f else 0
    except Exception:
        return 0
