"""
backup_transfer.py — pure, deterministic helpers behind Assisto's ENCRYPTED
BACKUP & PHONE TRANSFER feature (issue #197, SPEC v2.1 §21, ADVANCED).

WHAT THIS MODULE IS (and is NOT)
--------------------------------
This file is PURE stdlib: no Django, no DB, no network, no clock, **no AI** and
crucially **NO SECRET KEY MATERIAL and NO ENCRYPTION happens here**. The actual
encryption is done ON THE DEVICE in Dart (app/lib/screens/encrypted_backup_screen.dart)
reusing the app's existing audited primitives in app/lib/crypto/e2e.dart
(PBKDF2-HMAC-SHA256 key stretching + ChaCha20-Poly1305 AEAD + SHA-256). The
plaintext export never leaves the phone unencrypted, and the passphrase never
touches the server.

What this module DOES is the deterministic, side-effect-free *bookkeeping*
around that bundle so the client and (optionally) the server agree on the same
rules:

  * build_manifest()     — the metadata header that rides OUTSIDE the ciphertext
                           (format id, version, KDF params, chunk count, a
                           plaintext-checksum commitment, created_at passed IN).
  * verify_manifest()    — validate a manifest's shape/fields honestly.
  * checksum()           — SHA-256 hex of bytes/str (integrity, NOT secrecy).
  * verify_integrity()   — compare a recomputed checksum to the manifest's.
  * chunk() / dechunk()  — split a big base64 bundle into transfer-sized pieces
                           for a device-to-device handoff, and rejoin them.
  * make_transfer_code() — a short, human-readable, OUT-OF-BAND verification
                           code derived (deterministically) from the bundle's
                           checksum. It is NOT the key and NOT the passphrase —
                           it only lets the receiving phone confirm it got the
                           exact same bundle the sending phone sent.
  * validate_transfer_code() — check a typed code against a bundle.
  * drive_seam()         — the HONEST description of the Google-Drive cloud
                           backup seam: it is KEY-GATED (Drive OAuth not
                           configured) and returns connected=False so the UI can
                           say "connect Google Drive for automatic cloud backup"
                           without faking a sync.

HONEST TRANSPORT
----------------
Phone transfer is NOT magic cloud sync. The real transport is: the sending
phone produces the encrypted bundle (a file / pasteable text) and a short
transfer code; the user moves the *file* by whatever channel they already have
(share sheet, cable, Nearby Share, messaging app) and reads the short code (and
the passphrase) to the other person separately / out-of-band. The receiving
phone imports the file, confirms the transfer code matches, then is asked for
the passphrase to decrypt. We never pretend a code alone teleports the data.

PASSPHRASE LOSS
---------------
The manifest stores ONLY a checksum commitment of the *plaintext* and the KDF
salt/params — never the passphrase, never a password hash usable to brute the
passphrase offline cheaply beyond the PBKDF2 cost. If the passphrase is lost the
backup cannot be opened. The UI must warn about this; this module simply refuses
to carry anything that could weaken that guarantee.
"""

import hashlib

# --------------------------------------------------------------------------
# Format constants. The Dart side mirrors these EXACTLY (see encrypted_backup_
# screen.dart `_fmt`, `_fmtVersion`, `_kdfIters`). Bump FORMAT_VERSION only with
# a matching Dart change + a dechunk/restore compatibility path.
# --------------------------------------------------------------------------
FORMAT_ID = "assisto-backup"
FORMAT_VERSION = 1
KDF = "pbkdf2-hmac-sha256"
AEAD = "chacha20-poly1305"
# Matches KeyBackup.seal() in app/lib/crypto/e2e.dart (120000 iterations).
KDF_ITERS = 120000
# A transfer chunk is sized so a short code / small payload survives being
# pasted or QR-split by a future scanner without a hard native dependency now.
DEFAULT_CHUNK = 64 * 1024  # 64 KiB of base64 text per piece
# Transfer code: groups of the recovery-code alphabet (no ambiguous chars).
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # mirrors e2e.dart generateRecoveryCode
CODE_GROUPS = 3
CODE_GROUP_LEN = 4


# --------------------------------------------------------------- checksum

def checksum(data):
    """SHA-256 hex digest of bytes or str (utf-8). Integrity, not secrecy."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    if not isinstance(data, (bytes, bytearray)):
        raise TypeError("checksum expects bytes or str")
    return hashlib.sha256(bytes(data)).hexdigest()


def verify_integrity(data, expected_hex):
    """True iff checksum(data) equals expected_hex (case-insensitive, exact)."""
    if not expected_hex or not isinstance(expected_hex, str):
        return False
    return _ct_eq(checksum(data), expected_hex.lower())


def _ct_eq(a, b):
    if len(a) != len(b):
        return False
    diff = 0
    for x, y in zip(a, b):
        diff |= ord(x) ^ ord(y)
    return diff == 0


# --------------------------------------------------------------- manifest

def build_manifest(
    *,
    plaintext_checksum,
    cipher_len,
    created_at,
    salt_b64,
    nonce_b64,
    source="assisto-export",
    chunk_size=DEFAULT_CHUNK,
    item_count=None,
):
    """Build the plaintext metadata header that rides OUTSIDE the ciphertext.

    NOTHING secret goes here: no passphrase, no key, no plaintext. Only enough
    to (a) identify the format, (b) stretch the passphrase the same way on
    restore (salt + iters), (c) verify integrity after decrypt (the plaintext
    checksum commitment), and (d) know how to reassemble transfer chunks.

    `created_at` is passed IN (ISO string) so this stays clock-free/pure.
    """
    if not plaintext_checksum or len(plaintext_checksum) != 64:
        raise ValueError("plaintext_checksum must be a 64-char sha256 hex")
    if not isinstance(cipher_len, int) or cipher_len < 0:
        raise ValueError("cipher_len must be a non-negative int")
    if not salt_b64 or not nonce_b64:
        raise ValueError("salt_b64 and nonce_b64 are required")
    chunks = chunk_count(cipher_len, chunk_size)
    m = {
        "format": FORMAT_ID,
        "version": FORMAT_VERSION,
        "kdf": KDF,
        "kdf_iters": KDF_ITERS,
        "aead": AEAD,
        "salt": salt_b64,
        "nonce": nonce_b64,
        "cipher_len": cipher_len,
        "chunk_size": chunk_size,
        "chunks": chunks,
        "plaintext_sha256": plaintext_checksum.lower(),
        "source": source,
        "created_at": created_at,
    }
    if item_count is not None:
        m["item_count"] = int(item_count)
    return m


def verify_manifest(manifest):
    """Return a list of problem codes ([] == valid). Honest, never raises."""
    problems = []
    if not isinstance(manifest, dict):
        return ["not_a_manifest"]
    if manifest.get("format") != FORMAT_ID:
        problems.append("bad_format")
    v = manifest.get("version")
    if not isinstance(v, int) or v < 1 or v > FORMAT_VERSION:
        problems.append("bad_version")
    if manifest.get("kdf") != KDF:
        problems.append("bad_kdf")
    if not isinstance(manifest.get("kdf_iters"), int) or manifest.get("kdf_iters", 0) < 100000:
        # refuse to carry a weakened KDF cost
        problems.append("weak_kdf")
    if manifest.get("aead") != AEAD:
        problems.append("bad_aead")
    for f in ("salt", "nonce", "plaintext_sha256"):
        if not manifest.get(f):
            problems.append("missing_" + f)
    pc = manifest.get("plaintext_sha256")
    if pc and (not isinstance(pc, str) or len(pc) != 64):
        problems.append("bad_checksum")
    cl = manifest.get("cipher_len")
    if not isinstance(cl, int) or cl < 0:
        problems.append("bad_cipher_len")
    cs = manifest.get("chunk_size")
    if not isinstance(cs, int) or cs <= 0:
        problems.append("bad_chunk_size")
    elif isinstance(cl, int) and cl >= 0:
        if manifest.get("chunks") != chunk_count(cl, cs):
            problems.append("chunk_mismatch")
    return problems


# --------------------------------------------------------------- chunking

def chunk_count(total_len, chunk_size=DEFAULT_CHUNK):
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    if total_len <= 0:
        return 0
    return (total_len + chunk_size - 1) // chunk_size


def chunk(text, chunk_size=DEFAULT_CHUNK):
    """Split a (base64) bundle string into transfer-sized pieces.

    Returns a list of {'i', 'n', 'data'} so a receiver can reassemble in order
    and detect a missing piece. Deterministic; preserves exact bytes on rejoin.
    """
    if not isinstance(text, str):
        raise TypeError("chunk expects a str")
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")
    n = chunk_count(len(text), chunk_size)
    out = []
    for i in range(n):
        piece = text[i * chunk_size:(i + 1) * chunk_size]
        out.append({"i": i, "n": n, "data": piece})
    return out


def dechunk(pieces):
    """Rejoin pieces from chunk(). Raises ValueError on a missing/duplicate/out-
    of-range index or an inconsistent total so restore fails HONESTLY, never
    silently returning a truncated bundle."""
    if not isinstance(pieces, list) or not pieces:
        raise ValueError("no_pieces")
    total = pieces[0].get("n")
    if not isinstance(total, int) or total <= 0:
        raise ValueError("bad_total")
    seen = {}
    for p in pieces:
        if p.get("n") != total:
            raise ValueError("inconsistent_total")
        i = p.get("i")
        if not isinstance(i, int) or i < 0 or i >= total:
            raise ValueError("bad_index")
        if i in seen:
            raise ValueError("duplicate_index")
        seen[i] = p.get("data", "")
    if len(seen) != total:
        raise ValueError("missing_pieces")
    return "".join(seen[i] for i in range(total))


# --------------------------------------------------------- transfer code

def make_transfer_code(bundle_or_checksum):
    """A short OUT-OF-BAND verification code derived from the bundle checksum.

    NOT the key, NOT the passphrase — it only lets the receiving phone confirm
    it imported the exact same bundle. Deterministic: same bundle -> same code.
    Accepts either the raw bundle text or an already-computed sha256 hex.
    """
    if isinstance(bundle_or_checksum, str) and len(bundle_or_checksum) == 64 \
            and all(c in "0123456789abcdef" for c in bundle_or_checksum.lower()):
        digest_hex = bundle_or_checksum.lower()
    else:
        digest_hex = checksum(bundle_or_checksum)
    # Re-hash with a domain tag so the code can't be confused with the raw
    # checksum, then map digest bytes onto the unambiguous alphabet.
    tagged = hashlib.sha256(("assisto-transfer-code:" + digest_hex).encode("utf-8")).digest()
    chars = []
    for b in tagged[:CODE_GROUPS * CODE_GROUP_LEN]:
        chars.append(CODE_ALPHABET[b % len(CODE_ALPHABET)])
    groups = ["".join(chars[g * CODE_GROUP_LEN:(g + 1) * CODE_GROUP_LEN])
              for g in range(CODE_GROUPS)]
    return "-".join(groups)


def validate_transfer_code(bundle_or_checksum, typed_code):
    """True iff `typed_code` matches the bundle's transfer code. Tolerant of
    spaces/case/dashes the user may mistype; comparison is constant-time."""
    if not typed_code or not isinstance(typed_code, str):
        return False
    want = make_transfer_code(bundle_or_checksum)
    norm = "".join(ch for ch in typed_code.upper() if ch in CODE_ALPHABET)
    want_norm = "".join(ch for ch in want if ch in CODE_ALPHABET)
    return _ct_eq_str(norm, want_norm)


def _ct_eq_str(a, b):
    if len(a) != len(b):
        return False
    diff = 0
    for x, y in zip(a, b):
        diff |= ord(x) ^ ord(y)
    return diff == 0


# --------------------------------------------------- recovery note (text)

def recovery_note(manifest, transfer_code, *, strings=None):
    """Build the human recovery-note LINES (no literals baked in English — the
    UI passes localized `strings`; this only assembles order + values).

    `strings` keys used: title, created, format, items, code, warn. If omitted
    (tests / server), neutral ASCII labels are used — the SHIPPING app always
    passes localized bn/en strings so there are zero UI literals here."""
    s = strings or {
        "title": "Assisto encrypted backup",
        "created": "Created",
        "format": "Format",
        "items": "Items",
        "code": "Transfer code",
        "warn": "Keep your passphrase safe. Without it this backup cannot be opened.",
    }
    lines = [
        s["title"],
        "{}: {}".format(s["created"], manifest.get("created_at", "")),
        "{}: {} v{}".format(s["format"], manifest.get("format", ""),
                            manifest.get("version", "")),
    ]
    if manifest.get("item_count") is not None:
        lines.append("{}: {}".format(s["items"], manifest["item_count"]))
    lines.append("{}: {}".format(s["code"], transfer_code))
    lines.append(s["warn"])
    return lines


# ------------------------------------------------------- Drive OAuth seam

def drive_seam(configured=False):
    """HONEST description of the Google-Drive cloud-backup seam.

    Cloud backup is KEY-GATED: it needs Google Drive OAuth which is NOT wired.
    This returns connected=False (unless a real token layer later flips
    `configured`) so the UI shows "connect Google Drive for automatic cloud
    backup" instead of faking a sync. The LOCAL encrypted backup works with no
    key — that is the whole point of the feature shipping now.
    """
    return {
        "provider": "google_drive",
        "oauth": "google-oauth2",
        "scope": "https://www.googleapis.com/auth/drive.appdata",
        "configured": bool(configured),
        "connected": False,          # never true until a real token exists
        "local_backup_available": True,  # the shipped path needs no key
        "note": "key_gated",
    }
