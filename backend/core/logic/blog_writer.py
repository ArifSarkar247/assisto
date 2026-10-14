"""
blog_writer.py — the deterministic, key-free draft engine behind Assisto's
BLOG & SCRIPT WRITING tool (issue #130, SPEC v2.1 §21, ADVANCED).

The user picks a FORMAT (blog post / video script / social caption / outline),
a TOPIC, a TONE and a LENGTH; we ASSEMBLE a structured draft from a template:
an intro/hook, a body scaffold of sections (headings filled from the topic),
and a CTA — every section seeded with a short PLACEHOLDER PROMPT the user then
completes in their own words. The user edits the draft, copies it, and saves it
to a local draft list. Assisto NEVER auto-posts and never publishes anywhere.

This module is PURE, exactly like `social.py` / `in_chat_ai.py`: no Django, no
DB, no network, no clock, **no AI**. It is a DETERMINISTIC TEMPLATE ASSEMBLER —
same inputs always give the same scaffold — so the on-device Dart mirror
produces an identical preview offline and the tests can pin it.

HONEST AI, KEY-GATED
--------------------
The "AI writes it for you" promise is served, right now, by this deterministic
template engine and is clearly labelled a MOCK ("AI-generated — review"). It
never calls a model and never needs a key. When an AI key is present
(Integrations → `anthropic`, via `core.ai.generate`), the app/executor MAY
route the SAME request shape to the real provider for a full fleshed-out draft —
the request/plan shape here is the contract; nothing in this file calls a model.
Every result carries `ai_required=False, mock=True` so callers stay honest about
which path produced the text, and `marker` carries the honest "review" label key
the UI renders. A fuller AI draft is `ai_full_requires="anthropic"`.

NEVER AUTO-POST
---------------
We only ever produce TEXT. Copying it or saving a draft is a manual action the
user takes; nothing here posts, schedules or publishes. Callers get a plain
string / dict back and decide.

Everything is plain stdlib and hand-verified in blog_writer_tests_snippets.py.
"""

# ---------------------------------------------------------------- vocabulary

# The four supported output formats. The UI localises these keys; the engine
# shapes a different scaffold per format but stays deterministic throughout.
FORMATS = ("blog", "script", "caption", "outline")

# Tone presets. Neutral English seed labels the UI localises. Each selects a
# deterministic hook/closer pair the scaffold is wrapped in.
TONES = ("informative", "casual", "persuasive", "storytelling", "professional")

# Length presets → how many BODY sections the scaffold carries. "short" is a
# tight 2-section skeleton; "long" is a fuller 5-section one. Clamped so the
# mirror and tests pin an exact section count.
LENGTHS = ("short", "medium", "long")
_LENGTH_SECTIONS = {"short": 2, "medium": 3, "long": 5}

# Request-only language tag (bn / Banglish / en). The mock stays neutral English
# seeds (keeps the Dart mirror Bangla-free); a real-AI path answers in `lang`.
LANGS = ("bn", "banglish", "en")

# The honest marker key every result carries. The UI renders the localised
# "AI-generated — review" chip from this; the engine never emits prose.
MARKER_KEY = "ai_review"

# Which Integrations key a FULLER real-AI draft would need. Documented seam.
AI_FULL_KEY = "anthropic"


# Deterministic hook (intro opener) + closer (CTA) skeletons keyed by tone.
# `{topic}` is filled with the cleaned topic. Neutral English seeds the engine
# uses for the MOCK; the Dart mirror carries the same seeds so previews match;
# the real-AI path replaces them. The `[...]` fragments are PLACEHOLDER PROMPTS
# the user completes — the engine never fabricates real claims.
_TONE_HOOK = {
    "informative":  "In this piece we look at {topic} and what it means for you.",
    "casual":       "So, let's talk about {topic} — here's the quick version.",
    "persuasive":   "Here is why {topic} deserves your attention today.",
    "storytelling": "It started with a simple question about {topic}.",
    "professional": "An overview of {topic}: context, detail and next steps.",
}
_TONE_CTA = {
    "informative":  "[Wrap up with the single most useful takeaway about {topic}.]",
    "casual":       "[End with a friendly nudge — ask readers what they think.]",
    "persuasive":   "[Close with a clear call to action you want the reader to take.]",
    "storytelling": "[Land the story on the lesson you drew from {topic}.]",
    "professional": "[State the recommended next step and how to reach you.]",
}

# Deterministic section-heading seeds (used for blog/outline bodies). The engine
# picks the first N for the chosen length. Each pairs with a placeholder prompt.
_SECTION_SEEDS = (
    ("Background", "[Set the scene: what is {topic} and why now?]"),
    ("Key points", "[List the 2-3 points a reader must understand about {topic}.]"),
    ("How it works", "[Explain the mechanics / steps in plain language.]"),
    ("Example", "[Give one concrete, local example readers will recognise.]"),
    ("Common mistakes", "[Note a pitfall to avoid and how to avoid it.]"),
    ("What to do next", "[Give one small action the reader can take today.]"),
)

# Video-script beat seeds (used for the `script` format) — shot-oriented beats
# rather than prose headings. Each beat carries a placeholder direction.
_SCRIPT_BEATS = (
    ("HOOK (0-5s)",   "[Open with a question or bold line about {topic}.]"),
    ("SETUP",         "[In one line, tell viewers what they'll get.]"),
    ("POINT 1",       "[First key point — keep it to one idea.]"),
    ("POINT 2",       "[Second key point with a quick example.]"),
    ("POINT 3",       "[Third key point or a surprising detail.]"),
    ("CALL TO ACTION","[Tell viewers the one thing to do next (like/follow/visit).]"),
)


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None; never empty."""
    t = " ".join(str(text or "").split()).strip()
    return t or "this topic"


def _fill(seed, topic):
    """Fill a seed string's {topic} placeholder deterministically."""
    return seed.replace("{topic}", topic)


# ----------------------------------------------------------------- validate

def validate(fmt, topic, tone="informative", length="medium", lang="en"):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    problems = []
    if fmt not in FORMATS:
        problems.append("bad_format")
    if not str(topic or "").strip():
        problems.append("topic_required")
    if tone not in TONES:
        problems.append("bad_tone")
    if length not in LENGTHS:
        problems.append("bad_length")
    if lang not in LANGS:
        problems.append("bad_lang")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- assembler

def _body_sections(fmt, topic, length):
    """Deterministic list of body sections: [{heading, prompt}], scaled by
    length. Blog/outline use heading seeds; script uses shot beats; caption
    uses a single tight beat set. Always returns at least one section."""
    n = _LENGTH_SECTIONS.get(length, 3)
    if fmt == "script":
        beats = _SCRIPT_BEATS
        # always keep HOOK + CTA; scale the middle points by length
        middle = max(1, n)
        chosen = [beats[0], beats[1]] + list(beats[2:2 + middle]) + [beats[-1]]
        return [{"heading": h, "prompt": _fill(p, topic)} for h, p in chosen]
    if fmt == "caption":
        # a caption is intentionally tiny: one lead beat + one CTA beat
        return [
            {"heading": "Caption", "prompt": _fill(
                "[Write 1-2 punchy lines about {topic}.]", topic)},
            {"heading": "Hashtags", "prompt":
                "[Add 3-5 relevant hashtags — no spaces inside a tag.]"},
        ]
    seeds = _SECTION_SEEDS[:n]
    return [{"heading": h, "prompt": _fill(p, topic)} for h, p in seeds]


def _title_for(fmt, topic):
    """A deterministic working title/slug line for the draft."""
    lead = {"blog": "Blog:", "script": "Script:", "caption": "Caption:",
            "outline": "Outline:"}.get(fmt, "Draft:")
    return f"{lead} {topic}"


def assemble(fmt, topic, tone="informative", length="medium", lang="en"):
    """MAIN ENTRY. Build a deterministic MOCK draft scaffold for the inputs.

    Returns a dict the app renders + lets the user edit:

        {
          "format", "tone", "length", "lang",
          "title":    "<working title line>",
          "hook":     "<intro opener, topic-filled>",
          "sections": [{"heading", "prompt"}, ...],   # placeholder prompts
          "cta":      "<closing prompt, topic-filled>",
          "text":     "<the whole scaffold joined into editable markdown>",
          "marker":   "ai_review",
          "ai_required": False,          # this mock never needs a key
          "ai_full_requires": "anthropic",  # a FULLER AI draft is key-gated
          "mock": True,                  # HONEST: template scaffold, not real AI
          "problems": [...]              # validate() keys; non-empty ⇒ invalid
        }

    Deterministic: identical inputs → identical output. No model, no key, no
    network, no clock. `lang` only tags the request. The scaffold's prose stays
    neutral English seeds + bracketed placeholder prompts the user completes —
    so nothing is fabricated as fact and the Dart mirror is trivially Bangla-free.
    """
    problems = validate(fmt, topic, tone, length, lang)
    topic = _clean(topic)
    hook = _fill(_TONE_HOOK.get(tone, _TONE_HOOK["informative"]), topic)
    cta = _fill(_TONE_CTA.get(tone, _TONE_CTA["informative"]), topic)
    sections = _body_sections(fmt, topic, length)
    title = _title_for(fmt, topic)

    # Join into a single editable markdown-ish block. Headings as "## " lines,
    # each followed by its placeholder prompt on its own line. Deterministic.
    lines = ["# " + title, "", hook, ""]
    for s in sections:
        lines.append("## " + s["heading"])
        lines.append(s["prompt"])
        lines.append("")
    lines.append(cta)
    text = "\n".join(lines).strip()

    return {
        "format": fmt,
        "tone": tone,
        "length": length,
        "lang": lang,
        "title": title,
        "hook": hook,
        "sections": sections,
        "cta": cta,
        "text": text,
        "marker": MARKER_KEY,
        "ai_required": False,          # the mock is deterministic + key-free
        "ai_full_requires": AI_FULL_KEY,  # documented key-gated richer seam
        "mock": True,                  # honest: template scaffold, review
        "problems": problems,
    }


def section_count(length):
    """How many body sections a length yields (UI can preview this). Total."""
    return _LENGTH_SECTIONS.get(length, 3)
