"""
discover.py — HOME "Discover" cards manager (slot d1-discover). PURE logic:
no Django, no DB. The views resolve rows into plain dicts and call these.

SERVER-ENFORCED RULES (the app never decides who sees what):
  * disabled cards are hidden;
  * a card is shown only inside its [start_at, end_at) window (either end open);
  * min_build: a card with a minimum app build is hidden for older builds AND
    for clients that did not report a build (conservative);
  * audience: all | free | premium | business, matched against the user's
    plan SEGMENT (free / premium / business — see billing._segment_of);
  * SPONSORED cards reach EVERY plan by default (owner decision, 21 Oct) —
    always labelled "Sponsored"; the per-card audience can still narrow them;
  * Premium and Business users NEVER receive ADMOB cards (no AdMob ads is a
    paid-plan benefit), whatever the card's audience says;
  * the ADMOB slot is for FREE users only, at most ONE, and only when no active
    SPONSORED card is booked for that user (a sponsor always wins the slot).

LABELS (not editable — derived from the type, so a sponsor can never hide it):
  OUR_PRODUCT -> "our_products",  SPONSORED -> "sponsored", others -> "".

CONTENT SAFETY (on every admin save): rejects gambling / adult / scam or fake-
claim wording in bn + en, reuses the Scam-check engine (core.logic.scam) on the
copy, and only accepts https URLs that are not link shorteners / IP literals.
"""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta
from urllib.parse import urlparse

FEATURE = "FEATURE"
OUR_PRODUCT = "OUR_PRODUCT"
SPONSORED = "SPONSORED"
ADMOB = "ADMOB"
TYPES = (FEATURE, OUR_PRODUCT, SPONSORED, ADMOB)

AUDIENCES = ("all", "free", "premium", "business")
SEGMENTS = ("free", "premium", "business")

# In-app route keys the app can open (mirror of ChatNav.routes in
# app/lib/widgets/chatnav.dart — a test asserts they stay in lock-step).
ROUTE_KEYS = (
    "money", "documents", "family", "reminders", "vehicles", "vehicle_tracking",
    "car_mode", "emergency", "plans", "scam", "safety", "voice_sos", "crm",
    "medicine_db", "health_tips", "birthdays", "meetings", "dictionary",
    "ride_food", "fall_detect", "lost_stolen", "my_lost_phone", "recovery",
    "phone_safety", "security", "used_phone_check", "sell_phone", "shop_box",
    "analytics", "name_about", "ramadan", "exam", "unseen", "photo_enhance",
    "circle", "circle_add", "messages", "notifications", "groups", "status", "legal",
    "subscriptions", "finance", "payment_ladder", "notes", "memory", "nominee",
    "contacts", "agent_studio", "jobs", "cv", "resume", "inbox", "guide",
    "nearby", "watch_feed", "business", "bargain_rules", "business_plans",
    "journey", "referral", "circle_privacy", "circle_calls", "action_center",
    "disaster", "offline", "budget", "tax", "wrapped", "money_voice", "ai_chat",
    "voice_assistant", "voice_settings", "photo_studio",
    "feedback",  # f1-founders
    "offers",  # p2-money: brand offers feed
    "watchman",  # cctv1: Home & shop watchman
    "booking", "my_bookings",  # booking-bot (flag booking_bot)
)

# Icon names the app knows how to draw (app/lib/widgets/home_suggestions.dart
# `_kIcons`). Anything else falls back to a generic icon in the app.
ICONS = (
    "auto_fix_high", "phonelink_lock", "near_me", "diversity_3", "verified",
    "directions_car", "security", "workspace_premium", "storefront",
    "account_tree", "campaign", "star", "local_offer", "shopping_bag",
    "favorite", "school", "health", "family", "money", "lightbulb",
)


def label_for(card_type):
    if card_type == OUR_PRODUCT:
        return "our_products"
    if card_type == SPONSORED:
        return "sponsored"
    return ""


# --------------------------------------------------------------------- rules
def _active_window(card, now):
    s, e = card.get("start_at"), card.get("end_at")
    if s is not None and now < s:
        return False
    if e is not None and now >= e:
        return False
    return True


def _build_ok(card, build):
    mb = card.get("min_build")
    if not mb:
        return True
    if build is None:
        return False
    return int(build) >= int(mb)


def _audience_ok(card, segment):
    aud = card.get("audience") or "all"
    return aud == "all" or aud == segment


def visible_cards(cards, segment, build, now, hero_ad=False):
    """Filter + order `cards` (plain dicts) for one user. Returns a new list.

    `segment` ∈ free / premium / business (unknown -> free). `build` = the app
    build number the client reported, or None. `now` = aware datetime."""
    segment = segment if segment in SEGMENTS else "free"
    paid = segment != "free"
    base = []
    for c in cards or []:
        t = c.get("type")
        if t not in TYPES or not c.get("enabled"):
            continue
        if paid and t == ADMOB:
            continue          # Premium / Business never see AdMob (plan benefit)
        if not _active_window(c, now):
            continue
        if not _build_ok(c, build):
            continue
        if not _audience_ok(c, segment):
            continue
        base.append(c)
    base.sort(key=lambda c: (int(c.get("order") or 0), int(c.get("id") or 0)))
    has_sponsor = any(c.get("type") == SPONSORED for c in base)
    out, admob_used = [], False
    for c in base:
        if c.get("type") == ADMOB:
            # h1-home: only ONE AdMob ad on home — while the home hero is
            # showing a native ad the Discover AdMob slot is dropped.
            if paid or has_sponsor or admob_used or hero_ad:
                continue
            admob_used = True
        out.append(c)
    return out


# --------------------------------------------------------------- safety check
_EN_BANNED = [
    # gambling / betting
    r"casino", r"gambl\w*", r"betting", r"\bbet\b", r"\bbets\b", r"jackpot",
    r"lottery", r"\bpoker\b", r"1x\s?bet", r"\bslots?\s+game", r"sports?\s*book",
    # adult
    r"porn\w*", r"\bxxx\b", r"\bsex\w*", r"\bnude\w*", r"\bnudity\b", r"escort",
    r"hook\s?up", r"adults?\s+only", r"adult\s+content", r"18\s*\+",
    # scam / fake claims
    r"guarantee\w*\s+(profit|income|return|earning)", r"double\s+your\s+money",
    r"100\s*%\s*guarantee\w*", r"get\s+rich", r"free\s+money", r"risk[\s-]?free",
    r"no\s+risk", r"miracle", r"instant\s+loan", r"earn\s+\d[\d,]*\s*(tk|taka|bdt|৳)",
    r"work\s+from\s+home\s+and\s+earn", r"\bwin\s+(cash|money|prize)",
    r"crypto\s+(doubl|invest)\w*", r"forex\s+signal", r"\bmlm\b",
]
_BN_BANNED = [
    "জুয়া", "জুয়া", "ক্যাসিনো", "বাজি", "বেটিং", "লটারি", "জ্যাকপট",
    "পর্ন", "যৌন", "নগ্ন", "এসকর্ট", "১৮+", "প্রাপ্তবয়স্ক",
    "গ্যারান্টিড লাভ", "নিশ্চিত লাভ", "নিশ্চিত আয়", "নিশ্চিত আয়", "টাকা দ্বিগুণ",
    "দ্বিগুণ টাকা", "দ্বিগুণ লাভ", "রাতারাতি", "ঘরে বসে আয়", "ঘরে বসে আয়",
    "ফ্রি টাকা", "বিনামূল্যে টাকা", "অলৌকিক", "ঝুঁকিমুক্ত বিনিয়োগ", "লোন সাথে সাথে",
    "এমএলএম",
]
_EN_RE = [re.compile(p, re.I) for p in _EN_BANNED]

EXTRA_SHORTENERS = (
    "ow.ly", "buff.ly", "s.id", "tiny.cc", "shorte.st", "adf.ly", "lnkd.in",
    "t.co", "rebrand.ly", "bl.ink", "short.io", "v.gd", "shorturl.at", "x.co",
    "trib.al", "soo.gd", "clck.ru",
)


def _shorteners():
    try:
        from . import scam as S
        base = tuple(S.SHORTENERS)
    except Exception:
        base = ()
    return base + EXTRA_SHORTENERS


def _text_issues(text):
    out = []
    if not text:
        return out
    low = text.lower()
    for rx in _EN_RE:
        if rx.search(low):
            out.append("banned_wording")
            break
    if "banned_wording" not in out:
        if any(w in text for w in _BN_BANNED):
            out.append("banned_wording")
    try:
        from . import scam as S
        res = S.check_message(text, lang="en")
        if res.get("verdict") == "scam":
            out.append("scam_pattern")
    except Exception:
        pass
    return out


def url_issue(url):
    """None when `url` is an acceptable external link, else a reason code."""
    u = (url or "").strip()
    if not u:
        return None
    try:
        p = urlparse(u)
    except Exception:
        return "bad_url"
    if p.scheme != "https":
        return "url_not_https"
    host = (p.hostname or "").lower()
    if not host or "." not in host or "@" in (p.netloc or ""):
        return "bad_url"
    if re.fullmatch(r"[\d.]+", host) or ":" in host:
        return "url_ip_literal"
    for s in _shorteners():
        s = s.lower()
        if host == s or host.endswith("." + s) or ("." not in s and s in host):
            return "url_shortener"
    return None


def safety_issues(fields):
    """Content-safety check for an admin save. `fields` = dict with any of
    title_bn/title_en/desc_bn/desc_en/sponsor_name/url/route/type/icon.
    Returns a sorted list of reason codes ([] = safe)."""
    issues = set()
    for k in ("title_bn", "title_en", "desc_bn", "desc_en", "sponsor_name"):
        for i in _text_issues(fields.get(k) or ""):
            issues.add(i)
    ui = url_issue(fields.get("url"))
    if ui:
        issues.add(ui)
    # the copy itself must not smuggle a link (only the action URL may carry one)
    for k in ("title_bn", "title_en", "desc_bn", "desc_en"):
        v = (fields.get(k) or "").lower()
        if "http://" in v or "https://" in v or "www." in v:
            issues.add("link_in_text")
    return sorted(issues)


def validate(fields):
    """Structural validation (not safety). Returns {field: reason} errors."""
    err = {}
    t = fields.get("type")
    if t not in TYPES:
        err["type"] = "invalid"
    if (fields.get("audience") or "all") not in AUDIENCES:
        err["audience"] = "invalid"
    if t != ADMOB:
        if not (fields.get("title_bn") or "").strip():
            err["title_bn"] = "required"
        if not (fields.get("title_en") or "").strip():
            err["title_en"] = "required"
    route = (fields.get("route") or "").strip()
    url = (fields.get("url") or "").strip()
    if route and url:
        err["action"] = "route_or_url"
    if route and route not in ROUTE_KEYS:
        err["route"] = "unknown_route"
    if t in (OUR_PRODUCT, SPONSORED) and not (route or url):
        err["action"] = "required"
    if t == FEATURE and not (route or url):
        err["action"] = "required"
    icon = (fields.get("icon") or "").strip()
    if icon and icon not in ICONS:
        err["icon"] = "unknown_icon"
    if t == SPONSORED and not (fields.get("sponsor_name") or "").strip():
        err["sponsor_name"] = "required"
    s, e = fields.get("start_at"), fields.get("end_at")
    if s is not None and e is not None and e <= s:
        err["end_at"] = "before_start"
    try:
        rev = float(fields.get("sponsor_revenue") or 0)
        if rev < 0:
            err["sponsor_revenue"] = "negative"
    except (TypeError, ValueError):
        err["sponsor_revenue"] = "invalid"
    mb = fields.get("min_build")
    if mb not in (None, ""):
        try:
            if int(mb) < 0:
                err["min_build"] = "invalid"
        except (TypeError, ValueError):
            err["min_build"] = "invalid"
    return err


# ------------------------------------------------------------ sponsor revenue
def revenue_by_day(card, tz_localdate):
    """Spread one SPONSORED card's booked revenue over its run, per LOCAL date.

    With both start and end: evenly across every local date from start to the
    day before/at end (inclusive of start, end-exclusive by instant -> the
    date of end - 1µs). Only a start: the whole amount on the start date. No
    dates: the whole amount on the created date. Returns {date: amount}."""
    amount = float(card.get("sponsor_revenue") or 0)
    if amount <= 0 or card.get("type") != SPONSORED:
        return {}
    s, e = card.get("start_at"), card.get("end_at")
    if s is not None and e is not None and e > s:
        d0 = tz_localdate(s)
        d1 = tz_localdate(e - timedelta(microseconds=1))
        n = (d1 - d0).days + 1
        per = amount / n
        return {d0 + timedelta(days=i): per for i in range(n)}
    anchor = s or card.get("created_at")
    if anchor is None:
        return {}
    d = tz_localdate(anchor) if isinstance(anchor, datetime) else anchor
    if not isinstance(d, date):
        return {}
    return {d: amount}


def ctr(impressions, clicks):
    try:
        imp = int(impressions or 0)
        return round(100.0 * int(clicks or 0) / imp, 2) if imp > 0 else 0.0
    except (TypeError, ValueError):
        return 0.0
