"""
msg_contacts.py — Assisto Messenger "Contacts & Invites" + personal connection
request logic (Phase B, Step 3).  Pure Python, deterministic, unit-testable.
NO Django, NO AI key.  Builds ON TOP of core.logic.circle (relationship vocab,
request state machine, the 2b fix, block/report) — never duplicates it.

THE PRIVACY CONTRACT (owner-specified, PLAY-COMPLIANT, enforced here):
  - PHONE NUMBERS OF NON-USERS NEVER REACH THE SERVER.  Contact matching is done
    over SALTED HASHES computed ON THE DEVICE.  `match_contacts` takes hashes,
    returns which ones belong to registered users, and KEEPS NOTHING — it is a
    pure function with no storage side effect.  A non-user's hash that doesn't
    match is simply dropped on return; the server is told to persist nothing.
  - Contact access is EXPLICIT-PERMISSION gated (a flag the client must pass,
    reflecting a granted OS contacts permission + an in-app consent).  Without
    it, matching refuses — no hashes are even looked at.
  - NO SMS/WhatsApp gateway.  Inviting a non-user produces either a SHARE-LINK
    descriptor (shared via any app the user picks) or an OWN-SIM SMS descriptor
    (a prefilled `sms:` URI the user presses send on in their own SMS app — no
    SEND_SMS permission, no server gateway, never auto-sent).
  - A PERSONAL CONNECTION REQUEST reuses circle.py request/accept semantics:
    relationship is MANDATORY (no proof), the requester may attach exactly ONE
    text note, and BEFORE acceptance there are NO calls and NO further messages
    (only that one note is allowed through).  A configurable DAILY REQUEST LIMIT
    is enforced.  Block/report ride on the request via circle.report_payload.

WHAT LIVES HERE (logic/state only — DB models + HTTP endpoints are the
integrator's; see .phaseB/msg_contacts_integration.md):
  - The client hashing contract (algorithm + salt handling) + the server-side
    matcher that stores nothing.
  - Invite descriptors: in-app (existing user), share-link + own-SIM-SMS
    (non-user).  FCM push when a key is present, else "shown on next open".
  - Personal connection request builder + the pre-accept gate (one note, zero
    further messages, no calls) + the daily-limit check.

Run self-tests (no DB):
    python3 -c "import core.logic.msg_contacts_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

import hashlib
import hmac
from datetime import datetime, timedelta, timezone

from core.logic.circle import (
    REQ_ACCEPTED,
    REQ_PENDING,
    can_act_on_request,
    is_circle_member,
    normalize_direction,
    normalize_relation,
    pick,
    reciprocal_relation,
    relation_label,
    report_payload,
    request_actions,
)


# ---------------------------------------------------------------------------
# TUNABLE CONSTANTS  —  OWNER TO REVIEW (clearly marked)
# ---------------------------------------------------------------------------
# !!! POLICY — OWNER REVIEW REQUIRED !!!

# Max NEW personal connection requests one user may SEND in a rolling 24h.
# Anti-spam: a stranger cannot blast requests.  Enforced + tested.
DAILY_REQUEST_LIMIT = 20  # OWNER REVIEW

# The ONE pre-accept note length cap (a request may carry a single short note).
REQUEST_NOTE_MAX = 280  # OWNER REVIEW


# ---------------------------------------------------------------------------
# HASHED CONTACT MATCH — the device-side hashing contract
# ---------------------------------------------------------------------------
# The server never sees raw phone numbers of NON-users.  To find which of a
# user's phone contacts are on Assisto, the CLIENT:
#   1. normalizes each contact number to E.164 (+<country><number>, digits only
#      after the leading '+'), using the device SIM region for local numbers,
#   2. computes  hash = HMAC-SHA256( key = SERVER_MATCH_SALT, msg = e164 )  and
#      hex-encodes it, truncated to HASH_HEX_LEN chars,
#   3. uploads ONLY the batch of hashes (+ the permission flag), never numbers.
# The server holds the SAME salted hash for every REGISTERED user's verified
# phone (computed once at signup/verify with the identical contract).  Matching
# is a set intersection over hashes; unmatched hashes reveal nothing and are
# discarded.  The salt is a server-wide secret (NOT per-user) so the same number
# hashes identically on every device — that is what makes the intersection work;
# it is a secret only to raise the cost of an offline dictionary attack on the
# (already large) phone-number space, not a per-user key.

HASH_ALGO = "hmac-sha256"
HASH_HEX_LEN = 32  # 128 bits of the digest — ample, keeps payloads small
HASH_CONTRACT_VERSION = "v1"


def normalize_e164(raw, default_cc="880"):
    """Best-effort E.164 normalization used by BOTH the client (at match time)
    and the server (at phone-verify time) so the same number hashes identically.
    Bangladesh default country code 880.  This is the reference implementation
    the client mirrors; it is intentionally conservative (digits only).

    Rules:
      - strip everything but digits and a leading '+',
      - '+8801...' / '8801...' -> '+8801...',
      - local '01XXXXXXXXX' (11 digits) -> '+880' + drop leading 0,
      - already '+<cc>...' kept as-is.
    Returns "" for anything that cannot be made into a plausible number.
    """
    s = (raw or "").strip()
    if not s:
        return ""
    plus = s.startswith("+")
    digits = "".join(ch for ch in s if ch.isdigit())
    if not digits:
        return ""
    if plus:
        return "+" + digits
    # bare international already carrying the country code
    if digits.startswith(default_cc):
        return "+" + digits
    # local national number starting with a trunk 0 (e.g. BD 01XXXXXXXXX)
    if digits.startswith("0"):
        return "+" + default_cc + digits[1:]
    # otherwise assume it already omits the +; prepend default cc
    return "+" + default_cc + digits


def hash_phone(e164, salt):
    """THE hashing primitive (client + server use the identical call).  Takes an
    ALREADY-normalized E.164 string and the server-wide match salt; returns the
    truncated hex HMAC-SHA256 digest.  Deterministic, no storage."""
    key = (salt or "").encode("utf-8")
    msg = (e164 or "").encode("utf-8")
    full = hmac.new(key, msg, hashlib.sha256).hexdigest()
    return full[:HASH_HEX_LEN]


def hash_contacts_clientside(raw_numbers, salt, default_cc="880"):
    """REFERENCE of what the CLIENT runs before upload: normalize + hash every
    raw number, de-duplicated, dropping un-normalizable entries.  The raw numbers
    never leave this function's caller (the device).  Returns the list of hashes
    the client would upload.  Provided here so tests can prove the server matcher
    agrees with the documented client contract."""
    seen = set()
    out = []
    for raw in (raw_numbers or []):
        e164 = normalize_e164(raw, default_cc=default_cc)
        if not e164:
            continue
        h = hash_phone(e164, salt)
        if h in seen:
            continue
        seen.add(h)
        out.append(h)
    return out


def match_contacts(contact_hashes, registered_hash_to_user, *,
                   permission_granted):
    """SERVER-SIDE matcher.  PRIVACY-CRITICAL + STORES NOTHING.

    Args:
      contact_hashes: the batch of salted hashes the client uploaded (NEVER raw
        numbers).  Order/duplicates tolerated.
      registered_hash_to_user: {salted_phone_hash: public_user_descriptor} the
        server already holds for VERIFIED registered users (built once at
        signup/verify using the identical hashing contract).  A dict lookup only.
      permission_granted: the explicit-permission flag (OS contacts permission +
        in-app consent).  Play-compliant gate — if False we refuse and look at
        nothing.

    Returns a dict:
      {"ok": bool, "reason": str,
       "matches": [ {"contact_hash": h, "user": <descriptor>}, ... ],
       "matched_count": int, "checked": int,
       "stored": False}      # <-- the function keeps NOTHING; the caller must
                             #     not persist contact_hashes or non-matches.

    A hash that is NOT a registered user is simply absent from `matches` — it is
    never written anywhere, satisfying "NEVER store non-users' numbers/hashes".
    """
    if not permission_granted:
        return {"ok": False, "reason": "permission_required",
                "matches": [], "matched_count": 0, "checked": 0,
                "stored": False}

    reg = registered_hash_to_user or {}
    matches = []
    seen = set()
    checked = 0
    for h in (contact_hashes or []):
        if not h or h in seen:
            continue
        seen.add(h)
        checked += 1
        user = reg.get(h)
        if user is not None:
            matches.append({"contact_hash": h, "user": user})
        # a NON-match falls through: nothing is recorded, nothing stored.

    return {
        "ok": True,
        "reason": "ok",
        "matches": matches,
        "matched_count": len(matches),
        "checked": checked,
        "stored": False,  # explicit contract: this call persisted nothing
    }


def hashing_contract(base_url="https://assisto.asalify.com"):
    """Machine-readable statement of the client hashing contract (also rendered
    into the integration doc).  The client reads this at build time to stay in
    lockstep with the server matcher."""
    return {
        "version": HASH_CONTRACT_VERSION,
        "algorithm": HASH_ALGO,                 # HMAC-SHA256
        "key": "server_wide_match_salt",        # NOT per-user; a server secret
        "input": "e164_normalized_phone",       # see normalize_e164
        "default_country_code": "880",
        "hex_length": HASH_HEX_LEN,
        "upload_contains": ["salted_hashes", "permission_flag"],
        "upload_never_contains": ["raw_numbers", "names", "non_user_hashes_stored"],
        "server_stores": "only verified-user phone hashes (computed at signup/verify)",
        "non_user_retention": "none",           # matcher keeps nothing
        "deep_link_base": base_url,
    }


# ---------------------------------------------------------------------------
# INVITE descriptors
# ---------------------------------------------------------------------------
# Three channels, all PLAY-COMPLIANT and never auto-sending:
#   - existing user  -> IN-APP invite (FCM push if key present, else next-open).
#   - non-user       -> SHARE-LINK descriptor (user shares via any app) OR
#                       OWN-SIM-SMS descriptor (prefilled sms: URI, user sends).
#
# A descriptor is a plain dict the endpoint returns to the client, which then
# performs the channel action (open share sheet / open SMS app / enqueue push).
# This module NEVER sends anything itself.

CHANNEL_IN_APP = "in_app"
CHANNEL_SHARE_LINK = "share_link"
CHANNEL_SMS_OWN_SIM = "sms_own_sim"


def invite_existing_user(from_name, to_user_id, relation_code, *,
                         fcm_available=False, lang="bn", custom_label=""):
    """Invite a person who is ALREADY an Assisto user → an in-app invite that
    lands in their requests.  If an FCM key is configured the integrator pushes
    it; otherwise it is simply shown on the recipient's next app open.  Returns
    the descriptor (the actual request row is built by
    `build_connection_request`; this is the *delivery* descriptor)."""
    rel_lbl = relation_label(relation_code, lang, custom_label)
    return {
        "channel": CHANNEL_IN_APP,
        "to_user_id": int(to_user_id),
        "relation": normalize_relation(relation_code),
        "relation_label": rel_lbl,
        "delivery": "fcm_push" if fcm_available else "on_next_open",
        "fcm_available": bool(fcm_available),
        "title": pick(lang, "নতুন সংযোগের অনুরোধ", "New connection request"),
        "body": pick(
            lang,
            f"{from_name} আপনাকে {rel_lbl} হিসেবে যুক্ত করতে চান।",
            f"{from_name} wants to connect with you as {rel_lbl}.",
        ),
        "auto_sent": False,
    }


def _invite_message_text(from_name, link, lang):
    """The prefilled body used by both share + SMS descriptors (bilingual, the
    user can edit before sending — we never auto-send)."""
    return pick(
        lang,
        f"{from_name} আপনাকে Assisto Messenger-এ যুক্ত হতে আমন্ত্রণ জানিয়েছেন। "
        f"ইনস্টল করুন: {link}",
        f"{from_name} invited you to connect on Assisto Messenger. "
        f"Install: {link}",
    )


def invite_non_user_share_link(from_name, invite_link, *, lang="bn"):
    """Invite a NON-user via a SHARE-LINK → a descriptor the client feeds to the
    OS share sheet so the user picks any app (WhatsApp/SMS/email/etc.).  No
    gateway, no auto-send; the user chooses the app and presses send there."""
    return {
        "channel": CHANNEL_SHARE_LINK,
        "share_text": _invite_message_text(from_name, invite_link, lang),
        "link": invite_link,
        "subject": pick(lang, "Assisto Messenger আমন্ত্রণ",
                        "Assisto Messenger invite"),
        "opens": "os_share_sheet",
        "auto_sent": False,
    }


def invite_non_user_sms(from_name, invite_link, to_number, *, lang="bn"):
    """Invite a NON-user via the user's OWN SIM → a descriptor carrying a
    prefilled `sms:` URI.  The client opens the device SMS composer pre-filled;
    the USER presses send.  No SEND_SMS permission is requested and no gateway is
    used — the message goes through the user's own SIM only.  `to_number` is the
    user's OWN contact (it never left the device for matching; here the user is
    explicitly choosing to text a known person), so building a sms: URI is fine.
    """
    body = _invite_message_text(from_name, invite_link, lang)
    # sms: URI with a prefilled body (RFC 5724 style; the '?body=' is honored by
    # Android/iOS SMS composers).  The client URL-encodes the body.
    sms_uri = f"sms:{(to_number or '').strip()}?body=" + _uri_encode(body)
    return {
        "channel": CHANNEL_SMS_OWN_SIM,
        "sms_uri": sms_uri,
        "to_number": (to_number or "").strip(),
        "body": body,
        "link": invite_link,
        "requires_send_sms_permission": False,  # opens composer; user sends
        "uses_gateway": False,
        "opens": "device_sms_composer",
        "auto_sent": False,
    }


def _uri_encode(s):
    """Minimal percent-encoding for a sms: body (space + a few reserved chars).
    The client does the full job with the platform encoder; this keeps the pure
    module dependency-free and the descriptor inspectable in tests."""
    out = []
    safe = "-_.~"
    for ch in (s or ""):
        if ch.isalnum() or ch in safe:
            out.append(ch)
        else:
            for b in ch.encode("utf-8"):
                out.append(f"%{b:02X}")
    return "".join(out)


# ---------------------------------------------------------------------------
# PERSONAL CONNECTION REQUEST — mandatory relationship, ONE note, pre-accept gate
# ---------------------------------------------------------------------------
# Reuses circle.py request/accept semantics (and the 2b fix via
# can_act_on_request / request_actions / is_circle_member).  A personal request:
#   - MUST carry a relationship (no proof needed, but it cannot be blank),
#   - MAY carry exactly ONE text note (length-capped),
#   - BEFORE acceptance: no calls, no further messages — ONLY the single note is
#     allowed to reach the recipient.  can_send_before_accept enforces this.
#   - Is subject to the DAILY REQUEST LIMIT (anti-spam).

# refusal codes
ERR_RELATION_REQUIRED = "relation_required"
ERR_DAILY_LIMIT = "daily_request_limit_reached"
ERR_SELF_REQUEST = "self_request"
OK = "ok"


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


def requests_sent_last_24h(sent_log, now=None):
    """Count requests this user SENT in the rolling 24h window.  `sent_log` is a
    list of {created_at} rows (the integrator passes the requester's recent sent
    requests).  Pure; the window is relative to `now`."""
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=24)
    n = 0
    for r in (sent_log or []):
        dt = _as_dt(r.get("created_at") if isinstance(r, dict) else r)
        if dt is not None and dt > cutoff:
            n += 1
    return n


def can_send_request(requester_id, target_id, relation_code, *,
                     sent_log=None, now=None, daily_limit=DAILY_REQUEST_LIMIT):
    """SERVER AUTHORIZATION GUARD for sending a personal connection request.
    Returns (ok, code).  Enforces, independent of client:
      - relationship is MANDATORY (blank/unknown-blank ⇒ refuse),
      - no self-request,
      - the DAILY REQUEST LIMIT on NEW sent requests (the N+1 is blocked)."""
    if requester_id == target_id:
        return False, ERR_SELF_REQUEST
    # relationship mandatory — a blank/empty code is rejected before it is
    # normalized to 'custom'.  (normalize_relation would otherwise hide a blank.)
    if not (relation_code or "").strip():
        return False, ERR_RELATION_REQUIRED
    if requests_sent_last_24h(sent_log, now=now) >= daily_limit:
        return False, ERR_DAILY_LIMIT
    return True, OK


def build_connection_request(requester_id, target_id, relation_code, *,
                             note="", sent_log=None, now=None,
                             daily_limit=DAILY_REQUEST_LIMIT, custom_label="",
                             lang="bn"):
    """Build a PENDING personal connection request row after the guard passes.
    Returns {"ok": bool, "code": str, "request": <row or None>}.

    The row reuses circle.py's request shape (state=pending, relation,
    custom_label, note) so serialize_request / can_act_on_request / the 2b fix
    all apply unchanged.  The note is capped to ONE note of REQUEST_NOTE_MAX; the
    pre-accept gate (can_send_before_accept) then forbids any further message."""
    now = now or datetime.now(timezone.utc)
    ok, code = can_send_request(
        requester_id, target_id, relation_code,
        sent_log=sent_log, now=now, daily_limit=daily_limit,
    )
    if not ok:
        return {"ok": False, "code": code, "request": None}

    rel = normalize_relation(relation_code)
    row = {
        "requester_id": int(requester_id),
        "target_id": int(target_id),
        "relation": rel,
        "reciprocal_relation": reciprocal_relation(rel),
        "custom_label": (custom_label or "").strip(),
        # the ONE optional pre-accept note (empty string if none)
        "note": (note or "")[:REQUEST_NOTE_MAX],
        "note_used": bool((note or "").strip()),  # one-note budget consumed?
        "state": REQ_PENDING,
        "created_at": now.isoformat(),
        # direction is relative to the viewer; stored neutrally, the serializer
        # sets 'outgoing' for the requester and 'incoming' for the target.
    }
    return {"ok": True, "code": OK, "request": row}


def can_send_before_accept(request_state, note_already_used, is_note, is_call):
    """THE PRE-ACCEPT GATE.  Returns (allowed, reason_code).  Before the request
    is ACCEPTED:
      - calls are NEVER allowed,
      - messages are NEVER allowed, EXCEPT the single attached note, and only if
        the one-note budget has not already been used,
    After acceptance this gate steps aside (messaging/calls flow through the
    normal circle gates).  This is the server's enforcement of
    'before acceptance no calls + no further messages (only the one note)'."""
    if request_state == REQ_ACCEPTED:
        return True, "accepted"  # normal gates take over post-accept
    # pre-accept:
    if is_call:
        return False, "no_calls_before_accept"
    if is_note:
        if note_already_used:
            return False, "note_budget_exhausted"  # only ONE note allowed
        return True, "one_note"
    # any OTHER message before accept is forbidden
    return False, "no_messages_before_accept"


def pre_accept_message_count_ok(messages_before_accept):
    """Invariant check the relay can assert: at most ONE author message may exist
    from the requester before acceptance (the single note).  `messages_before_
    accept` is the list of requester-authored items prior to accept.  Returns
    True iff 0 or 1."""
    return len(messages_before_accept or []) <= 1


def act_on_connection_request(direction, event):
    """Pass-through to circle.can_act_on_request so personal requests obey the
    SAME 2b-fix semantics: sender(outgoing)=cancel/block only, never
    accept/decline their own; receiver(incoming)=accept/decline/block.  Returns
    (allowed, reason)."""
    return can_act_on_request(direction, event)


def connection_request_actions(direction):
    """The action buttons for a pending personal request (reuses circle):
    outgoing ⇒ ['cancel'], incoming ⇒ ['accept','decline']."""
    return request_actions(direction)


def is_connected(state):
    """A personal connection exists ONLY once ACCEPTED (reuses circle rule)."""
    return is_circle_member(state)


def block_or_report_on_request(reporter_id, target_id, *, action="report",
                               reason="harassment", note="", lang="bn"):
    """Block/report RIDING ON a connection request (reuses circle.report_payload
    for report; block is a simple directive the integrator persists).  `action`
    ∈ {'report','block','report_and_block'}.  Returns the directive dict."""
    out = {"kind": "connection_request_action", "action": action,
           "target_id": int(target_id), "reporter_id": int(reporter_id)}
    if action in ("report", "report_and_block"):
        out["report"] = report_payload(reporter_id, target_id, reason, note, lang)
    if action in ("block", "report_and_block") or (
        action == "report" and out.get("report", {}).get("auto_block")
    ):
        out["block"] = True
        out["block_message"] = pick(lang, "ব্লক করা হয়েছে।", "Blocked.")
    else:
        out["block"] = out.get("block", False)
    return out


# ---------------------------------------------------------------------------
# UI strings bundle (bilingual) — handy for the endpoint; mirrors the arb file
# ---------------------------------------------------------------------------

def strings(lang="bn"):
    return {
        "contacts_permission": pick(
            lang,
            "পরিচিতদের খুঁজে পেতে কন্টাক্ট অনুমতি দিন। আমরা শুধু মিল যাচাই করি, "
            "নম্বর সার্ভারে রাখি না।",
            "Allow contacts to find people you know. We only match — numbers are "
            "never stored on our server.",
        ),
        "invite_existing": pick(lang, "অ্যাপে আমন্ত্রণ পাঠান",
                                "Send in-app invite"),
        "invite_share": pick(lang, "লিংক শেয়ার করুন", "Share invite link"),
        "invite_sms": pick(lang, "নিজের সিম থেকে SMS", "SMS from your SIM"),
        "request_note_hint": pick(lang, "একটি সংক্ষিপ্ত নোট (ঐচ্ছিক)",
                                  "One short note (optional)"),
        "daily_limit_reached": pick(
            lang, "আজকের অনুরোধ সীমা শেষ। পরে আবার চেষ্টা করুন।",
            "Daily request limit reached. Try again later."),
        "relation_required": pick(lang, "সম্পর্ক নির্বাচন করুন।",
                                  "Please choose a relationship."),
        "no_message_before_accept": pick(
            lang, "গৃহীত হওয়ার আগে শুধু একটি নোট পাঠানো যাবে।",
            "Only one note can be sent before the request is accepted."),
    }
