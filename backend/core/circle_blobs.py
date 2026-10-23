"""
md1 — My Circle end-to-end-encrypted media blobs (photo / voice / document).

WHAT THE SERVER HOLDS: ciphertext only. The phone encrypts each file with a
random 32-byte key (ChaCha20-Poly1305, 64 KiB chunks) BEFORE upload; the key,
nonce, sha256, name, mime and a tiny thumbnail travel inside the normal
per-recipient E2E message envelope, which the server cannot read. This module
never sees a key, never decrypts, never transcodes.

STORAGE: a private directory OUTSIDE MEDIA_ROOT (settings.CIRCLE_BLOB_ROOT,
default <backend>/private/circle_blobs) — /media/ can never reach it. Bytes are
served only through a short-lived HMAC-signed link
(/api/v1/circle/media/dl/<ref>?e=&s=, 10 min) handed to a CHAT PARTICIPANT; in
production nginx streams the file (X-Accel-Redirect to the internal location
/protected-circle-blobs/, CIRCLE_BLOB_X_ACCEL=1), in dev/tests Django does.

UPLOAD: resumable — POST /circle/media/blobs {kind, size, sha256} -> ref; then
PUT /circle/media/blobs/<ref>?offset=N with raw chunks (<= 1 MiB); GET the
blob for the stored offset after a drop; POST .../finish verifies size + sha256.

LIMITS (owner-editable in admin pricing `limits`, see core.logic.pricing):
per-file cap by kind, per-user daily upload volume, uploads per hour.

RETENTION (purge(), run hourly by purge_l1_retention): a blob is deleted
`circle_media_keep_days` after every recipient downloaded it, at most
`circle_media_max_days` after upload, at once when its last live message is
deleted for everyone, and 24 h after an upload that never finished or was
never sent in a message.
"""
import hashlib
import hmac
import os
import secrets
import time
from datetime import timedelta

from django.conf import settings
from django.db.models import Q, Sum
from django.utils import timezone

MB = 1024 * 1024
KINDS = ("photo", "voice", "document")
# Chat media kinds that REALLY work end to end (md1). Video stays hidden: no
# reliable on-phone encoder without a heavy native dependency.
CHAT_MEDIA_KINDS = KINDS
CHUNK_MAX = 1 * MB            # one PUT body
URL_TTL_S = 600               # signed download link lifetime
STALE_UPLOAD_H = 24           # unfinished / never-sent uploads
DL_PREFIX = "/api/v1/circle/media/dl/"
ACCEL_PREFIX = "/protected-circle-blobs/"
# AEAD overhead: 16-byte tag per 64 KiB chunk (+ slack) over the plain cap.
_OVERHEAD = 64 * 1024

_DEFAULTS = {
    "circle_media_photo_max_mb": 16,
    "circle_media_voice_max_mb": 16,
    "circle_media_doc_max_mb": 25,
    "circle_media_daily_mb": 300,
    "circle_media_uploads_per_hour": 60,
    "circle_media_keep_days": 30,
    "circle_media_max_days": 90,
}


def limits():
    """The owner-editable media limits (falls back to defaults on any error)."""
    out = dict(_DEFAULTS)
    try:
        from . import billing
        lim = billing.cfg()["limits"]
        for k in out:
            if k in lim:
                out[k] = int(lim[k])
    except Exception:  # noqa: BLE001 — a config glitch never breaks a send
        pass
    return out


def max_bytes(kind, lim=None):
    """Ciphertext cap for one file of `kind` (plain cap + AEAD overhead)."""
    lim = lim or limits()
    mb = {"photo": lim["circle_media_photo_max_mb"],
          "voice": lim["circle_media_voice_max_mb"]}.get(
        kind, lim["circle_media_doc_max_mb"])
    return int(mb) * MB + _OVERHEAD


def public_limits():
    """What the phone needs to refuse a too-big file BEFORE encrypting."""
    lim = limits()
    return {
        "kinds": list(CHAT_MEDIA_KINDS),
        "photo_max_bytes": lim["circle_media_photo_max_mb"] * MB,
        "voice_max_bytes": lim["circle_media_voice_max_mb"] * MB,
        "doc_max_bytes": lim["circle_media_doc_max_mb"] * MB,
        "daily_bytes": lim["circle_media_daily_mb"] * MB,
        "chunk_bytes": 512 * 1024,
        "keep_days": lim["circle_media_keep_days"],
        "max_days": lim["circle_media_max_days"],
    }


# ---------------------------------------------------------------- storage
def root():
    r = getattr(settings, "CIRCLE_BLOB_ROOT", None) or os.path.join(
        str(settings.BASE_DIR), "private", "circle_blobs")
    return os.path.realpath(str(r))


def new_ref():
    return secrets.token_hex(16)  # 32 hex chars, unguessable


def valid_ref(ref):
    ref = str(ref or "")
    return len(ref) == 32 and all(c in "0123456789abcdef" for c in ref)


def rel_name(ref):
    return "%s/%s.bin" % (ref[:2], ref)


def path_for(ref):
    return os.path.join(root(), rel_name(ref))


def remove_file(ref):
    try:
        os.remove(path_for(ref))
    except FileNotFoundError:
        pass
    except OSError:
        pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(256 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


# ---------------------------------------------------------------- quota
def quota_check(user, kind, size, lim=None):
    """None if allowed, else a reason code: bad_kind | too_big | daily_quota |
    rate_limit."""
    from .models import CircleMediaBlob
    lim = lim or limits()
    if kind not in CHAT_MEDIA_KINDS:
        return "bad_kind"
    if size <= 0 or size > max_bytes(kind, lim):
        return "too_big"
    now = timezone.now()
    day = CircleMediaBlob.objects.filter(
        owner=user, created_at__gte=now - timedelta(hours=24))
    used = day.aggregate(s=Sum("size"))["s"] or 0
    if used + size > lim["circle_media_daily_mb"] * MB:
        return "daily_quota"
    hour = day.filter(created_at__gte=now - timedelta(hours=1)).count()
    if hour >= lim["circle_media_uploads_per_hour"]:
        return "rate_limit"
    return None


def reason_text(code, lang="bn", lim=None):
    from .logic.circle import pick
    lim = lim or limits()
    return {
        "bad_kind": pick(lang, "এই ধরনের ফাইল পাঠানো যায় না।",
                         "This kind of file can't be sent."),
        "too_big": pick(lang, "ফাইলটি অনেক বড়।", "This file is too large."),
        "daily_quota": pick(
            lang, "আজকের পাঠানোর সীমা শেষ ({} MB)। কাল আবার পাঠাতে পারবেন।".format(
                lim["circle_media_daily_mb"]),
            "Today's sending limit is used up ({} MB). You can send more "
            "tomorrow.".format(lim["circle_media_daily_mb"])),
        "rate_limit": pick(lang, "খুব দ্রুত অনেক ফাইল পাঠানো হচ্ছে। একটু পরে আবার চেষ্টা করুন।",
                           "Too many files in a short time. Try again in a little while."),
        "media_after_accept": pick(
            lang, "অনুরোধ গ্রহণ করার পরে ছবি ও ফাইল পাঠানো যাবে।",
            "Photos and files can be sent after they accept your request."),
        "blob_missing": pick(lang, "ফাইলটি পাওয়া যায়নি। আবার পাঠান।",
                             "The file wasn't found. Please send it again."),
    }.get(code, code)


# ---------------------------------------------------------------- signing
def _key():
    return hashlib.sha256(b"assisto-circle-blob:" +
                          settings.SECRET_KEY.encode()).digest()


def _sig(ref, uid, exp):
    msg = ("%s|%d|%d" % (ref, int(uid), int(exp))).encode()
    return hmac.new(_key(), msg, hashlib.sha256).hexdigest()[:40]


def signed_url(ref, uid, now=None):
    now = int(now if now is not None else time.time())
    exp = now + URL_TTL_S
    return "%s%s?u=%d&e=%d&s=%s" % (DL_PREFIX, ref, int(uid), exp,
                                    _sig(ref, uid, exp))


def verify(ref, uid, exp, sig, now=None):
    try:
        exp = int(exp)
        uid = int(uid)
    except (TypeError, ValueError):
        return False
    if exp < int(now if now is not None else time.time()):
        return False
    if exp > int(now if now is not None else time.time()) + URL_TTL_S + 5:
        return False
    return hmac.compare_digest(_sig(ref, uid, exp), str(sig or ""))


# ---------------------------------------------------------------- access
def _live_messages(ref):
    from .models import CircleMessage
    return CircleMessage.objects.filter(blob_ref=ref).exclude(deleted="everyone")


def can_access(user, ref):
    """True when `user` sent, or is a participant of a chat holding, a live
    message that references this blob (1:1 both sides; group ACTIVE members).

    md2: a forward is a NEW message (1:1 or group) carrying the SAME
    blob_ref, so the blob <-> message link is every live message with that
    ref: members of every chat it was forwarded into can open it, and losing
    one chat (left the group, that copy deleted for everyone) never affects
    the others."""
    from .models import CircleGroupMember
    uid = user.id
    for x in _live_messages(ref).select_related("member"):
        if uid in (x.hidden_for or []):
            continue
        if x.sender_id == uid:
            return True
        if x.group_id:
            if CircleGroupMember.objects.filter(
                    group_id=x.group_id, member_id=uid,
                    status="active").exists():
                return True
        elif x.member is not None and uid in (x.member.user_id,
                                              x.member.peer_user_id):
            return True
    # p3: a photo STORY's blob — its author, or a viewer the active story is
    # visible to (same server-side audience check as the story itself).
    try:
        from .views_p3_circle import active_story_viewer
        if active_story_viewer(user, ref):
            return True
    except Exception:  # noqa: BLE001 — never widen access on an error
        pass
    return False


def attach_check(user, ref, kind):
    """Before a media message is stored: the blob must exist, be complete and
    be the sender's own upload or one they can already open (forward)."""
    from .models import CircleMediaBlob
    if not valid_ref(ref):
        return None, "blob_missing"
    b = CircleMediaBlob.objects.filter(ref=ref, complete=True).first()
    if b is None:
        return None, "blob_missing"
    if b.owner_id != user.id and not can_access(user, ref):
        return None, "blob_missing"
    return b, None


def add_recipients(blob, user_ids):
    """Union of everyone who must download this blob, across EVERY chat it
    was sent or forwarded into (md2: 1:1 + groups). The uploader never
    downloads their own file, so a forward back to them never counts them —
    otherwise "all downloaded" could never be reached and the keep_days rule
    would silently become max_days."""
    ids = sorted((set(int(i) for i in (blob.recipients or [])) |
                  set(int(i) for i in user_ids if i)) - {blob.owner_id})
    if ids != (blob.recipients or []):
        blob.recipients = ids
        _refresh_all_downloaded(blob)
        blob.save(update_fields=["recipients", "all_downloaded_at"])


def _refresh_all_downloaded(blob):
    rec = set(blob.recipients or [])
    got = set(blob.downloaded_by or [])
    if rec and rec <= got:
        if blob.all_downloaded_at is None:
            blob.all_downloaded_at = timezone.now()
    else:
        blob.all_downloaded_at = None


def mark_downloaded(blob, uid):
    if uid == blob.owner_id:
        return
    got = set(blob.downloaded_by or [])
    if uid in got:
        return
    got.add(uid)
    blob.downloaded_by = sorted(got)
    _refresh_all_downloaded(blob)
    blob.save(update_fields=["downloaded_by", "all_downloaded_at"])


def release(ref):
    """Delete-for-everyone: drop the blob when no live message references it
    (a forward elsewhere keeps its own copy alive, like WhatsApp)."""
    from .models import CircleMediaBlob
    if not ref or _live_messages(ref).exists():
        return False
    from .models import CircleStatus
    if CircleStatus.objects.filter(blob_ref=ref).exists():
        return False   # p3: an active story still shows it
    n = 0
    for b in CircleMediaBlob.objects.filter(ref=ref):
        b.delete()   # post_delete removes the file
        n += 1
    return n > 0


# ---------------------------------------------------------------- retention
def purge(now=None, dry=False):
    """Retention sweep. Returns {reason: count}."""
    from .models import CircleMediaBlob, CircleMessage
    now = now or timezone.now()
    lim = limits()
    keep = timedelta(days=lim["circle_media_keep_days"])
    maxd = timedelta(days=lim["circle_media_max_days"])
    stale = now - timedelta(hours=STALE_UPLOAD_H)
    out = {"downloaded": 0, "max_age": 0, "unfinished": 0, "unsent": 0,
           "deleted_msgs": 0}
    qs = CircleMediaBlob.objects.all()
    hits = []
    for b in qs.filter(all_downloaded_at__isnull=False,
                       all_downloaded_at__lt=now - keep):
        hits.append((b, "downloaded"))
    for b in qs.filter(created_at__lt=now - maxd):
        hits.append((b, "max_age"))
    for b in qs.filter(complete=False, created_at__lt=stale):
        hits.append((b, "unfinished"))
    from .models import CircleStatus
    for b in qs.filter(complete=True, created_at__lt=stale):
        refs = CircleMessage.objects.filter(blob_ref=b.ref)
        # p3: a photo story still live (or awaiting the expiry sweep) keeps it
        if CircleStatus.objects.filter(blob_ref=b.ref).exists():
            continue
        if not refs.exists():
            hits.append((b, "unsent"))
        elif not refs.filter(~Q(deleted="everyone")).exists():
            hits.append((b, "deleted_msgs"))
    seen = set()
    for b, why in hits:
        if b.pk in seen:
            continue
        seen.add(b.pk)
        out[why] += 1
        if not dry:
            b.delete()
    return out


def _on_blob_delete(sender, instance, **kw):
    remove_file(instance.ref)


def connect():
    from django.db.models.signals import post_delete
    from .models import CircleMediaBlob
    post_delete.connect(_on_blob_delete, sender=CircleMediaBlob,
                        dispatch_uid="md1_blob_file")
