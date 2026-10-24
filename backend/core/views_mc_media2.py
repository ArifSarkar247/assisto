"""mc-media2 — LIVE location updates for My Circle chats (ciphertext only).

A live location is an ordinary E2E "location" message (1:1 or group). While
the sender's app is OPEN, the phone re-encrypts the newest point for every
recipient and replaces that message's ciphertext in place:

  POST /circle/live/<mid>
       1:1   {ciphertext, nonce[, scheme, sender_key_id]}
       group {per_recipient: {member_id: {ciphertext, nonce}}, recipient_ids}

The server never sees a coordinate, the end time or a "stopped" flag — those
are inside the E2E plaintext. It only enforces, from routing metadata:

  * sender only, content_type "location", not deleted;
  * at most LIVE_MAX_S after the message was sent (8 h + slack) — after that
    the message is frozen (the receivers show "Live location ended");
  * the same small-ciphertext cap as a send (core.logic.circle.SHARE_CT_MAX);
  * 1:1: the chat must still be accepted (not blocked); group: the sender
    must still be an ACTIVE member;
  * at most one update per MIN_GAP_S per message (soft, per process).

No push, no new message row: older app versions keep one "Location" bubble.
"""
from datetime import timedelta

from django.core.cache import cache
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import circle_groups as G
from .logic.circle import FORBIDDEN_META_KEYS, SHARE_CT_MAX
from .models import CircleGroupMember, CircleMessage

LIVE_MAX_S = 8 * 3600 + 10 * 60     # the longest choice (8 h) + clock slack
MIN_GAP_S = 5
MAX_RECIPIENTS = 1024


def _bad(why, http=status.HTTP_400_BAD_REQUEST):
    return Response({"detail": why, "reason": why}, status=http)


def _clean_entry(sub):
    """(ciphertext, nonce) of one opaque entry, or None."""
    if not isinstance(sub, dict) or FORBIDDEN_META_KEYS & set(sub.keys()):
        return None
    ct, n = str(sub.get("ciphertext") or ""), str(sub.get("nonce") or "")
    if not ct or not n or len(ct) > SHARE_CT_MAX or len(n) > 128:
        return None
    return ct, n


def live_refusal(x, user, now=None):
    """None when `user` may update message `x` now, else a reason code."""
    now = now or timezone.now()
    if x is None or x.sender_id != user.id:
        return "not_found"
    if x.content_type != "location" or x.deleted:
        return "not_live"
    if now - x.created_at > timedelta(seconds=LIVE_MAX_S):
        return "expired"
    if x.group_id:
        if not CircleGroupMember.objects.filter(
                group_id=x.group_id, member=user,
                status=G.MEMBERSHIP_ACTIVE).exists():
            return "not_found"
    else:
        m = x.member
        if m is None or m.state != "accepted" or getattr(m, "blocked", False):
            return "not_allowed"
    return None


class LiveLocationUpdateView(APIView):
    def post(self, request, mid):
        x = CircleMessage.objects.filter(pk=mid).select_related("member").first()
        why = live_refusal(x, request.user)
        if why == "not_found":
            return _bad(why, status.HTTP_404_NOT_FOUND)
        if why is not None:
            return _bad(why, status.HTTP_409_CONFLICT if why == "expired"
                        else status.HTTP_403_FORBIDDEN)
        d = request.data if isinstance(request.data, dict) else {}
        if FORBIDDEN_META_KEYS & set(d.keys()):
            return _bad("forbidden plaintext/secret field(s)")
        key = "mc2-live-%d" % x.id
        try:
            if cache.get(key):
                return _bad("too_fast", status.HTTP_429_TOO_MANY_REQUESTS)
            cache.set(key, 1, MIN_GAP_S)
        except Exception:  # noqa: BLE001 — a cache glitch never blocks
            pass
        fields = ["ciphertext", "nonce"]
        if x.group_id:
            pr = d.get("per_recipient")
            if not isinstance(pr, dict) or not pr or len(pr) > MAX_RECIPIENTS:
                return _bad("missing per_recipient")
            clean = {}
            for rid, sub in pr.items():
                e = _clean_entry(sub)
                if e is None or not str(rid).isdigit():
                    return _bad("bad per_recipient entry")
                clean[str(rid)] = {"ciphertext": e[0], "nonce": e[1]}
            first = next(iter(clean.values()))
            x.per_recipient = clean
            x.ciphertext, x.nonce = first["ciphertext"], first["nonce"]
            rids = [int(r) for r in clean]
            x.recipient_ids = rids
            fields += ["per_recipient", "recipient_ids"]
        else:
            e = _clean_entry(d)
            if e is None:
                return _bad("missing ciphertext")
            x.ciphertext, x.nonce = e
        for k in ("scheme", "sender_key_id"):
            v = d.get(k)
            if isinstance(v, str) and v and len(v) <= 64:
                setattr(x, k, v)
                fields.append(k)
        x.save(update_fields=fields)
        left = LIVE_MAX_S - (timezone.now() - x.created_at).total_seconds()
        return Response({"ok": True, "id": x.id, "max_left_s": int(max(0, left))})
