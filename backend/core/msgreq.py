"""mr1 — My Circle MESSAGE REQUESTS (WhatsApp-like, owner order 22 Oct).

A user can start a chat with ANY Assisto user found by phone and text right
away. Under the hood a message request IS the existing pending My Circle edge
pair (CircleMember: the sender's OUTGOING row + the recipient's INCOMING
row), so Accept is the existing /circle/request/<id>/act accept — both sides
can then text AND call immediately. No new table.

Rules (server-enforced here, used by CircleMessagesView / the request views):
  * before accept the SENDER may send at most N messages
    (limits.message_request_max_msgs, owner-editable, default 3 — connect-flow);
  * new requests per sender per day are capped
    (limits.message_requests_per_day, default 20 — abuse);
  * the recipient's who_can_message = nobody refuses strangers outright;
  * a block (either way) wins: I blocked them -> refused; they blocked me ->
    the request is created but every message is dropped silently (WhatsApp
    semantics — a block is never revealed);
  * connect-flow: NO receipts at all before accept (views_c3_msg.mark skips
    a pending request) — the sender only sees "sent" (the server has it);
  * no calls until accept (circle_calls.can_place_call already refuses an
    unaccepted pair; the app shows no call button);
  * ONE push per sender (the first message), grouped per sender on the
    phone (collapse key msgreq-<sender_id>); every message also gets the
    silent delivery ping so ticks stay honest.
"""
from datetime import timedelta

from django.db import transaction
from django.utils import timezone

from .logic import circle
from .models import CircleMember, CircleMessage, CirclePrivacy

DEFAULT_MAX_MSGS = 3
DEFAULT_PER_DAY = 20


def limits():
    """(max messages before accept, new requests per sender per day)."""
    try:
        from . import billing
        lim = billing.cfg()["limits"]
        return (int(lim.get("message_request_max_msgs", DEFAULT_MAX_MSGS)),
                int(lim.get("message_requests_per_day", DEFAULT_PER_DAY)))
    except Exception:  # noqa: BLE001 — never break a send on config
        return DEFAULT_MAX_MSGS, DEFAULT_PER_DAY


def who_can_message(user):
    from .logic import msg_contacts as MC
    pv = CirclePrivacy.objects.filter(user=user).first()
    return MC.normalize_who_can_message(pv.who_can_message if pv else None)


def strangers_refused(recipient):
    from .logic import msg_contacts as MC
    return who_can_message(recipient) == MC.WHO_MSG_NOBODY


def i_blocked(me, peer):
    """Did `me` block `peer` (any of my rows pointing at them)?"""
    return CircleMember.objects.filter(user=me, peer_user=peer).filter(
        blocked=True).exists() or CircleMember.objects.filter(
        user=me, peer_user=peer, state="blocked").exists()


def is_request_edge(edge):
    return (edge is not None and edge.state == "pending"
            and getattr(edge, "peer_user_id", None) is not None)


def sent_count(edge):
    return CircleMessage.objects.filter(member=edge, sender_id=edge.user_id,
                                        group=None).count()


def info(edge):
    """The `request` block on a member payload (None when not pending)."""
    if not is_request_edge(edge):
        return None
    direction = circle.normalize_direction(getattr(edge, "direction", ""))
    max_msgs, _ = limits()
    out = {"direction": direction, "limit": max_msgs}
    if direction == "outgoing":
        n = sent_count(edge)
        out.update(sent=n, can_send=n < max_msgs)
    else:
        out.update(sent=0, can_send=False)
    return out


def send_gate(edge):
    """Gate a send on a NOT-accepted edge. Returns (ok, reason, first):
      ok=True  -> store it as a pre-accept message (first = no earlier one);
      ok=False -> refuse with `reason` (request_limit / accept_first /
                  strangers_refused / not_connected)."""
    if not is_request_edge(edge):
        return False, "not_connected", False
    if circle.normalize_direction(edge.direction) != "outgoing":
        return False, "accept_first", False
    peer = edge.peer_user
    if peer is None or not peer.is_active:
        return False, "not_connected", False
    if strangers_refused(peer):
        return False, "strangers_refused", False
    max_msgs, _ = limits()
    n = sent_count(edge)
    if n >= max_msgs:
        return False, "request_limit", False
    return True, "ok", n == 0


def created_today(me):
    since = timezone.now() - timedelta(hours=24)
    return CircleMember.objects.filter(
        user=me, direction="outgoing", created_at__gte=since,
        peer_user__isnull=False).count()


def over_daily_limit(me):
    _, per_day = limits()
    return created_today(me) >= per_day


def _accept_pair(mine, theirs):
    with transaction.atomic():
        for row in (mine, theirs):
            if row is not None and row.state != "accepted":
                row.state = "accepted"
                row.save(update_fields=["state"])


def start(me, peer, relation="friend"):
    """Open (or create) the 1:1 chat `me` -> `peer`. Returns (edge, reason):
    edge is my CircleMember row (accepted, or my outgoing pending request);
    reason is "ok" / "accepted" / or a refusal (edge None): self, not_found,
    you_blocked, strangers_refused, rate_limited."""
    if peer is None or not getattr(peer, "is_active", True):
        return None, "not_found"
    if peer.pk == me.pk:
        return None, "self"
    if i_blocked(me, peer):
        return None, "you_blocked"
    mine = (CircleMember.objects.filter(user=me, peer_user=peer,
                                        state="accepted").order_by("-id").first())
    if mine is not None:
        return mine, "accepted"
    # They already asked me (pending, or a request I deleted earlier): me
    # starting a chat with them IS accepting — both sides converge.
    theirs = (CircleMember.objects.filter(user=peer, peer_user=me,
                                          direction="outgoing", state="pending")
              .order_by("-id").first())
    if theirs is not None:
        inc = (CircleMember.objects.filter(user=me, peer_user=peer,
                                           direction="incoming")
               .exclude(blocked=True).order_by("-id").first())
        if inc is None:
            inc = CircleMember.objects.create(
                user=me, peer_user=peer, direction="incoming",
                name=(peer.name or "").strip()[:120],
                phone=(peer.phone or "")[:40],
                relation=circle.reciprocal_relation(theirs.relation),
                state="pending",
                sharing=circle.default_sharing(
                    circle.reciprocal_relation(theirs.relation)))
        _accept_pair(inc, theirs)
        from . import connect_flow, e2_keys
        e2_keys.ensure_pair_keys(me, peer)
        connect_flow.on_connected(inc)   # system line + push to them
        return inc, "accepted"
    out = (CircleMember.objects.filter(user=me, peer_user=peer,
                                       direction="outgoing", state="pending")
           .order_by("-id").first())
    if out is not None:
        return out, "ok"
    if strangers_refused(peer):
        return None, "strangers_refused"
    if over_daily_limit(me):
        return None, "rate_limited"
    from . import connect_flow
    if connect_flow.recipient_over_limit(peer):
        return None, "recipient_busy"
    rel = circle.normalize_relation(relation or "friend")
    recip = circle.reciprocal_relation(rel)
    with transaction.atomic():
        out = CircleMember.objects.create(
            user=me, peer_user=peer, direction="outgoing",
            name=(peer.name or "").strip()[:120],
            phone=(peer.phone or "")[:40], relation=rel, state="pending",
            sharing=circle.default_sharing(rel))
        inc = (CircleMember.objects.filter(user=peer, peer_user=me,
                                           direction="incoming")
               .order_by("-id").first())
        if inc is None:
            CircleMember.objects.create(
                user=peer, peer_user=me, direction="incoming",
                name=(me.name or "").strip()[:120],
                phone=(me.phone or "")[:40], relation=recip, state="pending",
                sharing=circle.default_sharing(recip))
        elif inc.state in ("declined", "cancelled") and not inc.blocked:
            # an earlier request they deleted: a NEW request shows again
            inc.state = "pending"
            inc.save(update_fields=["state"])
    from . import e2_keys  # keys are invisible plumbing: ask both now
    e2_keys.ensure_pair_keys(me, peer)
    return out, "ok"


def recipient_edge(edge):
    """The recipient's INCOMING row for my outgoing request edge."""
    return (CircleMember.objects.filter(user_id=edge.peer_user_id,
                                        peer_user_id=edge.user_id)
            .order_by("-id").first())


def notify(sender, edge, message, first):
    """Realtime + delivery ping for every pre-accept message; ONE visible
    push per sender (the first message). Recipient deleted/blocked the
    request -> nothing at all. Never raises."""
    try:
        from . import push
        rev = recipient_edge(edge)
        if rev is None or rev.state != "pending" or rev.blocked:
            return False
        recipient = rev.user
        push._x2_notify_new(recipient, "member", rev.id, message.id)
        if not push.is_available():
            return False
        push._x2_silent_sync(recipient, "member", rev.id, message.id,
                             sender.id)
        if not first:
            return True
        prefs = push._m1_notif(recipient)
        if not prefs.get("messages", True):
            return True
        name = push.display_name(sender)
        if prefs.get("show_preview", True):
            tb, te = ("মেসেজ অনুরোধ — %s" % name,
                      "Message request from %s" % name)
        else:
            tb, te = "নতুন মেসেজ অনুরোধ", "New message request"
        return push.safe_push(
            recipient, "message_request", tb, te,
            "দেখতে Assisto খুলুন — গ্রহণ করলে উত্তর দিতে ও কল করতে পারবেন",
            "Open Assisto to see it — accept to reply and call",
            data={"sender_id": sender.id, "chat_kind": "member",
                  "chat_id": rev.id, "group_key": sender.id,
                  "route": "circle/requests"})
    except Exception:  # noqa: BLE001
        return False


def pending_senders(user, sender_ids):
    """Of `sender_ids`, the ones whose chat with `user` is still an
    unaccepted request on `user`'s side (their messages may be DELIVERED but
    never READ until accept)."""
    ids = {int(i) for i in sender_ids if i}
    if not ids:
        return set()
    accepted = set(CircleMember.objects.filter(
        user=user, peer_user_id__in=ids, state="accepted")
        .values_list("peer_user_id", flat=True))
    pend = set(CircleMember.objects.filter(
        user=user, peer_user_id__in=ids, direction="incoming")
        .exclude(state="accepted").values_list("peer_user_id", flat=True))
    return pend - accepted


def public_phone(user):
    """The sender's registered number for a request card — ONLY when the
    sender allows showing it (User.show_phone), else ""."""
    if not getattr(user, "show_phone", False):
        return ""
    from .phone import canonical_phone
    return canonical_phone(getattr(user, "phone", "") or "") or ""
