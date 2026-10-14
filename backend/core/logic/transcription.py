"""
transcription.py — pure, deterministic engine behind Assisto's CALL & VOICE-NOTE
TRANSCRIPTION organiser (#92, SPEC v2.1 §21, ADVANCED, KEY-GATED).

This module is PURE — exactly like `in_chat_ai.py` / `probashi.py`: no Django,
no DB, no network, **no speech-to-text model**, no live clock (all time is
passed in). It manages the ORGANISER half of the feature so the whole thing is
useful with no key at all:

  * a voice-note entry has a title, a duration (seconds), a date, an optional
    audio reference, a (possibly manual) transcript, and free notes;
  * `normalize_note` cleans one row to a canonical, total shape;
  * `search_notes` filters a list by a query over title / transcript / notes;
  * `note_stats` rolls up count + total duration (for the list header);
  * `word_count` / `reading_time` are deterministic transcript helpers.

HONEST, KEY-GATED (NEVER FABRICATE A TRANSCRIPT)
------------------------------------------------
Auto speech-to-text is a DOCUMENTED key-gated SEAM. `transcribe_request(note)`
returns the request SHAPE the integrator wires to the real STT provider
(Integrations → `transcription`: Deepgram / Google STT / Whisper). This module
NEVER calls a model and NEVER invents transcript text — when no key is present,
`transcribe_request` returns `ready=False` with the honest
`marker="stt_needs_key"` reason so the UI shows a "connect a transcription key
to auto-transcribe" state. The user can ALWAYS type/edit a transcript by hand;
a manual transcript is labelled `source="manual"` and is never presented as a
machine transcription.

AUDIO CAPTURE SEAM
------------------
Real audio capture (microphone / call recording) is the DEVICE's job and is a
documented seam too — a row stores only a reference string (`audio_ref`, e.g. a
local file name or an opaque id) plus the duration. This module computes nothing
from the audio bytes; it never has them. Recording a phone CALL is subject to
local law and all-party consent — the UI must surface that; this module only
stores a flag `consent_ack` the caller sets and never defaults to True.

Everything is plain stdlib and hand-verified in transcription_tests_snippets.py.

Run self-tests (no DB):
    python3 -c "import core.logic.transcription_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ----------------------------------------------------------------- constants

# Transcript provenance. "manual" = the user typed/edited it themselves;
# "auto" = produced by the key-gated STT seam (only the integrator sets this,
# never this module). "" = no transcript yet.
SOURCES = ("", "manual", "auto")

# The honest marker the UI renders when auto-STT is unavailable (no key).
STT_MARKER = "stt_needs_key"

# Words-per-minute used only to estimate a reading time for a transcript.
# Deterministic constant; purely a display convenience.
WPM = 160

# Clamp duration to a sane non-negative integer-seconds range so bad input
# never produces a negative total or a wild header number.
MAX_DURATION = 24 * 3600  # 24h, generous upper bound


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse internal whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _multiline(text):
    """Trim each line, drop trailing blank lines, keep paragraph breaks.
    Used for transcript/notes where newlines are meaningful."""
    lines = [ln.rstrip() for ln in str(text or "").replace("\r\n", "\n").split("\n")]
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines)


def clamp_duration(v):
    """Coerce a duration to an int number of SECONDS in [0, MAX_DURATION]."""
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return 0
    if n < 0:
        return 0
    return min(n, MAX_DURATION)


def fmt_duration(seconds):
    """Format integer seconds as M:SS, or H:MM:SS past an hour. Deterministic."""
    s = clamp_duration(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{sec:02d}"
    return f"{m}:{sec:02d}"


def word_count(text):
    """Whitespace word count of a transcript. 0 for empty/None."""
    return len(_clean(text).split()) if _clean(text) else 0


def reading_time(text):
    """Deterministic estimate of minutes to read a transcript (>=1 if any
    words), computed from WPM. Purely a display aid."""
    w = word_count(text)
    if w == 0:
        return 0
    return max(1, (w + WPM - 1) // WPM)


# ----------------------------------------------------------------- validate

def validate(note):
    """Return a list of problem keys (empty => valid). The UI localises these.

    A note needs at least a title. Duration must be coercible to a non-negative
    number (we clamp rather than reject, so only a present-but-garbage title
    fails). `source` must be known; an "auto" source requires non-empty
    transcript text (you cannot mark empty text as an auto transcript)."""
    problems = []
    note = note or {}
    if not _clean(note.get("title")):
        problems.append("empty_title")
    src = note.get("source", "")
    if src not in SOURCES:
        problems.append("bad_source")
    elif src == "auto" and not _clean(note.get("transcript")):
        problems.append("auto_without_text")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- normalize

def normalize_note(note):
    """Clean ONE voice-note row to a canonical, total shape the store round-trips.

    Never fabricates a transcript: `transcript` is only what the caller passed.
    `source` is forced to "manual" whenever there is transcript text but the
    caller left the source blank — because the only way text got there with no
    key is that a human typed it. `source` is NEVER auto-promoted to "auto"."""
    note = note or {}
    title = _clean(note.get("title"))
    transcript = _multiline(note.get("transcript"))
    notes = _multiline(note.get("notes"))
    src = note.get("source", "")
    if src not in SOURCES:
        src = ""
    if transcript and src == "":
        src = "manual"
    if not transcript:
        src = ""  # no text => no provenance to claim
    out = {
        "title": title,
        "duration": clamp_duration(note.get("duration")),
        "date": _clean(note.get("date")),
        "audio_ref": _clean(note.get("audio_ref")),
        "consent_ack": bool(note.get("consent_ack")),
        "transcript": transcript,
        "source": src,
        "notes": notes,
        "words": word_count(transcript),
        "read_min": reading_time(transcript),
    }
    out["problems"] = validate(out)
    return out


# ----------------------------------------------------------------- search

def search_notes(notes, query, lang="bn"):
    """Filter + annotate a list of notes by a case-insensitive query over
    title / transcript / notes. Empty query returns all (normalized). Order is
    preserved (deterministic). Each row is normalized on the way out so the
    caller gets totals even for rows stored before a field existed."""
    q = _clean(query).lower()
    out = []
    for raw in (notes or []):
        n = normalize_note(raw)
        # keep the store id if present so the UI can edit/delete the row
        if isinstance(raw, dict) and "id" in raw:
            n["id"] = raw["id"]
        if q:
            hay = " ".join([n["title"], n["transcript"], n["notes"]]).lower()
            if q not in hay:
                continue
        out.append(n)
    return out


def note_stats(notes):
    """Roll-up for the list header: count + total duration (seconds) + a human
    total-duration string + how many already have a transcript. Deterministic."""
    rows = [normalize_note(n) for n in (notes or [])]
    total_dur = sum(r["duration"] for r in rows)
    transcribed = sum(1 for r in rows if r["transcript"])
    return {
        "count": len(rows),
        "total_duration": total_dur,
        "total_duration_human": fmt_duration(total_dur),
        "transcribed": transcribed,
        "untranscribed": len(rows) - transcribed,
    }


# ----------------------------------------------------------------- STT seam

def transcribe_request(note, has_key=False):
    """Build the request SHAPE for the key-gated STT seam — NEVER a transcript.

    This is the contract the integrator wires to the real provider
    (Integrations → `transcription`). When `has_key` is False we HONESTLY return
    `ready=False` with `marker=STT_MARKER` so the UI shows "connect a
    transcription key to auto-transcribe". When True we return `ready=True` with
    the `audio_ref` + `duration` to send — but THIS MODULE STILL RETURNS NO
    TEXT; the executor performs the actual call. We never fabricate.

    `missing` lists why a request can't be built yet (no audio reference, etc.)
    so the UI can prompt precisely. `ai_required` is True to flag the live path.
    """
    n = normalize_note(note)
    missing = []
    if not n["audio_ref"]:
        missing.append("no_audio_ref")
    if n["duration"] <= 0:
        missing.append("no_duration")
    ready = has_key and not missing
    return {
        "action": "transcribe",
        "ready": ready,
        "ai_required": True,
        "provider_integration": "transcription",
        "marker": STT_MARKER if not has_key else "",
        "missing": missing,
        # what the executor would send — reference + duration only, no bytes,
        # no model output. The transcript this returns is ALWAYS empty here.
        "payload": {
            "audio_ref": n["audio_ref"],
            "duration": n["duration"],
        },
        "transcript": "",  # honest: this module never produces transcript text
    }
