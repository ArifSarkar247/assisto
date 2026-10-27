"""feature-flags: ONE server switch per user-facing feature (owner rule 26 Oct,
owner_actions/DEFINITION_OF_DONE_BN.md): a feature is visible only when all
9 Definition-of-Done checks pass; until then it sits behind its flag — and the
Google Play build can hide it separately, so the Play production application
(8 Nov) is never blocked by a half-done feature.

Registry (here) -> DB rows (core.models.FeatureFlag, edited in Owner Admin →
Features) -> GET /api/v1/features (per user + flavour) -> the app's ONE
central check (app/lib/feature_flags.dart) used by the drawer, ChatNav
routes, deep links / pushes, home quick buttons and every other entry point.

Resolution for one feature, one request:
  * on  = enabled_all AND (enabled_play when the request is the Play build)
          AND the user falls inside rollout_pct (stable hash of key:user id);
  * an owner (superuser) / staff account or a user id on the feature's
    allow-list ALWAYS sees it ("preview") — so the owner can test a hidden
    feature on a real phone, Play build included.
A missing DB row = the registry default below. Registry defaults keep TODAY's
behaviour: everything visible today stays visible on deploy; features that
are not visible today (code-gated showpieces, upcoming big-week features)
start hidden.

The Dart mirror (app/lib/feature_registry.dart) carries the same keys, routes
and defaults for a first run with no network; core.tests_feature_flags checks
both files stay in lock-step.

Medical features are NOT here: the Play build hides them at compile time
(app/lib/feature_gates.dart kMedicalFeaturesAllowed), unchanged.
"""
import hashlib
import json
import time

# (key, section, label EN, label BN, default visible, app routes it owns)
REGISTRY = (
    ('my_circle', 'circle', 'My Circle', 'আমার সার্কেল', True, ('circle', 'circle_add', 'messages', 'groups', 'status', 'circle_privacy')),
    ('calls', 'circle', 'Circle calls', 'সার্কেল কল', True, ('circle_calls',)),
    ('reminders', 'reminders_memory', 'Reminders', 'রিমাইন্ডার', True, ('reminders',)),
    ('birthdays', 'reminders_memory', 'Birthdays & memorable days', 'জন্মদিন ও স্মরণীয় দিন', True, ('birthdays',)),
    ('meetings', 'reminders_memory', 'Meetings & appointments', 'মিটিং ও অ্যাপয়েন্টমেন্ট', True, ('meetings',)),
    ('notes', 'reminders_memory', 'Notes/Tasks', 'নোট/কাজ', True, ('notes',)),
    ('memory', 'reminders_memory', 'AI knows', 'AI জানে', True, ('memory',)),
    ('saved_items', 'reminders_memory', 'Saved', 'সংরক্ষিত', True, ()),
    ('money', 'my_account', 'Account & Finance', 'হিসাব ও অর্থ', True, ('money',)),
    ('budget', 'my_account', 'Budget', 'বাজেট', True, ('budget',)),
    ('budget_remittance', 'my_account', 'Budget and Remittance (money from abroad)', 'বাজেট ও রেমিট্যান্স (বিদেশ থেকে আসা টাকা)', False, ('remittance',)),
    ('tax_zakat', 'my_account', 'Tax & Zakat', 'কর ও যাকাত', True, ('tax',)),
    ('money_wrapped', 'my_account', 'Money Wrapped', 'টাকার রিক্যাপ', True, ('wrapped',)),
    ('money_voice', 'my_account', 'Money by voice', 'মুখে বলে খরচ লেখা', True, ('money_voice',)),
    ('subscriptions', 'my_account', 'Subscriptions', 'সাবস্ক্রিপশন', True, ('subscriptions',)),
    ('finance_tools', 'my_account', 'Finance tools', 'ফিন্যান্স টুল', True, ('finance',)),
    ('payment_ladder', 'my_account', 'Payment Ladder', 'পেমেন্ট ল্যাডার', True, ('payment_ladder',)),
    ('mess_accounting', 'my_account', 'Mess & bachelor accounting', 'মেস ও ব্যাচেলর হিসাব', True, ()),
    ('expense_split', 'my_account', 'Split expenses', 'খরচ ভাগাভাগি', True, ()),
    ('samity', 'my_account', 'Samity', 'সমিতি', True, ()),
    ('house_rent', 'my_account', 'House rent', 'বাড়ি ভাড়া', True, ()),
    ('prepaid_meter', 'my_account', 'Prepaid meters', 'প্রিপেইড মিটার', True, ('prepaid_meter',)),
    ('domestic_staff', 'my_account', 'Household staff & driver', 'গৃহকর্মী ও ড্রাইভার', True, ()),
    ('savings_challenge', 'my_account', 'Savings challenge', 'সঞ্চয় চ্যালেঞ্জ', True, ()),
    ('spending_advice', 'my_account', 'Spending insights (rule-based)', 'খরচের পর্যবেক্ষণ (নিয়মভিত্তিক)', True, ()),
    ('price_radar', 'my_account', 'Market price radar', 'বাজার দাম রাডার', True, ()),
    ('family', 'family_safety', 'Family', 'ফ্যামিলি', True, ('family',)),
    ('nominee', 'family_safety', 'Nominee access', 'নমিনি অ্যাক্সেস', True, ('nominee',)),
    ('safe_journey', 'family_safety', 'Safe Journey', 'নিরাপদ যাত্রা', True, ('journey', 'safety')),
    ('emergency', 'family_safety', 'Emergency', 'ইমার্জেন্সি', True, ('emergency', 'voice_sos')),
    ('scam_check', 'family_safety', 'Scam protection', 'প্রতারণা সুরক্ষা', True, ('scam',)),
    ('fall_detect', 'family_safety', 'Accident / fall detection', 'দুর্ঘটনা/পতন শনাক্তকরণ', False, ('fall_detect',)),
    ('anti_theft', 'family_safety', 'Anti-theft (lost phone, safety check-up, ownership, sell, used-phone check)', 'চুরি-রোধ (হারানো ফোন, নিরাপত্তা চেক-আপ, মালিকানা, বিক্রি, পুরনো ফোন যাচাই)', True, ('lost_stolen', 'my_lost_phone', 'recovery', 'phone_safety', 'security', 'sell_phone', 'used_phone_check')),
    ('cctv_watchman', 'family_safety', 'CCTV watchman (Shop Box)', 'সিসিটিভি ওয়াচম্যান (শপ বক্স)', True, ('shop_box',)),
    # launch (owner 27 Oct): CCTV + vehicle tracking are LAUNCH features, not
    # previews — visible by default once their E2E passed (tests_e2e_cctv).
    ('home_watchman', 'family_safety', 'Home & shop watchman (CCTV AI)', 'বাড়ি ও দোকানের পাহারাদার (CCTV AI)', True, ('watchman',)),
    ('disaster_alerts', 'family_safety', 'Disaster alerts', 'দুর্যোগ সতর্কতা', True, ('disaster',)),
    ('blood_donor', 'family_safety', 'Blood donors', 'রক্তদাতা নেটওয়ার্ক', True, ()),
    ('kid_school', 'family_safety', 'School corner', 'স্কুল কর্নার', True, ()),
    ('contacts', 'contacts', 'Contacts', 'কন্টাক্টস', True, ('contacts',)),
    ('voice_assistant', 'daily_life', 'Assisto Voice', 'অ্যাসিস্টো ভয়েস', True, ('voice_assistant', 'voice_settings')),
    ('documents', 'daily_life', 'Documents', 'ডকুমেন্টস', True, ('documents',)),
    ('service_guide', 'daily_life', 'Service guide', 'সেবা গাইড', True, ('guide',)),
    ('nearby', 'daily_life', 'Nearby', 'কাছেপিঠে', True, ('nearby',)),
    # unseen-rename (owner 27 Oct): the Today / Jobs / Expats / Students /
    # Farmers / Government-services hub is "Daily info and services". Its
    # flag was `unseen_world` until this rename; that key now belongs to the
    # REAL Unseen World travel feature below (default OFF). Migration
    # 0099_daily_info_flag carries the owner's old row over; LEGACY_KEYS
    # keeps old apps (which still ask for `unseen_world`) showing the hub.
    ('daily_info', 'daily_life', 'Daily info and services', 'আজকের তথ্য ও সেবা', True, ()),
    ('unseen_bangladesh', 'daily_life', 'Unseen Bangladesh', 'অদেখা বাংলাদেশ', True, ('unseen',)),
    ('dictionary', 'daily_life', 'Dictionary', 'অভিধান', True, ('dictionary',)),
    ('ramadan', 'daily_life', 'Ramadan mode', 'রমজান মোড', True, ('ramadan',)),
    ('watch_feed', 'daily_life', 'Watch feed', 'ওয়াচ ফিড', True, ('watch_feed',)),
    ('exam_result', 'daily_life', 'Exam result', 'পরীক্ষার ফলাফল', True, ('exam',)),
    ('photo_studio', 'daily_life', 'Photo Studio', 'ফটো স্টুডিও', True, ('photo_studio', 'photo_enhance')),
    ('ride_food', 'daily_life', 'Ride & food', 'রাইড ও খাবার', True, ('ride_food',)),
    ('vehicles', 'daily_life', 'My Vehicles', 'আমার গাড়ি', True, ('vehicles',)),
    ('vehicle_tracking', 'daily_life', 'Live tracking', 'লাইভ ট্র্যাকিং', True, ('vehicle_tracking', 'car_mode')),
    ('student_corner', 'daily_life', 'Student corner', 'স্টুডেন্ট কর্নার', True, ()),
    ('wedding_events', 'daily_life', 'Wedding & events', 'বিয়ে ও অনুষ্ঠান', True, ()),
    ('qurbani', 'daily_life', 'Qurbani & Eid planner', 'কোরবানি ও ঈদ পরিকল্পনা', True, ()),
    ('probashi', 'daily_life', 'Probashi corner', 'প্রবাসী কর্নার', True, ()),
    ('farmer_mode', 'daily_life', 'Farmer mode', 'কৃষক মোড', True, ()),
    ('wellness', 'daily_life', 'Water, sleep & diet', 'পানি, ঘুম ও খাবার', True, ()),
    ('fitness', 'daily_life', 'Fitness partner', 'ফিটনেস সঙ্গী', True, ()),
    ('smartwatch', 'daily_life', 'Smartwatch & fitness', 'স্মার্টওয়াচ ও ফিটনেস', True, ()),
    ('daily_challenges', 'daily_life', 'Daily challenge', 'দৈনিক চ্যালেঞ্জ', True, ()),
    ('contract_analyzer', 'daily_life', 'Contract analyzer', 'চুক্তি বিশ্লেষক', True, ('contract',)),
    ('language_partner', 'daily_life', 'Language partner', 'ভাষা শেখার সঙ্গী', True, ()),
    ('daily_brief', 'daily_life', 'Daily brief', 'দৈনিক ব্রিফ', True, ()),
    ('doc_scanner', 'daily_life', 'Document scanner', 'ডকুমেন্ট স্ক্যানার', True, ()),
    ('transcription', 'daily_life', 'Calls & voice notes', 'কল ও ভয়েস নোট', True, ()),
    ('travel_planner', 'daily_life', 'Travel planner', 'ভ্রমণ পরিকল্পনা', True, ()),
    ('voice_mood', 'daily_life', 'Mood & energy journal', 'মন ও প্রাণশক্তির ডায়েরি', True, ()),
    ('proactive_ai', 'daily_life', 'Proactive helper', 'প্রোঅ্যাকটিভ সহায়তা', True, ()),
    ('area_community', 'daily_life', 'Area community', 'এলাকার কমিউনিটি', False, ()),
    ('agent_studio', 'work', 'Agent Studio', 'এজেন্ট স্টুডিও', False, ('agent_studio',)),
    # agent-core (owner final order 27 Oct, PART 2): the server-side Assisto
    # agent (goal -> plan -> act -> observe, typed tools, one-tap approvals,
    # audit). OFF until the live eval meets the bar (AGENT_CORE_DESIGN_BN.md
    # §15). WP-APP: the hidden agent screen + approval inbox (preview for
    # owner / staff / allow-listed testers only while OFF).
    ('agent_core', 'work', 'Assisto Agent (goals, plans, approvals)', 'Assisto এজেন্ট (লক্ষ্য, পরিকল্পনা, অনুমোদন)', False, ('agent_core', 'agent_approvals')),
    ('task_manager', 'work', 'Task Manager', 'টাস্ক ম্যানেজার', True, ()),
    ('cost_estimator', 'work', 'Cost & time estimator', 'খরচ ও সময় হিসাব', True, ()),
    ('mock_interview', 'work', 'Mock interview', 'মক ইন্টারভিউ', True, ()),
    ('quick_tools', 'work', 'Quick tools', 'কুইক টুলস', True, ()),
    ('blog_writer', 'work', 'Blog & script writing', 'ব্লগ ও স্ক্রিপ্ট লেখা', True, ()),
    ('jobs', 'work', 'Job hunter', 'জব হান্টার', True, ('jobs',)),
    ('cv_builder', 'work', 'CV Builder', 'সিভি বিল্ডার', True, ('cv', 'resume')),
    ('ai_inbox', 'work', 'AI Inbox', 'AI ইনবক্স', True, ('inbox',)),
    ('pa_secretary', 'work', 'PA Secretary', 'পিএ সেক্রেটারি', True, ()),
    ('business', 'business', 'Business', 'বিজনেস', True, ('business', 'bargain_rules', 'business_plans', 'khata')),
    ('crm', 'business', 'CRM', 'CRM', True, ('crm',)),
    ('business_agent', 'business', 'AI sales agent', 'AI সেলস এজেন্ট', True, ('sales_agent',)),
    ('booking_bot', 'business', 'Booking bot (appointments)', 'বুকিং বট (অ্যাপয়েন্টমেন্ট)', False, ('booking', 'my_bookings')),
    ('offers', 'business', 'Offers & brands', 'অফার ও ব্র্যান্ড', True, ('offers',)),
    ('referral', 'business', 'Referral points', 'রেফারেল পয়েন্ট', True, ('referral',)),
    ('retention_auto', 'business', 'Retention automation (thank-you, we-miss-you, due, back-in-stock, birthday)', 'রিটেনশন অটোমেশন (ধন্যবাদ, ফিরে আসুন, বাকি, স্টকে এসেছে, জন্মদিন)', False, ('retention_auto', 'retention_inbox')),
    # plans-v2 (owner 27 Oct): the Free / Premium / Business matrix, CRM
    # limits and the 7-day Business trial (core.entitlements_service). A
    # POLICY switch: OFF = every gate behaves exactly as before. Owns no route.
    ('plans_v2', 'business', 'Plans v2 (Free / Premium / Business limits, 7-day Business trial)', 'প্ল্যান v2 (ফ্রি / প্রিমিয়াম / বিজনেস সীমা, ৭ দিনের বিজনেস ট্রায়াল)', False, ()),
    # probashi-plan (owner 27 Oct): the expat family plan — payer Premium +
    # 3-4 family seats in Bangladesh, shared credit pool, family dashboard,
    # monthly report (core/probashi_plan.py). Hidden until all 9 DoD checks.
    ('probashi_plan', 'family_safety', 'Probashi family plan (expat pays, family in Bangladesh gets Premium)', 'প্রবাসী পরিবার প্ল্যান (বিদেশ থেকে পেমেন্ট, দেশের পরিবার প্রিমিয়াম পায়)', False, ('probashi_plan',)),
    ('corporate_meetings', 'upcoming', 'Corporate meetings (group video, screen share)', 'কর্পোরেট মিটিং (গ্রুপ ভিডিও, স্ক্রিন শেয়ার)', False, ()),
    ('remote_support', 'upcoming', 'Remote support', 'রিমোট সাপোর্ট', False, ()),
    ('marketing', 'upcoming', 'Marketing automation', 'মার্কেটিং অটোমেশন', False, ()),
    ('retention', 'upcoming', 'Retention automation', 'রিটেনশন অটোমেশন', False, ()),
    ('booking', 'upcoming', 'Appointment booking bot', 'অ্যাপয়েন্টমেন্ট বুকিং বট', False, ()),
    # The REAL Unseen World (owner 27 Oct): travel discovery — Bangladesh
    # divisions/districts/spots first, then countries. Not built yet; plan:
    # owner_actions/UNSEEN_WORLD_PLAN_BN.md. Hidden until all 9 DoD checks.
    ('unseen_world', 'upcoming', 'Unseen World (travel discovery)', 'অদেখা দুনিয়া (ভ্রমণ আবিষ্কার)', False, ()),
    # home_v2 (owner final home design, 26 Oct): ON = the new home (header,
    # Discover, 12 shortcuts, Ask Assisto card, bottom bar with Assisto Voice);
    # OFF = the previous home, unchanged (fallback for one week). App shell
    # switch, so it owns no route.
    ('home_v2', 'app_shell', 'New home (v2)', 'নতুন হোম (v2)', True, ()),
)

SECTIONS = (
    ("circle", "My Circle", "আমার সার্কেল"),
    ("reminders_memory", "Reminders & Memory", "রিমাইন্ডার ও মেমোরি"),
    ("my_account", "Account & Finance", "হিসাব ও অর্থ"),
    ("family_safety", "Family & Safety", "পরিবার ও নিরাপত্তা"),
    ("contacts", "Contacts", "কন্টাক্টস"),
    ("daily_life", "Daily Life", "দৈনন্দিন জীবন"),
    ("work", "Work", "কাজ"),
    ("business", "Business", "ব্যবসা"),
    ("upcoming", "Upcoming (big-week plan)", "আসছে (বড় সপ্তাহের পরিকল্পনা)"),
    ("app_shell", "App shell", "অ্যাপের কাঠামো"),
)

# The 9 Definition-of-Done checks, in the order of DEFINITION_OF_DONE_BN.md.
DOD_CHECKS = (
    ("Full real journey on two accounts (first run, empty, errors, retry, offline, slow net)",
     "দুই অ্যাকাউন্টে পুরো আসল যাত্রা (প্রথমবার, খালি, ত্রুটি, আবার চেষ্টা, ইন্টারনেট নেই, ধীর ইন্টারনেট)"),
    ("Every button really works (no placeholder, no 'coming soon')",
     "প্রতিটি বোতাম আসল কাজ করে (জায়গা-রাখা লেখা বা 'শীঘ্রই আসছে' নেই)"),
    ("Bangla + English complete, 200% font, dark mode, 48dp buttons",
     "বাংলা ও ইংরেজি সম্পূর্ণ, ২০০% ফন্ট, ডার্ক মোড, ৪৮dp বোতাম"),
    ("Runs on a 2 GB phone, every screen under 1 second",
     "২ GB ফোনে চলে, প্রতিটি স্ক্রিন ১ সেকেন্ডের কম"),
    ("Server limits, cost and abuse guards (rate limit, daily cap, credits / Profit Guard)",
     "সার্ভারে সীমা, খরচ ও অপব্যবহার-রোধ (রেট লিমিট, দৈনিক সীমা, ক্রেডিট / Profit Guard)"),
    ("Privacy, permissions and Play declarations ready",
     "গোপনীয়তা, অনুমতি ও Play-ঘোষণা তৈরি"),
    ("Automated tests + reality-audit flow pass",
     "স্বয়ংক্রিয় টেস্ট + রিয়ালিটি-অডিট ফ্লো পাস"),
    ("Short in-app guide (a new user understands in 30 seconds)",
     "ছোট অ্যাপ-ভেতরের গাইড (নতুন ব্যবহারকারী ৩০ সেকেন্ডে বোঝেন)"),
    ("Owner can test it in 10 minutes (Bangla steps in STATUS)",
     "মালিক ১০ মিনিটে পরীক্ষা করতে পারেন (STATUS-এ বাংলায় ধাপ)"),
)
N_CHECKS = len(DOD_CHECKS)
STATUSES = ("done", "in_progress", "hidden")
MAX_ALLOW = 200            # tester ids per feature
CACHE_TTL = 30             # seconds; the saving worker drops its copy at once

# truth (owner FINAL ORDER 27 Oct: "no demo or fake data anywhere, real
# licensed data sources, honest empty states, never promise what is not
# built"). A feature whose ONLY content is a data source we do not have yet is
# hidden by CODE until that source exists — independent of its DB flag, so no
# live flag is touched and it reappears by itself once the source is real.
# The owner / staff / allow-listed testers still get it as a "preview".
#   source -> zero-arg check (True = a real source is connected and served)
def _src_dictionary():
    from .logic import dictionary
    return not dictionary.is_sample()


SOURCES = {
    # licensed / open dictionary dataset loaded (logic.dictionary.load_dataset);
    # until then only ~20 hand-written sample words exist.
    "dictionary_dataset": _src_dictionary,
    # a real mail fetch path. None is built: connecting Google only flips a
    # flag, no message is ever fetched, so the inbox would only promise.
    "mail_fetch": lambda: False,
}
SOURCE_REQUIRED = {
    "dictionary": "dictionary_dataset",
    "ai_inbox": "mail_fetch",
}


def sources_ready():
    """{source: bool}. A broken check counts as 'not ready' (never shows a
    feature on an error)."""
    out = {}
    for name, fn in SOURCES.items():
        try:
            out[name] = bool(fn())
        except Exception:
            out[name] = False
    return out


def source_missing(key, ready=None):
    """True when `key` needs a data source that is not connected yet."""
    src = SOURCE_REQUIRED.get(key)
    if not src:
        return False
    ready = sources_ready() if ready is None else ready
    return not ready.get(src, False)


KEYS = tuple(r[0] for r in REGISTRY)
_BY_KEY = {r[0]: r for r in REGISTRY}
ROUTE_FEATURE = {route: r[0] for r in REGISTRY for route in r[5]}

# unseen-rename: a key whose MEANING changed. Apps built before the rename
# gate the daily info hub on `unseen_world` and do not send `fv`, so they get
# the daily_info answer under the old name. Apps that send `fv=2` (the rename
# build on) get every key with its real meaning (`unseen_world` = travel).
FEATURES_V = 2
LEGACY_KEYS = {"unseen_world": "daily_info"}   # old name -> key it meant


def is_known(key):
    return key in _BY_KEY


def meta(key):
    k, section, en, bn, on, routes = _BY_KEY[key]
    return {"key": k, "section": section, "label_en": en, "label_bn": bn,
            "default_on": on, "routes": list(routes)}


def default_row(key):
    """The registry default for a feature that has no DB row yet."""
    on = _BY_KEY[key][4]
    return {"enabled_all": on, "enabled_play": on, "rollout_pct": 100,
            "allow_user_ids": [], "dod_status": "in_progress" if on else "hidden"}


# ------------------------------------------------------------------ rows
_cache = {"at": 0.0, "rows": None}


def invalidate():
    _cache["at"], _cache["rows"] = 0.0, None


def _clean_ids(v):
    out = []
    for x in (v or []):
        try:
            i = int(x)
        except (TypeError, ValueError):
            continue
        if i > 0 and i not in out:
            out.append(i)
    return out[:MAX_ALLOW]


def rows():
    """{key: resolved row dict} for every registry key (DB row or default),
    cached per process for CACHE_TTL seconds."""
    now = time.monotonic()
    if _cache["rows"] is not None and now - _cache["at"] < CACHE_TTL:
        return _cache["rows"]
    from .models import FeatureFlag
    out = {k: default_row(k) for k in KEYS}
    try:
        for f in FeatureFlag.objects.filter(key__in=KEYS):
            out[f.key] = {"enabled_all": f.enabled_all, "enabled_play": f.enabled_play,
                          "rollout_pct": max(0, min(100, f.rollout_pct)),
                          "allow_user_ids": _clean_ids(f.allow_user_ids),
                          "dod_status": f.dod_status}
    except Exception:
        # DB trouble must never take features away: serve the defaults
        # (today's behaviour) and retry on the next request.
        return out
    _cache["at"], _cache["rows"] = now, out
    return out


def ensure_seeded():
    """Create the missing rows with their registry defaults + the proposed
    DoD audit (core.feature_audit). Never changes an existing row."""
    from .models import FeatureFlag
    from . import feature_audit as FA
    have = set(FeatureFlag.objects.values_list("key", flat=True))
    new = []
    for k in KEYS:
        if k in have:
            continue
        d = default_row(k)
        a = FA.AUDIT.get(k) or {}
        new.append(FeatureFlag(
            key=k, enabled_all=d["enabled_all"], enabled_play=d["enabled_play"],
            rollout_pct=100, allow_user_ids=[], dod_status=d["dod_status"],
            dod_checks=FA.checks_bools(k),
            note=a.get("note_en", ""), note_bn=a.get("note_bn", "")))
    if new:
        FeatureFlag.objects.bulk_create(new, ignore_conflicts=True)
        invalidate()
    return len(new)


# ------------------------------------------------------------ resolution
def in_rollout(key, user_id, pct):
    if pct >= 100:
        return True
    if pct <= 0 or not user_id:
        return False
    h = hashlib.sha256(("%s:%s" % (key, user_id)).encode()).hexdigest()
    return int(h[:8], 16) % 100 < pct


def is_privileged(user):
    return bool(getattr(user, "is_authenticated", False) and user.is_active
                and (user.is_superuser or user.is_staff))


def resolve(user=None, play=False):
    """(features {key: bool}, preview [keys visible ONLY because the user is
    the owner / staff / an allow-listed tester])."""
    authed = getattr(user, "is_authenticated", False)
    uid = getattr(user, "pk", None) if authed else None
    priv = is_privileged(user)
    feats, preview = {}, []
    ready = sources_ready()
    for k, r in rows().items():
        on = (r["enabled_all"] and (r["enabled_play"] or not play)
              and in_rollout(k, uid, r["rollout_pct"])
              and not source_missing(k, ready))   # truth: no source, no entry
        if not on and (priv or (uid and uid in r["allow_user_ids"])):
            on = True
            preview.append(k)
        feats[k] = on
    # probashi-plan: a live Probashi family (payer or seat member) gets budget
    # & remittance turned on (owner 27 Oct). Only when the plan flag is on.
    if feats.get("probashi_plan") and not feats.get("budget_remittance") and uid:
        try:
            from . import probashi_plan as PB
            if PB.in_live_family(user):
                feats["budget_remittance"] = True
        except Exception:
            pass
    return feats, preview


def is_on(key, user=None, play=False):
    """Server-side check for other code (unknown key -> True: a typo never
    hides a feature)."""
    if key not in _BY_KEY:
        return True
    return resolve(user, play)[0][key]


def payload(user=None, play=False, fv=1):
    feats, preview = resolve(user, play)
    if fv < FEATURES_V:
        preview = [k for k in preview if k not in LEGACY_KEYS]
        for old, new in LEGACY_KEYS.items():
            feats[old] = feats[new]
            if new in preview:
                preview.append(old)
    return {"v": 1, "flavour": "play" if play else "apk",
            "features": feats, "preview": sorted(preview)}


def etag(body):
    raw = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    return '"ff-%s"' % hashlib.sha256(raw).hexdigest()[:20]


# ------------------------------------------------------------ owner edits
def status_pct(checks):
    c = [bool(x) for x in (checks or [])][:N_CHECKS]
    return round(100 * sum(c) / N_CHECKS)


def validate(form):
    """Owner form -> (clean dict, problems list). Pure."""
    problems = []
    try:
        pct = int(str(form.get("rollout_pct", "100")).strip())
    except (TypeError, ValueError):
        pct = -1
    if not 0 <= pct <= 100:
        problems.append("rollout_pct")
    ids = []
    raw = str(form.get("allow_user_ids", "") or "")
    for part in raw.replace("\n", ",").replace(" ", ",").split(","):
        part = part.strip()
        if not part:
            continue
        if not part.isdigit() or int(part) <= 0:
            problems.append("allow_user_ids")
            break
        if int(part) not in ids:
            ids.append(int(part))
    if len(ids) > MAX_ALLOW:
        problems.append("allow_user_ids")
    checks = [bool(form.get("dod_%d" % i)) for i in range(N_CHECKS)]
    status = form.get("dod_status") or "in_progress"
    if status not in STATUSES:
        problems.append("dod_status")
    elif status == "done" and not all(checks):
        # owner rule: never DONE before all 9 checks pass
        problems.append("dod_not_complete")
    clean = {"enabled_all": bool(form.get("enabled_all")),
             "enabled_play": bool(form.get("enabled_play")),
             "rollout_pct": max(0, min(100, pct)), "allow_user_ids": ids,
             "dod_status": status, "dod_checks": checks,
             "note": str(form.get("note", "") or "")[:2000],
             "note_bn": str(form.get("note_bn", "") or "")[:2000]}
    return clean, problems
