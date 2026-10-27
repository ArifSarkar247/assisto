"""c3-msg — WhatsApp-standard message ticks, chat-list rows, notification
pull, presence and typing for My Circle.

PRIVACY: everything here is METADATA (ids, times, states). Message bodies stay
ciphertext; this module never decrypts, logs or pushes content. The device
decrypts the envelopes it pulls with its own key.

Ticks (sender view):
  sent       — the relay stored the message (row exists)
  delivered  — EVERY recipient's device fetched it (push-handler pull, app
               sync on open/resume, or opening the chat)
  read       — EVERY recipient opened the chat after it arrived AND the
               reciprocal read-receipt rule allows the sender to see it
               (circle_privacy.can_see_read_receipt: if either side turned read
               receipts off, the tick stays at delivered — like WhatsApp).

Presence / typing ride the ONE shared real-time queue (views_c2_calls
RtEvent, GET rt/events — see the "presence + typing" section below):
  POST rt/send {topic: "typing.set",   payload: {chat_kind, chat_id, state}}
  POST rt/send {topic: "presence.set", payload: {state: online|away}}
  GET  rt/events?after=<seq>&online=1   (heartbeat while My Circle is open)
  GET  /circle/rt/state     -> snapshot {now, chats:{"member:12": {...}}}
Visibility: last seen = circle_privacy 'last_seen', online = 'active_status',
both RECIPROCAL (if I hide mine I can't see yours); typing follows
can_see_typing (reciprocal `typing` flag).
"""
from datetime import timedelta

from django.db import models as dj_models
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import circle_privacy as CP
from .models import (CircleChatFlag, CircleGroup, CircleGroupMember,
                     CircleMember,
                     CircleMessage, CirclePresence, CirclePrivacy,
                     CircleReceipt, User)

MAX_BATCH = 500
PULL_LIMIT_MAX = 8
ONLINE_TTL_S = 70          # one heartbeat per ~45 s keeps a user "online"
TYPING_TTL_S = 8           # a typing event lives 8 s (client sends one / 3 s)
SYNC_CAP = 2000


def _now():
    return timezone.now()


# ---------------------------------------------------------------------------
# helpers: privacy rows
# ---------------------------------------------------------------------------
def _privacy_map(user_ids):
    """{user_id: CirclePrivacy-ish dict}; defaults when a user has no row."""
    out = {}
    for row in CirclePrivacy.objects.filter(user_id__in=list(set(user_ids))):
        out[row.user_id] = {
            "id": row.user_id, "read_receipts": row.read_receipts,
            "typing": row.typing, "visibility": row.visibility or {}}
    for uid in user_ids:
        out.setdefault(uid, {"id": uid, "read_receipts": True, "typing": True,
                             "visibility": CP.default_visibility()})
    return out


def _peer_user(edge):
    from . import push
    return push.member_peer_user(edge)


# ---------------------------------------------------------------------------
# recipients + access
# ---------------------------------------------------------------------------
def _group_member_users(gm_ids):
    return dict(CircleGroupMember.objects.filter(id__in=list(gm_ids))
                .values_list("id", "member_id"))


def recipients_map(msgs):
    """{message_id: [recipient user ids]} for a list of CircleMessage rows."""
    out = {}
    gm_ids = set()
    for x in msgs:
        if x.group_id:
            for r in (x.recipient_ids or []):
                try:
                    gm_ids.add(int(r))
                except (TypeError, ValueError):
                    pass
    gm = _group_member_users(gm_ids) if gm_ids else {}
    active_cache = {}
    peer_cache = {}
    for x in msgs:
        if x.group_id:
            users = []
            for r in (x.recipient_ids or []):
                try:
                    u = gm.get(int(r))
                except (TypeError, ValueError):
                    u = None
                if u and u != x.sender_id:
                    users.append(u)
            if not users:
                if x.group_id not in active_cache:
                    active_cache[x.group_id] = list(
                        CircleGroupMember.objects.filter(
                            group_id=x.group_id, status="active")
                        .values_list("member_id", flat=True))
                users = [u for u in active_cache[x.group_id] if u != x.sender_id]
            out[x.id] = sorted(set(users))
        else:
            edge = x.member
            if edge is None:
                out[x.id] = []
                continue
            if edge.id not in peer_cache:
                p = _peer_user(edge)
                peer_cache[edge.id] = (edge.user_id, p.id if p else None)
            owner, peer = peer_cache[edge.id]
            other = peer if x.sender_id == owner else owner
            out[x.id] = [other] if other and other != x.sender_id else []
    return out


def _can_access(user, x):
    if x.group_id:
        return CircleGroupMember.objects.filter(
            group_id=x.group_id, member=user, status="active").exists()
    if x.sender_id == user.id:
        return True
    return user.id in recipients_map([x]).get(x.id, [])


# ---------------------------------------------------------------------------
# marking receipts
# ---------------------------------------------------------------------------
def mark(user, msgs, seen=False, now=None, publish=True):
    """Record delivered (and seen) for `user` on incoming `msgs` (never on the
    user's own). Idempotent; legacy read_by/delivered_to stay in step (unread
    counts use read_by). Returns the number of rows that changed.
    x2-ticks: every change is pushed to the SENDER at once as a
    `receipt.update` realtime event (publish_receipts) — no chat reload."""
    now = now or _now()
    msgs = [x for x in msgs if x.sender_id != user.id]
    if not msgs:
        return 0
    # connect-flow (owner 25 Oct): a message REQUEST gets NO receipt at all
    # before I accept — neither delivered nor read. The sender only knows
    # the server has it. After accept the next fetch / open marks them.
    from . import msgreq
    pend = msgreq.pending_senders(
        user, {x.sender_id for x in msgs if not x.group_id})
    if pend:
        msgs = [x for x in msgs if x.group_id or x.sender_id not in pend]
        if not msgs:
            return 0
    ids = [x.id for x in msgs]
    have = {r.message_id: r for r in
            CircleReceipt.objects.filter(user=user, message_id__in=ids)}
    create, changed = [], 0
    touched = []
    for x in msgs:
        r = have.get(x.id)
        if r is None:
            create.append(CircleReceipt(message=x, user=user, delivered_at=now,
                                        seen_at=now if seen else None))
            changed += 1
            touched.append(x)
            continue
        fields = []
        if r.delivered_at is None:
            r.delivered_at = now
            fields.append("delivered_at")
        if seen and r.seen_at is None:
            r.seen_at = now
            fields.append("seen_at")
        if fields:
            r.save(update_fields=fields)
            changed += 1
            touched.append(x)
    if create:
        CircleReceipt.objects.bulk_create(create, ignore_conflicts=True)
    # srvperf: one bulk UPDATE per field set instead of one save() per
    # message (a 300-message sync was 300 round trips). No post_save
    # receiver cares (b2-badges only reacts to created rows).
    upd_d, upd_r, upd_dr = [], [], []
    for x in msgs:
        d_ch = r_ch = False
        dt = list(x.delivered_to or [])
        if user.id not in dt:
            dt.append(user.id)
            x.delivered_to = dt
            d_ch = True
        if seen:
            rb = list(x.read_by or [])
            if user.id not in rb:
                rb.append(user.id)
                x.read_by = rb
                r_ch = True
        if d_ch and r_ch:
            upd_dr.append(x)
        elif d_ch:
            upd_d.append(x)
        elif r_ch:
            upd_r.append(x)
    for rows, fields in ((upd_d, ["delivered_to"]), (upd_r, ["read_by"]),
                         (upd_dr, ["delivered_to", "read_by"])):
        if rows:
            CircleMessage.objects.bulk_update(rows, fields, batch_size=200)
    if publish and touched:
        publish_receipts(touched)
    return changed


# ---- x2-ticks ---- realtime receipt events to the SENDER -------------------
RECEIPT_EVENT_CHUNK = 200


def _sender_chat_key(x, cache):
    """The SENDER's chat key for message x: 'group:<gid>' or
    'member:<the sender's own edge id>' (what the sender's chat screen and
    chat list use). None when the sender has no edge for it."""
    if x.group_id:
        return "group:%d" % x.group_id
    edge = x.member
    if edge is None:
        return None
    if edge.user_id == x.sender_id:
        return "member:%d" % edge.id
    k = (x.sender_id, edge.user_id)
    if k not in cache:
        from . import push
        rev = push._reverse_edge(x.sender, edge.user)
        cache[k] = rev.id if rev is not None else None
    return ("member:%d" % cache[k]) if cache[k] else None


def publish_receipts(msgs):
    """`receipt.update` {chat, statuses: {"<id>": sent|delivered|read}} to
    each sender of `msgs`, computed by statuses() — so the reciprocal
    read-receipt rule is applied server-side and a hidden read is never
    sent (the sender sees delivered). Never raises; returns events queued."""
    try:
        from .views_c2_calls import rt_publish
        by_sender = {}
        for x in msgs:
            if x.sender_id:
                by_sender.setdefault(x.sender_id, []).append(x)
        if not by_sender:
            return 0
        senders = {u.id: u for u in User.objects.filter(id__in=list(by_sender))}
        n, cache = 0, {}
        for sid, xs in by_sender.items():
            sender = senders.get(sid)
            if sender is None:
                continue
            st = statuses(xs, sender)
            chats = {}
            for x in xs:
                key = _sender_chat_key(x, cache)
                if key:
                    chats.setdefault(key, {})[str(x.id)] = st.get(x.id, "sent")
            for key, m in chats.items():
                items = sorted(m.items(), key=lambda kv: int(kv[0]))
                for i in range(0, len(items), RECEIPT_EVENT_CHUNK):
                    if rt_publish(sender, "receipt.update", {
                            "chat": key,
                            "statuses": dict(items[i:i + RECEIPT_EVENT_CHUNK]),
                            }):
                        n += 1
        return n
    except Exception:
        return 0


def mark_fetched(user, msgs):
    """'Ack on any fetch': the recipient's device just downloaded these rows
    (chat open / poll) -> delivered for every incoming one still without a
    receipt. Cheap: one query for the existing receipts."""
    try:
        incoming = [x for x in msgs if x.sender_id != user.id]
        if not incoming:
            return 0
        have = set(CircleReceipt.objects.filter(
            user=user, message_id__in=[x.id for x in incoming],
            delivered_at__isnull=False).values_list("message_id", flat=True))
        todo = [x for x in incoming if x.id not in have]
        return mark(user, todo) if todo else 0
    except Exception:
        return 0
# ---- /x2-ticks ----


# ---------------------------------------------------------------------------
# status (ticks)
# ---------------------------------------------------------------------------
def status_from(recipients, receipts, sender_priv, priv_map):
    """Pure tick rule. recipients: [uid]; receipts: {uid: (delivered, seen)}.
    -> 'sent' | 'delivered' | 'read'."""
    if not recipients:
        return "sent"
    all_delivered = all(receipts.get(u, (None, None))[0] or
                        receipts.get(u, (None, None))[1] for u in recipients)
    if not all_delivered:
        return "sent"
    all_seen = all(
        receipts.get(u, (None, None))[1] and CP.can_see_read_receipt(
            sender_priv, priv_map.get(u, {"id": u}))
        for u in recipients)
    return "read" if all_seen else "delivered"


def statuses(msgs, viewer):
    """{message_id: status} for the VIEWER's own messages among `msgs`."""
    mine = [x for x in msgs if x.sender_id == viewer.id]
    if not mine:
        return {}
    rec = recipients_map(mine)
    rows = {}
    for r in CircleReceipt.objects.filter(message_id__in=[x.id for x in mine]):
        rows.setdefault(r.message_id, {})[r.user_id] = (r.delivered_at, r.seen_at)
    uids = {viewer.id}
    for v in rec.values():
        uids.update(v)
    pm = _privacy_map(list(uids))
    # t1-ticks 1a: pre-receipts messages stay at a neutral single tick.
    from .views_t1_ticks import legacy_ids
    legacy = legacy_ids(mine)
    out = {}
    for x in mine:
        out[x.id] = "sent" if x.id in legacy else status_from(
            rec.get(x.id, []), rows.get(x.id, {}), pm[viewer.id], pm)
    return out


def annotate(out_rows, msgs, viewer):
    """Add `status` to serialized message dicts (in place). Never raises.
    t1-ticks 1a: pre-receipts rows get `receipts_legacy: true`. (DELIVERED
    on fetch is x2-ticks' mark_fetched(), called by the fetch views.)"""
    from . import views_t1_ticks as T1
    try:
        st = statuses(msgs, viewer)
        legacy = T1.legacy_ids(msgs)
        for d in out_rows:
            if d.get("id") in st:
                d["status"] = st[d["id"]]
            if d.get("id") in legacy:
                d["receipts_legacy"] = True
    except Exception:
        pass
    return out_rows


# ---------------------------------------------------------------------------
# chat resolution
# ---------------------------------------------------------------------------
def _chat_rows(user, kind, chat_id):
    """(rows, ctx) for one of the user's chats, or (None, None)."""
    from .views_m1_messenger import visible_conversation, visible_group_messages
    try:
        cid = int(chat_id)
    except (TypeError, ValueError):
        return None, None
    if kind == "group":
        g = CircleGroup.objects.filter(pk=cid).first()
        if g is None or not CircleGroupMember.objects.filter(
                group=g, member=user, status="active").exists():
            return None, None
        return visible_group_messages(g, user), {"group": g}
    edge = CircleMember.objects.filter(user=user, pk=cid).first()
    if edge is None:
        return None, None
    return visible_conversation(user, edge), {"edge": edge}


def mark_chat_seen(user, kind, chat_id):
    """Opening a chat: every incoming message delivered + seen (receipts AND
    legacy read_by, which the unread badge counts), manual unread flag off."""
    rows, ctx = _chat_rows(user, kind, chat_id)
    if rows is None:
        return None
    set_marked_unread(user, kind, chat_id, False)
    n = mark(user, rows, seen=True)
    # b2-badges: my other devices' home badge refreshes at once.
    from . import b2_badges as B2
    B2.publish([user.id], "seen")
    return n


def set_marked_unread(user, kind, chat_id, on):
    try:
        if on:
            CircleChatFlag.objects.update_or_create(
                user=user, chat_kind=kind, chat_id=str(chat_id),
                defaults={"marked_unread": True})
        else:
            CircleChatFlag.objects.filter(
                user=user, chat_kind=kind, chat_id=str(chat_id)).update(
                marked_unread=False)
    except Exception:
        pass


def _flags(user):
    return {(f.chat_kind, f.chat_id) for f in CircleChatFlag.objects.filter(
        user=user, marked_unread=True)}


def sync_delivered(user):
    """Mark delivered on every incoming message in all the user's chats that
    has no receipt from this user yet (app open / resume / push handler).
    srvperf: ONE message query for all 1:1 chats (member_id IN the edges'
    conversation ids) instead of one OR-over-JOIN scan per chat, and only
    the columns mark() needs."""
    from .views_m1_messenger import conversation_edge_map
    now = _now()
    n = 0
    from django.db.models import Q
    edges = list(CircleMember.objects.filter(
        Q(state="accepted") | Q(state="pending", direction="incoming"),
        user=user))  # mr1: a request's messages are delivered too
    ids = set()
    for v in conversation_edge_map(user, edges).values():
        ids.update(v)
    if ids:
        qs = (CircleMessage.objects.filter(member_id__in=sorted(ids),
                                           group=None)
              .exclude(sender=user).exclude(receipts__user=user)
              .select_related("member", "member__peer_user", "sender")
              .only(*_MARK_FIELDS)
              .order_by("-created_at"))[:SYNC_CAP]
        n += mark(user, list(qs), now=now)
    gids = list(CircleGroupMember.objects.filter(
        member=user, status="active").values_list("group_id", flat=True))
    if gids:
        qs = (CircleMessage.objects.filter(group_id__in=gids)
              .exclude(sender=user).exclude(receipts__user=user)
              .select_related("sender").only(*_MARK_FIELDS)
              .order_by("-created_at"))[:SYNC_CAP]
        n += mark(user, list(qs), now=now)
    return n


# srvperf: what mark() / publish_receipts() / statuses() read on a message
# (the ciphertext + fan-out blobs are never needed to record a receipt).
_MARK_FIELDS = ("id", "member", "group", "sender", "recipient_ids",
                "delivered_to", "read_by", "created_at", "deleted",
                "sender_key_id", "scheme")


# ---------------------------------------------------------------------------
# envelopes for the device (chat list "last", notification pull)
# ---------------------------------------------------------------------------
def _peer_key(viewer, user_id):
    from .views_m2 import _peer_key_for
    from . import e2_keys  # e2-keys: live per-user directory
    return e2_keys.key_of(user_id)[0] or ""


def envelope_for(viewer, x, ctx, key_cache=None):
    """The ciphertext this viewer's device can decrypt for message x, plus the
    public key to decrypt it with (ECDH is symmetric, so my OWN sent message
    decrypts with the recipient's key). Content stays ciphertext."""
    key_cache = key_cache if key_cache is not None else {}
    mine = x.sender_id == viewer.id
    ct, nonce, peer_pub = x.ciphertext, x.nonce, ""
    if x.group_id:
        per = x.per_recipient if isinstance(x.per_recipient, dict) else {}
        if mine:
            # any recipient's blob + that recipient's key
            for gm_id, blob in per.items():
                uid = _group_member_users([gm_id]).get(int(gm_id)) \
                    if str(gm_id).isdigit() else None
                if uid is None or not isinstance(blob, dict):
                    continue
                if uid not in key_cache:
                    key_cache[uid] = _peer_key(viewer, uid)
                if key_cache[uid]:
                    ct, nonce, peer_pub = (blob.get("ciphertext", ""),
                                           blob.get("nonce", ""), key_cache[uid])
                    break
        else:
            gm = ctx.get("my_gm_id")
            if gm is None:
                row = CircleGroupMember.objects.filter(
                    group_id=x.group_id, member=viewer).first()
                gm = ctx["my_gm_id"] = row.id if row else None
            blob = per.get(str(gm)) if per else None
            if isinstance(blob, dict):
                ct, nonce = blob.get("ciphertext", ""), blob.get("nonce", "")
            elif per:
                ct, nonce = "", ""
            if x.sender_id not in key_cache:
                key_cache[x.sender_id] = _peer_key(viewer, x.sender_id)
            peer_pub = key_cache[x.sender_id]
    else:
        edge = ctx.get("edge")
        if edge is not None:
            if "edge_key" not in ctx:
                from . import e2_keys
                ctx["edge_key"] = e2_keys.edge_key(edge)[0] or ""
            peer_pub = ctx["edge_key"]
    return {
        "id": x.id, "sender_id": x.sender_id, "mine": mine,
        "sender_name": _cde_sender_name(viewer, x, ctx, key_cache, mine),
        "content_type": x.content_type, "ciphertext": ct, "nonce": nonce,
        "sender_key_id": x.sender_key_id, "scheme": x.scheme,
        "peer_public_key": peer_pub, "deleted": x.deleted or "",
        "created_at": x.created_at.isoformat(),
    }


def _cde_sender_name(viewer, x, ctx, cache, mine):
    """cde-chat: the sender's name as THIS viewer sees it — the shared
    nickname of the chat when one is set, else the real name."""
    if not x.sender_id:
        return ""
    name = x.sender.name or ""
    if mine:
        return name
    k = ("cde-nick", x.sender_id)
    if k not in cache:
        from . import chat_decor
        cache[k] = chat_decor.nickname_seen_by(
            viewer, x.sender, group=ctx.get("group") if x.group_id else None)
    return cache[k] or name


def _unseen_window(user, rows, limit):
    """The notification window: from the first incoming message this user has
    not SEEN, onward (my own replies interleave), newest `limit` kept."""
    incoming = [x for x in rows if x.sender_id != user.id]
    if not incoming:
        return [], []
    seen = set(CircleReceipt.objects.filter(
        user=user, message_id__in=[x.id for x in incoming],
        seen_at__isnull=False).values_list("message_id", flat=True))
    unseen = [x for x in incoming if x.id not in seen]
    if not unseen:
        return [], []
    first = unseen[0]
    idx = next(i for i, x in enumerate(rows) if x.id == first.id)
    window = [x for x in rows[idx:] if x.deleted != "everyone"]
    return window[-limit:], unseen


# ---------------------------------------------------------------------------
# chat-list augmentation (GET /circle/chats)
# ---------------------------------------------------------------------------
def augment_chat_rows(user, out):
    """Add tick status + sender name to each 1:1 row's `last`, a
    `last_key` hint, then append the user's GROUP chats (kind=group) with their
    last envelope (my own decryptable blob + key), unread count, time. Never
    raises — a failure leaves the original rows."""
    try:
        edges = {str(m.id): m for m in CircleMember.objects.filter(
            user=user, state__in=("accepted", "pending"))}  # mr1
        last_ids = [r["last"]["id"] for r in out if r.get("last")]
        msgs = {x.id: x for x in CircleMessage.objects.filter(
            id__in=last_ids).select_related("sender", "member")}
        st = statuses(list(msgs.values()), user)
        for r in out:
            r.setdefault("kind", "member")
            r.setdefault("is_group", False)
            last = r.get("last")
            if not last:
                continue
            x = msgs.get(last["id"])
            if x is None:
                continue
            if x.id in st:
                last["status"] = st[x.id]
            last["sender_name"] = x.sender.name or ""
            last["sender_key_id"] = x.sender_key_id
            edge = edges.get(str(r.get("id")))
            if edge is not None:
                from . import e2_keys
                last["peer_public_key"] = e2_keys.edge_key(edge)[0] or ""
            else:
                last["peer_public_key"] = ""
            last["created_at"] = x.created_at.isoformat()
    except Exception:
        pass
    try:
        out.extend(group_rows(user))
        out.sort(key=lambda r: r.get("at") or "", reverse=True)
    except Exception:
        pass
    try:
        flags = _flags(user)
        for r in out:
            key = ("group", str(r.get("group_id"))) if r.get("is_group") \
                else ("member", str(r.get("id")))
            r["marked_unread"] = key in flags
    except Exception:
        pass
    return out


def _group_row_prefs(user, g):
    try:
        from .views_m1_messenger import chat_pref, group_timer
        p = chat_pref(user, "group", g.id)
        t = group_timer(g)
        return {"favourite": bool(p and p.favourite),
                "disappearing_sec": (t.disappearing_sec if t else 0) or 0}
    except Exception:
        return {"favourite": False, "disappearing_sec": 0}


def group_rows(user):
    from .views_m1_messenger import visible_group_messages, organise_muted
    rows = []
    mems = (CircleGroupMember.objects.filter(member=user, status="active")
            .select_related("group"))
    from .views_e_gaps import group_organise_map   # e-gaps: pin / archive
    gorg = group_organise_map(user)
    for gm in mems:
        g = gm.group
        msgs = visible_group_messages(g, user)
        # chat-actions: a deleted group chat hides until a newer message
        from . import chat_actions as CA
        if CA.chat_hidden(user, "group", g.id, msgs):
            continue
        last = msgs[-1] if msgs else None
        from . import b2_badges as B2   # the ONE shared unread count
        unread = B2.count_unread(user, msgs)
        env = None
        if last is not None:
            env = envelope_for(user, last, {"group": g, "my_gm_id": gm.id})
            st = statuses([last], user)
            if last.id in st:
                env["status"] = st[last.id]
        try:
            muted = organise_muted(user, "group", g.id)
        except Exception:
            muted = False
        rows.append({
            "id": "g%d" % g.id, "kind": "group", "is_group": True,
            "group_id": g.id,
            "group": {"id": g.id, "name": g.name, "photo_ref": g.photo_ref,
                      "my_member_id": gm.id, "my_role": gm.role},
            "member": {"id": None, "name": g.name, "photo": ""},
            "last_text": "", "last": env, "unread": unread,
            "at": last.created_at.isoformat() if last else
            g.created_at.isoformat(),
            "status": "",
            "pinned": bool(gorg.get(str(g.id), {}).get("pinned")),
            "pin_at": gorg.get(str(g.id), {}).get("pin_at"),
            "archived": bool(gorg.get(str(g.id), {}).get("archived")),
            "muted": bool(muted), "lists": [],
            # chat-actions: the viewer's own favourite + the group timer
            **_group_row_prefs(user, g),
        })
    return rows


# ---------------------------------------------------------------------------
# views
# ---------------------------------------------------------------------------
def _ids(v):
    out = []
    for i in (v or [])[:MAX_BATCH]:
        try:
            out.append(int(i))
        except (TypeError, ValueError):
            pass
    return out


class ReceiptsView(APIView):
    """POST /circle/receipts {delivered:[ids], seen:[ids]} — batch acks from
    this device. Only messages the caller can read are touched; own messages
    are ignored."""

    def post(self, request):
        d = request.data or {}
        seen_ids = set(_ids(d.get("seen")))
        dl_ids = set(_ids(d.get("delivered"))) | seen_ids
        msgs = list(CircleMessage.objects.filter(id__in=dl_ids)
                    .select_related("member"))
        ok = [x for x in msgs if _can_access(request.user, x)]
        n = mark(request.user, [x for x in ok if x.id not in seen_ids])
        n += mark(request.user, [x for x in ok if x.id in seen_ids], seen=True)
        return Response({"ok": True, "updated": n,
                         "accepted": sorted(x.id for x in ok)})


class ReceiptsSyncView(APIView):
    """POST /circle/receipts/sync — 'this device is online and has fetched':
    delivered for everything addressed to me with no receipt yet."""

    def post(self, request):
        return Response({"ok": True, "updated": sync_delivered(request.user)})


class ChatSeenView(APIView):
    """POST /circle/<pk>/seen and /circle/groups/<pk>/seen — the chat is open:
    every incoming message is delivered + seen by me."""
    kind = "member"

    def post(self, request, pk):
        n = mark_chat_seen(request.user, self.kind, pk)
        if n is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        return Response({"ok": True, "updated": n})


class GroupChatSeenView(ChatSeenView):
    kind = "group"


class ChatUnreadFlagView(APIView):
    """POST /circle/chats/unread {chat_kind, chat_id, unread: bool} — the
    chat-list "Mark as unread" / "Mark as read". Mark as read = open-chat
    semantics (receipts + read_by: the sender gets blue ticks if allowed)."""

    def post(self, request):
        d = request.data or {}
        kind = "group" if str(d.get("chat_kind", "")) == "group" else "member"
        rows, _ = _chat_rows(request.user, kind, d.get("chat_id"))
        if rows is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        if bool(d.get("unread")):
            set_marked_unread(request.user, kind, d.get("chat_id"), True)
            return Response({"ok": True, "marked_unread": True})
        n = mark_chat_seen(request.user, kind, d.get("chat_id"))
        return Response({"ok": True, "marked_unread": False, "updated": n})


class MessageInfoView(APIView):
    """GET /circle/messages/<id>/info — the SENDER's per-recipient delivered /
    seen times (seen hidden when the reciprocal read-receipt rule says so)."""

    def get(self, request, pk):
        x = (CircleMessage.objects.filter(pk=pk).select_related("member")
             .first())
        if x is None or x.sender_id != request.user.id:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        recips = recipients_map([x]).get(x.id, [])
        # t1-ticks 1a: a pre-receipts message has no real times (any row was
        # written later by a sync / chat open) -> say so, never "Not yet".
        from .views_t1_ticks import is_legacy
        legacy = is_legacy(x)
        rec = ({} if legacy else
               {r.user_id: r for r in CircleReceipt.objects.filter(message=x)})
        pm = _privacy_map(recips + [request.user.id])
        names = dict(User.objects.filter(id__in=recips)
                     .values_list("id", "name"))
        rows = []
        for u in recips:
            r = rec.get(u)
            seen_ok = CP.can_see_read_receipt(pm[request.user.id], pm[u])
            delivered = (r.delivered_at or r.seen_at) if r else None
            seen = r.seen_at if (r and seen_ok) else None
            rows.append({
                "user_id": u, "name": names.get(u, "") or "",
                "delivered_at": delivered.isoformat() if delivered else None,
                "seen_at": seen.isoformat() if seen else None,
                "seen_hidden": bool(r and r.seen_at and not seen_ok),
                # x2-ticks: the EFFECTIVE state, shown honestly in Message
                # info ("Read receipts are off") — reciprocal, either side.
                "receipts_off": not seen_ok,
            })
        rows.sort(key=lambda z: (z["seen_at"] is None, z["seen_at"] or "",
                                 z["delivered_at"] is None, z["name"]))
        return Response({
            "id": x.id, "group": bool(x.group_id),
            "receipts_legacy": legacy,
            "created_at": x.created_at.isoformat(),
            "status": status_from(recips, {u: (r.delivered_at, r.seen_at)
                                           for u, r in rec.items()},
                                  pm[request.user.id], pm),
            "my_read_receipts": bool(pm[request.user.id].get(
                "read_receipts", True)),   # x2-ticks
            "recipients": rows})


class NotifyPullView(APIView):
    """POST /circle/notify/pull {chat_kind, chat_id, limit} — the push handler
    on the recipient's device: returns the latest (≤ limit) not-yet-seen
    window of this chat as CIPHERTEXT envelopes + keys + names, and records
    DELIVERED for every incoming message in it. The device decrypts, builds
    the MessagingStyle notification, and never sends plaintext back."""

    def post(self, request):
        d = request.data or {}
        kind = "group" if str(d.get("chat_kind", "")) == "group" else "member"
        try:
            limit = max(1, min(PULL_LIMIT_MAX, int(d.get("limit", 5))))
        except (TypeError, ValueError):
            limit = 5
        rows, ctx = _chat_rows(request.user, kind, d.get("chat_id"))
        if rows is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        window, unseen = _unseen_window(request.user, rows, limit)
        mark(request.user, unseen)
        if kind == "group":
            g = ctx["group"]
            row = CircleGroupMember.objects.filter(
                group=g, member=request.user).first()
            ctx["my_gm_id"] = row.id if row else None
            title, peer_pub = g.name, ""
            photo, photo_v = "", ""
        else:
            from .views_module5 import _member_dict
            md = _member_dict(ctx["edge"])
            title, peer_pub = (md.get("nickname") or md.get("name", ""),
                               md.get("public_key", ""))  # cde-chat
            photo, photo_v = md.get("photo", ""), md.get("photo_v", "")
        cache = {}
        msgs = [envelope_for(request.user, x, ctx, cache) for x in window]
        return Response({
            "chat": {"kind": kind, "id": int(d.get("chat_id")),
                     "title": title, "is_group": kind == "group",
                     "peer_public_key": peer_pub,
                     # x2-ticks: the notification's Person icon
                     "photo": photo, "photo_v": photo_v},
            "me": {"id": request.user.id, "name": request.user.name or ""},
            "unseen": len(unseen), "messages": msgs})


# ---------------------------------------------------------------------------
# presence + typing — over the SHARED real-time queue (mc-int unification)
# ---------------------------------------------------------------------------
# The phone runs ONE poll loop: c2-calls' GET rt/events?after=<seq>
# (PollRealtimeTransport). This module plugs into it:
#   * poll hook: `online=1` on that poll (sent only while a My Circle screen is
#     visible) is the presence heartbeat — written at most once per
#     HEARTBEAT_EVERY_S; an offline -> online flip fans out presence.update.
#   * producers on POST rt/send:
#       typing.set   {chat_kind, chat_id, state: typing|recording|stop}
#                    -> typing.update to the recipient(s) allowed to see it
#       presence.set {state: online|away} -> presence.update on a flip
#   * GET circle/rt/state stays as the SNAPSHOT (screen open, or when a
#     contact's `until` lapses — a phone that died never says "away").
# Event payloads (RtEvent envelope {"seq","topic","payload","ts"}):
#   presence.update {chat: "member:<recipient's edge id>", online, last_seen,
#                    until}
#   typing.update   {chat: "member:<id>" | "group:<id>", activity, who, ttl_s}
HEARTBEAT_EVERY_S = 30


def _presence(user):
    row, _ = CirclePresence.objects.get_or_create(user=user)
    return row


def heartbeat(user, online=True, now=None, force=False):
    """Record online / away. Returns (row, flipped) — flipped = the visible
    online state changed (the caller fans out presence.update). An online
    heartbeat that is still fresh is NOT written (battery + DB friendly)."""
    now = now or _now()
    row = _presence(user)
    was_online = bool(row.online_until and row.online_until > now)
    if (online and was_online and not force and row.online_until - now
            > timedelta(seconds=ONLINE_TTL_S - HEARTBEAT_EVERY_S)):
        return row, False
    row.last_seen = now
    row.online_until = now + timedelta(seconds=ONLINE_TTL_S) if online else None
    fields = ["last_seen", "online_until"]
    if not online:
        row.activity, row.activity_until = "", None
        fields += ["activity", "activity_until"]
    row.save(update_fields=fields)
    return row, was_online != bool(online)


def _visible_presence(viewer, owner, owner_priv, viewer_priv, relation,
                      blocked=False, contact=False):
    """(online: bool|None, last_seen: iso|None) the viewer may see.
    `contact` = the OWNER saved the viewer back (accepted edge owner->viewer),
    for the "My contacts" policy. RECIPROCAL: a viewer whose own setting is
    Nobody sees nobody's (WhatsApp rule)."""
    if blocked:
        return None, None
    o = {"visibility": owner_priv.get("visibility") or {}}
    v = {"id": viewer.id, "relation": relation, "contact": bool(contact)}
    mine = CP.normalize_visibility(viewer_priv.get("visibility") or {})
    can_ls = (CP.can_see_field(o, v, "last_seen")
              and mine.get("last_seen") != CP.VIS_NOBODY)
    can_on = (CP.can_see_field(o, v, "active_status")
              and mine.get("active_status") != CP.VIS_NOBODY)
    return can_on, can_ls


def _member_entry(viewer, e, p, r, pm, now):
    """What `viewer` (owner of edge `e` pointing at user `p`) may see of p's
    presence row `r` (None = no row)."""
    from . import push
    rev = push._reverse_edge(p, viewer)
    blocked = bool(e.blocked or (rev is not None and rev.blocked))
    rel = rev.relation if rev is not None else ""
    contact = rev is not None and rev.state == "accepted"
    can_on, can_ls = _visible_presence(viewer, p, pm[p.id], pm[viewer.id],
                                       rel, blocked, contact=contact)
    online = bool(r and r.online_until and r.online_until > now)
    act = ""
    if (r and r.activity and r.activity_until and r.activity_until > now
            and r.activity_to_user == viewer.id and not blocked
            and CP.can_see_typing(pm[viewer.id], pm[p.id])):
        act = r.activity
    on = (online or bool(act)) if can_on else None
    return {
        "online": on,
        "last_seen": (r.last_seen.isoformat() if (r and r.last_seen
                                                  and can_ls) else None),
        "until": (r.online_until.isoformat() if (on and r and r.online_until)
                  else None),
        "activity": act, "who": "",
    }


def _contact_edges_of(user):
    """Accepted CircleMember rows OTHER users hold for `user` (their chat id
    for me) — same matching as push._reverse_edge (peer_user, else phone)."""
    q = dj_models.Q(peer_user=user)
    phone = (getattr(user, "phone", "") or "").strip()
    if phone:
        q |= dj_models.Q(peer_user__isnull=True, phone=phone)
    return list(CircleMember.objects.filter(q, state="accepted")
                .exclude(user=user).select_related("user"))


def publish_presence(user, now=None):
    """presence.update to every contact, each with THEIR chat key and only
    what THEY may see (hidden -> nothing is sent). Returns the count."""
    from .views_c2_calls import rt_publish
    now = now or _now()
    try:
        r = _presence(user)
        edges = _contact_edges_of(user)
        if not edges:
            return 0
        pm = _privacy_map([user.id] + [e.user_id for e in edges])
        n = 0
        for e in edges:
            ent = _member_entry(e.user, e, user, r, pm, now)
            if ent["online"] is None and ent["last_seen"] is None:
                continue
            rt_publish(e.user, "presence.update", {
                "chat": "member:%d" % e.id, "online": ent["online"],
                "last_seen": ent["last_seen"], "until": ent["until"]})
            n += 1
        return n
    except Exception:
        return 0


def set_typing(user, kind, chat_id, st, now=None):
    """typing / recording / stop in one chat: stores it on the presence row
    (for snapshots) and pushes typing.update to whoever may see it.
    Returns False when the chat isn't the user's."""
    from . import push
    from .views_c2_calls import rt_publish
    rows, ctx = _chat_rows(user, kind, chat_id)
    if rows is None:
        return False
    now = now or _now()
    row = _presence(user)
    was_online = bool(row.online_until and row.online_until > now)
    row.last_seen = now
    row.online_until = now + timedelta(seconds=ONLINE_TTL_S)
    peer = None
    if st == "stop":
        row.activity, row.activity_until = "", None
        row.activity_to_user = row.activity_group = None
    else:
        row.activity = st
        row.activity_until = now + timedelta(seconds=TYPING_TTL_S)
        if kind == "group":
            row.activity_group, row.activity_to_user = ctx["group"].id, None
        else:
            peer = _peer_user(ctx["edge"])
            row.activity_to_user = peer.id if peer else None
            row.activity_group = None
    row.save()
    act = "" if st == "stop" else st
    try:
        if kind == "group":
            g = ctx["group"]
            gms = list(CircleGroupMember.objects.filter(
                group=g, status="active").exclude(member=user)
                .select_related("member"))
            pm = _privacy_map([user.id] + [x.member_id for x in gms])
            for gm in gms:
                if CP.can_see_typing(pm[gm.member_id], pm[user.id]):
                    rt_publish(gm.member, "typing.update", {
                        "chat": "group:%d" % g.id, "activity": act,
                        "who": user.name or "", "ttl_s": TYPING_TTL_S})
        else:
            edge = ctx["edge"]
            peer = peer or _peer_user(edge)
            # connect-flow: no typing either way before the request is
            # accepted on BOTH sides (no presence leak to a stranger).
            if (peer is not None and peer.id != user.id and not edge.blocked
                    and edge.state == "accepted"):
                rev = push._reverse_edge(peer, user)
                pm = _privacy_map([user.id, peer.id])
                if (rev is not None and not rev.blocked
                        and rev.state == "accepted"
                        and CP.can_see_typing(pm[peer.id], pm[user.id])):
                    rt_publish(peer, "typing.update", {
                        "chat": "member:%d" % rev.id, "activity": act,
                        "who": "", "ttl_s": TYPING_TTL_S})
    except Exception:
        pass
    if not was_online:
        publish_presence(user, now)
    return True


def rt_state(viewer, now=None):
    """Live state of every chat of `viewer` (the snapshot): peer presence
    (1:1) and who is typing / recording to me (1:1) or in my groups."""
    from . import push
    now = now or _now()
    edges = list(CircleMember.objects.filter(user=viewer, state="accepted"))
    peers = {}
    for e in edges:
        p = push.member_peer_user(e)
        if p is not None and p.id != viewer.id:
            peers[e.id] = (e, p)
    gms = list(CircleGroupMember.objects.filter(member=viewer, status="active"))
    gids = [g.group_id for g in gms]
    uids = {p.id for _, p in peers.values()}
    pres = {r.user_id: r for r in CirclePresence.objects.filter(
        dj_models.Q(user_id__in=list(uids)) |
        dj_models.Q(activity_group__in=gids, activity_until__gt=now))}
    pm = _privacy_map(list(set(pres.keys()) | uids | {viewer.id}))
    names = dict(User.objects.filter(id__in=list(pres.keys()))
                 .values_list("id", "name"))
    chats = {}
    for eid, (e, p) in peers.items():
        chats["member:%d" % eid] = _member_entry(viewer, e, p, pres.get(p.id),
                                                 pm, now)
    for gm in gms:
        acts = [r for r in pres.values()
                if r.activity_group == gm.group_id and r.user_id != viewer.id
                and r.activity_until and r.activity_until > now
                and CP.can_see_typing(pm[viewer.id], pm.get(r.user_id, {}))]
        if acts:
            a = acts[0]
            chats["group:%d" % gm.group_id] = {
                "online": None, "last_seen": None, "activity": a.activity,
                "who": names.get(a.user_id, "") or "",
                "count": len(acts)}
    return {"now": now.isoformat(), "chats": chats}


class RtStateView(APIView):
    """GET /circle/rt/state[?online=1] — snapshot of presence/typing for my
    chats. `online=1` also counts as a heartbeat (screen just opened)."""

    def get(self, request):
        if request.query_params.get("online") == "1":
            _, flipped = heartbeat(request.user, online=True)
            if flipped:
                publish_presence(request.user)
        return Response(rt_state(request.user))


# ---- producers / poll hook on the shared queue (views_c2_calls) ----------
def _produce_typing(request, topic, payload):
    if topic != "typing.set":
        return {"detail": "bad topic", "code": "bad_topic"}, 422
    kind = "group" if str(payload.get("chat_kind", "")) == "group" else "member"
    st = str(payload.get("state", "typing"))
    if st not in ("typing", "recording", "stop"):
        st = "typing"
    if not set_typing(request.user, kind, payload.get("chat_id"), st):
        return {"detail": "not found"}, 404
    return {"ok": True, "state": st, "ttl_s": TYPING_TTL_S}, 200


def _produce_presence(request, topic, payload):
    if topic != "presence.set":
        return {"detail": "bad topic", "code": "bad_topic"}, 422
    online = str(payload.get("state", "online")) != "away"
    _, flipped = heartbeat(request.user, online=online, force=True)
    if flipped:
        publish_presence(request.user)
    return {"ok": True, "online": online, "ttl_s": ONLINE_TTL_S}, 200


def _poll_heartbeat(request, now):
    """rt/events?online=1 — the poll IS the heartbeat (throttled write)."""
    if request.query_params.get("online") != "1":
        return
    _, flipped = heartbeat(request.user, online=True, now=now)
    if flipped:
        publish_presence(request.user, now)


def _register_rt():
    from . import views_c2_calls as C2
    C2.register_producer("typing.", _produce_typing)
    C2.register_producer("presence.", _produce_presence)
    C2.register_poll_hook(_poll_heartbeat)


_register_rt()
