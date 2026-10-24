"""e2e-recover — E2E key recovery (owner launch-blocker 24 Oct).

What happened: a reinstall wiped the phone's only copy of the private key, so
every older 1:1 message (incoming AND own sent — the box is symmetric) could
no longer be opened on that phone. The server never had the private key and
must never have it. Recovery therefore lives on PHONES:

1. PEER-ASSISTED HISTORY RESEND. The other party's phone still has its own
   key + our old PUBLIC key, so it can open every old message of the chat.
   When our key changes (or we ask), it re-encrypts those plaintexts to our
   NEW key and uploads them as per-recipient REPLACEMENT copies keyed by the
   original message id. The original ciphertext is never touched. Our phone
   prefers a copy only when the original does not open.

     GET  circle/e2/resend             -> requests waiting for MY phone
                                          (incl. contacts whose key changed
                                          in the last 90 days)
     POST circle/<edge>/e2/resend      -> ask the peer of my edge to re-share
                                          {message_ids?:[..], key_id?}
     POST circle/<edge>/e2/copies      -> upload copies for the peer of my
                                          edge {for_key_id, copies:[..], done}
     GET  circle/<edge>/messages       -> each row may carry `copy` (mine)

2. ENCRYPTED KEY-RING BACKUP (WhatsApp-style). The phone seals its whole key
   ring with enc_key = HKDF(scrypt(PIN, salt), "enc") — enc_key never leaves
   the phone. A SEPARATE auth_key = HKDF(scrypt(PIN, salt), "auth") is the
   proof: the server stores only sha256(auth_key) and releases the sealed
   blob only after a correct proof. Wrong proofs are counted server-side:
   5 per hour, then a 24-hour lock after 10 in a row (AuditLog).

     GET  e2/backup        -> {exists, slots:[{slot, salt, kdf, key_ids,
                               current_key_id, updated_at}], locked_until,
                               attempts_left}   (never the blob)
     POST e2/backup        -> store {salt, kdf, auth_key, blob, nonce,
                               key_ids, current_key_id}
     POST e2/backup/open   -> {proofs:[{slot, auth_key}]} -> blobs that match

HONEST LIMIT: a short numeric PIN has few combinations. Someone holding a
copy of the server database (salt + sealed blob) can try every PIN offline;
scrypt (N=2^15, r=8 -> 32 MiB per guess) only slows that down. Longer PINs
are stronger. The online path is rate-limited.
"""
import base64
import binascii
import hashlib
import hmac
import logging
from datetime import timedelta

from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import (AuditLog, CircleMember, CircleMessage, CircleMessageCopy,
                     E2KeyBackup, E2ResendRequest)

log = logging.getLogger("assisto.e2e_recover")

# ------------------------------------------------------------------ limits
WRONG_PER_HOUR = 5
WRONG_LOCK_AT = 10
LOCK_HOURS = 24
ARCHIVE_MAX = 3
MAX_BLOB = 64 * 1024          # a key ring of 32 keys is ~6 KB
MAX_CT = 96 * 1024            # one message copy (media descriptor incl. thumb)
MAX_COPIES_PER_CALL = 200
RESEND_IDS_MAX = 500
RESEND_NOTIFY_EVERY_S = 60
RESEND_WINDOW_DAYS = 90
KDF_ALGS = {"scrypt"}
KDF_MIN_N = 1 << 14
KDF_MAX_N = 1 << 18
FORBIDDEN = ("pin", "private_key", "priv", "plaintext", "text", "enc_key",
             "password")


def _audit(user, action, **detail):
    try:
        AuditLog.objects.create(user=user, action=action, detail=detail)
    except Exception:
        pass


def _b64(v, max_len, exact=None):
    """Decoded bytes of a base64 string, or None when not plain base64."""
    s = str(v or "").strip()
    if not s or len(s) > max_len:
        return None
    try:
        raw = base64.b64decode(s, validate=True)
    except (binascii.Error, ValueError):
        return None
    if exact is not None and len(raw) != exact:
        return None
    return raw


def auth_hash(auth_key_bytes):
    return hashlib.sha256(b"assisto-e2kb-v1|" + auth_key_bytes).hexdigest()


def _kdf_ok(kdf):
    if not isinstance(kdf, dict) or kdf.get("alg") not in KDF_ALGS:
        return None
    try:
        n, r, p = int(kdf.get("n")), int(kdf.get("r")), int(kdf.get("p"))
    except (TypeError, ValueError):
        return None
    if n < KDF_MIN_N or n > KDF_MAX_N or (n & (n - 1)) != 0:
        return None
    if r != 8 or p < 1 or p > 4:
        return None
    return {"alg": "scrypt", "n": n, "r": r, "p": p}


def _slots(b):
    """[{slot, salt, kdf, auth_hash, blob, nonce, key_ids, current_key_id,
    updated_at}] — slot 0 is the live backup, 1.. the archive."""
    out = [{"slot": 0, "salt": b.salt, "kdf": b.kdf, "auth_hash": b.auth_hash,
            "blob": b.blob, "nonce": b.nonce, "key_ids": b.key_ids or [],
            "current_key_id": b.current_key_id,
            "updated_at": b.updated_at.isoformat() if b.updated_at else None}]
    for i, a in enumerate(b.archive if isinstance(b.archive, list) else []):
        if isinstance(a, dict) and a.get("blob"):
            out.append(dict(a, slot=i + 1))
    return out


def _public_slot(s):
    return {k: s.get(k) for k in ("slot", "salt", "kdf", "key_ids",
                                  "current_key_id", "updated_at")}


def _lock_state(b, now):
    """(locked_until or None, attempts_left) after expiring stale windows."""
    if b.locked_until and b.locked_until <= now:
        b.locked_until = None
        b.wrong_total = 0
        b.wrong_count = 0
        b.window_start = None
    if b.window_start and now - b.window_start >= timedelta(hours=1):
        b.wrong_count = 0
        b.window_start = None
    left = max(0, min(WRONG_PER_HOUR - b.wrong_count,
                      WRONG_LOCK_AT - b.wrong_total))
    return b.locked_until, left


class E2BackupView(APIView):
    def get(self, request):
        b = E2KeyBackup.objects.filter(user=request.user).first()
        if b is None or not b.blob:
            return Response({"exists": False, "slots": [],
                             "locked_until": None,
                             "attempts_left": WRONG_PER_HOUR})
        now = timezone.now()
        locked, left = _lock_state(b, now)
        return Response({
            "exists": True,
            "slots": [_public_slot(s) for s in _slots(b)],
            "locked_until": locked.isoformat() if locked else None,
            "attempts_left": left,
        })

    def post(self, request):
        d = request.data or {}
        for f in FORBIDDEN:
            if d.get(f):
                return Response({"detail": "ciphertext only"},
                                status=status.HTTP_400_BAD_REQUEST)
        salt = _b64(d.get("salt"), 64)
        auth = _b64(d.get("auth_key"), 64, exact=32)
        blob = _b64(d.get("blob"), MAX_BLOB * 2)
        nonce = _b64(d.get("nonce"), 64, exact=12)
        kdf = _kdf_ok(d.get("kdf"))
        if (salt is None or len(salt) < 16 or auth is None or blob is None
                or nonce is None or kdf is None or len(blob) > MAX_BLOB
                or len(blob) < 16 + 32):
            return Response({"detail": "bad backup"},
                            status=status.HTTP_400_BAD_REQUEST)
        key_ids = [str(k)[:64] for k in (d.get("key_ids") or [])
                   if isinstance(k, str)][:64]
        cur = str(d.get("current_key_id") or "")[:64]
        h = auth_hash(auth)
        # PIN change: proof of the CURRENT backup = replace it outright (the
        # old-PIN copy is not kept around).
        prev = _b64(d.get("prev_auth"), 64, exact=32)
        with transaction.atomic():
            b = E2KeyBackup.objects.select_for_update().filter(
                user=request.user).first()
            archived = False
            if b is None:
                b = E2KeyBackup(user=request.user)
            elif (b.blob and not hmac.compare_digest(b.auth_hash, h)
                  and not (prev is not None and hmac.compare_digest(
                      b.auth_hash, auth_hash(prev)))):
                # Sealed under a different PIN/salt: keep the old ring in the
                # archive (never destroyed by a new phone that skipped restore).
                arch = [a for a in (b.archive or []) if isinstance(a, dict)]
                arch.insert(0, {"salt": b.salt, "kdf": b.kdf,
                                "auth_hash": b.auth_hash, "blob": b.blob,
                                "nonce": b.nonce, "key_ids": b.key_ids,
                                "current_key_id": b.current_key_id,
                                "updated_at": b.updated_at.isoformat()
                                if b.updated_at else None})
                b.archive = arch[:ARCHIVE_MAX]
                archived = True
            b.salt = d.get("salt").strip()
            b.kdf = kdf
            b.auth_hash = h
            b.blob = d.get("blob").strip()
            b.nonce = d.get("nonce").strip()
            b.key_ids = key_ids
            b.current_key_id = cur
            b.save()
        _audit(request.user, "e2.backup.saved", keys=len(key_ids),
               archived=archived)
        return Response({"ok": True, "archived": archived,
                         "updated_at": b.updated_at.isoformat()})


class E2BackupOpenView(APIView):
    def post(self, request):
        proofs = (request.data or {}).get("proofs")
        if not isinstance(proofs, list) or not proofs or len(proofs) > 8:
            return Response({"detail": "bad proof"},
                            status=status.HTTP_400_BAD_REQUEST)
        now = timezone.now()
        with transaction.atomic():
            b = E2KeyBackup.objects.select_for_update().filter(
                user=request.user).first()
            if b is None or not b.blob:
                return Response({"ok": False, "exists": False},
                                status=status.HTTP_404_NOT_FOUND)
            locked, left = _lock_state(b, now)
            if locked or left <= 0:
                b.save()
                until = locked or (b.window_start + timedelta(hours=1)
                                   if b.window_start else now)
                return Response({"ok": False, "locked": True,
                                 "locked_until": until.isoformat(),
                                 "attempts_left": 0},
                                status=status.HTTP_429_TOO_MANY_REQUESTS)
            slots = {s["slot"]: s for s in _slots(b)}
            matched = []
            for p in proofs:
                if not isinstance(p, dict):
                    continue
                try:
                    sid = int(p.get("slot", 0))
                except (TypeError, ValueError):
                    continue
                raw = _b64(p.get("auth_key"), 64, exact=32)
                s = slots.get(sid)
                if raw is None or s is None:
                    continue
                if hmac.compare_digest(str(s.get("auth_hash") or ""),
                                       auth_hash(raw)):
                    matched.append(s)
            if not matched:
                b.wrong_count += 1
                b.wrong_total += 1
                if b.window_start is None:
                    b.window_start = now
                if b.wrong_total >= WRONG_LOCK_AT:
                    b.locked_until = now + timedelta(hours=LOCK_HOURS)
                b.save()
                _audit(request.user, "e2.backup.wrong_pin",
                       count=b.wrong_total)
                if b.locked_until:
                    _audit(request.user, "e2.backup.locked",
                           until=b.locked_until.isoformat())
                locked, left = _lock_state(b, now)
                return Response({"ok": False, "attempts_left": left,
                                 "locked_until": locked.isoformat()
                                 if locked else None},
                                status=status.HTTP_403_FORBIDDEN)
            b.wrong_count = 0
            b.wrong_total = 0
            b.window_start = None
            b.save()
        _audit(request.user, "e2.backup.restored",
               slots=[s["slot"] for s in matched])
        return Response({"ok": True, "slots": [
            dict(_public_slot(s), blob=s["blob"], nonce=s["nonce"])
            for s in matched]})


# ======================================================== resend / copies
def _edge(user, pk):
    try:
        pk = int(pk)
    except (TypeError, ValueError):
        return None
    return CircleMember.objects.filter(user=user, pk=pk).first()


def _peer(edge):
    from . import e2_keys
    return e2_keys.edge_peer(edge)


def _my_edge_for(me, other):
    """MY accepted edge whose peer is `other` (my chat id for them)."""
    from . import e2_keys
    for e in CircleMember.objects.filter(user=me, state="accepted"):
        p = e2_keys.edge_peer(e)
        if p is not None and p.pk == other.pk:
            return e
    return None


def _conversation_ids(edge, ids=None):
    from .views_m1_messenger import conversation_rows
    q = conversation_rows(edge)
    if ids is not None:
        q = q.filter(id__in=list(ids))
    return set(q.values_list("id", flat=True))


def _ints(v, cap):
    out = []
    for x in (v if isinstance(v, list) else []):
        try:
            n = int(x)
        except (TypeError, ValueError):
            continue
        if n > 0 and n not in out:
            out.append(n)
        if len(out) >= cap:
            break
    return out


def notify_resend(req, target_edge=None):
    """Real-time `e2.resend` + a silent push to the target (throttled)."""
    now = timezone.now()
    if req.notified_at and (now - req.notified_at).total_seconds() \
            < RESEND_NOTIFY_EVERY_S:
        return False
    req.notified_at = now
    req.save(update_fields=["notified_at", "updated_at"])
    try:
        edge = target_edge or _my_edge_for(req.target, req.requester)
        chat = "member:%d" % edge.id if edge is not None else ""
        from .views_c2_calls import rt_publish
        from . import push
        rt_publish(req.target, "e2.resend", {"chat": chat,
                                             "user_id": req.requester_id})
        push.safe_push(req.target, "e2_resend", "", "", data={
            "chat_kind": "member", "chat_id": edge.id if edge else 0})
    except Exception as e:
        log.warning("e2e_recover: notify failed %s", type(e).__name__)
    return True


def request_resend(requester, target, key_id, message_ids=None,
                   whole=False, reason="decrypt"):
    """Upsert the (requester, target, key_id) request. Never raises."""
    try:
        with transaction.atomic():
            req, _ = E2ResendRequest.objects.select_for_update() \
                .get_or_create(requester=requester, target=target,
                               key_id=key_id[:64],
                               defaults={"reason": reason})
            ids = list(req.message_ids or [])
            for i in (message_ids or []):
                if i not in ids:
                    ids.append(i)
            req.message_ids = ids[-RESEND_IDS_MAX:]
            req.whole = req.whole or bool(whole)
            req.asks += 1
            req.fulfilled_at = None
            req.save()
        return req
    except Exception as e:
        log.warning("e2e_recover: request failed %s", type(e).__name__)
        return None


def on_key_changed(user):
    """The user published a DIFFERENT key: every accepted contact's phone is
    asked to re-share the chat to the new key. Never raises."""
    try:
        from . import e2_keys
        row = e2_keys.key_row(user)
        if row is None or not row.key_id:
            return 0
        n = 0
        for e in e2_keys._contact_edges(user):
            req = request_resend(user, e.user, row.key_id, whole=True,
                                 reason="key_change")
            if req is not None:
                notify_resend(req, target_edge=e)
                n += 1
        return n
    except Exception as e:
        log.warning("e2e_recover: key change fan-out %s", type(e).__name__)
        return 0


def _synth_key_change_requests(me, now):
    """Contacts whose key changed in the last RESEND_WINDOW_DAYS get a whole-
    chat request on MY phone (covers changes made before this feature)."""
    from . import e2_keys
    for e in CircleMember.objects.filter(user=me, state="accepted"):
        peer = e2_keys.edge_peer(e)
        if peer is None or peer.pk == me.pk:
            continue
        row = e2_keys.key_row(peer)
        if (row is None or not row.key_id or row.changed_at is None or
                now - row.changed_at > timedelta(days=RESEND_WINDOW_DAYS)):
            continue
        E2ResendRequest.objects.get_or_create(
            requester=peer, target=me, key_id=row.key_id,
            defaults={"whole": True, "reason": "key_change"})


class E2ResendPendingView(APIView):
    """GET circle/e2/resend — what MY phone should re-share, and to whom."""

    def get(self, request):
        from . import e2_keys
        me = request.user
        now = timezone.now()
        try:
            _synth_key_change_requests(me, now)
        except Exception as e:
            log.warning("e2e_recover: synth %s", type(e).__name__)
        out = []
        for r in E2ResendRequest.objects.filter(
                target=me, fulfilled_at__isnull=True).select_related(
                "requester").order_by("created_at")[:20]:
            row = e2_keys.key_row(r.requester)
            if row is None or row.key_id != r.key_id:
                continue      # superseded by a newer key: a new row covers it
            edge = _my_edge_for(me, r.requester)
            if edge is None:
                continue
            out.append({"id": r.id, "chat_id": edge.id,
                        "user_id": r.requester_id, "key_id": r.key_id,
                        "public_key": row.public_key, "whole": r.whole,
                        "message_ids": r.message_ids or [],
                        "reason": r.reason,
                        "since": (now - timedelta(days=RESEND_WINDOW_DAYS))
                        .isoformat()})
        return Response({"results": out})


class E2ResendAskView(APIView):
    """POST circle/<edge>/e2/resend {message_ids?, key_id?} — I cannot open
    these: ask the peer of my edge to re-share them to my CURRENT key."""

    def post(self, request, pk):
        from . import e2_keys
        edge = _edge(request.user, pk)
        if edge is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        peer = _peer(edge)
        mine = e2_keys.key_row(request.user)
        if peer is None or mine is None or not mine.key_id:
            return Response({"ok": False, "queued": False})
        d = request.data or {}
        ids = _ints(d.get("message_ids"), RESEND_IDS_MAX)
        if ids:
            ids = sorted(_conversation_ids(edge, ids))
        whole = bool(d.get("whole")) and not ids
        if not ids and not whole:
            return Response({"ok": True, "queued": False})
        req = request_resend(request.user, peer, mine.key_id, ids,
                             whole=whole)
        notified = notify_resend(req) if req is not None else False
        return Response({"ok": req is not None, "queued": req is not None,
                         "notified": notified,
                         "key_id": mine.key_id})


class E2CopiesView(APIView):
    """POST circle/<edge>/e2/copies — MY phone re-encrypted messages of this
    chat to the PEER's current key. Only the two parties of the chat may
    write; only messages of THIS 1:1 chat; originals are never modified."""

    def post(self, request, pk):
        from . import e2_keys
        from .logic import circle as circle_logic
        edge = _edge(request.user, pk)
        if edge is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        peer = _peer(edge)
        if peer is None or peer.pk == request.user.pk:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        row = e2_keys.key_row(peer)
        d = request.data or {}
        fkid = str(d.get("for_key_id") or "")[:64]
        if row is None or not fkid or fkid != row.key_id:
            return Response({"ok": False, "stale": True,
                             "key_id": row.key_id if row else ""},
                            status=status.HTTP_409_CONFLICT)
        copies = d.get("copies") if isinstance(d.get("copies"), list) else []
        if len(copies) > MAX_COPIES_PER_CALL:
            return Response({"detail": "too many"},
                            status=status.HTTP_400_BAD_REQUEST)
        want = _ints([c.get("message_id") for c in copies
                      if isinstance(c, dict)], MAX_COPIES_PER_CALL)
        allowed = _conversation_ids(edge, want)
        msgs = {m.id: m for m in CircleMessage.objects.filter(
            id__in=list(allowed), group__isnull=True)}
        stored = skipped = 0
        for c in copies:
            if not isinstance(c, dict):
                skipped += 1
                continue
            if any(c.get(f) for f in FORBIDDEN):
                return Response({"detail": "ciphertext only"},
                                status=status.HTTP_400_BAD_REQUEST)
            try:
                mid = int(c.get("message_id"))
            except (TypeError, ValueError):
                skipped += 1
                continue
            m = msgs.get(mid)
            ct = str(c.get("ciphertext") or "").strip()
            nonce = str(c.get("nonce") or "").strip()
            if (m is None or (m.deleted or "") == "everyone" or m.view_once
                    or _b64(ct, MAX_CT) is None or _b64(nonce, 128) is None):
                skipped += 1
                continue
            env = {"ciphertext": ct, "nonce": nonce,
                   "sender_key_id": str(c.get("sender_key_id") or ""),
                   "scheme": str(c.get("scheme") or ""),
                   "recipient_ids": [edge.id], "content_type": "text"}
            ok, _why = circle_logic.validate_envelope(env)
            if not ok:
                skipped += 1
                continue
            CircleMessageCopy.objects.update_or_create(
                message=m, for_user=peer,
                defaults={"by_user": request.user, "ciphertext": ct,
                          "nonce": nonce,
                          "sender_key_id": env["sender_key_id"][:64],
                          "scheme": env["scheme"][:64], "key_id": fkid})
            stored += 1
        done = 0
        if d.get("done"):
            done = E2ResendRequest.objects.filter(
                requester=peer, target=request.user, key_id=fkid,
                fulfilled_at__isnull=True).update(fulfilled_at=timezone.now())
        if stored:
            try:
                from .views_c2_calls import rt_publish
                back = _my_edge_for(peer, request.user)
                rt_publish(peer, "e2.copies", {
                    "chat": "member:%d" % back.id if back else "",
                    "count": stored})
            except Exception:
                pass
        return Response({"ok": True, "stored": stored, "skipped": skipped,
                         "fulfilled": done})


def annotate_copies(out_rows, msgs, viewer):
    """GET messages: attach MY replacement copy (if any) to each row. The
    original fields stay exactly as stored."""
    try:
        ids = [m.id for m in msgs]
        if not ids:
            return
        copies = {c.message_id: c for c in CircleMessageCopy.objects.filter(
            message_id__in=ids, for_user=viewer)}
        if not copies:
            return
        for row, m in zip(out_rows, msgs):
            c = copies.get(m.id)
            if c is None or (m.deleted or "") == "everyone" or m.view_once:
                continue
            row["copy"] = {"ciphertext": c.ciphertext, "nonce": c.nonce,
                           "sender_key_id": c.sender_key_id,
                           "scheme": c.scheme, "key_id": c.key_id,
                           "by": c.by_user_id}
    except Exception as e:
        log.warning("e2e_recover: annotate %s", type(e).__name__)
