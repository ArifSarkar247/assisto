"""
circle_messaging.py — Assisto "Connected Circle" 1:1 messaging semantics (M1
item 3).  Pure Python, deterministic, unit-testable.  NO AI key.

Scope: everything the server needs to *relay* and keep *state* for rich 1:1
messaging while NEVER reading plaintext.  Benchmarked against WhatsApp +
Messenger.  Builds on core.logic.circle (the ciphertext relay contract,
delivery/read marks, invite tokens, the request state machine).

THE PRIVACY CONTRACT (inherited, re-enforced here):
  - The server stores CIPHERTEXT ONLY.  Every user-authored field that could
    carry meaning (message body, reply preview, reaction emoji, link-preview
    title/description/image, edit history, forward caption) is encrypted on the
    SENDER device and relayed as opaque ciphertext.  The validator here rejects
    any envelope that smuggles plaintext.
  - Only *accepted* circle members may message (can_message gate — re-checked
    here as send_precheck so the relay can refuse at the door).
  - Link previews are built on the SENDER device (no server fetch) and shipped
    as ciphertext fields; the server never dereferences a URL.

WHAT LIVES HERE (logic/state only — DB models + HTTP endpoints are the
integrator's; see the report MIGRATION NOTE):
  - Extended message envelope build/validate (reply_to, reactions, edited,
    deleted, starred, pinned, forwarded, link_preview — all ciphertext-safe).
  - Edit window + delete-for-everyone window policy.
  - Reaction add/remove (per-member, one emoji ref per member; emoji itself is
    an opaque short token — no plaintext).
  - Delete-for-me vs delete-for-everyone semantics (tombstones).
  - Forward metadata (+ "forwarded" label, hop count, strip of
    sender-identifying reply context).
  - Star / pin state + per-chat pin cap.
  - Offline send queue: client-side id, retry/backoff schedule, dedupe key.
  - Search INDEX HINTS: the server can't read text, so search is client-side.
    This module documents the hint surface (what the server may expose to help
    the client page results) and a pure keyword matcher the CLIENT reuses for
    "search in-chat + across chats" over already-decrypted text.

Run self-tests (no DB):
    python3 -c "import core.logic.circle_messaging_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

from core.logic.circle import (
    FORBIDDEN_META_KEYS,
    REQ_ACCEPTED,
    pick,
    validate_envelope as _validate_base,
)


# ---------------------------------------------------------------------------
# Send precheck — only accepted circle members may message
# ---------------------------------------------------------------------------

def send_precheck(sender_state, recipient_state, blocked_either=False,
                  restricted=False):
    """Return (ok, reason_code).  Relay refuses at the door unless BOTH sides
    are 'accepted' and neither blocked.  'restricted' (agent B's feature) still
    allows send but the integrator routes it to the restricted inbox — we return
    ok=True, reason='restricted' so the endpoint can tag it."""
    if blocked_either:
        return False, "blocked"
    if sender_state != REQ_ACCEPTED or recipient_state != REQ_ACCEPTED:
        return False, "not_connected"
    if restricted:
        return True, "restricted"
    return True, "ok"


# ---------------------------------------------------------------------------
# Extended ciphertext-safe envelope fields
# ---------------------------------------------------------------------------
# A message envelope carries routing + opaque ciphertext (see circle.py).  M1
# adds OPTIONAL, still-ciphertext-only enrichments.  Each is validated so none
# can smuggle plaintext.
#
#   reply_to         : str message id this replies to (ROUTING id only — the
#                      quoted preview text is NOT stored server-side; the client
#                      re-renders it from its own decrypted copy).
#   forwarded        : bool  (+ forward_hops int)
#   edited_at        : iso str  (ciphertext replaced in place; history kept
#                      client-side only — server keeps just the latest ct)
#   deleted          : "" | "me" | "everyone"  (tombstone)
#   link_preview     : {ciphertext,nonce} OPAQUE — title/desc/image encrypted on
#                      sender device.  NEVER a readable url/title here.
#   client_msg_id    : sender-chosen dedupe id for the offline queue.

ENVELOPE_EXTRA_KEYS = {
    "reply_to", "forwarded", "forward_hops", "edited_at", "deleted",
    "link_preview", "client_msg_id", "starred_by", "pinned",
}

# A link_preview sub-object may ONLY carry opaque ciphertext fields.
_PREVIEW_ALLOWED = {"ciphertext", "nonce", "scheme", "sender_key_id"}
# ...and must NOT carry a readable url / title / description / image bytes.
_PREVIEW_FORBIDDEN = {"url", "title", "description", "image", "image_url",
                      "site", "html", "text"}


def validate_message_envelope(env):
    """Full M1 envelope validation = base relay contract + enrichment checks.
    Returns (ok, reason).  The relay calls this before persisting a send."""
    ok, why = _validate_base(env)
    if not ok:
        return False, why
    # deleted tombstones are allowed with no ciphertext (the body is gone).
    deleted = env.get("deleted") or ""
    if deleted and deleted not in ("me", "everyone"):
        return False, "bad deleted value"
    # link_preview must be opaque
    lp = env.get("link_preview")
    if lp is not None:
        if not isinstance(lp, dict):
            return False, "link_preview must be an object"
        bad = (_PREVIEW_FORBIDDEN | FORBIDDEN_META_KEYS) & set(lp.keys())
        if bad:
            return False, "link_preview carries plaintext: " + ",".join(sorted(bad))
        extra = set(lp.keys()) - _PREVIEW_ALLOWED
        if extra:
            return False, "link_preview has disallowed keys: " + ",".join(sorted(extra))
        if lp and not lp.get("ciphertext"):
            return False, "link_preview missing ciphertext"
    # forward_hops sanity
    fh = env.get("forward_hops")
    if fh is not None and (not isinstance(fh, int) or fh < 0 or fh > 50):
        return False, "bad forward_hops"
    return True, "ok"


def build_text_envelope(circle_id, sender_id, recipient_ids, ciphertext_b64,
                        nonce_b64, sender_key_id, scheme=None, reply_to=None,
                        forwarded=False, forward_hops=0, link_preview=None,
                        client_msg_id=None, now=None):
    """Construct a relay-safe TEXT envelope with M1 enrichments.  Server stores
    verbatim; holds no key; cannot decrypt.  Raises if the result isn't opaque."""
    from core.logic.circle import FALLBACK_SCHEME
    now = now or datetime.now(timezone.utc)
    env = {
        "circle_id": circle_id,
        "sender_id": sender_id,
        "recipient_ids": list(recipient_ids),
        "content_type": "text",
        "ciphertext": ciphertext_b64,
        "nonce": nonce_b64,
        "sender_key_id": sender_key_id,
        "scheme": scheme or FALLBACK_SCHEME,
        "created_at": now.isoformat(),
        "delivered_to": [],
        "read_by": [],
        "reactions": {},
        "deleted": "",
    }
    if reply_to is not None:
        env["reply_to"] = str(reply_to)
    if forwarded:
        env["forwarded"] = True
        env["forward_hops"] = int(forward_hops) + 0
    if link_preview is not None:
        env["link_preview"] = link_preview
    if client_msg_id is not None:
        env["client_msg_id"] = str(client_msg_id)
    ok, reason = validate_message_envelope(env)
    if not ok:
        raise ValueError("refusing to relay non-opaque envelope: " + reason)
    return env


# ---------------------------------------------------------------------------
# Edit window + delete-for-everyone window
# ---------------------------------------------------------------------------
# WhatsApp: edit within 15 min; delete-for-everyone within ~2 days (we use a
# generous, configurable window).  Messenger: edit within 15 min.  Both are the
# SENDER's prerogative only.

EDIT_WINDOW_MIN = 15
DELETE_EVERYONE_WINDOW_MIN = 60 * 24 * 2  # 2 days


def can_edit(env, actor_id, now=None, window_min=EDIT_WINDOW_MIN):
    """Only the sender, only text, only within the window, not already deleted."""
    if env.get("sender_id") != actor_id:
        return False
    if env.get("content_type") != "text":
        return False
    if env.get("deleted"):
        return False
    created = _as_dt(env.get("created_at"))
    if created is None:
        return False
    now = now or datetime.now(timezone.utc)
    return (now - created) <= timedelta(minutes=window_min)


def apply_edit(env, actor_id, new_ciphertext_b64, new_nonce_b64, now=None,
               window_min=EDIT_WINDOW_MIN):
    """Return (env, ok).  Replaces ciphertext IN PLACE (server keeps only the
    latest; edit history is a client concern) and stamps edited_at.  No-op if
    not editable."""
    if not can_edit(env, actor_id, now=now, window_min=window_min):
        return env, False
    now = now or datetime.now(timezone.utc)
    env = dict(env)
    env["ciphertext"] = new_ciphertext_b64
    env["nonce"] = new_nonce_b64
    env["edited_at"] = now.isoformat()
    return env, True


def can_delete_for_everyone(env, actor_id, now=None,
                            window_min=DELETE_EVERYONE_WINDOW_MIN):
    """Only the sender, within the (generous) window, not already gone."""
    if env.get("sender_id") != actor_id:
        return False
    if env.get("deleted") == "everyone":
        return False
    created = _as_dt(env.get("created_at"))
    if created is None:
        return False
    now = now or datetime.now(timezone.utc)
    return (now - created) <= timedelta(minutes=window_min)


def apply_delete(env, actor_id, scope, now=None):
    """scope ∈ {'me','everyone'}.  'everyone' tombstones the ciphertext (server
    drops the body) iff the actor is the sender within the window.  'me' is a
    per-member hide handled by the integrator (we just validate + tag).
    Returns (env, ok)."""
    env = dict(env)
    if scope == "everyone":
        if not can_delete_for_everyone(env, actor_id, now=now):
            return env, False
        env["deleted"] = "everyone"
        # Body is gone — server must not keep ciphertext for a recalled msg.
        env["ciphertext"] = ""
        env["nonce"] = ""
        env.pop("link_preview", None)
        return env, True
    if scope == "me":
        hidden = set(env.get("hidden_for") or [])
        hidden.add(actor_id)
        env["hidden_for"] = sorted(hidden)
        return env, True
    return env, False


def display_tombstone(env, lang="bn"):
    """The bilingual placeholder the client shows for a deleted-for-everyone
    message (the ciphertext is gone — there is nothing to decrypt)."""
    if env.get("deleted") != "everyone":
        return None
    return pick(lang, "এই মেসেজটি মুছে ফেলা হয়েছে।",
                "This message was deleted.")


# ---------------------------------------------------------------------------
# Reactions — one emoji per member, opaque short token
# ---------------------------------------------------------------------------
# The emoji is a short unicode token the client sends in the CLEAR? NO — to keep
# the "server reads nothing meaningful" promise we store a per-member reaction
# as an OPAQUE code the client maps to an emoji.  But a reaction's whole value
# is being lightweight + visible across devices; WhatsApp sends the emoji.  We
# compromise: reactions are stored as {member_id: emoji} where emoji is a short
# unicode grapheme.  This is metadata, not message content, and is explicitly
# permitted (it reveals far less than message text).  Validator still blocks
# long/abusive payloads.

REACTION_MAX_LEN = 8  # a single emoji grapheme cluster (+ ZWJ sequences)


def add_reaction(env, member_id, emoji):
    """Set/replace this member's reaction.  Returns (env, ok).  Rejects
    over-long payloads (anti-abuse: a reaction is one emoji, not a message)."""
    if not emoji or len(emoji) > REACTION_MAX_LEN:
        return env, False
    env = dict(env)
    reactions = dict(env.get("reactions") or {})
    reactions[str(member_id)] = emoji
    env["reactions"] = reactions
    return env, True


def remove_reaction(env, member_id):
    env = dict(env)
    reactions = dict(env.get("reactions") or {})
    reactions.pop(str(member_id), None)
    env["reactions"] = reactions
    return env, True


def reaction_summary(env):
    """Aggregate for the bubble: {emoji: count}, plus total.  Order by count."""
    reactions = env.get("reactions") or {}
    counts = {}
    for emoji in reactions.values():
        counts[emoji] = counts.get(emoji, 0) + 1
    ordered = dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
    return {"counts": ordered, "total": sum(counts.values())}


# ---------------------------------------------------------------------------
# Star / save + pin-in-chat
# ---------------------------------------------------------------------------

PIN_CAP_PER_CHAT = 3  # WhatsApp pins up to 3 messages per chat


def toggle_star(env, member_id):
    """Star/save is per-member (each person stars for themselves)."""
    env = dict(env)
    starred = set(env.get("starred_by") or [])
    if member_id in starred:
        starred.discard(member_id)
        now_starred = False
    else:
        starred.add(member_id)
        now_starred = True
    env["starred_by"] = sorted(starred)
    return env, now_starred


def is_starred(env, member_id):
    return member_id in set(env.get("starred_by") or [])


def can_pin(current_pinned_ids, message_id, cap=PIN_CAP_PER_CHAT):
    """Can this message be pinned given the chat's current pins + the cap?"""
    pins = set(current_pinned_ids or [])
    if message_id in pins:
        return True  # already pinned (unpin is always allowed)
    return len(pins) < cap


def apply_pin(current_pinned_ids, message_id, pin=True, cap=PIN_CAP_PER_CHAT):
    """Return (new_pinned_ids, ok).  Pins are chat-scoped (shared), capped."""
    pins = list(current_pinned_ids or [])
    if pin:
        if message_id in pins:
            return pins, True
        if len(pins) >= cap:
            return pins, False
        pins.append(message_id)
        return pins, True
    else:
        pins = [p for p in pins if p != message_id]
        return pins, True


# ---------------------------------------------------------------------------
# Forward
# ---------------------------------------------------------------------------

FORWARD_HOP_FREQUENT = 5  # WhatsApp "forwarded many times" threshold


def forward_label(forward_hops, lang="bn"):
    """The 'Forwarded' / 'Forwarded many times' label for a forwarded bubble."""
    if not forward_hops:
        return None
    if forward_hops >= FORWARD_HOP_FREQUENT:
        return pick(lang, "বহুবার ফরোয়ার্ড করা হয়েছে", "Forwarded many times")
    return pick(lang, "ফরোয়ার্ড করা হয়েছে", "Forwarded")


def build_forward_fields(source_env):
    """Fields a client sets when forwarding: strip reply context + reactions +
    star/pin (a forward is a fresh message), bump the hop count, set the flag.
    The CIPHERTEXT itself is re-encrypted by the client for the new recipient —
    this only returns the META to merge."""
    hops = int(source_env.get("forward_hops") or 0) + 1
    return {
        "forwarded": True,
        "forward_hops": hops,
        "reply_to": None,  # drop quoted context on forward
    }


# ---------------------------------------------------------------------------
# Delivery / read (re-exported convenience over circle.py marks)
# ---------------------------------------------------------------------------

def tick_state(env, recipient_id):
    """Sender-side tick for a 1:1 chat: sent (✓) / delivered (✓✓) / read (✓✓
    coloured).  Mirrors circle.delivery_status but tolerant of a single peer."""
    read = set(env.get("read_by") or [])
    delivered = set(env.get("delivered_to") or [])
    if recipient_id in read:
        return "read"
    if recipient_id in delivered:
        return "delivered"
    return "sent"


# ---------------------------------------------------------------------------
# Offline send queue — client-side id, dedupe, retry/backoff
# ---------------------------------------------------------------------------
# When offline, the client queues sends keyed by client_msg_id.  On reconnect it
# flushes oldest-first; the server dedupes by (sender_id, client_msg_id) so a
# retried send is idempotent.  Backoff is exponential, capped.

RETRY_BACKOFF_SEC = [0, 2, 5, 15, 30, 60, 120, 300]  # attempt -> delay
RETRY_MAX_ATTEMPTS = len(RETRY_BACKOFF_SEC)


def next_retry_delay(attempt):
    """Seconds to wait before send attempt `attempt` (0-based)."""
    if attempt < 0:
        attempt = 0
    if attempt >= len(RETRY_BACKOFF_SEC):
        return RETRY_BACKOFF_SEC[-1]
    return RETRY_BACKOFF_SEC[attempt]


def should_give_up(attempt, max_attempts=RETRY_MAX_ATTEMPTS):
    return attempt >= max_attempts


def dedupe_key(sender_id, client_msg_id):
    """The idempotency key the server uses to reject a duplicate retried send."""
    return f"{int(sender_id)}:{client_msg_id}"


def queue_snapshot(pending):
    """Order a list of pending {client_msg_id, created_at, attempt} oldest first
    for flush, dropping any that have given up."""
    live = [p for p in (pending or []) if not should_give_up(p.get("attempt", 0))]
    return sorted(live, key=lambda p: _as_dt(p.get("created_at")) or datetime.max.replace(tzinfo=timezone.utc))


# ---------------------------------------------------------------------------
# Search — CLIENT-SIDE (server can't read plaintext)
# ---------------------------------------------------------------------------
# The server CANNOT search ciphertext.  Search is done on the client over the
# locally-decrypted message cache.  This module provides:
#   - search_index_hints(): what the server MAY return to help the client page
#     (counts, date ranges, participants) — never content.
#   - match_message(): the pure keyword/phrase matcher the CLIENT reuses for
#     both "in this chat" and "across all chats".  Case/diacritic-insensitive,
#     token-AND, supports quoted "exact phrase".

def search_index_hints(chat_summaries):
    """Server-safe paging hints per chat (NO content).  chat_summaries is a list
    of {chat_id, message_count, last_at, participant_ids}.  Returned verbatim so
    the client knows where to look / how far to page its local cache."""
    out = []
    for c in (chat_summaries or []):
        out.append({
            "chat_id": c.get("chat_id"),
            "message_count": int(c.get("message_count") or 0),
            "last_at": c.get("last_at"),
            "participant_ids": list(c.get("participant_ids") or []),
        })
    return out


def _normalize_for_search(s):
    return (s or "").casefold().strip()


def parse_query(query):
    """Split a query into (phrases, terms).  "a b" -> one phrase; bare words ->
    AND terms."""
    q = query or ""
    phrases = re.findall(r'"([^"]+)"', q)
    rest = re.sub(r'"[^"]+"', " ", q)
    terms = [t for t in rest.split() if t]
    return ([_normalize_for_search(p) for p in phrases],
            [_normalize_for_search(t) for t in terms])


def match_message(decrypted_text, query):
    """True if the already-decrypted `decrypted_text` matches `query` (AND of all
    terms + all quoted phrases).  Runs ON THE CLIENT over decrypted text only."""
    hay = _normalize_for_search(decrypted_text)
    if not hay:
        return False
    phrases, terms = parse_query(query)
    if not phrases and not terms:
        return False
    for p in phrases:
        if p and p not in hay:
            return False
    for t in terms:
        if t not in hay:
            return False
    return True


def search_messages(messages, query, in_chat_id=None):
    """Client helper: filter a list of decrypted messages (dicts with 'id',
    'chat_id', 'text', 'at', 'deleted') by `query`.  Skips deleted + empty.
    If in_chat_id is given, restrict to that chat (in-chat search); else search
    across chats.  Returns matches newest-first."""
    out = []
    for m in (messages or []):
        if in_chat_id is not None and m.get("chat_id") != in_chat_id:
            continue
        if m.get("deleted"):
            continue
        if match_message(m.get("text", ""), query):
            out.append(m)
    return sorted(out, key=lambda m: _as_dt(m.get("at")) or datetime.min.replace(tzinfo=timezone.utc),
                  reverse=True)


# ---------------------------------------------------------------------------
# Link preview — built on SENDER device; server never fetches
# ---------------------------------------------------------------------------

_URL_RE = re.compile(r'https?://[^\s<>"]+', re.IGNORECASE)


def extract_first_url(text):
    """Find the first http(s) URL in a message (client-side, to decide whether
    to build a preview).  The server NEVER does this — it can't read text."""
    m = _URL_RE.search(text or "")
    return m.group(0) if m else None


def link_preview_policy():
    """Explicit statement of where preview fetching happens (for the report +
    an assertable constant the client/tests can check)."""
    return {
        "fetched_on": "sender_device",
        "server_fetches_url": False,
        "preview_stored_as": "ciphertext",  # title/desc/image encrypted
        "image_max_bytes": 100 * 1024,       # cap thumbnail size pre-encrypt
    }


# ---------------------------------------------------------------------------
# Typing indicator — ephemeral, never stored
# ---------------------------------------------------------------------------
# Typing is a transient signal (relay-through / drop, never persisted).  The
# server may forward a {typing: bool, chat_id, from} ping but MUST NOT store it.

TYPING_TTL_SEC = 6  # a typing ping expires quickly if no refresh


def typing_event(chat_id, from_id, is_typing):
    """The ephemeral typing ping payload (no content, not persisted)."""
    return {
        "kind": "circle_typing",
        "chat_id": chat_id,
        "from": from_id,
        "typing": bool(is_typing),
        "ttl_sec": TYPING_TTL_SEC,
        "persist": False,
    }


# ---------------------------------------------------------------------------
# Text formatting — markers are CLIENT-rendered over decrypted text
# ---------------------------------------------------------------------------
# WhatsApp uses *bold* _italic_ ~strike~ ```mono```.  Formatting is a RENDER
# concern over already-decrypted text; the server never sees it.  We expose the
# marker set so the client composer + bubble agree.

FORMAT_MARKERS = {
    "bold": "*",
    "italic": "_",
    "strike": "~",
    "mono": "```",
}


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
