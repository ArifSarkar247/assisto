"""
blood_donor.py — pure, deterministic BLOOD-DONOR NETWORK logic (#188, SPEC v2.1
§20). A personal / community blood-donor registry: the user's own circle of
donors (blood group, area, last-donation date, availability) plus donation
eligibility math and a privacy-safe search / match.

This is NOT a public directory and needs NO external key — it is the user's own
registry of people who have agreed to be listed.

HARD RULES (Section-21 "advanced" discipline):

  * NO DB, NO AI, NO I/O. Every function is pure: plain dict/list in, plain
    dict/list out. The view layer persists donors in a flexible per-user JSON
    collection and renders exactly what we return.
  * DETERMINISTIC. Eligibility is pure date math from the standard whole-blood
    inter-donation interval (DONATION_INTERVAL_DAYS). Same input -> same output.
  * CONSERVATIVE PRIVACY. A donor's phone is revealed by search ONLY when that
    donor row carries an explicit opt-in flag (`share_contact` true). The
    default is NOT to share. `public_donor_card` never leaks a phone unless
    opted in. We never invent a contact.
  * COMPATIBILITY is informational only (who can donate to whom) — it does NOT
    override the user's own choice of who to call.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer shows them directly and keeps ZERO Bangla in .dart.

Run self-tests (no DB):
    python3 -c "import core.logic.blood_donor_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date, datetime

# Standard minimum interval between two whole-blood donations. 3 months is the
# figure used by Bangladesh blood-transfusion guidance and the Red Crescent, and
# it is the conservative choice vs. the 56-day (8-week) US figure. We expose it
# as a constant so the Dart mirror and tests pin the exact same number.
DONATION_INTERVAL_DAYS = 90

# The eight ABO/Rh blood groups, in a fixed display order.
BLOOD_GROUPS = ("A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-")

AVAILABILITY = ("available", "paused", "unavailable")

# Who can receive from whom (donor group -> set of recipient groups). Pure ABO/Rh
# whole-blood compatibility. O- is the universal donor; AB+ the universal
# recipient.
_CAN_DONATE_TO = {
    "O-": {"O-", "O+", "A-", "A+", "B-", "B+", "AB-", "AB+"},
    "O+": {"O+", "A+", "B+", "AB+"},
    "A-": {"A-", "A+", "AB-", "AB+"},
    "A+": {"A+", "AB+"},
    "B-": {"B-", "B+", "AB-", "AB+"},
    "B+": {"B+", "AB+"},
    "AB-": {"AB-", "AB+"},
    "AB+": {"AB+"},
}


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# date helpers (pure)
# ---------------------------------------------------------------------------

def _parse_date(v):
    """Coerce an ISO-ish date string / date / datetime to a `date`. Junk -> None."""
    if v is None or v == "":
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v).strip()
    # tolerate a full ISO timestamp by taking the date head
    s = s.split("T")[0].split(" ")[0]
    try:
        return date.fromisoformat(s)
    except ValueError:
        return None


def _add_days(d, n):
    from datetime import timedelta
    return d + timedelta(days=n)


def normalise_group(g):
    """Canonicalise a blood-group string ('a positive', 'o+', 'AB-') to one of
    BLOOD_GROUPS, or None if it is not a recognised group."""
    if not g:
        return None
    s = str(g).strip().upper().replace(" ", "")
    s = (s.replace("POSITIVE", "+").replace("POS", "+")
           .replace("NEGATIVE", "-").replace("NEG", "-"))
    return s if s in BLOOD_GROUPS else None


# ---------------------------------------------------------------------------
# eligibility — the core date math
# ---------------------------------------------------------------------------

def next_eligible_date(last_donation):
    """Return the date the donor is next eligible, i.e. last_donation +
    DONATION_INTERVAL_DAYS. None if no (valid) last-donation date is known —
    which we treat as 'eligible now, unknown history'."""
    d = _parse_date(last_donation)
    if d is None:
        return None
    return _add_days(d, DONATION_INTERVAL_DAYS)


def eligibility(last_donation, today=None):
    """Pure eligibility computation for one donor.

    Returns:
        {
          'eligible'      : bool,   # eligible to donate on `today`
          'next_date'     : 'YYYY-MM-DD' | None,
          'days_left'     : int,    # 0 if eligible / unknown
          'has_history'   : bool,   # a valid last-donation date was supplied
          'state'         : 'eligible' | 'resting' | 'unknown',
        }

    If no last-donation date is known we return state 'unknown' and treat the
    donor as eligible (we never block a willing donor on missing history) — but
    we flag has_history False so the UI can say "last donation unknown".
    """
    today = _parse_date(today) or date.today()
    nxt = next_eligible_date(last_donation)
    if nxt is None:
        return {"eligible": True, "next_date": None, "days_left": 0,
                "has_history": False, "state": "unknown"}
    days_left = (nxt - today).days
    if days_left <= 0:
        return {"eligible": True, "next_date": nxt.isoformat(), "days_left": 0,
                "has_history": True, "state": "eligible"}
    return {"eligible": False, "next_date": nxt.isoformat(),
            "days_left": days_left, "has_history": True, "state": "resting"}


# ---------------------------------------------------------------------------
# compatibility
# ---------------------------------------------------------------------------

def can_donate_to(donor_group, recipient_group):
    """Pure ABO/Rh whole-blood compatibility. Unknown groups -> False (we never
    guess a compatibility we are not sure of)."""
    dg = normalise_group(donor_group)
    rg = normalise_group(recipient_group)
    if dg is None or rg is None:
        return False
    return rg in _CAN_DONATE_TO.get(dg, set())


def compatible_donor_groups(recipient_group):
    """All donor groups that can give to `recipient_group`, in BLOOD_GROUPS
    order. Empty list for an unknown recipient group."""
    rg = normalise_group(recipient_group)
    if rg is None:
        return []
    return [g for g in BLOOD_GROUPS if rg in _CAN_DONATE_TO.get(g, set())]


# ---------------------------------------------------------------------------
# privacy-safe donor card
# ---------------------------------------------------------------------------

def _wants_share(donor):
    return bool(donor.get("share_contact"))


def public_donor_card(donor, today=None):
    """Project a stored donor row into a privacy-safe card for display.

    The phone is included ONLY when the donor row explicitly opted in
    (`share_contact` true). Otherwise `phone` is None and `contact_hidden` is
    True so the UI shows an honest "contact hidden (not shared)" state instead
    of inventing or exposing a number.
    """
    group = normalise_group(donor.get("blood_group"))
    elig = eligibility(donor.get("last_donation"), today=today)
    avail = donor.get("availability", "available")
    if avail not in AVAILABILITY:
        avail = "available"
    shared = _wants_share(donor)
    return {
        "id": donor.get("id"),
        "name": (donor.get("name") or "").strip(),
        "blood_group": group,
        "area": (donor.get("area") or "").strip(),
        "availability": avail,
        "eligible": elig["eligible"],
        "eligibility_state": elig["state"],
        "next_date": elig["next_date"],
        "days_left": elig["days_left"],
        "has_history": elig["has_history"],
        "share_contact": shared,
        "contact_hidden": not shared,
        "phone": (donor.get("phone") or "").strip() if shared else None,
    }


# ---------------------------------------------------------------------------
# search / match
# ---------------------------------------------------------------------------

def _norm_text(s):
    return (s or "").strip().lower()


def search_donors(donors, blood_group=None, area=None, only_available=False,
                  only_eligible=False, compatible_for=None, today=None):
    """Filter + rank the user's own donor registry. Pure.

    Filters (all optional, AND-combined):
      blood_group    : exact canonical group match (after normalising)
      area           : case-insensitive substring match on the donor's area
      only_available : drop donors whose availability != 'available'
      only_eligible  : drop donors not eligible on `today`
      compatible_for : a recipient blood group — keep donors who CAN give to it
                       (used when you don't care about exact group, only that
                       the blood is usable). Ignored if blood_group is given.

    Ranking (deterministic): eligible-and-available first, then eligible, then
    others; within a tier soonest-next-eligible first; ties by name then id.

    Returns a list of privacy-safe donor cards (see public_donor_card) — phones
    appear only for opted-in donors.
    """
    want_group = normalise_group(blood_group)
    want_area = _norm_text(area)
    compat = normalise_group(compatible_for)

    cards = []
    for d in donors:
        card = public_donor_card(d, today=today)
        if want_group is not None and card["blood_group"] != want_group:
            continue
        if want_group is None and compat is not None:
            if not can_donate_to(card["blood_group"], compat):
                continue
        if want_area and want_area not in _norm_text(card["area"]):
            continue
        if only_available and card["availability"] != "available":
            continue
        if only_eligible and not card["eligible"]:
            continue
        cards.append(card)

    def _tier(c):
        if c["eligible"] and c["availability"] == "available":
            return 0
        if c["eligible"]:
            return 1
        return 2

    def _sort_key(c):
        # soonest next-eligible first; unknown/eligible-now sort as 0 days
        days = c["days_left"] if not c["eligible"] else 0
        return (_tier(c), days, _norm_text(c["name"]), str(c.get("id") or ""))

    cards.sort(key=_sort_key)
    return cards


def registry_summary(donors, today=None):
    """Headline counts for the registry home card. Pure.

    Returns {'total','available_now','eligible_now','by_group':{g:count},
    'note':{bn,en}}.
    """
    cards = [public_donor_card(d, today=today) for d in donors]
    by_group = {}
    avail = eligible = 0
    for c in cards:
        g = c["blood_group"] or "?"
        by_group[g] = by_group.get(g, 0) + 1
        if c["availability"] == "available":
            avail += 1
        if c["eligible"]:
            eligible += 1
    return {
        "total": len(cards),
        "available_now": avail,
        "eligible_now": eligible,
        "by_group": by_group,
        "note": {
            "bn": "এটি আপনার নিজের/কমিউনিটির রক্তদাতা তালিকা — যারা তালিকাভুক্ত "
                  "হতে রাজি হয়েছেন। ফোন নম্বর শুধু তখনই দেখানো হয় যখন দাতা নিজে "
                  "তা শেয়ার করতে সম্মতি দিয়েছেন।",
            "en": "This is your own / community donor list — only people who "
                  "agreed to be listed. A phone number is shown only when that "
                  "donor opted in to share it.",
        },
    }


# ---------------------------------------------------------------------------
# validation (before a donor row is stored)
# ---------------------------------------------------------------------------

def validate_donor(donor):
    """Validation codes for a donor row before it is stored. Pure."""
    problems = []
    if not (donor.get("name") or "").strip():
        problems.append("name_required")
    if normalise_group(donor.get("blood_group")) is None:
        problems.append("blood_group_required")
    if donor.get("last_donation") not in (None, "") \
            and _parse_date(donor.get("last_donation")) is None:
        problems.append("bad_last_donation")
    avail = donor.get("availability")
    if avail not in (None, "") and avail not in AVAILABILITY:
        problems.append("bad_availability")
    if _wants_share(donor) and not (donor.get("phone") or "").strip():
        problems.append("share_on_without_phone")
    return problems
