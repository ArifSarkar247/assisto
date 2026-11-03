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
    SPONSORED card is booked for that user (a sponsor always wins the slot);
  * homeorder (owner 2 Nov): a card whose in-app route belongs to a feature
    flag that is OFF for this user is hidden (preview-only = off, so the
    owner's home matches normal users');
  * homeorder: a SPONSORED / ADMOB card is NEVER placed right next to the SOS
    or Blood donor card — it moves to the nearest allowed slot, or is dropped
    when no slot is allowed ([separate_ads]). The app applies the same rule
    after its own filtering (home_suggestions.dart `separateDiscoverAds`).

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

# homeorder (owner 2 Nov): the route the SOS Discover card opens. ONE constant
# so the switch to the Emergency hub (agent/emhub, route `emergency_hub`) is a
# one-line change here + kDiscoverSosRoute in the app.
SOS_ROUTE = "emergency_hub"   # owner 2 Nov: SOS opens the Emergency hub
BLOOD_ROUTE = "blood_panel"
# Cards an ad may never sit next to (SOS — old screen and new hub — and Blood donor).
PROTECTED_ROUTES = frozenset({"emergency", "emergency_hub", "voice_sos", BLOOD_ROUTE,
                              "blood_donor"})   # ownerfix: old-link alias
AD_TYPES = (SPONSORED, ADMOB)
SEGMENTS = ("free", "premium", "business")

# In-app route keys the app can open (mirror of ChatNav.routes in
# app/lib/widgets/chatnav.dart — a test asserts they stay in lock-step).
ROUTE_KEYS = (
    "account_standing",   # adminsafe: Account status + appeal (ChatNav mirror)
    "emergency_hub",   # emhub: the Emergency hub (ChatNav mirror in lock-step)
    "family_alerts",   # family100 route (keeps the ChatNav mirror in lock-step)
    "day_planner",     # p2plan: AI daily planner (flag ai_daily_planner)
    "task_manager",    # p2plan: Task manager (push "tasks" target)
    "my_dues",         # tagada2: the customer's My Dues (push tap target)
    "kids_watch", "school_mode",   # kidswatch: parent hub + the child's side
    "missing_alert",   # missing: Missing person alert (flag missing_alert)
    "blood_panel",     # blood: Blood donor panel (flag blood_donors)
    "blood_donor",     # ownerfix: old links -> the same one panel
    "train_tracker", "dest_alarm",  # train: tracker + destination alarm
    "kid_audio",       # kidaudio: Child emergency audio (flag child_emergency_audio)
    "books",           # ledger: Business Accounting books (flag accounting_v2)
    "acct",            # acctui: accounting home (flag accounting_v2)
    "market",          # amarket: Assisto Market (flag assisto_market)
    "money", "documents", "family", "reminders", "vehicles", "vehicle_tracking",
    "car_mode", "emergency", "plans", "scam", "safety", "voice_sos", "crm",
    "medicine_db", "health_tips", "birthdays", "meetings", "dictionary",
    "ride_food", "fall_detect", "lost_stolen", "my_lost_phone", "recovery",
    "phone_safety", "security", "used_phone_check", "sell_phone", "shop_box",
    "analytics", "name_about", "ramadan", "exam", "unseen", "photo_enhance",
    "circle", "circle_add", "messages", "channels", "communities", "notifications", "groups", "status", "legal",
    "subscriptions", "finance", "payment_ladder", "notes", "memory", "nominee",
    "contacts", "agent_studio", "jobs", "cv", "resume", "inbox", "guide",
    "nearby", "watch_feed", "watched_phones", "business", "bargain_rules", "business_plans",
    "journey", "journey_watch", "journey_settings", "journey_requests", "referral", "circle_privacy", "circle_calls", "action_center",
    "disaster", "offline", "budget", "tax", "wrapped", "money_voice", "ai_chat",
    "voice_assistant", "voice_settings", "photo_studio",
    "feedback",  # f1-founders
    "offers",  # p2-money: brand offers feed
    "watchman",  # cctv1: Home & shop watchman
    "watchman_inbox",  # cctvx: alerts passed to me / clips shared with me
    "watchman_sos_live",  # cctvarm: an SOS at home opened the home camera for me
    "booking", "my_bookings",  # booking-bot (flag booking_bot)
    "remittance",  # budget-remittance (flag budget_remittance)
    "probashi_plan",  # probashi-plan (flag probashi_plan)
    "retention_auto", "retention_inbox",  # retention1: Retention automation
    "marketing_engine",  # mktengine: Marketing Engine v1
    "khata", "sales_agent", "prepaid_meter", "contract",  # home_v2 shortcut routes
    "agent_core", "agent_approvals",  # agent-core WP-APP (flag agent_core)
)

# Icon names the app knows how to draw (app/lib/widgets/home_suggestions.dart
# `_kIcons`). Anything else falls back to a generic icon in the app.
ICONS = (
    "auto_fix_high", "phonelink_lock", "near_me", "diversity_3", "verified",
    "directions_car", "security", "workspace_premium", "storefront",
    "account_tree", "campaign", "star", "local_offer", "shopping_bag",
    "favorite", "school", "health", "family", "money", "lightbulb",
    "emergency", "train", "bloodtype",   # homeorder: SOS / Train / Blood donor
    "alarm",                             # ownerfix: Destination Alarm
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


def is_protected(card):
    return card.get("type") not in AD_TYPES and \
        (card.get("route") or "") in PROTECTED_ROUTES


def separate_ads(cards):
    """Owner rule (2 Nov): no SPONSORED / ADMOB card directly next to an SOS
    or Blood donor card. Non-ad cards keep their order; each ad keeps its gap
    when allowed, else moves to the nearest allowed gap (later first), else is
    dropped (never shown next to SOS). Returns a new list."""
    plain = [c for c in cards if c.get("type") not in AD_TYPES]
    if len(plain) == len(cards):
        return list(cards)
    n = len(plain)

    def ok(g):   # gap g sits between plain[g-1] and plain[g]
        return not ((g > 0 and is_protected(plain[g - 1])) or
                    (g < n and is_protected(plain[g])))

    slots = {}   # gap -> ads placed there, in order
    seen_plain = 0
    for c in cards:
        if c.get("type") not in AD_TYPES:
            seen_plain += 1
            continue
        g = seen_plain
        for d in range(n + 1):
            pick = next((x for x in (g + d, g - d) if 0 <= x <= n and ok(x)), None)
            if pick is not None:
                slots.setdefault(pick, []).append(c)
                break
    out = []
    for g in range(n + 1):
        out.extend(slots.get(g, []))
        if g < n:
            out.append(plain[g])
    return out


def visible_cards(cards, segment, build, now, hero_ad=False, route_on=None):
    """Filter + order `cards` (plain dicts) for one user. Returns a new list.

    `segment` ∈ free / premium / business (unknown -> free). `build` = the app
    build number the client reported, or None. `now` = aware datetime.
    `route_on(route) -> bool` (optional): False hides a card whose in-app
    route's feature flag is off for this user."""
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
        if route_on is not None and c.get("route") and not route_on(c["route"]):
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
    return separate_ads(out)


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
