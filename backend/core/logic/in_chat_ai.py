"""
in_chat_ai.py — the deterministic, key-free engine behind Assisto's IN-CHAT AI
helper (issue #97, SPEC v2.1 §21, ADVANCED).

Inside the end-to-end-encrypted 1:1 messenger chat, the user may ask a bounded
helper to do one of three things over text THEY already decrypted on-device:

    * summarise_thread  — a short bullet digest of the last few messages
    * translate_message — bn <-> en direction hint + a MOCK rendering
    * adjust_tone       — rewrite one message in a chosen tone (polite /
                          shorter / warmer / firmer / formal)

This module is PURE, exactly like `social.py` / `agent_studio.py`: no Django,
no DB, no network, no clock, **no AI**. It is a DETERMINISTIC TEMPLATE engine —
same inputs always give the same output — so the on-device Dart mirror produces
an identical preview offline and the tests can pin it.

HONEST AI, KEY-GATED
--------------------
The "AI helps you in chat" promise is served, right now, by this deterministic
template engine and is clearly labelled a MOCK ("AI-generated — review"). It
never calls a model and never needs a key. When an AI key is present
(Integrations → `core.ai.generate`), the app/executor MAY route the SAME
request shape to the real provider for a richer result — the request/plan shape
here is the contract; nothing in this file calls a model. Every result carries
`ai_required=False, mock=True` so callers stay honest about which path produced
the text, and `marker` carries the honest "review" label key the UI renders.

PRIVACY
-------
The messages are E2E-encrypted; only the USER'S DEVICE has plaintext. This
engine therefore operates on text the caller already decrypted locally and is
never asked to reach the server. The real-AI seam (`core.ai.generate`) wraps
untrusted message text in a DATA fence (see `core/ai.py` `_INJECTION_GUARD`);
this mock does no interpretation of the text as commands either — it only
reshapes it deterministically.

NEVER AUTO-SEND
---------------
We only ever produce TEXT. Inserting it into the composer or copying it is a
manual action the user takes; nothing here sends a message. Callers get a
plain string back and decide.

Everything is plain stdlib and hand-verified in in_chat_ai_tests_snippets.py.
"""

# ---------------------------------------------------------------- vocabulary

# The three bounded actions this helper offers. The UI localises these keys.
ACTIONS = ("summarise", "translate", "tone")

# Tone presets for adjust_tone. Neutral English seed labels; the UI localises
# them. Each maps to a deterministic opener/closer the mock wraps the text in.
TONES = ("polite", "shorter", "warmer", "firmer", "formal")

# Translate direction hints. "auto" lets the engine guess from the script.
DIRECTIONS = ("auto", "bn2en", "en2bn")

# How many recent messages a summary will look at, at most. The caller slices
# its own on-device cache; we clamp again so the mock is total.
MAX_THREAD = 12

# The honest marker key every result carries. The UI renders the localised
# "AI-generated — review" chip from this; the engine never emits prose.
MARKER_KEY = "ai_review"


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _has_bangla(text):
    """True if any character is in the Bengali Unicode block (U+0980–U+09FF).
    Used only to GUESS translate direction; never to emit Bangla here."""
    for ch in str(text or ""):
        if "ঀ" <= ch <= "৿":
            return True
    return False


def _sentences(text):
    """Split into trimmed sentence-ish fragments on . ! ? । (Bangla danda) and
    newlines. Deterministic; drops empties."""
    import re
    parts = re.split(r"[.!?।\n]+", str(text or ""))
    return [p.strip() for p in parts if p.strip()]


def _first_words(text, n):
    """First `n` whitespace words of text (for a deterministic bullet lead)."""
    return " ".join(_clean(text).split()[:n])


# ----------------------------------------------------------------- validate

def validate(action, messages=None, text="", tone="polite", direction="auto"):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    * summarise needs a non-empty `messages` list.
    * translate / tone need a non-empty `text`.
    * tone must be a known preset; translate a known direction.
    """
    problems = []
    if action not in ACTIONS:
        problems.append("bad_action")
        return problems
    if action == "summarise":
        if not messages:
            problems.append("empty_thread")
    else:
        if not _clean(text):
            problems.append("empty_text")
    if action == "tone" and tone not in TONES:
        problems.append("bad_tone")
    if action == "translate" and direction not in DIRECTIONS:
        problems.append("bad_direction")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- generators

def summarise_thread(messages):
    """MOCK: a short bullet digest of recent messages.

    `messages` is a list of dicts the DEVICE decrypted, newest last:
        {"text": "...", "mine": True/False}
    We produce up to 3 deterministic bullet fragments (one per most-recent
    non-empty message, trimmed), plus a count line. No AI, no interpretation."""
    msgs = [m for m in (messages or []) if _clean(m.get("text"))][-MAX_THREAD:]
    total = len(msgs)
    # take the last 3 (newest) for the digest, but keep chronological order
    recent = msgs[-3:]
    bullets = []
    for m in recent:
        who = "you" if m.get("mine") else "them"
        lead = _first_words(m.get("text"), 14)
        bullets.append({"who": who, "text": lead})
    return {
        "action": "summarise",
        "count": total,
        "bullets": bullets,
        "ai_required": False,
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("summarise", messages=messages),
    }


def translate_message(text, direction="auto"):
    """MOCK: a translate PLAN, not a real translation.

    A faithful translation needs a real model (or a licensed dictionary, which
    this helper does not bundle). So we HONESTLY return the detected direction
    and the original text, labelled as needing the AI key for a real render —
    we never fabricate a translation and pass it off as real.

    Returns `ai_required=True` for the real render while staying a usable MOCK:
    the UI shows the direction + original and the honest "needs AI key" state.
    """
    text = _clean(text)
    if direction == "auto":
        direction = "bn2en" if _has_bangla(text) else "en2bn"
    return {
        "action": "translate",
        "direction": direction,
        "source": text,
        # honest: a REAL translation needs the key-gated route; we never invent
        # a translation. The mock shows direction + source only.
        "translated": "",
        "ai_required": True,
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("translate", text=text, direction=direction),
    }


# Deterministic tone skeletons. `{text}` is filled with the user's message.
# Neutral English seeds (zero Bangla) so the mirrored Dart generator matches
# and the file stays Bangla-free; the real-AI path replaces these.
_TONE_WRAP = {
    "polite":  "Could you please consider this: {text}. Thank you.",
    "shorter": "{short}",
    "warmer":  "Hope you're doing well! {text} 🙂",
    "firmer":  "To be clear: {text}. Please confirm.",
    "formal":  "Dear recipient, I would like to note the following: {text}. Regards.",
}


def adjust_tone(text, tone="polite"):
    """MOCK: rewrite one message in a chosen tone, deterministically.

    "shorter" keeps the first sentence (or first 10 words); the others wrap the
    text in a fixed polite/warm/firm/formal skeleton. No AI — honestly a MOCK
    the user reviews and edits before use. Deterministic."""
    text = _clean(text)
    short = _sentences(text)
    short_lead = short[0] if short else _first_words(text, 10)
    wrap = _TONE_WRAP.get(tone, _TONE_WRAP["polite"])
    result = wrap.format(text=text, short=short_lead)
    return {
        "action": "tone",
        "tone": tone,
        "source": text,
        "result": result,
        "ai_required": False,
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("tone", text=text, tone=tone),
    }


# ----------------------------------------------------------------- dispatch

def run(action, messages=None, text="", tone="polite", direction="auto"):
    """Single entry point mirroring the request shape the real-AI route takes.

    Returns the matching generator's dict, or an error dict with `problems`
    when inputs are invalid (so callers never crash on bad input). This is the
    contract the integrator wires to `core.ai.generate` for the real path."""
    problems = validate(action, messages=messages, text=text, tone=tone,
                        direction=direction)
    if problems:
        return {"action": action, "problems": problems, "mock": True,
                "ai_required": action == "translate", "marker": MARKER_KEY}
    if action == "summarise":
        return summarise_thread(messages)
    if action == "translate":
        return translate_message(text, direction=direction)
    return adjust_tone(text, tone=tone)
