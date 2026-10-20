"""Assisto Messenger STEP 3 — backend wiring (thin views over the pure logic).

Four surfaces, each SERVER-ENFORCED by its pure module (a client can never grant
itself a capability, skip a consent flow, reveal a hidden phone, see a count-only
follower, or make the admin read message content):

  1. CONTACTS / INVITES / personal CONNECTION REQUEST  -> core.logic.msg_contacts
  2. COMMUNITIES (consent-gated cross-circle messaging) -> core.logic.msg_community
  3. CHANNELS (one-to-many broadcast, NOT E2E)          -> core.logic.msg_channel
  4. MODERATION + OWNER-ADMIN (public surfaces only)     -> core.logic.msg_moderation

Multi-tenant / ownership scoping is applied on EVERY endpoint (rows are filtered
by request.user; cross-user actions resolve the peer explicitly). Owner/operator-
gated endpoints reuse request.user.is_superuser (the existing owner check).
Public channels/communities are gated behind the per-user owner switch
User.public_surfaces_enabled. Bilingual copy via core.i18n.req_lang.
"""
from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import models as dj_models
from django.utils import timezone

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang
from .logic import circle, circle_calls
from .logic import circle_extras as cx
from .logic import msg_contacts as mc
from .logic import msg_community as mcom
from .logic import msg_channel as mch
from .logic import msg_moderation as mmod
from .logic import msg_messenger_ui as mui
from .models import (
    User as _UserModel,
    UserPhoneHash, ConnectionRequest, InviteOutbound, CircleMember,
    Community, CommunityGroup, CommunityMember, CommunityJoinRequest,
    CommunityMessageRequest,
    Channel, ChannelAdmin, ChannelFollower, ChannelPost, ChannelPoll,
    ChannelPollVote, ChannelVerificationRequest,
    ModerationReport, ModerationItem, ModerationAudit,
    ChatSettings, StarredMessage, ChatList, CallLink, ScheduledCall,
    DeviceLinkToken, LinkedDevice,
)

User = get_user_model()


# ===========================================================================
# shared helpers
# ===========================================================================

def _match_salt():
    """The server-wide contact-match salt (NOT per-user). Falls back to the
    Django SECRET_KEY so matching still works in dev."""
    return getattr(settings, "SERVER_MATCH_SALT", None) or settings.SECRET_KEY


def _is_operator(request):
    """Platform operator / owner gate — reuses the existing superuser (owner)
    check used by the integrations admin."""
    u = request.user
    return bool(u and u.is_authenticated and u.is_superuser)


def _public_user_descriptor(u):
    """A minimal PUBLIC descriptor for a user (never private fields)."""
    return {"id": u.id, "name": (u.name or "").strip() or u.username,
            "photo": u.photo_url, "phone": u.phone or ""}


def _notfound(detail="not found"):
    return Response({"detail": detail}, status=status.HTTP_404_NOT_FOUND)


def _forbidden(detail="forbidden"):
    return Response({"detail": detail}, status=status.HTTP_403_FORBIDDEN)


def _badreq(detail="bad request"):
    return Response({"detail": detail}, status=status.HTTP_400_BAD_REQUEST)


# ===========================================================================
# 1. CONTACTS & INVITES + personal CONNECTION REQUEST  (msg_contacts)
# ===========================================================================

class ContactsMatchView(APIView):
    """POST /messenger/contacts/match  body {hashes:[...], permission_granted:bool}
    -> msg_contacts.match_contacts. STORES NOTHING: we look up each uploaded hash
    in UserPhoneHash (verified users only) and return the matches; non-user hashes
    are never written anywhere. The request body is never persisted."""

    def post(self, request):
        data = request.data or {}
        hashes = data.get("hashes") or []
        permission = bool(data.get("permission_granted", False))
        # Build {hash: public_user_descriptor} ONLY for verified registered users.
        reg = {}
        if permission and hashes:
            rows = (UserPhoneHash.objects
                    .filter(phone_hash__in=[str(h) for h in hashes][:5000])
                    .select_related("user"))
            for r in rows:
                reg[r.phone_hash] = _public_user_descriptor(r.user)
        result = mc.match_contacts(hashes, reg, permission_granted=permission)
        # result["stored"] is False by contract; we persist nothing here.
        return Response(result)


class ContactHashingContractView(APIView):
    """GET /messenger/contacts/contract -> the machine-readable client hashing
    contract so the Flutter client stays in lockstep with the server matcher."""

    def get(self, request):
        base = getattr(settings, "APP_DEEP_LINK_BASE_HTTPS",
                       "https://assisto.asalify.com")
        return Response(mc.hashing_contract(base))


class _InviteBase(APIView):
    def _from_name(self, request):
        return (request.user.name or "").strip() or request.user.username

    def _share_link(self, request, relation):
        token = circle.make_invite_token(
            request.user.id, relation, settings.SECRET_KEY)
        base = getattr(settings, "APP_DEEP_LINK_BASE_HTTPS",
                       "https://assisto.asalify.com")
        return token, f"{base}/i/{token}"


class InviteExistingView(_InviteBase):
    """POST /messenger/invite/existing {to_user_id, relation, custom_label?}
    -> invite_existing_user + create the ConnectionRequest (outgoing)."""

    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        to_id = data.get("to_user_id")
        relation = str(data.get("relation", "")).strip()
        label = str(data.get("custom_label", "")).strip()[:60]
        target = User.objects.filter(pk=to_id).first()
        if target is None:
            return _notfound("user not found")
        if target.id == request.user.id:
            return _badreq(mc.ERR_SELF_REQUEST)
        # daily limit + relation-mandatory via build_connection_request
        sent_log = [{"created_at": r.created_at} for r in
                    ConnectionRequest.objects.filter(requester=request.user)]
        built = mc.build_connection_request(
            request.user.id, target.id, relation, note="", sent_log=sent_log,
            custom_label=label, lang=lang)
        if not built["ok"]:
            return _badreq(built["code"])
        row = built["request"]
        cr, _ = ConnectionRequest.objects.get_or_create(
            requester=request.user, target=target, state="pending",
            defaults={"relation": row["relation"], "custom_label": label,
                      "note": "", "note_used": False})
        from . import push
        fcm = push.is_available()
        descriptor = mc.invite_existing_user(
            self._from_name(request), target.id, relation,
            fcm_available=bool(fcm), lang=lang, custom_label=label)
        InviteOutbound.objects.create(inviter=request.user, channel="in_app")
        return Response({"request_id": cr.id, "descriptor": descriptor},
                        status=status.HTTP_201_CREATED)


class InviteShareLinkView(_InviteBase):
    """POST /messenger/invite/share-link {relation} -> share-sheet descriptor."""

    def post(self, request):
        lang = req_lang(request)
        relation = str((request.data or {}).get("relation", "friend")).strip() or "friend"
        token, link = self._share_link(request, relation)
        InviteOutbound.objects.create(inviter=request.user, channel="share_link",
                                      token=token)
        return Response(mc.invite_non_user_share_link(
            self._from_name(request), link, lang=lang))


class InviteSmsView(_InviteBase):
    """POST /messenger/invite/sms {relation, to_number} -> own-SIM sms: URI
    descriptor. Server NEVER sends; the client opens the composer."""

    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        relation = str(data.get("relation", "friend")).strip() or "friend"
        to_number = str(data.get("to_number", "")).strip()
        token, link = self._share_link(request, relation)
        InviteOutbound.objects.create(inviter=request.user, channel="sms_own_sim",
                                      token=token)
        return Response(mc.invite_non_user_sms(
            self._from_name(request), link, to_number, lang=lang))


class ConnectionRequestCreateView(APIView):
    """POST /messenger/request {target_id, relation, note?}. Enforces relation-
    mandatory, no-self, daily limit (can_send_request/build_connection_request)
    and the ONE-note budget. Persists only on ok."""

    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        target = User.objects.filter(pk=data.get("target_id")).first()
        if target is None:
            return _notfound("user not found")
        relation = str(data.get("relation", "")).strip()
        note = str(data.get("note", ""))
        label = str(data.get("custom_label", "")).strip()[:60]
        sent_log = [{"created_at": r.created_at} for r in
                    ConnectionRequest.objects.filter(requester=request.user)]
        built = mc.build_connection_request(
            request.user.id, target.id, relation, note=note, sent_log=sent_log,
            custom_label=label, lang=lang)
        if not built["ok"]:
            code = built["code"]
            http = (status.HTTP_429_TOO_MANY_REQUESTS
                    if code == mc.ERR_DAILY_LIMIT else status.HTTP_400_BAD_REQUEST)
            return Response({"detail": code, "message": mc.strings(lang).get(
                "daily_limit_reached" if code == mc.ERR_DAILY_LIMIT
                else "relation_required", code)}, status=http)
        row = built["request"]
        cr = ConnectionRequest.objects.create(
            requester=request.user, target=target, relation=row["relation"],
            custom_label=label, note=row["note"], note_used=row["note_used"],
            state="pending")
        return Response(self._dict(cr, lang), status=status.HTTP_201_CREATED)

    @staticmethod
    def _dict(cr, lang="bn"):
        return {"id": cr.id, "requester_id": cr.requester_id,
                "target_id": cr.target_id, "relation": cr.relation,
                "custom_label": cr.custom_label, "note": cr.note,
                "note_used": cr.note_used, "state": cr.state,
                "relation_label": circle.relation_label(cr.relation, lang,
                                                         cr.custom_label),
                "created_at": cr.created_at.isoformat()}


class ConnectionRequestActView(APIView):
    """POST /messenger/request/<id>/act {event in accept|decline|cancel|block}.
    Guarded by act_on_connection_request (2b fix): sender(outgoing)=cancel/block
    only; receiver(incoming)=accept/decline/block. On accept -> create the mutual
    circle edge (circle semantics)."""

    def post(self, request, pk):
        cr = ConnectionRequest.objects.filter(pk=pk).filter(
            dj_models.Q(requester=request.user) | dj_models.Q(target=request.user)
        ).first()
        if cr is None:
            return _notfound()
        direction = "outgoing" if cr.requester_id == request.user.id else "incoming"
        event = str((request.data or {}).get("event", ""))
        allowed, reason = mc.act_on_connection_request(direction, event)
        if not allowed:
            return _forbidden(reason)
        new_state, changed = circle.apply_request_event(cr.state, event)
        if not changed:
            return _badreq("bad event")
        cr.state = new_state
        cr.save(update_fields=["state"])
        if new_state == circle.REQ_ACCEPTED:
            self._create_mutual_edge(cr)
        return Response({"id": cr.id, "state": cr.state})

    @staticmethod
    def _create_mutual_edge(cr):
        """On accept, create the mutual CircleMember edge both directions
        (reusing circle relationship semantics / default sharing)."""
        rel = circle.normalize_relation(cr.relation)
        recip = circle.reciprocal_relation(rel)
        req_u, tgt_u = cr.requester, cr.target
        CircleMember.objects.get_or_create(
            user=req_u, peer_user=tgt_u, direction="outgoing",
            defaults={"name": (tgt_u.name or "").strip(),
                      "phone": (tgt_u.phone or "")[:40], "relation": rel,
                      "state": "accepted", "sharing": circle.default_sharing(rel)})
        CircleMember.objects.get_or_create(
            user=tgt_u, peer_user=req_u, direction="incoming",
            defaults={"name": (req_u.name or "").strip(),
                      "phone": (req_u.phone or "")[:40], "relation": recip,
                      "state": "accepted", "sharing": circle.default_sharing(recip)})


class ConnectionRequestMessageView(APIView):
    """POST /messenger/request/<id>/message — the ONE pre-accept note path.
    Guarded by can_send_before_accept(state, note_used, is_note=True,
    is_call=False): rejects a second note / any other pre-accept message. Only the
    recipient-bound requester may attach the single note."""

    def post(self, request, pk):
        cr = ConnectionRequest.objects.filter(
            pk=pk, requester=request.user).first()
        if cr is None:
            return _notfound()
        allowed, reason = mc.can_send_before_accept(
            cr.state, cr.note_used, is_note=True, is_call=False)
        if not allowed:
            return _forbidden(reason)
        note = str((request.data or {}).get("note", ""))[:mc.REQUEST_NOTE_MAX]
        cr.note = note
        cr.note_used = True
        cr.save(update_fields=["note", "note_used"])
        return Response({"ok": True, "note_used": True})


class ConnectionRequestReportView(APIView):
    """POST /messenger/request/<id>/report {action, reason, note?} ->
    block_or_report_on_request (reuses circle report/block semantics)."""

    def post(self, request, pk):
        lang = req_lang(request)
        cr = ConnectionRequest.objects.filter(pk=pk).filter(
            dj_models.Q(requester=request.user) | dj_models.Q(target=request.user)
        ).first()
        if cr is None:
            return _notfound()
        other = cr.target_id if cr.requester_id == request.user.id else cr.requester_id
        data = request.data or {}
        directive = mc.block_or_report_on_request(
            request.user.id, other, action=data.get("action", "report"),
            reason=data.get("reason", "harassment"),
            note=data.get("note", ""), lang=lang)
        if directive.get("block"):
            blocked, changed = circle.apply_request_event(cr.state, "block")
            if changed:
                cr.state = blocked
                cr.save(update_fields=["state"])
        return Response(directive)


# ===========================================================================
# 2. COMMUNITIES  (msg_community)
# ===========================================================================

def _community_role(community_id, user_id):
    """Resolve a user's role across a community (admin if admin of any group)."""
    m = (CommunityMember.objects
         .filter(community_id=community_id, member_id=user_id, status="active")
         .order_by("-role").first())  # 'admin' < 'member' alpha -> order desc = admin first
    return m.role if m else None


def _group_role(group_id, user_id):
    m = CommunityMember.objects.filter(
        group_id=group_id, member_id=user_id, status="active").first()
    return m.role if m else None


class CommunityCreateView(APIView):
    """POST /api/community/create -> new_community (seeds announcements group +
    creator admin). PUBLIC communities require the owner switch."""

    def post(self, request):
        data = request.data or {}
        if data.get("is_public") and not request.user.public_surfaces_enabled:
            return _forbidden("public_surfaces_disabled")
        try:
            c_row, ann_row, creator_row = mcom.new_community(
                community_id=None, creator_id=request.user.id,
                name=str(data.get("name", "")),
                description=str(data.get("description", "")),
                photo_ref=data.get("photo_ref"))
        except ValueError:
            return _badreq("community name required")
        community = Community.objects.create(
            creator=request.user, name=c_row["name"],
            description=c_row["description"],
            photo_ref=c_row["photo_ref"] or "",
            is_public=bool(data.get("is_public", False)))
        ann = CommunityGroup.objects.create(
            community=community, creator=request.user, kind="announcements",
            name=ann_row["name"], join_mode="request",
            size_limit=ann_row["size_limit"], announcements_only=True)
        CommunityMember.objects.create(
            community=community, group=ann, member=request.user,
            role="admin", status="active")
        return Response({"id": community.id, "name": community.name,
                         "announcements_group_id": ann.id,
                         "is_public": community.is_public},
                        status=status.HTTP_201_CREATED)


class CommunityGroupCreateView(APIView):
    """POST /api/community/<id>/group/create -> new_community_group (admin-only)."""

    def post(self, request, pk):
        community = Community.objects.filter(pk=pk).first()
        if community is None:
            return _notfound()
        if _community_role(community.id, request.user.id) != mcom.ROLE_ADMIN:
            return _forbidden("not_admin")
        data = request.data or {}
        try:
            g_row, creator_row = mcom.new_community_group(
                group_id=None, community_id=community.id,
                creator_id=request.user.id, name=str(data.get("name", "")),
                kind=data.get("kind", "topic"),
                join_mode=data.get("join_mode", "request"),
                description=str(data.get("description", "")),
                photo_ref=data.get("photo_ref"),
                size_limit=data.get("size_limit", mcom.SIZE_LIMIT_DEFAULT))
        except ValueError:
            return _badreq("group name required")
        group = CommunityGroup.objects.create(
            community=community, creator=request.user,
            kind=g_row["kind"], name=g_row["name"],
            description=g_row["description"], photo_ref=g_row["photo_ref"] or "",
            join_mode=g_row["join_mode"], size_limit=g_row["size_limit"],
            announcements_only=g_row["announcements_only"])
        CommunityMember.objects.create(
            community=community, group=group, member=request.user,
            role="admin", status="active")
        return Response({"id": group.id, "name": group.name,
                         "kind": group.kind, "join_mode": group.join_mode},
                        status=status.HTTP_201_CREATED)


class CommunityGroupPatchView(APIView):
    """PATCH /api/community/group/<id> (rules/size/join_mode/announcements) ->
    set_group_rules / set_group_size_limit (admin capability check)."""

    def patch(self, request, pk):
        group = CommunityGroup.objects.filter(pk=pk).first()
        if group is None:
            return _notfound()
        role = _group_role(group.id, request.user.id)
        data = request.data or {}
        fields = []
        if "rules" in data:
            rules, ok = mcom.set_group_rules(role, str(data["rules"]))
            if not ok:
                return _forbidden("not_admin")
            group.rules = rules
            fields.append("rules")
        if "size_limit" in data:
            size, ok = mcom.set_group_size_limit(role, data["size_limit"])
            if not ok:
                return _forbidden("not_admin")
            group.size_limit = size
            fields.append("size_limit")
        if "join_mode" in data:
            if role != mcom.ROLE_ADMIN:
                return _forbidden("not_admin")
            group.join_mode = mcom.normalize_join_mode(data["join_mode"])
            fields.append("join_mode")
        if "announcements_only" in data and group.kind != "announcements":
            if role != mcom.ROLE_ADMIN:
                return _forbidden("not_admin")
            group.announcements_only = bool(data["announcements_only"])
            fields.append("announcements_only")
        if fields:
            group.save(update_fields=fields)
        return Response({"id": group.id, "rules": group.rules,
                         "size_limit": group.size_limit,
                         "join_mode": group.join_mode,
                         "announcements_only": group.announcements_only})


class CommunityGroupsListView(APIView):
    """GET /api/community/<id>/groups -> partition_groups for the caller."""

    def get(self, request, pk):
        community = Community.objects.filter(pk=pk).first()
        if community is None:
            return _notfound()
        groups = list(community.groups.all())
        all_rows = [{"id": g.id, "name": g.name, "kind": g.kind,
                     "join_mode": g.join_mode, "size_limit": g.size_limit}
                    for g in groups]
        active = list(CommunityMember.objects.filter(
            community=community, member=request.user, status="active"
        ).values_list("group_id", flat=True))
        pending = list(CommunityJoinRequest.objects.filter(
            group__community=community, requester=request.user, state="pending"
        ).values_list("group_id", flat=True))
        return Response(mcom.partition_groups(all_rows, active, pending))


class CommunityGroupJoinView(APIView):
    """POST /api/community/group/<id>/join -> request_to_join (open=join now,
    request=create a JoinRequest)."""

    def post(self, request, pk):
        group = CommunityGroup.objects.filter(pk=pk).first()
        if group is None:
            return _notfound()
        size = CommunityMember.objects.filter(group=group, status="active").count()
        already = CommunityMember.objects.filter(
            group=group, member=request.user, status="active").exists()
        has_pending = CommunityJoinRequest.objects.filter(
            group=group, requester=request.user, state="pending").exists()
        decision = mcom.request_to_join(
            {"join_mode": group.join_mode, "size_limit": group.size_limit},
            size, already_member=already, has_pending=has_pending)
        if not decision["allowed"]:
            return _badreq(decision["reason"])
        if decision["action"] == "joined":
            CommunityMember.objects.get_or_create(
                community=group.community, group=group, member=request.user,
                defaults={"role": "member", "status": "active"})
            return Response({"action": "joined", "group_id": group.id})
        jr = CommunityJoinRequest.objects.create(
            group=group, requester=request.user, state="pending")
        return Response({"action": "requested", "request_id": jr.id},
                        status=status.HTTP_201_CREATED)


class CommunityJoinRequestActView(APIView):
    """POST /api/community/join-request/<id>/<action> (approve|reject) ->
    can_approve_join + apply_join_event (admin-only)."""

    def post(self, request, pk, action):
        jr = CommunityJoinRequest.objects.filter(pk=pk).first()
        if jr is None:
            return _notfound()
        group = jr.group
        role = _group_role(group.id, request.user.id)
        size = CommunityMember.objects.filter(group=group, status="active").count()
        if action == "approve":
            gate = mcom.can_approve_join(role, size, group.size_limit, jr.state)
            if not gate["allowed"]:
                return _forbidden(gate["reason"])
        elif role != mcom.ROLE_ADMIN:
            return _forbidden("not_admin")
        new_state, changed = mcom.apply_join_event(jr.state, action)
        if not changed:
            return _badreq("bad event")
        jr.state = new_state
        jr.save(update_fields=["state"])
        if new_state == mcom.JOIN_APPROVED:
            CommunityMember.objects.get_or_create(
                community=group.community, group=group, member=jr.requester,
                defaults={"role": "member", "status": "active"})
        return Response({"id": jr.id, "state": jr.state})


class CommunityMemberRemoveView(APIView):
    """POST /api/community/group/<id>/member/<uid>/remove ->
    can_remove_community_member (last-admin protected)."""

    def post(self, request, pk, uid):
        group = CommunityGroup.objects.filter(pk=pk).first()
        if group is None:
            return _notfound()
        actor_role = _group_role(group.id, request.user.id)
        target = CommunityMember.objects.filter(
            group=group, member_id=uid, status="active").first()
        if target is None:
            return _notfound("member not found")
        admin_count = CommunityMember.objects.filter(
            group=group, role="admin", status="active").count()
        gate = mcom.can_remove_community_member(
            actor_role, target.role, target_is_actor=(int(uid) == request.user.id),
            admin_count=admin_count)
        if not gate["allowed"]:
            return _forbidden(gate["reason"])
        target.status = "removed"
        target.save(update_fields=["status"])
        return Response({"ok": True, "removed": int(uid)})


class CommunityGroupPostView(APIView):
    """POST /api/community/group/<id>/post -> can_post_in_group gate (announcements
    group / announcements_only = admins only), then the ciphertext relay envelope.
    Community posts stay E2E (opaque ciphertext) like 1:1/groups."""

    def post(self, request, pk):
        group = CommunityGroup.objects.filter(pk=pk).first()
        if group is None:
            return _notfound()
        role = _group_role(group.id, request.user.id)
        if role is None:
            return _forbidden("not_a_member")
        if not mcom.can_post_in_group(role, {
                "announcements_only": group.announcements_only}):
            return _forbidden("announcements_only")
        # Relay the opaque ciphertext envelope (stored elsewhere by the circle
        # group relay); here we only prove the gate passed.
        return Response({"ok": True, "can_post": True})


class CommunityMembersView(APIView):
    """GET /api/community/<id>/members -> member_card per member (phone hidden
    unless the member opted in via show_phone, or it is the viewer themself)."""

    def get(self, request, pk):
        community = Community.objects.filter(pk=pk).first()
        if community is None:
            return _notfound()
        if not CommunityMember.objects.filter(
                community=community, member=request.user, status="active").exists():
            return _forbidden("not_a_member")
        seen = {}
        for m in (CommunityMember.objects.filter(
                community=community, status="active").select_related("member")):
            u = m.member
            if u.id in seen:
                continue
            seen[u.id] = mcom.member_card({
                "member_id": u.id, "name": (u.name or "").strip() or u.username,
                "photo_ref": u.photo_url, "show_phone": u.show_phone,
                "phone": u.phone or ""}, viewer_id=request.user.id)
        return Response({"results": list(seen.values())})


class MeShowPhoneView(APIView):
    """PATCH /api/me/show-phone {show} -> set_show_phone (opt-in)."""

    def patch(self, request):
        show = bool((request.data or {}).get("show", False))
        request.user.show_phone = show
        request.user.save(update_fields=["show_phone"])
        return Response({"show_phone": request.user.show_phone})

    post = patch


class MeWhoCanMsgView(APIView):
    """GET/PATCH /api/me/communities-who-can-msg. GET -> the caller's current
    setting (own row only). PATCH {mode in everyone|nobody} -> stored, read by
    can_direct_message."""

    def get(self, request):
        mode = mcom.normalize_who_can_msg(
            getattr(request.user, "communities_who_can_msg", None))
        return Response({"communities_who_can_msg": mode})

    def patch(self, request):
        mode = mcom.normalize_who_can_msg((request.data or {}).get("mode"))
        request.user.communities_who_can_msg = mode
        request.user.save(update_fields=["communities_who_can_msg"])
        return Response({"communities_who_can_msg": mode})

    post = patch


class CommunityMessageView(APIView):
    """POST /api/community/message {recipient_id, community_id, ciphertext, nonce,
    sender_key_id}. check_msgreq_rate THEN can_direct_message:
      route=direct          -> normal 1:1 relay (allowed; client sends E2E),
      route=message_request -> new_message_request (CIPHERTEXT ONLY),
      who==nobody / blocked -> refused."""

    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        recipient = User.objects.filter(pk=data.get("recipient_id")).first()
        if recipient is None:
            return _notfound("recipient not found")
        community = Community.objects.filter(pk=data.get("community_id")).first()
        same_community = bool(community and self._both_in(community, request.user,
                                                          recipient))
        # Prior relationship signals.
        rel_state = self._rel_state(request.user, recipient)
        prior = CommunityMessageRequest.objects.filter(
            sender=request.user, recipient=recipient).order_by("-created_at").first()
        prior_state = prior.state if prior else None
        blocked = self._blocked_either(request.user, recipient)

        decision = mcom.can_direct_message(
            rel_state=rel_state, prior_request_state=prior_state,
            recipient_who_can_msg=recipient.communities_who_can_msg,
            blocked_either=blocked, same_community=same_community)
        if not decision["allowed"]:
            return Response({"allowed": False, "reason": decision["reason"]},
                            status=status.HTTP_403_FORBIDDEN)
        if decision["route"] == "direct":
            return Response({"allowed": True, "route": "direct",
                             "calls_allowed": decision["calls_allowed"]})
        # message_request: rate-limit THEN create (ciphertext only).
        recent = [r.created_at for r in CommunityMessageRequest.objects.filter(
            sender=request.user)]
        rate = mcom.check_msgreq_rate(recent)
        if not rate["allowed"]:
            return Response({"allowed": False, "reason": "rate_limited",
                             "retry_after_sec": rate["retry_after_sec"],
                             "message": mcom.rate_limited_message(
                                 rate["retry_after_sec"], lang)},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        row = mcom.new_message_request(
            request.user.id, recipient.id, community.id if community else None,
            data.get("ciphertext", ""), data.get("nonce", ""),
            data.get("sender_key_id", ""))
        mr = CommunityMessageRequest.objects.create(
            sender=request.user, recipient=recipient, community=community,
            state="pending", first_ciphertext=row["first_ciphertext"],
            first_nonce=row["first_nonce"], sender_key_id=row["sender_key_id"])
        return Response({"allowed": True, "route": "message_request",
                         "message_request_id": mr.id,
                         "banner": mcom.message_request_banner(lang)},
                        status=status.HTTP_201_CREATED)

    @staticmethod
    def _both_in(community, a, b):
        ids = set(CommunityMember.objects.filter(
            community=community, member__in=[a, b], status="active"
        ).values_list("member_id", flat=True))
        return a.id in ids and b.id in ids

    @staticmethod
    def _rel_state(a, b):
        edge = CircleMember.objects.filter(
            user=a, peer_user=b, state="accepted").first()
        return circle.REQ_ACCEPTED if edge else None

    @staticmethod
    def _blocked_either(a, b):
        return CircleMember.objects.filter(
            dj_models.Q(user=a, peer_user=b) | dj_models.Q(user=b, peer_user=a),
            blocked=True).exists()


class CommunityMsgReqActView(APIView):
    """POST /api/community/message-request/<id>/<action> (accept|decline|block)
    -> apply_msgreq_event (recipient-only)."""

    def post(self, request, pk, action):
        mr = CommunityMessageRequest.objects.filter(
            pk=pk, recipient=request.user).first()
        if mr is None:
            return _notfound()
        new_state, changed = mcom.apply_msgreq_event(mr.state, action)
        if not changed:
            return _badreq("bad event")
        mr.state = new_state
        mr.save(update_fields=["state"])
        return Response({"id": mr.id, "state": mr.state})


class CommunityMsgReqReportView(APIView):
    """POST /api/community/message-request/<id>/report {reason, note?, also_block}
    -> report_sender."""

    def post(self, request, pk):
        lang = req_lang(request)
        mr = CommunityMessageRequest.objects.filter(
            pk=pk, recipient=request.user).first()
        if mr is None:
            return _notfound()
        data = request.data or {}
        payload = mcom.report_sender(
            request.user.id, mr.sender_id,
            mr.community_id, data.get("reason", "other"),
            note=data.get("note", ""), also_block=bool(data.get("also_block")),
            lang=lang)
        if payload["also_block"]:
            mr.state, _ = mcom.apply_msgreq_event(mr.state, "block")
            mr.save(update_fields=["state"])
        return Response(payload)


class CommunityCallView(APIView):
    """POST /api/community/call {peer_id} -> can_call (refuse pre-acceptance).
    Plans: video reuses circle_calls.can_place_call (Premium caller-gated)."""

    def post(self, request):
        data = request.data or {}
        peer = User.objects.filter(pk=data.get("peer_id")).first()
        if peer is None:
            return _notfound("peer not found")
        rel_state = CommunityMessageView._rel_state(request.user, peer)
        prior = CommunityMessageRequest.objects.filter(
            sender=request.user, recipient=peer).order_by("-created_at").first()
        blocked = CommunityMessageView._blocked_either(request.user, peer)
        gate = mcom.can_call(rel_state=rel_state,
                             prior_request_state=prior.state if prior else None,
                             blocked_either=blocked)
        if not gate["allowed"]:
            return _forbidden(gate["reason"])
        # Video is Premium + caller-gated (text+voice free) — reuse circle_calls.
        kind = str(data.get("kind", "voice"))
        if kind == "video":
            call_gate = circle_calls.can_place_call(
                {"plan": getattr(request.user, "plan", "free"),
                 "video_unlocked": False, "accepted": True},
                {"accepted": True}, kind)
            if not call_gate.get("allowed"):
                return _forbidden(call_gate.get("reason", "video_premium"))
        return Response({"allowed": True, "kind": kind})


# ===========================================================================
# 3. CHANNELS  (msg_channel) — NOT E2E / plaintext; follower privacy enforced.
# ===========================================================================

def _channel_dict(ch):
    """Serialize a channel as the pure layer expects (so role_of / is_verified /
    serialize_follower_list operate on the same shape)."""
    return {
        "channel_id": ch.id, "owner_id": ch.owner_id, "name": ch.name,
        "handle": ch.handle, "description": ch.description,
        "category": ch.category, "language": ch.language,
        "photo_ref": ch.photo_ref,
        "admin_ids": list(ch.admins.values_list("user_id", flat=True)),
        "list_visibility": ch.list_visibility,
        "verified": ch.verified, "verified_by": ch.verified_by_id,
        "verification_state": ch.verification_state,
        "follower_count": ch.follower_count,
        "is_verified": mch.is_verified({"verified": ch.verified,
                                        "verified_by": ch.verified_by_id}),
    }


def _followers_roster(ch):
    """Build the {user_id: follower_record} roster the pure enumerator expects."""
    return {f.user_id: {"user_id": f.user_id, "visibility": f.visibility,
                        "muted": f.muted, "followed_at": f.followed_at}
            for f in ch.followers.all()}


class ChannelsView(APIView):
    """GET /channels -> my channels + followed. POST /channels -> new_channel.
    PUBLIC (public list_visibility) channels require the owner switch."""

    def get(self, request):
        owned = [_channel_dict(c) for c in Channel.objects.filter(owner=request.user)]
        following = [_channel_dict(f.channel) for f in
                     ChannelFollower.objects.filter(user=request.user).select_related("channel")]
        return Response({"owned": owned, "following": following})

    def post(self, request):
        data = request.data or {}
        try:
            row = mch.new_channel(
                channel_id=None, owner_id=request.user.id,
                name=str(data.get("name", "")), handle=str(data.get("handle", "")),
                description=str(data.get("description", "")),
                category=data.get("category", "other"),
                language=data.get("language", "other"),
                photo_ref=data.get("photo_ref"))
        except ValueError as e:
            return _badreq(str(e))
        if Channel.objects.filter(handle=row["handle"]).exists():
            return _badreq("handle_taken")
        ch = Channel.objects.create(
            owner=request.user, name=row["name"], handle=row["handle"],
            description=row["description"], category=row["category"],
            language=row["language"], photo_ref=row["photo_ref"] or "",
            list_visibility=row["list_visibility"])   # starts PRIVATE
        return Response(_channel_dict(ch), status=status.HTTP_201_CREATED)


class ChannelDetailView(APIView):
    """GET /channels/<id>. PATCH /channels/<id> -> sanitize_profile_edit (verified/
    follower_count/owner can NEVER be smuggled through)."""

    def get(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        return Response(_channel_dict(ch))

    def patch(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        if mch.role_of(_channel_dict(ch), request.user.id) not in (
                mch.ROLE_OWNER, mch.ROLE_ADMIN):
            return _forbidden("edit_denied")
        clean = mch.sanitize_profile_edit(request.data or {})
        for k in ("name", "handle", "description", "category", "language",
                  "photo_ref"):
            if k in clean:
                setattr(ch, k if k != "photo_ref" else "photo_ref",
                        clean[k] if clean[k] is not None else "")
        if "handle" in clean and clean["handle"] and \
                Channel.objects.filter(handle=clean["handle"]).exclude(pk=ch.pk).exists():
            return _badreq("handle_taken")
        ch.save()
        return Response(_channel_dict(ch))


class ChannelAdminsView(APIView):
    """GET/POST /channels/<id>/admins. GET -> list the channel's admins (owner/
    admin scoped). POST {action, user_id} -> add_admin/remove_admin (OWNER-only)."""

    def get(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        chd = _channel_dict(ch)
        if mch.role_of(chd, request.user.id) not in (
                mch.ROLE_OWNER, mch.ROLE_ADMIN):
            return _forbidden("admins_denied")
        admin_ids = chd["admin_ids"]
        users = {u.id: u for u in User.objects.filter(pk__in=admin_ids)}
        results = [_public_user_descriptor(users[uid])
                   for uid in admin_ids if uid in users]
        return Response({"owner_id": ch.owner_id, "results": results})

    def post(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        data = request.data or {}
        action = data.get("action", "add")
        uid = data.get("user_id")
        chd = _channel_dict(ch)
        if action == "add":
            _, ok, reason = mch.add_admin(chd, request.user.id, uid)
            if not ok and reason not in ("already_admin",):
                return _forbidden(reason)
            u = User.objects.filter(pk=uid).first()
            if u:
                ChannelAdmin.objects.get_or_create(channel=ch, user=u)
        else:
            _, ok, reason = mch.remove_admin(chd, request.user.id, uid)
            if not ok:
                return _forbidden(reason)
            ChannelAdmin.objects.filter(channel=ch, user_id=uid).delete()
        return Response(_channel_dict(ch))


class ChannelFollowView(APIView):
    """POST /channels/<id>/follow -> follow (default count_only; invisible until
    opt-in) and keep follower_count == COUNT(followers)."""

    def post(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        ChannelFollower.objects.get_or_create(
            channel=ch, user=request.user,
            defaults={"visibility": mch.VIS_DEFAULT})   # count_only
        ch.follower_count = ch.followers.count()
        ch.save(update_fields=["follower_count"])
        return Response({"following": True, "follower_count": ch.follower_count,
                         "visibility": mch.VIS_DEFAULT})


class ChannelUnfollowView(APIView):
    def post(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        ChannelFollower.objects.filter(channel=ch, user=request.user).delete()
        ch.follower_count = ch.followers.count()
        ch.save(update_fields=["follower_count"])
        return Response({"following": False, "follower_count": ch.follower_count})


class ChannelMuteView(APIView):
    def post(self, request, pk):
        f = ChannelFollower.objects.filter(channel_id=pk, user=request.user).first()
        if f is None:
            return _notfound("not following")
        f.muted = bool((request.data or {}).get("muted", True))
        f.save(update_fields=["muted"])
        return Response({"muted": f.muted})


class ChannelMyVisibilityView(APIView):
    """POST /channels/<id>/my-visibility {visibility in show|count_only} ->
    set_follower_visibility (the follower's OWN record only)."""

    def post(self, request, pk):
        f = ChannelFollower.objects.filter(channel_id=pk, user=request.user).first()
        if f is None:
            return _notfound("not following")
        rec = mch.set_follower_visibility({"visibility": f.visibility},
                                          (request.data or {}).get("visibility"))
        f.visibility = rec["visibility"]
        f.save(update_fields=["visibility"])
        return Response({"visibility": f.visibility})


class ChannelListVisibilityView(APIView):
    """POST /channels/<id>/list-visibility {visibility in public|private} ->
    set_list_visibility (OWNER-only). PUBLIC requires the owner switch."""

    def post(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        vis = (request.data or {}).get("visibility")
        if vis == mch.LIST_PUBLIC and not request.user.public_surfaces_enabled:
            return _forbidden("public_surfaces_disabled")
        chd, ok, reason = mch.set_list_visibility(_channel_dict(ch),
                                                  request.user.id, vis)
        if not ok:
            return _forbidden(reason)
        ch.list_visibility = chd["list_visibility"]
        ch.save(update_fields=["list_visibility"])
        return Response({"list_visibility": ch.list_visibility})


class ChannelFollowersView(APIView):
    """GET /channels/<id>/followers -> serialize_follower_list. count_only
    followers are NEVER in `followers` (even to owner/admin) but ALWAYS counted.
    THIS is the only path that builds a follower response."""

    def get(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        try:
            limit = int(request.query_params.get("limit")) if \
                request.query_params.get("limit") else None
        except ValueError:
            limit = None
        try:
            offset = int(request.query_params.get("offset", 0))
        except ValueError:
            offset = 0
        payload = mch.serialize_follower_list(
            _channel_dict(ch), _followers_roster(ch), request.user.id,
            limit=limit, offset=offset)
        return Response(payload)


class ChannelPostsView(APIView):
    """GET list visible posts. POST -> new_post (publish gate can_publish; REJECTS
    e2e=True; content is PLAINTEXT / moderatable)."""

    def get(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        posts = ch.posts.filter(deleted=False).exclude(
            content_status__in=["hidden", "removed"])
        return Response({"results": [self._post_dict(p) for p in posts]})

    def post(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        data = request.data or {}
        if data.get("e2e") is True:
            return _badreq("channel_post_must_not_be_e2e")
        chd = _channel_dict(ch)
        post, ok, reason = mch.new_post(
            post_id=None, channel=chd, author_id=request.user.id,
            kind=data.get("kind", "text"), text=str(data.get("text", "")),
            media_refs=data.get("media_refs"), link_url=data.get("link_url"),
            poll=data.get("poll"))
        if not ok:
            http = status.HTTP_403_FORBIDDEN if reason == "publish_denied" \
                else status.HTTP_400_BAD_REQUEST
            return Response({"detail": reason}, status=http)
        row = ChannelPost.objects.create(
            channel=ch, author=request.user, kind=post["kind"],
            e2e=False, content_scheme=post["content_scheme"],
            text=post["text"], media_refs=post["media_refs"],
            link_url=post["link_url"] or "")
        return Response(self._post_dict(row), status=status.HTTP_201_CREATED)

    @staticmethod
    def _post_dict(p):
        return {"id": p.id, "channel_id": p.channel_id, "author_id": p.author_id,
                "kind": p.kind, "e2e": p.e2e, "content_scheme": p.content_scheme,
                "text": p.text, "media_refs": p.media_refs,
                "link_url": p.link_url or None, "reactions": p.reactions or {},
                "views": p.views, "pinned": p.pinned,
                "created_at": p.created_at.isoformat()}


class ChannelPostReactView(APIView):
    """POST /channels/<id>/posts/<pid>/react {emoji, remove?} -> aggregate
    reaction count ONLY (never per-reactor rows)."""

    def post(self, request, pk, pid):
        p = ChannelPost.objects.filter(pk=pid, channel_id=pk).first()
        if p is None:
            return _notfound()
        data = request.data or {}
        env = {"reactions": p.reactions or {}}
        if data.get("remove"):
            env = mch.remove_reaction(env, str(data.get("emoji", "")))
        else:
            env = mch.add_reaction(env, str(data.get("emoji", "")))
        p.reactions = env["reactions"]
        p.save(update_fields=["reactions"])
        return Response({"reactions": p.reactions})


class ChannelPostViewView(APIView):
    """POST /channels/<id>/posts/<pid>/view -> record_view (no viewer id stored)."""

    def post(self, request, pk, pid):
        p = ChannelPost.objects.filter(pk=pid, channel_id=pk).first()
        if p is None:
            return _notfound()
        env = mch.record_view({"views": p.views})
        p.views = env["views"]
        p.save(update_fields=["views"])
        return Response({"views": p.views})


class ChannelPostPinView(APIView):
    """POST /channels/<id>/posts/<pid>/pin -> admin pin toggle (cap: admins only)."""

    def post(self, request, pk, pid):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        if mch.role_of(_channel_dict(ch), request.user.id) not in (
                mch.ROLE_OWNER, mch.ROLE_ADMIN):
            return _forbidden("pin_denied")
        p = ChannelPost.objects.filter(pk=pid, channel=ch).first()
        if p is None:
            return _notfound()
        p.pinned = not p.pinned
        p.save(update_fields=["pinned"])
        return Response({"pinned": p.pinned})


class ChannelPollsView(APIView):
    """POST /channels/<id>/polls -> new_channel_poll (PLAINTEXT labels, tally by
    index). Admin/owner only."""

    def post(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        if not mch.can_publish(mch.role_of(_channel_dict(ch), request.user.id)):
            return _forbidden("publish_denied")
        data = request.data or {}
        options = data.get("options") or []
        poll, ok, reason = mch.new_channel_poll(
            poll_id=None, option_count=data.get("option_count", len(options)),
            question=str(data.get("question", "")), options=options,
            multi=bool(data.get("multi", False)))
        if not ok:
            return _badreq(reason)
        row = ChannelPoll.objects.create(
            channel=ch, question=poll["question"], options=poll["options"],
            option_count=poll["option_count"], multi=poll["multi"])
        return Response({"id": row.id, "question": row.question,
                         "options": row.options, "multi": row.multi},
                        status=status.HTTP_201_CREATED)


class ChannelPollActView(APIView):
    """POST /channels/<id>/polls/<poll_id>/<action> (vote|close|tally).
    vote -> validate_vote/apply_vote (re-vote replaces); close -> close_poll
    (admin); tally -> tally_poll by index."""

    def post(self, request, pk, poll_id, action):
        poll = ChannelPoll.objects.filter(pk=poll_id, channel_id=pk).first()
        if poll is None:
            return _notfound()
        pd = {"option_count": poll.option_count, "multi": poll.multi,
              "closed": poll.closed}
        if action == "vote":
            choices = (request.data or {}).get("choices", [])
            votes = {v.voter_id: v.choices for v in poll.votes.all()}
            votes, ok, reason = mch.apply_vote(votes, pd, request.user.id, choices)
            if not ok:
                return _badreq(reason)
            ChannelPollVote.objects.update_or_create(
                poll=poll, voter=request.user,
                defaults={"choices": votes[request.user.id]})
            return Response({"ok": True, "choices": votes[request.user.id]})
        if action == "close":
            ch = poll.channel
            if not mch.can_publish(mch.role_of(_channel_dict(ch), request.user.id)):
                return _forbidden("publish_denied")
            poll.closed = True
            poll.save(update_fields=["closed"])
            return Response({"closed": True})
        if action == "tally":
            votes = {v.voter_id: v.choices for v in poll.votes.all()}
            return Response(mch.tally_poll(pd, votes))
        return _badreq("unknown action")


class ChannelPollTallyView(APIView):
    """GET /channels/<id>/polls/<poll_id>/tally -> tally_poll by index (counts
    only; never per-voter rows). Scoped to the poll's channel."""

    def get(self, request, pk, poll_id):
        poll = ChannelPoll.objects.filter(pk=poll_id, channel_id=pk).first()
        if poll is None:
            return _notfound()
        pd = {"option_count": poll.option_count, "multi": poll.multi,
              "closed": poll.closed}
        votes = {v.voter_id: v.choices for v in poll.votes.all()}
        return Response(mch.tally_poll(pd, votes))


class ChannelAnalyticsView(APIView):
    """GET /channels/<id>/analytics -> channel_analytics (COUNTS ONLY,
    contains_pii=False). Owner/admin only."""

    def get(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        if mch.role_of(_channel_dict(ch), request.user.id) not in (
                mch.ROLE_OWNER, mch.ROLE_ADMIN):
            return _forbidden("analytics_denied")
        posts = [{"views": p.views, "reactions": p.reactions or {},
                  "deleted": p.deleted} for p in ch.posts.all()]
        return Response(mch.channel_analytics(_channel_dict(ch), posts))


class ChannelVerifyRequestView(APIView):
    """POST /channels/<id>/verify/request -> request_verification (OWNER->pending
    only; NEVER grants)."""

    def post(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        chd, ok, reason = mch.request_verification(_channel_dict(ch),
                                                   request.user.id)
        if not ok:
            return _forbidden(reason)
        ch.verification_state = chd["verification_state"]
        ch.save(update_fields=["verification_state"])
        ChannelVerificationRequest.objects.create(channel=ch, state="pending")
        return Response({"verification_state": ch.verification_state})


class ChannelVerifyGrantView(APIView):
    """POST /admin/channels/<id>/verify/<action> (grant|revoke) -> grant/revoke_
    verification (operator-only). is_verified requires BOTH flag AND a recorded
    operator approver; a forged flag reads as NOT verified."""

    def post(self, request, pk, action):
        if not _is_operator(request):
            return _forbidden("operator_only")
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        if action == "grant":
            chd, ok, reason = mch.grant_verification(
                _channel_dict(ch), request.user.id, is_platform_operator=True)
            ch.verified = chd["verified"]
            ch.verified_by = request.user
            ch.verification_state = chd["verification_state"]
        else:
            chd, ok, reason = mch.revoke_verification(
                _channel_dict(ch), request.user.id, is_platform_operator=True)
            ch.verified = chd["verified"]
            ch.verified_by = None
            ch.verification_state = chd["verification_state"]
        if not ok:
            return _forbidden(reason)
        ch.save(update_fields=["verified", "verified_by", "verification_state"])
        return Response({"verified": ch.verified,
                         "is_verified": mch.is_verified(_channel_dict(ch))})


class ChannelShareLinkView(APIView):
    """GET /channels/<id>/share-link -> make_share_link."""

    def get(self, request, pk):
        ch = Channel.objects.filter(pk=pk).first()
        if ch is None:
            return _notfound()
        return Response({"link": mch.make_share_link(_channel_dict(ch))})


# ===========================================================================
# 4. MODERATION + OWNER-ADMIN  (msg_moderation) — public surfaces only.
# ===========================================================================

def _target_current_status(kind, tid):
    """Resolve the target's current moderation status from its latest item."""
    it = ModerationItem.objects.filter(
        target_kind=kind, target_id=str(tid)).order_by("-opened_at").first()
    return it.content_status if it else mmod.STATUS_VISIBLE


def _apply_status_to_target(kind, tid, new_status):
    """Persist the decided content_status onto the real target (channels/posts)."""
    if new_status is None:
        return
    if kind == mmod.T_POST:
        ChannelPost.objects.filter(pk=tid).update(content_status=new_status)
    elif kind == mmod.T_CHANNEL:
        # channels have no status column; hide == set list private is not apt, so
        # we leave the authoritative state on the ModerationItem only.
        pass


class ModerationReportView(APIView):
    """POST /api/moderation/report {target_kind, target_id, categories, note?} ->
    build_report -> evaluate_report. severe->hide immediately, mass->temp-hide,
    else queue; apply new_status to the target."""

    def post(self, request):
        data = request.data or {}
        kind = data.get("target_kind")
        tid = data.get("target_id")
        rpt = mmod.build_report(
            report_id=None, reporter_id=request.user.id, target_kind=kind,
            target_id=tid, categories=data.get("categories") or [],
            note=str(data.get("note", "")))
        ModerationReport.objects.create(
            reporter=request.user, target_kind=str(kind or "")[:12],
            target_id=str(tid or "")[:64], categories=rpt["categories"],
            note=rpt["note"], valid=rpt["valid"])
        if not rpt["valid"]:
            return _badreq("invalid_report")
        existing = [{"valid": r.valid, "reporter_id": r.reporter_id,
                     "created_at": r.created_at}
                    for r in ModerationReport.objects.filter(
                        target_kind=str(kind), target_id=str(tid))]
        decision = mmod.evaluate_report(
            {**rpt, "reporter_id": request.user.id},
            existing, _target_current_status(kind, tid))
        item = ModerationItem.objects.filter(
            target_kind=str(kind), target_id=str(tid)).exclude(
            queue_state=mmod.Q_RESOLVED).order_by("-opened_at").first()
        if item is None:
            built = mmod.build_queue_item(
                None, kind, tid, rpt["categories"], decision["severe"],
                decision["new_status"] or _target_current_status(kind, tid))
            item = ModerationItem.objects.create(
                target_kind=str(kind)[:12], target_id=str(tid)[:64],
                categories=built["categories"], severe=built["severe"],
                content_status=built["content_status"],
                queue_state=built["queue_state"],
                legal_retention=built["legal_retention"],
                report_count=built["report_count"])
        else:
            bumped = mmod.bump_queue_item(
                {"report_count": item.report_count, "categories": item.categories,
                 "legal_retention": item.legal_retention, "severe": item.severe,
                 "queue_state": item.queue_state},
                severe=decision["severe"], categories=rpt["categories"])
            item.report_count = bumped["report_count"]
            item.categories = bumped["categories"]
            item.legal_retention = bumped["legal_retention"]
            item.severe = bumped["severe"]
            item.queue_state = bumped["queue_state"]
            item.save()
        if decision["new_status"] is not None:
            item.content_status = decision["new_status"]
            item.save(update_fields=["content_status"])
            _apply_status_to_target(kind, tid, decision["new_status"])
        # bump the reported person's public report_count.
        if kind == mmod.T_PERSON:
            User.objects.filter(pk=tid).update(
                report_count=dj_models.F("report_count") + 1)
        return Response({"accepted": True, "action": decision["action"],
                         "reason": decision["reason"], "item_id": item.id,
                         "content_status": item.content_status})


class AdminQueueView(APIView):
    """GET /api/admin/moderation/queue -> items where queue_state != resolved.
    Admin-only; the view itself is audited."""

    def get(self, request):
        if not _is_operator(request):
            return _forbidden("admin_only")
        items = ModerationItem.objects.exclude(queue_state=mmod.Q_RESOLVED)
        severe = request.query_params.get("severe")
        if severe is not None:
            items = items.filter(severe=(severe in ("1", "true", "True")))
        ModerationAudit.objects.create(
            actor=request.user, action="view_queue",
            reason="admin queue viewed", extra={"count": items.count()})
        return Response({"results": [self._dict(i) for i in items]})

    @staticmethod
    def _dict(i):
        return {"id": i.id, "target_kind": i.target_kind, "target_id": i.target_id,
                "categories": i.categories, "severe": i.severe,
                "content_status": i.content_status, "queue_state": i.queue_state,
                "legal_retention": i.legal_retention, "report_count": i.report_count,
                "decision": i.decision, "opened_at": i.opened_at.isoformat()}


class AdminItemDetailView(APIView):
    """GET /api/admin/moderation/<item> -> the single queue item detail (operator/
    owner-gated; reuses the queue item serialization). Audited like the queue."""

    def get(self, request, pk):
        if not _is_operator(request):
            return _forbidden("admin_only")
        item = ModerationItem.objects.filter(pk=pk).first()
        if item is None:
            return _notfound()
        ModerationAudit.objects.create(
            actor=request.user, action="view_item",
            target_kind=item.target_kind, target_id=str(item.target_id),
            reason="admin item viewed", extra={"queue_item": item.id})
        return Response(AdminQueueView._dict(item))


class AdminItemActionView(APIView):
    """POST /api/admin/moderation/<item>/action {action, reason} ->
    apply_admin_action. reason REQUIRED; writes an append-only audit."""

    def post(self, request, pk):
        if not _is_operator(request):
            return _forbidden("admin_only")
        item = ModerationItem.objects.filter(pk=pk).first()
        if item is None:
            return _notfound()
        data = request.data or {}
        try:
            new_item, audit = mmod.apply_admin_action(
                {"id": item.id, "target_kind": item.target_kind,
                 "target_id": item.target_id, "content_status": item.content_status,
                 "legal_retention": item.legal_retention},
                data.get("action", ""), request.user.id,
                str(data.get("reason", "")))
        except ValueError as e:
            return _badreq(str(e))
        item.content_status = new_item["content_status"]
        item.queue_state = new_item["queue_state"]
        item.resolved_at = timezone.now()
        item.decision = new_item["decision"]
        item.save(update_fields=["content_status", "queue_state", "resolved_at",
                                 "decision"])
        _apply_status_to_target(item.target_kind, item.target_id,
                                item.content_status)
        ModerationAudit.objects.create(
            actor=request.user, action=audit["action"],
            target_kind=audit["target_kind"], target_id=str(audit["target_id"]),
            reason=audit["reason"],
            extra={k: v for k, v in audit.items()
                   if k not in ("actor_id", "action", "target_kind", "target_id",
                                "reason", "at")})
        return Response({"id": item.id, "content_status": item.content_status,
                         "queue_state": item.queue_state,
                         "decision": item.decision})


class ModerationAppealView(APIView):
    """POST /api/moderation/<item>/appeal {reason} -> can_appeal -> open_appeal.
    Affected user only; re-opens."""

    def post(self, request, pk):
        item = ModerationItem.objects.filter(pk=pk).first()
        if item is None:
            return _notfound()
        # affected-user check: for a person-target, the appellant must be that
        # user; for content targets the appellant must own the target.
        if not self._is_affected(request.user, item):
            return _forbidden("not_affected")
        if not mmod.can_appeal(
                {"queue_state": item.queue_state}, item.resolved_at):
            return _forbidden("appeal_window_closed")
        new_item, audit = mmod.open_appeal(
            {"id": item.id, "queue_state": item.queue_state,
             "target_kind": item.target_kind, "target_id": item.target_id},
            request.user.id, str((request.data or {}).get("reason", "")))
        item.queue_state = new_item["queue_state"]
        item.resolved_at = None
        item.save(update_fields=["queue_state", "resolved_at"])
        ModerationAudit.objects.create(
            actor=request.user, action="appeal",
            target_kind=item.target_kind, target_id=str(item.target_id),
            reason=audit["reason"], extra={"queue_item": item.id})
        return Response({"id": item.id, "queue_state": item.queue_state})

    @staticmethod
    def _is_affected(user, item):
        if item.target_kind == mmod.T_PERSON:
            return str(user.id) == str(item.target_id)
        if item.target_kind == mmod.T_POST:
            return ChannelPost.objects.filter(
                pk=item.target_id, author=user).exists()
        if item.target_kind == mmod.T_CHANNEL:
            return Channel.objects.filter(pk=item.target_id, owner=user).exists()
        if item.target_kind == mmod.T_COMMUNITY:
            return Community.objects.filter(pk=item.target_id, creator=user).exists()
        return False


class AdminItemReopenView(APIView):
    """POST /api/admin/moderation/<item>/reopen -> reopen_for_review (appealed ->
    queued)."""

    def post(self, request, pk):
        if not _is_operator(request):
            return _forbidden("admin_only")
        item = ModerationItem.objects.filter(pk=pk).first()
        if item is None:
            return _notfound()
        new_item = mmod.reopen_for_review({"queue_state": item.queue_state})
        item.queue_state = new_item["queue_state"]
        item.save(update_fields=["queue_state"])
        ModerationAudit.objects.create(
            actor=request.user, action="reopen",
            target_kind=item.target_kind, target_id=str(item.target_id),
            reason="reopened for review", extra={"queue_item": item.id})
        return Response({"id": item.id, "queue_state": item.queue_state})


class AdminUsersView(APIView):
    """GET /api/admin/users -> list_users_for_admin. PUBLIC PROJECTION ONLY
    (admin_user_projection): message contents / contacts are NEVER returned.
    The view is audited."""

    def get(self, request):
        if not _is_operator(request):
            return _forbidden("admin_only")
        q = request.query_params.get("q")
        st = request.query_params.get("status")
        try:
            limit = int(request.query_params.get("limit", 100))
        except ValueError:
            limit = 100
        # Build PUBLIC-field dicts only — nothing private is ever read into them.
        raw = [{"id": u.id, "name": u.name, "phone": u.phone,
                "photo_url": u.photo_url,
                "signup_date": u.date_joined.isoformat() if u.date_joined else None,
                "plan": u.plan,
                "last_active": u.last_active.isoformat() if u.last_active else None,
                "app_version": u.app_version, "report_count": u.report_count,
                "status": u.account_status}
               for u in User.objects.all()[:5000]]
        rows = mmod.list_users_for_admin(raw, query=q, status=st, limit=limit)
        ModerationAudit.objects.create(
            actor=request.user, action="view_users",
            reason="admin users listed", extra={"count": len(rows)})
        return Response({"results": rows})


class AdminUserPublicView(APIView):
    """GET /api/admin/users/<id>/public -> the single-user admin PUBLIC projection
    via admin_user_projection (operator/owner-gated; audited). Built from the SAME
    public allow-list as the list view — message contents and contacts are NEVER
    read into it, so they can never leak."""

    def get(self, request, pk):
        if not _is_operator(request):
            return _forbidden("admin_only")
        u = User.objects.filter(pk=pk).first()
        if u is None:
            return _notfound()
        # PUBLIC-field dict only — identical allow-list to AdminUsersView.
        raw = {"id": u.id, "name": u.name, "phone": u.phone,
               "photo_url": u.photo_url,
               "signup_date": u.date_joined.isoformat() if u.date_joined else None,
               "plan": u.plan,
               "last_active": u.last_active.isoformat() if u.last_active else None,
               "app_version": u.app_version, "report_count": u.report_count,
               "status": u.account_status}
        row = mmod.admin_user_projection(raw)
        ModerationAudit.objects.create(
            actor=request.user, action="view_user",
            target_kind=mmod.T_PERSON, target_id=str(u.id),
            reason="admin user viewed", extra={"user_id": u.id})
        return Response(row)


class AdminUserActionView(APIView):
    """POST /api/admin/users/<id>/action {action, reason} -> admin_user_action
    (suspend/unsuspend/reset-sessions/ban). reason REQUIRED; audited. NEVER
    returns message content/contacts — only the public status + reset flag."""

    def post(self, request, pk):
        if not _is_operator(request):
            return _forbidden("admin_only")
        target = User.objects.filter(pk=pk).first()
        if target is None:
            return _notfound()
        data = request.data or {}
        try:
            new_status, reset_sessions, audit = mmod.admin_user_action(
                target.account_status, data.get("action", ""), request.user.id,
                target.id, str(data.get("reason", "")))
        except ValueError as e:
            return _badreq(str(e))
        target.account_status = new_status
        target.save(update_fields=["account_status"])
        if reset_sessions:
            try:
                from rest_framework.authtoken.models import Token
                Token.objects.filter(user=target).delete()
            except Exception:
                pass
        ModerationAudit.objects.create(
            actor=request.user, action=audit["action"],
            target_kind=mmod.T_PERSON, target_id=str(target.id),
            reason=audit["reason"],
            extra={"new_status": new_status, "reset_sessions": reset_sessions})
        return Response({"id": target.id, "status": target.account_status,
                         "reset_sessions": reset_sessions})


# ===========================================================================
# 5. MESSENGER FULL-UI — hub-⋮ + chat-⋮ actions (msg_messenger_ui)
# ===========================================================================
# Every endpoint is ownership-scoped by request.user. Bilingual via req_lang.
# The pure module enforces the rules; these thin views only resolve DB rows.

def _app_base(request):
    return getattr(settings, "APP_DEEP_LINK_BASE_HTTPS",
                   "https://assisto.asalify.com")


# ---- STARRED messages ----

class StarredView(APIView):
    """GET  /api/messenger/starred -> all starred messages across chats (with a
             chat ref + message id to jump to).
    POST /api/messenger/starred {chat_kind, chat_id, message_id, starred:bool}
             -> star / unstar a message (idempotent)."""

    def get(self, request):
        rows = StarredMessage.objects.filter(user=request.user)
        out = [mui.star_jump_target({
            "chat_kind": r.chat_kind, "chat_id": r.chat_id,
            "message_id": r.message_id}) | {"at": r.at.isoformat()}
            for r in rows]
        return Response({"starred": out, "count": len(out)})

    def post(self, request):
        d = request.data or {}
        cid, mid = d.get("chat_id"), d.get("message_id")
        if cid is None or mid is None:
            return _badreq("chat_id and message_id required")
        rec = mui.build_star(request.user.id, d.get("chat_kind"), cid, mid)
        if d.get("starred", True):
            StarredMessage.objects.get_or_create(
                user=request.user, chat_kind=rec["chat_kind"],
                chat_id=rec["chat_id"], message_id=rec["message_id"])
            return Response({"starred": True, **mui.star_jump_target(rec)})
        StarredMessage.objects.filter(
            user=request.user, chat_kind=rec["chat_kind"],
            chat_id=rec["chat_id"], message_id=rec["message_id"]).delete()
        return Response({"starred": False, **mui.star_jump_target(rec)})


# ---- LINKED DEVICES ----

class LinkStartView(APIView):
    """POST /api/messenger/link/start {platform?} -> mint a SINGLE-USE, short-TTL
    pairing token + QR payload (server side now; web client later)."""

    def post(self, request):
        d = request.data or {}
        out = mui.mint_link_token(
            request.user.id, platform=d.get("platform", "web"),
            base_url=_app_base(request))
        rec = out["record"]
        DeviceLinkToken.objects.create(
            user=request.user, token=rec["token"], platform=rec["platform"],
            expires_at=timezone.datetime.fromisoformat(rec["expires_at"]))
        return Response({"qr_payload": out["qr_payload"],
                         "ttl_sec": out["ttl_sec"],
                         "expires_at": rec["expires_at"]})


class LinkConfirmView(APIView):
    """POST /api/messenger/link/confirm {token, device_id, name?, public_key_id?,
    platform?} -> consume the single-use token (if fresh + cap/web-after-mobile
    allow) and register the LinkedDevice. The token can never be replayed."""

    def post(self, request):
        d = request.data or {}
        tok = DeviceLinkToken.objects.filter(
            user=request.user, token=str(d.get("token", ""))).first()
        token_rec = None if tok is None else {
            "used": tok.used, "expires_at": tok.expires_at.isoformat()}
        existing = [cx.device_record(
            x.device_id, x.platform, role=x.role,
            public_key_id=x.public_key_id, name=x.name)
            for x in LinkedDevice.objects.filter(user=request.user)]
        plat = d.get("platform") or (tok.platform if tok else "web")
        ok, why = mui.can_confirm_link(token_rec, existing, plat)
        if not ok:
            return _badreq(why)     # used/expired/unknown/device_cap/web_after_mobile
        tok.used = True
        tok.save(update_fields=["used"])
        dev, _ = LinkedDevice.objects.get_or_create(
            device_id=str(d.get("device_id", "")),
            defaults={"user": request.user, "platform": plat,
                      "role": "linked", "name": str(d.get("name", ""))[:120],
                      "public_key_id": str(d.get("public_key_id", ""))[:64]})
        return Response({"ok": True, "device_id": dev.device_id})


class LinkedDevicesView(APIView):
    """GET /api/messenger/linked-devices -> list linked devices (name/platform/
    last-active). Never exposes a key."""

    def get(self, request):
        lang = req_lang(request)
        rows = LinkedDevice.objects.filter(user=request.user, revoked=False)
        out = [mui.linked_device_view({
            "device_id": r.device_id, "name": r.name, "platform": r.platform,
            "role": r.role, "linked_at": r.linked_at.isoformat(),
            "last_active": r.last_active.isoformat() if r.last_active else None,
            "revoked": r.revoked}, lang=lang) for r in rows]
        return Response({"devices": out, "count": len(out)})


class LinkedDeviceRevokeView(APIView):
    """POST /api/messenger/linked-devices/<device_id>/revoke -> logout/revoke one
    companion device (its keys are rotated out by the primary)."""

    def post(self, request, device_id):
        dev = LinkedDevice.objects.filter(
            user=request.user, device_id=str(device_id)).first()
        if dev is None:
            return _notfound()
        dev.revoked = True
        dev.save(update_fields=["revoked"])
        return Response({"ok": True, "device_id": dev.device_id, "revoked": True})


# ---- CALLS ----

def _caller_descriptor(user):
    return {"id": user.id, "plan": user.plan,
            "video_unlocked": any(
                CircleMember.objects.filter(
                    user=user, video_unlocked=True).values_list("id", flat=True)[:1])}


class CallLinkView(APIView):
    """POST /api/messenger/call-link {kind:voice|video} -> an EXPIRING tokenized
    call link. VIDEO is Premium creator-gated (circle_calls)."""

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        out = mui.mint_call_link(
            {"id": request.user.id, "plan": request.user.plan},
            kind=d.get("kind", "voice"), base_url=_app_base(request))
        if not out["ok"]:
            return Response(
                {"detail": out["reason"], "upgrade_required": True,
                 "upgrade": circle_calls.upgrade_prompt(lang)},
                status=status.HTTP_402_PAYMENT_REQUIRED)
        rec = out["record"]
        CallLink.objects.create(
            creator=request.user, token=rec["token"], kind=rec["kind"],
            expires_at=timezone.datetime.fromisoformat(rec["expires_at"]))
        return Response({"url": out["url"], "kind": rec["kind"],
                         "expires_at": rec["expires_at"]})


class ScheduleCallView(APIView):
    """POST /api/messenger/schedule-call {invitee_member_ids:[], scheduled_at,
    kind, title?, remind_lead_sec?} -> a ScheduledCall + a reminder descriptor
    for every invitee (organiser included). VIDEO is Premium organiser-gated."""

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        organiser = {"id": request.user.id, "plan": request.user.plan}
        try:
            built = mui.build_scheduled_call(
                organiser, d.get("invitee_member_ids") or [],
                d.get("scheduled_at"), kind=d.get("kind", "voice"),
                title=str(d.get("title", "")),
                remind_lead_sec=d.get("remind_lead_sec"))
        except ValueError as e:
            reason = str(e).split(": ", 1)[-1]
            if reason == "video_requires_premium":
                return Response(
                    {"detail": reason, "upgrade_required": True,
                     "upgrade": circle_calls.upgrade_prompt(lang)},
                    status=status.HTTP_402_PAYMENT_REQUIRED)
            return _badreq(reason)
        rec = built["record"]
        row = ScheduledCall.objects.create(
            organiser=request.user, invitee_ids=rec["invitee_ids"],
            call_kind=rec["call_kind"], title=rec["title"],
            scheduled_at=timezone.datetime.fromisoformat(rec["scheduled_at"]),
            remind_at=timezone.datetime.fromisoformat(rec["remind_at"]))
        return Response({"id": row.id, **rec, "reminders": built["reminders"]})


class GroupCallView(APIView):
    """POST /api/messenger/group-call {invitee_member_ids:[], kind} -> plan a new
    group call. VOICE free; VIDEO Premium organiser-gated. Not-connected invitees
    are skipped; a video-entitlement failure is fatal (reuse circle_calls)."""

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        ids = [int(i) for i in (d.get("invitee_member_ids") or []) if str(i).isdigit()]
        members = CircleMember.objects.filter(user=request.user, id__in=ids)
        invitees = [{"id": m.id, "accepted": m.state == "accepted",
                     "blocked": m.blocked} for m in members]
        plan = mui.plan_group_call(
            {"id": request.user.id, "plan": request.user.plan},
            invitees, kind=d.get("kind", "voice"))
        if not plan["allowed"]:
            if plan["reason"] == "video_requires_premium":
                return Response(
                    {"detail": plan["reason"], "upgrade_required": True,
                     "upgrade": circle_calls.upgrade_prompt(lang)},
                    status=status.HTTP_402_PAYMENT_REQUIRED)
            return _badreq(plan["reason"])
        return Response(plan)


# ---- REPORT-LAST-5 (reporter snapshot; server NEVER decrypts) ----

class ChatReportView(APIView):
    """POST /api/messenger/chat/<member_id>/report {categories:[], note?,
    last_messages:[{message_id, from_me, sender_name, at, content_type, text}]}
    -> build a 'person' moderation report with the reporter's LAST 5 DECRYPTED
    messages attached as context. THE SERVER NEVER DECRYPTS — it accepts the
    reporter-supplied plaintext snapshot, caps it to 5, and stores it. Reuses
    msg_moderation.build_report + evaluate_report."""

    def post(self, request, member_id):
        d = request.data or {}
        m = CircleMember.objects.filter(user=request.user, pk=member_id).first()
        if m is None:
            return _notfound()
        target_user_id = m.peer_user_id or m.id
        built = mui.build_chat_report(
            report_id=None, reporter_id=request.user.id,
            target_user_id=target_user_id,
            categories=d.get("categories") or [],
            snapshot_messages=d.get("last_messages") or [],
            note=str(d.get("note", "")))
        rpt = built["report"]
        ModerationReport.objects.create(
            reporter=request.user, target_kind=mmod.T_PERSON,
            target_id=str(target_user_id)[:64], categories=rpt["categories"],
            note=rpt["note"], valid=rpt["valid"],
            snapshot=built["snapshot"], snapshot_source=rpt["snapshot_source"])
        if not rpt["valid"]:
            return _badreq("invalid_report")
        existing = [{"valid": r.valid, "reporter_id": r.reporter_id,
                     "created_at": r.created_at}
                    for r in ModerationReport.objects.filter(
                        target_kind=mmod.T_PERSON,
                        target_id=str(target_user_id))]
        decision = mmod.evaluate_report(
            {**rpt, "reporter_id": request.user.id}, existing, mmod.STATUS_VISIBLE)
        item = ModerationItem.objects.filter(
            target_kind=mmod.T_PERSON, target_id=str(target_user_id)).exclude(
            queue_state=mmod.Q_RESOLVED).order_by("-opened_at").first()
        if item is None:
            b = mmod.build_queue_item(
                None, mmod.T_PERSON, target_user_id, rpt["categories"],
                decision["severe"],
                decision["new_status"] or mmod.STATUS_VISIBLE)
            item = ModerationItem.objects.create(
                target_kind=mmod.T_PERSON, target_id=str(target_user_id)[:64],
                categories=b["categories"], severe=b["severe"],
                content_status=b["content_status"], queue_state=b["queue_state"],
                legal_retention=b["legal_retention"],
                report_count=b["report_count"])
        return Response({"accepted": True, "action": decision["action"],
                         "reason": decision["reason"], "item_id": item.id,
                         "snapshot_count": len(built["snapshot"]),
                         "server_decrypted": False})


# ---- READ-ALL ----

class ReadAllView(APIView):
    """POST /api/messenger/read-all -> mark every 1:1 chat read for the user
    (append the user id to read_by on unread incoming messages). Idempotent."""

    def post(self, request):
        from .models import CircleMessage
        members = CircleMember.objects.filter(
            user=request.user, state="accepted")
        refs = [{"chat_kind": "member", "chat_id": m.id} for m in members]
        plan = mui.read_all_plan(refs)
        uid = request.user.id
        marked = 0
        qs = CircleMessage.objects.filter(
            member__user=request.user).exclude(sender=request.user)
        for msg in qs.iterator():
            rb = msg.read_by or []
            if uid not in rb:
                rb.append(uid)
                msg.read_by = rb
                msg.save(update_fields=["read_by"])
                marked += 1
        return Response({"ok": True, "chats": plan["count"],
                         "messages_marked": marked})


# ---- PER-CHAT theme/wallpaper + disappearing (reuse circle_extras ChatSettings) ----

class ChatThemeView(APIView):
    """GET/POST /api/messenger/chat/<member_id>/settings -> per-chat theme /
    wallpaper / disappearing (Off/24h/7d/90d). Only disappearing_sec is
    server-enforced; theme/wallpaper persist to ChatSettings (circle_extras)."""

    def _dict(self, row):
        return {"disappearing_sec": row.disappearing_sec,
                "wallpaper": row.wallpaper,
                "wallpaper_blob_ref": row.wallpaper_blob_ref,
                "theme": row.theme, "bubble_scheme": row.bubble_scheme}

    def get(self, request, member_id):
        m = CircleMember.objects.filter(user=request.user, pk=member_id).first()
        if m is None:
            return _notfound()
        row, _ = ChatSettings.objects.get_or_create(user=request.user, peer=m)
        lang = req_lang(request)
        return Response({**self._dict(row),
                         "disappearing_choices": [
                             {"sec": s, "label": cx.disappearing_label(s, lang)}
                             for s in cx.DISAPPEAR_CHOICES],
                         "wallpapers": cx.wallpaper_catalog(lang),
                         "themes": cx.theme_catalog(lang)})

    def post(self, request, member_id):
        m = CircleMember.objects.filter(user=request.user, pk=member_id).first()
        if m is None:
            return _notfound()
        d = request.data or {}
        try:
            built = cx.build_chat_settings(
                disappearing_sec=d.get("disappearing_sec", cx.DISAPPEAR_OFF),
                wallpaper=d.get("wallpaper", "default"),
                theme=d.get("theme", "system"),
                wallpaper_blob_ref=d.get("wallpaper_blob_ref"),
                bubble_scheme=d.get("bubble_scheme"))
        except ValueError as e:
            return _badreq(str(e))
        row, _ = ChatSettings.objects.get_or_create(user=request.user, peer=m)
        row.disappearing_sec = built["disappearing_sec"]
        row.wallpaper = built.get("wallpaper", "default")
        row.wallpaper_blob_ref = built.get("wallpaper_blob_ref", "")
        row.theme = built.get("theme", "system")
        row.bubble_scheme = built.get("bubble_scheme", "")
        row.save()
        return Response({"ok": True, **self._dict(row)})


# ---- CUSTOM LISTS (feed hub filter chips) ----

class ChatListsView(APIView):
    """GET  /api/messenger/lists -> the hub filter chips (All/Unread/Favourites/
             Groups + the user's own lists).
    POST /api/messenger/lists {name, member_refs:[]} -> create a named list."""

    def get(self, request):
        lang = req_lang(request)
        rows = ChatList.objects.filter(user=request.user)
        lists = [{"id": r.id, "name": r.name, "member_refs": r.member_refs}
                 for r in rows]
        return Response({"chips": mui.hub_filter_chips(lists, lang),
                         "lists": lists})

    def post(self, request):
        d = request.data or {}
        try:
            built = mui.build_chat_list(
                request.user.id, d.get("name", ""), d.get("member_refs") or [])
        except ValueError as e:
            return _badreq(str(e).split(": ", 1)[-1])
        if ChatList.objects.filter(user=request.user, name=built["name"]).exists():
            return _badreq("duplicate_name")
        row = ChatList.objects.create(
            user=request.user, name=built["name"],
            member_refs=built["member_refs"])
        return Response({"id": row.id, "name": row.name,
                         "member_refs": row.member_refs})


class ChatListDetailView(APIView):
    """POST   /api/messenger/lists/<id> {add:[], remove:[]} -> add/remove members.
    DELETE /api/messenger/lists/<id> -> delete the list."""

    def post(self, request, pk):
        row = ChatList.objects.filter(user=request.user, pk=pk).first()
        if row is None:
            return _notfound()
        d = request.data or {}
        refs = row.member_refs or []
        if d.get("add"):
            refs = mui.list_add_members(refs, d.get("add"))
        if d.get("remove"):
            refs = mui.list_remove_members(refs, d.get("remove"))
        row.member_refs = refs
        row.save(update_fields=["member_refs"])
        return Response({"id": row.id, "name": row.name, "member_refs": refs})

    def delete(self, request, pk):
        n, _ = ChatList.objects.filter(user=request.user, pk=pk).delete()
        if not n:
            return _notfound()
        return Response({"ok": True, "deleted": pk})


# ---- BROADCAST lists (reuse circle_extras.broadcast_fanout_plan + circle gate) ----

class BroadcastListsView(APIView):
    """GET  /api/messenger/broadcast-lists -> the user's broadcast lists.
    POST /api/messenger/broadcast-lists {name, member_ids:[CircleMember ids]}
             -> create a named broadcast list."""

    def get(self, request):
        from .models import BroadcastList
        rows = BroadcastList.objects.filter(owner=request.user)
        return Response({"lists": [
            {"id": r.id, "name": r.name, "member_ids": r.member_ids}
            for r in rows]})

    def post(self, request):
        from .models import BroadcastList
        d = request.data or {}
        row = BroadcastList.objects.create(
            owner=request.user, name=str(d.get("name", ""))[:120],
            member_ids=[int(i) for i in (d.get("member_ids") or [])
                        if str(i).isdigit()])
        return Response({"id": row.id, "name": row.name,
                         "member_ids": row.member_ids})


class BroadcastSendView(APIView):
    """POST /api/messenger/broadcast-lists/<id>/send {base_client_msg_id} ->
    fan out ONE message to N INDIVIDUAL 1:1 sends. THE GATE: a recipient only
    receives it if they have the SENDER in THEIR accepted circle (resolved from
    the OTHER side's CircleMember rows). Reuses circle_extras.broadcast_fanout_plan."""

    def post(self, request, pk):
        from .models import BroadcastList
        bl = BroadcastList.objects.filter(owner=request.user, pk=pk).first()
        if bl is None:
            return _notfound()
        # Resolve recipient USER ids from the list's CircleMember refs.
        members = CircleMember.objects.filter(
            user=request.user, id__in=bl.member_ids)
        recip_user_ids, peer_by_user = [], {}
        for m in members:
            if m.peer_user_id:
                recip_user_ids.append(m.peer_user_id)
                peer_by_user[m.peer_user_id] = m.id
        # THE circle gate: the recipient must have THIS sender accepted on THEIR
        # side — look up the OTHER party's CircleMember rows pointing back at us.
        mutual = list(CircleMember.objects.filter(
            user_id__in=recip_user_ids, peer_user=request.user,
            state="accepted").values_list("user_id", flat=True))
        d = request.data or {}
        ok, reason, plan = mui.broadcast_send_plan(
            request.user.id, recip_user_ids, mutual, bl.id,
            str(d.get("base_client_msg_id", f"bcast{bl.id}")))
        if not ok:
            return _badreq(reason)   # 'not_connected' / 'no recipients' / ...
        # Re-map each per-recipient descriptor's user id back to the sender-side
        # CircleMember id the client sends to.
        for p in plan:
            p["member_id"] = peer_by_user.get(p["recipient_id"])
        return Response({"ok": True, "fanout": plan, "count": len(plan)})
