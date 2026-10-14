"""
quick_tools.py — the deterministic, key-free engine behind Assisto's QUICK
TOOLS toolbox (#17, SPEC v2.1 §6, built to ADVANCED §21).

A small "toolbox over text": the user pastes/writes some text and taps one of a
handful of bounded transforms:

    * summarise       — an extractive digest (first + key sentences), not AI
    * fix_grammar     — rule-based spacing/punctuation/capitalisation cleanups
    * translate       — HONEST: a direction hint + a small built-in common-phrase
                        fallback; a real translation needs the key-gated AI route
    * change_tone     — deterministic template reframing (polite/shorter/warmer/
                        firmer/formal)
    * make_shareable  — tidy + a one-line lead + a short attribution footer,
                        clamped to a share-friendly length

This module is PURE, exactly like `social.py` / `in_chat_ai.py`: no Django, no
DB, no network, no clock, **no AI**. It is a DETERMINISTIC engine — identical
inputs always give identical output — so the on-device Dart mirror produces the
same result offline and the tests can pin it.

HONEST AI, KEY-GATED
--------------------
Every transform the mock produces is clearly labelled a MOCK ("AI-generated —
review"). It never calls a model and never needs a key. `translate` is honest:
it returns the detected direction plus a built-in common-phrase rendering when
the whole input is a known phrase, and otherwise `ai_required=True` with an
empty `translated` — it NEVER fabricates a sentence-level translation. When an
AI key is present (Integrations → `anthropic`, via `core.ai.generate`) the
app/executor MAY route the SAME request shape to the real provider for a richer
result — `ai_plan()` describes that contract; nothing here calls a model.

NEVER AUTO-SEND
---------------
We only ever produce TEXT. Copying or sharing it is a manual action the user
takes; nothing here sends/posts anything.

Hand-verified in quick_tools_tests_snippets.py.
"""
import re

# The bounded actions this toolbox offers. The UI localises these keys.
ACTIONS = ("summarise", "fix_grammar", "translate", "change_tone",
           "make_shareable")

# Tone presets for change_tone. Neutral English seed templates; the UI localises
# the chip labels. Kept in lockstep with the Dart mirror.
TONES = ("polite", "shorter", "warmer", "firmer", "formal")

# Translate direction hints. "auto" guesses from the script.
DIRECTIONS = ("auto", "bn2en", "en2bn")

# How many sentences an extractive summary keeps, at most.
MAX_SUMMARY = 3

# Share-friendly clamp for make_shareable (comfortable for a status/caption).
SHARE_LIMIT = 500

# The honest marker key every result carries. The UI renders the localised
# "AI-generated — review" chip from this; the engine never emits prose.
MARKER_KEY = "ai_review"


# ------------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse runs of whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _has_bangla(text):
    """True if any character is in the Bengali Unicode block (U+0980–U+09FF).
    Used only to GUESS translate direction; never to emit Bangla here."""
    for ch in str(text or ""):
        if "ঀ" <= ch <= "৿":
            return True
    return False


def _sentences(text):
    """Split into trimmed sentence fragments on . ! ? । (Bangla danda) and
    newlines, KEEPING the terminator so a rebuilt summary reads naturally.
    Deterministic; drops empties."""
    out = []
    buf = ""
    for ch in str(text or ""):
        buf += ch
        if ch in ".!?।\n":
            s = buf.strip()
            if s:
                out.append(s)
            buf = ""
    tail = buf.strip()
    if tail:
        out.append(tail)
    return out


def _word_count(text):
    return len(_clean(text).split())


# ------------------------------------------------------------------- validate

def validate(action, text="", tone="polite", direction="auto"):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    problems = []
    if action not in ACTIONS:
        problems.append("bad_action")
        return problems
    if not _clean(text):
        problems.append("empty_text")
    if action == "change_tone" and tone not in TONES:
        problems.append("bad_tone")
    if action == "translate" and direction not in DIRECTIONS:
        problems.append("bad_direction")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------------- summarise

# Words that make a sentence more likely to be a "key" point. Deterministic
# scoring only — no model. Neutral English seeds (zero Bangla); the Dart mirror
# carries the same set so previews match.
_KEY_HINTS = ("important", "must", "need", "because", "result", "deadline",
              "please", "note", "remember", "total", "decision", "summary")


def _score_sentence(sentence, index, total):
    """Deterministic extractive score: earlier sentences weigh more (lead bias),
    key-hint words add weight, and a mid-length sentence is preferred over a
    very short or very long one. Pure integer math so it never drifts."""
    words = sentence.lower().split()
    n = len(words)
    score = 0
    # lead bias: first two sentences get a bump
    if index == 0:
        score += 5
    elif index == 1:
        score += 2
    # key-hint words
    for h in _KEY_HINTS:
        if h in sentence.lower():
            score += 2
    # length sweet spot (6–30 words)
    if 6 <= n <= 30:
        score += 2
    elif n < 4:
        score -= 1
    return score


def summarise(text):
    """MOCK: an extractive digest — keep the highest-scoring sentences (up to
    MAX_SUMMARY), restored to their ORIGINAL order so the summary reads top to
    bottom. If there is only one sentence we return it as-is. No AI, no
    invention — every word in the output came from the input."""
    text = _clean(text)
    sents = _sentences(text)
    if len(sents) <= 1:
        kept = sents
    else:
        total = len(sents)
        scored = [(_score_sentence(s, i, total), i, s)
                  for i, s in enumerate(sents)]
        # pick top-N by score, break ties by original order (stable)
        top = sorted(scored, key=lambda t: (-t[0], t[1]))[:MAX_SUMMARY]
        kept = [s for _, i, s in sorted(top, key=lambda t: t[1])]
    summary = " ".join(kept)
    return {
        "action": "summarise",
        "source": text,
        "result": summary,
        "kept": len(kept),
        "total": len(sents),
        "ai_required": False,
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("summarise", text=text),
    }


# ------------------------------------------------------------------ fix_grammar

def fix_grammar(text):
    """MOCK: rule-based mechanical cleanups only — this is NOT a grammar model
    and does not rewrite phrasing. Deterministic fixes:

        * collapse repeated whitespace; strip leading/trailing space
        * no space BEFORE . , ! ? ; : and exactly one space AFTER them
        * collapse repeated terminal punctuation (!!!, ??, ...→keep one . )
        * capitalise the first letter of each sentence
        * capitalise a standalone 'i' (English pronoun)

    We list each kind of change we made (as keys the UI localises) so the user
    sees it is mechanical, not a rephrase. Bangla text passes through the
    whitespace/spacing rules only (capitalisation is a no-op for Bangla)."""
    original = _clean(text)
    s = original
    changes = []

    # 1. no space before punctuation
    s2 = re.sub(r"\s+([.,!?;:।])", r"\1", s)
    if s2 != s:
        changes.append("space_before_punct")
    s = s2

    # 2. collapse repeated terminal punctuation (keep a single mark)
    s2 = re.sub(r"([.!?।])\1{1,}", r"\1", s)
    if s2 != s:
        changes.append("repeat_punct")
    s = s2

    # 3. exactly one space after . , ! ? ; : when followed by a word char
    s2 = re.sub(r"([.,!?;:।])(?=[^\s\d])", r"\1 ", s)
    s2 = " ".join(s2.split())
    if s2 != s:
        changes.append("space_after_punct")
    s = s2

    # 4. capitalise 'i' as a standalone English pronoun
    s2 = re.sub(r"(?<![\w'])i(?![\w'])", "I", s)
    if s2 != s:
        changes.append("capital_i")
    s = s2

    # 5. capitalise the first ASCII letter of each sentence
    def _cap(sent):
        for idx, ch in enumerate(sent):
            if ch.isalpha():
                if "a" <= ch <= "z":
                    return sent[:idx] + ch.upper() + sent[idx + 1:]
                return sent
        return sent
    sents = _sentences(s)
    capped = " ".join(_cap(x) for x in sents) if sents else s
    if capped != s:
        changes.append("capital_sentence")
    s = capped

    return {
        "action": "fix_grammar",
        "source": original,
        "result": s.strip(),
        "changes": changes,
        "changed": s.strip() != original,
        "ai_required": False,
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("fix_grammar", text=text),
    }


# -------------------------------------------------------------------- translate

# A SMALL built-in common-phrase table so the key-free mock can honestly render
# a few everyday greetings both ways. This is NOT a translator — only whole-input
# exact matches (case/space-insensitive) are rendered; everything else honestly
# needs the AI key. The bn side lives in the BACKEND engine only (source of
# truth); the Dart mirror keeps the SAME table (its .dart is allowed phrase data
# via the ARB? no — the Dart mirror carries romanised keys + looks up bn from a
# generated map, see integration notes). Here the engine is the source of truth.
_PHRASES = {
    # en -> bn
    "hello": "হ্যালো",
    "thank you": "ধন্যবাদ",
    "thanks": "ধন্যবাদ",
    "good morning": "সুপ্রভাত",
    "good night": "শুভ রাত্রি",
    "how are you": "কেমন আছেন",
    "yes": "হ্যাঁ",
    "no": "না",
    "sorry": "দুঃখিত",
    "welcome": "স্বাগতম",
}
# Reverse map (bn -> en) built once, deterministically.
_PHRASES_REV = {}
for _en, _bn in _PHRASES.items():
    _PHRASES_REV.setdefault(_bn, _en)


def translate(text, direction="auto"):
    """MOCK: an honest translate helper.

    * Detects direction (auto → bn2en if the input has Bangla, else en2bn).
    * If the WHOLE cleaned input is a known common phrase, renders it from the
      built-in table and returns it (ai_required=False) — a genuine, if tiny,
      offline translation.
    * Otherwise returns the direction + original with an EMPTY `translated` and
      `ai_required=True`: a real sentence translation needs the key-gated AI
      route. We NEVER fabricate a translation and pass it off as real.
    """
    text = _clean(text)
    if direction == "auto":
        direction = "bn2en" if _has_bangla(text) else "en2bn"
    table = _PHRASES_REV if direction == "bn2en" else _PHRASES
    key = text.lower() if direction == "en2bn" else text
    hit = table.get(key)
    return {
        "action": "translate",
        "direction": direction,
        "source": text,
        "translated": hit or "",
        "phrase_hit": bool(hit),
        # a phrase hit is a real (tiny) translation; anything else needs the key
        "ai_required": not bool(hit),
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("translate", text=text, direction=direction),
    }


# ------------------------------------------------------------------ change_tone

# Deterministic tone skeletons. `{text}` is the user's text; `{short}` the lead.
# Neutral English seeds (zero Bangla) so the Dart mirror matches and the file
# stays Bangla-free; the real-AI path replaces these for a richer rewrite.
_TONE_WRAP = {
    "polite":  "Could you please consider this: {text} Thank you.",
    "shorter": "{short}",
    "warmer":  "Hope you're doing well! {text} Take care.",
    "firmer":  "To be clear: {text} Please confirm.",
    "formal":  "Dear recipient, I would like to note the following: {text} Regards.",
}


def change_tone(text, tone="polite"):
    """MOCK: reframe text in a chosen tone, deterministically. "shorter" keeps
    the first sentence (or first 12 words); the others wrap the text in a fixed
    skeleton. Honestly a MOCK the user reviews and edits before use."""
    text = _clean(text)
    sents = _sentences(text)
    short_lead = sents[0] if sents else " ".join(text.split()[:12])
    wrap = _TONE_WRAP.get(tone, _TONE_WRAP["polite"])
    result = _clean(wrap.format(text=text, short=short_lead))
    return {
        "action": "change_tone",
        "tone": tone,
        "source": text,
        "result": result,
        "ai_required": False,
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("change_tone", text=text, tone=tone),
    }


# ---------------------------------------------------------------- make_shareable

def make_shareable(text):
    """MOCK: tidy the text into something comfortable to paste as a status /
    message — collapse whitespace, keep it within SHARE_LIMIT (cut on a word
    boundary with an ellipsis, never mid-word), and surface a one-line lead the
    UI can show as a preview. Adds nothing the user didn't write (no fabricated
    hashtags/emoji here — that is the social composer's job). Deterministic."""
    text = _clean(text)
    sents = _sentences(text)
    lead = sents[0] if sents else text
    body = text
    truncated = False
    if len(body) > SHARE_LIMIT:
        cut = body[:SHARE_LIMIT]
        sp = cut.rfind(" ")
        if sp > SHARE_LIMIT // 2:
            cut = cut[:sp]
        body = cut.rstrip() + "…"   # … ellipsis
        truncated = True
    return {
        "action": "make_shareable",
        "source": text,
        "result": body,
        "lead": lead if len(lead) <= 120 else lead[:117].rstrip() + "…",
        "truncated": truncated,
        "limit": SHARE_LIMIT,
        "ai_required": False,
        "mock": True,
        "marker": MARKER_KEY,
        "problems": validate("make_shareable", text=text),
    }


# ----------------------------------------------------------------- dispatch

def run(action, text="", tone="polite", direction="auto"):
    """Single entry point mirroring the request shape the real-AI route takes.

    Returns the matching transform's dict, or an error dict with `problems` when
    inputs are invalid (so callers never crash on bad input). This is the
    contract the integrator wires to `core.ai.generate` for the richer path."""
    problems = validate(action, text=text, tone=tone, direction=direction)
    if problems:
        return {"action": action, "problems": problems, "mock": True,
                "ai_required": action == "translate", "marker": MARKER_KEY,
                "source": _clean(text), "result": ""}
    if action == "summarise":
        return summarise(text)
    if action == "fix_grammar":
        return fix_grammar(text)
    if action == "translate":
        return translate(text, direction=direction)
    if action == "change_tone":
        return change_tone(text, tone=tone)
    return make_shareable(text)


# ----------------------------------------------------------------- AI seam

def ai_plan(action, text="", tone="polite", direction="auto", lang="bn"):
    """Return the request SHAPE a real provider would receive to produce a RICHER
    result for a quick-tool action (a true translation, a fuller rewrite, an
    abstractive summary). This NEVER calls a model and needs NO key; it only
    describes the contract so the integrator can wire `core.ai.generate` behind
    the `anthropic` key later. The deterministic transforms above stay the
    always-available, honest path; the AI path is strictly opt-in + key-gated.
    Only the user's OWN text is ever sent; it is wrapped in a DATA fence by
    `core/ai.py` so the text is never interpreted as an instruction."""
    task_map = {
        "summarise": "summarise_text",
        "fix_grammar": "proofread_text",
        "translate": "translate_text",
        "change_tone": "rewrite_tone",
        "make_shareable": "make_shareable_text",
    }
    return {
        "task": task_map.get(action, "quick_tool"),
        "action": action,
        "lang": lang if lang in ("bn", "en") else "bn",
        "tone": tone if tone in TONES else "polite",
        "direction": direction if direction in DIRECTIONS else "auto",
        "source": _clean(text),   # only the user's own text is ever sent
        "ai_required": True,      # this path needs the anthropic key
        "mock": False,
    }
