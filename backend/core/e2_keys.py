"""e2-keys — the per-USER public key directory (owner order 22 Oct, item 1).

PRODUCT RULE (permanent): once a My Circle request is accepted BOTH sides can
text and call immediately. Encryption is invisible plumbing — the user never
sees a key error, and calls never depend on keys.

Before this module a user's public key only lived on CircleMember edges that
pointed at them: a key published before such an edge existed was DISCARDED,
and an accept (messenger ConnectionRequest) created both edges with no key —
so the peer's chat had nothing to encrypt to ("key isn't available yet").

Now:
  * UserPublicKey holds ONE row per user (POST circle/keys writes it);
  * every payload that carries a peer key (circle/members, chat list, group
    roster, c3 envelopes + notification pull, contact info, community message
    requests) reads it LIVE through key_of()/keys_for() — never from an edge;
  * a sender whose peer has no key calls request_key() (GET circle/keys/peer
    does it implicitly): the peer gets a silent FCM data push
    (kind=key_request) so their app publishes in the background;
  * publish() fans a `key.published` real-time event out to every contact
    (their chat id + whether the key CHANGED) and a silent `key_ready` push to
    whoever was waiting, so their outbox encrypts + sends on its own.

Only PUBLIC keys ever reach the server. Nothing here raises into a view.
"""
import logging

from django.db import models as dj_models
from django.utils import timezone

log = logging.getLogger("assisto.e2keys")

# One key_request push per (requester, target) at most this often.
REQUEST_PUSH_EVERY_S = 60
# Hard cap so a broken peer app can never be spammed forever.
REQUEST_PUSH_MAX = 30
MAX_KEY_LEN = 200


def _model():
    from .models import UserPublicKey
    return UserPublicKey


def _uid(user_or_id):
    if user_or_id is None:
        return None
    return getattr(user_or_id, "pk", user_or_id)


def key_of(user_or_id):
    """(public_key, key_id, scheme) the user last published; empty strings
    when they never published."""
    uid = _uid(user_or_id)
    if not uid:
        return "", "", ""
    row = _model().objects.filter(user_id=uid).exclude(public_key="").first()
    if row is None:
        return "", "", ""
    return row.public_key, row.key_id, row.scheme


def key_row(user_or_id):
    uid = _uid(user_or_id)
    if not uid:
        return None
    return _model().objects.filter(user_id=uid).exclude(public_key="").first()


def keys_for(user_ids):
    """{user_id: UserPublicKey} for many users in one query."""
    ids = [i for i in {_uid(u) for u in user_ids} if i]
    if not ids:
        return {}
    return {r.user_id: r for r in _model().objects.filter(
        user_id__in=ids).exclude(public_key="")}


def edge_peer(edge):
    """The OTHER party's User of a CircleMember edge (peer_user, else phone)."""
    if edge is None:
        return None
    try:
        from .push import member_peer_user
        return member_peer_user(edge)
    except Exception:
        return getattr(edge, "peer_user", None)


def edge_key(edge):
    """(public_key, key_id, scheme) of the peer of `edge`, read LIVE."""
    return key_of(edge_peer(edge))


def key_dict(row, user_id=None):
    if row is None:
        return {"user_id": user_id, "public_key": "", "key_id": "",
                "scheme": "", "updated_at": None, "changed_at": None}
    return {"user_id": row.user_id, "public_key": row.public_key,
            "key_id": row.key_id, "scheme": row.scheme,
            "updated_at": row.updated_at.isoformat() if row.updated_at else None,
            "changed_at": row.changed_at.isoformat() if row.changed_at else None}


# --------------------------------------------------------------- publish
def _contact_edges(user):
    """Accepted edges OTHER users hold for `user` (their chat id for me)."""
    from .models import CircleMember
    q = dj_models.Q(peer_user=user)
    phone = (getattr(user, "phone", "") or "").strip()
    if phone:
        q |= dj_models.Q(peer_user__isnull=True, phone=phone)
    return list(CircleMember.objects.filter(q, state="accepted")
                .exclude(user=user).select_related("user"))


def publish(user, public_key, key_id="", scheme="", now=None):
    """Upsert the user's key. Returns (row, created, changed). On a new or
    changed key every contact gets `key.published`; requesters that were
    waiting always get it (+ a silent key_ready push)."""
    Model = _model()
    now = now or timezone.now()
    pub = str(public_key or "").strip()[:MAX_KEY_LEN]
    if not pub:
        return None, False, False
    kid = str(key_id or "")[:64]
    sch = str(scheme or "")[:64]
    row = Model.objects.filter(user=user).first()
    created = row is None
    changed = False
    if created:
        row = Model.objects.create(user=user, public_key=pub, key_id=kid,
                                   scheme=sch)
    else:
        if row.public_key and row.public_key != pub:
            changed = True
            row.previous_key_id = row.key_id or ""
            row.changed_at = now
        fresh = row.public_key != pub or row.key_id != kid or row.scheme != sch
        row.public_key, row.key_id, row.scheme = pub, kid, sch
        if fresh or changed:
            row.save()
        else:
            row.save(update_fields=["updated_at"])
    try:
        _fan_out(user, row, created or changed, changed, now)
    except Exception as e:  # never break the publish
        log.warning("e2keys: fan-out failed %s", type(e).__name__)
    return row, created, changed


def _fan_out(user, row, notify_all, changed, now):
    from .models import E2KeyRequest
    from .views_c2_calls import rt_publish
    from . import push
    waiting = set(E2KeyRequest.objects.filter(
        target=user, fulfilled_at__isnull=True).values_list(
        "requester_id", flat=True))
    for e in _contact_edges(user):
        if not notify_all and e.user_id not in waiting:
            continue
        payload = {"chat": "member:%d" % e.id, "user_id": user.id,
                   "key_id": row.key_id, "changed": bool(changed)}
        rt_publish(e.user, "key.published", payload)
        if e.user_id in waiting:
            push.safe_push(e.user, "key_ready", "", "", data={
                "chat_kind": "member", "chat_id": e.id,
                "peer_user_id": user.id, "key_id": row.key_id})
    if waiting:
        E2KeyRequest.objects.filter(target=user, fulfilled_at__isnull=True) \
            .update(fulfilled_at=now)


# --------------------------------------------------------------- request
def request_key(requester, target, now=None):
    """`requester` needs `target`'s key. Returns True when a key_request push
    was queued now (False: target already has a key / throttled / no user).
    Never raises."""
    try:
        if requester is None or target is None or requester.pk == target.pk:
            return False
        if key_row(target) is not None:
            return False
        from .models import E2KeyRequest
        from . import push
        now = now or timezone.now()
        req, _ = E2KeyRequest.objects.get_or_create(
            requester=requester, target=target,
            defaults={"requested_at": now})
        if req.fulfilled_at is not None:
            req.fulfilled_at = None
            req.requested_at = now
            req.push_count = 0
            req.pushed_at = None
        due = (req.pushed_at is None or
               (now - req.pushed_at).total_seconds() >= REQUEST_PUSH_EVERY_S)
        if not due or req.push_count >= REQUEST_PUSH_MAX:
            req.save()
            return False
        req.pushed_at = now
        req.push_count += 1
        req.save()
        # Silent data push: the target's app (foreground OR background
        # isolate) publishes its public key. No title, nothing is drawn.
        push.safe_push(target, "key_request", "", "", data={
            "requester_id": requester.id})
        log.info("e2keys: key_request queued (count=%d)", req.push_count)
        return True
    except Exception as e:
        log.warning("e2keys: request_key failed %s", type(e).__name__)
        return False


def ensure_pair_keys(a, b):
    """After an accept: whichever side has no key yet is asked to publish, so
    the pair never dead-ends on 'key missing'. Returns the number queued."""
    n = 0
    try:
        if a is not None and b is not None:
            n += 1 if request_key(a, b) else 0
            n += 1 if request_key(b, a) else 0
    except Exception:
        pass
    return n


def pairs_missing_key():
    """Read-only audit: accepted (user, peer) edges whose peer has no key in
    the directory. Returns [(edge_id, owner_id, peer_id)]."""
    from .models import CircleMember
    have = set(_model().objects.exclude(public_key="")
               .values_list("user_id", flat=True))
    out = []
    for e in CircleMember.objects.filter(state="accepted",
                                         peer_user__isnull=False):
        if e.peer_user_id not in have:
            out.append((e.id, e.user_id, e.peer_user_id))
    return out
