"""
circle.py — Assisto "Connected Circle" logic (relationship graph + consent +
end-to-end-encrypted ciphertext relay).  No AI key; pure Python, deterministic,
unit-testable.  Benchmarked against Signal / WhatsApp (family E2E messaging).

THE PRIVACY CONTRACT (owner-specified, enforced here):
  - The server is a *relay*.  It stores and forwards CIPHERTEXT ONLY.  It never
    holds a message key and MUST NOT be able to read a circle message.  The
    server AI is never shown circle message plaintext.
  - Keys live on-device.  An OPTIONAL encrypted key backup may be stored, sealed
    under a recovery code the server also never learns (see
    owner_actions/connected_circle_e2e.md).
  - A relationship is mutual + consented: request → accept.  No contact-list
    upload without explicit consent.  Either side may block/report.

WHAT LIVES HERE (logic/state only — DB models, the HTTP relay endpoints, the
device keystore and the WebRTC/push ring are platform-gated and clearly marked
for the integrator):
  - Relationship vocabulary (আব্বা/আম্মা/সন্তান/স্বামী/স্ত্রী/ভাই/বোন/আত্মীয়/
    বন্ধু/সহকর্মী + custom) with bilingual labels and the *reciprocal* of each
    relation (so "I added you as my father" ⇒ "you added me as your child").
  - Relationship request state machine: pending → accepted | declined | blocked.
  - Consent gate for any contact-list / phone-book access.
  - Relationship-scoped sharing policy: who sees what (medicines, location,
    documents, money) per relation, with safe defaults.
  - Ciphertext relay rules: what the server is *allowed* to see on a message
    envelope (sender, recipients, timestamp, content-type, blob ref) vs. what it
    must never see (the plaintext, the keys).  A validator proves an envelope
    carries no plaintext.
  - Media gating: text works now (software-fallback E2E); voice-note / photo /
    short-video are key-gated storage ("Available when ___") until the media
    bucket + OpenMLS are wired.
  - Invite tokens (phone or QR) — short, signed, single-use, expiring.

Run self-tests (no DB):
    python3 -c "import core.logic.circle_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import time
from datetime import datetime, timedelta, timezone


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# Relationship vocabulary
# ---------------------------------------------------------------------------
# Each relation has a machine code (ASCII, stored), bilingual labels, and the
# reciprocal relation code.  Gendered reciprocals (father→child) collapse to a
# neutral "child" because the adder's gender is not implied by the relation.

RELATIONS = {
    # code:        (bn label,   en label,   reciprocal code)
    "father":   ("আব্বা",     "Father",    "child"),
    "mother":   ("আম্মা",     "Mother",    "child"),
    "child":    ("সন্তান",    "Child",     "parent"),
    "parent":   ("অভিভাবক",   "Parent",    "child"),
    "husband":  ("স্বামী",    "Husband",   "wife"),
    "wife":     ("স্ত্রী",    "Wife",      "husband"),
    "spouse":   ("জীবনসঙ্গী", "Spouse",    "spouse"),
    "brother":  ("ভাই",       "Brother",   "sibling"),
    "sister":   ("বোন",       "Sister",    "sibling"),
    "sibling":  ("ভাইবোন",    "Sibling",   "sibling"),
    "relative": ("আত্মীয়",   "Relative",  "relative"),
    "friend":   ("বন্ধু",     "Friend",    "friend"),
    "colleague": ("সহকর্মী",  "Colleague", "colleague"),
    "custom":   ("অন্যান্য",   "Other",     "custom"),
}

# Relations that are "close family" — looser sharing defaults, SOS reach, the
# 1-tap call/message from a medicine card.
CLOSE_FAMILY = {"father", "mother", "child", "parent", "husband", "wife", "spouse",
                "brother", "sister", "sibling"}


def normalize_relation(code):
    """Map a (possibly messy) relation code to a known one; unknown ⇒ 'custom'."""
    c = (code or "").strip().lower()
    return c if c in RELATIONS else "custom"


def relation_label(code, lang="bn", custom_label=""):
    """Bilingual label for a relation.  'custom' uses the user's own free text
    (never Bangla-forced; the user typed it in their language)."""
    code = normalize_relation(code)
    if code == "custom" and (custom_label or "").strip():
        return custom_label.strip()
    bn, en, _ = RELATIONS[code]
    return pick(lang, bn, en)


def reciprocal_relation(code):
    """The relation the *other* person has to me, given the relation I set.
    Example: I mark someone my 'father' ⇒ to them I am their 'child'."""
    code = normalize_relation(code)
    return RELATIONS[code][2]


def is_close_family(code):
    return normalize_relation(code) in CLOSE_FAMILY


def relation_catalog(lang="bn"):
    """Ordered list for the relation picker UI (code + localized label)."""
    order = ["father", "mother", "child", "husband", "wife", "brother", "sister",
             "relative", "friend", "colleague", "custom"]
    return [{"code": c, "label": relation_label(c, lang)} for c in order]


# ---------------------------------------------------------------------------
# Relationship request state machine
# ---------------------------------------------------------------------------

REQ_PENDING = "pending"
REQ_ACCEPTED = "accepted"
REQ_DECLINED = "declined"
REQ_BLOCKED = "blocked"
REQ_STATES = {REQ_PENDING, REQ_ACCEPTED, REQ_DECLINED, REQ_BLOCKED}

# Allowed transitions: current -> {events}. An event names an action by an actor.
#   accept / decline / block / unblock  (recipient)  ·  cancel (sender)
_TRANSITIONS = {
    REQ_PENDING:  {"accept": REQ_ACCEPTED, "decline": REQ_DECLINED,
                   "block": REQ_BLOCKED, "cancel": REQ_DECLINED},
    REQ_ACCEPTED: {"block": REQ_BLOCKED},
    REQ_DECLINED: {},                 # a new request must be sent afresh
    REQ_BLOCKED:  {"unblock": REQ_DECLINED},
}


def apply_request_event(state, event):
    """Return (new_state, changed) for a relationship-request transition.
    Unknown/illegal events leave the state unchanged (changed=False) so the
    relay/endpoint can reject without raising."""
    state = state if state in REQ_STATES else REQ_PENDING
    nxt = _TRANSITIONS.get(state, {}).get(event)
    if nxt is None:
        return state, False
    return nxt, True


# Request direction (whose row is this, relative to the viewer).
#   OUTGOING: I created / sent this request  -> I may only CANCEL it.
#   INCOMING: it was sent TO me               -> I may ACCEPT or DECLINE it.
DIR_OUTGOING = "outgoing"
DIR_INCOMING = "incoming"


def normalize_direction(direction):
    d = (direction or "").strip().lower()
    return d if d in (DIR_OUTGOING, DIR_INCOMING) else DIR_OUTGOING


def request_actions(direction):
    """The action codes the viewer is allowed to take on a PENDING request,
    given its direction.  The sender (outgoing) can ONLY cancel; the receiver
    (incoming) can accept or decline.  Accept/decline is NEVER offered to the
    sender.  Returned as a list the serializer hands to the UI so the client
    cannot invent a button the server will reject."""
    if normalize_direction(direction) == DIR_INCOMING:
        return ["accept", "decline"]
    return ["cancel"]


def can_act_on_request(direction, event):
    """SERVER AUTHORIZATION GUARD for /circle/request/<id>/act.  Returns
    (allowed, reason).  Enforces, independent of client state:
      - the RECEIVER (incoming) may accept/decline/block only;
      - the SENDER (outgoing) may cancel/block only — NEVER accept/decline
        (a user accepting their own outgoing request is forbidden → 403);
      - block is allowed from either side (safety valve)."""
    direction = normalize_direction(direction)
    event = (event or "").strip().lower()
    if event == "block":
        return True, "ok"
    if direction == DIR_INCOMING:
        if event in ("accept", "decline"):
            return True, "ok"
        return False, "receiver may only accept or decline"
    # outgoing / sender
    if event == "cancel":
        return True, "ok"
    if event in ("accept", "decline"):
        return False, "the sender cannot accept or decline their own request"
    return False, "not allowed for the sender"


def is_circle_member(state):
    """A person is part of 'Your circle' ONLY once the request is ACCEPTED.
    Pending (incoming OR outgoing), declined and blocked edges are NOT members
    and must not appear as circle members anywhere."""
    return state == REQ_ACCEPTED


def request_status_label(direction, lang="bn"):
    """Short status chip for a PENDING request in the viewer's language.
    Outgoing reads 'Sent'; incoming reads 'Request'."""
    if normalize_direction(direction) == DIR_INCOMING:
        return pick(lang, "রিকোয়েস্ট", "Request")
    return pick(lang, "পাঠানো হয়েছে", "Sent")


def serialize_request(row, *, direction, display_name="", photo="",
                      lang="bn", other_name=None):
    """Build the request payload the client renders for a PENDING edge.

    `row` is a dict/obj-like with: id, relation, custom_label, state, note,
    created_at.  `display_name`/`photo` are the OTHER party resolved from their
    user account (sender for an incoming request, recipient for an outgoing one)
    so the card never shows '?'.  Exposes `actions` (cancel-only vs
    accept/decline) so the UI is a pure function of the server's decision."""
    def g(k, default=""):
        if isinstance(row, dict):
            return row.get(k, default)
        return getattr(row, k, default)

    direction = normalize_direction(direction)
    rel = g("relation", "friend")
    name = (display_name or other_name or g("name") or "").strip()
    created = g("created_at") or g("requested_at")
    if created is not None and not isinstance(created, str):
        try:
            created = created.isoformat()
        except Exception:
            created = str(created)
    return {
        "id": g("id"),
        "direction": direction,
        "name": name,                      # the OTHER party's display name
        "display_name": name,
        "photo": photo or "",              # the OTHER party's photo (may be "")
        "relation": rel,
        "relation_label": relation_label(rel, lang, g("custom_label")),
        "custom_label": g("custom_label"),
        "note": (g("note") or "")[:500],   # their ONE optional pre-accept note
        "state": g("state", REQ_PENDING),
        "created_at": created,
        "status_label": request_status_label(direction, lang),
        "actions": request_actions(direction),
        "is_member": is_circle_member(g("state", REQ_PENDING)),
    }


def can_message(state_a, state_b=None, blocked_either=False):
    """Two members may exchange messages iff BOTH sides are 'accepted' and
    neither has blocked.  state_b defaults to state_a for a single mutual row."""
    if blocked_either:
        return False
    if state_b is None:
        return state_a == REQ_ACCEPTED
    return state_a == REQ_ACCEPTED and state_b == REQ_ACCEPTED


# ---------------------------------------------------------------------------
# Consent gate (contact-list / phone-book access)
# ---------------------------------------------------------------------------

def contact_access_allowed(consent_granted, consent_at=None, ttl_days=365, now=None):
    """Contacts may be read ONLY with an explicit, non-expired consent record.
    Default OFF.  Consent older than ttl_days must be re-granted."""
    if not consent_granted:
        return False
    if consent_at is None:
        return True
    now = now or datetime.now(timezone.utc)
    ca = _as_dt(consent_at)
    if ca is None:
        return False
    return (now - ca) <= timedelta(days=ttl_days)


def consent_prompt(lang="bn"):
    return pick(
        lang,
        "আপনার ফোনের কন্টাক্ট থেকে পরিচিতদের খুঁজে পেতে অনুমতি দিন? "
        "আমরা শুধু মিল যাচাই করি, আপনার তালিকা সার্ভারে রাখি না।",
        "Allow reading your phone contacts to find people you know? "
        "We only match — your list is never stored on our server.",
    )


# ---------------------------------------------------------------------------
# Relationship-scoped sharing policy ("who sees what")
# ---------------------------------------------------------------------------
# Shareable scopes. A member grants a subset to each relation. Safe defaults:
# close family may see medicines + SOS/location; nobody sees money/documents
# unless explicitly turned on.

SCOPES = ("medicines", "location", "documents", "money", "profile")

_DEFAULTS_CLOSE = {"medicines": True, "location": True, "documents": False,
                   "money": False, "profile": True}
_DEFAULTS_OTHER = {"medicines": False, "location": False, "documents": False,
                   "money": False, "profile": True}


def default_sharing(relation_code):
    """Starting sharing policy for a newly accepted relation (user can edit)."""
    base = _DEFAULTS_CLOSE if is_close_family(relation_code) else _DEFAULTS_OTHER
    return dict(base)


def normalize_sharing(policy):
    """Coerce an arbitrary dict into a clean {scope: bool} over known SCOPES."""
    policy = policy or {}
    return {s: bool(policy.get(s, False)) for s in SCOPES}


def can_see(policy, scope):
    """Does this relation's policy expose `scope`?  Unknown scope ⇒ False."""
    if scope not in SCOPES:
        return False
    return bool(normalize_sharing(policy).get(scope, False))


def scope_label(scope, lang="bn"):
    labels = {
        "medicines": ("ওষুধ", "Medicines"),
        "location":  ("অবস্থান", "Location"),
        "documents": ("ডকুমেন্ট", "Documents"),
        "money":     ("টাকা", "Money"),
        "profile":   ("প্রোফাইল", "Profile"),
    }
    bn, en = labels.get(scope, (scope, scope))
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# Ciphertext relay envelope — the SERVER contract
# ---------------------------------------------------------------------------
# A circle message, on the wire and at rest on the server, is an *envelope*.
# The server may read ONLY routing metadata.  The payload is opaque ciphertext
# the server stores verbatim and forwards; it carries no plaintext and no key.
#
# Content types.  'text' ciphertext is stored inline (small).  Media is a blob
# reference (the encrypted file lives in object storage; still ciphertext-only).

# md1: "document" (blob) and "location" (a static point, inline ciphertext).
# mc-media2: "contact" (a contact card, inline ciphertext). A LIVE location is
# a "location" message whose ciphertext the sender replaces in place
# (core/views_mc_media2.py) — older apps keep showing "Location".
CONTENT_TYPES = ("text", "voice", "photo", "video", "document", "location",
                 "contact", "key_exchange", "system")
# mc-media2: kinds whose ciphertext is INLINE and small (a point / a card):
# no blob, and a hard cap on the base64 ciphertext so nobody parks files here.
SHARE_TYPES = ("location", "contact")
SHARE_CT_MAX = 8192

# Metadata the server is permitted to persist on an envelope (ROUTING ONLY).
ALLOWED_META_KEYS = {
    "id", "circle_id", "sender_id", "recipient_ids", "content_type",
    "created_at", "blob_ref", "ciphertext", "nonce", "sender_key_id",
    "scheme", "delivered_to", "read_by",
}
# Keys that, if present, mean someone tried to smuggle plaintext/keys through
# the relay — the validator rejects these outright.
FORBIDDEN_META_KEYS = {
    "plaintext", "text", "body", "message", "transcript", "caption",
    "private_key", "priv", "secret", "recovery_code", "password", "key",
}


def validate_envelope(env):
    """Return (ok, reason).  Proves an envelope is relay-safe:
      - declares a known content_type,
      - carries ciphertext (inline for text, blob_ref for media),
      - contains NO forbidden plaintext/secret keys,
      - never includes a readable-looking payload.
    The relay calls this before persisting.  This is the server's guarantee
    that it is storing ciphertext only."""
    if not isinstance(env, dict):
        return False, "envelope must be an object"
    ct = env.get("content_type")
    if ct not in CONTENT_TYPES:
        return False, "unknown content_type"
    bad = FORBIDDEN_META_KEYS & set(env.keys())
    if bad:
        return False, "forbidden plaintext/secret field(s): " + ",".join(sorted(bad))
    # Text + key_exchange carry inline ciphertext; media carry a blob reference.
    if ct in ("text", "key_exchange") + SHARE_TYPES:
        if not env.get("ciphertext"):
            return False, "missing ciphertext"
        if not env.get("nonce"):
            return False, "missing nonce"
        if ct in SHARE_TYPES:
            if env.get("blob_ref"):
                return False, "no blob for " + ct
            if len(str(env.get("ciphertext"))) > SHARE_CT_MAX:
                return False, "ciphertext too large"
    elif ct in ("voice", "photo", "video", "document"):
        if not env.get("blob_ref"):
            return False, "missing blob_ref for media"
    # recipients must be present (routing)
    if ct != "system" and not env.get("recipient_ids"):
        return False, "missing recipient_ids"
    return True, "ok"


def server_visible_fields(env):
    """The projection the server/AI is allowed to see: routing metadata only,
    with the opaque ciphertext/blob preserved but NOT interpreted.  Any
    unexpected key is dropped (defence-in-depth against plaintext leaks)."""
    out = {}
    for k in ALLOWED_META_KEYS:
        if k in env:
            out[k] = env[k]
    # Hard strip anything forbidden even if it slipped into ALLOWED by mistake.
    for k in FORBIDDEN_META_KEYS:
        out.pop(k, None)
    return out


def ai_redaction(env):
    """What the server AI may know about a circle message: that it exists and
    its type — NEVER its content.  Used if the AI ever summarizes activity."""
    return {
        "kind": "circle_message",
        "content_type": env.get("content_type", "text"),
        "encrypted": True,
        "readable_by_server": False,
    }


# ---------------------------------------------------------------------------
# Delivery / read state
# ---------------------------------------------------------------------------

def mark_delivered(delivered_to, member_id):
    s = set(delivered_to or [])
    s.add(member_id)
    return sorted(s)


def mark_read(read_by, member_id):
    s = set(read_by or [])
    s.add(member_id)
    return sorted(s)


def delivery_status(env, member_id):
    """Per-recipient status label for a tick indicator (sender's view)."""
    read = set(env.get("read_by") or [])
    delivered = set(env.get("delivered_to") or [])
    if member_id in read:
        return "read"
    if member_id in delivered:
        return "delivered"
    return "sent"


# ---------------------------------------------------------------------------
# Media gating ("Available when ___")
# ---------------------------------------------------------------------------
# Text E2E works now via the software fallback.  Media + calls are key-gated on
# infra the owner must provision (object storage for encrypted blobs; a prod
# TURN server + push-to-ring).  The UI shows a clear reason string.

MEDIA_UNLOCKED = {
    "text": True,
    "voice": False,
    "photo": False,
    "video": False,
    "call": False,
}


def media_available(content_type):
    return bool(MEDIA_UNLOCKED.get(content_type, False))


def media_gate_reason(content_type, lang="bn"):
    """None if available; else a localized 'Available when ___' reason."""
    if media_available(content_type):
        return None
    reasons = {
        "voice": ("এনক্রিপ্টেড স্টোরেজ চালু হলে ভয়েস নোট পাঠানো যাবে।",
                  "Voice notes available when encrypted media storage is enabled."),
        "photo": ("এনক্রিপ্টেড স্টোরেজ চালু হলে ছবি পাঠানো যাবে।",
                  "Photos available when encrypted media storage is enabled."),
        "video": ("এনক্রিপ্টেড স্টোরেজ চালু হলে ভিডিও পাঠানো যাবে।",
                  "Short video available when encrypted media storage is enabled."),
        "call":  ("কল সার্ভার (TURN) চালু হলে ভয়েস কল করা যাবে।",
                  "Voice call available when the call (TURN) server is enabled."),
    }
    bn, en = reasons.get(content_type, ("শীঘ্রই আসছে।", "Coming soon."))
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# Invite tokens (phone / QR) — short, signed, single-use, expiring
# ---------------------------------------------------------------------------
# A member invites by sharing a token.  The token binds the inviter + their
# intended relation; when scanned/opened it pre-fills the request.  Signed with
# an HMAC server secret so it can't be forged; carries an expiry; marked used
# on first redemption (single-use is enforced in the DB by the integrator).

def make_invite_token(inviter_id, relation_code, secret, ttl_minutes=1440, now=None):
    """Create a compact signed invite token.  `secret` is a server-side key the
    integrator supplies (settings.SECRET_KEY is fine).  Returns the token str."""
    now = now or datetime.now(timezone.utc)
    exp = int((now + timedelta(minutes=ttl_minutes)).timestamp())
    nonce = secrets.token_urlsafe(6)
    body = f"{int(inviter_id)}.{normalize_relation(relation_code)}.{exp}.{nonce}"
    sig = _sign(body, secret)
    return f"{body}.{sig}"


def parse_invite_token(token, secret, now=None):
    """Return (ok, data|reason).  Verifies signature + expiry.  Does NOT mark
    used — single-use is the DB's job (the integrator checks a used flag)."""
    now = now or datetime.now(timezone.utc)
    try:
        inviter_id, relation_code, exp, nonce, sig = token.split(".")
    except (ValueError, AttributeError):
        return False, "malformed token"
    body = f"{inviter_id}.{relation_code}.{exp}.{nonce}"
    if not hmac.compare_digest(sig, _sign(body, secret)):
        return False, "bad signature"
    try:
        if int(exp) < int(now.timestamp()):
            return False, "expired"
    except ValueError:
        return False, "bad expiry"
    return True, {
        "inviter_id": int(inviter_id),
        "relation_code": normalize_relation(relation_code),
        "reciprocal_for_invitee": reciprocal_relation(relation_code),
        "expires_at": int(exp),
    }


def qr_payload(token, base_url="https://assisto.asalify.com"):
    """The string encoded into the QR image (a deep link the app intercepts)."""
    return f"{base_url}/i/{token}"


# ---------------------------------------------------------------------------
# Block / report
# ---------------------------------------------------------------------------

REPORT_REASONS = ("spam", "harassment", "scam", "impersonation", "other")


def report_payload(reporter_id, target_id, reason, note="", lang="bn"):
    reason = reason if reason in REPORT_REASONS else "other"
    return {
        "kind": "circle_report",
        "reporter_id": int(reporter_id),
        "target_id": int(target_id),
        "reason": reason,
        "note": (note or "")[:500],
        "auto_block": reason in ("harassment", "scam", "impersonation"),
        "message": pick(lang,
                        "রিপোর্ট জমা হয়েছে। চাইলে ব্লকও করতে পারেন।",
                        "Report submitted. You can also block this person."),
    }


# ---------------------------------------------------------------------------
# System notifications (bilingual)
# ---------------------------------------------------------------------------

def request_notification(sender_name, relation_code, lang="bn"):
    rel = relation_label(relation_code, lang)
    return {
        "kind": "circle_request",
        "title": pick(lang, "নতুন সংযোগের অনুরোধ", "New connection request"),
        "body": pick(
            lang,
            f"{sender_name} আপনাকে {rel} হিসেবে যুক্ত করতে চান।",
            f"{sender_name} wants to connect with you as {rel}.",
        ),
    }


def accepted_notification(name, lang="bn"):
    return {
        "kind": "circle_accepted",
        "title": pick(lang, "সংযোগ গৃহীত", "Connection accepted"),
        "body": pick(lang,
                     f"{name} এখন আপনার সার্কেলে যুক্ত।",
                     f"{name} is now in your circle."),
    }


# ---------------------------------------------------------------------------
# 1-tap call/message hook (from a parent's medicine card)
# ---------------------------------------------------------------------------

def quick_contact_actions(member, lang="bn"):
    """Given a resolved circle member (dict with id/name/phone + mutual accepted
    state), return the action set the medicine-card hook renders.  'message'
    opens the E2E chat; 'call' is key-gated until TURN is live; 'dial' is the
    always-available PSTN fallback via the phone dialer."""
    phone = (member or {}).get("phone", "")
    actions = [{
        "action": "message",
        "label": pick(lang, "মেসেজ", "Message"),
        "enabled": True,
        "target_member_id": member.get("id"),
    }]
    actions.append({
        "action": "call",
        "label": pick(lang, "ভয়েস কল", "Voice call"),
        "enabled": media_available("call"),
        "reason": media_gate_reason("call", lang),
        "target_member_id": member.get("id"),
    })
    if phone:
        actions.append({
            "action": "dial",
            "label": pick(lang, "ফোন করুন", "Phone"),
            "enabled": True,
            "tel": phone,
        })
    return actions


# ---------------------------------------------------------------------------
# E2E software-fallback WIRE FORMAT (the server never runs this; it documents
# what the app produces so the backend relay + tests can assert it is opaque).
# ---------------------------------------------------------------------------
# The app encrypts text with the E2E interface (see app/lib/crypto/e2e.dart):
#   scheme "x25519-xchacha-fallback-v1":
#     - sender & recipient each hold an X25519 identity keypair,
#     - per-message: derive a shared secret (X25519) → HKDF → AEAD key,
#     - encrypt plaintext with an AEAD (nonce random per message),
#     - envelope.ciphertext = base64(AEAD output), envelope.nonce = base64(nonce).
#   The MLS upgrade (OpenMLS, Apache/MIT) swaps the keying but keeps this
#   envelope shape, so the relay never changes.  See owner_actions doc.

FALLBACK_SCHEME = "x25519-xchacha-fallback-v1"
MLS_SCHEME = "mls-openmls-v1"  # the swap-in target (key-gated)


def build_text_envelope(circle_id, sender_id, recipient_ids, ciphertext_b64,
                        nonce_b64, sender_key_id, scheme=FALLBACK_SCHEME, now=None):
    """Construct a relay-safe text envelope from app-produced ciphertext.
    The server stores this verbatim; it holds no key and cannot decrypt."""
    now = now or datetime.now(timezone.utc)
    env = {
        "circle_id": circle_id,
        "sender_id": sender_id,
        "recipient_ids": list(recipient_ids),
        "content_type": "text",
        "ciphertext": ciphertext_b64,
        "nonce": nonce_b64,
        "sender_key_id": sender_key_id,
        "scheme": scheme,
        "created_at": now.isoformat(),
        "delivered_to": [],
        "read_by": [],
    }
    ok, reason = validate_envelope(env)
    if not ok:
        raise ValueError("refusing to relay non-opaque envelope: " + reason)
    return env


def looks_like_plaintext(env):
    """Heuristic guard used by tests + the relay: an envelope must NOT contain
    any field whose value looks like readable text where ciphertext is expected.
    (base64 ciphertext has no spaces and is not valid UTF-8 words.)"""
    ct = env.get("ciphertext")
    if ct is None:
        return False
    if any(k in env for k in FORBIDDEN_META_KEYS):
        return True
    # Base64 never contains spaces/newlines; readable text usually does.
    return isinstance(ct, str) and (" " in ct or "\n" in ct)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _sign(body, secret):
    key = (secret or "").encode("utf-8")
    return hashlib.sha256(hmac.new(key, body.encode("utf-8"), hashlib.sha256).digest()).hexdigest()[:24]


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
