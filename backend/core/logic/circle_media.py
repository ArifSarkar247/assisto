"""
circle_media.py — Assisto "Connected Circle" media semantics (M1 item 4).
Pure Python, deterministic, unit-testable.  NO AI key.

Scope: the SERVER-SIDE rules for encrypted media in 1:1 chats — blob metadata,
size limits, standard-vs-HD tiers, compression targets, auto-cleanup of
undelivered blobs, a disk floor so media never fills the device/server, plus
the metadata shapes for voice notes, short videos, documents, contact cards and
current/live location.  Benchmarked against WhatsApp + Messenger.

PRIVACY CONTRACT (inherited): every media file is ENCRYPTED ON-DEVICE before
upload.  The server stores an opaque encrypted blob + a ciphertext metadata
envelope (filename/caption/thumbnail are ciphertext, see validate — never
plaintext).  The server NEVER decrypts, transcodes, or inspects a blob; the
compression/thumbnail targets here are HINTS the SENDER device applies BEFORE
encryption.  Blob storage itself is KEY-GATED (owner must provision the
encrypted object bucket) — media_available() in circle.py returns False until
then; this module defines everything so the switch is a config flip.

Run self-tests (no DB):
    python3 -c "import core.logic.circle_media_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core.logic.circle import FORBIDDEN_META_KEYS, media_available, pick


# ---------------------------------------------------------------------------
# Media kinds + size limits
# ---------------------------------------------------------------------------
# Limits are pre-encryption byte caps the SENDER enforces (ciphertext is a touch
# larger; the server enforces a slightly higher hard cap to allow AEAD overhead).

MB = 1024 * 1024

MEDIA_KINDS = ("photo", "video", "voice", "document", "contact", "location")

# Per-kind sender-side size caps (bytes).  HD photo/video get a larger cap.
SIZE_LIMITS = {
    "photo": 16 * MB,
    "photo_hd": 32 * MB,
    "video": 64 * MB,
    "video_hd": 128 * MB,
    "voice": 16 * MB,
    "document": 100 * MB,
    "contact": 1 * MB,
    "location": 64 * 1024,  # a location fix is tiny
}

# Server hard cap allows AEAD + envelope overhead over the sender cap.
_SERVER_OVERHEAD = 64 * 1024


def size_limit(kind, hd=False):
    key = f"{kind}_hd" if hd and f"{kind}_hd" in SIZE_LIMITS else kind
    return SIZE_LIMITS.get(key, SIZE_LIMITS.get(kind, 16 * MB))


def within_size_limit(kind, nbytes, hd=False):
    """Sender-side check: is this file within the pre-encryption cap?"""
    return 0 <= int(nbytes) <= size_limit(kind, hd=hd)


def server_hard_cap(kind, hd=False):
    """Server-side ciphertext cap (sender cap + AEAD/envelope overhead)."""
    return size_limit(kind, hd=hd) + _SERVER_OVERHEAD


def size_reject_reason(kind, nbytes, hd=False, lang="bn"):
    """None if OK; else a localized 'too large' message with the limit in MB."""
    if within_size_limit(kind, nbytes, hd=hd):
        return None
    limit_mb = size_limit(kind, hd=hd) // MB
    return pick(lang,
                f"ফাইলটি অনেক বড়। সর্বোচ্চ {limit_mb} MB।",
                f"File is too large. Maximum {limit_mb} MB.")


# ---------------------------------------------------------------------------
# Quality tiers + compression targets (applied on-device BEFORE encryption)
# ---------------------------------------------------------------------------
# "Standard" compresses aggressively (fast, small — the WhatsApp default).
# "HD" keeps more detail (Messenger/WhatsApp HD toggle).  These are HINTS the
# sender's codec applies; the server never transcodes an encrypted blob.

QUALITY_STANDARD = "standard"
QUALITY_HD = "hd"


def compression_target(kind, quality=QUALITY_STANDARD):
    """Return the client compression target for a kind+quality.  Dimensions in
    px long-edge; bitrate in kbps for a/v; jpeg quality 0-100 for stills."""
    hd = quality == QUALITY_HD
    if kind == "photo":
        return {"max_long_edge_px": 2048 if hd else 1600,
                "jpeg_quality": 90 if hd else 75}
    if kind == "video":
        return {"max_long_edge_px": 1280 if hd else 848,
                "video_kbps": 3500 if hd else 1200,
                "audio_kbps": 128 if hd else 96,
                "fps": 30 if hd else 30}
    if kind == "voice":
        return {"audio_kbps": 64, "codec_hint": "opus", "mono": True}
    return {}  # documents/contacts/location are not transcoded


def thumbnail_target(kind):
    """On-device thumbnail spec (encrypted too).  Server stores it as an opaque
    inline ciphertext so the chat list can show a blurred/placeholder preview
    AFTER the client decrypts it."""
    if kind in ("photo", "video"):
        return {"max_long_edge_px": 320, "jpeg_quality": 60, "encrypt": True}
    return None


# ---------------------------------------------------------------------------
# Blob metadata envelope — ciphertext-only
# ---------------------------------------------------------------------------
# A media message's envelope (content_type ∈ photo|video|voice) carries a
# blob_ref (opaque storage handle) + encrypted metadata.  Readable fields
# (filename, caption, transcript, address text) are FORBIDDEN here — they ride
# as ciphertext just like the file.

BLOB_ALLOWED_META = {
    "blob_ref", "byte_size", "kind", "quality", "duration_sec",
    "width", "height", "mime_hint", "thumb_ciphertext", "thumb_nonce",
    "caption_ciphertext", "caption_nonce", "sha256_ct",
    "pages",  # documents
}
BLOB_FORBIDDEN_META = FORBIDDEN_META_KEYS | {
    "filename", "caption", "transcript", "address", "url", "note",
}


def validate_blob_meta(meta):
    """Return (ok, reason).  A media blob's metadata must be relay-safe: an
    opaque blob_ref, size within the server hard cap, and NO readable
    filename/caption/transcript/address (those are ciphertext fields)."""
    if not isinstance(meta, dict):
        return False, "meta must be an object"
    kind = meta.get("kind")
    if kind not in MEDIA_KINDS:
        return False, "unknown media kind"
    bad = BLOB_FORBIDDEN_META & set(meta.keys())
    if bad:
        return False, "forbidden plaintext field(s): " + ",".join(sorted(bad))
    extra = set(meta.keys()) - BLOB_ALLOWED_META
    if extra:
        return False, "disallowed meta key(s): " + ",".join(sorted(extra))
    if kind in ("photo", "video", "voice", "document"):
        if not meta.get("blob_ref"):
            return False, "missing blob_ref"
        nbytes = meta.get("byte_size")
        if nbytes is not None:
            hd = meta.get("quality") == QUALITY_HD
            if int(nbytes) > server_hard_cap(kind, hd=hd):
                return False, "blob exceeds server hard cap"
    return True, "ok"


def build_blob_meta(kind, blob_ref, byte_size, quality=QUALITY_STANDARD,
                    duration_sec=None, width=None, height=None, mime_hint=None,
                    thumb_ciphertext=None, thumb_nonce=None,
                    caption_ciphertext=None, caption_nonce=None,
                    sha256_ct=None, pages=None):
    """Assemble a validated, relay-safe media metadata dict.  Raises on
    non-opaque input (e.g. a plaintext caption slipped into the wrong field)."""
    meta = {"kind": kind, "blob_ref": blob_ref, "byte_size": int(byte_size),
            "quality": quality}
    for k, v in (("duration_sec", duration_sec), ("width", width),
                 ("height", height), ("mime_hint", mime_hint),
                 ("thumb_ciphertext", thumb_ciphertext),
                 ("thumb_nonce", thumb_nonce),
                 ("caption_ciphertext", caption_ciphertext),
                 ("caption_nonce", caption_nonce),
                 ("sha256_ct", sha256_ct), ("pages", pages)):
        if v is not None:
            meta[k] = v
    ok, reason = validate_blob_meta(meta)
    if not ok:
        raise ValueError("refusing non-opaque blob meta: " + reason)
    return meta


# ---------------------------------------------------------------------------
# Documents (PDF / Office)
# ---------------------------------------------------------------------------

DOC_EXTENSIONS = {
    "pdf": "application/pdf",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "txt": "text/plain",
    "csv": "text/csv",
}


def document_mime_hint(ext):
    """A MIME HINT (used only to pick an icon on the recipient).  The filename
    itself is ciphertext; only the extension's generic type is a routing hint."""
    return DOC_EXTENSIONS.get((ext or "").lower().lstrip("."), "application/octet-stream")


def is_supported_document(ext):
    return (ext or "").lower().lstrip(".") in DOC_EXTENSIONS


# ---------------------------------------------------------------------------
# Voice notes
# ---------------------------------------------------------------------------

VOICE_MAX_SEC = 15 * 60  # 15 minutes, like WhatsApp
PLAYBACK_SPEEDS = (1.0, 1.5, 2.0)  # WhatsApp speeds


def voice_within_limit(duration_sec):
    return 0 < (duration_sec or 0) <= VOICE_MAX_SEC


def next_playback_speed(current):
    """Cycle 1x → 1.5x → 2x → 1x (the WhatsApp tap behaviour)."""
    speeds = PLAYBACK_SPEEDS
    try:
        i = speeds.index(current)
    except ValueError:
        return speeds[0]
    return speeds[(i + 1) % len(speeds)]


# ---------------------------------------------------------------------------
# Short videos
# ---------------------------------------------------------------------------

SHORT_VIDEO_MAX_SEC = 5 * 60  # keep "short" sane; longer rides as a document-ish large video


def video_within_limit(duration_sec):
    return 0 < (duration_sec or 0) <= SHORT_VIDEO_MAX_SEC


# ---------------------------------------------------------------------------
# Contact cards
# ---------------------------------------------------------------------------
# A shared contact card is itself ciphertext (name/phone encrypted).  Only a
# count hint may be routing metadata.  We expose a builder that returns the
# CIPHERTEXT fields the client must fill (so the server never sees the contact).

def contact_card_meta(encrypted_vcard_ciphertext, nonce, scheme, sender_key_id,
                      count=1):
    """Metadata for a shared contact card.  The vCard is ciphertext; `count`
    (how many contacts) is the only routing hint."""
    return {
        "kind": "contact",
        "ciphertext": encrypted_vcard_ciphertext,
        "nonce": nonce,
        "scheme": scheme,
        "sender_key_id": sender_key_id,
        "count": int(count),
    }


# ---------------------------------------------------------------------------
# Location — current + LIVE (15m / 1h / 8h)
# ---------------------------------------------------------------------------
# Coordinates are ciphertext (lat/lng encrypted on device).  LIVE location is a
# stream of encrypted fixes with a server-known EXPIRY (so the relay can stop
# forwarding + auto-clean), but NOT the coordinates themselves.

LIVE_DURATIONS_MIN = {"15m": 15, "1h": 60, "8h": 480}


def live_location_expiry(duration_key, start=None):
    """Return the UTC expiry for a live-location share.  duration_key ∈
    {15m,1h,8h}.  The server knows WHEN it ends (to stop relaying + clean), not
    WHERE the person is."""
    minutes = LIVE_DURATIONS_MIN.get(duration_key)
    if minutes is None:
        return None
    start = start or datetime.now(timezone.utc)
    return start + timedelta(minutes=minutes)


def live_location_active(expires_at, now=None):
    exp = _as_dt(expires_at)
    if exp is None:
        return False
    now = now or datetime.now(timezone.utc)
    return now < exp


def location_fix_meta(ciphertext, nonce, scheme, sender_key_id, live=False,
                      duration_key=None, start=None):
    """Metadata for a current or live location fix.  Coordinates are ciphertext;
    for live shares the server also stores the expiry so it can auto-stop."""
    meta = {
        "kind": "location",
        "ciphertext": ciphertext,
        "nonce": nonce,
        "scheme": scheme,
        "sender_key_id": sender_key_id,
        "live": bool(live),
    }
    if live:
        exp = live_location_expiry(duration_key, start=start)
        if exp is None:
            raise ValueError("live location needs a valid duration_key")
        meta["expires_at"] = exp.isoformat()
        meta["duration_key"] = duration_key
    return meta


def duration_label(duration_key, lang="bn"):
    labels = {
        "15m": ("১৫ মিনিট", "15 minutes"),
        "1h": ("১ ঘণ্টা", "1 hour"),
        "8h": ("৮ ঘণ্টা", "8 hours"),
    }
    bn, en = labels.get(duration_key, (duration_key, duration_key))
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# Auto-cleanup of undelivered blobs + disk floor
# ---------------------------------------------------------------------------
# WhatsApp expires undelivered media on its servers.  We cleanup an encrypted
# blob once it is delivered to all recipients, OR after it ages out undelivered,
# OR when free disk drops below a floor (evict oldest undelivered first).

UNDELIVERED_TTL_DAYS = 30     # drop a never-delivered blob after this
DELIVERED_GRACE_HOURS = 24    # keep briefly after delivery for re-download
DISK_FLOOR_BYTES = 512 * MB   # never let media push free space below this


def should_cleanup_blob(blob, now=None):
    """blob = {created_at, delivered_to:[...], recipient_ids:[...],
    last_downloaded_at?}.  Return (cleanup: bool, reason)."""
    now = now or datetime.now(timezone.utc)
    created = _as_dt(blob.get("created_at"))
    delivered = set(blob.get("delivered_to") or [])
    recipients = set(blob.get("recipient_ids") or [])
    fully_delivered = recipients and recipients.issubset(delivered)
    if fully_delivered:
        ref = _as_dt(blob.get("last_downloaded_at")) or created
        if ref and (now - ref) >= timedelta(hours=DELIVERED_GRACE_HOURS):
            return True, "delivered_grace_elapsed"
        return False, "delivered_within_grace"
    if created and (now - created) >= timedelta(days=UNDELIVERED_TTL_DAYS):
        return True, "undelivered_ttl_elapsed"
    return False, "keep"


def disk_floor_ok(free_bytes, incoming_bytes=0, floor=DISK_FLOOR_BYTES):
    """True if accepting `incoming_bytes` still leaves >= floor free."""
    return (int(free_bytes) - int(incoming_bytes)) >= floor


def eviction_plan(blobs, free_bytes, need_bytes, floor=DISK_FLOOR_BYTES,
                  now=None):
    """When disk is tight, pick blobs to evict to make room.  Policy:
      1) first evict blobs that should_cleanup anyway,
      2) then oldest UNDELIVERED blobs,
    until (free + reclaimed - need) >= floor.  Returns the list of blob ids to
    evict (does NOT touch delivered-within-grace unless unavoidable)."""
    now = now or datetime.now(timezone.utc)
    target = floor + int(need_bytes)
    reclaimed = int(free_bytes)
    evict = []

    def take(candidates):
        nonlocal reclaimed
        for b in candidates:
            if reclaimed >= target:
                break
            evict.append(b.get("id"))
            reclaimed += int(b.get("byte_size") or 0)

    cleanable = [b for b in (blobs or []) if should_cleanup_blob(b, now=now)[0]]
    take(cleanable)
    if reclaimed < target:
        cleanable_ids = set(evict)
        undelivered = [
            b for b in (blobs or [])
            if b.get("id") not in cleanable_ids
            and not (set(b.get("recipient_ids") or [])
                     and set(b.get("recipient_ids") or [])
                     .issubset(set(b.get("delivered_to") or [])))
        ]
        undelivered.sort(key=lambda b: _as_dt(b.get("created_at"))
                         or datetime.min.replace(tzinfo=timezone.utc))
        take(undelivered)
    return evict


def media_gate_notice(kind, lang="bn"):
    """UI string when a media kind is not yet unlocked (key-gated storage).
    Reuses circle.media_available as the single source of truth."""
    if media_available(kind if kind in ("text", "voice", "photo", "video") else "photo"):
        return None
    return pick(lang,
                "এনক্রিপ্টেড স্টোরেজ চালু হলে এই মিডিয়া পাঠানো যাবে।",
                "Available when encrypted media storage is enabled.")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _as_dt(v):
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    if isinstance(v, (int, float)):
        return datetime.fromtimestamp(v, tz=timezone.utc)
    if isinstance(v, str):
        try:
            d = datetime.fromisoformat(v.replace("Z", "+00:00"))
            return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None
