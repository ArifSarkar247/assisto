"""
suggestions.py — Assisto HOME DYNAMIC SUGGESTION ENGINE (the 4 prompt cards on
the home screen). Pure, deterministic, RULE-BASED (no AI key needed), no Django,
no DB, no network. Unit-testable stdlib only.

WHAT THIS IS
    The home screen shows FOUR dynamic prompt cards ("ask Assisto / do this now").
    This engine chooses and ranks those four from the user's live context — it is
    deterministic given (now, context, history), so the same inputs always yield
    the same four cards and the tests can pin exact behaviour.

HOW IT DECIDES (rule-based scoring, highest 4 win)
    Each candidate prompt has a base weight plus context boosts:
      * NEW USER            → onboarding prompts that teach the main features win.
      * time of day         → morning vs evening prompts.
      * due bills           → "pay/record the bill" prompt.
      * missed medicine     → surfaces a take/log-medicine prompt (high boost).
      * recent spending     → "see where your money went" prompt.
      * upcoming birthday   → wish / gift prompt.
      * unfinished tasks     → "finish your to-dos" prompt.
      * active modules      → business/CRM users get business prompts.
      * day / season        → Friday / Eid / Ramadan prompts.
      * language mode       → every prompt is returned in ONE language only.

    LEARN-FROM-USE: a tap/ignore history raises the score of prompt *types* the
    user taps and lowers ones they ignore. NO-REPEAT-TWO-DAYS: a prompt served
    yesterday is penalised so the four don't repeat two days running — UNLESS it
    is still strongly relevant (e.g. medicine still missed), in which case it may
    survive. DON'T-SHOW: a long-pressed/suppressed key is removed entirely.

    STRICT LANGUAGE: the caller passes `lang` ("bn"|"en"); every returned prompt
    text is in THAT language only. We never mix languages in the output.

Output: a list of up to 4 dicts {key, text, route} — `text` is a single string
in the requested language (not a bn/en pair), `route` is a screen_synonyms route.

Run self-tests:
    (cd backend && python3 -c "import core.logic.suggestions_tests_snippets as t; t.run_all()")
"""

N_CARDS = 4

# Time-of-day buckets (local hour).
PART_MORNING = "morning"
PART_AFTERNOON = "afternoon"
PART_EVENING = "evening"
PART_NIGHT = "night"


def part_of_day(now):
    h = now.hour
    if 5 <= h < 12:
        return PART_MORNING
    if 12 <= h < 17:
        return PART_AFTERNOON
    if 17 <= h < 22:
        return PART_EVENING
    return PART_NIGHT


# ---------------------------------------------------------------------------
# PROMPT CATALOGUE
# Each prompt: key, bn/en text, route, base weight, and the context predicate
# that decides whether it is a candidate + how much to boost it.
# `kind` groups onboarding vs contextual vs business vs seasonal (used by the
# no-repeat / learn-from-use logic).
# ---------------------------------------------------------------------------

def _t(bn, en):
    return {"bn": bn, "en": en}


# Catalogue entries: (key, kind, route, base_weight, text{bn,en})
_PROMPTS = {
    # ---- onboarding (new users) ----
    "onboard_reminder": ("onboarding", "reminders", 50,
        _t("একটা রিমাইন্ডার সেট করে দেখুন — \"কাল সকালে ওষুধ\"।",
           "Try setting a reminder — \"medicine tomorrow morning\".")),
    "onboard_money": ("onboarding", "money", 48,
        _t("আজকের একটা খরচ লিখে রাখুন — হিসাব নিজে থেকেই গুছিয়ে যাবে।",
           "Log one expense today — your accounts will organise themselves.")),
    "onboard_medicine": ("onboarding", "family", 46,
        _t("পরিবারের ওষুধের সময় যোগ করুন — আমি মনে করিয়ে দেবো।",
           "Add a family medicine time — I'll remind you.")),
    "onboard_circle": ("onboarding", "circle", 44,
        _t("প্রিয়জনকে Circle-এ যুক্ত করুন — নিরাপদে খোঁজ রাখুন।",
           "Add a loved one to your Circle — stay in touch safely.")),
    "onboard_scam": ("onboarding", "scam", 42,
        _t("সন্দেহজনক একটা মেসেজ দিন — এটা প্রতারণা কিনা দেখে দিই।",
           "Paste a suspicious message — I'll check if it's a scam.")),

    # ---- contextual ----
    "medicine_due": ("contextual", "family", 40,
        _t("এখন ওষুধ খাওয়ার সময় — খেয়ে নিয়ে টিক দিন।",
           "It's time for medicine — take it and tick it off.")),
    "pay_bill": ("contextual", "money", 38,
        _t("একটা বিল বাকি আছে — এখন পরিশোধ করে নিন।",
           "A bill is due — pay it now.")),
    "spending_review": ("contextual", "money", 30,
        _t("এই সপ্তাহের খরচ দেখে নিন — কোথায় গেল টাকা?",
           "Review this week's spending — where did the money go?")),
    "finish_tasks": ("contextual", "notes", 28,
        _t("অসমাপ্ত কাজগুলো শেষ করুন — তালিকা দেখুন।",
           "Finish your pending tasks — open the list.")),
    "birthday_soon": ("contextual", "birthdays", 34,
        _t("সামনে একটা জন্মদিন — শুভেচ্ছা পাঠানোর প্রস্তুতি নিন।",
           "A birthday is coming up — get ready to wish them.")),
    "todays_plan": ("contextual", "reminders", 32,
        _t("আজকের পরিকল্পনা দেখুন — কী কী আছে আজ?",
           "See today's plan — what's on for today?")),

    # ---- time-of-day ----
    "morning_briefing": ("contextual", "reminders", 36,
        _t("সুপ্রভাত! আজকের দিনটা এক নজরে দেখে নিন।",
           "Good morning! Here's your day at a glance.")),
    "evening_wrap": ("contextual", "money", 26,
        _t("দিন শেষে আজকের খরচ আর কাজ গুছিয়ে নিন।",
           "Wind down — tidy up today's spending and tasks.")),

    # ---- business / CRM ----
    "biz_orders": ("business", "business", 40,
        _t("নতুন অর্ডার দেখে কনফার্ম করুন।",
           "Review and confirm your new orders.")),
    "biz_dues": ("business", "business", 38,
        _t("বাকির খাতা দেখুন — কার কাছে কত পাওনা?",
           "Check your khata — who owes you how much?")),
    "crm_leads": ("business", "crm", 36,
        _t("আজকের লিডগুলোতে ফলোআপ করুন।",
           "Follow up on today's leads.")),

    # ---- seasonal / day ----
    "friday": ("seasonal", "reminders", 24,
        _t("শুভ শুক্রবার — পরিবারের জন্য কিছু পরিকল্পনা করুন।",
           "Happy Friday — plan something for the family.")),
    "ramadan": ("seasonal", "ramadan", 44,
        _t("রমজান মোবারক — সেহরি ও ইফতারের সময় দেখে নিন।",
           "Ramadan Mubarak — check sehri and iftar times.")),
    "eid": ("seasonal", "reminders", 46,
        _t("ঈদ মোবারক! প্রিয়জনকে শুভেচ্ছা পাঠান।",
           "Eid Mubarak! Send your loved ones greetings.")),
}

# Boost applied to a contextual prompt when its context fires. Big enough to
# overtake onboarding ONCE the user is no longer brand-new.
_CTX_BOOST = {
    "medicine_due": 60,     # missed medicine must surface
    "pay_bill": 45,
    "biz_orders": 40,
    "biz_dues": 30,
    "crm_leads": 30,
    "birthday_soon": 35,
    "spending_review": 25,
    "finish_tasks": 20,
    "ramadan": 50,
    "eid": 55,
    "friday": 20,
    "morning_briefing": 40,
    "evening_wrap": 35,
    "todays_plan": 30,
}

# Prompts that stay relevant enough to override the no-repeat-two-days penalty
# when their context is still firing (safety/health first).
_STICKY_WHEN_RELEVANT = frozenset({"medicine_due", "pay_bill"})

LEARN_TAP_BONUS = 8      # per tap of a prompt kind (capped)
LEARN_IGNORE_PENALTY = 6  # per ignore of a prompt kind (capped)
LEARN_CAP = 24
REPEAT_PENALTY = 1000     # effectively drops a repeat unless it is sticky+relevant


def _candidates(now, ctx):
    """Return {key: score} for every prompt whose context applies, before
    learn-from-use / no-repeat adjustments."""
    ctx = ctx or {}
    part = part_of_day(now)
    weekday = now.weekday()  # Mon=0 .. Fri=4 .. Sun=6
    new_user = bool(ctx.get("new_user"))
    scores = {}

    def add(key, boost=0):
        if key not in _PROMPTS:
            return
        base = _PROMPTS[key][2]
        scores[key] = base + boost

    if new_user:
        # Teach the main features. Onboarding dominates until the user has data.
        for k in ("onboard_reminder", "onboard_money", "onboard_medicine",
                  "onboard_circle", "onboard_scam"):
            add(k)
        # New users still get a couple of gentle contextual nudges so the deck
        # isn't 100% onboarding, but onboarding out-weights them.
        if part == PART_MORNING:
            add("morning_briefing", -20)
        return scores

    # ---- time of day ----
    if part == PART_MORNING:
        add("morning_briefing", _CTX_BOOST["morning_briefing"])
        add("todays_plan", _CTX_BOOST["todays_plan"])
    elif part in (PART_EVENING, PART_NIGHT):
        add("evening_wrap", _CTX_BOOST["evening_wrap"])
    add("todays_plan")

    # ---- missed / due medicine (safety-critical) ----
    if ctx.get("missed_medicine"):
        add("medicine_due", _CTX_BOOST["medicine_due"])

    # ---- bills due ----
    if ctx.get("due_bills"):
        add("pay_bill", _CTX_BOOST["pay_bill"])

    # ---- recent spending ----
    if ctx.get("recent_spending"):
        add("spending_review", _CTX_BOOST["spending_review"])

    # ---- unfinished tasks ----
    if ctx.get("unfinished_tasks"):
        add("finish_tasks", _CTX_BOOST["finish_tasks"])

    # ---- upcoming birthday ----
    if ctx.get("upcoming_birthday"):
        add("birthday_soon", _CTX_BOOST["birthday_soon"])

    # ---- active modules: business / CRM ----
    mods = set(ctx.get("active_modules") or [])
    if "business" in mods:
        add("biz_orders", _CTX_BOOST["biz_orders"])
        add("biz_dues", _CTX_BOOST["biz_dues"])
    if "crm" in mods:
        add("crm_leads", _CTX_BOOST["crm_leads"])

    # ---- season / day ----
    season = ctx.get("season")  # "ramadan" | "eid" | None
    if season == "ramadan":
        add("ramadan", _CTX_BOOST["ramadan"])
    elif season == "eid":
        add("eid", _CTX_BOOST["eid"])
    if weekday == 4:  # Friday
        add("friday", _CTX_BOOST["friday"])

    # Always keep enough TIME-APPROPRIATE evergreen fallbacks so there are >=4
    # candidates even with an empty context (low base weights so real context
    # always wins, and morning/evening stay distinct).
    fallbacks = ["todays_plan", "spending_review", "finish_tasks", "onboard_circle"]
    if part == PART_MORNING:
        fallbacks.insert(0, "morning_briefing")
    else:
        fallbacks.insert(0, "evening_wrap")
    for k in fallbacks:
        if k not in scores:
            add(k, -40)

    return scores


def _learn_adjust(scores, history):
    """Raise kinds the user taps, drop kinds they ignore. History:
        {"taps": {kind_or_key: n}, "ignores": {kind_or_key: n}}.
    Matching is by prompt KEY first, then its KIND, so a user can train either
    a specific card or a whole family."""
    if not history:
        return scores
    taps = history.get("taps") or {}
    ignores = history.get("ignores") or {}
    for key in list(scores):
        kind = _PROMPTS[key][0]
        tap = taps.get(key, 0) + taps.get(kind, 0)
        ign = ignores.get(key, 0) + ignores.get(kind, 0)
        delta = min(LEARN_CAP, tap * LEARN_TAP_BONUS) - min(LEARN_CAP, ign * LEARN_IGNORE_PENALTY)
        scores[key] += delta
    return scores


def _no_repeat_adjust(scores, history, ctx):
    """Penalise prompts served yesterday so the deck changes day-to-day, unless a
    sticky prompt is still strongly relevant."""
    if not history:
        return scores
    yesterday = set(history.get("served_yesterday") or [])
    ctx = ctx or {}
    for key in list(scores):
        if key not in yesterday:
            continue
        if key in _STICKY_WHEN_RELEVANT:
            # keep only if its context is still firing right now
            if key == "medicine_due" and ctx.get("missed_medicine"):
                continue
            if key == "pay_bill" and ctx.get("due_bills"):
                continue
        scores[key] -= REPEAT_PENALTY
    return scores


def _suppress(scores, history):
    """Remove long-pressed 'don't show' keys entirely."""
    if not history:
        return scores
    for key in history.get("suppressed") or []:
        scores.pop(key, None)
    return scores


def rank(now, context=None, history=None, refresh=False):
    """Return the ranked list of candidate keys (highest score first) after all
    adjustments. `refresh=True` rotates in the next-best set by dropping the top
    group that was just shown (history['current'])."""
    scores = _candidates(now, context)
    scores = _suppress(scores, history)
    scores = _learn_adjust(scores, history)
    scores = _no_repeat_adjust(scores, history, context)

    # Drop anything that fell below zero via penalties — a repeat that isn't
    # sticky shouldn't reappear if other candidates exist.
    if refresh and history:
        for key in history.get("current") or []:
            scores.pop(key, None)

    ranked = sorted(scores.items(), key=lambda kv: (-kv[1], kv[0]))
    return [k for k, s in ranked if s > -REPEAT_PENALTY / 2]


def suggest(lang, now, context=None, history=None, refresh=False, n=N_CARDS):
    """The public entry point. Returns up to `n` prompts as
        [{"key","text","route"}]
    with `text` in the requested language ONLY (strict — never mixed).
    """
    lang = "en" if lang == "en" else "bn"
    keys = rank(now, context, history, refresh=refresh)
    out = []
    for key in keys[:n]:
        _kind, route, _w, text = _PROMPTS[key]
        out.append({
            "key": key,
            "text": text[lang],      # single language, strict
            "route": route,
        })
    return out
