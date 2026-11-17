"""
ad_control.py — the ONE ad PLACEMENT REGISTRY + Owner Admin ad control
(adcontrol, OWNER FINAL ORDER ADS 10 Nov 03:45, parts A–F). PURE: no Django.

Every place in the app that may ever show an AdMob ad is ONE row here:
  key        the id the app uses (AdBannerSlot(screen: key), AdExitPlacement
             id, AdRewardGate key ...). Mirrored 1:1 in
             app/lib/ads/ad_control.dart (CI: core.tests_adcontrol parses it).
  group      the feature group Owner Admin groups rows by.
  allowed    the ad types that FIT this spot (the owner picks one of them).
  on, type   the DEFAULT (owner order part C = OFF list, part D = ON list).
  safety     an emergency / safety / trust screen (part C). Default OFF; Owner
             Admin shows "this is an emergency or safety screen, are you
             sure?" before it can be turned on; the app never shows it unless
             the server EXPLICITLY says on (fetch failure -> off).

The owner's stored choices live in PricingConfig.data["ad_control"]
({"placements": {key: {"on": bool, "type": str}}, "caps": {...}}); normalize()
drops anything unknown, so the server can only switch REGISTERED placements.
AdMob is for FREE users only — Premium, Plus, Business ... never (part A);
owner Discover / brand cards (sponsors) are not AdMob and stay for everyone.
"""

TYPES = ("banner", "native", "interstitial", "rewarded", "app_open")
INLINE = ("banner", "native")          # a bottom banner or an in-page card
LIST = ("native",)                     # a card between list rows
MOMENT = ("interstitial",)             # a full-screen ad at a finished task
REWARD = ("rewarded",)                 # user-chosen "watch an ad to unlock"
APP_OPEN = ("app_open",)

# group id -> (Bangla, English) — Owner Admin section titles, in this order
GROUPS = (
    ("home", "হোম, ডিসকভার ও সব সেবা", "Home, Discover & All services"),
    ("circle", "আমার সার্কেল ও কল", "My Circle & calls"),
    ("ai", "AI চ্যাট", "AI chat"),
    ("photo", "ফটো স্টুডিও", "Photo Studio"),
    ("lp", "ল্যাঙ্গুয়েজ পার্টনার", "Language Partner"),
    ("exam", "পরীক্ষা ও ছাত্র কর্নার", "Exams & Student corner"),
    ("finance", "হিসাব ও অর্থ", "Account & Finance"),
    ("mess", "মেস", "Mess"),
    ("notes", "নোট, কাজ ও রিমাইন্ডার", "Notes, tasks & reminders"),
    ("city", "সিটি সার্ভিস ও কাছাকাছি", "City Service & Nearby"),
    ("train", "ট্রেন ট্র্যাকার", "Train tracker"),
    ("security", "নিরাপত্তা ফিচার", "Security features"),
    ("offers", "অফার, কুপন ও মার্কেট", "Offers, coupons & market"),
    ("work", "কাজ, সিভি ও টুলস", "Work, CV & tools"),
    ("safety", "জরুরি, নিরাপত্তা ও আস্থা (ডিফল্ট বন্ধ)", "Emergency, safety & trust (default OFF)"),
)
GROUP_IDS = tuple(g[0] for g in GROUPS)


def _p(key, group, allowed, on, typ, bn, en, safety=False, rule=""):
    return {"key": key, "group": group, "allowed": tuple(allowed), "on": bool(on),
            "type": typ, "bn": bn, "en": en, "safety": bool(safety), "rule": rule}


# NOTE: every key is 2-40 chars [a-z0-9_] (the /ads/event placement rule).
PLACEMENTS = (
    # ---------------- D: default ON
    _p("home", "home", LIST, True, "native", "হোম — নেটিভ কার্ড (আগের মতো)", "Home native card (existing)"),
    _p("discover_native", "home", LIST, True, "native", "ডিসকভার — তালিকায় AdMob নেটিভ", "Discover: AdMob native in the list",
       rule="owner Discover / brand cards stay for everyone"),
    _p("app_open", "home", APP_OPEN, True, "app_open", "অ্যাপ খোলার বিজ্ঞাপন", "App open ad",
       rule="only if preloaded; never delays start; never first launch / after login / after a notification"),
    _p("all_services", "home", INLINE, True, "native", "সব সেবা — নেটিভ", "All Services native"),
    _p("circle_list", "circle", INLINE, True, "banner", "আমার সার্কেল চ্যাট তালিকা — ব্যানার (আগের মতো)", "My Circle chat list banner (existing)"),
    _p("after_call_review", "circle", INLINE, True, "native", "কল শেষের রিভিউ কার্ড — নেটিভ", "After-call review card native",
       rule="never after SOS, emergency or Care Call calls, calls under 10 s or missed calls"),
    _p("ai_chat_unlock", "ai", REWARD, True, "rewarded", "AI চ্যাট — বিজ্ঞাপন দেখে উত্তর খুলুন", "AI chat: rewarded to unlock answers",
       rule="ads per answer = dynamic (aimoney); the open chat itself never carries an ad"),
    # ai-reply-core (owner 17 Nov): a free user watches a rewarded ad for AI
    # reply credits (the same SSV ticket + credit formula as ai_chat_unlock).
    # Not a safety spot: never shown inside SOS, calls or the open chat.
    _p("ai_reply_unlock", "ai", REWARD, True, "rewarded", "AI উত্তর — বিজ্ঞাপন দেখে উত্তর খুলুন", "AI reply: rewarded to unlock replies",
       rule="opened from the AI reply sheet / notification state only; never in an open chat, SOS or a call"),
    _p("photo_studio", "photo", REWARD, True, "rewarded", "ফটো স্টুডিও — বিজ্ঞাপন দেখে খুলুন", "Photo Studio rewarded unlock"),
    _p("photo_after_save", "photo", MOMENT, True, "interstitial", "ফটো সেভের পর — পূর্ণ পর্দা", "Photo Studio interstitial after save"),
    _p("photo_gallery", "photo", INLINE, True, "banner", "ফটো স্টুডিও শুরুর পাতা — ব্যানার", "Photo Studio landing banner"),
    _p("lp_home", "lp", INLINE, True, "banner", "ল্যাঙ্গুয়েজ পার্টনার — ব্যানার", "Language Partner banner"),
    _p("lp_hub", "lp", INLINE, True, "banner", "ল্যাঙ্গুয়েজ পার্টনার IELTS হাব — ব্যানার", "Language Partner IELTS hub banner"),
    _p("lp_life", "lp", INLINE, True, "banner", "ল্যাঙ্গুয়েজ পার্টনার জীবনের পরিস্থিতি তালিকা — ব্যানার", "Language Partner life scenarios list banner"),
    _p("lp_vocab", "lp", INLINE, True, "banner", "ল্যাঙ্গুয়েজ পার্টনার শব্দভান্ডার — ব্যানার", "Language Partner vocabulary banner"),
    _p("lesson_after_finish", "lp", MOMENT, True, "interstitial", "পাঠ শেষে — পূর্ণ পর্দা", "Language Partner interstitial at lesson end"),
    _p("lp_unlock", "lp", REWARD, True, "rewarded", "ল্যাঙ্গুয়েজ পার্টনার — বিজ্ঞাপন দেখে খুলুন", "Language Partner rewarded unlock"),
    _p("exam_after_submit", "exam", MOMENT, True, "interstitial", "পরীক্ষা জমার পর, ফলাফলের আগে — একটি পূর্ণ পর্দা", "Exams: one interstitial after Submit, before the result",
       rule="fired once by the result opening after a submitted test (AdExit.transition); never during the timed test, listening audio or speaking recording, never on certificates"),
    _p("exam", "exam", INLINE, True, "banner", "পরীক্ষার ফলাফল পাতা — ব্যানার", "Exam result page banner"),
    _p("student_after_practice", "exam", MOMENT, True, "interstitial", "ছাত্র কর্নার অনুশীলনের পর", "Student corner after practice"),
    _p("finance_home", "finance", INLINE, True, "native", "হিসাব ও অর্থ মূল পাতা — নেটিভ কার্ড", "Account & Finance main page native card"),
    _p("finance_list", "finance", LIST, True, "native", "লেনদেনের তালিকা — প্রতি ১৫–২০ সারিতে নেটিভ", "Transaction list native every 15-20 rows"),
    _p("finance_reports", "finance", INLINE, True, "native", "রিপোর্ট — নিচে নেটিভ", "Reports native at the bottom"),
    _p("finance_after_export", "finance", MOMENT, True, "interstitial", "PDF রপ্তানি বা শেয়ারের পর — পূর্ণ পর্দা", "Interstitial after PDF export or share"),
    _p("finance_month_report", "finance", MOMENT, True, "interstitial", "মাস শেষের পূর্ণ রিপোর্ট — পূর্ণ পর্দা", "Month-end full report interstitial"),
    _p("mess_home", "mess", INLINE, True, "banner", "মেস — ব্যানার", "Mess banner"),
    _p("mess_list", "mess", LIST, True, "native", "মেস তালিকা — নেটিভ", "Mess native in lists"),
    _p("mess_month_report", "mess", MOMENT, True, "interstitial", "মেসের মাস শেষের রিপোর্ট — পূর্ণ পর্দা", "Mess month-end report interstitial"),
    _p("notes_home", "notes", INLINE, True, "banner", "নোট ও কাজ — ব্যানার", "Notes & tasks banner"),
    _p("notes_list", "notes", LIST, True, "native", "নোট ও কাজের তালিকা — নেটিভ", "Notes & tasks native in lists"),
    _p("reminders_list", "notes", INLINE, True, "banner", "রিমাইন্ডার তালিকা — ব্যানার", "Reminders list banner",
       rule="never on the alarm moment itself"),
    _p("city_search", "city", INLINE, True, "banner", "সিটি সার্ভিস খোঁজা ও ফলাফল — ব্যানার", "City Service search & results banner",
       rule="never during navigation or the destination alarm"),
    _p("city_results", "city", LIST, True, "native", "সিটি সার্ভিস ফলাফল — নেটিভ", "City Service results native"),
    _p("city_more_routes", "city", REWARD, True, "rewarded", "আরও পথ (Google) — বিজ্ঞাপন দেখে", "Rewarded for More routes (Google)",
       rule="covers the Google cost; if no ad can play the user still gets the routes"),
    _p("nearby", "city", INLINE, True, "banner", "কাছাকাছি — ব্যানার (আগের মতো)", "Nearby banner (existing)"),
    _p("train_search", "train", INLINE, True, "banner", "ট্রেন খোঁজা — ব্যানার", "Train search banner"),
    _p("train_detail", "train", INLINE, True, "banner", "ট্রেনের বিস্তারিত — ব্যানার", "Train detail banner"),
    _p("train_live_unlock", "train", REWARD, True, "rewarded", "ট্রেনের লাইভ অবস্থান — বিজ্ঞাপন দেখে, তারপর ১৫ মিনিট ফ্রি", "Rewarded to see a train's live location, then 15 min free",
       rule="no ad when a family member watches a relative's active train journey"),
    _p("security_unlock", "security", REWARD, True, "rewarded", "নিরাপত্তা ফিচার চালু — একবার বিজ্ঞাপন, তারপর চিরকাল ফ্রি", "Security feature switch-on: one rewarded ad once, then free forever",
       rule="theft protection, phone safety, scam protection, sell my phone; never blocks if no ad can play"),
    _p("security_scan", "security", REWARD, True, "rewarded", "প্রতি স্ক্যান বা নম্বর যাচাই — একটি বিজ্ঞাপন", "One rewarded ad per manual scan or number check",
       rule="never blocks: no ad available -> the check still runs"),
    _p("offers_list", "offers", LIST, True, "native", "অফার, কুপন ও মার্কেট — নেটিভ", "Offers, coupons & marketplace native"),
    _p("credits", "offers", REWARD, True, "rewarded", "ক্রেডিট পেতে বিজ্ঞাপন (ব্যবহারকারী নিজে চাইলে)", "Watch an ad for credits (user-chosen)"),
    # earlier owner-approved placements (2 Nov / 3 Nov) — still ON
    _p("saved_items", "work", INLINE, True, "banner", "সংরক্ষিত — ব্যানার", "Saved items banner"),
    _p("dictionary", "work", INLINE, True, "banner", "অভিধান — ব্যানার", "Dictionary banner"),
    _p("birthdays", "notes", INLINE, True, "banner", "জন্মদিন — ব্যানার", "Birthdays banner"),
    _p("meetings", "notes", INLINE, True, "banner", "মিটিং — ব্যানার", "Meetings banner"),
    _p("jobs", "work", INLINE, True, "banner", "চাকরি — ব্যানার", "Jobs banner"),
    _p("cv_builder", "work", INLINE, True, "banner", "সিভি বিল্ডার — ব্যানার", "CV Builder banner"),
    _p("contract", "work", INLINE, True, "banner", "চুক্তি যাচাই — ব্যানার", "Contract check banner"),
    _p("guide", "work", INLINE, True, "banner", "সেবা গাইড — ব্যানার", "Service guide banner"),
    _p("quick_tools", "work", INLINE, True, "banner", "কুইক টুলস — ব্যানার", "Quick tools banner"),
    _p("settings", "work", INLINE, True, "banner", "সেটিংস তালিকা — ব্যানার", "Settings list banner"),
    _p("scan_after_save", "work", MOMENT, True, "interstitial", "ডকুমেন্ট স্ক্যান সেভের পর", "Document scan after save"),
    _p("cv_after_download", "work", MOMENT, True, "interstitial", "সিভি ডাউনলোডের পর", "CV after download"),
    _p("interview_after_feedback", "work", MOMENT, True, "interstitial", "মক ইন্টারভিউ ফিডব্যাকের পর", "Mock interview after feedback"),
    _p("article_after_read", "home", MOMENT, True, "interstitial", "লেখা পড়া শেষে ফিরে যাওয়ার সময়", "After reading an article"),
    _p("job_after_apply", "work", MOMENT, True, "interstitial", "চাকরিতে আবেদনের পর", "Job after apply"),
    _p("plan_after_save", "work", MOMENT, True, "interstitial", "ভ্রমণ/অনুষ্ঠান পরিকল্পনা সেভের পর", "Travel / event plan after save"),
    _p("estimate_after_finish", "work", MOMENT, True, "interstitial", "খরচ হিসাব/সেবা গাইড শেষে", "Estimator / guide after finish"),
    _p("quick_tool_exit", "work", MOMENT, True, "interstitial", "কুইক টুল ব্যবহারের পর (দিনে ১ বার)", "Quick tool exit (once a day)"),
    # ---------------- C: default OFF — emergency, safety and trust screens
    _p("sos", "safety", INLINE + MOMENT, False, "banner", "SOS ও জরুরি", "SOS and Emergency", safety=True),
    _p("safe_journey_active", "safety", INLINE + MOMENT, False, "banner", "চলমান নিরাপদ যাত্রা ও এর সতর্কতা", "Active Safe Journey and its alerts", safety=True),
    _p("family_care", "safety", INLINE + MOMENT, False, "banner", "ফ্যামিলি কেয়ার (বয়স্কদের সহজ হোমসহ)", "Family Care incl. elder simple home", safety=True),
    _p("blood_donor", "safety", INLINE + MOMENT, False, "banner", "রক্তদাতা (সব পাতা)", "Blood donor (every screen)", safety=True),
    _p("care_call", "safety", INLINE + MOMENT, False, "banner", "কেয়ার কল", "Care Call", safety=True),
    _p("quran", "safety", INLINE + MOMENT, False, "banner", "কুরআন ও কুরআন শিখি", "Quran and Quran Shikhi", safety=True),
    _p("child_accounts", "safety", INLINE + MOMENT, False, "banner", "শিশুদের অ্যাকাউন্ট", "Child accounts", safety=True),
    _p("chats_calls", "safety", INLINE + MOMENT, False, "banner", "চ্যাটের ভেতরে ও কলের সময়", "Inside chats and during calls", safety=True),
    _p("reminder_alarm", "safety", INLINE + MOMENT, False, "banner", "রিমাইন্ডার অ্যালার্ম বাজার মুহূর্ত", "The reminder alarm moment", safety=True),
    _p("lost_mode", "safety", INLINE + MOMENT, False, "banner", "হারানো ফোন (লস্ট মোড)", "A lost phone in lost mode", safety=True),
    _p("payment", "safety", INLINE + MOMENT, False, "banner", "পেমেন্টের পাতা", "Payment screens", safety=True),
    _p("first_launch_login", "safety", INLINE + MOMENT + APP_OPEN, False, "banner", "প্রথমবার খোলা ও লগইন", "First launch and login", safety=True),
    _p("timed_test", "safety", INLINE + MOMENT, False, "banner", "সময় ধরা পরীক্ষা, লিসেনিং অডিও, স্পিকিং রেকর্ডিং চলাকালে", "During a timed exam, listening audio or speaking recording", safety=True),
    _p("certificates", "safety", INLINE + MOMENT, False, "banner", "সার্টিফিকেট", "Certificates", safety=True),
    _p("finance_forms", "safety", INLINE + MOMENT, False, "banner", "হিসাব/খাতায় এন্ট্রি যোগ বা সম্পাদনার ফর্ম", "Add / edit entry forms in Account & Finance or khata", safety=True),
    _p("ai_chat_open", "safety", INLINE, False, "banner", "খোলা AI চ্যাট (কথোপকথনের ভেতরে)", "Inside an open AI chat conversation", safety=True),
    _p("city_navigation", "safety", INLINE + MOMENT, False, "banner", "সিটি সার্ভিস নেভিগেশন ও গন্তব্য অ্যালার্ম", "City Service navigation and destination alarm", safety=True),
    _p("train_family_watch", "safety", INLINE + REWARD, False, "banner", "আত্মীয়ের চলমান ট্রেন যাত্রা দেখা", "A family member watching a relative's active train journey", safety=True),
)
BY_KEY = {p["key"]: p for p in PLACEMENTS}

# part C, word for word — every one of these MUST be a default-OFF safety row
OWNER_OFF_LIST = ("sos", "safe_journey_active", "family_care", "blood_donor", "care_call",
                  "quran", "child_accounts", "chats_calls", "reminder_alarm", "lost_mode",
                  "payment", "first_launch_login", "timed_test", "certificates",
                  "finance_forms")
# part D — every one of these MUST be a default-ON row of that type
OWNER_ON_LIST = {
    "home": "native", "discover_native": "native", "app_open": "app_open",
    "circle_list": "banner", "after_call_review": "native", "all_services": "native",
    "ai_chat_unlock": "rewarded", "photo_studio": "rewarded",
    "photo_after_save": "interstitial", "lp_home": "banner",
    "lesson_after_finish": "interstitial", "lp_unlock": "rewarded",
    "exam_after_submit": "interstitial", "mess_home": "banner", "mess_list": "native",
    "finance_home": "native", "finance_list": "native", "finance_reports": "native",
    "finance_after_export": "interstitial", "finance_month_report": "interstitial",
    "mess_month_report": "interstitial", "notes_home": "banner", "notes_list": "native",
    "reminders_list": "banner", "city_search": "banner", "city_results": "native",
    "city_more_routes": "rewarded", "train_search": "banner",
    "train_live_unlock": "rewarded", "security_unlock": "rewarded",
    "security_scan": "rewarded", "offers_list": "native",
}

# ------------------------------------------------------------ global caps
# owner order: interstitial max 1 per 3 min + a daily cap (both editable).
CAP_BOUNDS = {
    "interstitial_min_gap_sec": (180, 86400),
    "interstitial_daily_cap": (0, 12),
    "list_native_every": (15, 20),        # one native card per N list rows
    "train_free_minutes": (5, 120),       # after one rewarded train ad
}
CAP_DEFAULTS = {"interstitial_min_gap_sec": 180, "interstitial_daily_cap": 6,
                "list_native_every": 15, "train_free_minutes": 15}
# estimated eCPM in BDT per 1,000 impressions, used ONLY until Google's
# real per-impression values (onPaidEvent / AdMob reporting) exist — always
# labelled "estimate" in Owner Admin. Rewarded 400 = 0.40 Tk an ad (part G).
ECPM_BOUNDS = (0.0, 5000.0)
ECPM_DEFAULTS = {"banner": 20.0, "native": 60.0, "interstitial": 150.0,
                 "rewarded": 400.0, "app_open": 100.0}

# part E: blocked ad categories. The app enforces what an SDK request CAN
# (max content rating "T" = no MA / adult 18+ ads); the AdMob console must
# block the rest — owner steps in owner_actions/AD_MEDIATION_SETUP_BN.md.
BLOCKED_CATEGORIES = ("dating", "gambling", "alcohol", "adult", "politics")
MAX_AD_CONTENT_RATING = "T"


def _bool(v, d):
    return v if isinstance(v, bool) else d


def _int(v, d, lo, hi):
    try:
        n = int(v)
    except (TypeError, ValueError):
        n = d
    return max(lo, min(hi, n))


def _num(v, d, lo, hi):
    try:
        n = float(v)
    except (TypeError, ValueError):
        n = d
    return max(lo, min(hi, n))


def normalize(raw):
    """Stored ad_control -> the full effective dict: every registered
    placement with on/type (unknown keys and types dropped, a type that does
    not fit the placement -> its default), caps clamped, eCPM estimates."""
    raw = raw if isinstance(raw, dict) else {}
    stored = raw.get("placements") if isinstance(raw.get("placements"), dict) else {}
    placements = {}
    for p in PLACEMENTS:
        s = stored.get(p["key"]) if isinstance(stored.get(p["key"]), dict) else {}
        typ = s.get("type") if s.get("type") in p["allowed"] else p["type"]
        placements[p["key"]] = {"on": _bool(s.get("on"), p["on"]), "type": typ}
    caps_raw = raw.get("caps") if isinstance(raw.get("caps"), dict) else {}
    caps = {k: _int(caps_raw.get(k), CAP_DEFAULTS[k], lo, hi)
            for k, (lo, hi) in CAP_BOUNDS.items()}
    e_raw = raw.get("ecpm_estimate") if isinstance(raw.get("ecpm_estimate"), dict) else {}
    ecpm = {t: _num(e_raw.get(t), ECPM_DEFAULTS[t], *ECPM_BOUNDS) for t in TYPES}
    return {"placements": placements, "caps": caps, "ecpm_estimate": ecpm}


def defaults():
    return normalize({})


def apply_change(current, key, on=None, typ=None, confirm_safety=False):
    """(new_dict, None) or (None, reason). Turning a SAFETY placement on needs
    confirm_safety=True (Owner Admin asked "are you sure?")."""
    cur = normalize(current)
    p = BY_KEY.get(key)
    if p is None:
        return None, "unknown_placement"
    row = dict(cur["placements"][key])
    if typ is not None:
        if typ not in p["allowed"]:
            return None, "type_not_allowed"
        row["type"] = typ
    if on is not None:
        if on and not row["on"] and p["safety"] and not confirm_safety:
            return None, "needs_safety_confirm"
        row["on"] = bool(on)
    cur["placements"][key] = row
    return cur, None


def client_payload(stored, paid):
    """What /ads/config sends as `control`. A paid plan (Premium, Plus,
    Business ...) gets every placement OFF — AdMob is for Free users only."""
    eff = normalize(stored)
    out = {}
    for k, row in eff["placements"].items():
        p = BY_KEY[k]
        out[k] = {"on": bool(row["on"]) and not paid, "type": row["type"],
                  "safety": p["safety"]}
    return {"version": 1, "placements": out, "caps": dict(eff["caps"]),
            "max_ad_content_rating": MAX_AD_CONTENT_RATING,
            "blocked_categories": list(BLOCKED_CATEGORIES)}


def moments_on(stored):
    """The interstitial placements switched on with type interstitial."""
    eff = normalize(stored)["placements"]
    return [p["key"] for p in PLACEMENTS
            if "interstitial" in p["allowed"] and not p["safety"]
            and eff[p["key"]]["on"] and eff[p["key"]]["type"] == "interstitial"]


# ------------------------------------------------------------ owner report
def stat_key(placement):
    """An /ads/event placement ('banner_notes_home', 'interstitial_x',
    'native_home' ...) -> the registry key, or '' when it is not one."""
    s = str(placement or "").strip().lower()
    if s in BY_KEY:
        return s
    for pre in ("banner_", "native_", "interstitial_", "rewarded_", "app_open_", "appopen_"):
        if s.startswith(pre) and s[len(pre):] in BY_KEY:
            return s[len(pre):]
    if s in ("hero", "home_native", "native_hero"):
        return "home"
    return ""


def report(rows, stored, dates):
    """rows: [{date (ISO str), placement, fmt, currency, impressions,
    paid_events, revenue_micros}] (AdPlacementStat). dates: ISO strings,
    newest first. -> {key: {"days": [{date, impressions, income, ecpm,
    estimate}], "impressions", "income", "ecpm", "estimate", "currency"}}.
    Google's own values (onPaidEvent micros, account currency) when there
    are any for that placement and day; otherwise impressions x the owner's
    estimated eCPM (BDT) and estimate=True — never presented as real."""
    eff = normalize(stored)
    est = eff["ecpm_estimate"]
    by = {}
    for r in rows or []:
        k = stat_key(r.get("placement"))
        if not k:
            continue
        d = str(r.get("date"))
        a = by.setdefault(k, {}).setdefault(d, {"imp": 0, "paid": 0, "micros": 0, "cur": ""})
        a["imp"] += int(r.get("impressions") or 0)
        a["paid"] += int(r.get("paid_events") or 0)
        if int(r.get("revenue_micros") or 0):
            a["micros"] += int(r.get("revenue_micros") or 0)
            a["cur"] = a["cur"] or str(r.get("currency") or "")
    out = {}
    for p in PLACEMENTS:
        k = p["key"]
        typ = eff["placements"][k]["type"]
        days, tot_imp, real, est_bdt, cur = [], 0, 0.0, 0.0, ""
        for d in dates:
            a = by.get(k, {}).get(d) or {"imp": 0, "paid": 0, "micros": 0, "cur": ""}
            if a["paid"] and a["micros"]:
                inc = a["micros"] / 1e6
                ecpm = 1000.0 * inc / a["paid"]
                estimate, c = False, a["cur"]
                real += inc
                cur = cur or c
            else:
                ecpm = est[typ]
                inc = a["imp"] * ecpm / 1000.0
                estimate, c = True, "BDT"
                est_bdt += inc
            tot_imp += a["imp"]
            days.append({"date": d, "impressions": a["imp"], "income": round(inc, 2),
                         "currency": c, "ecpm": round(ecpm, 2), "estimate": estimate})
        out[k] = {"days": days, "impressions": tot_imp, "income_real": round(real, 2),
                  "currency": cur, "income_estimate_bdt": round(est_bdt, 2),
                  "ecpm_estimate_bdt": est[typ],
                  # what the list shows: Google's real eCPM when there is real
                  # income, else the owner's estimate (labelled "estimate")
                  "ecpm": round(1000.0 * (real or est_bdt) / tot_imp, 2) if tot_imp else est[typ],
                  "ecpm_is_estimate": not real}
    return out
