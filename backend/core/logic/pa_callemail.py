"""
pa_callemail.py — the deterministic, key-free engine behind Assisto's
PA SECRETARY MODE · CALL & EMAIL HANDLING inbox (issue #106, SPEC v2.1 §14,
built to the §21 ADVANCED standard).

WHAT THIS IS
------------
A PA inbox / work-log for the two things a secretary chases all day: CALLS to
make or return, and EMAILS to handle. Each is a TASK with:

    channel   — "call" or "email"
    contact   — who (a person/org the PA deals with)
    subject   — one-line what-about
    priority  — "high" / "normal" / "low"
    status    — "todo" / "done"
    notes     — free text the PA keeps

The engine orders the inbox by (status open-first, then priority, then the
subject) and reports honest counts (open calls, open emails, done). It also
drafts a SUGGESTED reply from a DETERMINISTIC template bank by CATEGORY
(acknowledge / decline / schedule / follow-up). The draft is template-filled
from the task's own fields — it is clearly a MOCK ("AI-generated — review"),
never a fabricated "real" AI reply, and NOTHING here ever sends anything.

KEY-GATED, HONEST
-----------------
The deterministic templates work with NO key — the feature is a usable call/
email task manager + template drafter offline. A richer, fully AI-written reply
is a DOCUMENTED key-gated seam: `draft_reply(..., want_ai=True)` returns
`ai_required=True` with an EMPTY `body` and the honest marker, so the UI shows
the "connect an AI key for a full AI-drafted reply" state and never invents
prose. The request shape here is the contract the integrator wires to
`core.ai.generate`; nothing in this file calls a model.

NEVER AUTO-SENDS
----------------
Every function returns TEXT or state only. Copying a draft into a mail client
or dialling a number is a manual action the user takes; this module holds no
address book, opens no dialer, sends no mail.

PURE — NO DJANGO, NO DB, NO NETWORK, NO CLOCK, NO AI
----------------------------------------------------
Every function is a pure function of its arguments; the on-device Dart mirror
(call_email_screen.dart) reproduces identical previews offline and the tests
pin them. Persistence is the caller's job via the generic 'pa/callemail'
collection. Hand-verified in pa_callemail_tests_snippets.py.
"""

# ------------------------------------------------------------------ vocabulary

CHANNEL_CALL = "call"
CHANNEL_EMAIL = "email"
CHANNELS = (CHANNEL_CALL, CHANNEL_EMAIL)

PRIORITY_HIGH = "high"
PRIORITY_NORMAL = "normal"
PRIORITY_LOW = "low"
PRIORITIES = (PRIORITY_HIGH, PRIORITY_NORMAL, PRIORITY_LOW)

STATUS_TODO = "todo"
STATUS_DONE = "done"
STATUSES = (STATUS_TODO, STATUS_DONE)

# The four deterministic reply categories the template bank serves.
CAT_ACK = "acknowledge"
CAT_DECLINE = "decline"
CAT_SCHEDULE = "schedule"
CAT_FOLLOWUP = "followup"
CATEGORIES = (CAT_ACK, CAT_DECLINE, CAT_SCHEDULE, CAT_FOLLOWUP)

# Ordering weights. Lower sorts first.
_PRIORITY_RANK = {PRIORITY_HIGH: 0, PRIORITY_NORMAL: 1, PRIORITY_LOW: 2}
_STATUS_RANK = {STATUS_TODO: 0, STATUS_DONE: 1}

# The honest marker key every draft carries. The UI renders the localised
# "AI-generated — review" chip from this; the engine emits no prose of its own.
MARKER_KEY = "ai_review"


# ------------------------------------------------------------------ helpers

def _clean(text):
    """Trim + collapse whitespace; never crash on None."""
    return " ".join(str(text or "").split()).strip()


def _norm_channel(v):
    v = _clean(v).lower()
    return v if v in CHANNELS else CHANNEL_CALL


def _norm_priority(v):
    v = _clean(v).lower()
    return v if v in PRIORITIES else PRIORITY_NORMAL


def _norm_status(v):
    v = _clean(v).lower()
    return v if v in STATUSES else STATUS_TODO


def _norm_category(v):
    v = _clean(v).lower()
    return v if v in CATEGORIES else CAT_ACK


# ------------------------------------------------------------------ validate

def validate(channel=CHANNEL_CALL, contact="", subject=""):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    A task needs a known channel and at least one of contact / subject so a row
    is never a blank card."""
    problems = []
    if _clean(channel).lower() not in CHANNELS:
        problems.append("bad_channel")
    if not _clean(contact) and not _clean(subject):
        problems.append("empty_task")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


def normalise(item):
    """Coerce a raw stored/entered task dict into the canonical shape. Pure;
    unknown enum values fall back to safe defaults, so a row is always total."""
    item = item or {}
    return {
        "channel": _norm_channel(item.get("channel")),
        "contact": _clean(item.get("contact")),
        "subject": _clean(item.get("subject")),
        "priority": _norm_priority(item.get("priority")),
        "status": _norm_status(item.get("status")),
        "notes": str(item.get("notes") or "").strip(),
    }


# ------------------------------------------------------------------ inbox view

def _sort_key(it):
    n = normalise(it)
    return (
        _STATUS_RANK.get(n["status"], 0),
        _PRIORITY_RANK.get(n["priority"], 1),
        n["subject"].lower(),
        n["contact"].lower(),
    )


def order(items):
    """Return items ordered open-first, then high→low priority, then subject.
    Stable + deterministic; does not mutate the input list."""
    return sorted(list(items or []), key=_sort_key)


def counts(items):
    """Honest roll-up the inbox header shows. Open calls / open emails / done /
    total — computed, never stored."""
    open_calls = open_emails = done = 0
    for it in (items or []):
        n = normalise(it)
        if n["status"] == STATUS_DONE:
            done += 1
        elif n["channel"] == CHANNEL_CALL:
            open_calls += 1
        else:
            open_emails += 1
    return {
        "open_calls": open_calls,
        "open_emails": open_emails,
        "open_total": open_calls + open_emails,
        "done": done,
        "total": len(items or []),
    }


# ------------------------------------------------------------------ templates
# Deterministic reply skeletons, per category. `{contact}` / `{subject}` are
# filled from the task; `{sender}` from the owner's display name if provided.
# Neutral English seeds (ZERO Bangla) so the mirrored Dart generator matches and
# this file stays Bangla-free; the Bangla renderings live in the .arb and the
# real-AI path replaces these entirely.
_TEMPLATES = {
    CAT_ACK: (
        "Dear {contact}, thank you for your message regarding {subject}. "
        "I confirm I have received it and will get back to you shortly. "
        "Best regards, {sender}"
    ),
    CAT_DECLINE: (
        "Dear {contact}, thank you for reaching out about {subject}. "
        "Regretfully, we are unable to proceed at this time. "
        "I appreciate your understanding. Best regards, {sender}"
    ),
    CAT_SCHEDULE: (
        "Dear {contact}, regarding {subject}, could we arrange a time to speak? "
        "Please share a slot that suits you and I will confirm. "
        "Best regards, {sender}"
    ),
    CAT_FOLLOWUP: (
        "Dear {contact}, following up on {subject} — I wanted to check whether "
        "there is any update from your side. Please let me know. "
        "Best regards, {sender}"
    ),
}


def draft_reply(item, category=CAT_ACK, sender="", want_ai=False):
    """Suggest a DETERMINISTIC template reply for a call/email task, by category.

    Fills the category skeleton from the task's own contact/subject (+ optional
    owner `sender` sign-off). Honest MOCK: `mock=True`, `marker=MARKER_KEY`, and
    `ai_required=False` for the template path.

    The key-gated FULL AI reply is `want_ai=True`: we return `ai_required=True`
    with an EMPTY `body` (never a fabricated AI reply) + the same request shape
    the integrator routes to `core.ai.generate`. NEVER auto-sends — text only.
    """
    n = normalise(item)
    category = _norm_category(category)
    sender = _clean(sender) or "—"
    contact = n["contact"] or "—"
    subject = n["subject"] or "—"

    if want_ai:
        return {
            "category": category,
            "channel": n["channel"],
            "contact": n["contact"],
            "subject": n["subject"],
            # honest: a fully AI-written reply needs the key-gated route; we
            # never invent prose here. The UI shows the "connect a key" state.
            "body": "",
            "ai_required": True,
            "mock": True,
            "marker": MARKER_KEY,
        }

    body = _TEMPLATES[category].format(
        contact=contact, subject=subject, sender=sender)
    return {
        "category": category,
        "channel": n["channel"],
        "contact": n["contact"],
        "subject": n["subject"],
        "body": body,
        "ai_required": False,
        "mock": True,
        "marker": MARKER_KEY,
    }
