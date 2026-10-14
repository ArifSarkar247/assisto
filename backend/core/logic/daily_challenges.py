"""
daily_challenges.py — pure, deterministic DAILY CHALLENGE / QUIZ engine
(#173, §21). A daily-engagement feature for the ordinary user: one challenge
per day, rotated DETERMINISTICALLY from the calendar date so the same day
always yields the same item (reproducible, testable, identical on every
device without any sync). Answer the quiz, track a streak, earn points, and
keep a history of what you completed.

WHY DETERMINISTIC-BY-DATE: the daily item is NOT stored in a collection and is
NOT random. `daily(date_str)` hashes the ISO date into an index over a built-in
bilingual BANK, so there is no server round-trip, no per-user seed, and no way
for two users to see a different "challenge of the day". The bank lives in code
(this file); only the user's PROGRESS (which day they completed, the answer
they gave, points earned) is stored via the generic REST collection.

THE BANK (>=20 real bilingual items) covers useful, ACCURATE knowledge:
financial literacy, health tips, digital safety, and general knowledge. Two
item shapes:
  * "quiz" — a multiple-choice question with one correct option index + a short
    bilingual explanation. Facts are hand-checked, neutral, non-prescriptive.
  * "task" — a tiny do-this-today challenge (no right/wrong answer); completing
    it is self-reported and always "correct" (engagement, not assessment).

POINTS SEAM (never holds money):
  * A correct quiz = POINTS_CORRECT; a wrong quiz = POINTS_TRY (a small
    consolation so the user still feels progress); a task done = POINTS_TASK.
  * `summarise()` returns the TOTAL points a user has accrued from their saved
    progress rows. These points are the SAME "points" concept the referral
    engine (referral.py) mints — this module only COUNTS points from completed
    challenges and returns the number; it never grants Premium, never touches a
    balance, never holds money. The integrator who wires redemption routes
    points through the existing referral/plan seam (referral.POINTS_PER_PREMIUM_
    DAY). Documented, not wired here.

STREAK: `streak(progress_rows, today)` counts consecutive days (ending today or
yesterday) with a completed challenge — honest: a gap breaks it; a streak that
ended before yesterday is reported as 0 (it's over), with the longest run kept
separately so history still celebrates a past best.

HARD RULES:
  * NO DB, NO AI, NO I/O, NO MONEY-HOLDING. Pure dicts in/out.
  * TIME IS PASSED IN. Every date-dependent function takes an explicit date
    string ('YYYY-MM-DD'); there is no hidden clock.
  * Bilingual {"bn","en"} copy via `pick`; the .dart mirror keeps ZERO Bangla
    literals (all strings are localization getters; the bank TEXT itself is
    served from here / mirrored constants, not hard-coded Bangla in widgets).
  * Facts ACCURATE + neutral. No medical/financial prescription — tips are
    general ("drink water", "use a unique password"), not personalised advice.

Row shape the view layer stores (see integration note), collection
'challenges/progress':
  progress : {id, date, item_id, kind, answer, correct, points}
    date    'YYYY-MM-DD' (the day the challenge belonged to)
    item_id stable id from the BANK (e.g. 'fin_emergency_fund')
    kind    'quiz' | 'task'
    answer  chosen option index (quiz) or 1 (task done); null if skipped
    correct bool (task => always true once done)
    points  int points earned for that row

Run self-tests (no DB):
    python3 -c "import core.logic.daily_challenges_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# POINTS POLICY — OWNER REVIEW REQUIRED (documented seam; holds no money).
# These mirror the referral engine's "points" unit. Redemption (points ->
# Premium days) is the integrator's job via referral.POINTS_PER_PREMIUM_DAY.
# ---------------------------------------------------------------------------
POINTS_CORRECT = 10   # OWNER REVIEW — points for a correct quiz answer
POINTS_TRY = 2        # OWNER REVIEW — consolation points for a wrong answer
POINTS_TASK = 5       # OWNER REVIEW — points for completing a daily task


# ---------------------------------------------------------------------------
# THE BANK — >=20 real bilingual items. Hand-checked, neutral, accurate.
# Each item:
#   id        stable string id (used as item_id in progress rows)
#   cat       category key: 'finance' | 'health' | 'safety' | 'general'
#   kind      'quiz' | 'task'
#   q         (bn, en) question / challenge prompt
#   options   list of (bn, en) — quiz only
#   answer    correct option index — quiz only
#   explain   (bn, en) short explanation / why — both kinds
# ---------------------------------------------------------------------------
CATEGORIES = ["finance", "health", "safety", "general"]

BANK = [
    # ---- financial literacy ----
    {
        "id": "fin_emergency_fund", "cat": "finance", "kind": "quiz",
        "q": ("জরুরি তহবিল হিসেবে সাধারণত কত মাসের খরচ জমানোর পরামর্শ দেওয়া হয়?",
              "An emergency fund is commonly suggested to cover how many months of expenses?"),
        "options": [("১ সপ্তাহ", "1 week"), ("৩–৬ মাস", "3–6 months"),
                    ("১০ বছর", "10 years"), ("কোনো দরকার নেই", "No need at all")],
        "answer": 1,
        "explain": ("৩–৬ মাসের খরচ হাতে থাকলে চাকরি হারানো বা হঠাৎ অসুখের ধাক্কা সামলানো সহজ হয়। এটি সাধারণ নির্দেশনা, ব্যক্তিগত পরামর্শ নয়।",
                    "Keeping 3–6 months of expenses helps absorb a job loss or sudden illness. This is general guidance, not personal advice."),
    },
    {
        "id": "fin_interest_compound", "cat": "finance", "kind": "quiz",
        "q": ("চক্রবৃদ্ধি সুদ কীভাবে কাজ করে?",
              "How does compound interest work?"),
        "options": [("শুধু মূল টাকার উপর সুদ", "Interest only on the original amount"),
                    ("সুদের উপরও সুদ জমে", "Interest earns interest over time"),
                    ("সুদ কখনো বাড়ে না", "Interest never grows"),
                    ("সুদ মানেই লোকসান", "Interest always means loss")],
        "answer": 1,
        "explain": ("চক্রবৃদ্ধিতে জমা সুদ মূলের সাথে যোগ হয়, তাই পরের বার আগের সুদের উপরও সুদ আসে — সময়ের সাথে তা দ্রুত বাড়ে।",
                    "With compounding, earned interest is added to the principal, so later interest is calculated on the interest too — it grows faster over time."),
    },
    {
        "id": "fin_budget_5030_20", "cat": "finance", "kind": "quiz",
        "q": ("৫০/৩০/২০ বাজেট নিয়মে ২০% ভাগটি কিসের জন্য?",
              "In the 50/30/20 budgeting rule, the 20% is for what?"),
        "options": [("বিলাসিতা", "Luxury only"), ("প্রয়োজনীয় খরচ", "Needs"),
                    ("সঞ্চয় ও ঋণ শোধ", "Savings and paying off debt"),
                    ("বিনোদন", "Entertainment")],
        "answer": 2,
        "explain": ("৫০% প্রয়োজন, ৩০% শখ, আর ২০% সঞ্চয় ও ঋণ পরিশোধে — একটি সহজ কাঠামো, বাধ্যতামূলক নয়।",
                    "50% needs, 30% wants, and 20% to savings and debt repayment — a simple framework, not a rule you must follow."),
    },
    {
        "id": "fin_inflation", "cat": "finance", "kind": "quiz",
        "q": ("মূল্যস্ফীতি (inflation) আপনার টাকার উপর কী প্রভাব ফেলে?",
              "What does inflation do to the value of your money?"),
        "options": [("ক্রয়ক্ষমতা কমায়", "Reduces its purchasing power"),
                    ("ক্রয়ক্ষমতা বাড়ায়", "Increases its purchasing power"),
                    ("কোনো প্রভাব নেই", "Has no effect"),
                    ("টাকা দ্বিগুণ করে", "Doubles your money")],
        "answer": 0,
        "explain": ("মূল্যস্ফীতিতে জিনিসের দাম বাড়ে, তাই একই টাকায় কম জিনিস কেনা যায় — অর্থাৎ টাকার ক্রয়ক্ষমতা কমে।",
                    "Inflation raises prices, so the same money buys fewer things — its purchasing power falls."),
    },
    {
        "id": "fin_save_task", "cat": "finance", "kind": "task",
        "q": ("আজকের চ্যালেঞ্জ: আজ একটি অপ্রয়োজনীয় খরচ এড়িয়ে সেই টাকাটা আলাদা করে রাখুন।",
              "Today's challenge: skip one non-essential purchase today and set that money aside."),
        "options": [],
        "answer": None,
        "explain": ("ছোট ছোট সঞ্চয় জমে বড় হয়। কত বাঁচালেন তা নিজের সঞ্চয় চ্যালেঞ্জে যোগ করতে পারেন।",
                    "Small savings add up. You can log what you saved in your Savings Challenge."),
    },
    # ---- health tips ----
    {
        "id": "health_water", "cat": "health", "kind": "quiz",
        "q": ("সুস্থ থাকার সাধারণ পরামর্শ অনুযায়ী দিনে কেমন পানি পান করা ভালো?",
              "For general wellbeing, which habit is usually recommended for water?"),
        "options": [("একদমই না", "None at all"),
                    ("পর্যাপ্ত পানি, তৃষ্ণা অনুযায়ী নিয়মিত", "Enough water, regularly, as you feel thirsty"),
                    ("শুধু চা-কফি", "Only tea and coffee"),
                    ("দিনে একবার", "Just once a day")],
        "answer": 1,
        "explain": ("প্রয়োজন ব্যক্তিভেদে আলাদা, তবে সারাদিন নিয়মিত পর্যাপ্ত পানি পান করা সাধারণভাবে ভালো। এটি সাধারণ তথ্য, চিকিৎসা পরামর্শ নয়।",
                    "Needs vary by person, but drinking enough water regularly through the day is generally good. This is general info, not medical advice."),
    },
    {
        "id": "health_handwash", "cat": "health", "kind": "quiz",
        "q": ("রোগ ছড়ানো ঠেকাতে সাবান দিয়ে হাত ধোয়া কমপক্ষে কতক্ষণ করা উচিত?",
              "To help prevent illness spreading, you should wash hands with soap for at least how long?"),
        "options": [("২ সেকেন্ড", "2 seconds"), ("২০ সেকেন্ড", "20 seconds"),
                    ("৫ মিনিট", "5 minutes"), ("ধোয়ার দরকার নেই", "No need to wash")],
        "answer": 1,
        "explain": ("অন্তত ২০ সেকেন্ড সাবান দিয়ে হাত ঘষে ধোয়া জীবাণু কমাতে কার্যকর — খাওয়ার আগে ও টয়লেটের পরে বিশেষভাবে।",
                    "Scrubbing with soap for at least 20 seconds effectively removes germs — especially before eating and after the toilet."),
    },
    {
        "id": "health_sleep", "cat": "health", "kind": "quiz",
        "q": ("প্রাপ্তবয়স্কদের জন্য সাধারণভাবে রাতে কত ঘণ্টা ঘুম পরামর্শ দেওয়া হয়?",
              "How many hours of sleep per night are generally suggested for adults?"),
        "options": [("২–৩ ঘণ্টা", "2–3 hours"), ("৭–৯ ঘণ্টা", "7–9 hours"),
                    ("১২ ঘণ্টা", "12 hours"), ("ঘুমের দরকার নেই", "No sleep needed")],
        "answer": 1,
        "explain": ("বেশিরভাগ প্রাপ্তবয়স্কের জন্য রাতে ৭–৯ ঘণ্টা ঘুম সাধারণভাবে পরামর্শ দেওয়া হয়। ব্যক্তিভেদে ভিন্ন হতে পারে।",
                    "Most adults are generally advised to get 7–9 hours a night. Individual needs can differ."),
    },
    {
        "id": "health_salt", "cat": "health", "kind": "quiz",
        "q": ("রক্তচাপ নিয়ন্ত্রণে রাখতে সাধারণভাবে কোনটি সহায়ক?",
              "Which habit generally helps keep blood pressure in check?"),
        "options": [("অতিরিক্ত লবণ খাওয়া", "Eating a lot of extra salt"),
                    ("পরিমিত লবণ ও নিয়মিত হাঁটা", "Moderate salt and regular walking"),
                    ("ধূমপান", "Smoking"),
                    ("রাত জাগা", "Staying up late")],
        "answer": 1,
        "explain": ("পরিমিত লবণ, নিয়মিত হাঁটাচলা ও ওজন নিয়ন্ত্রণ সাধারণভাবে রক্তচাপের জন্য ভালো। সমস্যা থাকলে ডাক্তারের পরামর্শ নিন।",
                    "Moderate salt, regular walking and a healthy weight are generally good for blood pressure. See a doctor if you have concerns."),
    },
    {
        "id": "health_walk_task", "cat": "health", "kind": "task",
        "q": ("আজকের চ্যালেঞ্জ: আজ অন্তত ১৫ মিনিট হাঁটুন।",
              "Today's challenge: take at least a 15-minute walk today."),
        "options": [],
        "answer": None,
        "explain": ("অল্প হাঁটাও শরীর ও মনের জন্য ভালো। নিজের সুবিধামতো সময়ে করুন।",
                    "Even a short walk is good for body and mind. Do it whenever suits you."),
    },
    # ---- digital safety ----
    {
        "id": "safe_password", "cat": "safety", "kind": "quiz",
        "q": ("কোনটি সবচেয়ে নিরাপদ পাসওয়ার্ড অভ্যাস?",
              "Which is the safest password habit?"),
        "options": [("সব জায়গায় একই পাসওয়ার্ড", "The same password everywhere"),
                    ("প্রতিটি গুরুত্বপূর্ণ অ্যাকাউন্টে আলাদা, শক্ত পাসওয়ার্ড", "A different, strong password for each important account"),
                    ("পাসওয়ার্ড লিখে দেয়ালে টাঙানো", "Writing it on the wall"),
                    ("নাম ও জন্মসাল", "Your name and birth year")],
        "answer": 1,
        "explain": ("প্রতিটি গুরুত্বপূর্ণ অ্যাকাউন্টে আলাদা শক্ত পাসওয়ার্ড রাখলে একটি ফাঁস হলেও বাকিগুলো সুরক্ষিত থাকে। পাসওয়ার্ড ম্যানেজার সাহায্য করে।",
                    "A unique strong password per important account means one leak doesn't expose the rest. A password manager helps."),
    },
    {
        "id": "safe_otp", "cat": "safety", "kind": "quiz",
        "q": ("কেউ ফোন করে আপনার OTP/ভেরিফিকেশন কোড চাইলে কী করবেন?",
              "Someone calls asking for your OTP / verification code. What should you do?"),
        "options": [("দিয়ে দেবেন", "Share it with them"),
                    ("কখনোই শেয়ার করবেন না", "Never share it"),
                    ("শুধু আত্মীয় হলে দেবেন", "Share only if they say they're a relative"),
                    ("SMS-এ ফরোয়ার্ড করবেন", "Forward it over SMS")],
        "answer": 1,
        "explain": ("ব্যাংক বা কোনো আসল প্রতিষ্ঠান কখনো OTP চায় না। OTP শেয়ার করলে অ্যাকাউন্ট খালি হয়ে যেতে পারে — কখনো দেবেন না।",
                    "No real bank or company ever asks for your OTP. Sharing it can empty your account — never give it out."),
    },
    {
        "id": "safe_2fa", "cat": "safety", "kind": "quiz",
        "q": ("টু-ফ্যাক্টর অথেনটিকেশন (2FA) কী করে?",
              "What does two-factor authentication (2FA) do?"),
        "options": [("পাসওয়ার্ড মুছে দেয়", "Deletes your password"),
                    ("পাসওয়ার্ডের পাশাপাশি দ্বিতীয় একটি ধাপ যোগ করে", "Adds a second step on top of your password"),
                    ("ইন্টারনেট দ্রুত করে", "Makes the internet faster"),
                    ("অ্যাকাউন্ট পাবলিক করে", "Makes your account public")],
        "answer": 1,
        "explain": ("2FA চালু থাকলে পাসওয়ার্ড জানলেও দ্বিতীয় কোড ছাড়া কেউ ঢুকতে পারে না — গুরুত্বপূর্ণ অ্যাকাউন্টে চালু রাখা ভালো।",
                    "With 2FA on, even someone who knows your password can't log in without the second code — worth enabling on important accounts."),
    },
    {
        "id": "safe_link", "cat": "safety", "kind": "quiz",
        "q": ("'আপনি পুরস্কার জিতেছেন, লিংকে ক্লিক করুন' — এমন SMS পেলে কী করবেন?",
              "You get an SMS: 'You won a prize, click this link.' What should you do?"),
        "options": [("দ্রুত ক্লিক করবেন", "Click it quickly"),
                    ("ক্লিক না করে মুছে দেবেন", "Don't click — delete it"),
                    ("ব্যাংক তথ্য দেবেন", "Reply with bank details"),
                    ("সবাইকে ফরোয়ার্ড করবেন", "Forward it to everyone")],
        "answer": 1,
        "explain": ("অপ্রত্যাশিত পুরস্কারের লিংক প্রায়ই প্রতারণা (ফিশিং)। ক্লিক করলে তথ্য বা টাকা খোয়া যেতে পারে — মুছে ফেলাই নিরাপদ।",
                    "Unexpected prize links are usually scams (phishing). Clicking can steal your data or money — deleting is the safe move."),
    },
    {
        "id": "safe_backup_task", "cat": "safety", "kind": "task",
        "q": ("আজকের চ্যালেঞ্জ: আপনার ফোনের গুরুত্বপূর্ণ ছবি/ফাইল আজ একবার ব্যাকআপ করে রাখুন।",
              "Today's challenge: back up your phone's important photos/files once today."),
        "options": [],
        "answer": None,
        "explain": ("ফোন হারালে বা নষ্ট হলে ব্যাকআপ থাকলে তথ্য থেকে যায়। Vault-এ গুরুত্বপূর্ণ নথি রাখতে পারেন।",
                    "A backup keeps your data if the phone is lost or breaks. You can keep important documents in Vault."),
    },
    # ---- general knowledge ----
    {
        "id": "gen_bd_capital", "cat": "general", "kind": "quiz",
        "q": ("বাংলাদেশের রাজধানী কোনটি?",
              "What is the capital of Bangladesh?"),
        "options": [("চট্টগ্রাম", "Chattogram"), ("ঢাকা", "Dhaka"),
                    ("খুলনা", "Khulna"), ("রাজশাহী", "Rajshahi")],
        "answer": 1,
        "explain": ("ঢাকা বাংলাদেশের রাজধানী ও সবচেয়ে বড় শহর।",
                    "Dhaka is the capital and largest city of Bangladesh."),
    },
    {
        "id": "gen_language_day", "cat": "general", "kind": "quiz",
        "q": ("আন্তর্জাতিক মাতৃভাষা দিবস কবে পালিত হয়?",
              "When is International Mother Language Day observed?"),
        "options": [("২১ ফেব্রুয়ারি", "21 February"), ("১৬ ডিসেম্বর", "16 December"),
                    ("২৬ মার্চ", "26 March"), ("১ জানুয়ারি", "1 January")],
        "answer": 0,
        "explain": ("একুশে ফেব্রুয়ারি ভাষা আন্দোলনের স্মরণে আন্তর্জাতিক মাতৃভাষা দিবস হিসেবে স্বীকৃত।",
                    "21 February is recognised as International Mother Language Day, honouring the Language Movement."),
    },
    {
        "id": "gen_water_boil", "cat": "general", "kind": "quiz",
        "q": ("সমুদ্রপৃষ্ঠে বিশুদ্ধ পানি কত ডিগ্রি সেলসিয়াসে ফোটে?",
              "At sea level, pure water boils at what temperature (°C)?"),
        "options": [("৫০°", "50°"), ("১০০°", "100°"), ("২০০°", "200°"), ("০°", "0°")],
        "answer": 1,
        "explain": ("সমুদ্রপৃষ্ঠের স্বাভাবিক চাপে বিশুদ্ধ পানি ১০০° সেলসিয়াসে ফোটে; উঁচু জায়গায় তা একটু কম।",
                    "At normal sea-level pressure, pure water boils at 100 °C; at high altitude it's a bit lower."),
    },
    {
        "id": "gen_continents", "cat": "general", "kind": "quiz",
        "q": ("পৃথিবীতে মহাদেশ কয়টি?",
              "How many continents are there on Earth?"),
        "options": [("৫টি", "5"), ("৭টি", "7"), ("১০টি", "10"), ("৩টি", "3")],
        "answer": 1,
        "explain": ("সাধারণভাবে পৃথিবীকে ৭টি মহাদেশে ভাগ করা হয়: এশিয়া, আফ্রিকা, ইউরোপ, উত্তর আমেরিকা, দক্ষিণ আমেরিকা, অস্ট্রেলিয়া ও অ্যান্টার্কটিকা।",
                    "The Earth is commonly divided into 7 continents: Asia, Africa, Europe, North America, South America, Australia and Antarctica."),
    },
    {
        "id": "gen_learn_task", "cat": "general", "kind": "task",
        "q": ("আজকের চ্যালেঞ্জ: আজ নতুন একটি শব্দ বা তথ্য শিখে কাউকে শেখান।",
              "Today's challenge: learn one new word or fact today and teach it to someone."),
        "options": [],
        "answer": None,
        "explain": ("শেখা জিনিস কাউকে শেখালে তা ভালো মনে থাকে। ছোট কিছু হলেও চলবে।",
                    "Teaching what you learn helps you remember it. Even something small counts."),
    },
    {
        "id": "fin_scam_invest", "cat": "finance", "kind": "quiz",
        "q": ("'নিশ্চিত দ্বিগুণ লাভ, কোনো ঝুঁকি নেই' — এমন বিনিয়োগের প্রস্তাব সাধারণত কী?",
              "'Guaranteed double returns, zero risk' investment offers are usually what?"),
        "options": [("দারুণ সুযোগ", "A great opportunity"),
                    ("প্রতারণার লক্ষণ", "A sign of a scam"),
                    ("সরকারি স্কিম", "A government scheme"),
                    ("ব্যাংকের অফার", "A normal bank offer")],
        "answer": 1,
        "explain": ("কোনো আসল বিনিয়োগ 'ঝুঁকিহীন নিশ্চিত দ্বিগুণ লাভ' দেয় না। এমন প্রতিশ্রুতি প্রায় সবসময়ই প্রতারণা।",
                    "No genuine investment offers 'risk-free guaranteed doubling'. Such promises are almost always scams."),
    },
]

# Public, stable lookup by id.
BANK_BY_ID = {it["id"]: it for it in BANK}


# ---------------------------------------------------------------------------
# Deterministic date -> index mapping (no DB, no randomness).
# ---------------------------------------------------------------------------
def _parse_date(date_str):
    """Return (y, m, d) ints or None for a 'YYYY-MM-DD' string."""
    if not date_str:
        return None
    parts = str(date_str).strip().split("-")
    if len(parts) < 3:
        return None
    try:
        y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
    except (TypeError, ValueError):
        return None
    if m < 1 or m > 12 or d < 1 or d > 31:
        return None
    return (y, m, d)


_MDAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


def _is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def date_ordinal(date_str):
    """Proleptic day-number from year 1 for a valid date, else None.

    Pure integer date math (no datetime) so it is identical to the .dart
    mirror and never drifts across time zones / platforms."""
    ymd = _parse_date(date_str)
    if ymd is None:
        return None
    y, m, d = ymd
    days = 0
    for yy in range(1, y):
        days += 366 if _is_leap(yy) else 365
    for mm in range(1, m):
        days += _MDAYS[mm - 1] + (1 if (mm == 2 and _is_leap(y)) else 0)
    return days + d


def daily_index(date_str, n=None):
    """Deterministic index into the bank for a given ISO date.

    Uses the date's ordinal modulo the bank size — same day => same index,
    every day advances by one, and it wraps cleanly. Returns None for a bad
    date (the caller shows an honest 'no challenge' state rather than guessing).
    """
    size = len(BANK) if n is None else n
    if size <= 0:
        return None
    o = date_ordinal(date_str)
    if o is None:
        return None
    return o % size


def daily(date_str, lang="bn"):
    """The deterministic challenge for `date_str`, localized.

    Returns a dict shaped for the view layer, or {'ok': False, ...} on a bad
    date. Never random, never per-user; the same date always returns the same
    item_id. HOLDS NO MONEY; this only describes the challenge."""
    idx = daily_index(date_str)
    if idx is None:
        return {"ok": False, "reason": "bad_date", "date": date_str}
    it = BANK[idx]
    return _present(it, date_str, lang)


def by_id(item_id, date_str, lang="bn"):
    """Localized presentation of a specific bank item (for history replay)."""
    it = BANK_BY_ID.get(item_id)
    if it is None:
        return {"ok": False, "reason": "unknown_item", "item_id": item_id}
    return _present(it, date_str, lang)


def _present(it, date_str, lang):
    return {
        "ok": True,
        "date": date_str,
        "item_id": it["id"],
        "cat": it["cat"],
        "kind": it["kind"],
        "question": pick(lang, *it["q"]),
        "options": [pick(lang, *o) for o in it["options"]],
        "answer": it["answer"],
        "explain": pick(lang, *it["explain"]),
        # honest flags
        "ai_required": False,
        "mock": False,          # these are real curated facts, not mock AI
        "deterministic": True,
    }


# ---------------------------------------------------------------------------
# Scoring — pure. Never grants money/plan; returns points only.
# ---------------------------------------------------------------------------
def score(item_id, answer):
    """Score an attempt at a bank item.

    answer: the chosen option index for a quiz, or any truthy value (e.g. 1)
    meaning "I did the task" for a task. Returns a dict:
      {correct, points, kind, answer} — for a quiz, correct iff answer matches
      the bank's answer index; a wrong quiz still earns POINTS_TRY. A task is
      'correct' once done (engagement, not assessment) and earns POINTS_TASK.
    An unknown item or a null/blank answer scores nothing (honest skip)."""
    it = BANK_BY_ID.get(item_id)
    if it is None:
        return {"correct": False, "points": 0, "kind": None, "answer": answer,
                "reason": "unknown_item"}
    if it["kind"] == "task":
        done = answer is not None and answer is not False and answer != ""
        return {"correct": bool(done), "points": POINTS_TASK if done else 0,
                "kind": "task", "answer": answer}
    # quiz
    if answer is None or answer == "":
        return {"correct": False, "points": 0, "kind": "quiz", "answer": None}
    try:
        chosen = int(answer)
    except (TypeError, ValueError):
        return {"correct": False, "points": 0, "kind": "quiz", "answer": answer}
    correct = chosen == it["answer"]
    return {"correct": correct,
            "points": POINTS_CORRECT if correct else POINTS_TRY,
            "kind": "quiz", "answer": chosen}


def build_progress_row(item_id, answer):
    """Shape a progress row for the generic collection from an attempt.

    Returns {date, item_id, kind, answer, correct, points} — WITHOUT an id
    (the collection assigns it). `date` is the item's own date if the caller
    scored a specific day; the view layer sets it. Here we return the scoring
    half; the view layer merges {'date': <the day>} before POSTing."""
    s = score(item_id, answer)
    return {
        "item_id": item_id,
        "kind": s["kind"],
        "answer": s["answer"],
        "correct": s["correct"],
        "points": s["points"],
    }


# ---------------------------------------------------------------------------
# Streak + summary over saved progress rows — all pure, time passed in.
# ---------------------------------------------------------------------------
def _completed_days(progress_rows):
    """Set of distinct 'YYYY-MM-DD' strings that have a completed row.

    A row counts as completed if it has a valid date and a non-null answer
    (i.e. the user actually engaged — a skipped row with answer null does not
    count toward a streak)."""
    days = set()
    for r in progress_rows or []:
        d = r.get("date")
        if date_ordinal(d) is None:
            continue
        if r.get("answer") is None:
            continue
        days.add(str(d).strip())
    return days


def streak(progress_rows, today):
    """Current consecutive-day streak ending today or yesterday, else 0.

    Honest: a gap breaks the current streak; a run that ended two or more days
    ago is over and reported as 0. The streak is counted backwards from the
    most recent of {today, yesterday} that has a completed challenge."""
    days = _completed_days(progress_rows)
    t = date_ordinal(today)
    if t is None or not days:
        return 0
    ordinals = {date_ordinal(d) for d in days}
    ordinals.discard(None)
    # Current streak must include today or yesterday to be "current".
    if t in ordinals:
        anchor = t
    elif (t - 1) in ordinals:
        anchor = t - 1
    else:
        return 0
    run = 0
    cur = anchor
    while cur in ordinals:
        run += 1
        cur -= 1
    return run


def longest_streak(progress_rows):
    """Longest consecutive-day run ever completed (celebrates a past best)."""
    days = _completed_days(progress_rows)
    ordinals = sorted({date_ordinal(d) for d in days} - {None})
    if not ordinals:
        return 0
    best = 1
    run = 1
    for i in range(1, len(ordinals)):
        if ordinals[i] == ordinals[i - 1] + 1:
            run += 1
            best = max(best, run)
        else:
            run = 1
    return best


def summarise(progress_rows, today):
    """Aggregate a user's challenge progress — pure, no money.

    Returns:
      {total_points, total_completed, correct_count, quiz_attempts,
       accuracy, current_streak, longest_streak, done_today, by_category}
    `total_points` is the SUM of the points field across completed rows — the
    same "points" unit the referral engine mints. This function only COUNTS;
    redemption to Premium is the integrator's seam (referral.POINTS_PER_PREMIUM_
    DAY). Never grants a plan, never holds money."""
    rows = [r for r in (progress_rows or []) if r.get("answer") is not None]
    total_points = sum(int(r.get("points") or 0) for r in rows)
    total_completed = len(rows)
    quiz = [r for r in rows if r.get("kind") == "quiz"]
    correct_count = sum(1 for r in quiz if r.get("correct"))
    quiz_attempts = len(quiz)
    accuracy = (round(correct_count * 100 / quiz_attempts)
                if quiz_attempts else None)
    by_cat = {c: 0 for c in CATEGORIES}
    for r in rows:
        it = BANK_BY_ID.get(r.get("item_id"))
        if it is not None:
            by_cat[it["cat"]] = by_cat.get(it["cat"], 0) + 1
    done_today = str(today).strip() in _completed_days(rows)
    return {
        "total_points": total_points,
        "total_completed": total_completed,
        "correct_count": correct_count,
        "quiz_attempts": quiz_attempts,
        "accuracy": accuracy,
        "current_streak": streak(rows, today),
        "longest_streak": longest_streak(rows),
        "done_today": done_today,
        "by_category": by_cat,
    }


def premium_days_from_points(points):
    """DOCUMENTED SEAM (not wired): how many Premium days `points` would buy.

    Mirrors the referral redemption rate so challenge points and referral
    points share one wallet concept. Returns an int >= 0. The actual grant
    (extending user.plan_until) is the integrator's job via the existing plan
    mechanism — this never holds money or mutates a plan."""
    # Keep in lockstep with referral.POINTS_PER_PREMIUM_DAY (imported lazily so
    # this module stays standalone-testable without the Django app on path).
    rate = 25  # referral.POINTS_PER_PREMIUM_DAY default (OWNER REVIEW)
    try:
        from core.logic import referral as _r  # pragma: no cover
        rate = getattr(_r, "POINTS_PER_PREMIUM_DAY", rate)
    except Exception:
        pass
    if rate <= 0:
        return 0
    p = int(points or 0)
    return p // rate if p > 0 else 0
