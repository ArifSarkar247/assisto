"""train — pure rules for the per-train chat (same train + same date).

* nickname only — never a name, phone or profile; the API never returns a
  user id, so nobody can open anybody's profile;
* "add to My Circle" is a REQUEST: the other person accepts or declines;
* emergency words (bn / en / Banglish) make the app show 999 and the rail
  hotline 131 (one tap opens the dialer — never auto-dial);
* rate limits; the whole room is deleted after the trip (purge job inside the
  existing per-minute journey sweep — no new cron line).
"""
import re
import unicodedata

POLICE = "999"
RAIL_HOTLINE = "131"
SMS_TO = "16318"
SMS_COST_BDT = 4

MSG_MAX = 500
NICK_MIN, NICK_MAX = 2, 20
PER_MIN = 6                 # messages per user per minute
PER_DAY = 150               # messages per user per day (all rooms)
REPORTS_PER_DAY = 10
CIRCLE_REQ_PER_ROOM = 5
HIDE_AFTER_REPORTS = 3      # distinct reporters hide a message for everyone

EMERGENCY_WORDS = (
    # Bangla
    "অসুস্থ", "সাহায্য", "বাঁচাও", "বাচাও", "জরুরি", "জরুরী", "বিপদ", "ডাকাত",
    "ছিনতাই", "হামলা", "আগুন", "রক্ত", "অজ্ঞান", "হার্ট অ্যাটাক", "দুর্ঘটনা",
    "পুলিশ", "অ্যাম্বুলেন্স", "এম্বুলেন্স", "ডাক্তার লাগবে", "হয়রানি", "শ্লীলতাহানি",
    # English
    "help", "sick", "emergency", "sos", "fire", "robbery", "robbed", "attack",
    "unconscious", "bleeding", "heart attack", "accident", "ambulance", "police",
    "harass", "harassment", "doctor needed", "need a doctor",
    # Banglish
    "osustho", "osusto", "shahajjo", "sahajjo", "shahajo", "bachao", "bachaw",
    "jorur", "jorury", "bipod", "dakat", "chhintai", "chintai", "agun",
    "ogyan", "oggan", "durghotona", "ambulance lagbe", "daktar lagbe",
)

_NICK_OK = re.compile(r"^[\wঀ-৿ .\-]+$")
_PHONE_LIKE = re.compile(r"(?:\+?88)?0?1[3-9]\d{8}|\d{7,}")
_LINK = re.compile(r"https?://|www\.|\.com\b|\.bd\b|t\.me/|wa\.me/", re.I)


def norm(text):
    t = unicodedata.normalize("NFC", str(text or "")).lower()
    return re.sub(r"\s+", " ", t).strip()


def is_emergency(text):
    """True when the message contains an emergency word (whole word for the
    short Latin ones so 'helpful' / 'sosa' do not fire)."""
    t = norm(text)
    if not t:
        return False
    for w in EMERGENCY_WORDS:
        if re.fullmatch(r"[a-z ]+", w):
            if re.search(r"(?<![a-z])" + re.escape(w) + r"(?![a-z])", t):
                return True
        elif w in t:
            return True
    return False


def clean_nickname(raw):
    """(nickname, error). No phone numbers / links in a nickname."""
    n = re.sub(r"\s+", " ", unicodedata.normalize("NFC", str(raw or ""))).strip()
    if len(n) < NICK_MIN or len(n) > NICK_MAX:
        return None, "nickname_length"
    if not _NICK_OK.match(n) or _PHONE_LIKE.search(n) or _LINK.search(n):
        return None, "nickname_invalid"
    return n, None


def clean_message(raw):
    """(text, error). Phone numbers are masked: strangers swap numbers only
    through an accepted My Circle request."""
    t = unicodedata.normalize("NFC", str(raw or "")).strip()
    if not t:
        return None, "empty"
    if len(t) > MSG_MAX:
        return None, "too_long"
    t = _PHONE_LIKE.sub("•••", t)
    return t, None


def sms_body(train_no):
    return "TR %s" % str(train_no).strip()


def sms_uri(train_no):
    """sms: link the phone's OWN SMS app opens (the user presses Send)."""
    return "sms:%s?body=%s" % (SMS_TO, sms_body(train_no).replace(" ", "%20"))
