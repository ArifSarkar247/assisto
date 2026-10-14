"""
security_checkup.py — pure deterministic engine for Assisto's DIGITAL SECURITY
CHECK-UP module (SPEC v2.1 §20, #198). No Django, no DB, no network, no AI, no
clock of its own. Every function is a pure function of the user's checklist
answers → a security SCORE, a graded verdict, and an honest list of weak areas.

WHAT THE CHECK-UP IS
--------------------
A guided self-audit of the security practices that actually protect an ordinary
Bangladeshi user's phone, money and accounts. Each ITEM is a yes/no practice the
user marks DONE or NOT-DONE (a few are "not applicable" where honest). We never
probe the device or claim a protection is on — the user tells us, and the score
is only ever as honest as their own answers. The copy around every item says so.

HARD HONESTY RULES (structural, not just documented)
----------------------------------------------------
  * SELF-REPORTED.  `self_reported()` is a constant True. This engine reads NO
    device state and verifies NOTHING. A "done" item means the user said so.
  * NEVER CLAIMS A PROTECTION IS ON.  The score and weak-areas are computed
    purely from the answers passed in; nothing is assumed "on" by default. An
    unanswered item counts as NOT done (conservative — we never flatter).
  * DETERMINISTIC.  Same answers → same score, verdict and tip order, always.
    Weights are fixed integers; the max is their sum; the percentage is integer
    rounding of (earned / max * 100). No floats leak into the stored result.
  * ACTIONABLE, NOT ALARMIST.  Every item carries a short, concrete tip the UI
    localises. We grade honestly ("needs work") without scare language.

ITEMS
-----
Each item is (id, weight, category). Weight reflects how much that practice
reduces real risk for this audience — a screen lock and 2FA on the primary
account matter more than, say, reviewing app permissions. Weights are small
fixed integers so the arithmetic is exact and the max is stable.

DATA SHAPES (unknown keys ignored; missing keys default to not-done)
--------------------------------------------------------------------
answers = {"screen_lock": True, "wallet_pin": True, "two_factor": False, ...}
          # only the item ids in ITEMS are read; anything else is ignored.
          # a value is "done" iff it is exactly boolean True.

result (score(answers)) = {
    "earned": 17,            # sum of weights of done items
    "max": 26,               # sum of all item weights (constant)
    "percent": 65,           # int round(earned / max * 100); 0 when max == 0
    "grade": "fair",         # strong | good | fair | at_risk  (see GRADES)
    "done": [ "screen_lock", ... ],        # ids marked done, in ITEMS order
    "weak": [ "two_factor", ... ],         # NOT-done ids, worst-weight first
    "done_count": 4,
    "total_count": 9,
    "self_reported": True,
}
"""

# --------------------------------------------------------------------------- #
# Item catalogue. (id, weight, category). ORDER IS LOAD-BEARING: `done`/`weak`
# and the UI list follow it, so the output is stable. Weights are fixed.
# --------------------------------------------------------------------------- #
ITEMS = [
    ("screen_lock",      5, "device"),   # phone PIN / fingerprint / face lock
    ("app_lock",         3, "device"),   # lock on Assisto / wallet apps
    ("wallet_pin",       5, "money"),     # strong, private bKash/Nagad PIN
    ("two_factor",       5, "accounts"),  # 2FA on email / primary account
    ("strong_passwords", 3, "accounts"),  # unique, strong passwords
    ("backup_enabled",   2, "data"),      # contacts / photos / docs backed up
    ("scam_awareness",   2, "awareness"), # never shares OTP / PIN with callers
    ("permissions_review", 1, "privacy"), # reviewed app permissions
]

ITEM_IDS = [i[0] for i in ITEMS]
WEIGHTS = {i[0]: i[1] for i in ITEMS}
CATEGORY = {i[0]: i[2] for i in ITEMS}
MAX_SCORE = sum(i[1] for i in ITEMS)

# Grade thresholds on the integer percentage. Lower-bound inclusive, checked
# high→low. Deliberately conservative: you only reach "strong" near the top.
GRADES = [
    ("strong",  85),
    ("good",    65),
    ("fair",    40),
    ("at_risk",  0),
]


def self_reported():
    """This check-up is ENTIRELY self-reported — it reads no device state and
    verifies nothing. Always True; the UI must say so."""
    return True


def is_done(answers, item_id):
    """A practice counts as done ONLY when the answer is exactly boolean True.
    Missing / None / falsey → not done (conservative; we never flatter)."""
    return (answers or {}).get(item_id) is True


def grade_for(percent):
    """Map an integer percentage to a verdict key. Deterministic, total."""
    p = max(0, min(100, int(percent)))
    for key, lo in GRADES:
        if p >= lo:
            return key
    return "at_risk"


def score(answers):
    """Pure deterministic score of the self-reported checklist.

    Returns the result dict documented in the module header. `answers` is a
    plain mapping of item-id → bool; unknown keys are ignored and any item not
    present (or not exactly True) is treated as NOT done.
    """
    answers = answers or {}
    done = [iid for iid in ITEM_IDS if is_done(answers, iid)]
    earned = sum(WEIGHTS[iid] for iid in done)
    percent = 0 if MAX_SCORE == 0 else round(earned * 100 / MAX_SCORE)
    # weak areas = not-done items, worst (heaviest weight) first; ties keep
    # ITEMS order so the list is stable.
    not_done = [iid for iid in ITEM_IDS if iid not in done]
    weak = sorted(not_done, key=lambda iid: (-WEIGHTS[iid], ITEM_IDS.index(iid)))
    return {
        "earned": earned,
        "max": MAX_SCORE,
        "percent": percent,
        "grade": grade_for(percent),
        "done": done,
        "weak": weak,
        "done_count": len(done),
        "total_count": len(ITEM_IDS),
        "self_reported": self_reported(),
    }


def top_weak(answers, n=3):
    """The n highest-impact practices the user has NOT done yet — what to fix
    first. Deterministic (follows `score`'s weak ordering)."""
    return score(answers)["weak"][: max(0, int(n))]


def sanitize(answers):
    """Return a clean {item_id: bool} map keyed only by known items — the exact
    shape to persist to the 'security/checklist' row. Drops unknown keys and
    coerces every value to a strict bool so the stored row never drifts."""
    answers = answers or {}
    return {iid: (answers.get(iid) is True) for iid in ITEM_IDS}
