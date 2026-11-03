"""p3docs — Documents vault: END-TO-END layer (owner PART 3, 3 Nov 2026).

The server is treated as an adversary here. It stores ONLY opaque blobs the
phone sealed; it never sees a PIN, a recovery code, the document master key
(DMK), a per-document key or a plaintext document. Everything below refuses
input that does not have the sealed shape (tests_p3docs proves it).

Key model (app/lib/vault/vault_e2e.dart is the other half):
  DMK            32 random bytes, made on the phone.
  PIN wrap       DMK sealed under PBKDF2(PIN)            -> phone ONLY (a 4-6
                 digit PIN would be brute-forced if the server held it).
  biometric wrap DMK sealed under a random Keystore-held key -> phone ONLY.
  recovery wrap  DMK sealed under PBKDF2(16-char code)   -> HERE (kind
                 recovery), so a NEW phone can recover; ~79-bit code.
  helper wrap    DMK sealed to a trusted My Circle person's X25519 public key
                 -> HERE (kind helper); only their phone can open it.
Lose the PIN, the phone (biometric), the recovery code AND the helper: the
sealed documents are unrecoverable — by design, Assisto cannot open them.

Sealed document (Document.e2e = True):
  file     b"AVE1" || ciphertext (ChaCha20-Poly1305, per-document key)
  details  {"e2e": 1, "box": base64(b"AVB1" || nonce || sealed JSON)}
  title "" · note ""   (doc_type + expiry_date stay plain for the expiry push)

Endpoints (all login-only):
  GET    vault/e2e/state                  wraps I have (no blob of helpers)
  PUT    vault/e2e/recovery {blob}        store / replace the recovery wrap
  GET    vault/e2e/recovery               fetch it (new phone)
  DELETE vault/e2e/recovery
  POST   vault/e2e/helpers {member_id, blob, key_id}
  DELETE vault/e2e/helpers/<id>
  POST   vault/e2e/help/request {wrap_id, public_key, key_id}   (owner)
  GET    vault/e2e/help/request                                 (owner)
  POST   vault/e2e/help/cancel                                  (owner)
  GET    vault/e2e/help/inbox                                   (helper)
  POST   vault/e2e/help/<id>/approve {blob} · /decline          (helper)
  POST   vault/share (multipart: document_id, hours, max_opens, blob)
  GET    vault/share?document_id=
  POST   vault/share/<id>/revoke
Public (no login, web/views_vault_share.py): /d/<token>, /d/<token>/blob.
"""
import base64
import binascii
import hashlib
import json
import secrets
from datetime import timedelta

from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang
from .models import AuditLog

FILE_MAGIC = b"AVE1"
BOX_MAGIC = b"AVB1"
SHARE_MAGIC = b"AVS1"
MAX_BOX_B64 = 64 * 1024
MAX_WRAP_B64 = 4096
WRAP_KEYS = {"v", "alg", "salt", "iters", "nonce", "ct", "epk", "kid"}
WRAP_CT_BYTES = 48          # 32-byte DMK + 16-byte Poly1305 tag — never 32
FORBIDDEN = ("pin", "new_pin", "vault_pin", "recovery_code", "code", "dmk",
             "key", "master_key", "private_key", "plaintext", "password")
HELP_WAIT = timedelta(hours=24)
MAX_HELP_PER_DAY = 3
MAX_HELPERS = 3
SHARE_HOURS = (1, 24, 72, 168)
SHARE_MAX_OPENS = 20
SHARE_MAX_BYTES = 10 * 1024 * 1024 + 4096
SHARE_MAX_ACTIVE = 20
# Plaintext file signatures that must never arrive as "ciphertext".
_PLAIN_MAGIC = (b"\xff\xd8\xff", b"\x89PNG", b"%PDF", b"GIF8", b"RIFF",
                b"PK\x03\x04", b"{", b"[")

_MSG = {
    "not_sealed": ("এটা এন্ড-টু-এন্ড সিল করা নয় — সার্ভার খোলা কাগজ রাখে না।",
                   "This is not end-to-end sealed — the server never keeps it in the clear."),
    "never_send": ("নিরাপত্তার জন্য PIN, কোড বা চাবি কখনো সার্ভারে পাঠানো হয় না।",
                   "For your safety a PIN, code or key is never sent to the server."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "not_in_circle": ("এই মানুষ আপনার My Circle-এ নেই।", "This person is not in your My Circle."),
    "no_key": ("তাঁর ফোনে এখনো নিরাপত্তা-চাবি তৈরি হয়নি — তাঁকে একবার Assisto খুলতে বলুন।",
               "Their phone has no security key yet — ask them to open Assisto once."),
    "too_many": ("সর্বোচ্চ ৩ জন বিশ্বস্ত মানুষ রাখা যায়।", "You can keep at most 3 trusted people."),
    "rate": ("আজ অনেকবার চাওয়া হয়েছে। কাল আবার চেষ্টা করুন।",
             "Too many requests today. Try again tomorrow."),
    "bad_hours": ("মেয়াদ বেছে নিন: ১ ঘণ্টা, ১ দিন, ৩ দিন বা ৭ দিন।",
                  "Pick 1 hour, 1 day, 3 days or 7 days."),
    "too_big": ("শেয়ার লিংকে ১০ MB পর্যন্ত ফাইল দেওয়া যায়।", "Share links take files up to 10 MB."),
    "too_many_links": ("অনেক লিংক খোলা আছে — কিছু বন্ধ করুন।",
                       "Too many open links — turn some off first."),
    "e2e_doc": ("এন্ড-টু-এন্ড তালার কাগজ এভাবে শেয়ার হয় না — 'লিংকে দেখান' ব্যবহার করুন।",
                "End-to-end locked documents can't be shared this way — use 'Show with a link'."),
    "off": ("এই সুবিধা এখনো চালু হয়নি।", "This isn't switched on yet."),
    "not_pending": ("এই অনুরোধ আর খোলা নেই।", "This request is no longer open."),
}


FLAG = "vault_e2e"


def enabled(user):
    """New sealed uploads / wraps / share links need the vault_e2e switch.
    Reading, deleting, cancelling and helping someone else never do — a
    switched-off feature must never strand a user's sealed documents."""
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user))
    except Exception:  # noqa: BLE001
        return False


def _fail(reason, request, code=status.HTTP_400_BAD_REQUEST, **extra):
    bn, en = _MSG.get(reason, _MSG["not_found"])
    return Response({"ok": False, "reason": reason,
                     "detail": pick(req_lang(request), bn, en), **extra}, status=code)


def _b64(s):
    """Strict-ish base64 (std or url-safe) -> bytes, or None."""
    if not isinstance(s, str) or not s:
        return None
    t = s.strip().replace("-", "+").replace("_", "/")
    t += "=" * (-len(t) % 4)
    try:
        return base64.b64decode(t, validate=True)
    except (binascii.Error, ValueError):
        return None


def _has_forbidden(data):
    if not hasattr(data, "keys"):
        return False
    return any(k in FORBIDDEN and data.get(k) not in (None, "") for k in data.keys())


def looks_plain(head):
    return any(head.startswith(m) for m in _PLAIN_MAGIC)


# ------------------------------------------------------------ validation
def valid_wrap(blob):
    """A wrap is base64(JSON) with ONLY the sealed-box fields and a 48-byte
    ciphertext (key + tag). A bare key, a PIN, a code -> refused."""
    if not isinstance(blob, str) or not blob or len(blob) > MAX_WRAP_B64:
        return False
    raw = _b64(blob)
    if raw is None:
        return False
    try:
        j = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return False
    if not isinstance(j, dict) or not set(j.keys()) <= WRAP_KEYS:
        return False
    ct = _b64(j.get("ct") or "")
    nonce = _b64(j.get("nonce") or "")
    if ct is None or len(ct) != WRAP_CT_BYTES or nonce is None or len(nonce) != 12:
        return False
    if j.get("alg") not in ("pbkdf2-c20p", "x25519-c20p"):
        return False
    if j["alg"] == "pbkdf2-c20p":
        salt = _b64(j.get("salt") or "")
        try:
            iters = int(j.get("iters") or 0)
        except (TypeError, ValueError):
            return False
        if salt is None or len(salt) < 16 or iters < 100000:
            return False
    else:
        epk = _b64(j.get("epk") or "")
        if epk is None or len(epk) != 32:
            return False
    return True


def validate_sealed(attrs, creating):
    """Serializer hook for Document(e2e=True). Returns an error string or ''."""
    if creating or "title" in attrs:
        if (attrs.get("title") or "").strip():
            return "sealed documents carry no plain title"
    if (attrs.get("note") or "").strip():
        return "sealed documents carry no plain note"
    if creating or "details" in attrs:
        d = attrs.get("details")
        if not isinstance(d, dict) or set(d.keys()) != {"e2e", "box"} or d.get("e2e") != 1:
            return "details must be exactly {e2e: 1, box: <sealed>}"
        box = d.get("box")
        if not isinstance(box, str) or len(box) > MAX_BOX_B64:
            return "box too large"
        raw = _b64(box)
        if raw is None or not raw.startswith(BOX_MAGIC) or len(raw) < 4 + 12 + 16:
            return "box is not sealed"
    f = attrs.get("file")
    if f is not None:
        try:
            f.seek(0)
            head = f.read(8)
            f.seek(0)
        except Exception:  # noqa: BLE001
            return "file unreadable"
        if not head.startswith(FILE_MAGIC) or looks_plain(head):
            return "file is not sealed"
    return ""


# ------------------------------------------------------------ wraps
def _wrap_row(w):
    return {"id": w.id, "kind": w.kind, "helper_user_id": w.helper_id,
            "helper_name": _name(w.helper) if w.helper_id else "",
            "created_at": w.created_at.isoformat()}


def _name(u):
    if u is None:
        return ""
    return (getattr(u, "name", "") or "").strip() or (getattr(u, "phone", "") or "")


def _log(user, action, **detail):
    try:
        AuditLog.objects.create(user=user, action=action, detail=detail)
    except Exception:  # noqa: BLE001
        pass


def _push(user, tbn, ten, bbn, ben, event):
    try:
        from . import push
        push.push_to_user(user, "reminder", tbn, ten, bbn, ben,
                          data={"route": "vault", "event": event})
    except Exception:  # noqa: BLE001
        pass


class VaultE2EStateView(APIView):
    def get(self, request):
        from .models import Document, VaultKeyWrap, VaultHelpRequest
        u = request.user
        wraps = list(VaultKeyWrap.objects.filter(user=u).select_related("helper"))
        inbox = VaultHelpRequest.objects.filter(helper=u, state="pending").count()
        return Response({
            "ok": True,
            "recovery_wrap": any(w.kind == "recovery" for w in wraps),
            "helpers": [_wrap_row(w) for w in wraps if w.kind == "helper"],
            "sealed_docs": Document.objects.filter(user=u, e2e=True).count(),
            "help_inbox": inbox,
            "server_can_read_sealed": False,
        })


class VaultRecoveryWrapView(APIView):
    def get(self, request):
        from .models import VaultKeyWrap
        w = VaultKeyWrap.objects.filter(user=request.user, kind="recovery").first()
        if w is None:
            return _fail("not_found", request, status.HTTP_404_NOT_FOUND)
        return Response({"ok": True, "blob": w.blob, "created_at": w.created_at.isoformat()})

    def put(self, request):
        from .models import VaultKeyWrap
        d = request.data or {}
        if not enabled(request.user):
            return _fail("off", request, status.HTTP_403_FORBIDDEN)
        if _has_forbidden(d):
            return _fail("never_send", request)
        blob = d.get("blob")
        if not valid_wrap(blob) or json.loads(_b64(blob)).get("alg") != "pbkdf2-c20p":
            return _fail("not_sealed", request)
        with transaction.atomic():
            VaultKeyWrap.objects.filter(user=request.user, kind="recovery").delete()
            VaultKeyWrap.objects.create(user=request.user, kind="recovery", blob=blob)
        _log(request.user, "vault.e2e_recovery_set")
        return Response({"ok": True})

    def delete(self, request):
        from .models import VaultKeyWrap
        VaultKeyWrap.objects.filter(user=request.user, kind="recovery").delete()
        _log(request.user, "vault.e2e_recovery_delete")
        return Response({"ok": True})


class VaultHelperView(APIView):
    def post(self, request):
        from . import e2_keys
        from .models import CircleMember, VaultKeyWrap
        d = request.data or {}
        if not enabled(request.user):
            return _fail("off", request, status.HTTP_403_FORBIDDEN)
        if _has_forbidden(d):
            return _fail("never_send", request)
        blob = d.get("blob")
        if not valid_wrap(blob) or json.loads(_b64(blob)).get("alg") != "x25519-c20p":
            return _fail("not_sealed", request)
        try:
            mid = int(d.get("member_id"))
        except (TypeError, ValueError):
            return _fail("not_in_circle", request, status.HTTP_404_NOT_FOUND)
        edge = CircleMember.objects.filter(user=request.user, pk=mid).first()
        peer = e2_keys.edge_peer(edge) if edge is not None else None
        if peer is None or peer.id == request.user.id:
            return _fail("not_in_circle", request, status.HTTP_404_NOT_FOUND)
        if e2_keys.key_row(peer) is None:
            return _fail("no_key", request, status.HTTP_409_CONFLICT)
        qs = VaultKeyWrap.objects.filter(user=request.user, kind="helper")
        existing = qs.filter(helper=peer).first()
        if existing is None and qs.count() >= MAX_HELPERS:
            return _fail("too_many", request)
        if existing is not None:
            existing.blob = blob
            existing.helper_key_id = str(d.get("key_id") or "")[:64]
            existing.save(update_fields=["blob", "helper_key_id", "updated_at"])
            w = existing
        else:
            w = VaultKeyWrap.objects.create(user=request.user, kind="helper", helper=peer,
                                            blob=blob, helper_key_id=str(d.get("key_id") or "")[:64])
        _log(request.user, "vault.e2e_helper_set", helper=peer.id)
        n = _name(request.user)
        _push(peer, f"{n} আপনাকে ভল্টের বিশ্বস্ত মানুষ বানিয়েছেন",
              f"{n} made you a trusted person for their vault",
              "আপনি তাঁর কাগজ দেখতে পারবেন না — শুধু দরকারে তালা খুলতে সাহায্য করবেন।",
              "You can't see their documents — you can only help them unlock if needed.",
              "vault_helper_added")
        return Response({"ok": True, "helper": _wrap_row(w)}, status=status.HTTP_201_CREATED)


class VaultHelperDeleteView(APIView):
    def delete(self, request, pk):
        from .models import VaultKeyWrap
        n, _ = VaultKeyWrap.objects.filter(user=request.user, kind="helper", pk=pk).delete()
        if not n:
            return _fail("not_found", request, status.HTTP_404_NOT_FOUND)
        _log(request.user, "vault.e2e_helper_delete", wrap=pk)
        return Response({"ok": True})


# ------------------------------------------------------------ trusted-person recovery
def _req_row(r, for_owner):
    now = timezone.now()
    out = {"id": r.id, "state": r.state, "created_at": r.created_at.isoformat(),
           "ready_at": r.ready_at.isoformat() if r.ready_at else None,
           "requester_key_id": r.requester_key_id}
    if for_owner:
        out["helper_name"] = _name(r.helper)
        ready = r.state in ("approved", "done") and r.ready_at and r.ready_at <= now
        out["ready"] = bool(ready)
        if ready:
            out["handback"] = r.handback
    else:
        out["owner_name"] = _name(r.owner)
        out["wrap"] = r.wrap.blob
        out["requester_pub"] = r.requester_pub
    return out


class VaultHelpRequestView(APIView):
    def get(self, request):
        from .models import VaultHelpRequest
        r = VaultHelpRequest.objects.filter(owner=request.user).select_related("helper").first()
        if r is None:
            return Response({"ok": True, "request": None})
        row = _req_row(r, True)
        if row.get("ready") and r.state == "approved":
            r.state = "done"
            r.save(update_fields=["state"])
            _log(request.user, "vault.e2e_help_released", req=r.id)
        return Response({"ok": True, "request": row})

    def post(self, request):
        from .models import VaultHelpRequest, VaultKeyWrap
        d = request.data or {}
        if not enabled(request.user):
            return _fail("off", request, status.HTTP_403_FORBIDDEN)
        if _has_forbidden(d):
            return _fail("never_send", request)
        pub = _b64(str(d.get("public_key") or ""))
        if pub is None or len(pub) != 32:
            return _fail("not_found", request)
        w = VaultKeyWrap.objects.filter(user=request.user, kind="helper",
                                        pk=d.get("wrap_id") or 0).select_related("helper").first()
        if w is None:
            return _fail("not_found", request, status.HTTP_404_NOT_FOUND)
        day_ago = timezone.now() - timedelta(days=1)
        if VaultHelpRequest.objects.filter(owner=request.user, created_at__gte=day_ago).count() \
                >= MAX_HELP_PER_DAY:
            return _fail("rate", request, status.HTTP_429_TOO_MANY_REQUESTS)
        VaultHelpRequest.objects.filter(owner=request.user, state__in=("pending", "approved")) \
            .update(state="cancelled", decided_at=timezone.now())
        r = VaultHelpRequest.objects.create(
            owner=request.user, helper=w.helper, wrap=w,
            requester_pub=str(d.get("public_key")).strip()[:200],
            requester_key_id=str(d.get("key_id") or "")[:64])
        _log(request.user, "vault.e2e_help_request", req=r.id, helper=w.helper_id)
        n = _name(request.user)
        _push(w.helper, f"{n} ভল্ট খুলতে আপনার সাহায্য চান",
              f"{n} asks for your help to unlock their vault",
              "অনুমোদনের আগে তাঁকে ফোন করে মিল-কোড মিলিয়ে নিন।",
              "Call them and match the code before you approve.", "vault_help_request")
        _push(request.user, "ভল্ট উদ্ধারের অনুরোধ পাঠানো হয়েছে",
              "A vault recovery was requested",
              "আপনি না করে থাকলে এখনই বাতিল করুন ও পাসওয়ার্ড বদলান।",
              "If this wasn't you, cancel it now and change your password.",
              "vault_help_requested")
        return Response({"ok": True, "request": _req_row(r, True)}, status=status.HTTP_201_CREATED)


class VaultHelpCancelView(APIView):
    def post(self, request):
        from .models import VaultHelpRequest
        n = VaultHelpRequest.objects.filter(owner=request.user, state__in=("pending", "approved")) \
            .update(state="cancelled", decided_at=timezone.now(), handback="")
        _log(request.user, "vault.e2e_help_cancel", n=n)
        return Response({"ok": True, "cancelled": n})


class VaultHelpInboxView(APIView):
    def get(self, request):
        from .models import VaultHelpRequest
        rows = VaultHelpRequest.objects.filter(helper=request.user, state="pending") \
            .select_related("owner", "wrap")[:10]
        return Response({"ok": True, "results": [_req_row(r, False) for r in rows]})


class VaultHelpDecideView(APIView):
    def post(self, request, pk, action):
        from .models import VaultHelpRequest
        r = VaultHelpRequest.objects.filter(helper=request.user, pk=pk).select_related("owner").first()
        if r is None:
            return _fail("not_found", request, status.HTTP_404_NOT_FOUND)
        if r.state != "pending":
            return _fail("not_pending", request, status.HTTP_409_CONFLICT)
        now = timezone.now()
        if action == "decline":
            r.state, r.decided_at = "declined", now
            r.save(update_fields=["state", "decided_at"])
            _log(r.owner, "vault.e2e_help_declined", req=r.id)
            return Response({"ok": True, "state": r.state})
        d = request.data or {}
        if _has_forbidden(d):
            return _fail("never_send", request)
        blob = d.get("blob")
        if not valid_wrap(blob) or json.loads(_b64(blob)).get("alg") != "x25519-c20p":
            return _fail("not_sealed", request)
        r.state, r.decided_at, r.ready_at, r.handback = "approved", now, now + HELP_WAIT, blob
        r.save(update_fields=["state", "decided_at", "ready_at", "handback"])
        _log(r.owner, "vault.e2e_help_approved", req=r.id, helper=request.user.id)
        _push(r.owner, "বিশ্বস্ত মানুষ অনুমোদন দিয়েছেন — ২৪ ঘণ্টা পরে ভল্ট খুলবে",
              "Your trusted person approved — the vault opens in 24 hours",
              "আপনি না চেয়ে থাকলে এখনই বাতিল করুন।",
              "If you didn't ask for this, cancel it now.", "vault_help_approved")
        return Response({"ok": True, "state": r.state, "ready_at": r.ready_at.isoformat()})


# ------------------------------------------------------------ share links
def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def link_state(s, now=None):
    now = now or timezone.now()
    if s.revoked_at is not None:
        return "revoked"
    if s.expires_at <= now:
        return "expired"
    if s.opens >= s.max_opens:
        return "used"
    return "open"


def _drop_blob(s):
    try:
        if s.blob:
            s.blob.delete(save=False)
    except Exception:  # noqa: BLE001
        pass
    s.blob = None


def purge_shares(now=None, limit=200):
    """Delete the ciphertext of links that can never open again."""
    from django.db.models import F, Q
    from .models import VaultShareLink
    now = now or timezone.now()
    qs = VaultShareLink.objects.filter(
        Q(revoked_at__isnull=False) | Q(expires_at__lte=now) | Q(opens__gte=F("max_opens"))
    ).exclude(blob="").exclude(blob__isnull=True)[:limit]
    n = 0
    for s in qs:
        _drop_blob(s)
        s.save(update_fields=["blob"])
        n += 1
    return n


def _share_row(s):
    return {"id": s.id, "document_id": s.document_id, "state": link_state(s),
            "expires_at": s.expires_at.isoformat(), "opens": s.opens,
            "max_opens": s.max_opens, "size": s.size,
            "created_at": s.created_at.isoformat(),
            "last_opened_at": s.last_opened_at.isoformat() if s.last_opened_at else None}


class VaultShareView(APIView):
    def get(self, request):
        from .models import VaultShareLink
        qs = VaultShareLink.objects.filter(owner=request.user)
        did = request.query_params.get("document_id")
        if did:
            qs = qs.filter(document_id=did)
        return Response({"ok": True, "results": [_share_row(s) for s in qs[:50]]})

    def post(self, request):
        from .models import Document, VaultShareLink
        d = request.data or {}
        if not enabled(request.user):
            return _fail("off", request, status.HTTP_403_FORBIDDEN)
        if _has_forbidden(d):
            return _fail("never_send", request)
        doc = Document.objects.filter(user=request.user, pk=d.get("document_id") or 0).first()
        if doc is None:
            return _fail("not_found", request, status.HTTP_404_NOT_FOUND)
        try:
            hours = int(d.get("hours"))
            max_opens = int(d.get("max_opens") or 1)
        except (TypeError, ValueError):
            return _fail("bad_hours", request)
        if hours not in SHARE_HOURS or not 1 <= max_opens <= SHARE_MAX_OPENS:
            return _fail("bad_hours", request)
        f = request.FILES.get("blob")
        if f is None:
            return _fail("not_sealed", request)
        if f.size > SHARE_MAX_BYTES:
            return _fail("too_big", request, status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        head = f.read(8)
        f.seek(0)
        if not head.startswith(SHARE_MAGIC) or f.size < 4 + 12 + 16:
            return _fail("not_sealed", request)
        purge_shares(limit=50)
        now = timezone.now()
        active = [s for s in VaultShareLink.objects.filter(owner=request.user, revoked_at__isnull=True,
                                                           expires_at__gt=now)
                  if link_state(s, now) == "open"]
        if len(active) >= SHARE_MAX_ACTIVE:
            return _fail("too_many_links", request, status.HTTP_429_TOO_MANY_REQUESTS)
        token = secrets.token_urlsafe(18)
        s = VaultShareLink(owner=request.user, document=doc, token_hash=token_hash(token),
                           size=f.size, expires_at=now + timedelta(hours=hours),
                           max_opens=max_opens)
        s.blob.save("x.bin", f, save=False)
        s.save()
        _log(request.user, "vault.share_create", id=s.id, doc=doc.id, hours=hours,
             max_opens=max_opens)
        return Response({"ok": True, "token": token, "path": f"/d/{token}",
                         "link": _share_row(s)}, status=status.HTTP_201_CREATED)


class VaultShareRevokeView(APIView):
    def post(self, request, pk):
        from .models import VaultShareLink
        s = VaultShareLink.objects.filter(owner=request.user, pk=pk).first()
        if s is None:
            return _fail("not_found", request, status.HTTP_404_NOT_FOUND)
        if s.revoked_at is None:
            s.revoked_at = timezone.now()
        _drop_blob(s)
        s.save(update_fields=["revoked_at", "blob"])
        _log(request.user, "vault.share_revoke", id=s.id)
        return Response({"ok": True, "link": _share_row(s)})


def open_share(token, now=None):
    """Public read: (state, bytes|None). Counts one open when it returns the
    ciphertext; drops the ciphertext once the link can never open again."""
    from .models import VaultShareLink
    now = now or timezone.now()
    if not isinstance(token, str) or not 8 <= len(token) <= 64:
        return "bad", None
    with transaction.atomic():
        s = VaultShareLink.objects.select_for_update().filter(token_hash=token_hash(token)).first()
        if s is None:
            return "bad", None
        st = link_state(s, now)
        if st != "open" or not s.blob:
            if s.blob:
                _drop_blob(s)
                s.save(update_fields=["blob"])
            return (st if st != "open" else "expired"), None
        try:
            with s.blob.open("rb") as fh:
                data = fh.read()
        except Exception:  # noqa: BLE001
            return "expired", None
        s.opens += 1
        s.last_opened_at = now
        fields = ["opens", "last_opened_at"]
        if s.opens >= s.max_opens:
            _drop_blob(s)
            fields.append("blob")
        s.save(update_fields=fields)
    return "open", data


def peek_share(token, now=None):
    """Public page state WITHOUT counting an open (link previews are free)."""
    from .models import VaultShareLink
    if not isinstance(token, str) or not 8 <= len(token) <= 64:
        return "bad", None
    s = VaultShareLink.objects.filter(token_hash=token_hash(token)).first()
    if s is None:
        return "bad", None
    return link_state(s, now), s
