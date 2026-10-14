"""
pa_board.py — the deterministic, key-free engine behind Assisto's
PA SECRETARY MODE · BOARD-MEETING PACK assembler (issue #116, SPEC v2.1 §14,
built to the §21 ADVANCED standard; CORPORATE tier).

WHAT THIS IS
------------
A board-pack assembler. The PA gathers the raw parts of a board meeting —
AGENDA items, the DOCUMENTS circulated, the ATTENDEE list, and the RESOLUTIONS
put to a vote — and the engine ASSEMBLES a correctly-structured, numbered pack
plus a deterministic formatted SUMMARY (a cover-page outline). Nothing is
fabricated: every line is the owner's own text, ordered, numbered and totalled.

    agenda      — ordered items (title + optional presenter + optional minutes)
    documents   — the circulated papers (title + optional ref/tab label)
    attendees   — who attends (name + optional role + present/apology/absent)
    resolutions — motions to vote (text + optional proposer/seconder)

The pack is clearly a MOCK ("AI-generated — review") because the STRUCTURE /
numbering / roll-up is generated; the content is the owner's. It is editable +
copy/share/save-able by the caller.

STRUCTURE IS LANGUAGE-AWARE
---------------------------
Formal pack scaffolding (section headings, "Agenda", "Quorum", "Present",
"Apologies", the minute-total label) differs bn/en, so — exactly like
pa_letters.py — the engine returns a STRUCTURED pack (ordered sections of
{role, text, phrase, num} lines) using NEUTRAL phrase KEYS for the fixed
scaffolding; the UI renders the localised bn/en phrase from the .arb. Owner
field text passes through verbatim; this engine never translates or invents.

QUORUM / ATTENDANCE are COUNTED, never decided
----------------------------------------------
We total present / apologies / absent deterministically and report whether the
count MEETS a quorum the owner typed in — we never invent a legal quorum rule.
If no quorum number is given we simply omit the quorum line (honest).

KEY-GATED, HONEST
-----------------
Assembly needs NO key. An AI-DRAFTED executive summary (prose) is a DOCUMENTED
key-gated seam: `build(..., want_ai_summary=True)` sets `ai_required=True` and
NEVER fabricates prose — the deterministic cover outline is always produced; the
UI shows "connect an AI key for an AI-written executive summary".

PURE — NO DJANGO, NO DB, NO NETWORK, NO CLOCK, NO AI
----------------------------------------------------
Every function is a pure function of its arguments. Hand-verified in
pa_board_tests_snippets.py. Mirrored by app/lib/screens/pa/board_pack_screen.dart.
"""

# ------------------------------------------------------------------ vocabulary

# Section roles the UI styles (section heading, numbered item, roll-up line).
ROLE_TITLE = "title"            # the pack title line (meeting name/date)
ROLE_SECTION = "section"        # a section heading (Agenda / Documents / ...)
ROLE_ITEM = "item"              # a numbered agenda / document / resolution line
ROLE_ATTENDEE = "attendee"      # an attendee line (name — role · status)
ROLE_ROLLUP = "rollup"          # a counted roll-up line (totals / quorum)
ROLE_NOTE = "note"              # a small deterministic note (e.g. empty section)

# Neutral phrase KEYS the UI localises (engine never emits the phrase text).
PHRASE_PACK = "pack"                    # "Board meeting pack" cover label
PHRASE_AGENDA = "agenda"
PHRASE_DOCUMENTS = "documents"
PHRASE_ATTENDEES = "attendees"
PHRASE_RESOLUTIONS = "resolutions"
PHRASE_PRESENT = "present"
PHRASE_APOLOGIES = "apologies"
PHRASE_ABSENT = "absent"
PHRASE_QUORUM_MET = "quorum_met"
PHRASE_QUORUM_SHORT = "quorum_short"
PHRASE_TOTAL_MINUTES = "total_minutes"
PHRASE_TO_VOTE = "to_vote"              # "N resolutions to vote"
PHRASE_EMPTY = "empty"                  # a section with no items yet

# Attendance statuses (owner picks one per attendee; neutral seed keys).
STATUS_PRESENT = "present"
STATUS_APOLOGY = "apology"
STATUS_ABSENT = "absent"
STATUSES = (STATUS_PRESENT, STATUS_APOLOGY, STATUS_ABSENT)

# The honest marker key every pack carries.
MARKER_KEY = "ai_review"


# ------------------------------------------------------------------ helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _int(v, default=0):
    """Parse a non-negative int; never crash. Negative/garbage → default."""
    try:
        n = int(float(str(v).strip()))
        return n if n >= 0 else default
    except (TypeError, ValueError):
        return default


def _norm_status(v):
    v = _clean(v).lower()
    return v if v in STATUSES else STATUS_PRESENT


def _line(role, text="", phrase="", num=0):
    return {"role": role, "text": text, "phrase": phrase, "num": num}


def _rows(items):
    """Accept a list of dicts (or strings) → list of dicts. Deterministic."""
    out = []
    for it in (items or []):
        if isinstance(it, str):
            out.append({"title": it})
        elif isinstance(it, dict):
            out.append(it)
    return out


# ------------------------------------------------------------------ validate

def validate(title="", agenda=None, resolutions=None):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    A pack needs a title and at least one agenda item to be meaningful; a
    resolution row with no text is flagged so the owner fixes it (we never drop
    it silently). Everything else is optional."""
    problems = []
    if not _clean(title):
        problems.append("empty_title")
    agenda_rows = [r for r in _rows(agenda) if _clean(r.get("title"))]
    if not agenda_rows:
        problems.append("empty_agenda")
    for r in _rows(resolutions):
        if not _clean(r.get("text")):
            problems.append("empty_resolution")
            break
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------------ attendance

def count_attendance(attendees=None):
    """Deterministically total present / apologies / absent. PURE."""
    present = apology = absent = 0
    for r in _rows(attendees):
        if not _clean(r.get("name")):
            continue
        st = _norm_status(r.get("status"))
        if st == STATUS_PRESENT:
            present += 1
        elif st == STATUS_APOLOGY:
            apology += 1
        else:
            absent += 1
    return {"present": present, "apologies": apology, "absent": absent,
            "named": present + apology + absent}


# ------------------------------------------------------------------ assembly

def build(title="", meeting_date="", agenda=None, documents=None,
          attendees=None, resolutions=None, quorum=0, want_ai_summary=False):
    """Assemble a board pack as an ordered list of {role,text,phrase,num} lines
    + a counted roll-up. PURE — no clock; `meeting_date` is a passed-in string.

    Returns a dict:
        title, date, lines (list), counts (dict), problems (list),
        ai_required, mock, marker.

    Key-gated: `want_ai_summary=True` → `ai_required=True`; the deterministic
    cover outline is ALWAYS produced (we never fabricate an AI executive
    summary). The owner's own agenda/docs/resolutions text passes through
    verbatim and is numbered."""
    title = _clean(title)
    meeting_date = _clean(meeting_date)
    agenda_rows = [r for r in _rows(agenda) if _clean(r.get("title"))]
    doc_rows = [r for r in _rows(documents) if _clean(r.get("title"))]
    att_rows = [r for r in _rows(attendees) if _clean(r.get("name"))]
    res_rows = [r for r in _rows(resolutions) if _clean(r.get("text"))]
    quorum = _int(quorum)

    problems = validate(title, agenda=agenda, resolutions=resolutions)
    counts = count_attendance(att_rows)
    ai_required = bool(want_ai_summary)

    lines = []

    # ---- cover title
    if title:
        cover = title + ((" — " + meeting_date) if meeting_date else "")
        lines.append(_line(ROLE_TITLE, cover, phrase=PHRASE_PACK))

    # ---- agenda (numbered)
    lines.append(_line(ROLE_SECTION, phrase=PHRASE_AGENDA))
    if agenda_rows:
        for i, r in enumerate(agenda_rows, 1):
            txt = _clean(r.get("title"))
            presenter = _clean(r.get("presenter"))
            minutes = _int(r.get("minutes"))
            if presenter:
                txt += " · " + presenter
            if minutes:
                txt += " (" + str(minutes) + ")"
            lines.append(_line(ROLE_ITEM, txt, num=i))
    else:
        lines.append(_line(ROLE_NOTE, phrase=PHRASE_EMPTY))

    # ---- documents (numbered)
    lines.append(_line(ROLE_SECTION, phrase=PHRASE_DOCUMENTS))
    if doc_rows:
        for i, r in enumerate(doc_rows, 1):
            txt = _clean(r.get("title"))
            ref = _clean(r.get("ref"))
            if ref:
                txt = "[" + ref + "] " + txt
            lines.append(_line(ROLE_ITEM, txt, num=i))
    else:
        lines.append(_line(ROLE_NOTE, phrase=PHRASE_EMPTY))

    # ---- attendees + roll-up
    lines.append(_line(ROLE_SECTION, phrase=PHRASE_ATTENDEES))
    if att_rows:
        for r in att_rows:
            name = _clean(r.get("name"))
            role = _clean(r.get("role"))
            st = _norm_status(r.get("status"))
            st_phrase = {STATUS_PRESENT: PHRASE_PRESENT,
                         STATUS_APOLOGY: PHRASE_APOLOGIES,
                         STATUS_ABSENT: PHRASE_ABSENT}[st]
            txt = name + ((" — " + role) if role else "")
            lines.append(_line(ROLE_ATTENDEE, txt, phrase=st_phrase))
        # counted roll-up line (num carries present count for the UI chip)
        lines.append(_line(ROLE_ROLLUP,
                           "{}/{}/{}".format(counts["present"],
                                             counts["apologies"],
                                             counts["absent"]),
                           phrase=PHRASE_PRESENT, num=counts["present"]))
        if quorum:
            met = counts["present"] >= quorum
            lines.append(_line(
                ROLE_ROLLUP,
                "{}/{}".format(counts["present"], quorum),
                phrase=PHRASE_QUORUM_MET if met else PHRASE_QUORUM_SHORT,
                num=quorum))
    else:
        lines.append(_line(ROLE_NOTE, phrase=PHRASE_EMPTY))

    # ---- resolutions (numbered) + to-vote roll-up
    lines.append(_line(ROLE_SECTION, phrase=PHRASE_RESOLUTIONS))
    if res_rows:
        for i, r in enumerate(res_rows, 1):
            txt = _clean(r.get("text"))
            proposer = _clean(r.get("proposer"))
            seconder = _clean(r.get("seconder"))
            tail = " · ".join([p for p in (proposer, seconder) if p])
            if tail:
                txt += " (" + tail + ")"
            lines.append(_line(ROLE_ITEM, txt, num=i))
        lines.append(_line(ROLE_ROLLUP, str(len(res_rows)),
                           phrase=PHRASE_TO_VOTE, num=len(res_rows)))
    else:
        lines.append(_line(ROLE_NOTE, phrase=PHRASE_EMPTY))

    # total meeting minutes (sum of agenda minutes) — only when any given
    total_minutes = sum(_int(r.get("minutes")) for r in agenda_rows)
    if total_minutes:
        lines.append(_line(ROLE_ROLLUP, str(total_minutes),
                           phrase=PHRASE_TOTAL_MINUTES, num=total_minutes))

    return {
        "title": title,
        "date": meeting_date,
        "lines": lines,
        "counts": counts,
        "problems": problems,
        "ai_required": ai_required,
        "mock": True,
        "marker": MARKER_KEY,
    }
