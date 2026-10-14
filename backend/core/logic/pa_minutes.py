"""
pa_minutes.py — the deterministic, key-free engine behind PA SECRETARY MODE's
MEETING MINUTES tool (issue #110, SPEC v2.1 §14, ADVANCED §21).

This captures the minutes of a meeting the PA sat in on (or typed up afterward):
a meeting TITLE + DATE, the ATTENDEES, the AGENDA items discussed, the DECISIONS
taken, and ACTION ITEMS each with an owner and a due date. From those entered
fields a deterministic MINUTES SUMMARY is formatted — a clean, readable recap of
exactly what the user typed. It complements the meeting brief (#104 pa_brief.py,
which prepares the owner BEFORE a meeting); this records what happened AFTER.

This module is PURE: no Django, no DB, no network, no clock, **no transcription,
no AI**. It is a DETERMINISTIC formatter — normalise entries, validate, order
action items, and render a summary from the entered fields ONLY — so the
on-device Dart mirror (`pa_minutes_engine.dart`) behaves identically offline and
the tests can pin it.

HONEST TRANSCRIPTION, KEY-GATED
-------------------------------
Auto-GENERATING minutes from a recording (speech-to-text) is a DOCUMENTED
key-gated seam. Without a transcription key (Integrations → `transcription`) the
tool works fully as a MANUAL minutes tool and NEVER fabricates a transcript or
minutes — `transcription_state()` returns an honest "connect a transcription key
to auto-generate minutes from audio" state. When the owner connects the
`transcription` key, the app/executor MAY route a recording to the provider and
PREFILL the minutes fields (which the user then reviews/edits); this file does
no transcription and invents nothing. The summary is only ever built from
fields that are already present.

PERSISTENCE (described, not performed here): a minutes entry round-trips through
the generic per-user JSON collection `pa/minutes` as {id, ...build_minutes(...)}
(action items embedded in the entry); a flat per-owner action-item view is kept
in `pa/actionitems` as {id, title, owner, due, status, meeting_id}. See
up_pafileminutes_integration.md.

Everything is plain stdlib and hand-verified in pa_minutes_tests_snippets.py.
"""

# ---------------------------------------------------------------- vocabulary

# Action-item lifecycle. The UI localises these keys; the engine validates on
# them. "open" is the safe fallback for anything unknown.
ACTION_OPEN = "open"
ACTION_DOING = "doing"
ACTION_DONE = "done"
ACTION_STATUSES = (ACTION_OPEN, ACTION_DOING, ACTION_DONE)

# The honest transcription state keys the UI renders. Engine emits no prose.
STT_LOCKED = "stt_locked"   # no key → manual only, "connect a transcription key"
STT_READY = "stt_ready"     # key present → auto-minutes offered (routed away)

# Which Integrations key auto-minutes needs. Documented seam.
STT_KEY = "transcription"

# A far-future sentinel so action items with no due date sort AFTER dated ones.
_NO_DUE = "9999-12-31"


# ----------------------------------------------------------------- helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _clean_list(items):
    """Coerce a list OR newline/comma string into a clean list of non-empty
    trimmed strings, order preserved. Total; never raises."""
    raw = []
    if isinstance(items, str):
        raw = items.replace("\r", "\n").split("\n")
    elif isinstance(items, (list, tuple)):
        raw = list(items)
    return [c for c in (_clean(x) for x in raw) if c]


def normalise_status(status):
    """Coerce any input to a known action status; unknown ⇒ 'open'. Total."""
    s = _clean(status).lower()
    return s if s in ACTION_STATUSES else ACTION_OPEN


# ----------------------------------------------------------------- action items

def normalise_action(action):
    """Coerce one action-item dict into the stored shape with safe defaults.

        {"title", "owner", "due", "status"}

    Unknown status ⇒ 'open'. Never raises; never invents a due date."""
    a = dict(action or {})
    return {
        "title": _clean(a.get("title")),
        "owner": _clean(a.get("owner")),
        "due": _clean(a.get("due")),
        "status": normalise_status(a.get("status")),
    }


def validate_action(action):
    """Problem keys for one action item (empty ⇒ valid). An action needs a
    TITLE; owner/due are optional. The UI localises these keys."""
    a = dict(action or {})
    problems = []
    if not _clean(a.get("title")):
        problems.append("action_title_required")
    if a.get("status") is not None and \
            _clean(a.get("status")).lower() not in ACTION_STATUSES and \
            _clean(a.get("status")):
        problems.append("bad_status")
    return problems


def order_actions(actions):
    """Return a NEW list of normalised action items in display order: not-done
    before done, then by soonest due date, then title. Deterministic, stable,
    non-mutating. No clock — ordering is by the entered due string only."""
    normed = [normalise_action(a) for a in (actions or [])]

    def key(a):
        done = 1 if a["status"] == ACTION_DONE else 0
        due = a["due"] or _NO_DUE
        return (done, due, a["title"].lower())

    return sorted(normed, key=key)


def action_rows(entry, meeting_id=""):
    """Flatten one minutes entry's action items into the flat per-owner view
    rows stored in `pa/actionitems`. Each carries a back-reference `meeting_id`
    (the owning minutes row id) so the app can show a cross-meeting action list.
    Deterministic; the title/owner/due/status come straight from the entry."""
    mid = _clean(meeting_id)
    out = []
    for a in order_actions((entry or {}).get("actions")):
        row = dict(a)
        row["meeting_id"] = mid
        out.append(row)
    return out


# ----------------------------------------------------------------- validate

def validate(title, date="", attendees=None, agenda=None, decisions=None,
             actions=None):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    A minutes entry needs at least a meeting TITLE (so it is retrievable). Every
    other section is optional — a title alone saves a stub the user fills later.
    Each action item is validated too; `bad_action` surfaces if any action lacks
    a title."""
    problems = []
    if not _clean(title):
        problems.append("title_required")
    for a in (actions or []):
        if validate_action(a):
            problems.append("bad_action")
            break
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ----------------------------------------------------------------- build entry

def build_minutes(title, date="", attendees=None, agenda=None, decisions=None,
                  actions=None):
    """Normalise a meeting into the row shape stored in the `pa/minutes`
    collection.

        {
          "title", "date",
          "attendees": [..], "agenda": [..], "decisions": [..],
          "actions":   [{"title","owner","due","status"}, ...],  # ordered
          "stt_state": "stt_locked",   # honest key-gated transcription state
          "ai_required": False,        # manual minutes need no key
          "mock": True,                # honest: formatter output, no STT run
          "problems": [...]            # validate() keys
        }

    Deterministic + total: never raises on bad input. NEVER fabricates a
    transcript — every field comes from what the caller passed in."""
    return {
        "title": _clean(title),
        "date": _clean(date),
        "attendees": _clean_list(attendees),
        "agenda": _clean_list(agenda),
        "decisions": _clean_list(decisions),
        "actions": order_actions(actions),
        "stt_state": STT_LOCKED,   # honest: no key → manual only
        "ai_required": False,
        "mock": True,
        "problems": validate(title, date, attendees, agenda, decisions, actions),
    }


def transcription_state(stt_key_present):
    """Honest transcription availability for the UI. Returns a dict, no prose:

        {"state", "key": "transcription", "can_autominutes": bool}

    `stt_locked` → the UI shows "connect a transcription key to auto-generate
    minutes from audio" and the tool stays a MANUAL minutes tool. `stt_ready` →
    the UI may OFFER auto-minutes, routed through the key-gated provider
    elsewhere (not here). This engine never transcribes and never fabricates a
    transcript or minutes either way."""
    present = bool(stt_key_present)
    return {
        "state": STT_READY if present else STT_LOCKED,
        "key": STT_KEY,
        "can_autominutes": present,
    }


# ----------------------------------------------------------------- summary

def summarise(entry):
    """DETERMINISTIC minutes summary built ONLY from the entered fields.

    Returns a STRUCTURED recap (never prose the engine invents), so the UI can
    render it bilingually and the test can pin it:

        {
          "title", "date",
          "attendee_count", "attendees",
          "agenda":    [..],
          "decisions": [..],
          "actions":   [{"title","owner","due","status"}, ...],  # ordered
          "open_actions":  int,   # actions not yet done
          "done_actions":  int,
          "sections": ["agenda","decisions","actions", ...],  # which are present
          "mock": True,           # honest: formatted from entered fields, no AI
          "ai_required": False
        }

    No clock, no AI, no transcription. If a section is empty it is simply absent
    from `sections` — the summary never pads itself with invented content."""
    e = build_minutes(
        (entry or {}).get("title"),
        date=(entry or {}).get("date"),
        attendees=(entry or {}).get("attendees"),
        agenda=(entry or {}).get("agenda"),
        decisions=(entry or {}).get("decisions"),
        actions=(entry or {}).get("actions"),
    )
    actions = e["actions"]
    open_n = sum(1 for a in actions if a["status"] != ACTION_DONE)
    done_n = sum(1 for a in actions if a["status"] == ACTION_DONE)
    sections = []
    if e["attendees"]:
        sections.append("attendees")
    if e["agenda"]:
        sections.append("agenda")
    if e["decisions"]:
        sections.append("decisions")
    if actions:
        sections.append("actions")
    return {
        "title": e["title"],
        "date": e["date"],
        "attendee_count": len(e["attendees"]),
        "attendees": e["attendees"],
        "agenda": e["agenda"],
        "decisions": e["decisions"],
        "actions": actions,
        "open_actions": open_n,
        "done_actions": done_n,
        "sections": sections,
        "mock": True,
        "ai_required": False,
    }
