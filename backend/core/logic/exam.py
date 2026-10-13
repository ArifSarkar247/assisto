"""
exam.py — Assisto exam-result-day logic (module-5 "Life").

Pure Python, deterministic, no AI key, unit-testable.

What lives here:
  - a WATCHER for a user-provided result URL and/or an expected result DATE.
    We NEVER scrape behind a login or bypass auth; the watcher only polls a
    PUBLIC url the user pasted (the HTTP fetch itself is a platform/integrator
    hook — this module computes WHEN to poll and interprets the result).
  - polling schedule: results sites get hammered on result day, so we back off
    and add a clear "servers may be slow / try official SMS or alternate
    mirrors" traffic-spike note instead of pretending we have the result.
  - a shareable result CARD draft (bn/en) built ONLY from values the user
    enters (roll, board, GPA, etc.) — never fabricated.
  - change detection: given a previous and current fetched snapshot (hash or
    text supplied by the caller), decide if the page changed.
"""
from datetime import datetime, timedelta


def pick(lang, bn, en):
    return en if lang == "en" else bn


def parse_dt(v):
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# watcher config + validation
# ---------------------------------------------------------------------------

def normalise_watcher(payload):
    """Validate a result-watcher the user sets up.

    Needs at least a URL or an expected date. Returns (ok, data_or_error_key).
    We require an http(s) url (public page only) — no auth flows handled here.
    """
    payload = payload or {}
    url = str(payload.get("url", "")).strip()
    exp = parse_dt(payload.get("expected_date"))
    label = str(payload.get("label", "")).strip()
    if url and not (url.startswith("http://") or url.startswith("https://")):
        return False, "url_invalid"
    if not url and exp is None:
        return False, "url_or_date_required"
    return True, {
        "label": label or "Result",
        "url": url,
        "expected_date": exp.isoformat() if exp else None,
        "roll": str(payload.get("roll", "")).strip(),
        "board": str(payload.get("board", "")).strip(),
        "exam": str(payload.get("exam", "")).strip(),
        "year": str(payload.get("year", "")).strip(),
    }


# ---------------------------------------------------------------------------
# polling schedule (traffic-spike aware)
# ---------------------------------------------------------------------------

# Before the expected date: check sparsely. On/after the expected date: poll
# more often but BACK OFF (servers are overloaded on result day).
POLL_BEFORE_MIN = 6 * 60      # every 6h before result day
POLL_DAY_BASE_MIN = 10        # start at 10 min on result day
POLL_DAY_MAX_MIN = 60         # back off up to 60 min
POLL_BACKOFF_FACTOR = 1.5


def next_poll_minutes(expected_date, now=None, consecutive_failures=0):
    """Minutes until the next poll.

    Before the expected date -> POLL_BEFORE_MIN.
    On/after -> base interval, exponentially backed off by failure count
    (capped), because result servers are overloaded on the day.
    """
    exp = parse_dt(expected_date)
    now = now or datetime.now()
    if exp is not None:
        if (exp.tzinfo is None) != (now.tzinfo is None):
            exp = exp.replace(tzinfo=None)
            now = now.replace(tzinfo=None)
        if now < exp - timedelta(hours=12):
            return POLL_BEFORE_MIN
    # result day (or no date set): back off on repeated failures
    try:
        f = max(0, int(consecutive_failures))
    except (TypeError, ValueError):
        f = 0
    interval = POLL_DAY_BASE_MIN * (POLL_BACKOFF_FACTOR ** f)
    return int(min(POLL_DAY_MAX_MIN, round(interval)))


def is_result_day(expected_date, now=None):
    exp = parse_dt(expected_date)
    if exp is None:
        return False
    now = now or datetime.now()
    if (exp.tzinfo is None) != (now.tzinfo is None):
        exp = exp.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    return now.date() >= exp.date()


def traffic_spike_note(lang="bn"):
    """Honest heads-up shown on result day instead of faking a fast result."""
    return pick(lang,
        "ফল প্রকাশের দিন ওয়েবসাইট ধীর বা ব্যস্ত থাকতে পারে। "
        "অফিশিয়াল SMS বা বিকল্প মিরর সাইটও ব্যবহার করে দেখুন।",
        "On result day the website can be slow or overloaded. "
        "Try the official SMS service or an alternate mirror site too.")


# ---------------------------------------------------------------------------
# change detection (fetch itself is a platform hook; we only compare)
# ---------------------------------------------------------------------------

def snapshot_changed(previous, current):
    """True if the watched page's snapshot changed (both supplied by caller as
    a hash or text). Empty/None current -> no change (nothing fetched)."""
    if current in (None, ""):
        return False
    return str(previous or "") != str(current)


def watcher_phase(expected_date, now=None, result_ready=False):
    """UI state of a watcher.

    Returns:
      ('ready', 0)              result detected (caller set result_ready)
      ('waiting', days)         before result day, `days` until expected date
      ('watching', 0)           on/after result day, still polling
    """
    if result_ready:
        return ("ready", 0)
    exp = parse_dt(expected_date)
    now = now or datetime.now()
    if exp is None:
        return ("watching", 0)
    if (exp.tzinfo is None) != (now.tzinfo is None):
        exp = exp.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    if now.date() < exp.date():
        return ("waiting", (exp.date() - now.date()).days)
    return ("watching", 0)


# ---------------------------------------------------------------------------
# share card (built only from user-entered values)
# ---------------------------------------------------------------------------

def result_card(fields, lang="bn"):
    """A shareable result card DRAFT from USER-ENTERED values only.

    fields may include: name, exam, board, year, roll, gpa, grade, note.
    We never invent a result; blank fields are simply omitted.
    """
    fields = fields or {}

    def g(k):
        return str(fields.get(k, "")).strip()

    name, exam, board = g("name"), g("exam"), g("board")
    year, roll, gpa = g("year"), g("roll"), g("gpa")
    grade, note = g("grade"), g("note")

    lines = []
    header = exam or pick(lang, "পরীক্ষার ফল", "Exam result")
    if year:
        header += f" {year}"
    lines.append(header)
    if name:
        lines.append(pick(lang, f"নাম: {name}", f"Name: {name}"))
    if roll:
        lines.append(pick(lang, f"রোল: {roll}", f"Roll: {roll}"))
    if board:
        lines.append(pick(lang, f"বোর্ড: {board}", f"Board: {board}"))
    if gpa:
        lines.append(pick(lang, f"জিপিএ: {gpa}", f"GPA: {gpa}"))
    if grade:
        lines.append(pick(lang, f"গ্রেড: {grade}", f"Grade: {grade}"))
    if note:
        lines.append(note)
    return {
        "kind": "exam_result_card",
        "lang": lang,
        "title": header,
        "text": "\n".join(lines),
        "editable": True,
    }


def result_ready_payload(label, lang="bn"):
    return {
        "kind": "exam_result_ready",
        "title": pick(lang, "ফল প্রকাশিত হয়েছে", "Result is out"),
        "body": pick(lang,
            f"{label} এর ফল প্রকাশিত হয়েছে বলে মনে হচ্ছে — দেখে নিন।",
            f"The {label} result appears to be published — check it now."),
    }
