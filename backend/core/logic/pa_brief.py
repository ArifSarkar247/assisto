"""
pa_brief.py — Assisto PA (Secretary) MEETING REMINDER + 1-PAGE BRIEF
(SPEC v2.1 §14 #104, ADVANCED §21).

For a selected meeting the PA can:
  1. configure a REMINDER (lead-time offsets before the meeting), and
  2. generate a ONE-PAGE BRIEF — who / what / when / where, agenda bullets and
     a prep checklist — assembled DETERMINISTICALLY from the structured fields
     the owner entered.

HONEST, NOT AI
--------------
The brief is a DETERMINISTIC ASSEMBLY of the owner's own entered data. It does
NOT call a model, needs no key, and invents nothing: if a field is empty we omit
it (and tell the UI which sections are missing) rather than hallucinate content.
Same inputs → same brief. An "AI-enhanced brief" (rephrase the owner's notes,
suggest agenda points) is a FUTURE, KEY-GATED seam: `ai_brief_plan()` returns the
request shape a real provider would receive — nothing here calls a model. That
keeps the zero-Bangla-in-dart mirror trivially true as well.

This module is PURE: no Django, no DB, no network, no AI. ``now`` is always
passed in. Hand-verified in pa_brief_tests_snippets.py.

The brief field labels are localised BY THE APP (ARB keys). This module returns
structured DATA (sections, bullets, flags) — never localized prose — so the same
assembly drives bn/en and the share/export text the app builds.
"""
from datetime import datetime, timedelta


def parse_dt(v):
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def _naive(dt):
    return dt.replace(tzinfo=None) if (dt is not None and dt.tzinfo) else dt


# ---------------------------------------------------------------------------
# reminder config
# ---------------------------------------------------------------------------

# Lead-time offsets the PA can toggle, in minutes-before-start. The UI renders a
# label per value; the engine only deals in ints so bn/en can't drift.
LEAD_OPTIONS = (24 * 60, 60, 30, 15, 0)       # 1 day, 1h, 30m, 15m, at-time
DEFAULT_LEADS = (24 * 60, 60)                  # sensible default: 1 day + 1 hour


def clean_leads(offsets):
    """Normalise reminder lead offsets: keep only known LEAD_OPTIONS, de-dup,
    sort descending (earliest reminder first). Empty/garbage → DEFAULT_LEADS.
    We never invent a lead the user didn't pick from the offered set."""
    if offsets is None:
        return list(DEFAULT_LEADS)
    allowed = set(LEAD_OPTIONS)
    seen, out = set(), []
    for o in offsets:
        try:
            m = int(o)
        except (TypeError, ValueError):
            continue
        if m in allowed and m not in seen:
            seen.add(m)
            out.append(m)
    if not out:
        return list(DEFAULT_LEADS)
    return sorted(out, reverse=True)


def reminder_times(start, leads=None, now=None):
    """Concrete fire-times (datetimes) for a meeting's reminders.

    Drops any lead whose fire-time is already <= ``now`` (so we never schedule a
    reminder that should already have fired). De-duplicated, ascending. Returns
    [] if start is unparseable (honest: nothing to remind about).
    """
    s = parse_dt(start)
    if s is None:
        return []
    s = _naive(s)
    now = _naive(now or datetime.now())
    seen, out = set(), []
    for off in clean_leads(leads):
        t = s - timedelta(minutes=off)
        if t <= now:
            continue
        k = t.isoformat()
        if k in seen:
            continue
        seen.add(k)
        out.append(t)
    return sorted(out)


def reminder_summary(start, leads=None, now=None):
    """Small status dict for the reminder config UI::

        {"count": <int>, "next": <datetime or None>, "all_past": bool}

    ``all_past`` is True when leads were chosen but every fire-time is already
    behind ``now`` — the UI then honestly says "these reminders are in the past"
    instead of implying something will fire.
    """
    chosen = clean_leads(leads)
    times = reminder_times(start, leads=leads, now=now)
    all_past = bool(chosen) and parse_dt(start) is not None and not times
    return {"count": len(times),
            "next": times[0] if times else None,
            "all_past": all_past}


# ---------------------------------------------------------------------------
# 1-page brief assembly
# ---------------------------------------------------------------------------

def _lines(raw):
    """Split a free-text block into trimmed, non-empty lines (bullets). Accepts
    a list (each item a bullet) or a newline/• separated string."""
    items = []
    if isinstance(raw, (list, tuple)):
        items = list(raw)
    elif raw:
        for part in str(raw).replace("•", "\n").splitlines():
            items.append(part)
    out, seen = [], set()
    for it in items:
        # strip common bullet prefixes the user may have typed themselves
        t = str(it).strip().lstrip("-*•").strip()
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def assemble_brief(meeting, now=None):
    """Build the structured ONE-PAGE BRIEF from a meeting's entered fields.

    ``meeting`` fields (all optional except the brief is only useful with a
    title + start)::

        title, start, duration_min, place, people (list), purpose/what (str),
        agenda (list|str of bullets), prep (list|str of checklist items),
        note, organiser

    Returns a dict the app renders into a one-page layout and the share/export
    text::

        {
          "title": str,
          "has_core": bool,              # enough to show a brief at all
          "when": {"start": iso|None, "end": iso|None, "duration_min": int},
          "where": str,                  # "" if none
          "who": [names...],             # organiser first if given, de-duped
          "what": str,                   # purpose; "" if none
          "agenda": [bullets...],
          "prep":   [checklist items...],
          "note":   str,
          "missing": [section_keys...],  # HONEST: which sections are empty
          "ai_enhanced": False,          # deterministic assembly, no model
          "mock": True                   # honest marker (never AI here)
        }

    We NEVER fabricate agenda/prep: an empty source yields an empty list and the
    section key goes into ``missing`` so the UI can nudge the owner to fill it
    (or hide the section) honestly.
    """
    m = meeting or {}
    title = str(m.get("title", "")).strip()
    start = parse_dt(m.get("start"))
    duration = m.get("duration_min")
    try:
        duration = int(duration)
        if duration <= 0:
            duration = 30
    except (TypeError, ValueError):
        duration = 30
    end = (_naive(start) + timedelta(minutes=duration)) if start else None

    organiser = str(m.get("organiser", "")).strip()
    people = []
    seen = set()
    for n in ([organiser] if organiser else []) + list(m.get("people") or []):
        nm = str(n).strip()
        if nm and nm not in seen:
            seen.add(nm)
            people.append(nm)

    place = str(m.get("place", "")).strip()
    what = str(m.get("purpose", m.get("what", ""))).strip()
    agenda = _lines(m.get("agenda"))
    prep = _lines(m.get("prep"))
    note = str(m.get("note", "")).strip()

    missing = []
    if not place:
        missing.append("where")
    if not people:
        missing.append("who")
    if not what:
        missing.append("what")
    if not agenda:
        missing.append("agenda")
    if not prep:
        missing.append("prep")

    has_core = bool(title) and start is not None
    return {
        "title": title,
        "has_core": has_core,
        "when": {
            "start": _naive(start).isoformat() if start else None,
            "end": end.isoformat() if end else None,
            "duration_min": duration,
        },
        "where": place,
        "who": people,
        "what": what,
        "agenda": agenda,
        "prep": prep,
        "note": note,
        "missing": missing,
        "ai_enhanced": False,
        "mock": True,
    }


def brief_completeness(meeting):
    """0–100 integer completeness of a brief's content (title+start+the five
    optional sections). Deterministic; the UI shows a small 'brief is N% ready'
    meter so the owner knows what's still worth filling. Never rounds up a blank
    brief to look full."""
    b = assemble_brief(meeting)
    if not b["has_core"]:
        return 0
    # title+start satisfied (core). Five optional sections each worth a slice.
    filled = 5 - len(b["missing"])
    # core counts as a base so a bare title+start isn't 0%.
    base = 20
    return base + int(round((filled / 5.0) * (100 - base)))


# ---------------------------------------------------------------------------
# share / export text (plain, portable) — the app localises labels; this is the
# backend-side share body. Kept ASCII-structural so callers can localise.
# ---------------------------------------------------------------------------

def share_text(meeting, labels=None):
    """Assemble a plain-text one-page brief for share/export.

    ``labels`` is an OPTIONAL dict of localized section labels the CALLER passes
    (the app supplies bn/en from its ARB); when omitted we fall back to neutral
    English keys so the backend can still emit something useful in tests/logs.
    This function emits NO Bangla itself — the localized copy is the app's job.

    Omits empty sections (honest — no "Where: (none)" filler). Returns a string.
    """
    b = assemble_brief(meeting)
    L = {
        "when": "When", "where": "Where", "who": "Who",
        "what": "What", "agenda": "Agenda", "prep": "Prep", "note": "Notes",
    }
    if labels:
        L.update({k: str(v) for k, v in labels.items() if v})

    lines = []
    if b["title"]:
        lines.append(b["title"])
    w = b["when"]
    if w["start"]:
        s = parse_dt(w["start"])
        e = parse_dt(w["end"])
        when = s.strftime("%Y-%m-%d %H:%M")
        if e:
            when += "–" + e.strftime("%H:%M")
        lines.append(f"{L['when']}: {when}")
    if b["where"]:
        lines.append(f"{L['where']}: {b['where']}")
    if b["who"]:
        lines.append(f"{L['who']}: {', '.join(b['who'])}")
    if b["what"]:
        lines.append(f"{L['what']}: {b['what']}")
    if b["agenda"]:
        lines.append(L["agenda"] + ":")
        lines.extend(f"  - {x}" for x in b["agenda"])
    if b["prep"]:
        lines.append(L["prep"] + ":")
        lines.extend(f"  [ ] {x}" for x in b["prep"])
    if b["note"]:
        lines.append(f"{L['note']}: {b['note']}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# FUTURE, KEY-GATED AI seam (documented, NOT built)
# ---------------------------------------------------------------------------

def ai_brief_plan(meeting, lang="bn"):
    """Return the request SHAPE a real provider would receive to produce an
    AI-ENHANCED brief (rephrase notes into crisp agenda points, suggest prep
    items). This NEVER calls a model and needs NO key; it only describes the
    contract so the integrator can wire `core.ai.generate` behind a key later.

    The deterministic ``assemble_brief`` remains the always-available, honest
    path; the AI path is strictly opt-in and key-gated.
    """
    b = assemble_brief(meeting)
    return {
        "task": "enhance_meeting_brief",
        "lang": lang if lang in ("bn", "en") else "bn",
        "source": {  # only the owner's OWN entered data is ever sent
            "title": b["title"],
            "what": b["what"],
            "agenda": b["agenda"],
            "prep": b["prep"],
            "note": b["note"],
        },
        "ai_required": True,   # this path needs a provider key
        "mock": False,
    }
