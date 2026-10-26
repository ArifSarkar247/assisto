"""
remittance.py — PURE maths for Budget & Remittance (flag budget_remittance).

The RECEIVER side: money a family in Bangladesh gets from a relative abroad,
and the family budget made from it. No Django imports at module load; every
function takes plain dicts so it is tested in isolation. Money is integer
POISHA internally (core.logic.budget.to_poisha) — no float drift.

Only LEGAL channels exist here (bank, bKash, Nagad, Rocket, Western Union,
MoneyGram, other). There is no hundi option and none is ever suggested.
"""
from collections import defaultdict
from datetime import date

from .budget import to_poisha, from_poisha

CHANNELS = ("bank", "bkash", "nagad", "rocket", "western_union", "moneygram", "other")
CHANNEL_LABELS = {
    "bank": ("ব্যাংক", "Bank"),
    "bkash": ("বিকাশ", "bKash"),
    "nagad": ("নগদ", "Nagad"),
    "rocket": ("রকেট", "Rocket"),
    "western_union": ("ওয়েস্টার্ন ইউনিয়ন", "Western Union"),
    "moneygram": ("মানিগ্রাম", "MoneyGram"),
    "other": ("অন্যান্য", "Other"),
}
# Currencies a Bangladeshi family most often receives (any 3-letter ISO code
# is accepted; this is only the picker's order). BDT = sent already in taka.
CURRENCIES = ("SAR", "AED", "QAR", "KWD", "OMR", "BHD", "MYR", "SGD", "USD",
              "GBP", "EUR", "JPY", "KRW", "AUD", "CAD", "BDT")

# Family budget categories (owner order). Stored as the existing Budget
# model's `category` (plan) and Transaction.category (actual spending).
CATEGORIES = ("food", "rent", "education", "health", "savings", "loan", "other")
CATEGORY_LABELS = {
    "food": ("খাবার", "Food"),
    "rent": ("ভাড়া", "Rent"),
    "education": ("পড়াশোনা", "Education"),
    "health": ("ওষুধ ও চিকিৎসা", "Medicine"),
    "savings": ("সঞ্চয়", "Savings"),
    "loan": ("ঋণ / কিস্তি", "Loan or EMI"),
    "other": ("অন্যান্য", "Other"),
}
# Words people already type as a category in the Money module that belong to
# one of ours, so their existing expenses count as the "actual" too.
_SYNONYMS = {
    "food": {"food", "groceries", "grocery", "bazar", "bajar", "dining",
             "খাবার", "বাজার", "খাওয়া", "খাওয়া", "মুদি"},
    "rent": {"rent", "house rent", "bhara", "ভাড়া", "ভাড়া", "বাসা ভাড়া", "বাড়ি ভাড়া"},
    "education": {"education", "school", "tuition", "college", "পড়াশোনা", "পড়াশোনা",
                  "স্কুল", "শিক্ষা", "টিউশন", "কলেজ"},
    "health": {"health", "medicine", "medical", "doctor", "hospital", "ওষুধ",
               "চিকিৎসা", "ডাক্তার", "হাসপাতাল"},
    "savings": {"savings", "saving", "dps", "সঞ্চয়", "সঞ্চয়", "জমা"},
    "loan": {"loan", "emi", "installment", "kisti", "ঋণ", "কিস্তি", "লোন"},
}
_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
BN_MONTHS = ("জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই",
             "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর")
EN_MONTHS = ("January", "February", "March", "April", "May", "June", "July",
             "August", "September", "October", "November", "December")


def category_of(raw):
    """A transaction's free-text category -> one of CATEGORIES."""
    s = (raw or "").strip().lower()
    if s in CATEGORIES:
        return s
    for key, words in _SYNONYMS.items():
        if s in words:
            return key
    return "other"


def month_key(d):
    return "%04d-%02d" % (d.year, d.month)


def month_bounds(month):
    y, m = int(month[:4]), int(month[5:7])
    first = date(y, m, 1)
    nxt = date(y + (m // 12), m % 12 + 1, 1)
    return first, nxt


def valid_month(s):
    try:
        y, m = int(str(s)[:4]), int(str(s)[5:7])
        return len(str(s)) == 7 and str(s)[4] == "-" and 2000 <= y <= 2100 and 1 <= m <= 12
    except (TypeError, ValueError):
        return False


# ------------------------------------------------------------- formatting
def digits(lang, s):
    s = str(s)
    return s.translate(_BN_DIGITS) if lang == "bn" else s


def taka(lang, poisha):
    """৳1,23,456 (Indian grouping, no paisa when whole) in the UI digits."""
    neg = poisha < 0
    p = abs(int(poisha))
    whole, frac = divmod(p, 100)
    s = str(whole)
    if len(s) > 3:
        head, tail = s[:-3], s[-3:]
        parts = []
        while len(head) > 2:
            parts.insert(0, head[-2:])
            head = head[:-2]
        if head:
            parts.insert(0, head)
        s = ",".join(parts + [tail])
    if frac:
        s += ".%02d" % frac
    return ("-" if neg else "") + "৳" + digits(lang, s)


def month_label(lang, month):
    y, m = int(month[:4]), int(month[5:7])
    if lang == "bn":
        return "%s %s" % (BN_MONTHS[m - 1], digits("bn", y))
    return "%s %d" % (EN_MONTHS[m - 1], y)


def label(lang, table, key):
    bn, en = table.get(key, (key, key))
    return bn if lang == "bn" else en


# ------------------------------------------------------------- maths
def entries_total(entries):
    return sum(to_poisha(e.get("taka")) for e in entries)


def plan_vs_actual(plan, txns, month):
    """plan {key: amount} + the user's REAL transactions -> one line per
    category: plan, actual (expenses this month), percent and state
    (none / ok / near (>=80%) / over (>100%)) — the existing budget's 80/100
    warnings."""
    first, nxt = month_bounds(month)
    spent = defaultdict(int)
    for t in txns:
        if t.get("kind") != "expense":
            continue
        d = t.get("date")
        if isinstance(d, str):
            try:
                d = date.fromisoformat(d[:10])
            except ValueError:
                continue
        if not d or not (first <= d < nxt):
            continue
        spent[category_of(t.get("category"))] += to_poisha(t.get("amount"))
    lines = []
    for k in CATEGORIES:
        p = to_poisha(plan.get(k))
        a = spent.get(k, 0)
        pct = int(round(a * 100 / p)) if p else (100 if a else 0)
        if not p:
            state = "none"
        elif a > p:
            state = "over"
        elif a * 100 >= p * 80:
            state = "near"
        else:
            state = "ok"
        lines.append({"key": k, "plan_p": p, "actual_p": a, "pct": pct, "state": state})
    return lines


def expected_status(today, month, expected_p, expected_day, received_p):
    """Where this month's expected money stands.
    none     — no expected amount set
    future   — the month asked about has not started
    arrived  — received >= expected
    partial  — something came, less than expected
    waiting  — nothing yet, the expected day has not passed
    missing  — nothing yet and the expected day has passed (remind ONCE)"""
    if not expected_p or not expected_day:
        return "none"
    first, nxt = month_bounds(month)
    if today < first:
        return "future"
    if received_p >= expected_p:
        return "arrived"
    if received_p > 0:
        return "partial"
    last_day = (nxt - first).days
    due = date(first.year, first.month, min(int(expected_day), last_day))
    if today <= due:
        return "waiting"
    return "missing"


def due_date(month, expected_day):
    first, nxt = month_bounds(month)
    return date(first.year, first.month, min(int(expected_day), (nxt - first).days))


def should_alert(status, month, alerted_month):
    """The 'not arrived' reminder fires at most once per month."""
    return status == "missing" and alerted_month != month


def year_view(entries, year, savings_p_by_month):
    """entries: decrypted [{received_on, taka, sender_name, channel}] (any
    year); savings_p_by_month {YYYY-MM: poisha moved to savings}."""
    months = [0] * 12
    by_sender = defaultdict(lambda: [0, 0])
    by_channel = defaultdict(lambda: [0, 0])
    n = 0
    for e in entries:
        d = e.get("received_on")
        if isinstance(d, str):
            try:
                d = date.fromisoformat(d[:10])
            except ValueError:
                continue
        if not d or d.year != year:
            continue
        p = to_poisha(e.get("taka"))
        months[d.month - 1] += p
        name = (e.get("sender_name") or "").strip() or "?"
        by_sender[name][0] += p
        by_sender[name][1] += 1
        ch = e.get("channel") if e.get("channel") in CHANNELS else "other"
        by_channel[ch][0] += p
        by_channel[ch][1] += 1
        n += 1
    total = sum(months)
    savings = sum(v for k, v in savings_p_by_month.items() if k.startswith("%04d-" % year))
    return {
        "year": year,
        "total_p": total,
        "count": n,
        "months_p": months,
        "by_sender": sorted(({"name": k, "total_p": v[0], "count": v[1]}
                             for k, v in by_sender.items()),
                            key=lambda r: (-r["total_p"], r["name"])),
        "by_channel": sorted(({"key": k, "total_p": v[0], "count": v[1]}
                              for k, v in by_channel.items()),
                             key=lambda r: (-r["total_p"], r["key"])),
        "savings_p": savings,
        "avg_month_p": total // len([m for m in months if m]) if any(months) else 0,
    }


def report_text(lang, month, received_p, count, lines, goal=None):
    """The plain monthly summary the user may share with the sender (only when
    they tap Share). `lines` = plan_vs_actual output; goal = {title,
    target_p, saved_p} or None."""
    bn = lang == "bn"
    out = []
    out.append(("%s-এর হিসাব" if bn else "Family budget — %s") % month_label(lang, month))
    if bn:
        out.append("এসেছে: %s (%s বার)" % (taka(lang, received_p), digits(lang, count)))
    else:
        out.append("Received: %s (%d %s)" % (taka(lang, received_p), count,
                                              "time" if count == 1 else "times"))
    spent = [ln for ln in lines if ln["actual_p"] > 0]
    total = sum(ln["actual_p"] for ln in lines)
    if spent:
        out.append("কোথায় গেল:" if bn else "Where it went:")
        for ln in spent:
            row = "• %s: %s" % (label(lang, CATEGORY_LABELS, ln["key"]), taka(lang, ln["actual_p"]))
            if ln["plan_p"]:
                row += (" (পরিকল্পনা %s)" if bn else " (plan %s)") % taka(lang, ln["plan_p"])
            out.append(row)
        out.append(("মোট খরচ: %s" if bn else "Total spent: %s") % taka(lang, total))
    else:
        out.append("এ মাসে এখনো কোনো খরচ লেখা হয়নি।" if bn else "No spending written down yet this month.")
    left = received_p - total
    out.append(("হাতে আছে: %s" if bn else "Left: %s") % taka(lang, left))
    if goal and goal.get("target_p"):
        pct = int(goal["saved_p"] * 100 // goal["target_p"]) if goal["target_p"] else 0
        if bn:
            out.append("সঞ্চয়-লক্ষ্য \"%s\": %s / %s (%s%%)" % (
                goal.get("title") or "সঞ্চয়", taka(lang, goal["saved_p"]),
                taka(lang, goal["target_p"]), digits(lang, pct)))
        else:
            out.append("Savings goal \"%s\": %s of %s (%d%%)" % (
                goal.get("title") or "Savings", taka(lang, goal["saved_p"]),
                taka(lang, goal["target_p"]), pct))
    out.append("— Assisto")
    return "\n".join(out)


def p2s(p):
    """poisha -> '1234.50' string for the API."""
    return str(from_poisha(p))
