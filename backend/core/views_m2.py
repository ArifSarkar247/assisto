"""Messenger M2 endpoints: Groups (item 7) + Status/Stories (item 8) + Extras
(items 9 + 10).

Thin wiring over the pure logic in core/logic/{circle_groups,circle_status,
circle_extras}.py. EVERY enforcement gate the reviewers flagged runs SERVER-SIDE
here — the client cannot bypass it:

  Groups   validate_group_envelope (reject plaintext incl per_recipient),
           can_add_member / can_redeem_invite (circle-only; a leaked invite
           still refuses a stranger), the capability matrix for promote/demote/
           remove/post, last-admin protection, poll index-only tally, group
           video reuses circle_calls.can_place_call.
  Status   validate_status_meta + disk_floor_ok on create; can_view_status
           (block both ways) on tray/author/view; /mine serializes
           named_viewers only (+ anonymous COUNT, never raw anon ids); the view
           endpoint re-checks can_view_status + is_active before record_view.
  Extras   scheduled stores an OPAQUE envelope only; broadcast uses
           broadcast_fanout_plan -> N individual 1:1 messages with distinct
           client_msg_ids and NO shared id row; backup via
           validate_backup_envelope (secrets rejected).

All user-facing copy follows Accept-Language via i18n.req_lang + the pure fns'
bilingual pick().
"""
from django.conf import settings
from django.contrib.auth import get_user_model
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from .logic import (circle, circle_groups as G, circle_status as S,
                    circle_extras as X, circle_calls as CC)
from . import plans, push
from .models import (CircleMember, CircleMessage, CircleGroup,
                     CircleGroupMember, GroupPoll, PollVote, CircleStatus,
                     StatusView, StatusMute, ChatSettings, ScheduledMessage,
                     BroadcastList, UserSticker, ChatBackup, LinkedDevice,
                     CirclePrivacy)

User = get_user_model()


# ===========================================================================
# Shared helpers
# ===========================================================================
def _not_found():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _my_membership(group, user):
    """The requester's ACTIVE membership row in `group`, or None."""
    return CircleGroupMember.objects.filter(
        group=group, member=user, status=G.MEMBERSHIP_ACTIVE).first()


def _admin_count(group):
    return CircleGroupMember.objects.filter(
        group=group, role=G.ROLE_ADMIN, status=G.MEMBERSHIP_ACTIVE).count()


def _active_count(group):
    return CircleGroupMember.objects.filter(
        group=group, status=G.MEMBERSHIP_ACTIVE).count()


def _rel_state_to(viewer, other_user):
    """The requester's relationship state to `other_user`, resolved from the
    requester's CircleMember edges (matched by phone — the only stable join we
    have, since CircleMember has no peer_user FK). Returns a circle.REQ_* value
    or 'pending' when no accepted edge exists. Used by can_add_member /
    can_redeem_invite so a stranger with a leaked invite is refused."""
    phone = (getattr(other_user, "phone", "") or "").strip()
    if not phone:
        return "pending"
    edge = CircleMember.objects.filter(user=viewer, phone=phone).first()
    return edge.state if edge else "pending"


def _peer_key_for(viewer, member_user):
    """(public_key, key_id) the VIEWER uses to encrypt to `member_user`, resolved
    from the viewer's own CircleMember edge (keys are published per-edge). Empty
    strings when the viewer has no recorded edge yet."""
    phone = (getattr(member_user, "phone", "") or "").strip()
    if phone:
        edge = CircleMember.objects.filter(user=viewer, phone=phone).first()
        if edge:
            return edge.public_key, edge.key_id
    return "", ""


def _group_dict(group, me):
    mine = _my_membership(group, me)
    return {
        "id": group.id, "name": group.name, "description": group.description,
        "photo_ref": group.photo_ref,
        "size_limit": group.size_limit,
        "announcements_only": group.announcements_only,
        "pinned_ids": group.pinned_ids or [],
        "member_count": _active_count(group),
        "my_role": (mine.role if mine else None),
        "my_member_id": (mine.id if mine else None),
        "created_at": group.created_at.isoformat(),
        # m1-messenger: the viewer's ⋮ state (mute / disappearing / theme /
        # favourite) so a reload shows what the server actually holds.
        **_m1_group_prefs(group, me),
    }


def _m1_group_prefs(group, me):
    from .views_m1_messenger import group_prefs_for
    try:
        return group_prefs_for(group, me)
    except Exception:
        return {}


# ===========================================================================
# GROUPS — item 7
# ===========================================================================
class CircleGroupsView(APIView):
    """GET  /circle/groups          -> groups I'm an active member of
       POST /circle/groups          -> create a group (new_group); I'm admin."""
    def get(self, request):
        me = request.user
        gids = CircleGroupMember.objects.filter(
            member=me, status=G.MEMBERSHIP_ACTIVE).values_list("group_id", flat=True)
        groups = CircleGroup.objects.filter(id__in=list(gids))
        return Response({"results": [_group_dict(g, me) for g in groups]})

    def post(self, request):
        d = request.data or {}
        info = G.sanitize_group_info(
            d.get("name", ""), d.get("description", ""), d.get("photo_ref"))
        if not info["name"]:
            return Response({"detail": "group name required"},
                            status=status.HTTP_400_BAD_REQUEST)
        g = CircleGroup.objects.create(
            creator=request.user, name=info["name"],
            description=info["description"], photo_ref=info["photo_ref"] or "",
            size_limit=G.clamp_size_limit(d.get("size_limit", G.SIZE_LIMIT_DEFAULT)),
            announcements_only=bool(d.get("announcements_only", False)))
        # Seed the creator as the first admin.
        CircleGroupMember.objects.create(
            group=g, member=request.user, role=G.ROLE_ADMIN,
            status=G.MEMBERSHIP_ACTIVE)
        return Response(_group_dict(g, request.user),
                        status=status.HTTP_201_CREATED)


class CircleGroupDetailView(APIView):
    """GET  /circle/groups/<id>     -> group info (members only)
       POST /circle/groups/<id>     -> edit (sanitize_group_info; admin cap)."""
    def get(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None or _my_membership(g, request.user) is None:
            return _not_found()
        return Response(_group_dict(g, request.user))

    def post(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        if not G.has_capability(mine.role, "edit_group"):
            return Response({"detail": "not_admin"},
                            status=status.HTTP_403_FORBIDDEN)
        d = request.data or {}
        info = G.sanitize_group_info(
            d.get("name", g.name), d.get("description", g.description),
            d.get("photo_ref", g.photo_ref))
        g.name = info["name"] or g.name
        g.description = info["description"]
        if info["photo_ref"] is not None:
            g.photo_ref = info["photo_ref"] or ""
        g.save(update_fields=["name", "description", "photo_ref"])
        return Response(_group_dict(g, request.user))


class CircleGroupMembersView(APIView):
    """GET  /circle/groups/<id>/members -> roster (per-viewer keys + roles)
       POST /circle/groups/<id>/members -> add a member (can_add_member, circle-
            only). Body: {user_id}."""
    def _roster(self, g, me):
        mine = _my_membership(g, me)
        rows = CircleGroupMember.objects.filter(
            group=g, status=G.MEMBERSHIP_ACTIVE).select_related("member")
        out = []
        for r in rows:
            is_self = (r.member_id == me.id)
            if is_self:
                pub, kid = "", ""  # my own key lives on my device
            else:
                pub, kid = _peer_key_for(me, r.member)
            out.append({
                "member_id": r.id,
                "user_id": r.member_id,
                "name": (r.member.name or ""),
                "role": r.role,
                "public_key": pub,
                "key_id": kid,
                "is_self": is_self,
                "my_member_id": (mine.id if mine else None),
                "my_role": (mine.role if mine else None),
                "joined_at": r.joined_at.isoformat(),
            })
        return out

    def get(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None or _my_membership(g, request.user) is None:
            return _not_found()
        return Response({"results": self._roster(g, request.user)})

    def post(self, request, pk):
        lang = req_lang(request)
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        uid = (request.data or {}).get("user_id")
        candidate = User.objects.filter(pk=uid).first() if uid else None
        if candidate is None:
            return _not_found()
        existing = CircleGroupMember.objects.filter(
            group=g, member=candidate).first()
        already = bool(existing and existing.status == G.MEMBERSHIP_ACTIVE)
        rel = _rel_state_to(request.user, candidate)
        gate = G.can_add_member(
            mine.role, rel, _active_count(g), size_limit=g.size_limit,
            already_member=already)
        if not gate["allowed"]:
            return Response({"allowed": False, "reason": gate["reason"]},
                            status=status.HTTP_403_FORBIDDEN)
        if existing:
            existing.status = G.MEMBERSHIP_ACTIVE
            existing.role = G.ROLE_MEMBER
            existing.save(update_fields=["status", "role"])
            row = existing
        else:
            row = CircleGroupMember.objects.create(
                group=g, member=candidate, role=G.ROLE_MEMBER,
                status=G.MEMBERSHIP_ACTIVE)
        note = G.member_added_notification(
            request.user.name or "", candidate.name or "", lang)
        return Response({"ok": True, "member_id": row.id,
                         "user_id": candidate.id, "notification": note},
                        status=status.HTTP_201_CREATED)


class CircleGroupMemberActionView(APIView):
    """POST /circle/groups/<id>/members/<mid>/<event> -> remove|promote|demote.
    Capability matrix + last-admin protection run server-side."""
    def post(self, request, pk, mid, event):
        lang = req_lang(request)
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        target = CircleGroupMember.objects.filter(
            group=g, pk=mid, status=G.MEMBERSHIP_ACTIVE).select_related(
            "member").first()
        if target is None:
            return _not_found()
        admin_count = _admin_count(g)
        target_is_actor = (target.member_id == request.user.id)

        if event == "remove":
            gate = G.can_remove_member(mine.role, target.role,
                                       target_is_actor=target_is_actor,
                                       admin_count=admin_count)
            if not gate["allowed"]:
                return Response({"allowed": False, "reason": gate["reason"]},
                                status=status.HTTP_403_FORBIDDEN)
            new_status, _ = G.apply_membership_event(target.status, "remove")
            target.status = new_status
            target.save(update_fields=["status"])
            note = G.member_removed_notification(
                request.user.name or "", target.member.name or "", lang)
            return Response({"ok": True, "status": target.status,
                             "notification": note})

        if event in ("promote", "demote"):
            new_role, changed, reason = G.apply_role_event(
                target.role, event, mine.role, admin_count=admin_count,
                target_is_actor=target_is_actor)
            if not changed:
                return Response({"allowed": False, "reason": reason},
                                status=status.HTTP_403_FORBIDDEN)
            target.role = new_role
            target.save(update_fields=["role"])
            note = G.role_changed_notification(
                target.member.name or "", new_role, lang)
            return Response({"ok": True, "role": target.role,
                             "notification": note})

        return Response({"detail": "unknown event"},
                        status=status.HTTP_400_BAD_REQUEST)


class CircleGroupMessagesView(APIView):
    """GET  /circle/groups/<id>/messages -> ciphertext messages (members only)
       POST /circle/groups/<id>/messages -> relay a group envelope.
    validate_group_envelope (ciphertext-only incl per_recipient) + can_post gate
    run server-side before persisting."""
    def get(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None or _my_membership(g, request.user) is None:
            return _not_found()
        # m1-messenger: hide what I cleared / deleted-for-me / what expired.
        from .views_m1_messenger import visible_group_messages
        msgs = visible_group_messages(g, request.user)
        out = [{
            "id": x.id, "sender_id": x.sender_id, "content_type": x.content_type,
            "ciphertext": x.ciphertext, "nonce": x.nonce, "blob_ref": x.blob_ref,
            "per_recipient": x.per_recipient, "mentions": x.mentions or [],
            "sender_key_id": x.sender_key_id, "scheme": x.scheme,
            "reactions": x.reactions or {}, "pinned": x.pinned,
            "announcement": x.announcement,
            "deleted": x.deleted or "",
            "starred": request.user.id in (x.starred_by or []),
            "created_at": x.created_at.isoformat(),
            "mine": x.sender_id == request.user.id,
        } for x in msgs]
        return Response({"results": out})

    def post(self, request, pk):
        lang = req_lang(request)
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        # Announcements-only gate.
        if not G.can_post(mine.role, announcements_only=g.announcements_only):
            return Response({"detail": G.post_blocked_reason(lang)},
                            status=status.HTTP_403_FORBIDDEN)
        env = dict(request.data or {})
        env.setdefault("content_type", "text")
        # group_id is SERVER-SET from the URL — never trust a client-supplied one.
        env["group_id"] = g.id
        # The client sends a PER-RECIPIENT fan-out map and NO top-level
        # ciphertext/nonce (there is no shared group key). The base relay
        # validator requires inline ciphertext/nonce for a text envelope, so —
        # exactly like build_group_fanout — lift the FIRST per_recipient entry's
        # (ciphertext, nonce) to the top level. This supplies the missing-but-
        # not-plaintext fields WITHOUT ever accepting plaintext: the per_recipient
        # map is itself still validated for forbidden keys below.
        pr = env.get("per_recipient")
        if isinstance(pr, dict) and pr and not env.get("ciphertext"):
            first = None
            rids = env.get("recipient_ids") or []
            if rids:
                first = pr.get(str(rids[0])) or pr.get(rids[0])
            if first is None:
                first = next(iter(pr.values()))
            if isinstance(first, dict):
                env.setdefault("ciphertext", first.get("ciphertext", ""))
                env.setdefault("nonce", first.get("nonce", ""))
        # SERVER-ENFORCED: prove ciphertext-only (incl per_recipient fan-out map).
        ok, reason = G.validate_group_envelope(env)
        if not ok:
            return Response({"detail": reason},
                            status=status.HTTP_400_BAD_REQUEST)
        # idempotent dedupe on (sender, group, client_msg_id).
        cmid = str(env.get("client_msg_id", ""))[:64]
        if cmid:
            dup = CircleMessage.objects.filter(
                sender=request.user, group=g, client_msg_id=cmid).first()
            if dup is not None:
                return Response({"id": dup.id, "ok": True, "deduped": True},
                                status=status.HTTP_200_OK)
        mentions = G.mention_targets(env)
        x = CircleMessage.objects.create(
            member=None, sender=request.user, group=g,
            recipient_ids=env.get("recipient_ids", []),
            content_type=env["content_type"],
            ciphertext=env.get("ciphertext", ""),
            nonce=env.get("nonce", ""),
            blob_ref=env.get("blob_ref", ""),
            sender_key_id=env.get("sender_key_id", ""),
            scheme=env.get("scheme", ""),
            per_recipient=env.get("per_recipient"),
            mentions=mentions or None,
            announcement=bool(env.get("announcement", False)),
            client_msg_id=cmid)
        push.hook_group_message(request.user, g, x)   # key-gated, never raises
        return Response({"id": x.id, "ok": True, "mentions": mentions},
                        status=status.HTTP_201_CREATED)


class CircleGroupMessageActionView(APIView):
    """POST /circle/groups/messages/<mid>/<action> -> react|pin. Pin is admin-
    only, group-scoped, capped (can_pin_group / apply_pin_group)."""
    def post(self, request, mid, action):
        x = CircleMessage.objects.filter(pk=mid).exclude(group=None).first()
        if x is None:
            return _not_found()
        g = x.group
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        d = request.data or {}
        if action == "react":
            env = {"reactions": x.reactions or {}}
            emoji = str(d.get("emoji", ""))[:8]
            if emoji:
                env, _ = G.add_reaction(env, request.user.id, emoji)
            else:
                env, _ = G.remove_reaction(env, request.user.id)
            x.reactions = env["reactions"]
            x.save(update_fields=["reactions"])
            return Response({"ok": True, "reactions": x.reactions,
                             "summary": G.reaction_summary(env)})
        if action == "pin":
            pin = bool(d.get("pin", not x.pinned))
            new_pins, ok = G.apply_pin_group(
                mine.role, g.pinned_ids or [], x.id, pin=pin)
            if not ok:
                return Response({"ok": False, "detail": "pin_cap_or_not_admin"},
                                status=status.HTTP_403_FORBIDDEN)
            g.pinned_ids = new_pins
            g.save(update_fields=["pinned_ids"])
            x.pinned = x.id in new_pins
            x.save(update_fields=["pinned"])
            return Response({"ok": True, "pinned": x.pinned,
                             "pinned_ids": new_pins})
        return Response({"detail": "unknown action"},
                        status=status.HTTP_400_BAD_REQUEST)


class CircleGroupPollsView(APIView):
    """GET  /circle/groups/<id>/polls -> polls + tallies
       POST /circle/groups/<id>/polls -> create a poll. Accepts the client
            PER-RECIPIENT maps (question_ct:{mid:env}, options_ct:{mid:[env,...]})
            verbatim: each option is sealed per recipient (there is no shared
            group key). option_count is DERIVED from the per-recipient option
            list length (every recipient must agree); the maps are stored opaque
            and the tally is BY INDEX only."""
    def _poll_dict(self, p):
        votes = {v.voter_id: (v.choices or [])
                 for v in PollVote.objects.filter(poll=p)}
        poll_pure = {"option_count": p.option_count, "multi": p.multi,
                     "closed": p.closed}
        return {
            "id": p.id, "author_id": p.author_id,
            "option_count": p.option_count, "multi": p.multi,
            "closed": p.closed, "question_ct": p.question_ct,
            "options_ct": p.options_ct,
            "tally": G.tally_poll(poll_pure, votes),
            "created_at": p.created_at.isoformat(),
        }

    def get(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None or _my_membership(g, request.user) is None:
            return _not_found()
        polls = GroupPoll.objects.filter(group=g)
        return Response({"results": [self._poll_dict(p) for p in polls]})

    def post(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        if not G.can_create_poll(mine.role):
            return Response({"detail": "not_allowed"},
                            status=status.HTTP_403_FORBIDDEN)
        d = request.data or {}
        # PER-RECIPIENT maps keyed by member id (there is no shared group key, so
        # the question + every option are sealed once per recipient).
        #   question_ct : {member_id: {ciphertext, nonce, ...}}
        #   options_ct  : {member_id: [{ciphertext, nonce, ...}, ...]}
        question_ct = d.get("question_ct") or {}
        options_ct = d.get("options_ct") or {}
        if not isinstance(question_ct, dict) or not isinstance(options_ct, dict):
            return Response({"detail": "question_ct/options_ct must be "
                                       "per-recipient maps"},
                            status=status.HTTP_400_BAD_REQUEST)
        if not options_ct:
            return Response({"detail": "options_ct must carry at least one "
                                       "recipient"},
                            status=status.HTTP_400_BAD_REQUEST)
        # Derive option_count from the per-recipient option lists; EVERY
        # recipient's list must be the same length (= option_count) so the
        # index-only tally is well defined. Reject any mismatch.
        option_count = None
        for mid, opts in options_ct.items():
            if not isinstance(opts, (list, tuple)):
                return Response({"detail": "options_ct entry must be a list"},
                                status=status.HTTP_400_BAD_REQUEST)
            if option_count is None:
                option_count = len(opts)
            elif len(opts) != option_count:
                return Response({"detail": "options_ct length mismatch across "
                                           "recipients"},
                                status=status.HTTP_400_BAD_REQUEST)
        # Reject any plaintext/forbidden key smuggled inside the maps (reuse the
        # circle_groups forbidden-key set — the server never reads a label).
        def _opaque(entry):
            return not (isinstance(entry, dict)
                        and (G.FORBIDDEN_META_KEYS & set(entry.keys())))
        for env in question_ct.values():
            if not _opaque(env):
                return Response({"detail": "poll question carries plaintext"},
                                status=status.HTTP_400_BAD_REQUEST)
        for opts in options_ct.values():
            for env in opts:
                if not _opaque(env):
                    return Response({"detail": "poll option carries plaintext"},
                                    status=status.HTTP_400_BAD_REQUEST)
        # Bounds check via new_poll (reuses POLL_MIN/MAX_OPTIONS as the single
        # source of truth) with a stub flat list of the derived length; the
        # per-recipient MAPS are what we persist as opaque JSON.
        try:
            G.new_poll(
                poll_id=None, group_id=g.id, author_id=request.user.id,
                option_count=option_count,
                question_ct={}, options_ct=[{} for _ in range(option_count)],
                multi=bool(d.get("multi", False)))
        except ValueError as e:
            return Response({"detail": str(e)},
                            status=status.HTTP_400_BAD_REQUEST)
        p = GroupPoll.objects.create(
            group=g, author=request.user,
            option_count=option_count, multi=bool(d.get("multi", False)),
            question_ct=question_ct, options_ct=options_ct)
        return Response(self._poll_dict(p), status=status.HTTP_201_CREATED)


class CircleGroupPollActionView(APIView):
    """POST /circle/groups/polls/<pid>/vote  (body {choices:[idx,...]})
       POST /circle/groups/polls/<pid>/close
    validate_vote / apply_vote (index-only, re-vote replaces) + close_poll."""
    def post(self, request, pid, action):
        p = GroupPoll.objects.filter(pk=pid).first()
        if p is None:
            return _not_found()
        g = p.group
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        poll_pure = {"option_count": p.option_count, "multi": p.multi,
                     "closed": p.closed}
        if action == "vote":
            choices = (request.data or {}).get("choices") or []
            try:
                choices = [int(c) for c in choices]
            except (TypeError, ValueError):
                return Response({"detail": "choice_out_of_range"},
                                status=status.HTTP_400_BAD_REQUEST)
            ok, reason = G.validate_vote(poll_pure, choices)
            if not ok:
                return Response({"detail": reason},
                                status=status.HTTP_400_BAD_REQUEST)
            # apply_vote normalizes/dedupes the voter's choice set.
            merged, _, _ = G.apply_vote({}, poll_pure, request.user.id, choices)
            PollVote.objects.update_or_create(
                poll=p, voter=request.user,
                defaults={"choices": merged[request.user.id]})
            votes = {v.voter_id: (v.choices or [])
                     for v in PollVote.objects.filter(poll=p)}
            return Response({"ok": True, "tally": G.tally_poll(poll_pure, votes)})
        if action == "close":
            poll2, ok = G.close_poll(
                {"closed": p.closed}, mine.role,
                author_id=p.author_id, actor_id=request.user.id)
            if not ok:
                return Response({"detail": "not_allowed"},
                                status=status.HTTP_403_FORBIDDEN)
            p.closed = True
            p.save(update_fields=["closed"])
            return Response({"ok": True, "closed": True})
        return Response({"detail": "unknown action"},
                        status=status.HTTP_400_BAD_REQUEST)


class CircleGroupSettingsView(APIView):
    """POST /circle/groups/<id>/announcements  (body {on})  -> admin only
       POST /circle/groups/<id>/size-limit     (body {size_limit}) -> clamp."""
    def post(self, request, pk, setting):
        lang = req_lang(request)
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        d = request.data or {}
        if setting == "announcements":
            if not G.has_capability(mine.role, "set_announcements_only"):
                return Response({"detail": "not_admin"},
                                status=status.HTTP_403_FORBIDDEN)
            on = bool(d.get("on", False))
            g.announcements_only = on
            g.save(update_fields=["announcements_only"])
            return Response({"ok": True, "announcements_only": on,
                             "notification": G.announcements_mode_notification(on, lang)})
        if setting == "size-limit":
            if not G.has_capability(mine.role, "set_size_limit"):
                return Response({"detail": "not_admin"},
                                status=status.HTTP_403_FORBIDDEN)
            g.size_limit = G.clamp_size_limit(d.get("size_limit", g.size_limit))
            g.save(update_fields=["size_limit"])
            return Response({"ok": True, "size_limit": g.size_limit})
        return Response({"detail": "unknown setting"},
                        status=status.HTTP_400_BAD_REQUEST)


class CircleGroupInviteView(APIView):
    """GET  /circle/groups/<id>/invite        -> mint a signed invite (admin)
       POST /circle/groups/<id>/invite/redeem -> redeem (can_redeem_invite,
            circle-gated). Body: {token}."""
    def get(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        if not G.has_capability(mine.role, "add_member"):
            return Response({"detail": "not_admin"},
                            status=status.HTTP_403_FORBIDDEN)
        token = G.make_group_invite(g.id, request.user.id, settings.SECRET_KEY)
        return Response({"token": token, "url": G.group_invite_url(token)})

    def post(self, request, pk):
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        token = str((request.data or {}).get("token", ""))
        ok, data = G.parse_group_invite(token, settings.SECRET_KEY)
        if not ok:
            return Response({"allowed": False, "reason": data},
                            status=status.HTTP_400_BAD_REQUEST)
        # token binds group_id; it must match this group.
        if str(data.get("group_id")) != str(g.id):
            return Response({"allowed": False, "reason": "group_mismatch"},
                            status=status.HTTP_400_BAD_REQUEST)
        inviter = User.objects.filter(pk=data["inviter_id"]).first()
        existing = CircleGroupMember.objects.filter(
            group=g, member=request.user).first()
        already = bool(existing and existing.status == G.MEMBERSHIP_ACTIVE)
        # CIRCLE-GATED: joiner must be an accepted circle member of the INVITER.
        # Resolve the joiner's relationship to the inviter from the joiner's own
        # edges (a leaked link cannot admit a stranger).
        rel = _rel_state_to(request.user, inviter) if inviter else "pending"
        gate = G.can_redeem_invite(rel, _active_count(g),
                                   size_limit=g.size_limit,
                                   already_member=already)
        if not gate["allowed"]:
            return Response({"allowed": False, "reason": gate["reason"]},
                            status=status.HTTP_403_FORBIDDEN)
        if existing:
            existing.status = G.MEMBERSHIP_ACTIVE
            existing.save(update_fields=["status"])
            row = existing
        else:
            row = CircleGroupMember.objects.create(
                group=g, member=request.user, role=G.ROLE_MEMBER,
                status=G.MEMBERSHIP_ACTIVE)
        return Response({"ok": True, "member_id": row.id, "group_id": g.id},
                        status=status.HTTP_201_CREATED)


class CircleGroupLeaveView(APIView):
    """POST /circle/groups/<id>/leave -> can_leave (last admin must promote first
    unless they're the last member, in which case the group dissolves)."""
    def post(self, request, pk):
        lang = req_lang(request)
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        gate = G.can_leave(mine.role, admin_count=_admin_count(g),
                           member_count=_active_count(g))
        if not gate["allowed"]:
            return Response({"allowed": False, "reason": gate["reason"]},
                            status=status.HTTP_403_FORBIDDEN)
        new_status, _ = G.apply_membership_event(mine.status, "leave")
        mine.status = new_status
        mine.save(update_fields=["status"])
        if gate["dissolves"]:
            g.delete()
        note = G.member_left_notification(request.user.name or "", lang)
        return Response({"ok": True, "dissolved": gate["dissolves"],
                         "notification": note})


class CircleGroupReportView(APIView):
    """POST /circle/groups/<id>/report -> group_report_payload (reuses 1:1 shape).
    Body: {reason, note, target_member_id?}."""
    def post(self, request, pk):
        lang = req_lang(request)
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None or _my_membership(g, request.user) is None:
            return _not_found()
        d = request.data or {}
        payload = G.group_report_payload(
            request.user.id, g.id, d.get("reason", "other"),
            target_member_id=d.get("target_member_id"),
            note=d.get("note", ""), lang=lang)
        return Response(payload, status=status.HTTP_201_CREATED)


class CircleGroupCallView(APIView):
    """POST /circle/groups/<id>/call -> can_place_group_call (reuses
    circle_calls.can_place_call; group voice free, group video Premium)."""
    def post(self, request, pk):
        lang = req_lang(request)
        g = CircleGroup.objects.filter(pk=pk).first()
        if g is None:
            return _not_found()
        mine = _my_membership(g, request.user)
        if mine is None:
            return _not_found()
        kind = CC.normalize_kind((request.data or {}).get("kind", "voice"))
        initiator = {
            "id": request.user.id, "plan": plans.effective_plan(request.user),
            "video_unlocked": False, "role": mine.role,
        }
        gate = G.can_place_group_call(initiator, kind,
                                      member_count=_active_count(g))
        if not gate["allowed"]:
            body = {"allowed": False, "kind": kind,
                    "upgrade_required": gate.get("upgrade_required", False),
                    "reason": gate.get("reason")}
            if gate.get("upgrade_required"):
                body["prompt"] = G.group_call_upgrade_prompt(lang)
            return Response(body, status=status.HTTP_200_OK)
        return Response({"allowed": True, "kind": kind,
                         "group_video": gate.get("group_video", False),
                         "member_count": gate.get("member_count")},
                        status=status.HTTP_200_OK)


# ===========================================================================
# STATUS / STORIES — item 8
# ===========================================================================
def _status_author_dict(author_user):
    """Block sets for can_view_status, resolved from the AUTHOR's circle edges:
    `blocked` = peers the author blocked. (blocked_by is the author's view of who
    blocked them; we resolve what we can from edges.)"""
    edges = CircleMember.objects.filter(user=author_user, blocked=True)
    blocked_phones = {(e.phone or "").strip() for e in edges if e.phone}
    return {"id": author_user.id, "_blocked_phones": blocked_phones}


def _viewer_dict(author_user, viewer_user):
    """viewer dict for can_view_status: relation (viewer->author) + muted set."""
    rel = ""
    v_phone = (getattr(viewer_user, "phone", "") or "").strip()
    a_phone = (getattr(author_user, "phone", "") or "").strip()
    # the viewer's relation TO the author = the author's edge to the viewer
    if v_phone:
        e = CircleMember.objects.filter(user=author_user, phone=v_phone).first()
        if e:
            rel = e.relation
    muted = set(StatusMute.objects.filter(
        muter=viewer_user, author=author_user).values_list(
        "author_id", flat=True))
    return {"id": viewer_user.id, "relation": rel, "muted_authors": muted}


def _blocked_either(author_user, viewer_user):
    """True if either side blocked the other (block always wins)."""
    v_phone = (getattr(viewer_user, "phone", "") or "").strip()
    a_phone = (getattr(author_user, "phone", "") or "").strip()
    if v_phone and CircleMember.objects.filter(
            user=author_user, phone=v_phone, blocked=True).exists():
        return True
    if a_phone and CircleMember.objects.filter(
            user=viewer_user, phone=a_phone, blocked=True).exists():
        return True
    return False


def _can_view(author_user, viewer_user, st):
    """Server-side can_view_status wrapper (block both ways + visibility)."""
    if author_user.id == viewer_user.id:
        return True
    if _blocked_either(author_user, viewer_user):
        return False
    author = {"id": author_user.id}
    viewer = _viewer_dict(author_user, viewer_user)
    return S.can_view_status(author, viewer, st.visibility,
                             status={"expires_at": st.expires_at.isoformat()})


def _read_receipts_on(user):
    row = CirclePrivacy.objects.filter(user=user).first()
    return bool(row.read_receipts) if row else True


class CircleStatusView(APIView):
    """GET  /circle/status -> tray grouped by author (can_view_status filtered)
       POST /circle/status -> create (validate_status_meta + disk_floor_ok)."""
    def get(self, request):
        me = request.user
        now = timezone.now()
        # candidate active statuses = everyone I have an edge to + my own.
        active = CircleStatus.objects.filter(expires_at__gt=now)
        visible = []
        for st in active.select_related("author"):
            if not _can_view(st.author, me, st):
                continue
            seen = StatusView.objects.filter(status=st, viewer=me).exists()
            visible.append({
                "id": st.id, "author_id": st.author_id,
                "created_at": st.created_at.isoformat(),
                "views": [{"viewer": me.id}] if seen else [],
            })
        tray = S.group_by_author(visible, me.id, now=now)
        return Response({"tray": tray})

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        kind = d.get("kind", S.STATUS_TEXT)
        # disk floor check for media status blobs.
        if kind in (S.STATUS_PHOTO, S.STATUS_VIDEO):
            free = int(d.get("free_bytes", 0) or 0)
            incoming = int(d.get("byte_size", 0) or 0)
            if free and not S.disk_floor_ok(free, incoming):
                return Response({"detail": "disk_floor"},
                                status=status.HTTP_507_INSUFFICIENT_STORAGE)
            # Build 3 STORAGE GATE: retained status media counts toward the plan
            # quota. If the user is already full, refuse the NEW media blob with
            # 413 and store nothing. (Text statuses are NEVER gated.)
            from . import billing
            if billing.storage_state(request.user)["full"]:
                return Response(
                    {"error": "storage_full",
                     "state": billing.storage_state(request.user)},
                    status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        try:
            meta = S.build_status_meta(
                kind=kind, visibility=d.get("visibility"),
                ciphertext=d.get("ciphertext"), nonce=d.get("nonce"),
                scheme=d.get("scheme"), sender_key_id=d.get("sender_key_id"),
                blob_ref=d.get("blob_ref"), byte_size=d.get("byte_size"),
                quality=d.get("quality"), duration_sec=d.get("duration_sec"),
                width=d.get("width"), height=d.get("height"),
                mime_hint=d.get("mime_hint"),
                thumb_ciphertext=d.get("thumb_ciphertext"),
                thumb_nonce=d.get("thumb_nonce"),
                caption_ciphertext=d.get("caption_ciphertext"),
                caption_nonce=d.get("caption_nonce"),
                sha256_ct=d.get("sha256_ct"))
        except ValueError as e:
            return Response({"detail": str(e)},
                            status=status.HTTP_400_BAD_REQUEST)
        exp = S.expiry_for(meta["created_at"])
        st = CircleStatus.objects.create(
            author=request.user, kind=kind,
            ciphertext=meta.get("ciphertext", ""), nonce=meta.get("nonce", ""),
            scheme=meta.get("scheme", ""),
            sender_key_id=meta.get("sender_key_id", ""),
            blob_ref=meta.get("blob_ref", ""), meta=meta,
            visibility=meta["visibility"],
            expires_at=_parse_dt(exp.isoformat()))
        # Build 3: retained media counts toward storage (decremented later by the
        # status-expiry / purge sweep — WhatsApp model: delivered+expired pruned).
        if kind in (S.STATUS_PHOTO, S.STATUS_VIDEO):
            try:
                from . import billing
                billing.add_storage(request.user,
                                    int(meta.get("byte_size", 0) or 0))
            except Exception:
                pass
        return Response({"id": st.id, "ok": True,
                         "expires_at": st.expires_at.isoformat()},
                        status=status.HTTP_201_CREATED)


class CircleStatusAuthorView(APIView):
    """GET /circle/status/author/<uid> -> that author's ACTIVE statuses I may see."""
    def get(self, request, uid):
        author = User.objects.filter(pk=uid).first()
        if author is None:
            return _not_found()
        now = timezone.now()
        out = []
        for st in CircleStatus.objects.filter(author=author, expires_at__gt=now):
            if not _can_view(author, request.user, st):
                continue
            out.append(_status_payload(st, request.user, now))
        return Response({"results": out})


class CircleStatusMineView(APIView):
    """GET /circle/status/mine -> my active statuses with NAMED viewers only
    (+ anonymous COUNT). Raw anonymous viewer ids are NEVER serialized
    (reviewer P0)."""
    def get(self, request):
        now = timezone.now()
        out = []
        for st in CircleStatus.objects.filter(author=request.user,
                                              expires_at__gt=now):
            views = [{"viewer": v.viewer_id, "at": v.at.isoformat(),
                      "anonymous": v.anonymous}
                     for v in StatusView.objects.filter(status=st)]
            named = S.named_viewers(views)  # read-receipts-ON viewers only
            named_out = []
            for nv in named:
                u = User.objects.filter(pk=nv["viewer"]).first()
                named_out.append({"viewer_id": nv["viewer"],
                                  "name": (u.name if u else ""),
                                  "at": nv.get("at")})
            total = S.viewer_count(views)
            out.append({
                "id": st.id, "kind": st.kind,
                "created_at": st.created_at.isoformat(),
                "expires_at": st.expires_at.isoformat(),
                "viewer_count": total,
                "anonymous_count": total - len(named_out),
                "named_viewers": named_out,
                "summary": S.viewer_summary(views, req_lang(request)),
            })
        return Response({"results": out})


class CircleStatusViewView(APIView):
    """POST /circle/status/<id>/view -> record a view. RE-CHECKS can_view_status
    + is_active before recording (reviewer P1); honours viewer read-receipts."""
    def post(self, request, pk):
        now = timezone.now()
        st = CircleStatus.objects.filter(pk=pk).select_related("author").first()
        if st is None:
            return _not_found()
        # re-check: expired or hidden -> reject the view outright.
        if st.expires_at <= now or not _can_view(st.author, request.user, st):
            return _not_found()
        if st.author_id == request.user.id:
            return Response({"ok": True, "self": True})
        rr_on = _read_receipts_on(request.user)
        StatusView.objects.get_or_create(
            status=st, viewer=request.user,
            defaults={"anonymous": not rr_on})
        return Response({"ok": True})


class CircleStatusMuteView(APIView):
    """POST /circle/status/mute -> apply_status_mute. Body: {author_id, on}."""
    def post(self, request):
        d = request.data or {}
        author = User.objects.filter(pk=d.get("author_id")).first()
        if author is None:
            return _not_found()
        on = bool(d.get("on", True))
        if on:
            StatusMute.objects.get_or_create(muter=request.user, author=author)
        else:
            StatusMute.objects.filter(muter=request.user, author=author).delete()
        return Response({"ok": True, "muted": on, "author_id": author.id})


class CircleStatusReplyView(APIView):
    """POST /circle/status/<id>/reply -> build_status_reply_envelope ->
    the EXISTING 1:1 circle message relay (NOT stored on the status)."""
    def post(self, request, pk):
        st = CircleStatus.objects.filter(pk=pk).select_related("author").first()
        if st is None:
            return _not_found()
        if not _can_view(st.author, request.user, st) or st.expires_at <= timezone.now():
            return _not_found()
        d = request.data or {}
        try:
            env = S.build_status_reply_envelope(
                status_id=st.id, status_kind=st.kind,
                sender_id=request.user.id, author_id=st.author_id,
                ciphertext=d.get("ciphertext", ""), nonce=d.get("nonce", ""),
                scheme=d.get("scheme", ""),
                sender_key_id=d.get("sender_key_id", ""))
        except ValueError as e:
            return Response({"detail": str(e)},
                            status=status.HTTP_400_BAD_REQUEST)
        # Relay through the author's 1:1 chat edge (the viewer's edge to author).
        a_phone = (getattr(st.author, "phone", "") or "").strip()
        peer = CircleMember.objects.filter(
            user=request.user, phone=a_phone).first() if a_phone else None
        if peer is None:
            return Response({"ok": False, "detail": "no_chat_edge",
                             "envelope": env}, status=status.HTTP_200_OK)
        x = CircleMessage.objects.create(
            member=peer, sender=request.user,
            recipient_ids=env.get("recipient_ids", []),
            content_type="text", ciphertext=env.get("ciphertext", ""),
            nonce=env.get("nonce", ""), scheme=env.get("scheme", ""),
            sender_key_id=env.get("sender_key_id", ""))
        push.hook_circle_message(request.user, peer, x)   # key-gated
        return Response({"ok": True, "message_id": x.id},
                        status=status.HTTP_201_CREATED)


def _status_payload(st, viewer, now):
    return {
        "id": st.id, "author_id": st.author_id, "kind": st.kind,
        "ciphertext": st.ciphertext, "nonce": st.nonce, "scheme": st.scheme,
        "sender_key_id": st.sender_key_id, "blob_ref": st.blob_ref,
        "meta": st.meta, "created_at": st.created_at.isoformat(),
        "expires_at": st.expires_at.isoformat(),
        "seconds_remaining": S.seconds_remaining(
            {"expires_at": st.expires_at.isoformat()}, now=now),
    }


def _parse_dt(iso):
    return parse_datetime(iso)


# ===========================================================================
# EXTRAS — items 9 + 10
# ===========================================================================
class CircleChatSettingsView(APIView):
    """GET/POST /circle/<peer>/settings -> per-chat settings. Only
    disappearing_sec is server-enforced; wallpaper/theme persist to ChatSettings."""
    def _dict(self, row):
        return {
            "disappearing_sec": row.disappearing_sec,
            "wallpaper": row.wallpaper,
            "wallpaper_blob_ref": row.wallpaper_blob_ref,
            "theme": row.theme, "bubble_scheme": row.bubble_scheme,
        }

    def get(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return _not_found()
        row, _ = ChatSettings.objects.get_or_create(user=request.user, peer=m)
        from .views_m1_messenger import member_favourite
        return Response({**self._dict(row),
                         "favourite": member_favourite(request.user, m.id)})

    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return _not_found()
        # m1-messenger: PARTIAL update (a theme change no longer resets the
        # timer, and vice versa); the timer is mirrored to the peer's edge.
        from .views_m1_messenger import apply_chat_settings
        try:
            row = apply_chat_settings(request.user, m, request.data or {})
        except ValueError as e:
            return Response({"detail": str(e)},
                            status=status.HTTP_400_BAD_REQUEST)
        return Response({"ok": True, **self._dict(row)})


class CircleScheduledView(APIView):
    """GET  /circle/<peer>/scheduled -> my pending scheduled messages
       POST /circle/<peer>/scheduled -> schedule (OPAQUE envelope only;
            build_scheduled_message rejects plaintext)."""
    def get(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return _not_found()
        rows = ScheduledMessage.objects.filter(
            sender=request.user, peer=m, status="pending")
        return Response({"results": [{
            "id": r.id, "client_msg_id": r.client_msg_id,
            "send_at": r.send_at.isoformat(), "status": r.status,
            "attempt": r.attempt} for r in rows]})

    def post(self, request, pk):
        m = CircleMember.objects.filter(user=request.user, pk=pk).first()
        if m is None:
            return _not_found()
        d = request.data or {}
        envelope = dict(d.get("envelope") or {})
        send_at = d.get("send_at")
        cmid = str(d.get("client_msg_id", ""))[:64]
        if not cmid:
            return Response({"detail": "client_msg_id required"},
                            status=status.HTTP_400_BAD_REQUEST)
        try:
            built = X.build_scheduled_message(envelope, send_at, cmid)
        except ValueError as e:
            return Response({"detail": str(e)},
                            status=status.HTTP_400_BAD_REQUEST)
        row, created = ScheduledMessage.objects.update_or_create(
            sender=request.user, client_msg_id=cmid,
            defaults={"peer": m, "send_at": _parse_dt(built["send_at"]),
                      "status": "pending", "envelope": built["envelope"]})
        return Response({"id": row.id, "ok": True, "send_at": built["send_at"]},
                        status=status.HTTP_201_CREATED if created
                        else status.HTTP_200_OK)


class CircleScheduledCancelView(APIView):
    """POST /circle/scheduled/<id>/cancel -> mark cancelled."""
    def post(self, request, pk):
        row = ScheduledMessage.objects.filter(
            pk=pk, sender=request.user).first()
        if row is None:
            return _not_found()
        row.status = "cancelled"
        row.save(update_fields=["status"])
        return Response({"ok": True, "status": row.status})


class CircleBroadcastView(APIView):
    """POST /circle/broadcast -> fan out to N INDIVIDUAL 1:1 messages with
    distinct client_msg_ids and NO shared id row (reviewer G1: recipients never
    see each other). Body: {sends:[{peer_id, client_msg_id, envelope}, ...]} —
    each entry is a distinct recipient with its OWN pre-sealed opaque envelope and
    its OWN client_msg_id. We create ONE private 1:1 CircleMessage per entry;
    never a shared id, never a recipient_ids group row."""
    def post(self, request):
        d = request.data or {}
        sends = d.get("sends") or []
        if not isinstance(sends, list):
            return Response({"detail": "sends must be a list"},
                            status=status.HTTP_400_BAD_REQUEST)
        # Circle-only: every peer must be an ACCEPTED, non-blocked member of the
        # sender's own circle. We resolve CircleMember rows owned by the sender.
        peer_ids = []
        for item in sends:
            if isinstance(item, dict):
                peer_ids.append(item.get("peer_id"))
        members = {m.id: m for m in CircleMember.objects.filter(
            user=request.user, pk__in=[p for p in peer_ids if p is not None])}
        sent = []
        for item in sends:
            if not isinstance(item, dict):
                continue
            pid = item.get("peer_id")
            m = members.get(pid)
            # circle-only gate: skip strangers / non-accepted / blocked peers so a
            # broadcast can never reach outside the sender's circle.
            if m is None or m.state != "accepted" or m.blocked:
                continue
            envelope = dict(item.get("envelope") or {})
            # The envelope is pre-sealed and OPAQUE — reject any smuggled
            # plaintext/secret (reuse the forbidden-key set; defence in depth).
            bad = X.FORBIDDEN_META_KEYS & set(envelope.keys())
            if bad:
                return Response({"detail": "broadcast envelope carries "
                                           "plaintext: " + ",".join(sorted(bad))},
                                status=status.HTTP_400_BAD_REQUEST)
            cmid = str(item.get("client_msg_id", ""))[:64]
            # Each send is an INDIVIDUAL 1:1 message — NO group, NO shared id,
            # recipient_ids scoped to this single peer only (G1 invariant).
            x = CircleMessage.objects.create(
                member=m, sender=request.user, recipient_ids=[pid],
                content_type="text",
                ciphertext=envelope.get("ciphertext", ""),
                nonce=envelope.get("nonce", ""),
                scheme=envelope.get("scheme", ""),
                sender_key_id=envelope.get("sender_key_id", ""),
                client_msg_id=cmid)
            push.hook_circle_message(request.user, m, x)   # key-gated
            sent.append({"peer_id": pid, "message_id": x.id})
        return Response({"ok": True, "sent_count": len(sent), "sent": sent},
                        status=status.HTTP_201_CREATED)


class CircleBackupView(APIView):
    """GET  /circle/backup -> my latest backup envelope (opaque) + restore_plan
       POST /circle/backup -> store (validate_backup_envelope rejects secrets)."""
    def get(self, request):
        lang = req_lang(request)
        row = ChatBackup.objects.filter(owner=request.user).first()
        if row is None:
            return Response({"available": False})
        env = {
            "v": row.v, "owner_id": row.owner_id,
            "created_at": row.created_at.isoformat(), "scheme": row.scheme,
            "ciphertext": row.ciphertext, "nonce": row.nonce, "salt": row.salt,
            "iters": row.iters, "message_count": row.message_count,
            "recovery_hint": row.recovery_hint, "size_bytes": row.size_bytes,
        }
        return Response({"available": True, "envelope": env,
                         "restore_plan": X.restore_plan(env, lang)})

    def post(self, request):
        d = request.data or {}
        # Build 3 STORAGE GATE: a cloud chat backup counts toward the plan quota
        # (WhatsApp model). If the user is already full, refuse the NEW backup
        # with 413 and store nothing — a text/voice/safety path is never gated.
        from . import billing
        if billing.storage_state(request.user)["full"]:
            return Response(
                {"error": "storage_full",
                 "state": billing.storage_state(request.user)},
                status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        try:
            env = X.build_backup_envelope(
                owner_id=request.user.id,
                ciphertext_b64=d.get("ciphertext", ""),
                nonce_b64=d.get("nonce", ""), salt_b64=d.get("salt", ""),
                iters=int(d.get("iters", 0) or 0),
                message_count=int(d.get("message_count", 0) or 0),
                recovery_hint=d.get("recovery_hint", ""),
                scheme=d.get("scheme"),
                size_bytes=int(d.get("size_bytes", 0) or 0))
        except (ValueError, TypeError) as e:
            return Response({"detail": str(e)},
                            status=status.HTTP_400_BAD_REQUEST)
        # a user keeps one backup envelope — replace the previous one's bytes so
        # the quota reflects the current (latest) backup, not a growing sum.
        prev = ChatBackup.objects.filter(owner=request.user)
        prev_bytes = sum(int(r.size_bytes or 0) for r in prev)
        prev.delete()
        row = ChatBackup.objects.create(
            owner=request.user, v=env["v"], scheme=env["scheme"],
            ciphertext=env["ciphertext"], nonce=env["nonce"], salt=env["salt"],
            iters=env["iters"], message_count=env["message_count"],
            recovery_hint=env["recovery_hint"], size_bytes=env["size_bytes"])
        try:
            billing.add_storage(request.user,
                               int(env["size_bytes"] or 0) - prev_bytes)
        except Exception:
            pass
        return Response({"ok": True, "id": row.id,
                         "created_at": row.created_at.isoformat()},
                        status=status.HTTP_201_CREATED)


class CircleDevicesView(APIView):
    """GET /circle/devices -> my linked devices (item 10 — design-level)."""
    def get(self, request):
        rows = LinkedDevice.objects.filter(user=request.user, revoked=False)
        return Response({"results": [{
            "device_id": r.device_id, "platform": r.platform, "role": r.role,
            "public_key_id": r.public_key_id, "name": r.name,
            "linked_at": r.linked_at.isoformat()} for r in rows]})


class CircleDeviceLinkView(APIView):
    """POST /circle/devices/link -> can_link_device (cap + platform order:
    web only after a mobile device). Body: {device_id, platform, public_key_id,
    name, sealed_welcome?}."""
    def post(self, request):
        d = request.data or {}
        existing = [{
            "device_id": r.device_id, "platform": r.platform, "role": r.role,
            "revoked": r.revoked} for r in LinkedDevice.objects.filter(
            user=request.user)]
        platform = d.get("platform", "android")
        ok, reason = X.can_link_device(existing, platform)
        if not ok:
            return Response({"ok": False, "reason": reason},
                            status=status.HTTP_403_FORBIDDEN)
        rec = X.device_record(
            device_id=d.get("device_id", ""), platform=platform,
            public_key_id=d.get("public_key_id"), name=d.get("name", ""))
        row, _ = LinkedDevice.objects.update_or_create(
            device_id=rec["device_id"],
            defaults={"user": request.user, "platform": rec["platform"],
                      "role": rec["role"], "public_key_id": rec["public_key_id"],
                      "name": rec["name"], "revoked": False})
        return Response({"ok": True, "device_id": row.device_id},
                        status=status.HTTP_201_CREATED)


class CircleDeviceRevokeView(APIView):
    """POST /circle/devices/<device_id>/revoke -> revoke a companion device."""
    def post(self, request, device_id):
        row = LinkedDevice.objects.filter(
            user=request.user, device_id=device_id).first()
        if row is None:
            return _not_found()
        row.revoked = True
        row.save(update_fields=["revoked"])
        return Response({"ok": True, "revoked": True})
