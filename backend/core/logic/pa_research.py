"""
pa_research.py — the deterministic engine behind PA SECRETARY MODE RESEARCH &
PRESENTATION organizer (issue #114, SPEC v2.1 §14, ADVANCED).

The PA organises research for the boss entirely by hand, offline, with NO key:
a research TOPIC, NOTES and SOURCES (title + url/citation the PA typed), a
presentation OUTLINE (ordered SECTIONS, each with ordered BULLET points), and a
deterministic plain-text OUTLINE EXPORT suitable for pasting into slides.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**.
Mirrors the conventions of the other pa_*/logic modules.

HONEST, KEY-GATED — AI RESEARCH / SLIDE-GEN SEAM (NEVER FABRICATES)
-------------------------------------------------------------------
AI-assisted research (finding facts/sources) and slide generation need a real
model. So `ai_seam()` HONESTLY returns `{required: True, mock: True, ...}` — the
UI shows a "connect an AI key" card and the PA writes the notes and outline by
hand. We NEVER invent a researched fact, a citation, or a source URL. The only
text this engine emits is a deterministic reshape of what the PA typed.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_research_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
KIND_NOTE = "note"
KIND_SOURCE = "source"
KINDS = (KIND_NOTE, KIND_SOURCE)

# The honest marker key the AI seam carries. The UI renders the localised
# "connect an AI key" copy from this.
AI_MARKER_KEY = "research_ai_seam"


def _clean(text):
    return " ".join(str(text or "").split()).strip()


def _multiline(text):
    """Trim each line, drop blank lines, collapse inner whitespace. Keeps the
    author's line breaks (bullets/notes) but stays deterministic."""
    out = []
    for ln in str(text or "").replace("\r", "").split("\n"):
        c = _clean(ln)
        if c:
            out.append(c)
    return out


# ------------------------------------------------------------- normalization

def normalize_topic(topic):
    """Coerce a dict into a clean research topic header."""
    t = dict(topic or {})
    return {
        "id": t.get("id"),
        "title": _clean(t.get("title")),
        "goal": str(t.get("goal") or ""),
    }


def normalize_item(item):
    """Coerce a dict into a clean note OR source. Unknown kind → note. A source
    carries an optional `ref` (url / citation the PA typed — never invented)."""
    x = dict(item or {})
    kind = x.get("kind")
    if kind not in KINDS:
        kind = KIND_NOTE
    return {
        "id": x.get("id"),
        "topic_id": x.get("topic_id"),
        "kind": kind,
        "text": str(x.get("text") or "").strip(),
        "ref": _clean(x.get("ref")),
    }


def normalize_section(section):
    """Coerce a dict into a clean outline section. `order` is an int used for
    deterministic ordering; `bullets` is a newline-joined block the PA typed."""
    s = dict(section or {})
    try:
        order = int(s.get("order"))
    except (TypeError, ValueError):
        order = 0
    return {
        "id": s.get("id"),
        "topic_id": s.get("topic_id"),
        "heading": _clean(s.get("heading")),
        "order": order,
        "bullets": str(s.get("bullets") or ""),
    }


# ------------------------------------------------------------------- validate

def validate_topic(topic):
    t = normalize_topic(topic)
    return [] if t["title"] else ["title_required"]


def validate_item(item):
    """A note needs text; a source needs either text or a ref."""
    x = normalize_item(item)
    problems = []
    if x["kind"] == KIND_NOTE and not x["text"]:
        problems.append("text_required")
    if x["kind"] == KIND_SOURCE and not x["text"] and not x["ref"]:
        problems.append("source_required")
    return problems


def validate_section(section):
    s = normalize_section(section)
    return [] if s["heading"] else ["heading_required"]


# ------------------------------------------------------------------ queries

def notes(items):
    """Normalized notes only, input order preserved."""
    return [normalize_item(x) for x in (items or [])
            if normalize_item(x)["kind"] == KIND_NOTE]


def sources(items):
    """Normalized sources only, input order preserved."""
    return [normalize_item(x) for x in (items or [])
            if normalize_item(x)["kind"] == KIND_SOURCE]


def order_sections(sections):
    """New list of normalized sections ordered by `order`, then heading, then
    id for stability. Deterministic; never mutates the input."""
    normed = [normalize_section(s) for s in (sections or [])]
    return sorted(normed, key=lambda s: (s["order"], s["heading"].lower(),
                                         str(s.get("id") or "")))


def section_bullets(section):
    """The section's bullet lines as a clean list (deterministic)."""
    return _multiline(normalize_section(section)["bullets"])


# ---------------------------------------------------------------- summary

def research_summary(topic, items=None, sections=None):
    """Deterministic roll-up for the organiser header + export view."""
    t = normalize_topic(topic)
    ns = notes(items)
    ss = sources(items)
    secs = order_sections(sections)
    bullet_total = sum(len(section_bullets(s)) for s in secs)
    return {
        "topic": t,
        "notes": ns,
        "sources": ss,
        "sections": secs,
        "counts": {
            "notes": len(ns),
            "sources": len(ss),
            "sections": len(secs),
            "bullets": bullet_total,
        },
        # honest: everything here is the PA's own typed research, not AI output.
        "mock": False,
        "ai_required": False,
    }


def outline_export(topic, sections=None, include_sources=False, items=None):
    """A deterministic plain-text outline export the PA can paste into slides.

    Format (pure, repeatable):

        <TOPIC TITLE>

        1. <Section heading>
           - bullet
           - bullet
        2. <Section heading>
           - bullet

        Sources:
        - <source text> (<ref>)      # only when include_sources and present

    Emits ONLY the PA's typed text, reshaped. No AI, no fabricated content."""
    t = normalize_topic(topic)
    lines = []
    if t["title"]:
        lines.append(t["title"])
        lines.append("")
    for i, s in enumerate(order_sections(sections), start=1):
        lines.append(f"{i}. {s['heading']}")
        for b in section_bullets(s):
            lines.append(f"   - {b}")
    if include_sources:
        srcs = sources(items)
        if srcs:
            lines.append("")
            lines.append("Sources:")
            for s in srcs:
                label = s["text"] or s["ref"]
                if s["text"] and s["ref"]:
                    lines.append(f"- {s['text']} ({s['ref']})")
                else:
                    lines.append(f"- {label}")
    # trim a single trailing blank line if present
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


# ------------------------------------------------------------- ai seam

def ai_seam(topic=None, task="research"):
    """DOCUMENTED key-gated seam for AI research / slide generation.

    Honest MOCK: never calls a model, never invents a fact, citation or slide.
    Returns the shape the integrator wires to `core.ai.generate` when an
    `anthropic` key is present. Until then the UI shows a "connect an AI key"
    card and the PA researches and outlines by hand.
    """
    return {
        "action": "ai_research",
        "task": _clean(task) or "research",
        "topic": _clean(topic),
        "result": "",          # honest: empty — no model, nothing invented
        "required": True,      # an AI key is required for a real result
        "mock": True,
        "marker": AI_MARKER_KEY,
    }
