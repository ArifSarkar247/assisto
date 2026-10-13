"""
scam.py — Assisto's maintained library of REAL Bangladeshi scam patterns +
a rule-based detector (no AI key; pure Python, deterministic, unit-testable).

Benchmarked against GASA / Truecaller fraud-awareness: instead of a single
opaque "spam" score, every detection cites a *named pattern* drawn from a
curated library, with a plain-language WHY-it's-a-scam explanation and
concrete "what to do" steps — in BOTH Bangla and English.

Honesty rules (do NOT fabricate):
  - A verdict only ever cites patterns that actually matched, by their type.
  - We never claim certainty: the verdict is "scam-likely / suspicious / clean"
    and always tells the user to verify through official channels.
  - The library describes well-documented, publicly reported scam *tactics*
    (bKash/Nagad PIN-OTP theft, lottery/prize, fake jobs, impersonation of
    bank/police/family, loan-advance-fee, MFS "wrong send, please reverse"
    tricks). It names no real person or company as a fraudster.

Kept free of Django imports so it runs anywhere:
    python3 -c "import core.logic.scam as s; print(s.check_message('...','bn'))"
"""
import re
import unicodedata


# ---------------------------------------------------------------------------
# bilingual pick (local copy so this module has zero Django dependency)
# ---------------------------------------------------------------------------

def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# normalisation — fold Bangla digits, collapse spacing, lower-case.
# Scam SMS routinely space out "O T P" / "প ি ন" to dodge naive filters;
# we strip single-char gaps between letters so those still match.
# ---------------------------------------------------------------------------

_BN_DIGITS = {ord("০") + i: str(i) for i in range(10)}


def normalize(text):
    t = unicodedata.normalize("NFKC", text or "")
    t = t.translate(_BN_DIGITS)
    t = t.lower()
    # collapse runs of whitespace
    t = re.sub(r"\s+", " ", t).strip()
    return t


# Scammers space out only a handful of sensitive keywords ("o t p", "p i n")
# to dodge naive filters. We collapse a spaced-out run ONLY when it spells one
# of these known evasion keywords — so innocent spaced acronyms like "c i d"
# (which is a legitimate signal word) are left untouched and don't false-match.
_DESPACE_KEYWORDS = ["otp", "pin", "cvv", "password", "pwd"]
# Build a regex that matches each keyword with a single space between letters,
# e.g. "o t p", "p a s s w o r d" (word-bounded).
_DESPACE_RE = re.compile(
    r"\b(" + "|".join(" ".join(k) for k in _DESPACE_KEYWORDS) + r")\b")


def _despace_latin(low):
    """Join 'o t p' / 'p i n' style spaced-out Latin letters so the keyword
    regexes still fire — but ONLY for known evasion keywords (otp/pin/cvv/
    password/pwd), never for arbitrary spaced Latin runs. This keeps 'c i d'
    from being collapsed into 'cid' and falsely firing the impersonation rule."""
    return _DESPACE_RE.sub(lambda m: m.group(0).replace(" ", ""), low)


# ---------------------------------------------------------------------------
# shared signal regexes
# ---------------------------------------------------------------------------

URL = re.compile(r"(https?://[^\s]+|\b[\w\-]+\.(?:com|net|xyz|top|info|link|ml|tk|ga|cc|online|site|club|shop|vip)\b)", re.I)
SHORTENERS = ["bit.ly", "tinyurl", "cutt.ly", "t.me", "wa.me", "is.gd", "shorturl", "rb.gy", "bit.do", "goo.gl"]
MFS = ["bkash", "বিকাশ", "nagad", "নগদ", "rocket", "রকেট", "upay", "উপায়", "tap", "ট্যাপ"]


def _any(low, pats):
    return any(re.search(p, low) for p in pats)


# ---------------------------------------------------------------------------
# THE PATTERN LIBRARY
# Each entry:
#   key       machine id (stable; cite this)
#   weight    0-100 contribution to the risk score
#   level     'high' | 'medium' | 'low' — inherent danger of the tactic
#   name_*    short human label (bn/en)
#   why_*     WHY it's a scam (bn/en) — the teaching moment
#   do_*      what to do about it (bn/en)
#   signals   list of regexes (run against the normalised text); [] means the
#             match is computed in code (see _dynamic_signals)
# ---------------------------------------------------------------------------

PATTERNS = [
    {
        "key": "pin_otp_request", "weight": 45, "level": "high",
        "name_bn": "PIN / OTP / পাসওয়ার্ড চাওয়া",
        "name_en": "PIN / OTP / password request",
        "why_bn": "কোনো আসল ব্যাংক, bKash, Nagad বা সরকারি অফিস আপনার PIN, OTP বা "
                  "পাসওয়ার্ড কখনোই ফোনে/মেসেজে চায় না। এটা চাইলেই বুঝবেন প্রতারণা।",
        "why_en": "No real bank, bKash, Nagad or government office ever asks for your "
                  "PIN, OTP or password by phone or message. If they ask, it is a scam.",
        "do_bn": "PIN/OTP কাউকে দেবেন না। লাইন কেটে দিন। সন্দেহ হলে কার্ডের পেছনের "
                 "অফিসিয়াল নম্বরে নিজে ফোন করুন।",
        "do_en": "Never share a PIN/OTP. Hang up. If unsure, call the official number "
                 "on your card yourself.",
        "signals": [r"\bpin\b", r"\botp\b", r"ও\s*টি\s*পি", r"পিন", r"পাসওয়ার্ড",
                    r"password", r"ভেরিফিকেশন কোড", r"verification code", r"\bcvv\b",
                    r"গোপন (কোড|নম্বর)", r"secret code"],
    },
    {
        "key": "prize_lottery", "weight": 35, "level": "high",
        "name_bn": "লটারি / পুরস্কার জেতার টোপ",
        "name_en": "Prize / lottery bait",
        "why_bn": "যে লটারিতে আপনি অংশই নেননি, সেখানে জেতা অসম্ভব। 'পুরস্কার পেতে আগে "
                  "ফি/চার্জ দিন' — এটাই আসল ফাঁদ; টাকা নিয়ে উধাও হয়ে যায়।",
        "why_en": "You cannot win a lottery you never entered. 'Pay a fee first to "
                  "claim your prize' is the trap — they take the fee and vanish.",
        "do_bn": "পুরস্কারের কথা শুনে কোনো ফি দেবেন না, তথ্য দেবেন না। মেসেজ ডিলিট করুন।",
        "do_en": "Pay nothing and share nothing to 'claim' a prize. Delete the message.",
        "signals": [r"লটারি", r"lottery", r"পুরস্কার", r"prize", r"জিতেছেন", r"বিজয়ী",
                    r"winner", r"congratulation", r"অভিনন্দন", r"লাখ টাকা.*জিত",
                    r"gift", r"উপহার", r"বোনাস.*পেয়েছেন", r"lucky (draw|winner)"],
    },
    {
        "key": "fake_job", "weight": 30, "level": "high",
        "name_bn": "ভুয়া চাকরি / ঘরে বসে আয়ের অফার",
        "name_en": "Fake job / work-from-home offer",
        "why_bn": "'ঘরে বসে দিনে হাজার টাকা', 'শুধু লাইক দিলেই আয়' — আগে রেজিস্ট্রেশন/"
                  "সিকিউরিটি ফি চায়। আসল চাকরিতে প্রার্থীর কাছ থেকে টাকা নেওয়া হয় না।",
        "why_en": "'Earn thousands a day from home', 'get paid just to like videos' — "
                  "they ask for a registration/security fee first. Real jobs never "
                  "charge the applicant.",
        "do_bn": "চাকরির জন্য আগে টাকা চাইলে সেটি প্রতারণা। প্রতিষ্ঠানটি আলাদাভাবে যাচাই করুন।",
        "do_en": "If a job asks you to pay upfront, it's a scam. Verify the company "
                 "independently.",
        "signals": [r"ঘরে বসে.*(আয়|ইনকাম|income|earn)", r"work from home", r"part[- ]?time",
                    r"দিনে \d+ ?(টাকা|tk)", r"খণ্ডকালীন", r"শুধু লাইক", r"just like",
                    r"telegram.*(task|job|কাজ)", r"রেজিস্ট্রেশন ফি", r"registration fee",
                    r"সিকিউরিটি ফি", r"নিয়োগ.*ফি"],
    },
    {
        "key": "impersonation_authority", "weight": 30, "level": "high",
        "name_bn": "ব্যাংক / পুলিশ / অফিসের ছদ্মবেশ",
        "name_en": "Bank / police / office impersonation",
        "why_bn": "প্রতারকেরা 'হেড অফিস থেকে বলছি', 'পুলিশ/CID', 'আপনার অ্যাকাউন্ট বন্ধ "
                  "হয়ে যাবে' বলে ভয় দেখায়। পরিচয় যাচাই না করে কিছুই করবেন না।",
        "why_en": "Scammers pose as 'head office', 'police/CID' or threaten 'your "
                  "account will be blocked' to frighten you. Verify the identity "
                  "before doing anything.",
        "do_bn": "ভয় পাবেন না। কল কেটে দিয়ে অফিসিয়াল হেল্পলাইনে নিজে ফোন করে যাচাই করুন।",
        "do_en": "Don't panic. Hang up and verify by calling the official helpline "
                 "yourself.",
        "signals": [r"হেড অফিস", r"head office", r"অফিস থেকে বলছি", r"official",
                    r"customer care", r"কাস্টমার কেয়ার", r"helpline", r"পুলিশ", r"police",
                    r"\bcid\b", r"র‍?্যাব", r"\brab\b", r"আদালত", r"মামলা", r"warrant",
                    r"অ্যাকাউন্ট.*(বন্ধ|block|suspend|স্থগিত)", r"account.*(block|suspend|close)"],
    },
    {
        "key": "impersonation_family", "weight": 28, "level": "high",
        "name_bn": "পরিবার / বন্ধুর ছদ্মবেশে টাকা চাওয়া",
        "name_en": "Family / friend impersonation asking for money",
        "why_bn": "'আমি তোমার আত্মীয়, নতুন নম্বর, বিপদে পড়েছি, টাকা পাঠাও' — নতুন নম্বর "
                  "থেকে এমন বার্তা প্রায়ই প্রতারণা। পাঠানোর আগে সরাসরি পরিচিত নম্বরে কল করুন।",
        "why_en": "'It's me, your relative, new number, I'm in trouble, send money' — "
                  "such messages from a new number are often scams. Call the person "
                  "on their known number before sending anything.",
        "do_bn": "টাকা পাঠানোর আগে তাকে তার পুরোনো/পরিচিত নম্বরে সরাসরি ফোন করে নিশ্চিত হন।",
        "do_en": "Before sending money, call them directly on their known number to confirm.",
        "signals": [r"নতুন নম্বর", r"new number", r"আমি তোমার", r"it'?s me", r"বিপদে",
                    r"emergency.*money", r"হাসপাতাল.*টাকা", r"accident.*(money|টাকা)",
                    r"মা বলছি", r"বাবা বলছি", r"your (son|daughter|father|mother)"],
    },
    {
        "key": "loan_advance_fee", "weight": 28, "level": "high",
        "name_bn": "লোন / অগ্রিম-ফি প্রতারণা",
        "name_en": "Loan / advance-fee scam",
        "why_bn": "'বিনা জামানতে তাৎক্ষণিক লোন, আগে প্রসেসিং ফি দিন' — ফি নেওয়ার পর লোন "
                  "আসে না। আসল ঋণদাতা অনুমোদনের আগে ফি কাটে না।",
        "why_en": "'Instant collateral-free loan, just pay a processing fee first' — "
                  "the loan never comes after you pay. Real lenders don't take a fee "
                  "before approval.",
        "do_bn": "লোন পেতে আগে টাকা দিতে বললে থামুন। লাইসেন্সপ্রাপ্ত ব্যাংক/এনবিএফআই ছাড়া নেবেন না।",
        "do_en": "Stop if a loan asks for money upfront. Only borrow from a licensed "
                 "bank / NBFI.",
        "signals": [r"লোন", r"\bloan\b", r"ঋণ", r"বিনা জামানত", r"collateral[- ]?free",
                    r"instant loan", r"তাৎক্ষণিক (লোন|ঋণ)", r"প্রসেসিং ফি", r"processing fee",
                    r"loan approved", r"লোন অনুমোদন"],
    },
    {
        "key": "mfs_reversal_trick", "weight": 30, "level": "high",
        "name_bn": "বিকাশ/নগদ 'ভুলে টাকা গেছে, ফেরত দিন' কৌশল",
        "name_en": "bKash/Nagad 'sent by mistake, please reverse' trick",
        "why_bn": "'ভুল করে আপনার নম্বরে টাকা পাঠিয়েছি, Send Money করে ফেরত দিন' — আসলে "
                  "কোনো টাকা আসেনি; ভুয়া SMS দেখিয়ে আপনাকে দিয়ে টাকা পাঠিয়ে নেয়।",
        "why_en": "'I sent money to your number by mistake, please Send Money back' — "
                  "no money actually arrived; a fake SMS tricks you into sending real "
                  "money out.",
        "do_bn": "নিজের অ্যাপে ব্যালেন্স যাচাই করুন। সত্যিই এলে অফিসিয়াল চ্যানেলে রিভার্সাল "
                 "করতে বলুন — নিজে Send Money করবেন না।",
        "do_en": "Check your own app balance. If money truly came, ask them to request "
                 "a reversal via the official channel — never Send Money yourself.",
        "signals": [r"ভুল(ে| করে).*পাঠি", r"by mistake.*sen[dt]", r"wrong (number|send)",
                    r"ফেরত (দিন|পাঠান)", r"send ?money.*(back|ফেরত)", r"রিভার্স",
                    r"reversal", r"ক্যাশ ?আউট করে দিন"],
    },
    {
        "key": "send_money_demand", "weight": 20, "level": "medium",
        "name_bn": "টাকা পাঠাতে / ফি দিতে বলা",
        "name_en": "Demand to send money / pay a fee",
        "why_bn": "অচেনা উৎস থেকে টাকা/ফি/চার্জ চাওয়া প্রতারণার সবচেয়ে সাধারণ ধাপ।",
        "why_en": "An unknown source asking you to send money/fee/charge is the most "
                  "common scam step.",
        "do_bn": "অচেনা কাউকে টাকা পাঠাবেন না। পরিচয় ও কারণ স্বাধীনভাবে যাচাই করুন।",
        "do_en": "Don't send money to anyone unknown. Verify who and why independently.",
        "signals": [r"টাকা পাঠা", r"send money", r"ক্যাশ ইন", r"cash in", r"ফি দিন",
                    r"\bfee\b", r"চার্জ দিন", r"পেমেন্ট করুন", r"transfer.*(tk|টাকা)",
                    r"\b\d{3,}\s*(টাকা|tk|taka)\b"],
    },
    {
        "key": "urgency_pressure", "weight": 18, "level": "medium",
        "name_bn": "তাড়াহুড়ার চাপ (এখনই / শেষ সুযোগ)",
        "name_en": "Urgency pressure (act now / last chance)",
        "why_bn": "প্রতারকেরা ভাবার সময় দেয় না — 'এখনই করুন নইলে বন্ধ হয়ে যাবে'। তাড়া "
                  "দেওয়া নিজেই একটা বিপদচিহ্ন।",
        "why_en": "Scammers don't give you time to think — 'do it now or it closes'. "
                  "Being rushed is itself a red flag.",
        "do_bn": "তাড়াহুড়ায় কিছু করবেন না। থামুন, যাচাই করুন, দরকারে পরিবারের সাথে কথা বলুন।",
        "do_en": "Never act in a rush. Pause, verify, and talk to family if needed.",
        "signals": [r"এখনই", r"আজই", r"দ্রুত", r"তাড়াতাড়ি", r"urgent", r"immediately",
                    r"within \d+ ?(hour|minute|min|ঘণ্টা|মিনিট)", r"শেষ সুযোগ", r"last chance",
                    r"আজকের মধ্যে", r"expire.*(today|soon)"],
    },
    {
        "key": "suspicious_link", "weight": 20, "level": "medium",
        "name_bn": "সন্দেহজনক / শর্ট লিংক",
        "name_en": "Suspicious / shortened link",
        "why_bn": "শর্ট লিংক বা অচেনা ডোমেইন আসল সাইটের নকল হতে পারে (ফিশিং)। ক্লিক করলে "
                  "লগইন তথ্য চুরি হয়।",
        "why_en": "A shortened link or odd domain may be a fake copy of the real site "
                  "(phishing). Clicking can steal your login.",
        "do_bn": "লিংকে ক্লিক করবেন না। ঠিকানা নিজে টাইপ করে অফিসিয়াল সাইটে যান।",
        "do_en": "Don't click the link. Type the address yourself to reach the official site.",
        "signals": [],  # dynamic (see below)
    },
    {
        "key": "account_verify_phish", "weight": 22, "level": "medium",
        "name_bn": "অ্যাকাউন্ট 'ভেরিফাই/আপডেট' করতে বলা (ফিশিং)",
        "name_en": "'Verify/update your account' phishing",
        "why_bn": "'আপনার অ্যাকাউন্ট ভেরিফাই/আপডেট করুন নইলে বন্ধ' — লিংকে পাঠিয়ে লগইন "
                  "তথ্য চুরি করার ফাঁদ।",
        "why_en": "'Verify/update your account or it will be closed' — a trap to steal "
                  "your login via a link.",
        "do_bn": "লিংকে লগইন করবেন না। সরাসরি অফিসিয়াল অ্যাপ/সাইট থেকে যাচাই করুন।",
        "do_en": "Don't log in through the link. Check directly in the official app/site.",
        "signals": [r"verify your account", r"update your account", r"অ্যাকাউন্ট (ভেরিফাই|আপডেট|যাচাই)",
                    r"re[- ]?activate", r"পুনরায় চালু", r"kyc.*update", r"তথ্য হালনাগাদ"],
    },
    {
        "key": "mfs_verify_phish", "weight": 24, "level": "high",
        "name_bn": "bKash/Nagad-এর নামে নম্বর/অ্যাকাউন্ট 'যাচাই' করতে বলা",
        "name_en": "MFS-brand 'verify your number/account' phishing",
        "why_bn": "bKash/Nagad/Rocket/Upay-এর নাম ভাঙিয়ে 'আপনার নম্বর/অ্যাকাউন্ট যাচাই "
                  "করুন' বলা হয় — এটি তথ্য বা PIN/OTP হাতানোর ফাঁদ। আসল MFS এভাবে "
                  "ফোনে/মেসেজে যাচাই করতে বলে না।",
        "why_en": "Posing as bKash/Nagad/Rocket/Upay and telling you to 'verify your "
                  "number/account' is a trap to harvest your details or PIN/OTP. A real "
                  "MFS never asks you to verify like this by phone or message.",
        "do_bn": "লিংকে বা মেসেজে কিছু যাচাই করবেন না। নিজের অফিসিয়াল অ্যাপ/হেল্পলাইনে "
                 "নিজে যোগাযোগ করুন।",
        "do_en": "Don't 'verify' anything via a message or link. Reach out yourself "
                 "through the official app/helpline.",
        "signals": [],  # dynamic: MFS brand + a verify-word targeting number/account
    },
]

PATTERN_INDEX = {p["key"]: p for p in PATTERNS}


# ---------------------------------------------------------------------------
# dynamic signals (computed, not regex-only)
# ---------------------------------------------------------------------------

def _dynamic_hits(low):
    """Return (set_of_pattern_keys, list_of_extra_notes) for non-regex signals."""
    hits = set()
    extra = {}
    urls = URL.findall(low)
    if urls:
        if any(s in low for s in SHORTENERS) or "http://" in low:
            hits.add("suspicious_link")
            extra["suspicious_link"] = True
        else:
            # plain link — mild; still flag suspicious_link but low
            hits.add("suspicious_link")
            extra["suspicious_link"] = False
    # MFS-brand impersonation asking to "verify/যাচাই" a number or account:
    # brand + a verify-word + a number/account target. This is a known
    # credential-harvest phishing tactic, so it should never land at 'safe'.
    if any(m in low for m in MFS):
        verify_word = re.search(r"verify|ভেরিফাই|যাচাই|confirm|নিশ্চিত", low)
        target = re.search(
            r"number|নম্বর|নাম্বার|account|অ্যাকাউন্ট|একাউন্ট|wallet|ওয়ালেট|\d{4,}",
            low)
        if verify_word and target:
            hits.add("mfs_verify_phish")
    return hits, extra


# ---------------------------------------------------------------------------
# the detector
# ---------------------------------------------------------------------------

def _matched_patterns(text):
    """Return the list of matched pattern dicts (library entries) for `text`,
    each annotated with how it matched. Deterministic, order = PATTERNS order."""
    low = _despace_latin(normalize(text))
    dyn_keys, dyn_extra = _dynamic_hits(low)
    matched = []
    for p in PATTERNS:
        key = p["key"]
        if p["signals"]:
            if _any(low, p["signals"]):
                matched.append((p, None))
        elif key in dyn_keys:
            matched.append((p, dyn_extra.get(key)))
    # MFS + a long number present strengthens money/reversal/PIN context
    mfs_money = any(m in low for m in MFS) and re.search(r"\d{4,}", low)
    return matched, mfs_money, low


def check_message(text, lang="bn"):
    """Analyse a pasted suspicious message.

    Returns a dict:
      {score, verdict, level, label, emoji,
       patterns: [{key, name, level, why, do}],   # only what actually matched
       advice, summary}
    All user-facing strings localised to `lang` ('bn'|'en').
    `verdict`: 'scam' | 'suspicious' | 'safe' (machine value; label is localised).
    """
    if not (text or "").strip():
        return {
            "score": 0, "verdict": "safe", "level": "low",
            "label": pick(lang, "খালি", "Empty"), "emoji": "✅",
            "patterns": [], "advice": pick(lang, "মেসেজ দিন।", "Please enter a message."),
            "summary": pick(lang, "কিছু লেখা হয়নি।", "Nothing entered."),
        }

    matched, mfs_money, low = _matched_patterns(text)

    score = 0
    out_patterns = []
    for p, extra in matched:
        w = p["weight"]
        # a plain (non-shortened) link is milder than a shortener/http link
        if p["key"] == "suspicious_link" and extra is False:
            w = 8
        score += w
        out_patterns.append({
            "key": p["key"],
            "name": pick(lang, p["name_bn"], p["name_en"]),
            "level": p["level"],
            "why": pick(lang, p["why_bn"], p["why_en"]),
            "do": pick(lang, p["do_bn"], p["do_en"]),
        })

    if mfs_money:
        score += 10
        out_patterns.append({
            "key": "mfs_number_mentioned", "level": "medium",
            "name": pick(lang, "মোবাইল ব্যাংকিং নম্বর/লেনদেন উল্লেখ",
                         "Mobile-banking number / transaction mentioned"),
            "why": pick(lang, "মেসেজে bKash/Nagad সংক্রান্ত নম্বর/লেনদেন আছে — অর্থ "
                              "আদায়ের চেষ্টা হতে পারে।",
                        "The message mentions an MFS number/transaction — it may be an "
                        "attempt to extract money."),
            "do": pick(lang, "নিজের অ্যাপে যাচাই করুন; অচেনা অনুরোধে সাড়া দেবেন না।",
                       "Verify in your own app; don't respond to unknown requests."),
        })

    score = min(100, score)

    # verdict thresholds (any 'high'-level match floors us at 'suspicious')
    has_high = any(op.get("level") == "high" for op in out_patterns)
    if score >= 55 or (has_high and score >= 40):
        verdict, level, emoji = "scam", "high", "⚠️"
        label = pick(lang, "প্রতারণা হতে পারে", "Likely a scam")
    elif score >= 20 or has_high:
        verdict, level, emoji = "suspicious", "medium", "🟡"
        label = pick(lang, "সন্দেহজনক", "Suspicious")
    else:
        verdict, level, emoji = "safe", "low", "✅"
        label = pick(lang, "স্পষ্ট প্রতারণার লক্ষণ নেই", "No clear scam signs")

    advice = {
        "scam": pick(lang,
            "এটি প্রতারণা হতে পারে। PIN/OTP/পাসওয়ার্ড দেবেন না, টাকা পাঠাবেন না, "
            "লিংকে ক্লিক করবেন না। পরিবারের বড়দের সাবধান করুন।",
            "This may be a scam. Don't share PIN/OTP/password, don't send money, don't "
            "click links. Warn the elders in your family."),
        "suspicious": pick(lang,
            "সাবধান থাকুন। পরিচয় ও কারণ স্বাধীনভাবে যাচাই না করে কোনো তথ্য বা টাকা দেবেন না।",
            "Be careful. Don't share any info or money without independently verifying "
            "who is asking and why."),
        "safe": pick(lang,
            "স্পষ্ট প্রতারণার লক্ষণ পাওয়া যায়নি। তবুও অচেনা উৎস হলে সতর্ক থাকুন — "
            "নিশ্চিত হতে না পারলে যাচাই করুন।",
            "No clear scam signs found. Still, stay alert with unknown sources — "
            "verify if you are not sure."),
    }[verdict]

    n = len(out_patterns)
    summary = pick(lang,
        f"{n}টি সতর্কতা-সংকেত মিলেছে।" if n else "কোনো সতর্কতা-সংকেত মেলেনি।",
        f"{n} warning signal(s) matched." if n else "No warning signals matched.")

    return {
        "score": score, "verdict": verdict, "level": level, "label": label,
        "emoji": emoji, "patterns": out_patterns, "advice": advice, "summary": summary,
    }


# ---------------------------------------------------------------------------
# library browsing (for the "learn" tab in the UI — teaches the tactics)
# ---------------------------------------------------------------------------

def library(lang="bn"):
    """The full curated scam-pattern library, localised — for an educational
    'know these scams' list in the app (GASA-style awareness)."""
    return [
        {
            "key": p["key"], "level": p["level"],
            "name": pick(lang, p["name_bn"], p["name_en"]),
            "why": pick(lang, p["why_bn"], p["why_en"]),
            "do": pick(lang, p["do_bn"], p["do_en"]),
        }
        for p in PATTERNS
    ]


def family_alert_payload(reporter_name, result, lang="bn"):
    """Build the family-alert body when a member reports a scam they received.
    The integrator pushes this to family members (foreground-poll now, push when
    Firebase is added). Cites the top matched pattern type — never fabricated."""
    top = result["patterns"][0]["name"] if result.get("patterns") else pick(
        lang, "সন্দেহজনক বার্তা", "a suspicious message")
    return {
        "kind": "scam_report",
        "verdict": result["verdict"],
        "title": pick(lang, "পরিবারে প্রতারণার সতর্কতা", "Scam alert in your family"),
        "body": pick(lang,
            f"{reporter_name} একটি সম্ভাব্য প্রতারণার বার্তা রিপোর্ট করেছেন "
            f"(ধরন: {top})। আপনিও সতর্ক থাকুন।",
            f"{reporter_name} reported a possible scam message (type: {top}). "
            f"Please stay alert too."),
    }
