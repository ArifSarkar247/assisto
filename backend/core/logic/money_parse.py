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
# aieval: Bangla-template SMS ("ফি ৳১৮", "ব্যালেন্স ৳১,৫০০") are read too.
_FEE_RX = re.compile(r"(?:fee|charge|chrg|ফি(?=\s*[:৳\d]))[:\s]*(?:tk|bdt|৳)?\s*([\d,]+(?:\.\d+)?)", re.I)
_BAL_RX = re.compile(
    r"(?:bal(?:ance)?|avl\s*bal|available\s*balance|ব্যালেন্স)[:\s]*(?:tk|bdt|৳)?\s*([\d,]+(?:\.\d+)?)",
    re.I,
)
# TrxID / TxnID are the authoritative wallet references; prefer them over a
# generic "Ref". Try the strong pattern first, then fall back.
_TRXID_RX = re.compile(r"(?:trx\s*id|txn\s*id|trxid|txnid)[:\s.]*([a-z0-9]{4,})", re.I)
_REF_RX = re.compile(r"(?:ref(?:erence)?\s*(?:no)?)[:\s.]*([a-z0-9]{4,})", re.I)
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
    """All amount tokens in order of appearance (value, num_start, num_end).

    `num_start`/`num_end` are the span of the NUMBER itself (not the currency
    marker), so callers can test overlap against fee/balance number spans."""
    out = []
    for m in _AMOUNT_RX.finditer(normalize_digits(body or "")):
        # group(1) = "Tk 123" form, group(2) = "123 Tk" form; take whichever hit
        gi = 1 if m.group(1) is not None else 2
        val = _to_decimal(m.group(gi))
        if val is not None:
            out.append((val, m.start(gi), m.end(gi)))
    return out


def parse_sms(body, sender=""):
    """Main entry point. Parse one raw SMS/notification body into a txn dict."""
    raw = (body or "").strip()
    norm = normalize_digits(raw)
    channel = detect_channel(sender, norm)
    txn_type = detect_type(norm)

    fee_m = _FEE_RX.search(norm)
    bal_m = _BAL_RX.search(norm)
    fee = _to_decimal(fee_m.group(1)) if fee_m else None
    bal = _to_decimal(bal_m.group(1)) if bal_m else None

    # amount = first currency token NOT inside the fee/balance capture spans.
    # Selecting by POSITION (not by value) so a transaction amount that happens
    # to equal the fee or balance (e.g. "Cash Out Tk 18.50 Fee Tk 18.50" or
    # "received Tk 1000 ... Balance Tk 1000") is still picked up correctly.
    skip_spans = []
    if fee_m:
        skip_spans.append(fee_m.span(1))
    if bal_m:
        skip_spans.append(bal_m.span(1))

    def _overlaps_skip(num_start, num_end):
        # True if this amount's number span overlaps a fee/balance number span.
        for s, e in skip_spans:
            if num_start < e and s < num_end:
                return True
        return False

    amount = None
    for val, num_start, num_end in _amounts(norm):
        if _overlaps_skip(num_start, num_end):
            continue
        amount = val
        break

    ref = None
    rm = _TRXID_RX.search(norm) or _REF_RX.search(norm)
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
    # sendmoney = outgoing transfers only. Incoming-credit words ("received",
    # "cash in", "add money") must NOT live here or a credit gets mislabelled
    # as 'sendmoney'; credits fall through to the weak 'income' default instead.
    ("sendmoney", ["send money", "cash out", "transfer"]),
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

def txn_fingerprint(parsed, seq=None):
    """A stable key to dedupe the same SMS parsed/imported twice.

    A real transaction ref (TrxID/TxnID/Ref) is authoritative, so ref-bearing
    txns dedupe on the ref alone. Ref-less txns are intrinsically ambiguous:
    two genuinely-distinct txns can share channel+amount+date+party+type (e.g.
    paying the same shop the same amount twice in one day). Collapsing them
    would silently drop a real txn, so for ref-less txns we append a per-batch
    sequence index (`seq`) — identical-looking entries stay distinct and are
    all kept. (Re-importing the exact same batch still re-derives the same
    seq order, so true double-imports are caught by the caller's seen set.)"""
    if parsed.get("ref"):
        return "ref:" + str(parsed["ref"]).upper()
    base = "|".join([
        parsed.get("channel") or "",
        str(parsed.get("amount") or ""),
        parsed.get("date") or "",
        (parsed.get("counterparty") or "").lower(),
        parsed.get("type") or "",
    ])
    if seq is not None:
        base += "#" + str(seq)
    return "noref:" + base


def dedupe(parsed_list, seen_fingerprints=None):
    """Split a batch of parsed txns into (fresh, duplicates). `seen_fingerprints`
    lets the caller pass fingerprints already imported previously.

    Ref-less txns get a per-key sequence index so two distinct-but-identical
    looking entries in the same batch are BOTH kept (only exact re-imports,
    caught via `seen_fingerprints`, are treated as dupes)."""
    seen = set(seen_fingerprints or [])
    noref_counts = {}
    fresh, dups = [], []
    for p in parsed_list:
        if p.get("ref"):
            fp = txn_fingerprint(p)
        else:
            # disambiguate ref-less collisions within this batch
            key = txn_fingerprint(p)
            n = noref_counts.get(key, 0)
            noref_counts[key] = n + 1
            fp = txn_fingerprint(p, seq=n)
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


# ===========================================================================
# money-VOICE parsing (feature #62, SPEC v2.1 §21)
# ===========================================================================
# A spoken utterance ("রহিমকে ৫০০ টাকা দিলাম", "cha 20 taka", "tea 20, rickshaw
# 30") is NOT a wallet SMS — there is no channel, no TrxID, no balance. It is a
# short natural-language money entry the user DICTATED. These helpers turn one
# (or a comma-separated batch of) such utterance(s) into a reviewable draft the
# UI confirms BEFORE logging. They deliberately REUSE the SMS parser's building
# blocks — normalize_digits / _amounts / guess_category — so Bangla numerals,
# amount tokens and category rules behave identically to SMS import. The STT
# transcript is produced by the device (key/engine-gated on the Flutter side);
# this layer is pure text -> structured draft, so it is deterministic and
# unit-testable and never fabricates words the user did not speak.
#
# Output per entry (money_voice_entry):
#   {
#     "amount": Decimal|None,
#     "txn_type": "expense"|"income"|"due_in"|"due_out"|None,
#         # due_in  = someone owes YOU (you lent / will receive)      -> loan given
#         # due_out = YOU owe someone (you borrowed / must pay later) -> loan taken
#     "category_guess": str|None,     # money_engine slug (reuses guess_category)
#     "category_confidence": float,
#     "counterparty": str|None,       # "Rahim" from "Rahim-ke" / "রহিমকে"
#     "note": str,                    # leftover descriptive words (e.g. "tea")
#     "raw": str,                     # this entry's text, trimmed
#     "parsed": bool,                 # True when amount AND txn_type both found
#   }

# -- type cues (bn + Banglish + en), checked by phrase so Banglish wins too ---
# Order matters only within a class; across classes we score by *last* cue hit
# (the verb that ends a Bangla sentence carries the real direction).
_MV_INCOME_CUES = [
    # money came IN
    "income", "earned", "got paid", "received", "receive", "salary", "profit",
    "পেলাম", "পেয়েছি", "পাইলাম", "আয়", "বেতন", "ইনকাম", "জমা",
    "pelam", "peyechi", "paisi", "income holo", "ay holo", "beton",
]
_MV_EXPENSE_CUES = [
    # money went OUT as spend
    "spent", "paid", "bought", "expense", "cost", "bill", "kinlam", "khoroch",
    "খরচ", "কিনলাম", "কিনেছি", "দিলাম খরচ", "বিল দিলাম",
    "khoroch korechi", "kharoch", "porlo", "laglo", "gelo",
]
_MV_DUE_IN_CUES = [
    # you LENT / money owed TO you
    "lent", "loaned", "gave a loan", "will get back", "owes me", "to pabo",
    "ধার দিলাম", "ধার দিয়েছি", "পাবো", "পাব", "পাওনা", "ধারে দিলাম",
    "dhar dilam", "dhar dilo", "pabo", "pawna", " dhar diyechi",
]
_MV_DUE_OUT_CUES = [
    # you BORROWED / you OWE
    "borrowed", "owe", "i owe", "took a loan", "to debo",
    "ধার নিলাম", "ধার নিয়েছি", "দেনা", "দিতে হবে", "দেবো", "দিব",
    "dhar nilam", "dhar nilo", "dena", "debo", "dibo", "dite hobe",
]
# A bare "gave" verb ("দিলাম" / "dilam" / "gave") with a counterparty but no
# loan word is an EXPENSE (you handed over money), not a loan — handled below.
_MV_GAVE_CUES = ["দিলাম", "দিয়েছি", "দিলো", "দিল", "dilam", "diyechi", "dilo", "gave", "diye dilam"]

# counterparty: "<name>-ke" (Bangla dative "কে" / Banglish " ke") or
# "<name> theke / থেকে" (from) or English "to/from/for <name>". Names keep
# their original casing.
# Bangla dative: a word ending in কে — but NOT the word "থেকে" (from), whose
# own tail is কে; require ≥2 leading chars and forbid the থে- stem.
_MV_PARTY_BN = re.compile(r"(?<![ঀ-৿])((?!থে)[ঀ-৿]{2,}?)কে(?=[\s,।]|$)")
# Bangla/Banglish "from": "<name>র থেকে" / "<name> theke".
_MV_PARTY_BN_FROM = re.compile(r"([ঀ-৿]{2,}?)(?:র|ের)?\s*থেকে")
_MV_PARTY_BANGLISH = re.compile(r"\b([A-Za-z][A-Za-z.'\-]{1,24})\s+(?:ke|theke)\b", re.I)
_MV_PARTY_EN = re.compile(r"\b(?:to|from|for)\s+([A-Za-z][A-Za-z .'\-]{1,24}?)(?=[.,;]|\s+(?:tk|taka|bdt|৳|\d)|$)", re.I)


def _mv_last_cue_type(low):
    """Score the four type-classes by the LAST position each class's strongest
    cue appears; the latest-appearing wins (Bangla direction verbs trail the
    sentence). Returns a txn_type or None. Loan cues beat plain spend/income
    because 'ধার দিলাম' contains the spend-ish 'দিলাম'."""
    # "got paid" is income; its inner "paid" must not count as a spend (aieval)
    low = low.replace("got paid", "received")

    def last_hit(cues):
        pos = -1
        for c in cues:
            c = c.strip()
            if not c:
                continue
            i = low.rfind(c)
            if i > pos:
                pos = i
        return pos

    scores = {
        "due_in": last_hit(_MV_DUE_IN_CUES),
        "due_out": last_hit(_MV_DUE_OUT_CUES),
        "income": last_hit(_MV_INCOME_CUES),
        "expense": last_hit(_MV_EXPENSE_CUES),
    }
    # loans take priority on a tie / overlap with spend verbs.
    best_t, best_p = None, -1
    for t in ("due_in", "due_out", "income", "expense"):
        if scores[t] > best_p:
            best_p, best_t = scores[t], t
    if best_p < 0:
        return None
    return best_t


def _mv_counterparty(raw):
    """Pull a counterparty name out of one voice entry (original casing)."""
    m = _MV_PARTY_BN.search(raw)
    if m:
        name = m.group(1).strip(" .,।-")
        if name:
            return name
    m = _MV_PARTY_BN_FROM.search(raw)
    if m:
        name = m.group(1).strip(" .,।-")
        if name:
            return name
    m = _MV_PARTY_BANGLISH.search(raw)
    if m:
        return m.group(1).strip(" .,-")
    m = _MV_PARTY_EN.search(raw)
    if m:
        return m.group(1).strip(" .,-")
    return None


def _mv_note(raw, amount_span, party):
    """Leftover descriptive words after removing the amount token + the party
    phrase — this is the human label ("tea", "rickshaw", "চা")."""
    norm = normalize_digits(raw)
    if amount_span:
        s, e = amount_span
        norm = norm[:s] + " " + norm[e:]
    # strip currency words + the party + common cue/verb noise words
    norm = re.sub(r"\b(?:tk|taka|bdt)\b|৳", " ", norm, flags=re.I)
    if party:
        norm = re.sub(re.escape(party), " ", norm, flags=re.I)
        norm = re.sub(r"\bke\b|কে", " ", norm, flags=re.I)
    norm = re.sub(r"\b(?:to|from|for|the|a|an|of)\b", " ", norm, flags=re.I)
    note = re.sub(r"\s+", " ", norm).strip(" .,।-")
    return note


def parse_money_voice_entry(text):
    """Parse ONE spoken money utterance into a reviewable draft dict.

    Deterministic; reuses normalize_digits / _amounts / guess_category so the
    numerals, amount token and category behave exactly like SMS import.
    """
    raw = (text or "").strip()
    norm = normalize_digits(raw)
    low = norm.lower()

    # amount: first currency/number token (voice has no fee/balance to skip).
    amount = None
    amount_span = None
    amts = _amounts(norm)
    if amts:
        val, s, e = amts[0]
        amount, amount_span = val, (s, e)
    else:
        m = re.search(r"\b(\d[\d,]*(?:\.\d+)?)\b", norm)
        if m:
            amount = _to_decimal(m.group(1))
            amount_span = m.span(1)

    party = _mv_counterparty(raw)

    # type: explicit loan/income/expense cues first.
    txn_type = _mv_last_cue_type(low)
    if txn_type is None:
        # a bare "gave <party>" with no loan word = expense; otherwise default
        # to expense (the overwhelmingly common quick-entry case) ONLY when an
        # amount exists — a type with no amount stays unparsed for review.
        if any(g in low for g in _MV_GAVE_CUES):
            txn_type = "expense"
        elif amount is not None:
            txn_type = "expense"

    # category: reuse the SMS category guesser. Map our voice types to the
    # debit/credit the guesser expects (loans are neither; pass None).
    cat_type = {"income": "credit", "due_in": "credit",
                "expense": "debit", "due_out": "debit"}.get(txn_type)
    cat, conf = guess_category(norm, party, cat_type, "voice")
    # income/due_in with no keyword match shouldn't claim an expense slug.
    if txn_type in ("income", "due_in") and cat == _UNCATEGORIZED:
        cat, conf = "income", 0.3

    note = _mv_note(raw, amount_span, party)

    return {
        "amount": amount,
        "txn_type": txn_type,
        "category_guess": cat,
        "category_confidence": conf,
        "counterparty": party,
        "note": note,
        "raw": raw,
        "parsed": bool(amount is not None and txn_type is not None),
    }


# batch splitter: commas / " and " / Bangla danda / "ar" separate entries. A
# comma is a separator ONLY when it is NOT a thousands separator inside a number
# (negative lookbehind/lookahead on digits keeps "1,500" intact).
_MV_SPLIT_RX = re.compile(
    r"\s*(?:(?<!\d),|,(?!\d)|।|;|\n|\band\b|\bar\b|\bও\b|\bএবং\b)\s*", re.I)


def split_money_voice(text):
    """Split a dictated batch ("tea 20, rickshaw 30") into entry strings.
    Keeps order; drops empties; does not split inside numbers."""
    norm = normalize_digits(text or "")
    parts = _MV_SPLIT_RX.split(norm)
    out = []
    for p in parts:
        p = (p or "").strip(" .।,-")
        # only keep a fragment that carries a digit (an amount) — stray
        # connectors / trailing words without a number aren't entries.
        if p and re.search(r"\d", p):
            out.append(p)
    return out


def parse_money_voice(text):
    """Parse a spoken money utterance (single OR comma/‘and’-separated batch)
    into a list of reviewable entry drafts, in spoken order.

    Single entry with no separators still returns a 1-element list, so the UI
    has one review path. Entries with parsed=False are kept (shown greyed /
    needing the user to fill a field) — never silently dropped, never auto-logged.
    """
    raw = (text or "").strip()
    if not raw:
        return []
    frags = split_money_voice(raw)
    if len(frags) <= 1:
        return [parse_money_voice_entry(raw)]
    return [parse_money_voice_entry(f) for f in frags]
