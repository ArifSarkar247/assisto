"""e2e-groups — peer-assisted history re-share for GROUP chats.

Group messages are sealed PER MEMBER (per_recipient, keyed by the member's
CircleGroupMember id; there is no shared group key). After a reinstall that
skipped the PIN restore, member A has a NEW key and none of A's per-member
copies of older group messages open any more. Every OTHER member whose own
copy still opens can help: their phone decrypts its own copy, re-encrypts the
plaintext to A's NEW key and uploads a CircleMessageCopy (for_user = A). The
original row (ciphertext + per_recipient) is never modified.

     POST circle/groups/<g>/e2/resend  {message_ids:[..]}
                                        -> A asks the group's phones
     POST circle/groups/<g>/e2/copies  {for_user_id, for_key_id, copies, done}
                                        -> a helper uploads copies for A
     GET  circle/e2/resend              -> `groups`: requests MY phone can
                                           help with (only the ids still
                                           missing that MY copy can open)
     GET  circle/groups/<g>/messages    -> each row may carry `copy` (mine)

Rules (server-enforced):
  * only ACTIVE members of the group may write or read copies; a removed /
    left member gets 404 (and never sees copies made after they left);
  * a copy is only accepted for a message the target member RECEIVED (their
    member id is in per_recipient / recipient_ids, or they sent it) and that
    the uploader received or sent too — i.e. only messages from when both
    were in the group;
  * FIRST COPY WINS per (message, for_user): a later duplicate (same target
    key) is skipped idempotently, so N helpers never produce N copies. The
    original SENDER's copy may replace another member's (strongest source);
    a copy for an OLDER key of the target is replaced;
  * ciphertext only, last 500 messages / 90 days, throttled notifications.
"""
import logging
from datetime import timedelta

from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import (CircleGroup, CircleGroupMember, CircleMessage,
                     CircleMessageCopy, E2GroupResendRequest)
from . import views_e2e_recover as E2R

log = logging.getLogger("assisto.e2e_groups")

MAX_MESSAGES = 500
SCAN_MAX = 1500             # rows read to find the newest 500 eligible
WINDOW_DAYS = E2R.RESEND_WINDOW_DAYS
KEY_CHANGE_SLACK = timedelta(minutes=10)   # senders with a stale cached key
NOTIFY_EVERY_S = E2R.RESEND_NOTIFY_EVERY_S
PUSH_MAX = 30               # silent pushes per notification round
GROUPS_MAX = 100
PENDING_MAX = 20
KINDS = ("text", "photo", "voice", "document", "video")
ACTIVE = "active"


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _active(group, user):
    return CircleGroupMember.objects.filter(
        group=group, member=user, status=ACTIVE).first()


def _rcpts(m):
    out = set()
    pr = m.per_recipient
    if isinstance(pr, dict):
        out.update(str(k) for k in pr.keys())
    for r in (m.recipient_ids if isinstance(m.recipient_ids, list) else []):
        out.add(str(r))
    return out


def received(m, gm):
    """True when membership row `gm` sent or received message `m`."""
    return m.sender_id == gm.member_id or str(gm.id) in _rcpts(m)


def _base(group, now):
    return (CircleMessage.objects.filter(
        group=group, content_type__in=KINDS,
        created_at__gte=now - timedelta(days=WINDOW_DAYS))
        .exclude(deleted="everyone").exclude(view_once=True))


def candidates(req, gm, now=None):
    """Messages of `req.group` that the requester (membership `gm`) received,
    newest MAX_MESSAGES within WINDOW_DAYS (whole = sent before the key
    change; else exactly the asked ids)."""
    now = now or timezone.now()
    qs = _base(req.group, now)
    if req.whole:
        from . import e2_keys
        row = e2_keys.key_row(req.requester)
        if row is not None and row.changed_at is not None:
            qs = qs.filter(created_at__lte=row.changed_at + KEY_CHANGE_SLACK)
    else:
        ids = [i for i in (req.message_ids or []) if isinstance(i, int)]
        if not ids:
            return []
        qs = qs.filter(id__in=ids)
    out = []
    for m in qs.order_by("-id").only(
            "id", "sender_id", "per_recipient", "recipient_ids",
            "created_at")[:SCAN_MAX]:
        if received(m, gm):
            out.append(m)
            if len(out) >= MAX_MESSAGES:
                break
    return out


def missing(req, gm, now=None):
    """Candidates that have NO copy for the requester's current key yet."""
    cand = candidates(req, gm, now)
    if not cand:
        return []
    have = set(CircleMessageCopy.objects.filter(
        message_id__in=[m.id for m in cand], for_user=req.requester,
        key_id=req.key_id).values_list("message_id", flat=True))
    return [m for m in cand if m.id not in have]


def _notify(req, now=None):
    """Real-time `e2.resend` to every other active member + a few silent
    pushes. Throttled per request. Never raises."""
    now = now or timezone.now()
    if req.notified_at and (now - req.notified_at).total_seconds() \
            < NOTIFY_EVERY_S:
        return False
    req.notified_at = now
    req.save(update_fields=["notified_at", "updated_at"])
    try:
        from .views_c2_calls import rt_publish
        from . import push
        rows = CircleGroupMember.objects.filter(
            group_id=req.group_id, status=ACTIVE).exclude(
            member_id=req.requester_id).select_related("member")
        for i, r in enumerate(rows[:256]):
            rt_publish(r.member, "e2.resend", {
                "chat": "group:%d" % req.group_id,
                "user_id": req.requester_id})
            if i < PUSH_MAX:
                push.safe_push(r.member, "e2_resend", "", "", data={
                    "chat_kind": "group", "chat_id": req.group_id})
    except Exception as e:
        log.warning("e2e_groups: notify failed %s", type(e).__name__)
    return True


def request_group_resend(requester, group, key_id, message_ids=None,
                         whole=False, reason="decrypt"):
    """Upsert the (requester, group, key) request; a new ask re-opens it for
    every helper. Never raises."""
    try:
        with transaction.atomic():
            req, _ = E2GroupResendRequest.objects.select_for_update() \
                .get_or_create(requester=requester, group=group,
                               key_id=key_id[:64],
                               defaults={"reason": reason})
            ids = list(req.message_ids or [])
            for i in (message_ids or []):
                if i not in ids:
                    ids.append(i)
            req.message_ids = ids[-E2R.RESEND_IDS_MAX:]
            req.whole = req.whole or bool(whole)
            req.asks += 1
            req.served_by = []
            req.fulfilled_at = None
            req.save()
        return req
    except Exception as e:
        log.warning("e2e_groups: request failed %s", type(e).__name__)
        return None


def on_key_changed(user):
    """The user published a DIFFERENT key: each of their groups is asked to
    re-share. Never raises."""
    try:
        from . import e2_keys
        row = e2_keys.key_row(user)
        if row is None or not row.key_id:
            return 0
        n = 0
        for gm in CircleGroupMember.objects.filter(
                member=user, status=ACTIVE).select_related("group")[:GROUPS_MAX]:
            req = request_group_resend(user, gm.group, row.key_id,
                                       whole=True, reason="key_change")
            if req is not None:
                _notify(req)
                n += 1
        return n
    except Exception as e:
        log.warning("e2e_groups: key change fan-out %s", type(e).__name__)
        return 0


def _synth(me, mine, now):
    """Co-members whose key changed in the last WINDOW_DAYS get a whole-group
    request (covers changes made before this feature)."""
    from .models import UserPublicKey
    gids = [gm.group_id for gm in mine]
    rows = CircleGroupMember.objects.filter(
        group_id__in=gids, status=ACTIVE).exclude(member=me)
    by_user = {}
    for r in rows:
        by_user.setdefault(r.member_id, []).append(r.group_id)
    if not by_user:
        return
    for k in UserPublicKey.objects.filter(
            user_id__in=list(by_user), changed_at__isnull=False,
            changed_at__gte=now - timedelta(days=WINDOW_DAYS)).exclude(
            public_key="").exclude(key_id=""):
        for gid in by_user[k.user_id]:
            E2GroupResendRequest.objects.get_or_create(
                requester_id=k.user_id, group_id=gid, key_id=k.key_id,
                defaults={"whole": True, "reason": "key_change"})


def pending_for(me, now=None):
    """Group requests MY phone can help with right now (GET circle/e2/resend
    -> `groups`). Only ids still missing that MY own copy can open."""
    from . import e2_keys
    now = now or timezone.now()
    mine = list(CircleGroupMember.objects.filter(
        member=me, status=ACTIVE)[:GROUPS_MAX])
    if not mine:
        return []
    try:
        _synth(me, mine, now)
    except Exception as e:
        log.warning("e2e_groups: synth %s", type(e).__name__)
    my_gm = {gm.group_id: gm for gm in mine}
    out = []
    for r in (E2GroupResendRequest.objects.filter(
            group_id__in=list(my_gm), fulfilled_at__isnull=True)
            .exclude(requester=me).select_related("requester", "group")
            .order_by("created_at")[:PENDING_MAX * 3]):
        if len(out) >= PENDING_MAX:
            break
        if me.id in (r.served_by or []):
            continue
        row = e2_keys.key_row(r.requester)
        if row is None or row.key_id != r.key_id:
            continue          # superseded by a newer key
        their = _active(r.group, r.requester)
        if their is None:
            continue          # the requester left: nothing to re-share
        todo = missing(r, their, now)
        if not todo:
            r.fulfilled_at = now
            r.save(update_fields=["fulfilled_at", "updated_at"])
            continue
        gm = my_gm[r.group_id]
        can = [m.id for m in todo if received(m, gm)]
        if not can:
            continue
        out.append({"id": r.id, "kind": "group", "group_id": r.group_id,
                    "user_id": r.requester_id, "member_id": their.id,
                    "my_member_id": gm.id, "key_id": r.key_id,
                    "public_key": row.public_key, "reason": r.reason,
                    "message_ids": sorted(can),
                    "since": (now - timedelta(days=WINDOW_DAYS)).isoformat()})
    return out


class E2GroupResendAskView(APIView):
    """POST circle/groups/<g>/e2/resend {message_ids} — I cannot open these
    group messages: ask the other members' phones to re-share them to my
    CURRENT key."""

    def post(self, request, pk):
        from . import e2_keys
        g = CircleGroup.objects.filter(pk=pk).first()
        gm = _active(g, request.user) if g is not None else None
        if gm is None:
            return _nf()
        mine = e2_keys.key_row(request.user)
        if mine is None or not mine.key_id:
            return Response({"ok": False, "queued": False})
        ids = E2R._ints((request.data or {}).get("message_ids"),
                        E2R.RESEND_IDS_MAX)
        now = timezone.now()
        ids = sorted(m.id for m in _base(g, now).filter(id__in=ids).only(
            "id", "sender_id", "per_recipient", "recipient_ids")
            if received(m, gm))
        if not ids:
            return Response({"ok": True, "queued": False})
        req = request_group_resend(request.user, g, mine.key_id, ids)
        notified = _notify(req, now) if req is not None else False
        return Response({"ok": req is not None, "queued": req is not None,
                         "notified": notified, "key_id": mine.key_id})


class E2GroupCopiesView(APIView):
    """POST circle/groups/<g>/e2/copies {for_user_id, for_key_id, copies,
    done} — MY phone re-encrypted group messages to a co-member's current
    key. First copy per (message, for_user) wins; originals never change."""

    def post(self, request, pk):
        from . import e2_keys
        from .logic import circle as circle_logic
        g = CircleGroup.objects.filter(pk=pk).first()
        me_gm = _active(g, request.user) if g is not None else None
        if me_gm is None:
            return _nf()
        d = request.data or {}
        try:
            fuid = int(d.get("for_user_id"))
        except (TypeError, ValueError):
            return _nf()
        if fuid == request.user.id:
            return _nf()
        for_gm = CircleGroupMember.objects.filter(
            group=g, member_id=fuid, status=ACTIVE).select_related(
            "member").first()
        if for_gm is None:
            return _nf()      # not (or no longer) a member
        target = for_gm.member
        row = e2_keys.key_row(target)
        fkid = str(d.get("for_key_id") or "")[:64]
        if row is None or not fkid or fkid != row.key_id:
            return Response({"ok": False, "stale": True,
                             "key_id": row.key_id if row else ""},
                            status=status.HTTP_409_CONFLICT)
        copies = d.get("copies") if isinstance(d.get("copies"), list) else []
        if len(copies) > E2R.MAX_COPIES_PER_CALL:
            return Response({"detail": "too many"},
                            status=status.HTTP_400_BAD_REQUEST)
        for c in copies:
            if isinstance(c, dict) and any(c.get(f) for f in E2R.FORBIDDEN):
                return Response({"detail": "ciphertext only"},
                                status=status.HTTP_400_BAD_REQUEST)
        want = E2R._ints([c.get("message_id") for c in copies
                          if isinstance(c, dict)], E2R.MAX_COPIES_PER_CALL)
        now = timezone.now()
        msgs = {m.id: m for m in _base(g, now).filter(id__in=want)
                if received(m, for_gm) and received(m, me_gm)}
        have = {c.message_id: c for c in CircleMessageCopy.objects.filter(
            message_id__in=list(msgs), for_user=target)}
        stored = dup = skipped = 0
        for c in copies:
            if not isinstance(c, dict):
                skipped += 1
                continue
            try:
                mid = int(c.get("message_id"))
            except (TypeError, ValueError):
                skipped += 1
                continue
            m = msgs.get(mid)
            ct = str(c.get("ciphertext") or "").strip()
            nonce = str(c.get("nonce") or "").strip()
            if (m is None or E2R._b64(ct, E2R.MAX_CT) is None
                    or E2R._b64(nonce, 128) is None):
                skipped += 1
                continue
            env = {"ciphertext": ct, "nonce": nonce,
                   "sender_key_id": str(c.get("sender_key_id") or ""),
                   "scheme": str(c.get("scheme") or ""),
                   "recipient_ids": [for_gm.id], "content_type": "text"}
            ok, _why = circle_logic.validate_envelope(env)
            if not ok:
                skipped += 1
                continue
            fields = {"by_user": request.user, "ciphertext": ct,
                      "nonce": nonce,
                      "sender_key_id": env["sender_key_id"][:64],
                      "scheme": env["scheme"][:64], "key_id": fkid}
            old = have.get(mid)
            if old is not None:
                sender_wins = (request.user.id == m.sender_id
                               and old.by_user_id != m.sender_id)
                if old.key_id == fkid and not sender_wins:
                    dup += 1          # first copy wins (idempotent)
                    continue
                for k, v in fields.items():
                    setattr(old, k, v)
                old.save()
                stored += 1
                continue
            try:
                with transaction.atomic():
                    have[mid] = CircleMessageCopy.objects.create(
                        message=m, for_user=target, **fields)
                stored += 1
            except IntegrityError:
                dup += 1              # another member's phone was first
        fulfilled = 0
        reqs = list(E2GroupResendRequest.objects.filter(
            requester=target, group=g, key_id=fkid,
            fulfilled_at__isnull=True))
        for r in reqs:
            changed = []
            if d.get("done") and request.user.id not in (r.served_by or []):
                r.served_by = list(r.served_by or []) + [request.user.id]
                changed.append("served_by")
            if not missing(r, for_gm, now):
                r.fulfilled_at = now
                changed.append("fulfilled_at")
                fulfilled += 1
            if changed:
                r.save(update_fields=changed + ["updated_at"])
        if stored:
            try:
                from .views_c2_calls import rt_publish
                rt_publish(target, "e2.copies",
                           {"chat": "group:%d" % g.id, "count": stored})
            except Exception:
                pass
        return Response({"ok": True, "stored": stored, "duplicate": dup,
                         "skipped": skipped, "fulfilled": fulfilled})
