"""connect-flow — My Circle CONNECT FLOW (owner order 25 Oct, QUEUE 0b).

Builds on mr1 (core/msgreq.py: a message request IS the pending CircleMember
edge pair). This module adds the server rules the owner asked for:

  * BEFORE accept the sender may send up to N (default 3) TEXT messages —
    no media, links, voice, location, contacts, forwards ([pre_accept_refusal];
    the device also refuses http/www links in the typed text because the
    server only ever sees ciphertext);
  * new requests are capped per sender per day (msgreq) AND per recipient per
    day ([recipient_over_limit], limits.message_requests_per_recipient_day);
  * on accept ([on_connected]) both edges get `connected_at` (the chat moves
    to the top of BOTH chat lists and both phones draw the system line "You
    are now connected"), and the requester gets ONE push "X accepted your
    request — say hi" that opens the chat directly;
  * phone-number invites ([link_phone_invites]): when the invited number
    registers, the inviter's phone-only request is linked to the new account
    and shows in their Requests box; accepting it connects both as above.

Receipts / presence / typing before accept are refused in views_c3_msg
(mark() + set_typing) — the sender never learns more than "the server has
it" until the recipient accepts. Decline / Block never tell the sender.
"""
import logging
import re
from datetime import timedelta

from django.db import transaction
from django.utils import timezone

log = logging.getLogger(__name__)

DEFAULT_PER_RECIPIENT_DAY = 50

# Pre-accept: only plain text. Everything else waits for the accept.
PRE_ACCEPT_KINDS = ("text",)

# Same rule as the app (lib/messaging/connect_flow.dart preAcceptHasLink).
LINK_RE = re.compile(r"(https?://|www\.)", re.IGNORECASE)


def has_link(text):
    return bool(LINK_RE.search(str(text or "")))


def per_recipient_limit():
    try:
        from . import billing
        lim = billing.cfg()["limits"]
        return int(lim.get("message_requests_per_recipient_day",
                           DEFAULT_PER_RECIPIENT_DAY))
    except Exception:  # noqa: BLE001 — never break a send on config
        return DEFAULT_PER_RECIPIENT_DAY


def received_today(peer):
    """New requests `peer` received in the last 24 h (any sender)."""
    from .models import CircleMember
    since = timezone.now() - timedelta(hours=24)
    return CircleMember.objects.filter(
        user=peer, direction="incoming", created_at__gte=since,
        peer_user__isnull=False).count()


def recipient_over_limit(peer):
    return peer is not None and received_today(peer) >= per_recipient_limit()


def pre_accept_refusal(env):
    """None when a pre-accept envelope is allowed, else a machine reason:
    text_only (media / voice / location / contact / forward) or no_links
    (a link preview, or the device's has_link flag)."""
    ct = str(env.get("content_type") or "text")
    if ct not in PRE_ACCEPT_KINDS:
        return "text_only"
    if env.get("forwarded") or int(env.get("forward_hops") or 0) > 0:
        return "text_only"
    if env.get("blob_ref"):
        return "text_only"
    if env.get("link_preview") or env.get("has_link"):
        return "no_links"
    return None


REFUSAL_TEXT = {
    "text_only": ("গ্রহণ না করা পর্যন্ত শুধু লেখা পাঠানো যাবে।",
                  "Only text can be sent until they accept."),
    "no_links": ("গ্রহণ না করা পর্যন্ত লিংক পাঠানো যাবে না।",
                 "Links can't be sent until they accept."),
    "recipient_busy": ("এই মানুষটি আজ অনেক অনুরোধ পেয়েছেন। কাল আবার চেষ্টা করুন।",
                       "This person got many requests today. Try again tomorrow."),
}


def _reverse(edge):
    from .models import CircleMember
    if edge is None or not getattr(edge, "peer_user_id", None):
        return None
    return (CircleMember.objects.filter(user_id=edge.peer_user_id,
                                        peer_user_id=edge.user_id)
            .exclude(blocked=True).order_by("-id").first())


def on_connected(accepter_edge, notify=True, now=None):
    """`accepter_edge` (the accepter's own row) just became accepted.
    Stamp connected_at on both rows and push the OTHER side once.
    Never raises; returns the other side's edge (or None)."""
    try:
        now = now or timezone.now()
        other = _reverse(accepter_edge)
        with transaction.atomic():
            for row in (accepter_edge, other):
                if row is not None:
                    row.connected_at = now
                    row.save(update_fields=["connected_at"])
        if notify and other is not None and other.state == "accepted":
            push_accepted(accepter_edge.user, other)
        return other
    except Exception as e:  # noqa: BLE001
        log.warning("connect_flow.on_connected: %s", type(e).__name__)
        return None


def push_accepted(accepter, requester_edge):
    """'X accepted your request — say hi' to the requester; the tap opens the
    chat (chat_kind/chat_id = the requester's own edge). Never raises."""
    try:
        from . import push
        requester = requester_edge.user
        prefs = push._m1_notif(requester)
        if not prefs.get("messages", True):
            return 0
        name = push.display_name(accepter)
        return push.safe_push(
            requester, "message_request",
            "%s আপনার অনুরোধ গ্রহণ করেছেন — হাই বলুন" % name,
            "%s accepted your request — say hi" % name,
            "চ্যাট খুলতে চাপুন", "Tap to open the chat",
            data={"event": "accepted", "sender_id": accepter.id,
                  "chat_kind": "member", "chat_id": requester_edge.id,
                  "group_key": accepter.id, "route": "circle/chat"})
    except Exception:  # noqa: BLE001
        return 0


def link_phone_invites(user):
    """A new account (or a changed number): every PENDING phone-only request
    other people sent to this number is linked to `user` and mirrored as an
    INCOMING row, so it shows in their Requests box. Returns the count."""
    try:
        from .logic import circle
        from .models import CircleMember
        phone = (getattr(user, "phone", "") or "").strip()
        if not phone or not getattr(user, "is_active", True):
            return 0
        rows = list(CircleMember.objects.filter(
            peer_user__isnull=True, phone=phone, direction="outgoing",
            state="pending").exclude(user=user).select_related("user"))
        n = 0
        for out in rows:
            inviter = out.user
            if inviter is None or not inviter.is_active:
                continue
            with transaction.atomic():
                out.peer_user = user
                out.save(update_fields=["peer_user"])
                if not CircleMember.objects.filter(
                        user=user, peer_user=inviter).exists():
                    rel = circle.reciprocal_relation(out.relation)
                    CircleMember.objects.create(
                        user=user, peer_user=inviter, direction="incoming",
                        name=(inviter.name or "").strip()[:120],
                        phone=(inviter.phone or "")[:40], relation=rel,
                        note=out.note or "", state="pending",
                        sharing=circle.default_sharing(rel))
            n += 1
        return n
    except Exception as e:  # noqa: BLE001 — never break a registration
        log.warning("connect_flow.link_phone_invites: %s", type(e).__name__)
        return 0


def fields(m):
    """Extra member-payload fields (connected_at iso or None)."""
    at = getattr(m, "connected_at", None)
    return {"connected_at": at.isoformat() if at else None}
