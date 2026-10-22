"""m3-circle — My Circle "works like WhatsApp" (owner order 21 Oct).

* mutual_add(): adding someone who already asked you IS accepting; adding
  someone you are already connected with returns that edge (no duplicates).
* invite_base(): the live public base for invite links (the old default was
  the retired assisto.asalify.com domain, with no /i/ page behind it).
* CircleInviteRedeemView  POST /circle/invite/redeem {token | link}
  Turns a shared My Circle invite (QR / share link / SMS link) into a real
  connection. The inviter consented by creating + sharing the invite, the
  redeemer consents by redeeming it, so both edges become ACCEPTED. Single-use
  (CircleInvite.used), signature + expiry checked, never self.
"""
from django.conf import settings
from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import circle
from .models import CircleInvite, CircleMember, User
from .i18n import pick, req_lang


def invite_base():
    """https base for /i/<token> links: an explicit APP_DEEP_LINK_BASE_HTTPS,
    else the server's own ASSISTO_BASE_URL when it is https, else the live
    domain. Never the retired assisto.asalify.com default."""
    explicit = (getattr(settings, "APP_DEEP_LINK_BASE_HTTPS", "") or "").strip()
    if explicit:
        return explicit.rstrip("/")
    base = (getattr(settings, "ASSISTO_BASE_URL", "") or "").strip()
    if base.startswith("https://"):
        return base.rstrip("/")
    return "https://lifeassisto.com"


def remember_invite(user, relation, token, minutes=1440):
    """Store a share-link token so it can be redeemed (best effort)."""
    try:
        CircleInvite.objects.create(
            inviter=user, relation=circle.normalize_relation(relation),
            token=token,
            expires_at=timezone.now() + timezone.timedelta(minutes=minutes))
    except Exception:  # noqa: BLE001 — never break the share sheet
        pass


def _accept(row):
    if row.state != "accepted":
        row.state = "accepted"
        row.save(update_fields=["state"])


def mutual_add(me, peer, relation, custom_label=""):
    """Return an ACCEPTED edge when `me` adding `peer` needs no new request:
      * an accepted edge already exists (either direction) -> that edge;
      * `peer` already sent me a pending request -> accept it (both rows), keep
        the relation I just chose for MY row.
    Returns None when a normal outgoing request should be created."""
    mine = (CircleMember.objects.filter(user=me, peer_user=peer, state="accepted")
            .order_by("-id").first())
    if mine is not None:
        return mine
    inc = (CircleMember.objects.filter(user=me, peer_user=peer,
                                       direction="incoming", state="pending")
           .order_by("-id").first())
    if inc is None:
        return None
    with transaction.atomic():
        inc.state = "accepted"
        if relation:
            inc.relation = circle.normalize_relation(relation)
            inc.custom_label = custom_label or ""
            inc.sharing = circle.default_sharing(inc.relation)
        inc.save(update_fields=["state", "relation", "custom_label", "sharing"])
        for out in CircleMember.objects.filter(user=peer, peer_user=me,
                                               direction="outgoing",
                                               state="pending"):
            _accept(out)
    from . import e2_keys  # e2-keys: never a keyless dead-end
    e2_keys.ensure_pair_keys(me, peer)
    return inc


def _token_from(raw):
    raw = (raw or "").strip()
    if "/i/" in raw:
        raw = raw.split("/i/", 1)[1]
    return raw.split("?", 1)[0].split("#", 1)[0].strip().strip("/")


def _edge(owner, peer, direction, relation, custom_label=""):
    # e2-keys: keys are read live from the per-user directory, never copied.
    row = (CircleMember.objects.filter(user=owner, peer_user=peer)
           .exclude(state__in=("blocked",)).order_by("-id").first())
    if row is None:
        row = CircleMember.objects.create(
            user=owner, peer_user=peer, direction=direction,
            name=(getattr(peer, "name", "") or "").strip()[:120],
            phone=(getattr(peer, "phone", "") or "")[:40],
            relation=relation, custom_label=custom_label[:60],
            state="accepted", sharing=circle.default_sharing(relation))
    else:
        _accept(row)
    return row


class CircleInviteRedeemView(APIView):
    """POST /circle/invite/redeem {token | link}  ->  {ok, member, inviter}.
    Errors (bilingual detail + machine reason): bad_token, expired, used,
    self_invite, blocked."""

    def post(self, request):
        from .views_module5 import _member_dict
        lang = req_lang(request)
        data = request.data or {}
        token = _token_from(str(data.get("token") or data.get("link") or ""))

        def err(reason, bn, en, code=status.HTTP_400_BAD_REQUEST):
            return Response({"ok": False, "reason": reason,
                             "detail": pick(lang, bn, en)}, status=code)

        if not token:
            return err("bad_token", "আমন্ত্রণ লিংকটি সঠিক নয়।",
                       "That invite link isn't valid.")
        ok, info = circle.parse_invite_token(token, settings.SECRET_KEY)
        if not ok:
            if "expired" in str(info):
                return err("expired", "এই আমন্ত্রণের মেয়াদ শেষ। নতুন লিংক চেয়ে নিন।",
                           "This invite has expired. Ask for a new link.")
            return err("bad_token", "আমন্ত্রণ লিংকটি সঠিক নয়।",
                       "That invite link isn't valid.")
        inv = CircleInvite.objects.filter(token=token).order_by("-id").first()
        try:
            inviter_id = int(str(token).split(".", 1)[0])
        except (TypeError, ValueError):
            inviter_id = None
        inviter = User.objects.filter(pk=inviter_id, is_active=True).first() \
            if inviter_id else None
        if inviter is None or inv is None:
            return err("bad_token", "আমন্ত্রণ লিংকটি সঠিক নয়।",
                       "That invite link isn't valid.")
        if inviter.id == request.user.id:
            return err("self_invite", "এটি আপনার নিজের আমন্ত্রণ — যাকে যোগ করতে চান তাকে পাঠান।",
                       "This is your own invite — send it to the person you want to add.")
        if CircleMember.objects.filter(
                user__in=(inviter, request.user),
                peer_user__in=(inviter, request.user), state="blocked").exists():
            return err("blocked", "এই সংযোগটি করা যাচ্ছে না।",
                       "This connection isn't possible.", status.HTTP_403_FORBIDDEN)
        already = CircleMember.objects.filter(user=request.user, peer_user=inviter,
                                              state="accepted").first()
        if inv.used and already is None:
            return err("used", "এই আমন্ত্রণ আগেই ব্যবহার হয়েছে। নতুন লিংক চেয়ে নিন।",
                       "This invite was already used. Ask for a new link.")
        rel_inviter = circle.normalize_relation(inv.relation or "friend")
        with transaction.atomic():
            # Inviter's row describes the redeemer with the relation the
            # inviter picked; mine is the reciprocal.
            _edge(inviter, request.user, "outgoing", rel_inviter)
            mine = _edge(request.user, inviter, "incoming",
                         circle.reciprocal_relation(rel_inviter))
            if not inv.used:
                inv.used = True
                inv.save(update_fields=["used"])
        from . import e2_keys  # e2-keys: never a keyless dead-end
        e2_keys.ensure_pair_keys(request.user, inviter)
        return Response({"ok": True, "member": _member_dict(mine),
                         "inviter": {"id": inviter.id,
                                     "name": (inviter.name or "").strip()}},
                        status=status.HTTP_200_OK)
