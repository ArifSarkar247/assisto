"""
job_hunter.py — Job Hunter ADVANCED pipeline/tracker logic (feature 37, SPEC
v2.1 §21). Pure, deterministic Python: no DB, no network, no AI key. State is
passed in / returned as plain dicts so it is unit-testable and so the DB models
+ endpoints stay the integrator's job (the existing JobApplication model in
core/models.py already carries status/applied_at/followup_at — this module
only computes transitions, reminders, filters, prep, and salary notes).

Design notes for Bangladeshi job-seekers, benchmarked against the best
job-search apps (capability parity only — bdjobs-style *sources* are provided
via an official API / owner-supplied feed, NEVER by scraping or copying anyone
else's listings). The discovery feed therefore ships a small CURATED SAMPLE
plus an honest "connect a source" state until a feed key is configured.

The AI-dependent pieces (CV tailoring, cover-letter draft) live in core/jobs.py
and are MOCK + key-gated there. This module is the deterministic backbone:
  - the applied-tracker pipeline (an explicit FSM with legal transitions),
  - deterministic application reminders (dates only, no clock surprises),
  - an interview-prep checklist,
  - filter/search predicates (category, location, salary, type, experience),
  - salary insight that is SOURCE-NOTED, never invented.
"""
from datetime import date, timedelta

from .. import i18n  # pick(lang, bn, en) is also re-exported below for callers

pick = i18n.pick


# --------------------------------------------------------------------------- #
# Applied-tracker pipeline (FSM).                                             #
# matched → saved → applied → interview → offer | rejected                   #
# "rejected" / "offer" are terminal; "withdrawn" is an escape hatch from any  #
# non-terminal stage. Only legal transitions are accepted so the tracker can  #
# never show an impossible history.                                           #
# --------------------------------------------------------------------------- #
STAGE_MATCHED = "matched"
STAGE_SAVED = "saved"
STAGE_APPLIED = "applied"
STAGE_INTERVIEW = "interview"
STAGE_OFFER = "offer"
STAGE_REJECTED = "rejected"
STAGE_WITHDRAWN = "withdrawn"

# Ordered for display (progress bar). Terminal stages excluded from the spine.
PIPELINE = [STAGE_MATCHED, STAGE_SAVED, STAGE_APPLIED, STAGE_INTERVIEW, STAGE_OFFER]
TERMINAL = {STAGE_OFFER, STAGE_REJECTED, STAGE_WITHDRAWN}

_TRANSITIONS = {
    STAGE_MATCHED: {STAGE_SAVED, STAGE_APPLIED, STAGE_REJECTED, STAGE_WITHDRAWN},
    STAGE_SAVED: {STAGE_APPLIED, STAGE_MATCHED, STAGE_REJECTED, STAGE_WITHDRAWN},
    STAGE_APPLIED: {STAGE_INTERVIEW, STAGE_REJECTED, STAGE_WITHDRAWN},
    STAGE_INTERVIEW: {STAGE_OFFER, STAGE_REJECTED, STAGE_WITHDRAWN},
    STAGE_OFFER: set(),
    STAGE_REJECTED: set(),
    STAGE_WITHDRAWN: set(),
}


def can_transition(frm, to):
    """True iff moving an application from stage ``frm`` to ``to`` is legal."""
    if frm == to:
        return False
    return to in _TRANSITIONS.get(frm, set())


def advance(app, to, *, when=None, note=""):
    """Return a NEW application dict moved to stage ``to``.

    ``app`` is a plain dict (id/title/company/status/history/...). Raises
    ValueError on an illegal transition so the caller never persists a bad
    state. ``when`` defaults to today; a dated, append-only ``history`` entry
    is recorded (nothing is ever silently rewritten).
    """
    frm = app.get("status", STAGE_MATCHED)
    if not can_transition(frm, to):
        raise ValueError(f"illegal transition {frm!r} -> {to!r}")
    when = when or date.today()
    out = dict(app)
    out["status"] = to
    # keep the canonical timestamps the DB model exposes in sync
    if to == STAGE_APPLIED:
        out["applied_at"] = when.isoformat()
    history = list(app.get("history") or [])
    entry = {"stage": to, "date": when.isoformat()}
    if note:
        entry["note"] = note.strip()[:300]
    history.append(entry)
    out["history"] = history
    return out


def pipeline_progress(status):
    """(index, total) for the progress spine. Terminal rejected/withdrawn → -1."""
    if status in (STAGE_REJECTED, STAGE_WITHDRAWN):
        return (-1, len(PIPELINE))
    try:
        return (PIPELINE.index(status), len(PIPELINE))
    except ValueError:
        return (0, len(PIPELINE))


def stage_label(lang, status):
    labels = {
        STAGE_MATCHED: ("মিলেছে", "Matched"),
        STAGE_SAVED: ("সংরক্ষিত", "Saved"),
        STAGE_APPLIED: ("আবেদন করেছেন", "Applied"),
        STAGE_INTERVIEW: ("ইন্টারভিউ", "Interview"),
        STAGE_OFFER: ("অফার", "Offer"),
        STAGE_REJECTED: ("বাতিল", "Rejected"),
        STAGE_WITHDRAWN: ("প্রত্যাহার", "Withdrawn"),
    }
    bn, en = labels.get(status, (status, status))
    return pick(lang, bn, en)


# --------------------------------------------------------------------------- #
# Application reminders — deterministic, dates only.                          #
# --------------------------------------------------------------------------- #
# Days after entering a stage before a nudge is due. The user never gets a
# surprise: everything is derived from a stage date they can see.
_REMINDER_AFTER = {
    STAGE_SAVED: 3,       # saved but not applied → apply before it closes
    STAGE_APPLIED: 7,     # applied, no word → polite follow-up
    STAGE_INTERVIEW: 2,   # interview booked → prep + thank-you note
}


def next_reminder(app, *, today=None):
    """Return {'due': ISO date, 'kind': stage, 'overdue': bool} or None.

    Based solely on the latest stage date in ``history`` (or applied_at). No
    reminder for terminal stages. Deterministic: same inputs → same output.
    """
    status = app.get("status", STAGE_MATCHED)
    if status in TERMINAL or status not in _REMINDER_AFTER:
        return None
    today = today or date.today()
    anchor = _last_stage_date(app, status) or _parse(app.get("applied_at")) \
        or _parse(app.get("created_at")) or today
    due = anchor + timedelta(days=_REMINDER_AFTER[status])
    return {"due": due.isoformat(), "kind": status, "overdue": due <= today}


def _last_stage_date(app, status):
    for entry in reversed(app.get("history") or []):
        if entry.get("stage") == status:
            return _parse(entry.get("date"))
    return None


def _parse(value):
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


# --------------------------------------------------------------------------- #
# Interview-prep checklist (deterministic template, bilingual).              #
# --------------------------------------------------------------------------- #
_PREP = [
    ("কোম্পানি ও পণ্য সম্পর্কে পড়ুন", "Research the company & its product"),
    ("চাকরির বিবরণের সাথে নিজের দক্ষতা মিলিয়ে নিন", "Map your skills to the job description"),
    ("সাধারণ প্রশ্নের উত্তর অনুশীলন করুন (STAR)", "Practise common questions (STAR method)"),
    ("তাদের জন্য ২-৩টি প্রশ্ন প্রস্তুত রাখুন", "Prepare 2–3 questions to ask them"),
    ("পোশাক ও পথ/লিঙ্ক আগে ঠিক করুন", "Sort out attire and the route/meeting link"),
    ("সিভি ও কাগজপত্রের কপি নিন", "Bring copies of your CV and documents"),
    ("ইন্টারভিউয়ের পর ধন্যবাদ বার্তা পাঠান", "Send a thank-you note afterwards"),
]


def interview_checklist(lang):
    """Return the prep checklist as [{'id', 'text'}]. Caller tracks ticks locally."""
    return [{"id": i, "text": pick(lang, bn, en)}
            for i, (bn, en) in enumerate(_PREP)]


# --------------------------------------------------------------------------- #
# Filter / search predicates.                                                 #
# --------------------------------------------------------------------------- #
# Enumerations (stable keys; labels bilingual in the UI).
CATEGORIES = ["it", "accounts", "sales", "ngo", "garments", "education",
              "engineering", "health", "gov", "other"]
JOB_TYPES = ["full_time", "part_time", "contract", "remote", "internship"]
EXPERIENCE = ["entry", "mid", "senior"]


def matches_filters(job, *, query="", category="", location="",
                    min_salary=None, max_salary=None, job_type="",
                    experience=""):
    """True iff ``job`` (a dict) passes every active filter. Empty/None = off.

    Salary filtering only applies to jobs that *state* a salary — a job with no
    stated salary is never hidden by a salary filter (we don't invent numbers).
    """
    if query:
        hay = " ".join(str(job.get(k, "")) for k in
                       ("title", "company", "jd", "location", "category")).lower()
        if query.lower().strip() not in hay:
            return False
    if category and job.get("category") != category:
        return False
    if location and location.lower().strip() not in str(job.get("location", "")).lower():
        return False
    if job_type and job.get("job_type") != job_type:
        return False
    if experience and job.get("experience") != experience:
        return False
    sal = job.get("salary")
    if sal is not None:
        if min_salary is not None and sal < min_salary:
            return False
        if max_salary is not None and sal > max_salary:
            return False
    return True


def filter_jobs(jobs, **flt):
    return [j for j in jobs if matches_filters(j, **flt)]


# --------------------------------------------------------------------------- #
# Salary insight — SOURCE-NOTED, never invented.                             #
# --------------------------------------------------------------------------- #
def salary_insight(jobs, *, category="", lang="bn", source=""):
    """Summarise the salary range across the *given* jobs that state a salary.

    Returns a dict with min/median/max AND a ``source`` string. If no job in
    the set states a salary we return ``available=False`` rather than fabricate
    a market figure — honesty is a hard requirement of the spec.
    """
    vals = sorted(j["salary"] for j in jobs
                  if (not category or j.get("category") == category)
                  and isinstance(j.get("salary"), (int, float)))
    if not vals:
        return {"available": False,
                "note": pick(lang,
                             "এই তালিকায় বেতন উল্লেখ নেই — অনুমান করা হয়নি।",
                             "No salary stated in this set — not estimated.")}
    median = vals[len(vals) // 2]
    note = pick(lang,
                f"এই {len(vals)}টি তালিকার বেতন থেকে (উৎস: {source or 'সংযুক্ত ফিড'})।",
                f"From {len(vals)} listings in this set (source: {source or 'connected feed'}).")
    return {"available": True, "count": len(vals), "min": vals[0],
            "median": median, "max": vals[-1], "source": source, "note": note}


# --------------------------------------------------------------------------- #
# Discovery sources — curated sample + honest "connect a source" gate.        #
# NEVER scrape. A real feed arrives only via an official API / owner feed.    #
# --------------------------------------------------------------------------- #
def sources_state(feed_connected=False, lang="bn"):
    """Describe the discovery feed's state for the UI.

    ``feed_connected`` is the key-gate (an official job-source API key or an
    owner-provided feed is configured). Until then the UI shows a small
    CURATED SAMPLE and an honest banner — we never scrape bdjobs/LinkedIn.
    """
    if feed_connected:
        return {"connected": True, "scraping": False,
                "note": pick(lang, "লাইভ ফিড সংযুক্ত।", "Live feed connected.")}
    return {"connected": False, "scraping": False,
            "note": pick(lang,
                         "নমুনা তালিকা দেখানো হচ্ছে। সরকারি API/মালিকের ফিড যুক্ত করলে লাইভ চাকরি আসবে। আমরা কখনও স্ক্র্যাপ করি না।",
                         "Showing sample listings. Connect an official API / owner feed for live jobs. We never scrape.")}
