"""
money_parse.py — Bangladeshi transaction SMS / notification parser (no AI key).

Takes a raw SMS/notification body from a mobile-money wallet (bKash, Nagad,
Rocket, Upay) or a bank, and extracts a structured transaction:

    {
      "channel": "bkash"|"nagad"|"rocket"|"upay"|"bank"|"unknown",
      "type": "debit"|"credit"|None,     # debit = money leaving, credit = coming in
      "amount": Decimal|None,
      "fee": Decimal|None,               # charge, if the SMS states one
      "balance": Decimal|None,           # wallet/account balance after txn
      "counterparty": str|None,          # name / merchant / account the money moved to/from
      "counterparty_number": str|None,   # phone / account number if present
      "ref": str|None,                   # TrxID / Ref / transaction id
      "category_guess": str|None,        # best-guess spending category
      "category_confidence": float,      # 0..1
      "date": str|None,                  # ISO date if the SMS carries one
      "raw": str,                        # original body (trimmed)
      "parsed": bool,                    # True when amount + type both found
    }

Everything is deterministic and import-light (only stdlib) so it is trivially
unit-testable and safe to reason about in isolation. Django model touches (the
"learn from corrections" store) are late-bound inside functions.

Design notes for Bangladeshi formats:
  - Amounts appear as "Tk 1,234.50", "BDT 1234", "৳500", "Taka 2,000".
  - bKash:  "You have received Tk 500.00 from 01712345678. ... TrxID 9F2A1B3C"
            "Cash Out Tk 1,000.00 to 01800000000 successful. Fee Tk 18.50 ..."
            "Payment Tk 250.00 to MERCHANT ... Balance Tk 812.33"
  - Nagad:  "Money Received. Amount: Tk 1,000.00 ... TxnID: ABC123"
            "Cash Out Tk 500 ... Balance: Tk 312.00"
  - Rocket: "Tk500.0 received from A/C:017... Fee:Tk0.0 Bal:Tk1,234.0 TxnId:XYZ"
  - Bank:   "Your A/C ...1234 debited BDT 2,500.00 at MERCHANT on 12-OCT-26.
             Avl Bal BDT 48,210.00"
Bangla digits (০-৯) are normalised before any regex runs.
"""
import re
from decimal import Decimal, InvalidOperation

# ---------------------------------------------------------------------------
# digit / number normalisation (handles Bangla numerals + separators)
# ---------------------------------------------------------------------------

_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def normalize_digits(s):
    """Convert Bangla numerals to ASCII; leave everything else alone."""
    return (s or "").translate(_BN_DIGITS)


def _to_decimal(s):
    """Parse a money token like '1,234.50' / '1234' / '৳500' to Decimal."""
    if s is None:
        return None
    t = normalize_digits(str(s))
    t = re.sub(r"[^\d.]", "", t.replace(",", ""))
    if t in ("", "."):
        return None
    try:
        return Decimal(t)
    except (InvalidOperation, ValueError):
        return None


# ---------------------------------------------------------------------------
# channel detection
# ---------------------------------------------------------------------------

_CHANNELS = [
    ("bkash", re.compile(r"\bbkash\b", re.I)),
    ("nagad", re.compile(r"\bnagad\b", re.I)),
    ("rocket", re.compile(r"\brocket\b|\bdbbl\b", re.I)),
    ("upay", re.compile(r"\bupay\b", re.I)),
]


def detect_channel(sender, body):
    """Prefer the SMS sender id, then fall back to keywords in the body."""
    s = (sender or "").lower()
    for name, _ in _CHANNELS:
        if name in s:
            return name
    b = body or ""
    for name, rx in _CHANNELS:
        if rx.search(b):
            return name
    # heuristics for banks: A/C + debited/credited
    if re.search(r"\bA/C\b|\bAC\b|account", body or "", re.I) and \
       re.search(r"debit|credit|withdraw", body or "", re.I):
        return "bank"
    return "unknown"


# ---------------------------------------------------------------------------
# type (debit / credit) detection
# ---------------------------------------------------------------------------

_CREDIT_WORDS = re.compile(
    r"received|cash\s*in|deposit|credited|add\s*money|refund|has\s*received|"
    r"you\s*have\s*received|salary|disbursed",
    re.I,
)
_DEBIT_WORDS = re.compile(
    r"cash\s*out|payment|paid|sent|send\s*money|withdraw|debited|purchase|"
    r"bill\s*pay|recharge|transferred\s*to|buy",
    re.I,
)


def detect_type(body):
    b = body or ""
    credit = bool(_CREDIT_WORDS.search(b))
    debit = bool(_DEBIT_WORDS.search(b))
    if credit and not debit:
        return "credit"
    if debit and not credit:
        return "debit"
    # both or neither — use nearest keyword to the word "Tk"/amount: prefer debit
    if debit and credit:
        # whichever word appears first wins
        cm = _CREDIT_WORDS.search(b)
        dm = _DEBIT_WORDS.search(b)
        return "credit" if cm.start() < dm.start() else "debit"
    return None


# ---------------------------------------------------------------------------
# field extraction
# ---------------------------------------------------------------------------

# amount: a currency marker (Tk/BDT/Taka/৳) hugging a number, in either order.
_AMOUNT_RX = re.compile(
    r"(?:(?:tk|bdt|taka|৳)\s*([\d,]+(?:\.\d+)?)|([\d,]+(?:\.\d+)?)\s*(?:tk|bdt|taka|৳))",
    re.I,
)
_FEE_RX = re.compile(r"(?:fee|charge|chrg)[:\s]*(?:tk|bdt|৳)?\s*([\d,]+(?:\.\d+)?)", re.I)
_BAL_RX = re.compile(
    r"(?:bal(?:ance)?|avl\s*bal|available\s*balance)[:\s]*(?:tk|bdt|৳)?\s*([\d,]+(?:\.\d+)?)",
    re.I,
)
_REF_RX = re.compile(r"(?:trx\s*id|txn\s*id|trxid|txnid|ref(?:erence)?\s*(?:no)?)[:\s.]*([a-z0-9]{4,})", re.I)
_PHONE_RX = re.compile(r"\b(01[3-9]\d{8})\b")
_ACC_RX = re.compile(r"A/C[:\s]*[xX*]*(\d{3,})", re.I)
# "from NAME", "to NAME", "to MERCHANT" — stop at punctuation / currency / digits run.
_PARTY_RX = re.compile(
    r"\b(?:from|to|at)\s+([A-Za-z][A-Za-z .&'\-]{1,38}?)(?=[.,;]|\s+(?:on|tk|bdt|৳|trx|txn|ref|bal|fee|successful|$))",
    re.I,
)
# dates like 12-OCT-26, 12/10/2026, 2026-10-12
_DATE_RX = re.compile(
    r"(\d{4}-\d{2}-\d{2})|(\d{1,2})[-/](\d{1,2}|[A-Za-z]{3})[-/](\d{2,4})"
)

_MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], start=1)}


def _parse_date(body):
    m = _DATE_RX.search(normalize_digits(body or ""))
    if not m:
        return None
    if m.group(1):
        return m.group(1)
    d, mon, y = m.group(2), m.group(3).lower(), m.group(4)
    mm = _MONTHS.get(mon[:3]) if not mon.isdigit() else int(mon)
    if not mm:
        return None
    if len(y) == 2:
        y = "20" + y
    try:
        return f"{int(y):04d}-{int(mm):02d}-{int(d):02d}"
    except ValueError:
        return None


def _amounts(body):
    """All amount tokens in order of appearance (value, start-index)."""
    out = []
    for m in _AMOUNT_RX.finditer(normalize_digits(body or "")):
        val = _to_decimal(m.group(1) or m.group(2))
        if val is not None:
            out.append((val, m.start()))
    return out


def parse_sms(body, sender=""):
    """Main entry point. Parse one raw SMS/notification body into a txn dict."""
    raw = (body or "").strip()
    norm = normalize_digits(raw)
    channel = detect_channel(sender, norm)
    txn_type = detect_type(norm)

    fee = _to_decimal((_FEE_RX.search(norm) or [None, None])[1]) if _FEE_RX.search(norm) else None
    bal = _to_decimal(_BAL_RX.search(norm).group(1)) if _BAL_RX.search(norm) else None

    # amount = first currency token that is NOT the fee/balance value.
    amount = None
    for val, _ in _amounts(norm):
        if (fee is not None and val == fee) or (bal is not None and val == bal):
            continue
        amount = val
        break

    ref = None
    rm = _REF_RX.search(norm)
    if rm:
        ref = rm.group(1).upper()

    party = None
    pm = _PARTY_RX.search(raw)  # names keep their original casing
    if pm:
        party = pm.group(1).strip().rstrip(".")

    number = None
    phm = _PHONE_RX.search(norm)
    if phm:
        number = phm.group(1)
    else:
        acm = _ACC_RX.search(norm)
        if acm:
            number = "AC" + acm.group(1)

    cat, conf = guess_category(norm, party, txn_type, channel)

    return {
        "channel": channel,
        "type": txn_type,
        "amount": amount,
        "fee": fee,
        "balance": bal,
        "counterparty": party,
        "counterparty_number": number,
        "ref": ref,
        "category_guess": cat,
        "category_confidence": conf,
        "date": _parse_date(norm),
        "raw": raw,
        "parsed": bool(amount is not None and txn_type is not None),
    }


# ---------------------------------------------------------------------------
# category guesser (+ learn-from-corrections hook)
# ---------------------------------------------------------------------------

# keyword -> category. Bilingual keys so bn merchant SMS also match. The engine
# maps these internal slugs to display names in money_engine.CATEGORY_LABELS.
_CATEGORY_RULES = [
    ("salary", ["salary", "payroll", "betōn", "beton", "বেতন", "disbursed"]),
    ("food", ["food", "restaurant", "cafe", "foodpanda", "hungrynaki", "khabar", "খাবার", "hotel"]),
    ("transport", ["uber", "pathao", "cng", "bus", "train", "fuel", "petrol", "octane",
                   "transport", "jatayat", "যাতায়াত", "rickshaw", "taxi"]),
    ("mobile", ["recharge", "topup", "top up", "flexiload", "minute", "mb", "data pack",
                "gp", "robi", "banglalink", "airtel", "teletalk"]),
    ("utility", ["electric", "desco", "dpdc", "wasa", "gas", "titas", "bill pay",
                 "utility", "bidyut", "বিদ্যুৎ", "internet", "wifi", "isp"]),
    ("shopping", ["daraz", "shop", "store", "mart", "bazar", "bazaar", "purchase",
                  "shopping", "kena", "কেনা", "fashion", "clothes"]),
    ("health", ["pharmacy", "medicine", "hospital", "clinic", "doctor", "lab",
                "diagnostic", "osudh", "ঔষধ", "medic"]),
    ("education", ["school", "college", "university", "tuition", "coaching",
                   "exam fee", "admission", "education"]),
    ("rent", ["rent", "bhara", "ভাড়া", "house rent", "flat"]),
    ("sendmoney", ["send money", "cash out", "transfer", "received", "cash in"]),
]

# default label when nothing matches
_UNCATEGORIZED = "uncategorized"


def guess_category(body, counterparty, txn_type, channel):
    """Return (category_slug, confidence 0..1). Learned corrections win first;
    then keyword rules; then a weak channel/type default."""
    text = (normalize_digits(body or "") + " " + (counterparty or "")).lower()

    # 1) learned corrections (late-bound; safe if DB absent)
    learned = _lookup_learned(text, counterparty)
    if learned:
        return learned, 0.95

    # 2) keyword rules
    for slug, kws in _CATEGORY_RULES:
        for kw in kws:
            if kw in text:
                # a salary rule only makes sense for credits
                if slug == "salary" and txn_type == "debit":
                    continue
                return slug, 0.8

    # 3) weak defaults
    if txn_type == "credit":
        return "income", 0.3
    return _UNCATEGORIZED, 0.2


# -- learn-from-corrections store ------------------------------------------
# In-memory fallback so the parser works even without a DB (tests, offline).
# key = a normalised merchant/counterparty token -> chosen category slug.
_LEARNED_MEM = {}


def _norm_key(counterparty, text=""):
    base = (counterparty or "").strip().lower()
    if base:
        return re.sub(r"\s+", " ", base)
    # fall back to the first merchant-ish word in the text
    m = re.search(r"\b(?:at|to)\s+([a-z][a-z0-9 ]{2,20})", text)
    return m.group(1).strip() if m else ""


def _lookup_learned(text, counterparty):
    key = _norm_key(counterparty, text)
    if not key:
        return None
    # DB first (per-user table), then in-memory fallback
    db_hit = _db_lookup_correction(key)
    if db_hit:
        return db_hit
    return _LEARNED_MEM.get(key)


def learn_correction(counterparty, chosen_category, user=None, raw_text=""):
    """Record that the user re-categorised a txn from this counterparty.

    Writes to the in-memory store always, and to the DB model
    `CategoryCorrection` when a user + model are available. Next time a txn from
    the same counterparty is parsed, `guess_category` returns `chosen_category`
    with high confidence.
    """
    key = _norm_key(counterparty, raw_text)
    if not key:
        return False
    _LEARNED_MEM[key] = chosen_category
    _db_store_correction(key, chosen_category, user)
    return True


def _db_lookup_correction(key):
    """Late-bound DB read; returns None if the model/table isn't there."""
    try:
        from core.models import CategoryCorrection  # type: ignore
        row = CategoryCorrection.objects.filter(key=key).order_by("-updated_at").first()
        return row.category if row else None
    except Exception:
        return None


def _db_store_correction(key, category, user):
    try:
        from core.models import CategoryCorrection  # type: ignore
        if user is None:
            return
        CategoryCorrection.objects.update_or_create(
            user=user, key=key, defaults={"category": category})
    except Exception:
        pass


# ---------------------------------------------------------------------------
# duplicate detection for the import-review flow
# ---------------------------------------------------------------------------

def txn_fingerprint(parsed):
    """A stable key to dedupe the same SMS parsed/imported twice. Uses the ref
    when present (most reliable), else channel+amount+date+counterparty."""
    if parsed.get("ref"):
        return "ref:" + str(parsed["ref"]).upper()
    return "|".join([
        parsed.get("channel") or "",
        str(parsed.get("amount") or ""),
        parsed.get("date") or "",
        (parsed.get("counterparty") or "").lower(),
        parsed.get("type") or "",
    ])


def dedupe(parsed_list, seen_fingerprints=None):
    """Split a batch of parsed txns into (fresh, duplicates). `seen_fingerprints`
    lets the caller pass fingerprints already imported previously."""
    seen = set(seen_fingerprints or [])
    fresh, dups = [], []
    for p in parsed_list:
        fp = txn_fingerprint(p)
        if fp in seen:
            dups.append(p)
        else:
            seen.add(fp)
            fresh.append(p)
    return fresh, dups


def parse_batch(messages):
    """messages: list of {'body':..., 'sender':...} (or plain strings).
    Returns parsed dicts in input order; unparseable ones have parsed=False."""
    out = []
    for m in messages or []:
        if isinstance(m, str):
            out.append(parse_sms(m))
        else:
            out.append(parse_sms(m.get("body", ""), m.get("sender", "")))
    return out
