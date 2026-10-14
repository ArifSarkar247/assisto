"""
circle_extras.py — Assisto "Connected Circle" messenger EXTRAS (M2 items 9 + 10).
Pure Python, deterministic, unit-testable.  NO AI key at runtime (the one AI
touchpoint — message translation — is a mock + needs-key state here).

Scope (benchmarked vs WhatsApp + Messenger extras):
  - Disappearing messages (per-chat timer 24h / 7d / 90d) + view-once.
  - Per-chat wallpapers / themes (ON-DEVICE preference payload; no server state
    beyond an opaque per-chat setting the client may sync).
  - ORIGINAL sticker packs (we ship vector/drawn sets — this module models the
    pack/catalog + user-made stickers from the user's OWN photos; media bytes
    are key-gated like other circle media).
  - GIF search picker state (Tenor / GIPHY — OWNER KEY; we build the query/paging
    contract + a clean "available when GIF key added" gate; we NEVER bundle or
    proxy their assets).
  - On-device voice-note transcription (model-gated stub + state).
  - Message translation (AI key — mock now, needs-key state).
  - Scheduled messages (local schedule -> send at time; survives offline queue).
  - Broadcast list -> fan-out to INDIVIDUAL E2E chats (NOT a group; recipients
    never see each other).
  - "@Assisto" in a chat -> ON-DEVICE parse of a message into a reminder /
    expense / event (reuses nlp_datetime + money engines).  Only on explicit tap.
  - Encrypted chat backup envelope (ciphertext + recovery) + restore plan
    (reuses the e2e KeyBackup recovery-code scheme) + chat export assembler.

THE PRIVACY CONTRACT (inherited from circle.py / circle_messaging.py, re-enforced):
  - The server stores CIPHERTEXT ONLY.  Everything that carries meaning — sticker
    bytes, scheduled message bodies, backup contents, transcription text,
    translation text — is produced / held on the SENDER device.  The validators
    here reject any payload that smuggles plaintext or a secret.
  - @Assisto parsing runs ON-DEVICE over text the user ALREADY sees; the server
    never performs it and never sees the parsed result.
  - GIF search sends ONLY the query to the owner-keyed provider from the client;
    no circle content leaves the device.

WHAT LIVES HERE (logic/state only — DB models + HTTP endpoints + the Flutter UI
are the integrator's; see the report MIGRATION NOTE):
  - disappearing-timer evaluation (is a message expired? when does it expire?)
  - view-once state machine (unopened -> opened -> consumed; no re-view)
  - per-chat settings builder/validator (disappearing_sec, wallpaper, theme)
  - scheduled-message due evaluation + offline-safe queue ordering
  - broadcast fan-out PLAN (one opaque per-recipient envelope each; no shared id)
  - @Assisto intent -> action mapping (reminder / expense / event)
  - backup envelope builder/validator (ciphertext + recovery meta; no secret)
  - chat export assembler (decrypted locally by the user; never server-side)
  - sticker pack catalog + user-sticker gating
  - GIF picker gate + query contract
  - voice transcription gate + stub
  - translation gate + mock
  - linked-devices data model stubs (item 10 — design doc is owner_actions/
    linked_devices.md)

Run self-tests (no DB):
    python3 -c "import core.logic.circle_extras_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from core.logic.circle import (
    FALLBACK_SCHEME,
    FORBIDDEN_META_KEYS,
    pick,
)


# ===========================================================================
# 1. Disappearing messages — per-chat timer (24h / 7d / 90d)
# ===========================================================================
# WhatsApp offers 24h / 7d / 90d; Messenger offers a vanish mode + custom timers.
# The timer is a per-CHAT setting.  A message's expiry clock starts at a defined
# anchor.  WhatsApp starts the clock at SEND time (not read) — we match that so
# behaviour is predictable even if the recipient never opens the chat.  The
# server, holding only ciphertext, can still purge by (created_at + ttl) because
# that is routing metadata, not content.

DISAPPEAR_OFF = 0
DISAPPEAR_24H = 24 * 3600
DISAPPEAR_7D = 7 * 24 * 3600
DISAPPEAR_90D = 90 * 24 * 3600

DISAPPEAR_CHOICES = (DISAPPEAR_OFF, DISAPPEAR_24H, DISAPPEAR_7D, DISAPPEAR_90D)


def normalize_disappearing(seconds):
    """Snap an arbitrary value to one of the allowed timers (default OFF)."""
    try:
        s = int(seconds)
    except (TypeError, ValueError):
        return DISAPPEAR_OFF
    return s if s in DISAPPEAR_CHOICES else DISAPPEAR_OFF


def disappearing_label(seconds, lang="bn"):
    """Bilingual label for the per-chat timer picker / banner."""
    s = normalize_disappearing(seconds)
    table = {
        DISAPPEAR_OFF: ("বন্ধ", "Off"),
        DISAPPEAR_24H: ("২৪ ঘণ্টা", "24 hours"),
        DISAPPEAR_7D: ("৭ দিন", "7 days"),
        DISAPPEAR_90D: ("৯০ দিন", "90 days"),
    }
    bn, en = table[s]
    return pick(lang, bn, en)


def message_expires_at(created_at, disappearing_sec):
    """When a message in a disappearing chat expires, or None if timer is OFF.
    Clock starts at SEND time (created_at), matching WhatsApp."""
    ttl = normalize_disappearing(disappearing_sec)
    if ttl == DISAPPEAR_OFF:
        return None
    created = _as_dt(created_at)
    if created is None:
        return None
    return created + timedelta(seconds=ttl)


def is_expired(created_at, disappearing_sec, now=None):
    """True if a disappearing message is past its TTL (safe to purge/hide)."""
    exp = message_expires_at(created_at, disappearing_sec)
    if exp is None:
        return False
    now = now or datetime.now(timezone.utc)
    return _as_dt(now) >= exp


def seconds_until_expiry(created_at, disappearing_sec, now=None):
    """Remaining lifetime in seconds (>=0), or None if the timer is OFF."""
    exp = message_expires_at(created_at, disappearing_sec)
    if exp is None:
        return None
    now = now or datetime.now(timezone.utc)
    remaining = (exp - _as_dt(now)).total_seconds()
    return max(0, int(remaining))


# ===========================================================================
# 2. View-once photos / videos — state machine
# ===========================================================================
# WhatsApp/Messenger view-once: media is opened exactly once, then consumed; the
# server stores only the ciphertext blob ref and a small state flag.  The bytes
# are media (key-gated like other circle media).  No screenshot-proofing is
# claimed (impossible to enforce on-device without OS support — stated in UI).

VIEW_ONCE_UNOPENED = "unopened"
VIEW_ONCE_OPENED = "opened"     # currently being viewed (grace window)
VIEW_ONCE_CONSUMED = "consumed"  # viewed; may never be re-opened

# After first open, a short grace window lets the viewer finish; after it the
# state is CONSUMED and the blob may be purged.
VIEW_ONCE_GRACE_SEC = 30


def view_once_initial(content_type="photo"):
    """The state a view-once media message starts in (server stores this flag)."""
    return {
        "view_once": True,
        "content_type": content_type,
        "state": VIEW_ONCE_UNOPENED,
        "opened_at": None,
    }


def can_open_view_once(state):
    """True only while UNOPENED — a consumed view-once may never be re-opened."""
    return (state or {}).get("state") == VIEW_ONCE_UNOPENED


def open_view_once(state, now=None):
    """Transition UNOPENED -> OPENED, stamping opened_at.  Returns (state, ok).
    No-op (ok=False) if already opened/consumed."""
    if not can_open_view_once(state):
        return state, False
    now = now or datetime.now(timezone.utc)
    st = dict(state)
    st["state"] = VIEW_ONCE_OPENED
    st["opened_at"] = _as_dt(now).isoformat()
    return st, True


def view_once_consumed(state, now=None):
    """True if a view-once should now be treated as CONSUMED (open grace elapsed,
    or explicitly consumed).  The integrator purges the blob when this is True."""
    st = state or {}
    if st.get("state") == VIEW_ONCE_CONSUMED:
        return True
    if st.get("state") == VIEW_ONCE_OPENED:
        opened = _as_dt(st.get("opened_at"))
        if opened is None:
            return True
        now = now or datetime.now(timezone.utc)
        return (_as_dt(now) - opened) >= timedelta(seconds=VIEW_ONCE_GRACE_SEC)
    return False


def consume_view_once(state):
    """Force-transition to CONSUMED (viewer closed it / grace elapsed)."""
    st = dict(state or {})
    st["state"] = VIEW_ONCE_CONSUMED
    return st


# ===========================================================================
# 3. Per-chat wallpapers / themes — ON-DEVICE preference
# ===========================================================================
# Wallpapers/themes are a presentation preference.  They live on-device; the
# client MAY sync an opaque small settings blob so a user sees the same wallpaper
# on their linked devices.  No image bytes go to the server here — a wallpaper is
# either a built-in id or a user photo stored locally (and, if synced, as an
# encrypted blob ref like any other media).  We expose the built-in catalog +
# a validator so the settings payload stays presentation-only.

BUILTIN_WALLPAPERS = (
    # id,            bn label,            en label  (ORIGINAL gradients we ship)
    ("default",      "ডিফল্ট",            "Default"),
    ("cyan_blue",    "সায়ান-নীল",         "Cyan to Blue"),
    ("blue_purple",  "নীল-বেগুনি",         "Blue to Purple"),
    ("night_ink",    "রাতের কালি",         "Night Ink"),
    ("paper_warm",   "উষ্ণ কাগজ",          "Warm Paper"),
    ("forest_calm",  "শান্ত সবুজ",         "Calm Forest"),
)

CHAT_THEMES = (
    ("system", "সিস্টেম", "System"),
    ("light",  "হালকা",   "Light"),
    ("dark",   "গাঢ়",    "Dark"),
)

_WALLPAPER_IDS = {w[0] for w in BUILTIN_WALLPAPERS}
_THEME_IDS = {t[0] for t in CHAT_THEMES}

# A per-chat settings payload may carry ONLY these keys (presentation + timers).
_CHAT_SETTINGS_ALLOWED = {
    "disappearing_sec", "wallpaper", "wallpaper_blob_ref", "theme",
    "bubble_scheme",
}


def wallpaper_catalog(lang="bn"):
    return [{"id": i, "label": pick(lang, bn, en)}
            for (i, bn, en) in BUILTIN_WALLPAPERS]


def theme_catalog(lang="bn"):
    return [{"id": i, "label": pick(lang, bn, en)}
            for (i, bn, en) in CHAT_THEMES]


def build_chat_settings(disappearing_sec=DISAPPEAR_OFF, wallpaper="default",
                        theme="system", wallpaper_blob_ref=None,
                        bubble_scheme=None):
    """Assemble a validated per-chat settings payload (ChatSettings model)."""
    settings = {
        "disappearing_sec": normalize_disappearing(disappearing_sec),
        "wallpaper": wallpaper if wallpaper in _WALLPAPER_IDS else "default",
        "theme": theme if theme in _THEME_IDS else "system",
    }
    if wallpaper_blob_ref is not None:
        # A user-photo wallpaper: only an opaque blob ref may travel (bytes are
        # an encrypted media blob; see media gating).  Never raw image bytes.
        settings["wallpaper_blob_ref"] = str(wallpaper_blob_ref)
        settings["wallpaper"] = "custom"
    if bubble_scheme is not None:
        settings["bubble_scheme"] = str(bubble_scheme)
    ok, why = validate_chat_settings(settings)
    if not ok:
        raise ValueError("invalid chat settings: " + why)
    return settings


def validate_chat_settings(settings):
    """Return (ok, reason).  Settings are presentation-only — no plaintext/secret
    and no raw image bytes."""
    if not isinstance(settings, dict):
        return False, "settings must be an object"
    bad = FORBIDDEN_META_KEYS & set(settings.keys())
    if bad:
        return False, "forbidden field(s): " + ",".join(sorted(bad))
    extra = set(settings.keys()) - _CHAT_SETTINGS_ALLOWED
    if extra:
        return False, "disallowed keys: " + ",".join(sorted(extra))
    if "disappearing_sec" in settings and \
            normalize_disappearing(settings["disappearing_sec"]) != settings["disappearing_sec"]:
        return False, "bad disappearing_sec"
    return True, "ok"


# ===========================================================================
# 4. Sticker packs (ORIGINAL) + user-made stickers from own photos
# ===========================================================================
# We ship ORIGINAL sticker sets (vector/drawn — NOT copied from WhatsApp/others).
# This module models the catalog (pack id -> stickers) + user-made stickers from
# the user's OWN photos.  A sent sticker is a reference to a pack+sticker id (for
# built-ins) or an encrypted media blob (for user stickers) — never bundled
# third-party assets, never plaintext.

# Built-in ORIGINAL packs (asset ids resolve to our bundled vector files; the
# labels are the only strings here — bytes live in app assets, integrator-owned).
STICKER_PACKS = (
    {
        "id": "assisto_hearts",
        "name_bn": "আসিস্টো হৃদয়", "name_en": "Assisto Hearts",
        "stickers": ["heart_wave", "heart_grow", "heart_two", "heart_spark"],
    },
    {
        "id": "assisto_faces",
        "name_bn": "আসিস্টো মুখভঙ্গি", "name_en": "Assisto Faces",
        "stickers": ["smile", "wink", "cry", "laugh", "think", "sleep"],
    },
    {
        "id": "assisto_bangla",
        "name_bn": "বাংলা অভিব্যক্তি", "name_en": "Bangla Expressions",
        "stickers": ["thik_ache", "darun", "dhonnobad", "valobasha"],
    },
)

_STICKER_PACK_IDS = {p["id"] for p in STICKER_PACKS}


def sticker_pack_catalog(lang="bn"):
    """Pack list for the picker (id, name, sticker count)."""
    out = []
    for p in STICKER_PACKS:
        out.append({
            "id": p["id"],
            "name": pick(lang, p["name_bn"], p["name_en"]),
            "count": len(p["stickers"]),
            "sticker_ids": list(p["stickers"]),
        })
    return out


def build_builtin_sticker_ref(pack_id, sticker_id):
    """A sent built-in sticker travels as a tiny reference (pack+id), not bytes.
    Returns None if the sticker isn't in a known ORIGINAL pack."""
    for p in STICKER_PACKS:
        if p["id"] == pack_id and sticker_id in p["stickers"]:
            return {"kind": "sticker", "source": "builtin",
                    "pack_id": pack_id, "sticker_id": sticker_id}
    return None


def build_user_sticker_ref(blob_ref):
    """A user-made sticker (cut out from the user's OWN photo on-device) travels
    as an encrypted media blob ref — key-gated like other circle media."""
    if not blob_ref:
        raise ValueError("user sticker needs an encrypted blob_ref")
    return {"kind": "sticker", "source": "user", "blob_ref": str(blob_ref)}


def user_sticker_gate(media_bytes_available, lang="bn"):
    """User stickers need the encrypted-media bucket (same gate as photos).  On-
    device cutout/crop is pure client work and needs no key; STORING/SENDING the
    result does.  Returns None if available, else a bilingual reason."""
    if media_bytes_available:
        return None
    return pick(lang,
                "নিজের ছবি থেকে স্টিকার পাঠানো যাবে এনক্রিপ্টেড স্টোরেজ চালু হলে।",
                "Stickers from your own photos available when encrypted media "
                "storage is enabled.")


# ===========================================================================
# 5. GIF search (Tenor / GIPHY — OWNER KEY)
# ===========================================================================
# GIF search needs an OWNER-provided provider API key.  We build the query/paging
# contract + a clean gate.  We NEVER bundle provider assets; the client fetches
# directly from the provider with the owner key.  No circle content leaves the
# device — only the search query.

GIF_PROVIDERS = ("tenor", "giphy")


def gif_search_available(provider_key):
    """True only when the owner has configured a provider key."""
    return bool(provider_key)


def gif_gate_reason(lang="bn"):
    """The 'Available when GIF key added' state string."""
    return pick(lang,
                "GIF খোঁজা চালু হবে মালিক Tenor/GIPHY কী যোগ করলে।",
                "GIF search available when the owner adds a Tenor/GIPHY key.")


def gif_search_request(query, provider="tenor", limit=24, pos=None,
                       lang="bn", content_filter="high"):
    """Build the provider-agnostic search request the CLIENT issues (with the
    owner key injected by the client transport).  Only the QUERY leaves the
    device — never circle content.  content_filter defaults to the strictest
    (family-safe)."""
    prov = provider if provider in GIF_PROVIDERS else "tenor"
    req = {
        "provider": prov,
        "q": (query or "").strip(),
        "limit": max(1, min(int(limit), 50)),
        "content_filter": content_filter,  # family-safe default
        "locale": "bn" if lang == "bn" else "en",
    }
    if pos:
        req["pos"] = str(pos)  # paging cursor
    return req


# ===========================================================================
# 6. On-device voice-note transcription (model-gated)
# ===========================================================================
# Transcription runs ON-DEVICE with a bundled/downloaded small model when present
# (no audio leaves the device; no server AI).  Until a model is present we return
# a clean gated state.  The stub below is deterministic so UI/tests can exercise
# the flow; a real on-device model plugs in behind the same signature.

def transcription_available(model_present):
    return bool(model_present)


def transcription_gate_reason(lang="bn"):
    return pick(lang,
                "ভয়েস নোট লেখায় রূপান্তর হবে অন-ডিভাইস মডেল যুক্ত হলে।",
                "Voice-note transcription available when the on-device model is "
                "added.")


def transcribe_voice_note(audio_bytes, model_present=False, model=None,
                          lang="bn"):
    """Return {available, text, lang, gated_reason}.  When a model is present it
    is invoked (model(audio_bytes, lang) -> str); otherwise a gated state is
    returned.  Runs ON-DEVICE; the server never sees audio or text."""
    if not transcription_available(model_present):
        return {"available": False, "text": None, "lang": lang,
                "gated_reason": transcription_gate_reason(lang)}
    text = ""
    if callable(model):
        try:
            text = model(audio_bytes, lang) or ""
        except Exception:
            text = ""
    return {"available": True, "text": text, "lang": lang, "gated_reason": None}


# ===========================================================================
# 7. Message translation (AI KEY — mock now, needs-key state)
# ===========================================================================
# Translation is the ONE AI touchpoint in extras.  It needs the owner AI key and
# runs on the user's OWN decrypted text ON TAP (never automatically, never on the
# server over ciphertext).  Mock now; clean needs-key state otherwise.

SUPPORTED_TRANSLATE = ("bn", "en")


def translation_available(ai_key):
    return bool(ai_key)


def translation_gate_reason(lang="bn"):
    return pick(lang,
                "মেসেজ অনুবাদ চালু হবে মালিক AI কী যোগ করলে।",
                "Message translation available when the owner adds an AI key.")


def translate_message(text, target_lang="en", ai_key=None, translator=None):
    """Translate already-DECRYPTED text on tap.  Returns {available, text,
    target_lang, gated_reason, mocked}.  With no key -> gated.  With a key but no
    real translator wired -> a deterministic MOCK (so UI/tests work now)."""
    tl = target_lang if target_lang in SUPPORTED_TRANSLATE else "en"
    if not translation_available(ai_key):
        return {"available": False, "text": None, "target_lang": tl,
                "gated_reason": translation_gate_reason(), "mocked": False}
    if callable(translator):
        return {"available": True, "text": translator(text, tl),
                "target_lang": tl, "gated_reason": None, "mocked": False}
    # Deterministic mock: tag the text so the UI can show the flow end-to-end.
    mocked = f"[{tl}] {text or ''}"
    return {"available": True, "text": mocked, "target_lang": tl,
            "gated_reason": None, "mocked": True}


# ===========================================================================
# 8. Scheduled messages — local schedule, send at time, offline-safe
# ===========================================================================
# The client composes + ENCRYPTS now, stores the ciphertext envelope locally with
# a send_at, and flushes it when due (reusing the circle_messaging offline queue).
# The server only ever receives the opaque envelope at/after send_at — it never
# holds a "future plaintext".  If the device is offline at send_at, the message
# is queued and sent on reconnect (offline-safe), still as ciphertext.

SCHEDULE_MIN_LEAD_SEC = 60        # can't schedule < 1 min out
SCHEDULE_MAX_LEAD_SEC = 365 * 24 * 3600  # or > 1 year out


def validate_schedule_time(send_at, now=None):
    """Return (ok, reason).  send_at must be a sane future time inside the lead
    window."""
    when = _as_dt(send_at)
    if when is None:
        return False, "bad send_at"
    now = _as_dt(now or datetime.now(timezone.utc))
    lead = (when - now).total_seconds()
    if lead < SCHEDULE_MIN_LEAD_SEC:
        return False, "too soon"
    if lead > SCHEDULE_MAX_LEAD_SEC:
        return False, "too far"
    return True, "ok"


def build_scheduled_message(envelope, send_at, client_msg_id, now=None):
    """Wrap an already-opaque message envelope for local scheduling.  The
    envelope is validated to be ciphertext-only via circle_messaging's validator
    by the caller; here we only add scheduling metadata + a dedupe id.  Raises on
    a bad time."""
    ok, why = validate_schedule_time(send_at, now=now)
    if not ok:
        raise ValueError("bad schedule time: " + why)
    # Defence in depth: refuse to schedule anything carrying plaintext/secrets.
    bad = FORBIDDEN_META_KEYS & set((envelope or {}).keys())
    if bad:
        raise ValueError("scheduled envelope smuggles plaintext: "
                         + ",".join(sorted(bad)))
    return {
        "kind": "scheduled_message",
        "send_at": _as_dt(send_at).isoformat(),
        "client_msg_id": str(client_msg_id),
        "status": "pending",      # pending -> sent | cancelled | failed
        "attempt": 0,
        "envelope": dict(envelope or {}),
    }


def is_scheduled_due(scheduled, now=None):
    """True if a pending scheduled message should be flushed now."""
    if (scheduled or {}).get("status") != "pending":
        return False
    send_at = _as_dt(scheduled.get("send_at"))
    if send_at is None:
        return False
    now = _as_dt(now or datetime.now(timezone.utc))
    return now >= send_at


def due_scheduled(scheduled_list, now=None):
    """All pending scheduled messages that are due, oldest send_at first
    (offline flush order).  Items already sent/cancelled are skipped."""
    now = _as_dt(now or datetime.now(timezone.utc))
    due = [s for s in (scheduled_list or []) if is_scheduled_due(s, now=now)]
    return sorted(due, key=lambda s: _as_dt(s.get("send_at"))
                  or datetime.max.replace(tzinfo=timezone.utc))


def mark_scheduled(scheduled, status):
    """Transition a scheduled message's status (sent / cancelled / failed)."""
    st = dict(scheduled or {})
    if status in ("sent", "cancelled", "failed", "pending"):
        st["status"] = status
    return st


# ===========================================================================
# 9. Broadcast list — fan-out to INDIVIDUAL E2E chats (NOT a group)
# ===========================================================================
# A broadcast is a convenience: compose once, send privately to many chosen
# circle members.  Each recipient gets an INDIVIDUAL message in their own 1:1
# chat — recipients NEVER see each other and there is NO shared message id (that
# would be a group).  The client re-ENCRYPTS the body per-recipient (each 1:1
# chat has its own key).  This function returns the FAN-OUT PLAN: one opaque
# per-recipient send descriptor each, with a distinct client_msg_id so the
# offline queue dedupes correctly.

BROADCAST_MAX_RECIPIENTS = 256  # WhatsApp broadcast-list cap


def validate_broadcast(sender_id, recipient_ids, accepted_ids):
    """Return (ok, reason).  Recipients must all be ACCEPTED circle members (the
    integrator passes the set of accepted member ids); self excluded; within the
    cap; at least one recipient."""
    recips = [r for r in (recipient_ids or []) if r != sender_id]
    if not recips:
        return False, "no recipients"
    if len(recips) > BROADCAST_MAX_RECIPIENTS:
        return False, "too many recipients"
    accepted = set(accepted_ids or [])
    not_connected = [r for r in recips if r not in accepted]
    if not_connected:
        return False, "not_connected"
    return True, "ok"


def broadcast_fanout_plan(sender_id, recipient_ids, accepted_ids,
                          broadcast_id, base_client_msg_id):
    """Return a list of INDIVIDUAL send descriptors (one per recipient).  Each is
    a private 1:1 send — NO shared message id, recipients cannot see each other.
    The client encrypts the body separately per recipient (per-chat key) and
    attaches the per-recipient client_msg_id for offline dedupe.  Raises if the
    broadcast is invalid."""
    ok, why = validate_broadcast(sender_id, recipient_ids, accepted_ids)
    if not ok:
        raise ValueError("invalid broadcast: " + why)
    recips = [r for r in recipient_ids if r != sender_id]
    plan = []
    for r in recips:
        plan.append({
            "recipient_id": r,
            "content_type": "text",
            # distinct per-recipient dedupe id; the broadcast_id is a CLIENT-only
            # grouping tag so the sender can see "sent to N" — it is NOT sent to
            # recipients and NEVER links their messages server-side.
            "client_msg_id": f"{base_client_msg_id}:{r}",
            "broadcast_local_tag": str(broadcast_id),  # client-only
            "is_broadcast": True,
        })
    return plan


# ===========================================================================
# 10. "@Assisto" in a chat -> reminder / expense / event (ON-DEVICE, on tap)
# ===========================================================================
# The user long-presses/taps a message and chooses "@Assisto".  The DECRYPTED
# text is parsed ON-DEVICE with the existing engines (nlp_datetime, money_parse)
# to offer a reminder / expense / event action.  NEVER automatic, NEVER server-
# side, NEVER over ciphertext.  Returns candidate actions ranked by confidence;
# the user confirms which to create.

ASSISTO_TRIGGER = "@assisto"


def has_assisto_trigger(text):
    """True if a message explicitly invokes @Assisto (so the action chip can be
    offered).  Matching is case-insensitive.  NOTE: even when present, action
    creation only happens ON TAP — never automatically."""
    return ASSISTO_TRIGGER in (text or "").casefold()


def strip_assisto_trigger(text):
    """Remove the @Assisto token so the parsers see the user's actual intent."""
    t = text or ""
    low = t.casefold()
    i = low.find(ASSISTO_TRIGGER)
    if i < 0:
        return t.strip()
    return (t[:i] + t[i + len(ASSISTO_TRIGGER):]).strip()


def assisto_actions(text, now=None, lang=None):
    """Parse DECRYPTED chat text into candidate actions.  Returns a list of
    {type, confidence, payload, label_bn, label_en} ordered by confidence.
    Reuses nlp_datetime.parse (reminder/event) + money_parse.parse_sms (expense).
    Pure, on-device, deterministic.  type ∈ {reminder, event, expense}."""
    # Imported lazily so this module has no hard import cost when unused and so a
    # test harness can stub the engines if desired.
    from core.logic import nlp_datetime as NLP
    from core.logic import money_parse as MP

    body = strip_assisto_trigger(text)
    actions = []

    # --- expense (money) ---
    try:
        m = MP.parse_sms(body)
    except Exception:
        m = None
    if m and m.get("amount") is not None:
        conf = 0.6
        if m.get("parsed"):
            conf = 0.85
        actions.append({
            "type": "expense",
            "confidence": round(conf, 2),
            "payload": {
                "amount": str(m.get("amount")),
                "category_guess": m.get("category_guess"),
                "counterparty": m.get("counterparty"),
                "txn_type": m.get("type"),
                "date": m.get("date"),
            },
            "label_bn": "খরচ হিসেবে যোগ করুন",
            "label_en": "Add as expense",
        })

    # --- reminder / event (datetime) ---
    try:
        d = NLP.parse(body, now=now, lang=lang)
    except Exception:
        d = None
    if d and d.get("datetime"):
        conf = float(d.get("confidence") or 0.0)
        # A recurrence or an explicit title tends to read as a reminder; a one-
        # off dated thing with a place/title reads as an event.  We offer BOTH
        # when confident and let the user pick, but rank reminder first for a
        # recurrence and event first for a one-off with no recurrence.
        reminder = {
            "type": "reminder",
            "confidence": round(conf, 2),
            "payload": {
                "datetime": d.get("datetime"),
                "recurrence_rule": d.get("recurrence_rule"),
                "title": d.get("clean_title") or body,
            },
            "label_bn": "রিমাইন্ডার তৈরি করুন",
            "label_en": "Create reminder",
        }
        event = {
            "type": "event",
            "confidence": round(max(0.0, conf - 0.05), 2),
            "payload": {
                "datetime": d.get("datetime"),
                "title": d.get("clean_title") or body,
                "all_day": bool(d.get("date_only")),
            },
            "label_bn": "ইভেন্ট তৈরি করুন",
            "label_en": "Create event",
        }
        if d.get("recurrence_rule"):
            actions.extend([reminder, event])
        else:
            actions.extend([event, reminder])

    # Highest confidence first; stable within equal confidence.
    actions.sort(key=lambda a: -a["confidence"])
    return actions


def assisto_action_label(action, lang="bn"):
    """Bilingual chip label for an action candidate."""
    return pick(lang, action.get("label_bn", ""), action.get("label_en", ""))


# ===========================================================================
# 11. Encrypted chat backup + recovery code + restore
# ===========================================================================
# Reuses the e2e KeyBackup recovery-code scheme (app/lib/crypto/e2e.dart): the
# chat history is serialized + sealed on-device under a recovery code the server
# NEVER learns.  The server stores only an opaque blob + non-secret meta so the
# user can restore on a new phone.  This builder assembles/validates the ENVELOPE
# (the actual sealing happens in Dart with KeyBackup/ChaCha20-Poly1305); the
# Python side proves the stored object carries no plaintext/secret.

BACKUP_ENVELOPE_VERSION = 1
# Only these keys may travel to the server for a backup (all opaque/non-secret).
_BACKUP_ALLOWED = {
    "v", "owner_id", "created_at", "scheme", "ciphertext", "nonce", "salt",
    "iters", "message_count", "recovery_hint", "size_bytes",
}


def build_backup_envelope(owner_id, ciphertext_b64, nonce_b64, salt_b64,
                          iters, message_count, recovery_hint="",
                          scheme=None, size_bytes=0, now=None):
    """Assemble the server-stored encrypted-backup envelope.  ciphertext is the
    SEALED chat archive (sealed on-device under the recovery code).  The recovery
    code itself is NEVER included (recovery_hint is a non-secret reminder the
    user chose, e.g. 'notebook page 3').  Raises if anything looks like a secret."""
    now = now or datetime.now(timezone.utc)
    env = {
        "v": BACKUP_ENVELOPE_VERSION,
        "owner_id": owner_id,
        "created_at": _as_dt(now).isoformat(),
        "scheme": scheme or FALLBACK_SCHEME,
        "ciphertext": ciphertext_b64,
        "nonce": nonce_b64,
        "salt": salt_b64,
        "iters": int(iters),
        "message_count": int(message_count),
        "recovery_hint": recovery_hint or "",
        "size_bytes": int(size_bytes),
    }
    ok, why = validate_backup_envelope(env)
    if not ok:
        raise ValueError("refusing to store non-opaque backup: " + why)
    return env


def validate_backup_envelope(env):
    """Return (ok, reason).  The stored backup must carry NO recovery code / key /
    plaintext — only the sealed ciphertext + public KDF params + non-secret meta."""
    if not isinstance(env, dict):
        return False, "backup must be an object"
    bad = FORBIDDEN_META_KEYS & set(env.keys())
    if bad:
        return False, "backup carries secret/plaintext: " + ",".join(sorted(bad))
    extra = set(env.keys()) - _BACKUP_ALLOWED
    if extra:
        return False, "backup has disallowed keys: " + ",".join(sorted(extra))
    if not env.get("ciphertext"):
        return False, "backup missing ciphertext"
    if not env.get("nonce") or not env.get("salt"):
        return False, "backup missing nonce/salt"
    return True, "ok"


def restore_plan(env, lang="bn"):
    """What the client needs to restore on a NEW phone: the sealed blob + KDF
    params; the user must supply the recovery code (which the server never had).
    Returns the opaque params + a bilingual prompt.  Returns None if invalid."""
    ok, _ = validate_backup_envelope(env)
    if not ok:
        return None
    return {
        "scheme": env.get("scheme"),
        "ciphertext": env.get("ciphertext"),
        "nonce": env.get("nonce"),
        "salt": env.get("salt"),
        "iters": env.get("iters"),
        "message_count": env.get("message_count"),
        "recovery_hint": env.get("recovery_hint", ""),
        "prompt": pick(lang,
                       "নতুন ফোনে চ্যাট ফিরে পেতে রিকভারি কোড লিখুন।",
                       "Enter your recovery code to restore chats on the new "
                       "phone."),
    }


# ===========================================================================
# 12. Export a chat (decrypted LOCALLY by the user; never server-side)
# ===========================================================================
# The user exports a chat to a file.  Decryption happens ON-DEVICE over the
# user's own messages; the server never produces a plaintext export.  This
# assembler turns a list of already-DECRYPTED messages into a text (or structured)
# export, bilingual headers, skipping deleted + (optionally) view-once consumed.

def export_chat_text(decrypted_messages, chat_title="", lang="bn",
                     include_media_placeholders=True):
    """Assemble a human-readable .txt export from already-DECRYPTED messages.
    Each message: {at, sender_name, text, content_type, deleted}.  Deleted
    messages are skipped; media become a bilingual placeholder line.  Runs on the
    user's device — the server is never asked to decrypt."""
    lines = []
    header = pick(lang, "আসিস্টো সার্কেল চ্যাট রপ্তানি", "Assisto Circle chat export")
    lines.append(header + (f" — {chat_title}" if chat_title else ""))
    lines.append("")
    media_word = {
        "photo": pick(lang, "[ছবি]", "[photo]"),
        "video": pick(lang, "[ভিডিও]", "[video]"),
        "voice": pick(lang, "[ভয়েস নোট]", "[voice note]"),
        "sticker": pick(lang, "[স্টিকার]", "[sticker]"),
        "gif": "[GIF]",
    }
    for m in (decrypted_messages or []):
        if m.get("deleted"):
            continue
        ts = _as_dt(m.get("at"))
        stamp = ts.strftime("%Y-%m-%d %H:%M") if ts else ""
        who = m.get("sender_name") or ""
        ct = m.get("content_type") or "text"
        if ct == "text":
            body = m.get("text") or ""
        else:
            body = media_word.get(ct, f"[{ct}]") if include_media_placeholders \
                else ""
            if m.get("text"):  # caption
                body = (body + " " + m["text"]).strip()
        lines.append(f"[{stamp}] {who}: {body}".rstrip())
    return "\n".join(lines) + "\n"


def export_chat_json(decrypted_messages, chat_title="", lang="bn"):
    """Structured export (for re-import / archival).  Still assembled on-device
    from decrypted messages; the server never sees it."""
    out = {
        "format": "assisto.circle.chat.v1",
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "title": chat_title,
        "lang": lang,
        "messages": [],
    }
    for m in (decrypted_messages or []):
        if m.get("deleted"):
            continue
        out["messages"].append({
            "at": (_as_dt(m.get("at")).isoformat() if _as_dt(m.get("at")) else None),
            "sender_name": m.get("sender_name") or "",
            "content_type": m.get("content_type") or "text",
            "text": m.get("text") or "",
        })
    out["message_count"] = len(out["messages"])
    return out


# ===========================================================================
# 13. Linked devices / multi-device (item 10 — DESIGN; data model stubs only)
# ===========================================================================
# Full design lives in owner_actions/linked_devices.md.  Platform order:
# Android + iPhone first, web client AFTER.  Each linked device holds its OWN
# key; the primary device authorizes a new device via a key-transfer handshake
# (MLS "welcome" in production; software-fallback sealed transfer now).  No
# plaintext/key ever touches the server.  Here we model the device registry +
# the (opaque) welcome/link request so the integrator can build the data model
# and stubs — NO web client is built.

DEVICE_PLATFORMS = ("android", "ios", "web")
DEVICE_ROLE_PRIMARY = "primary"
DEVICE_ROLE_LINKED = "linked"
# Web is explicitly LAST in platform order (owner-specified).
DEVICE_PLATFORM_ORDER = ("android", "ios", "web")
MAX_LINKED_DEVICES = 4  # WhatsApp links up to 4 companion devices


def device_record(device_id, platform, role=DEVICE_ROLE_LINKED,
                  public_key_id=None, linked_at=None, name=""):
    """A registry row for a user's device.  The server stores ONLY a public key
    id + non-secret meta — never a private key."""
    now = linked_at or datetime.now(timezone.utc)
    plat = platform if platform in DEVICE_PLATFORMS else "android"
    return {
        "device_id": str(device_id),
        "platform": plat,
        "role": role if role in (DEVICE_ROLE_PRIMARY, DEVICE_ROLE_LINKED) else DEVICE_ROLE_LINKED,
        "public_key_id": public_key_id or "",
        "name": name or "",
        "linked_at": _as_dt(now).isoformat(),
        "revoked": False,
    }


def can_link_device(existing_devices, new_platform):
    """Return (ok, reason).  Enforces the companion cap + platform order (web is
    allowed only AFTER an Android or iOS device exists — owner's platform order).
    """
    live = [d for d in (existing_devices or []) if not d.get("revoked")]
    linked = [d for d in live if d.get("role") == DEVICE_ROLE_LINKED]
    if len(linked) >= MAX_LINKED_DEVICES:
        return False, "device_cap"
    if new_platform == "web":
        has_mobile = any(d.get("platform") in ("android", "ios") for d in live)
        if not has_mobile:
            return False, "web_after_mobile"  # web client comes after mobile
    return True, "ok"


def build_link_request(primary_device_id, new_device_public_key_id,
                       new_platform, sealed_welcome_b64, now=None):
    """The opaque device-link ('welcome') request: the primary device seals the
    group/key material to the new device's public key (MLS welcome in prod;
    software-sealed now) and the server relays the OPAQUE blob.  The server never
    sees a key.  Raises if the blob carries a secret field or the platform order
    is violated at the request shape level."""
    now = now or datetime.now(timezone.utc)
    if new_platform not in DEVICE_PLATFORMS:
        raise ValueError("unknown platform")
    if not sealed_welcome_b64:
        raise ValueError("link request needs a sealed welcome blob")
    req = {
        "kind": "device_link_welcome",
        "primary_device_id": str(primary_device_id),
        "new_device_public_key_id": str(new_device_public_key_id),
        "platform": new_platform,
        "sealed_welcome": sealed_welcome_b64,  # OPAQUE (sealed to new device key)
        "created_at": _as_dt(now).isoformat(),
    }
    bad = FORBIDDEN_META_KEYS & set(req.keys())
    if bad:
        raise ValueError("link request smuggles secret: " + ",".join(sorted(bad)))
    return req


def revoke_device(devices, device_id):
    """Mark a linked device revoked (its keys are rotated out by the primary).
    Returns the updated list."""
    out = []
    for d in (devices or []):
        d = dict(d)
        if d.get("device_id") == str(device_id):
            d["revoked"] = True
        out.append(d)
    return out


# ===========================================================================
# helpers
# ===========================================================================

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
