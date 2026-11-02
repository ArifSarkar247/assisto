"""
blood_rules.py — pure rules of the Blood donor panel (owner 2 Nov, flag
`blood_donors`). No DB, no I/O: numbers, eligibility date math, blood-group
compatibility, input cleaning. Every number the panel uses lives HERE (one
place for the owner / a medical advisor to change).

DONATION INTERVAL (whole blood) — sources (see owner_actions/BLOOD_DONOR_BN.md §৪):
  * Bangladesh national guideline (Safe Blood Transfusion Programme, DGHS),
    as reported by Dipta et al., "Demographic Status and Blood Group of Family
    Blood Donors with a Focus on Their Rejection", BIRDEM Medical Journal
    6(2), 2016: a donor who meets the selection criteria may give 450 ml
    "with every 4 months interval, according to the national guideline".
  * WHO, "Blood donor selection: guidelines on assessing donor suitability
    for blood donation" (2012) and India NBTC (2017): 12 weeks / 90 days for
    men, 16 weeks / 120 days for women — SHORTER than the Bangladesh figure.
  * Sources disagree (one Bangladeshi review lists 6 months for women), so we
    use the CONSERVATIVE national 4 months (120 days) for men AND women: it
    satisfies every cited guideline's minimum. Per-sex constants stay so the
    owner's medical advisor can change one number.
"""
from __future__ import annotations

import math
import re
from datetime import date, datetime, timedelta

from . import missing_rules as MR   # districts, coarse(), haversine (shared)

INTERVAL_DAYS = {"m": 120, "f": 120}
INTERVAL_DEFAULT = 120
INTERVAL_SOURCE = ("Bangladesh national guideline (DGHS Safe Blood Transfusion Programme): "
                   "4 months, as reported in BIRDEM Med J 2016;6(2). WHO 2012: 12 weeks men / "
                   "16 weeks women. Conservative 120 days used for everyone.")
MIN_AGE, MAX_AGE, MIN_WEIGHT_KG = 18, 60, 45   # self-declared on the consent page

BLOOD_GROUPS = ("A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-")
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

CONSENT_VERSION = 1
RADIUS_CHOICES = (2, 5, 10, 25)
DEFAULT_RADIUS = 5
DISTRICT_FUZZ_KM = MR.DISTRICT_FUZZ_KM

MAX_REQ_DAY = 3                 # urgent requests per user per 24 h
MAX_ACTIVE_REQ = 2
MAX_UNITS = 10
MAX_NEEDED_IN_H = 72            # needed-by at most 3 days ahead
EXPIRE_AFTER_NEEDED_H = 6       # a request auto-expires 6 h after needed-by
MAX_PUSH_PER_REQUEST = 200      # nearest first; the rest see it in the list
MAX_PUSH_PER_DONOR_DAY = 3
MAX_SEARCH_DAY = 60
MAX_LIST = 100
MAX_NEW_THREADS_DAY = 10
MAX_MSGS_DAY = 60               # per sender per thread
REPORT_HIDE_N = 3
REPORTER_MIN_AGE_DAYS = 3
MAX_REPORTS_DAY = 20
POSTING_BAN_DAYS = 90
REPORT_REASONS = ("fake", "selling", "spam", "harassment", "other")
PHOTO_MAX_BYTES = 6 * 1024 * 1024
PHOTO_MAX_SIDE = 1600
SITE_LINK = "https://lifeassisto.com"

# Blood banks: ONLY from an official / verified published list, with source +
# date — the owner imports it (finish1): `manage.py import_blood_banks
# <csv> --source-name --source-url --source-date` (core/blood_banks.py).
# Until then the app shows EMPTY + "source pending" (never invented entries).


def normalise_group(raw):
    s = str(raw or "").strip().upper().replace(" ", "")
    s = s.replace("POSITIVE", "+").replace("NEGATIVE", "-").replace("VE", "")
    s = s.replace("−", "-").replace("–", "-")
    return s if s in BLOOD_GROUPS else ""


def can_donate_to(donor_group, recipient_group):
    return recipient_group in _CAN_DONATE_TO.get(donor_group, set())


def donor_groups_for(recipient_group):
    """Groups that can give to recipient_group (exact first)."""
    out = [g for g in BLOOD_GROUPS if can_donate_to(g, recipient_group)]
    out.sort(key=lambda g: (g != recipient_group, BLOOD_GROUPS.index(g)))
    return out


def interval_days(sex):
    return INTERVAL_DAYS.get(sex or "", INTERVAL_DEFAULT)


def parse_date(v):
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = MR.clean_text(v, 20).translate(MR._BN_DIGITS) if v else ""
    try:
        return date.fromisoformat(s[:10])
    except ValueError:
        return None


def next_eligible(last_donation, sex):
    d = parse_date(last_donation)
    if d is None:
        return None
    return d + timedelta(days=interval_days(sex))


def is_eligible(last_donation, sex, on_day):
    n = next_eligible(last_donation, sex)
    return n is None or n <= on_day


def clean_last_donation(raw, today):
    """None (never / unknown) or a date not in the future and not before 1950.
    -> (date|None, ok)."""
    if raw in (None, ""):
        return None, True
    d = parse_date(raw)
    if d is None or d > today or d.year < 1950:
        return None, False
    return d, True


def clean_units(raw):
    try:
        n = int(str(raw).translate(MR._BN_DIGITS))
    except (TypeError, ValueError):
        return None
    return n if 1 <= n <= MAX_UNITS else None


def clean_radius(raw):
    try:
        n = int(str(raw).translate(MR._BN_DIGITS))
    except (TypeError, ValueError):
        return DEFAULT_RADIUS
    return n if n in RADIUS_CHOICES else DEFAULT_RADIUS


def area_of(lat, lng, district_code):
    """(lat, lng, fuzz_km) of a coarse point or a district centre; None."""
    if lat is not None and lng is not None:
        return lat, lng, 0
    p = MR.district_point(district_code)
    if p:
        return p[0], p[1], DISTRICT_FUZZ_KM
    return None


def within(a, b, radius_km):
    if not a or not b:
        return False, None
    d = MR.haversine_km(a[0], a[1], b[0], b[1])
    return d <= radius_km + a[2] + b[2], d


def shown_km(d):
    """Rounded distance a viewer sees (whole km, at least 1) — never exact."""
    if d is None:
        return None
    return max(1, int(math.ceil(d)))


def clean_text(raw, cap):
    return MR.clean_text(raw, cap)


def has_contact(text):
    """A phone number or an e-mail in free text (hospital / note / area)."""
    t = str(text or "").translate(MR._BN_DIGITS)
    return MR.has_phone(re.sub(r"[\s\-]", "", t)) or bool(re.search(r"\S+@\S+\.\S+", t))


def first_name(full):
    """What strangers see: the first word of the name only."""
    s = str(full or "").strip().split()
    return s[0][:24] if s else ""
