"""
missing_rules — PURE rules for the Missing person alert ("নিখোঁজ সতর্কতা",
owner 2 Nov). No Django imports: unit-testable and mirrored in the app where a
check runs before a network call (GD format, age class).

What lives here:
  * the 64 districts (bn/en name + district-HQ point) used as a COARSE area;
  * coarse rounding (2 decimals, ~1.1 km) — we never store a precise point;
  * the GD number format check (police General Diary). A format check only:
    we NEVER claim the number was verified with the police;
  * child / adult (under 18 = child, Children Act 2013);
  * who is "nearby" (distance with district fuzz when only a district is known);
  * limits (posting, pushes per day, tips, reports) in one place.
"""
import math
import re
from datetime import date, timedelta

CHILD_UNDER = 18
EXPIRY_DAYS = 7
RENEW_DAYS = 7
MAX_RENEWALS = 4
RENEW_WINDOW_H = 48           # renew is offered in the last 48 h of an alert
RADIUS_CHOICES = (5, 10, 25)
DEFAULT_RADIUS = 10
DISTRICT_FUZZ_KM = 20         # a district-only area is "somewhere in the district"
MAX_ACTIVE_PER_POSTER = 2
MAX_POSTS_30D = 3
COOLING_DAYS = 7              # after "I am safe": no new alert for that person without a NEW GD
MAX_PUSH_PER_ALERT = 500      # nearest first; the rest see it in the app list
MAX_PUSH_PER_USER_DAY = 3     # nearby-alert pushes one user gets in 24 h
MAX_TIP_THREADS_DAY = 10
MAX_TIP_MSGS_DAY = 30
REPORT_HIDE_N = 3             # independent reports -> hidden until admin review
REPORTER_MIN_AGE_DAYS = 3     # accounts younger than this do not count toward N
MAX_REPORTS_DAY = 20
OPEN_LOCATION_TTL_H = 12      # a "where I am" point counts this long
OPEN_LOCATION_MIN_GAP_MIN = 30
POSTING_BAN_DAYS = 90         # after an admin removes a post as fake
GD_MAX_AGE_DAYS = 60
PHOTO_MAX_BYTES = 6 * 1024 * 1024
PHOTO_MAX_SIDE = 1024
SITE_LINK = "https://lifeassisto.com"

# (code, name_en, name_bn, lat, lng) — district headquarters (coarse).
DISTRICTS = (
    ("dhaka", "Dhaka", "ঢাকা", 23.81, 90.41),
    ("gazipur", "Gazipur", "গাজীপুর", 24.00, 90.42),
    ("narayanganj", "Narayanganj", "নারায়ণগঞ্জ", 23.62, 90.50),
    ("narsingdi", "Narsingdi", "নরসিংদী", 23.93, 90.72),
    ("manikganj", "Manikganj", "মানিকগঞ্জ", 23.86, 90.00),
    ("munshiganj", "Munshiganj", "মুন্সীগঞ্জ", 23.54, 90.53),
    ("tangail", "Tangail", "টাঙ্গাইল", 24.25, 89.92),
    ("kishoreganj", "Kishoreganj", "কিশোরগঞ্জ", 24.44, 90.78),
    ("faridpur", "Faridpur", "ফরিদপুর", 23.61, 89.84),
    ("gopalganj", "Gopalganj", "গোপালগঞ্জ", 23.01, 89.83),
    ("madaripur", "Madaripur", "মাদারীপুর", 23.16, 90.19),
    ("rajbari", "Rajbari", "রাজবাড়ী", 23.76, 89.64),
    ("shariatpur", "Shariatpur", "শরীয়তপুর", 23.24, 90.43),
    ("chattogram", "Chattogram", "চট্টগ্রাম", 22.36, 91.78),
    ("coxsbazar", "Cox's Bazar", "কক্সবাজার", 21.43, 92.01),
    ("cumilla", "Cumilla", "কুমিল্লা", 23.46, 91.18),
    ("feni", "Feni", "ফেনী", 23.02, 91.40),
    ("noakhali", "Noakhali", "নোয়াখালী", 22.87, 91.10),
    ("lakshmipur", "Lakshmipur", "লক্ষ্মীপুর", 22.94, 90.83),
    ("chandpur", "Chandpur", "চাঁদপুর", 23.23, 90.67),
    ("brahmanbaria", "Brahmanbaria", "ব্রাহ্মণবাড়িয়া", 23.96, 91.11),
    ("rangamati", "Rangamati", "রাঙ্গামাটি", 22.65, 92.18),
    ("khagrachhari", "Khagrachhari", "খাগড়াছড়ি", 23.12, 91.98),
    ("bandarban", "Bandarban", "বান্দরবান", 22.20, 92.22),
    ("rajshahi", "Rajshahi", "রাজশাহী", 24.37, 88.60),
    ("bogura", "Bogura", "বগুড়া", 24.85, 89.38),
    ("pabna", "Pabna", "পাবনা", 24.01, 89.24),
    ("sirajganj", "Sirajganj", "সিরাজগঞ্জ", 24.45, 89.70),
    ("natore", "Natore", "নাটোর", 24.42, 89.00),
    ("naogaon", "Naogaon", "নওগাঁ", 24.79, 88.93),
    ("chapainawabganj", "Chapainawabganj", "চাঁপাইনবাবগঞ্জ", 24.60, 88.28),
    ("joypurhat", "Joypurhat", "জয়পুরহাট", 25.10, 89.02),
    ("khulna", "Khulna", "খুলনা", 22.85, 89.54),
    ("jashore", "Jashore", "যশোর", 23.17, 89.21),
    ("satkhira", "Satkhira", "সাতক্ষীরা", 22.72, 89.07),
    ("bagerhat", "Bagerhat", "বাগেরহাট", 22.65, 89.79),
    ("kushtia", "Kushtia", "কুষ্টিয়া", 23.90, 89.12),
    ("jhenaidah", "Jhenaidah", "ঝিনাইদহ", 23.55, 89.17),
    ("magura", "Magura", "মাগুরা", 23.49, 89.42),
    ("narail", "Narail", "নড়াইল", 23.17, 89.51),
    ("chuadanga", "Chuadanga", "চুয়াডাঙ্গা", 23.64, 88.84),
    ("meherpur", "Meherpur", "মেহেরপুর", 23.76, 88.63),
    ("barishal", "Barishal", "বরিশাল", 22.70, 90.35),
    ("bhola", "Bhola", "ভোলা", 22.69, 90.65),
    ("patuakhali", "Patuakhali", "পটুয়াখালী", 22.36, 90.33),
    ("pirojpur", "Pirojpur", "পিরোজপুর", 22.58, 89.97),
    ("jhalokati", "Jhalokati", "ঝালকাঠি", 22.64, 90.20),
    ("barguna", "Barguna", "বরগুনা", 22.10, 90.11),
    ("sylhet", "Sylhet", "সিলেট", 24.89, 91.87),
    ("moulvibazar", "Moulvibazar", "মৌলভীবাজার", 24.48, 91.78),
    ("habiganj", "Habiganj", "হবিগঞ্জ", 24.37, 91.42),
    ("sunamganj", "Sunamganj", "সুনামগঞ্জ", 25.07, 91.40),
    ("rangpur", "Rangpur", "রংপুর", 25.74, 89.28),
    ("dinajpur", "Dinajpur", "দিনাজপুর", 25.62, 88.64),
    ("kurigram", "Kurigram", "কুড়িগ্রাম", 25.81, 89.64),
    ("gaibandha", "Gaibandha", "গাইবান্ধা", 25.33, 89.53),
    ("nilphamari", "Nilphamari", "নীলফামারী", 25.93, 88.86),
    ("lalmonirhat", "Lalmonirhat", "লালমনিরহাট", 25.99, 89.28),
    ("thakurgaon", "Thakurgaon", "ঠাকুরগাঁও", 26.03, 88.46),
    ("panchagarh", "Panchagarh", "পঞ্চগড়", 26.34, 88.55),
    ("mymensingh", "Mymensingh", "ময়মনসিংহ", 24.75, 90.42),
    ("jamalpur", "Jamalpur", "জামালপুর", 24.94, 89.94),
    ("sherpur", "Sherpur", "শেরপুর", 25.02, 90.02),
    ("netrokona", "Netrokona", "নেত্রকোনা", 24.87, 90.73),
)
_BY_CODE = {d[0]: d for d in DISTRICTS}

REPORT_REASONS = ("fake", "not_missing", "wrong_photo", "harassment", "spam", "other")

_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def district(code):
    return _BY_CODE.get((code or "").strip().lower())


def district_point(code):
    d = district(code)
    return (d[3], d[4]) if d else None


def district_list(lang="bn"):
    return [{"code": c, "name": bn if lang == "bn" else en, "bn": bn, "en": en}
            for c, en, bn, _la, _ln in DISTRICTS]


def nearest_district(lat, lng):
    if lat is None or lng is None:
        return ""
    best, bd = "", None
    for c, _en, _bn, la, ln in DISTRICTS:
        d = haversine_km(lat, lng, la, ln)
        if bd is None or d < bd:
            best, bd = c, d
    return best


def coarse(v):
    """Round a coordinate to 2 decimals (~1.1 km). None stays None."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if math.isnan(f) or math.isinf(f):
        return None
    return round(f, 2)


def in_bangladesh(lat, lng):
    return lat is not None and lng is not None and 20.3 <= lat <= 26.8 and 87.9 <= lng <= 92.8


def haversine_km(a_lat, a_lng, b_lat, b_lng):
    r = 6371.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp = p2 - p1
    dl = math.radians(b_lng - a_lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def is_child(age):
    try:
        return int(age) < CHILD_UNDER
    except (TypeError, ValueError):
        return False


def clean_age(raw):
    try:
        a = int(str(raw).translate(_BN_DIGITS).strip())
    except (TypeError, ValueError):
        return None
    return a if 0 <= a <= 110 else None


def clean_radius(raw):
    try:
        r = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_RADIUS
    return r if r in RADIUS_CHOICES else DEFAULT_RADIUS


# ------------------------------------------------------------------ GD
# A Bangladesh police General Diary number as families write it: the diary
# number, optionally "/<year>" or "/<month>", sometimes prefixed "GD", "No."
# or the Bangla "জিডি নং". Bangla digits are accepted. A FORMAT check only.
_GD_PREFIX = re.compile(r"^(gd|g\.d\.?|জিডি|জি\.ডি\.?)\s*(no\.?|nong|নং|নম্বর)?\s*[:.\-#]?\s*",
                        re.I)
_GD_BODY = re.compile(r"^\d{1,6}(\s*/\s*\d{1,4}){0,2}$")


def clean_gd_number(raw):
    """-> normalised GD number ("123/2026") or None when the format is wrong."""
    s = str(raw or "").translate(_BN_DIGITS).strip()
    s = _GD_PREFIX.sub("", s).strip()
    s = re.sub(r"\s+", "", s)
    if not s or not _GD_BODY.match(s):
        return None
    if int(s.split("/")[0]) == 0:
        return None
    return s


def gd_problems(number, thana, gd_date, today):
    """-> (clean dict, [problem codes]). Codes: gd_number, gd_thana, gd_date."""
    out, bad = {}, []
    n = clean_gd_number(number)
    if n is None:
        bad.append("gd_number")
    else:
        out["gd_number"] = n
    t = re.sub(r"\s+", " ", str(thana or "")).strip()
    if not (2 <= len(t) <= 80):
        bad.append("gd_thana")
    else:
        out["gd_thana"] = t
    d = gd_date
    if isinstance(d, str):
        try:
            d = date.fromisoformat(d.translate(_BN_DIGITS).strip()[:10])
        except ValueError:
            d = None
    if not isinstance(d, date) or d > today or d < today - timedelta(days=GD_MAX_AGE_DAYS):
        bad.append("gd_date")
    else:
        out["gd_date"] = d
    return out, bad


# ------------------------------------------------------------------ nearby
def area_of(lat, lng, district_code):
    """-> (lat, lng, fuzz_km) for an alert or a user's area; None when unknown."""
    if lat is not None and lng is not None:
        return lat, lng, 0
    p = district_point(district_code)
    if p:
        return p[0], p[1], DISTRICT_FUZZ_KM
    return None


def is_nearby(alert_area, radius_km, user_area, same_district=False):
    """True when the user's coarse area falls inside the alert's radius
    (plus the district fuzz of whichever side is only a district)."""
    if same_district:
        return True
    if not alert_area or not user_area:
        return False
    d = haversine_km(alert_area[0], alert_area[1], user_area[0], user_area[1])
    return d <= radius_km + alert_area[2] + user_area[2]


def distance_km(alert_area, user_area):
    if not alert_area or not user_area:
        return None
    return haversine_km(alert_area[0], alert_area[1], user_area[0], user_area[1])


# ------------------------------------------------------------------ text
_ADDR = re.compile(r"(house|holding|flat|বাসা|বাড়ি নং|হোল্ডিং|ফ্ল্যাট)\s*(no\.?|নং|#)?\s*[:\-]?\s*\d",
                   re.I)
_PHONE = re.compile(r"(\+?88)?0?1[3-9]\d{8}")


def looks_like_address(text):
    """A house / flat / road NUMBER in the area or description -> refuse
    (we never publish a home address)."""
    return bool(_ADDR.search(str(text or "").translate(_BN_DIGITS)))


def has_phone(text):
    """Contact goes through the app: a phone number in public text is refused."""
    return bool(_PHONE.search(re.sub(r"[\s\-]", "", str(text or "").translate(_BN_DIGITS))))


def clean_text(raw, cap):
    s = re.sub(r"[\u0000-\u0008\u000b-\u001f]", "", str(raw or "")).strip()
    return s[:cap]
