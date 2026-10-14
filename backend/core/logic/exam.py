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
        "source_only": True,  # the user still confirms on the official site
    }


# ===========================================================================
# ADVANCED (SPEC v2.1 §21)
# ===========================================================================
#
# Hard, non-negotiable rule for everything below: we NEVER invent, infer,
# guess, or pre-fill a RESULT (GPA/grade/pass-fail). The only place a real
# result can come from is the OFFICIAL board site, opened by the user. This
# module can:
#   - name the official board + its canonical PUBLIC portal (a fixed registry),
#   - tell the user WHEN results are expected and count down to it,
#   - detect that the official page CHANGED and nudge the user to go look,
#   - explain the GPA/grade scale (public, factual — not the user's result),
#   - manage MANY watches (a parent/teacher with several students),
# and that is the whole of it. No scraping behind auth, no fabricated result.

# ---------------------------------------------------------------------------
# official board registry (the ONLY sanctioned result sources)
# ---------------------------------------------------------------------------

# The single official public portal for board (SSC/HSC/JSC/etc.) results.
OFFICIAL_RESULTS_PORTAL = "https://eboardresults.com/en/ebr.app/home/"
# Education Board Bangladesh canonical domains we trust as "official".
OFFICIAL_RESULT_DOMAINS = (
    "educationboardresults.gov.bd",
    "eboardresults.com",
    "results.ebaube.gov.bd",
)

# General boards (board exams). `code` is the stable key; `portal` is the
# official public result portal for that board (all route via eboardresults).
BOARDS = [
    {"code": "dhaka", "bn": "ঢাকা", "en": "Dhaka"},
    {"code": "rajshahi", "bn": "রাজশাহী", "en": "Rajshahi"},
    {"code": "chittagong", "bn": "চট্টগ্রাম", "en": "Chattogram"},
    {"code": "khulna", "bn": "খুলনা", "en": "Khulna"},
    {"code": "barisal", "bn": "বরিশাল", "en": "Barishal"},
    {"code": "sylhet", "bn": "সিলেট", "en": "Sylhet"},
    {"code": "comilla", "bn": "কুমিল্লা", "en": "Cumilla"},
    {"code": "dinajpur", "bn": "দিনাজপুর", "en": "Dinajpur"},
    {"code": "mymensingh", "bn": "ময়মনসিংহ", "en": "Mymensingh"},
    {"code": "madrasah", "bn": "মাদ্রাসা", "en": "Madrasah"},
    {"code": "technical", "bn": "কারিগরি", "en": "Technical"},
]

# Public exams the board portal serves.
EXAM_TYPES = [
    {"code": "ssc", "bn": "এসএসসি", "en": "SSC"},
    {"code": "hsc", "bn": "এইচএসসি", "en": "HSC"},
    {"code": "jsc", "bn": "জেএসসি", "en": "JSC"},
    {"code": "psc", "bn": "পিইসি/পিএসসি", "en": "PSC"},
    {"code": "dakhil", "bn": "দাখিল", "en": "Dakhil"},
    {"code": "alim", "bn": "আলিম", "en": "Alim"},
]


def boards(lang="bn"):
    return [{"code": b["code"], "name": pick(lang, b["bn"], b["en"])}
            for b in BOARDS]


def exam_types(lang="bn"):
    return [{"code": e["code"], "name": pick(lang, e["bn"], e["en"])}
            for e in EXAM_TYPES]


def is_official_result_url(url):
    """True only for the sanctioned official board domains. We use this to flag
    any user-pasted URL that is NOT official, so we never pretend a random page
    is a result source."""
    u = str(url or "").strip().lower()
    if not (u.startswith("http://") or u.startswith("https://")):
        return False
    for dom in OFFICIAL_RESULT_DOMAINS:
        if ("://" + dom) in u or ("." + dom) in u or ("/" + dom) in u:
            return True
    return False


def official_check_target(board=None, exam=None):
    """The OFFICIAL destination the user should open to CHECK a result.

    We deep-link honestly to the public board portal — we do NOT fetch and
    render the result ourselves (that would mean scraping / possibly faking).
    Returns the canonical portal + a human note that the result is shown ONLY
    on the official site.
    """
    return {
        "url": OFFICIAL_RESULTS_PORTAL,
        "domains": list(OFFICIAL_RESULT_DOMAINS),
        "board": str(board or "").strip(),
        "exam": str(exam or "").strip(),
        "official_only": True,
    }


# ---------------------------------------------------------------------------
# countdown to expected result date
# ---------------------------------------------------------------------------

def countdown(expected_date, now=None):
    """Days/hours until the expected result date (never fabricates a result).

    Returns dict: {days, hours, past (bool), total_hours}. On/after the date,
    past=True and the UI switches to the traffic-spike + check-official flow.
    """
    exp = parse_dt(expected_date)
    now = now or datetime.now()
    if exp is None:
        return {"days": None, "hours": None, "past": False, "total_hours": None}
    if (exp.tzinfo is None) != (now.tzinfo is None):
        exp = exp.replace(tzinfo=None)
        now = now.replace(tzinfo=None)
    delta = exp - now
    secs = delta.total_seconds()
    if secs <= 0:
        return {"days": 0, "hours": 0, "past": True, "total_hours": 0}
    total_h = int(secs // 3600)
    return {
        "days": total_h // 24,
        "hours": total_h % 24,
        "past": False,
        "total_hours": total_h,
    }


# ---------------------------------------------------------------------------
# GPA / grade explainer (PUBLIC facts — NOT the user's result)
# ---------------------------------------------------------------------------

# The standard BD board letter-grade scale (GPA out of 5.0). This is public
# reference data, identical for everyone — it is NOT a student's result.
GRADE_SCALE = [
    {"grade": "A+", "gp": "5.00", "min": 80, "max": 100},
    {"grade": "A", "gp": "4.00", "min": 70, "max": 79},
    {"grade": "A-", "gp": "3.50", "min": 60, "max": 69},
    {"grade": "B", "gp": "3.00", "min": 50, "max": 59},
    {"grade": "C", "gp": "2.00", "min": 40, "max": 49},
    {"grade": "D", "gp": "1.00", "min": 33, "max": 39},
    {"grade": "F", "gp": "0.00", "min": 0, "max": 32},
]


def grade_scale(lang="bn"):
    """The public letter-grade ↔ grade-point ↔ marks scale."""
    return {
        "scale": [dict(row) for row in GRADE_SCALE],
        "note": pick(lang,
            "এটি বোর্ডের সাধারণ গ্রেডিং স্কেল — কারও নিজস্ব ফল নয়।",
            "This is the board's standard grading scale — not anyone's result."),
    }


def explain_gpa(gpa, lang="bn"):
    """Explain what a GPA VALUE THE USER TYPED means on the public scale.

    We only interpret a number the user supplies (e.g. from their own result
    slip). We never produce a GPA. Returns None for blank/invalid input.
    """
    try:
        v = float(str(gpa).strip())
    except (TypeError, ValueError):
        return None
    if v < 0 or v > 5:
        return None
    if v >= 5.0:
        band = pick(lang, "চমৎকার (A+)", "Outstanding (A+)")
    elif v >= 4.0:
        band = pick(lang, "খুব ভালো", "Very good")
    elif v >= 3.0:
        band = pick(lang, "ভালো", "Good")
    elif v >= 2.0:
        band = pick(lang, "সন্তোষজনক", "Satisfactory")
    elif v >= 1.0:
        band = pick(lang, "উত্তীর্ণ", "Passed")
    else:
        band = pick(lang, "অকৃতকার্য", "Did not pass")
    return {
        "gpa": f"{v:.2f}",
        "band": band,
        "scale_note": pick(lang,
            "জিপিএ ৫.০০-এর স্কেলে।", "On the 5.00 GPA scale."),
        "from_user": True,  # interpreting the user's own typed value
    }


# ---------------------------------------------------------------------------
# multi-student watch (a parent / teacher with several students)
# ---------------------------------------------------------------------------

def normalise_students(items):
    """Validate a list of students to watch (parent/teacher use-case).

    Each student needs at least a label or roll; result fields are NEVER
    pre-filled. Returns (ok, list_or_error_key). Caps the list to keep the
    result-day polling load sane.
    """
    items = items or []
    if not isinstance(items, (list, tuple)):
        return False, "students_invalid"
    out = []
    for it in items:
        it = it or {}
        label = str(it.get("label", "")).strip()
        roll = str(it.get("roll", "")).strip()
        if not label and not roll:
            continue
        out.append({
            "label": label or roll,
            "roll": roll,
            "reg": str(it.get("reg", "")).strip(),
            "board": str(it.get("board", "")).strip(),
            "exam": str(it.get("exam", "")).strip(),
        })
    if not out:
        return False, "students_empty"
    if len(out) > 25:
        out = out[:25]
    return True, out


def watch_summary(students, lang="bn"):
    """One honest line for a multi-student watch — counts only, no results."""
    n = len(students or [])
    return pick(lang,
        f"{n} জন শিক্ষার্থীর ফলের জন্য নজর রাখা হচ্ছে। ফল কেবল অফিশিয়াল "
        "সাইটেই দেখা যাবে।",
        f"Watching results for {n} student(s). Results are only ever shown "
        "on the official site.")
