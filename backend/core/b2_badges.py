"""b2-badges — ONE source of truth for the My Circle unread badge + the
notification-centre (bell / Reminders tab) badge watermarks.

My Circle (owner bug: "14" on the home icon never dropped):
  * the per-chat unread number on GET /circle/chats rows and the home badge
    (GET home/badges -> my_circle_unread) are computed by the SAME functions
    here (`count_unread`, `member_unread`, `group_unread`), over the SAME
    visible rows the chat screen shows (views_m1_messenger.visible_* — cleared,
    deleted-for-me and expired rows are already gone);
  * the home badge = the sum the app's My Circle tab shows: every chat row that
    is not archived, `unread` if > 0 else 1 for a manual "Mark as unread"
    (ChatPreview.unreadOf + MsgrHubChatList._publishUnread);
  * messages the user can never open are NEVER counted: a contact that is
    removed / declined / pending / blocked (no accepted, unblocked edge of
    mine), a group I left / was removed from / that was deleted, a message
    deleted for everyone, and orphan rows (the member edge is gone, or I am
    not a party to it).

Realtime: a new CircleMessage, a NotifEvent or a FamilyAlert queues a
`badges.update` event on the shared rt queue (views_c2_calls.RtEvent) for every
recipient, and opening a chat queues one for the reader's other devices, so
the home icons refresh without a restart or pull-to-refresh.
"""
from django.db.models.signals import post_save
from django.utils import timezone

TOPIC = "badges.update"


# ---------------------------------------------------------------------------
# My Circle unread
# ---------------------------------------------------------------------------
def count_unread(user, rows):
    """Incoming, not deleted-for-everyone, not read by `user`."""
    uid = user.id
    return sum(1 for x in rows
               if x.sender_id != uid and (x.deleted or "") != "everyone"
               and uid not in (x.read_by or []))


def member_open(user, edge):
    """Can `user` open this 1:1 chat at all? (own, accepted, not blocked)"""
    return (edge is not None and edge.user_id == user.id
            and edge.state == "accepted" and not edge.blocked)


def member_unread(user, edge, rows=None):
    if not member_open(user, edge):
        return 0
    if rows is None:
        from .views_m1_messenger import visible_conversation
        rows = visible_conversation(user, edge)
    return count_unread(user, rows)


def group_unread(user, group, rows=None):
    from .models import CircleGroupMember
    if group is None or not CircleGroupMember.objects.filter(
            group=group, member=user, status="active").exists():
        return 0
    if rows is None:
        from .views_m1_messenger import visible_group_messages
        rows = visible_group_messages(group, user)
    return count_unread(user, rows)


def unread_by_chat(user):
    """{"member:<edge id>" | "group:<group id>": n} for every chat row the
    chat list shows (archived rows included; see `badge_total`)."""
    from .models import CircleGroupMember, CircleMember
    from .views_m1_messenger import (conversation_edge_map,
                                     visible_conversation,
                                     visible_group_messages)
    out = {}
    edges = list(CircleMember.objects.filter(user=user, state="accepted"))
    # srvperf: one mirror-edge query for every chat (not one per chat)
    emap = conversation_edge_map(user, [m for m in edges
                                        if member_open(user, m)])
    for m in edges:
        out["member:%d" % m.id] = (member_unread(
            user, m, visible_conversation(user, m, emap.get(m.id)))
            if member_open(user, m) else 0)
    for gm in (CircleGroupMember.objects.filter(member=user, status="active")
               .select_related("group")):
        out["group:%d" % gm.group_id] = count_unread(
            user, visible_group_messages(gm.group, user))
    return out


def badge_total(user):
    """The home My Circle badge = the sum the app's chat list / My Circle tab
    shows (non-archived rows; a manual "Mark as unread" row counts 1)."""
    from .models import CircleMember
    from .views_module5 import _organise_map
    from . import views_c3_msg as C3
    counts = unread_by_chat(user)
    try:
        org = _organise_map(user)
    except Exception:
        org = {}
    try:
        flags = C3._flags(user)
    except Exception:
        flags = set()
    blocked = set("member:%d" % i for i in CircleMember.objects.filter(
        user=user, state="accepted", blocked=True).values_list("id", flat=True))
    total = 0
    for key, n in counts.items():
        kind, cid = key.split(":", 1)
        if kind == "member" and org.get(cid, {}).get("archived"):
            continue
        if key in blocked:
            continue
        if n <= 0 and (kind, cid) in flags:
            n = 1
        total += max(0, n)
    return total


def fix_chat_rows(user, rows):
    """Chat-list rows: blocked contacts never show a manual unread dot (they
    count 0 in the badge too)."""
    try:
        from .models import CircleMember
        blocked = set(str(i) for i in CircleMember.objects.filter(
            user=user, state="accepted", blocked=True).values_list("id", flat=True))
        for r in rows:
            if not r.get("is_group") and str(r.get("id")) in blocked:
                r["unread"] = 0
                r["marked_unread"] = False
    except Exception:
        pass
    return rows


# ---------------------------------------------------------------------------
# realtime "badges.update"
# ---------------------------------------------------------------------------
def publish(user_ids, reason="chat"):
    """Queue badges.update for each user id. Never raises."""
    try:
        from .models import RtEvent
        ids = sorted(set(int(u) for u in user_ids if u))
        if not ids:
            return 0
        RtEvent.objects.bulk_create([
            RtEvent(user_id=u, topic=TOPIC, payload={"reason": reason})
            for u in ids])
        return len(ids)
    except Exception:
        return 0


def _on_message(sender, instance, created, **kw):
    if not created or kw.get("raw"):
        return
    try:
        from . import views_c3_msg as C3
        publish(C3.recipients_map([instance]).get(instance.id, []), "chat")
    except Exception:
        pass


def _on_notif(sender, instance, created, **kw):
    if not created or kw.get("raw"):
        return
    publish([getattr(instance, "user_id", None)], "notif")


def connect():
    from .models import CircleMessage, FamilyAlert, NotifEvent
    post_save.connect(_on_message, sender=CircleMessage,
                      dispatch_uid="b2_badges_msg")
    post_save.connect(_on_notif, sender=NotifEvent,
                      dispatch_uid="b2_badges_notif")
    post_save.connect(_on_notif, sender=FamilyAlert,
                      dispatch_uid="b2_badges_fa")


# ---------------------------------------------------------------------------
# Bell / Reminders-tab badge (Facebook / WhatsApp style)
# ---------------------------------------------------------------------------
SCOPES = ("bell", "feed", "reminders")


def watermarks(user):
    from .models import NotifBadgeState
    ns = NotifBadgeState.objects.filter(user=user).first()
    if ns is None:
        return {"bell": None, "feed": None, "reminders": None}
    return {"bell": ns.badge_cleared_at, "feed": ns.feed_tab_cleared_at,
            "reminders": ns.reminders_cleared_at}


def mark_opened(user, scopes, now=None):
    """POST notif/opened — the centre (bell) / a tab was opened: its badge
    watermark moves to now. Items stay unread (bold) until tapped."""
    from .models import NotifBadgeState
    now = now or timezone.now()
    ns, _ = NotifBadgeState.objects.get_or_create(user=user)
    fields = []
    for s in scopes:
        f = {"bell": "badge_cleared_at", "feed": "feed_tab_cleared_at",
             "reminders": "reminders_cleared_at"}.get(s)
        if f:
            setattr(ns, f, now)
            fields.append(f)
    if fields:
        ns.save(update_fields=fields)
    return now
