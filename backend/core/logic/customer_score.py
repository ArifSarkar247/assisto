"""
customer_score.py — TRANSPARENT customer / lead score for a shop (crmauto).
PURE: no Django, no clock, no AI, no network.

Not a black box: every point comes from ONE written rule the owner can read
(RULES, served as-is to the app), and every score returns the list of rules
that fired with the real value behind each ("bought 12 days ago +30").
Nothing is guessed: a signal we do not have scores 0, never an estimate.

Signals (all from the shop's own records):
  days_since_last   days since the latest purchase (None = never bought)
  purchases         purchases (sales) in the last 365 days
  spend_poisha      total spend in the last 365 days (poisha)
  due_poisha        what the customer owes in the khata now
  returns           returned / cancelled online orders in the last 365 days
  replied_recent    replied to a shop message in the last 30 days
  open_quote        has an open (issued / viewed) price quote
  last_rating       latest delivery rating 1..5 (None = never rated)
  opted_out         said STOP — shown as "do not message", never scored
"""

HOT, WARM, COLD = "hot", "warm", "cold"
HOT_MIN, WARM_MIN = 70, 40

# id, bn, en — the {v} is the real value. Points per tier are in the table
# itself so the app can show the rule book exactly as the code applies it.
RULES = [
    {"id": "recent_30", "points": 30, "bn": "গত ৩০ দিনে কিনেছেন", "en": "Bought in the last 30 days"},
    {"id": "recent_90", "points": 15, "bn": "গত ৩১–৯০ দিনে কিনেছেন", "en": "Bought 31-90 days ago"},
    {"id": "freq_5", "points": 25, "bn": "এক বছরে ৫ বা বেশি বার কিনেছেন", "en": "5+ purchases in a year"},
    {"id": "freq_3", "points": 18, "bn": "এক বছরে ৩–৪ বার কিনেছেন", "en": "3-4 purchases in a year"},
    {"id": "freq_2", "points": 10, "bn": "এক বছরে ২ বার কিনেছেন", "en": "2 purchases in a year"},
    {"id": "freq_1", "points": 5, "bn": "এক বছরে ১ বার কিনেছেন", "en": "1 purchase in a year"},
    {"id": "spend_20k", "points": 20, "bn": "এক বছরে ৳২০,০০০ বা বেশি কিনেছেন", "en": "Spent ৳20,000+ in a year"},
    {"id": "spend_5k", "points": 12, "bn": "এক বছরে ৳৫,০০০–১৯,৯৯৯ কিনেছেন", "en": "Spent ৳5,000-19,999 in a year"},
    {"id": "spend_1k", "points": 6, "bn": "এক বছরে ৳১,০০০–৪,৯৯৯ কিনেছেন", "en": "Spent ৳1,000-4,999 in a year"},
    {"id": "replied", "points": 10, "bn": "গত ৩০ দিনে দোকানের মেসেজে উত্তর দিয়েছেন", "en": "Replied to the shop in the last 30 days"},
    {"id": "open_quote", "points": 10, "bn": "খোলা দামের প্রস্তাব আছে (আগ্রহী)", "en": "Has an open price quote (interested)"},
    {"id": "due", "points": -10, "bn": "খাতায় ৳১০০ বা বেশি বাকি", "en": "Owes ৳100+ in the khata"},
    {"id": "returns", "points": -15, "bn": "এক বছরে অর্ডার ফেরত/বাতিল", "en": "Returned / cancelled an order this year"},
    {"id": "low_rating", "points": -10, "bn": "শেষ মতামত ১ বা ২", "en": "Last rating was 1 or 2"},
]
_BY_ID = {r["id"]: r for r in RULES}


def _bn(s):
    return "".join(chr(0x09E6 + int(c)) if c.isdigit() else c for c in str(s))


def _num(v, lang):
    return _bn(v) if lang != "en" else str(v)


def _taka(poisha, lang):
    s = "{:,}".format(int(poisha or 0) // 100)
    return _bn(s) if lang != "en" else s


def _fire(rule_id, value_text):
    r = _BY_ID[rule_id]
    return {"id": rule_id, "points": r["points"], "value": value_text}


def score(sig, lang="bn"):
    """sig: the signals dict above -> {score, band, parts, do_not_message}.
    parts: [{id, points, value, rule}] — rule = the rule text in `lang`."""
    s = sig or {}
    parts = []
    d = s.get("days_since_last")
    if d is not None:
        if d <= 30:
            parts.append(_fire("recent_30", _num(d, lang)))
        elif d <= 90:
            parts.append(_fire("recent_90", _num(d, lang)))
    n = int(s.get("purchases") or 0)
    if n >= 5:
        parts.append(_fire("freq_5", _num(n, lang)))
    elif n >= 3:
        parts.append(_fire("freq_3", _num(n, lang)))
    elif n == 2:
        parts.append(_fire("freq_2", _num(n, lang)))
    elif n == 1:
        parts.append(_fire("freq_1", _num(n, lang)))
    sp = int(s.get("spend_poisha") or 0)
    if sp >= 20000 * 100:
        parts.append(_fire("spend_20k", _taka(sp, lang)))
    elif sp >= 5000 * 100:
        parts.append(_fire("spend_5k", _taka(sp, lang)))
    elif sp >= 1000 * 100:
        parts.append(_fire("spend_1k", _taka(sp, lang)))
    if s.get("replied_recent"):
        parts.append(_fire("replied", ""))
    if s.get("open_quote"):
        parts.append(_fire("open_quote", ""))
    due = int(s.get("due_poisha") or 0)
    if due >= 100 * 100:
        parts.append(_fire("due", _taka(due, lang)))
    if int(s.get("returns") or 0) > 0:
        parts.append(_fire("returns", _num(int(s["returns"]), lang)))
    rt = s.get("last_rating")
    if rt is not None and int(rt) <= 2:
        parts.append(_fire("low_rating", _num(int(rt), lang)))
    total = max(0, min(100, sum(p["points"] for p in parts)))
    band = HOT if total >= HOT_MIN else WARM if total >= WARM_MIN else COLD
    for p in parts:
        p["rule"] = _BY_ID[p["id"]]["en" if lang == "en" else "bn"]
    return {"score": total, "band": band, "parts": parts,
            "do_not_message": bool(s.get("opted_out"))}


def rule_book(lang="bn"):
    """The full rule table exactly as score() applies it."""
    return {"rules": [{"id": r["id"], "points": r["points"],
                       "text": r["en" if lang == "en" else "bn"]} for r in RULES],
            "bands": {HOT: HOT_MIN, WARM: WARM_MIN, COLD: 0}, "max": 100}


def max_possible():
    """Highest reachable score (one tier per group) — sanity check: <= 100."""
    return 30 + 25 + 20 + 10 + 10
