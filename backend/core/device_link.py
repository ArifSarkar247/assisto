"""circle-extras (board row 50) — LINK A SECOND PHONE BY QR, WhatsApp style.

Before this, "Linked devices" showed an empty token (the server sent
`qr_payload`, the screen read `token`), no phone could scan anything, the
confirm API wanted the new phone to be signed in to the SAME account already,
and "Log out" only flipped a flag (the phone stayed signed in). A second
phone that signed in with OTP made a NEW E2E key that replaced the first
phone's key, so friends' messages stopped opening on one of the two phones.

The flow now (no migration: the short-lived pairing state is one
PaCollectionItem row, collection "devlink", on the PRIMARY's account):

  1. PRIMARY (signed in)   POST e2/link/start
        -> {token, code "ABCD-EFGH", qr "assisto-link:1:<token>", expires_at}
        The QR and the 8-character code are two spellings of one single-use,
        2-minute pairing secret (only sha256 of each is stored).
  2. NEW PHONE (no login)  POST e2/link/claim {code|token, eph_pub, name}
        -> {pair, poll, verify, expires_at}
        eph_pub = a ONE-TIME X25519 public key made on the new phone. A code
        can be claimed once. `poll` is a secret only the new phone knows
        (sha256 stored), so someone who saw the QR cannot pick up the session.
        `verify` (6 digits, from eph_pub) is shown on the new phone.
  3. PRIMARY               GET  e2/link/status?pair=  -> {state, name, verify}
        The primary shows "Link <name>? Code 123 456" — the same 6 digits
        must be on the new phone (a stranger who raced the claim with their
        own key would show different digits).
                           POST e2/link/approve {pair, sealed:{epk,nonce,ct}}
        sealed = the primary's WHOLE E2E key ring, encrypted ON THE PRIMARY
        to eph_pub (X25519 + ChaCha20-Poly1305). The server relays bytes it
        cannot open. Or {pair, reject:true}.
  4. NEW PHONE             POST e2/link/poll {pair, poll}
        -> waiting | rejected | expired | approved {token, user, sealed}
        On approve the new phone's OWN sign-in session (a DeviceSession,
        exactly like a password sign-in) is created at this moment, so the
        raw session key is never stored; the pairing row is deleted.

Both phones then hold the same key ring: every 1:1 / group message (sealed to
the account's key) opens on both, and the same key id is re-published, so
friends see no "security code changed".

UNLINK = revoke_device(): the LinkedDevice row AND every live sign-in session
of that phone (its next request gets 401 -> the app goes to sign-in and, as a
linked phone, wipes its copy of the keys). Signing a phone out from Account &
security marks its LinkedDevice row revoked too (one truth).

Honest limit (owner card): unlinking does not rotate the primary's key — a
copy of the old server database plus the stolen phone's key file would still
open old ciphertext. A "change my key" button is a P2 decision.
"""
import base64
import hashlib
import secrets
import time
from datetime import datetime, timedelta, timezone as dt_tz

from django.utils import timezone

COLLECTION = "devlink"
TTL_SEC = 120            # QR / code life
APPROVE_TTL_SEC = 300    # after a claim: time for the owner to approve + pickup
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ"   # letters only (no I/O): no digit-script
# mix-ups in Bangla; 24^8 = 1.1e11 codes for a 2-minute single-use secret
CODE_LEN = 8
QR_PREFIX = "assisto-link:1:"
CLAIMS_PER_IP_PER_10MIN = 20


def _sha(s):
    return hashlib.sha256(str(s).encode()).hexdigest()


def norm_code(raw):
    """'abcd efgh' / 'ABCD-EFGH' / the whole QR text -> the bare secret."""
    s = str(raw or "").strip()
    if s.startswith(QR_PREFIX):
        return s[len(QR_PREFIX):].strip()
    up = "".join(ch for ch in s.upper() if ch.isalnum())
    if len(up) == CODE_LEN and all(ch in CODE_ALPHABET for ch in up):
        return up
    return s


def pretty_code(code):
    return code[:4] + "-" + code[4:]


def verify_digits(eph_pub_b64):
    """6 digits both screens show (from the new phone's one-time key)."""
    h = hashlib.sha256(("assisto-link-verify:" + str(eph_pub_b64)).encode()).digest()
    return "%06d" % (int.from_bytes(h[:6], "big") % 1000000)


def _valid_pub(b64):
    try:
        return len(base64.b64decode(str(b64), validate=True)) == 32
    except Exception:  # noqa: BLE001
        return False


def _now():
    return time.time()


def _rows():
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(collection=COLLECTION)


def _cleanup():
    """Drop pairing rows older than an hour (cheap, bounded)."""
    try:
        old = timezone.now() - timedelta(hours=1)
        ids = list(_rows().filter(created_at__lt=old).values_list("id", flat=True)[:200])
        if ids:
            _rows().filter(id__in=ids).delete()
    except Exception:  # noqa: BLE001
        pass


# --------------------------------------------------------------- 1. start
def start(user):
    """A fresh pairing secret for `user` (any older unfinished one is gone)."""
    from .models import PaCollectionItem
    _cleanup()
    _rows().filter(user=user).delete()
    token = secrets.token_urlsafe(24)
    code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))
    exp = _now() + TTL_SEC
    PaCollectionItem.objects.create(user=user, collection=COLLECTION, data={
        "tok": _sha(token), "code": _sha(code), "exp": exp, "state": "waiting"})
    return {"token": token, "code": pretty_code(code), "qr": QR_PREFIX + token,
            "ttl_sec": TTL_SEC,
            "expires_at": datetime.fromtimestamp(exp, tz=dt_tz.utc).isoformat()}


def _find_secret(secret):
    h = _sha(secret)
    row = _rows().filter(data__tok=h).first()
    if row is None:
        row = _rows().filter(data__code=h).first()
    return row


# --------------------------------------------------------------- 2. claim
def claim(raw_code, eph_pub, name="", platform="android", device_id=""):
    """(result, error). error in unknown | expired | used | bad_key."""
    if not _valid_pub(eph_pub):
        return None, "bad_key"
    secret = norm_code(raw_code)
    if not secret:
        return None, "unknown"
    row = _find_secret(secret)
    if row is None:
        return None, "unknown"
    d = dict(row.data or {})
    if d.get("state") != "waiting":
        return None, "used"
    if _now() > float(d.get("exp") or 0):
        return None, "expired"
    poll = secrets.token_urlsafe(24)
    d.update(state="claimed", eph=str(eph_pub), name=str(name or "")[:80],
             platform=(str(platform or "android")[:10] or "android"),
             dev=str(device_id or "")[:64], poll=_sha(poll),
             exp=_now() + APPROVE_TTL_SEC)
    row.data = d
    row.save(update_fields=["data", "updated_at"])
    return {"pair": row.id, "poll": poll, "verify": verify_digits(eph_pub),
            "expires_in": APPROVE_TTL_SEC}, None


# -------------------------------------------------------------- 3. status
def _mine(user, pair):
    try:
        return _rows().filter(user=user, id=int(pair)).first()
    except (TypeError, ValueError):
        return None


def status(user, pair):
    row = _mine(user, pair)
    if row is None:
        return {"state": "gone"}
    d = row.data or {}
    st = d.get("state", "waiting")
    if st in ("waiting", "claimed") and _now() > float(d.get("exp") or 0):
        st = "expired"
    out = {"state": st}
    if st in ("claimed", "approved"):
        # eph_pub: the main phone seals its key ring to it and computes the
        # 6 digits itself (it never has to trust `verify` from us)
        out.update(name=d.get("name", ""), platform=d.get("platform", "android"),
                   verify=verify_digits(d.get("eph", "")), eph_pub=d.get("eph", ""))
    return out


def status_latest(user):
    """The newest pairing row of `user` (the QR sheet polls without a pair id)."""
    row = _rows().filter(user=user).order_by("-id").first()
    if row is None:
        return {"state": "gone"}
    out = status(user, row.id)
    out["pair"] = row.id
    return out


def _valid_sealed(s):
    if not isinstance(s, dict):
        return False
    try:
        for k in ("epk", "nonce", "ct"):
            base64.b64decode(str(s.get(k, "")), validate=True)
        return _valid_pub(s.get("epk")) and 0 < len(str(s.get("ct"))) <= 400_000
    except Exception:  # noqa: BLE001
        return False


def approve(user, pair, sealed=None, reject=False):
    """(ok, error). error in gone | expired | not_claimed | bad_sealed."""
    row = _mine(user, pair)
    if row is None:
        return False, "gone"
    d = dict(row.data or {})
    if d.get("state") != "claimed":
        return False, "not_claimed"
    if _now() > float(d.get("exp") or 0):
        return False, "expired"
    if reject:
        d.update(state="rejected")
    else:
        if not _valid_sealed(sealed):
            return False, "bad_sealed"
        d.update(state="approved", sealed={k: str(sealed[k]) for k in ("epk", "nonce", "ct")})
    row.data = d
    row.save(update_fields=["data", "updated_at"])
    return True, None


# ---------------------------------------------------------------- 4. poll
def poll(pair, poll_secret, request=None):
    """(answer, http_status). Approved -> the new phone's own session."""
    from .models import PaCollectionItem
    try:
        row = PaCollectionItem.objects.filter(collection=COLLECTION, id=int(pair)).first()
    except (TypeError, ValueError):
        row = None
    if row is None:
        return {"state": "gone"}, 404
    d = row.data or {}
    if not poll_secret or not secrets.compare_digest(_sha(poll_secret), str(d.get("poll", ""))):
        return {"state": "gone"}, 404
    st = d.get("state")
    if st == "rejected":
        row.delete()
        return {"state": "rejected"}, 200
    if st == "claimed":
        if _now() > float(d.get("exp") or 0):
            row.delete()
            return {"state": "expired"}, 410
        return {"state": "waiting"}, 200
    if st != "approved":
        return {"state": "gone"}, 404
    user = row.user
    from .account_block import is_blocked
    if is_blocked(user):
        row.delete()
        return {"state": "rejected"}, 200
    from . import device_sessions as DS
    raw, sess = DS.create(user, request, reason="linked")
    dev_id = d.get("dev") or sess.device_id or ("link-%d" % row.id)
    if not sess.device_id:
        type(sess).objects.filter(pk=sess.pk).update(device_id=dev_id[:64])
    name = d.get("name") or sess.device_name or ""
    if name and not sess.device_name:
        type(sess).objects.filter(pk=sess.pk).update(device_name=name[:80])
    from .models import LinkedDevice
    LinkedDevice.objects.update_or_create(device_id=dev_id[:128], defaults={
        "user": user, "platform": d.get("platform") or "android", "role": "linked",
        "name": name[:120], "public_key_id": "", "revoked": False,
        "last_active": timezone.now()})
    sealed = d.get("sealed") or {}
    row.delete()
    from .serializers import UserSerializer
    return {"state": "approved", "token": raw, "user": UserSerializer(user).data,
            "sealed": sealed, "device_id": dev_id}, 200


# -------------------------------------------------------------- unlink
def revoke_device(user, device_id):
    """Unlink one phone: its registry row AND its live sign-in sessions.
    Returns the number of sessions signed out, or None when unknown."""
    from .models import DeviceSession, LinkedDevice
    dev = LinkedDevice.objects.filter(user=user, device_id=str(device_id)).first()
    if dev is None:
        return None
    if not dev.revoked:
        dev.revoked = True
        dev.save(update_fields=["revoked"])
    return DeviceSession.objects.filter(
        user=user, device_id=str(device_id)[:64], revoked_at__isnull=True).update(
        revoked_at=timezone.now(), revoke_reason="unlinked")


def on_session_revoked(session):
    """Account & security signed a phone out -> its linked row goes too."""
    try:
        from .models import LinkedDevice
        if session is not None and session.device_id:
            LinkedDevice.objects.filter(user_id=session.user_id,
                                        device_id=session.device_id,
                                        revoked=False).update(revoked=True)
    except Exception:  # noqa: BLE001
        pass


def listing(user, current_device_id="", lang="bn"):
    """Linked phones, each with last use from its live session. A phone
    whose sessions were all signed out elsewhere is shown as gone."""
    from .models import DeviceSession, LinkedDevice
    from .logic import msg_messenger_ui as mui
    out = []
    for r in LinkedDevice.objects.filter(user=user, revoked=False):
        sess = list(DeviceSession.objects.filter(user=user, device_id=r.device_id[:64])
                    .order_by("-last_seen_at")[:5])
        live = [s for s in sess if s.revoked_at is None]
        if sess and not live:
            LinkedDevice.objects.filter(pk=r.pk).update(revoked=True)
            continue
        last = live[0].last_seen_at if live else r.last_active
        row = mui.linked_device_view({
            "device_id": r.device_id, "name": r.name, "platform": r.platform,
            "role": r.role, "linked_at": r.linked_at.isoformat(),
            "last_active": last.isoformat() if last else None,
            "revoked": False}, lang=lang)
        row["linked_at"] = r.linked_at.isoformat()
        row["current"] = bool(current_device_id) and r.device_id == current_device_id
        out.append(row)
    return out


def claim_rate_ok(request):
    """At most CLAIMS_PER_IP_PER_10MIN claims per IP (8 random letters
    from 24 = 1.1e11 codes; this only stops noise)."""
    try:
        from django.core.cache import cache
        from .otp import client_ip
        k = "devlink:%s:%d" % (client_ip(request) or "-", int(_now() // 600))
        cache.add(k, 0, 660)
        try:
            n = cache.incr(k)
        except ValueError:
            n = 1
        return n <= CLAIMS_PER_IP_PER_10MIN
    except Exception:  # noqa: BLE001
        return True
