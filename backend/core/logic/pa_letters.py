"""
pa_letters.py — the deterministic, key-free engine behind Assisto's
PA SECRETARY MODE · LETTERS / NOTICES / MEMOS generator (issue #107,
SPEC v2.1 §14, built to the §21 ADVANCED standard).

WHAT THIS IS
------------
A formal-document generator. The PA picks a TYPE and fills a few fields; the
engine ASSEMBLES a correctly-structured formal document from a fixed template.
Four types, each with the right formal skeleton:

    letter      — formal letter: date, recipient block, subject, salutation,
                  body, closing + sender.
    notice      — a headed NOTICE with a reference date, subject and body (the
                  shape an office pins to a board / circulates).
    memo        — an internal memo: TO / FROM / DATE / SUBJECT header, body.
    application — a formal application "to" an authority, subject, body, closing.

The body is assembled from the owner's `body_points` (one paragraph/line each)
— so the OUTPUT IS THE OWNER'S OWN WORDS, formatted. The document is clearly a
MOCK ("AI-generated — review") because the STRUCTURE is generated; it is
editable + copy/share/save-able by the caller. Nothing is fabricated.

STRUCTURE IS LANGUAGE-AWARE
---------------------------
Formal Bangla and formal English differ in their fixed phrases (date label,
salutation, closing). To keep this file Bangla-free, the engine returns a
STRUCTURED document (ordered list of {role, text} lines) using NEUTRAL phrase
KEYS for the fixed scaffolding (e.g. role="salutation", key="dear"); the UI
renders the localised Bangla/English phrase for each key from the .arb. The
owner's own field text (recipient, subject, body points) is passed through
verbatim — this engine never translates and never invents content.

KEY-GATED, HONEST
-----------------
Template assembly needs NO key — the feature is a usable template-based
document generator offline. A fully AI-WRITTEN body is a DOCUMENTED key-gated
seam: `build(..., want_ai_body=True)` with no body_points returns
`ai_required=True` and an empty body section + the honest marker, so the UI
shows "connect an AI key for an AI-written body" and never fabricates prose.

PURE — NO DJANGO, NO DB, NO NETWORK, NO CLOCK, NO AI
----------------------------------------------------
Every function is a pure function of its arguments; `date` is passed IN (no
clock) so the Dart mirror (letters_screen.dart) and the tests pin identical
output. Hand-verified in pa_letters_tests_snippets.py.
"""

# ------------------------------------------------------------------ vocabulary

TYPE_LETTER = "letter"
TYPE_NOTICE = "notice"
TYPE_MEMO = "memo"
TYPE_APPLICATION = "application"
TYPES = (TYPE_LETTER, TYPE_NOTICE, TYPE_MEMO, TYPE_APPLICATION)

# Line roles the UI styles (heading bold/centred, label bold inline, etc.).
ROLE_DATE = "date"          # a right/left date line
ROLE_RECIPIENT = "recipient"  # "To, <name/address>"
ROLE_SENDER = "sender"      # "From, <name>"
ROLE_SUBJECT = "subject"    # "Subject: <...>" / notice heading
ROLE_HEADING = "heading"    # centred NOTICE / MEMO heading
ROLE_SALUTATION = "salutation"  # "Dear ...," / "Respected ...,"
ROLE_BODY = "body"          # a body paragraph (owner's own words)
ROLE_CLOSING = "closing"    # "Yours sincerely," / "Yours faithfully,"
ROLE_LABEL = "label"        # a TO/FROM/DATE/SUBJECT labelled header line (memo)

# Neutral phrase KEYS the UI localises. The engine never emits the phrase text
# itself (keeps the file Bangla-free); it emits the key in `phrase`.
PHRASE_TO = "to"
PHRASE_FROM = "from"
PHRASE_DATE = "date"
PHRASE_SUBJECT = "subject"
PHRASE_DEAR = "dear"              # letter salutation
PHRASE_RESPECTED = "respected"    # application salutation
PHRASE_YOURS_SINCERELY = "yours_sincerely"   # letter closing
PHRASE_YOURS_FAITHFULLY = "yours_faithfully"  # application closing
PHRASE_NOTICE = "notice"          # centred NOTICE heading
PHRASE_MEMO = "memo"              # centred MEMO heading

# The honest marker key every document carries.
MARKER_KEY = "ai_review"


# ------------------------------------------------------------------ helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _norm_type(v):
    v = _clean(v).lower()
    return v if v in TYPES else TYPE_LETTER


def _points(body_points):
    """Normalise body points to a list of non-empty trimmed strings. Accepts a
    list or a newline/blank-line separated string. Deterministic; drops empties.
    """
    if body_points is None:
        return []
    if isinstance(body_points, str):
        raw = body_points.replace("\r\n", "\n").split("\n")
    else:
        raw = list(body_points)
    out = []
    for p in raw:
        s = _clean(p)
        if s:
            out.append(s)
    return out


def _line(role, text="", phrase=""):
    return {"role": role, "text": text, "phrase": phrase}


# ------------------------------------------------------------------ validate

def validate(doc_type=TYPE_LETTER, to="", subject="", body_points=None):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    Every type needs a subject; letter/memo/application need a recipient (`to`);
    a notice may be general (no single recipient) so `to` is optional there."""
    problems = []
    t = _clean(doc_type).lower()
    if t not in TYPES:
        problems.append("bad_type")
        t = TYPE_LETTER
    if not _clean(subject):
        problems.append("empty_subject")
    if t != TYPE_NOTICE and not _clean(to):
        problems.append("empty_recipient")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------------ assembly

def build(doc_type=TYPE_LETTER, to="", sender="", subject="",
          body_points=None, date="", want_ai_body=False):
    """Assemble a formal document as an ordered list of {role, text, phrase}
    lines. PURE — `date` is passed in (string, no clock).

    Returns a dict:
        type, lines (list), problems (list), ai_required, mock, marker.

    Key-gated: `want_ai_body=True` with NO body points → `ai_required=True` and
    the body section omitted + the honest marker, so the UI shows the "connect
    an AI key for an AI-written body" state and never fabricates prose. With
    body points present we always assemble them (the owner's own words).
    """
    t = _norm_type(doc_type)
    to = _clean(to)
    sender = _clean(sender)
    subject = _clean(subject)
    date = _clean(date)
    points = _points(body_points)

    problems = validate(t, to=to, subject=subject, body_points=points)

    # key-gated AI body: only when the owner explicitly asked for an AI body AND
    # supplied no points of their own. We never fabricate the body here.
    ai_required = bool(want_ai_body and not points)

    lines = []

    if t == TYPE_MEMO:
        lines.append(_line(ROLE_HEADING, phrase=PHRASE_MEMO))
        lines.append(_line(ROLE_LABEL, to, phrase=PHRASE_TO))
        lines.append(_line(ROLE_LABEL, sender, phrase=PHRASE_FROM))
        lines.append(_line(ROLE_LABEL, date, phrase=PHRASE_DATE))
        lines.append(_line(ROLE_LABEL, subject, phrase=PHRASE_SUBJECT))
        if not ai_required:
            for p in points:
                lines.append(_line(ROLE_BODY, p))

    elif t == TYPE_NOTICE:
        lines.append(_line(ROLE_HEADING, phrase=PHRASE_NOTICE))
        if date:
            lines.append(_line(ROLE_DATE, date, phrase=PHRASE_DATE))
        lines.append(_line(ROLE_SUBJECT, subject, phrase=PHRASE_SUBJECT))
        if to:
            lines.append(_line(ROLE_RECIPIENT, to, phrase=PHRASE_TO))
        if not ai_required:
            for p in points:
                lines.append(_line(ROLE_BODY, p))

    elif t == TYPE_APPLICATION:
        if date:
            lines.append(_line(ROLE_DATE, date, phrase=PHRASE_DATE))
        lines.append(_line(ROLE_RECIPIENT, to, phrase=PHRASE_TO))
        lines.append(_line(ROLE_SUBJECT, subject, phrase=PHRASE_SUBJECT))
        lines.append(_line(ROLE_SALUTATION, phrase=PHRASE_RESPECTED))
        if not ai_required:
            for p in points:
                lines.append(_line(ROLE_BODY, p))
        lines.append(_line(ROLE_CLOSING, phrase=PHRASE_YOURS_FAITHFULLY))
        if sender:
            lines.append(_line(ROLE_SENDER, sender, phrase=PHRASE_FROM))

    else:  # TYPE_LETTER
        if date:
            lines.append(_line(ROLE_DATE, date, phrase=PHRASE_DATE))
        lines.append(_line(ROLE_RECIPIENT, to, phrase=PHRASE_TO))
        lines.append(_line(ROLE_SUBJECT, subject, phrase=PHRASE_SUBJECT))
        lines.append(_line(ROLE_SALUTATION, phrase=PHRASE_DEAR))
        if not ai_required:
            for p in points:
                lines.append(_line(ROLE_BODY, p))
        lines.append(_line(ROLE_CLOSING, phrase=PHRASE_YOURS_SINCERELY))
        if sender:
            lines.append(_line(ROLE_SENDER, sender, phrase=PHRASE_FROM))

    return {
        "type": t,
        "lines": lines,
        "problems": problems,
        "ai_required": ai_required,
        "mock": True,
        "marker": MARKER_KEY,
    }
