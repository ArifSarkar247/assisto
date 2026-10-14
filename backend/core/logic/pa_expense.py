"""
pa_expense.py — the deterministic engine behind PA SECRETARY MODE EXPENSE
VOUCHER / claim builder (issue #113, SPEC v2.1 §14, ADVANCED).

The PA builds an expense voucher entirely by hand, offline, with NO key: a
voucher header (title + claimant + an approval STATUS of draft → submitted →
approved) and LINE ITEMS (date, category, ৳ amount, an optional note and an
attach-receipt REFERENCE). The engine auto-TOTALS the lines and produces a
deterministic voucher SUMMARY.

MONEY IS INTEGER POISHA
-----------------------
All amounts are carried as integer POISHA (1 taka = 100 poisha) so totals never
drift through float rounding. `to_poisha()` parses a typed BDT string → int
poisha (half-up on the hidden third decimal); `fmt_bdt()` renders int poisha →
a grouped "৳" string. The engine HOLDS NO MONEY and moves nothing — it only
arithmetic-sums what the PA typed.

Pure Python, deterministic, no Django, no DB, no network, **no clock**, **no AI**,
**no OCR**. Mirrors the conventions of the other pa_*/logic modules.

HONEST, KEY-GATED — OCR RECEIPT SEAM (NEVER FABRICATES)
-------------------------------------------------------
Auto-reading a receipt photo into a line item needs a real OCR provider this
engine does not bundle. So `ocr_seam()` HONESTLY returns `{required: True,
mock: True, ...}` — the UI shows a "connect an OCR key to auto-read receipts"
card and the PA types the amount by hand. We NEVER invent an amount, a merchant
or a date from an image.

Run self-tests (no DB):
    python3 -c "import core.logic.pa_expense_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------- vocabulary
STATUS_DRAFT = "draft"
STATUS_SUBMITTED = "submitted"
STATUS_APPROVED = "approved"
STATUSES = (STATUS_DRAFT, STATUS_SUBMITTED, STATUS_APPROVED)

# Expense categories (neutral English seed keys; the UI localises them).
CATEGORIES = (
    "transport", "lodging", "meals", "supplies",
    "communication", "entertainment", "other",
)

# The honest marker key the OCR seam carries. The UI renders the localised
# "connect an OCR key to auto-read receipts" copy from this.
OCR_MARKER_KEY = "ocr_seam"


# ------------------------------------------------------------------ money
# Integer-poisha arithmetic (1 taka = 100 poisha). Mirrors the Dart _toPoisha /
# _fmtBdt helpers so totals are identical on-device and in tests.

def to_poisha(value):
    """Parse a BDT amount (str/number) → integer poisha. Half-up on the hidden
    third decimal. Negatives clamp to 0 (a voucher line is never negative).
    Garbage → 0. Never raises."""
    if value is None or value == "":
        return 0
    if isinstance(value, bool):
        return 0
    s = str(value).strip().replace(",", "")
    if s.startswith("-"):
        return 0
    if "." in s:
        whole, _, frac = s.partition(".")
    else:
        whole, frac = s, ""
    if whole == "":
        whole = "0"
    frac = (frac + "000")[:3]
    try:
        major = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = major * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return poisha


def fmt_bdt(poisha):
    """Render integer poisha → a grouped '৳' string with 2 decimals (Indian/
    Bangladeshi lakh grouping: 12,34,567.89). Deterministic."""
    poisha = int(poisha or 0)
    neg = poisha < 0
    p = abs(poisha)
    taka = p // 100
    paisa = p % 100
    s = str(taka)
    if len(s) <= 3:
        grouped = s
    else:
        head, tail = s[:-3], s[-3:]
        parts = []
        while len(head) > 2:
            parts.insert(0, head[-2:])
            head = head[:-2]
        if head:
            parts.insert(0, head)
        grouped = ",".join(parts) + "," + tail
    return f"{'-' if neg else ''}৳{grouped}.{paisa:02d}"


# ------------------------------------------------------------------ parsing

def _parse(dt):
    if not dt:
        return None
    s = str(dt).strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1]
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        try:
            return datetime.fromisoformat(s + "T00:00:00")
        except ValueError:
            return None


def _clean(text):
    return " ".join(str(text or "").split()).strip()


# ------------------------------------------------------------- normalization

def normalize_voucher(voucher):
    """Coerce a dict into a clean voucher header. Unknown status → draft."""
    v = dict(voucher or {})
    status = v.get("status")
    if status not in STATUSES:
        status = STATUS_DRAFT
    return {
        "id": v.get("id"),
        "title": _clean(v.get("title")),
        "claimant": _clean(v.get("claimant")),
        "status": status,
        "note": str(v.get("note") or ""),
    }


def normalize_line(line):
    """Coerce a dict into a clean line item. The amount is carried as typed
    (string) for round-trip; `amount_poisha` is the canonical integer we sum.
    Unknown category → other."""
    x = dict(line or {})
    cat = x.get("category")
    if cat not in CATEGORIES:
        cat = "other"
    raw = x.get("amount")
    return {
        "id": x.get("id"),
        "voucher_id": x.get("voucher_id"),
        "date": (str(x.get("date")).strip() if x.get("date") else ""),
        "category": cat,
        "amount": ("" if raw is None else str(raw).strip()),
        "amount_poisha": to_poisha(raw),
        "receipt_ref": _clean(x.get("receipt_ref")),
        "note": str(x.get("note") or ""),
    }


# ------------------------------------------------------------------- validate

def validate_voucher(voucher):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    v = normalize_voucher(voucher)
    problems = []
    if not v["title"]:
        problems.append("title_required")
    return problems


def validate_line(line):
    """A line needs a category (always coerced valid) and a non-zero amount; a
    date, if present, must parse."""
    x = normalize_line(line)
    problems = []
    if x["amount_poisha"] <= 0:
        problems.append("amount_required")
    if x["date"] and _parse(x["date"]) is None:
        problems.append("bad_date")
    return problems


# ------------------------------------------------------------------ status

def can_transition(current, target):
    """Honest one-way approval flow: draft → submitted → approved. You may stay
    put, step forward one, or pull BACK to draft (e.g. a rejected claim). You
    can never jump draft → approved in one hop."""
    if current not in STATUSES or target not in STATUSES:
        return False
    if current == target:
        return True
    if target == STATUS_DRAFT:
        return True  # withdraw / reject back to draft
    order = {STATUS_DRAFT: 0, STATUS_SUBMITTED: 1, STATUS_APPROVED: 2}
    return order[target] - order[current] == 1


def advance_status(current):
    """Next status in the forward flow; approved stays approved. Deterministic."""
    if current == STATUS_DRAFT:
        return STATUS_SUBMITTED
    if current == STATUS_SUBMITTED:
        return STATUS_APPROVED
    return STATUS_APPROVED


# ---------------------------------------------------------------- totals

def total_poisha(lines):
    """Integer-poisha sum of all line amounts. Order-independent, no drift."""
    return sum(normalize_line(x)["amount_poisha"] for x in (lines or []))


def category_totals(lines):
    """{category: poisha} rollup (only categories that appear). Deterministic."""
    out = {}
    for x in (lines or []):
        n = normalize_line(x)
        out[n["category"]] = out.get(n["category"], 0) + n["amount_poisha"]
    return out


def voucher_summary(voucher, lines=None):
    """Deterministic, printable voucher roll-up the UI renders:

        {
          "voucher": {...}, "lines": [...ordered...],
          "total_poisha", "total_display" (formatted ৳),
          "by_category": {cat: poisha}, "count",
          "status", "mock": False
        }

    Lines are ordered by date (undated last), then by id for stability. Holds
    no money; sums only what the PA typed."""
    v = normalize_voucher(voucher)
    normed = [normalize_line(x) for x in (lines or [])]
    far = "9999-12-31T23:59:59"
    normed.sort(key=lambda x: (
        (_parse(x["date"]).isoformat() if _parse(x["date"]) else far),
        str(x.get("id") or ""),
    ))
    total = sum(x["amount_poisha"] for x in normed)
    return {
        "voucher": v,
        "lines": normed,
        "total_poisha": total,
        "total_display": fmt_bdt(total),
        "by_category": category_totals(normed),
        "count": len(normed),
        "status": v["status"],
        "mock": False,
    }


# ------------------------------------------------------------- ocr seam

def ocr_seam(ref=None):
    """DOCUMENTED key-gated seam for OCR auto-read of a receipt image.

    Honest MOCK: never reads an image, never invents an amount/merchant/date.
    Returns the shape the integrator wires to a real OCR provider when an `ocr`
    key is present. Until then the UI shows a "connect an OCR key to auto-read
    receipts" card and the PA types the line by hand.
    """
    return {
        "action": "ocr_receipt",
        "ref": _clean(ref),
        "fields": {},          # honest: empty — no provider, nothing extracted
        "required": True,      # an OCR key is required to auto-read a receipt
        "mock": True,
        "marker": OCR_MARKER_KEY,
    }
