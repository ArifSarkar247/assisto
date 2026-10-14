"""
prepaid_meter.py — pure, deterministic PREPAID-METER balance tracker (#193,
SPEC v2.1 §20). Electricity & gas prepaid meters: the user adds meters, logs
each recharge (token amount, in ৳), optionally reads the current balance off
the meter, and we PROJECT when the balance will run low from the deterministic
average daily consumption implied by the recharge history.

There is NO live utility API — this is a MANUAL tracker. The seam where a live
DESCO / NESCO / titas integration would plug in is documented at
`live_balance_seam()` below; until a licensed utility key exists we never
fabricate a reading and we are honest that every number is an estimate.

HARD RULES (identical money discipline to the §20 money modules):

  * ALL MONEY IS INTEGER POISHA. 1 taka = 100 poisha. No float ever enters the
    ledger. Consumption rate is poisha-per-day as an integer (floor); projection
    uses integer division so the same history always yields the same day count.
  * NO DB, NO AI, NO I/O, NO MONEY-HOLDING. We compute and return plain dicts;
    the view layer persists meters + recharges in flexible per-user JSON
    collections and renders what we return. The app never buys a token and never
    moves a taka.
  * DETERMINISTIC. Average daily spend is derived purely from the recharge
    history span (first recharge date -> `as_of`), with a conservative fallback
    when history is too thin to trust. Low-balance threshold is an explicit,
    documented number of days.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer shows them directly and keeps ZERO Bangla in .dart.

Run self-tests (no DB):
    python3 -c "import core.logic.prepaid_meter_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date, datetime, timedelta

METER_KINDS = ("electricity", "gas")

# Default "running low" horizon: warn when the projected balance will last fewer
# than this many days. Explicit + documented so the Dart mirror and tests agree.
DEFAULT_LOW_DAYS = 5

# When the recharge history is too thin to imply a rate (only one recharge, or
# all recharges on the same day), we cannot honestly estimate consumption. We
# return rate 0 and an 'unknown' projection rather than inventing a burn rate.


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# poisha <-> taka (integer only) — same discipline as money_engine
# ---------------------------------------------------------------------------

def to_poisha(v):
    """Coerce taka-ish input to INTEGER poisha. Junk -> 0."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    try:
        taka = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


def _group(n):
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts) + "," + tail


def fmt_poisha(p):
    """Format integer poisha as a ৳ amount string (always 2 dp)."""
    p = int(p)
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


# ---------------------------------------------------------------------------
# date helpers (pure)
# ---------------------------------------------------------------------------

def _parse_date(v):
    if v is None or v == "":
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v).strip().split("T")[0].split(" ")[0]
    try:
        return date.fromisoformat(s)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# consumption estimation — the deterministic core
# ---------------------------------------------------------------------------

def _recharge_rows(recharges):
    """Normalise recharge rows to [{'date': date, 'amount': poisha}] sorted by
    date, dropping rows with no valid date or non-positive amount."""
    rows = []
    for r in recharges:
        d = _parse_date(r.get("date"))
        amt = to_poisha(r.get("amount"))
        if d is None or amt <= 0:
            continue
        rows.append({"date": d, "amount": amt})
    rows.sort(key=lambda x: x["date"])
    return rows


def daily_consumption(recharges, as_of=None):
    """Estimate average spend per day (INTEGER poisha/day) from recharge history.

    Model (deterministic, conservative): over the window from the FIRST recharge
    to `as_of`, the household has spent, on average, everything recharged EXCEPT
    the most recent top-up (which is assumed to still be (partly) in the meter).
    So rate = (sum of all recharges before the last) / (days from first recharge
    to the last recharge). This uses only CLOSED intervals between top-ups, which
    is the honest signal — we do not assume anything about days after the final
    recharge.

    Returns {'rate': poisha_per_day:int, 'span_days':int, 'confident':bool}.
    When history is too thin (fewer than 2 dated recharges, or zero span) we
    return rate 0 / confident False and the caller reports 'unknown'.
    """
    rows = _recharge_rows(recharges)
    if len(rows) < 2:
        return {"rate": 0, "span_days": 0, "confident": False}
    first = rows[0]["date"]
    last = rows[-1]["date"]
    span = (last - first).days
    if span <= 0:
        return {"rate": 0, "span_days": 0, "confident": False}
    # spend over the closed window = everything topped up strictly before the
    # last recharge (that money has been consumed to reach the last top-up).
    consumed = sum(r["amount"] for r in rows[:-1])
    rate = consumed // span
    return {"rate": rate, "span_days": span, "confident": rate > 0}


def current_balance(meter, recharges, as_of=None):
    """Best-estimate current balance in poisha.

    Two honest sources, in priority order:
      1. An explicit meter reading the user entered (`balance` + `balance_date`)
         carried FORWARD by the estimated daily rate to `as_of`.
      2. If no reading: the last recharge amount, decayed by the rate for the
         days since that recharge.
    Never goes below 0. Returns {'balance': poisha, 'basis': str, 'as_of': iso}.
    """
    as_of = _parse_date(as_of) or date.today()
    rate = daily_consumption(recharges, as_of=as_of)["rate"]
    rows = _recharge_rows(recharges)

    reading = to_poisha(meter.get("balance"))
    reading_date = _parse_date(meter.get("balance_date"))
    if reading > 0 and reading_date is not None:
        days = max(0, (as_of - reading_date).days)
        bal = max(0, reading - rate * days)
        return {"balance": bal, "basis": "reading", "as_of": as_of.isoformat()}

    if rows:
        last = rows[-1]
        days = max(0, (as_of - last["date"]).days)
        bal = max(0, last["amount"] - rate * days)
        return {"balance": bal, "basis": "last_recharge",
                "as_of": as_of.isoformat()}

    return {"balance": 0, "basis": "none", "as_of": as_of.isoformat()}


def project_runout(meter, recharges, as_of=None, low_days=DEFAULT_LOW_DAYS):
    """Project how long the current balance will last and whether it is low.

    Returns:
        {
          'balance'       : poisha (estimated now),
          'balance_display',
          'rate'          : poisha/day,
          'rate_display',
          'days_left'     : int | None   (None when rate unknown),
          'runout_date'   : 'YYYY-MM-DD' | None,
          'low'           : bool,         (days_left < low_days)
          'state'         : 'ok' | 'low' | 'empty' | 'unknown',
          'basis'         : balance basis,
          'note'          : {bn,en},
        }

    Honest 'unknown' when we cannot estimate a burn rate (too little history) —
    we do not invent a runout date.
    """
    as_of_d = _parse_date(as_of) or date.today()
    cons = daily_consumption(recharges, as_of=as_of_d)
    rate = cons["rate"]
    bal_info = current_balance(meter, recharges, as_of=as_of_d)
    bal = bal_info["balance"]

    if bal <= 0:
        state, days_left, runout = "empty", 0, as_of_d
    elif not cons["confident"] or rate <= 0:
        state, days_left, runout = "unknown", None, None
    else:
        days_left = bal // rate
        runout = as_of_d + timedelta(days=days_left)
        state = "low" if days_left < low_days else "ok"

    return {
        "balance": bal,
        "balance_display": fmt_poisha(bal),
        "rate": rate,
        "rate_display": fmt_poisha(rate),
        "days_left": days_left,
        "runout_date": runout.isoformat() if runout is not None else None,
        "low": state in ("low", "empty"),
        "state": state,
        "basis": bal_info["basis"],
        "note": {
            "bn": "সব সংখ্যা রিচার্জ ও ব্যবহারের ইতিহাস থেকে অনুমান করা — এটি "
                  "একটি ম্যানুয়াল ট্র্যাকার, কোনো লাইভ মিটার সংযোগ নেই। অ্যাপ "
                  "কোনো টোকেন কেনে না বা টাকা রাখে না।",
            "en": "All figures are estimates from your recharge & usage history "
                  "— this is a manual tracker, not a live meter link. The app "
                  "buys no token and holds no money.",
        },
    }


def meter_total_recharged(recharges):
    """Sum of all valid recharges for a meter (poisha). Pure."""
    return sum(r["amount"] for r in _recharge_rows(recharges))


def meters_overview(meters, recharges_by_meter, as_of=None,
                    low_days=DEFAULT_LOW_DAYS):
    """Dashboard row per meter. `recharges_by_meter` maps meter id -> list of
    recharge rows. Returns a list sorted lowest-days-left first (empty/low
    surface at the top), each row carrying its projection."""
    rows = []
    for m in meters:
        rr = recharges_by_meter.get(m.get("id"), [])
        proj = project_runout(m, rr, as_of=as_of, low_days=low_days)
        kind = m.get("kind", "electricity")
        if kind not in METER_KINDS:
            kind = "electricity"
        rows.append({
            "id": m.get("id"),
            "name": (m.get("name") or "").strip(),
            "kind": kind,
            "total_recharged": meter_total_recharged(rr),
            "total_recharged_display": fmt_poisha(meter_total_recharged(rr)),
            **proj,
        })

    _order = {"empty": 0, "low": 1, "ok": 2, "unknown": 3}

    def _key(r):
        dl = r["days_left"] if r["days_left"] is not None else 10 ** 9
        return (_order.get(r["state"], 4), dl, (r["name"] or "").lower(),
                str(r.get("id") or ""))

    rows.sort(key=_key)
    return rows


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate_meter(meter):
    problems = []
    if not (meter.get("name") or "").strip():
        problems.append("name_required")
    kind = meter.get("kind")
    if kind not in (None, "") and kind not in METER_KINDS:
        problems.append("bad_kind")
    if meter.get("balance") not in (None, "") \
            and to_poisha(meter.get("balance")) < 0:
        problems.append("bad_balance")
    if meter.get("balance_date") not in (None, "") \
            and _parse_date(meter.get("balance_date")) is None:
        problems.append("bad_balance_date")
    return problems


def validate_recharge(recharge):
    problems = []
    if to_poisha(recharge.get("amount")) <= 0:
        problems.append("amount_required")
    if _parse_date(recharge.get("date")) is None:
        problems.append("date_required")
    if recharge.get("meter") in (None, ""):
        problems.append("meter_required")
    return problems


# ---------------------------------------------------------------------------
# live-utility seam (documented, inert)
# ---------------------------------------------------------------------------

def live_balance_seam():
    """Documents (and refuses) the live-utility integration seam.

    A future licensed integration with a prepaid-utility provider (e.g. DESCO /
    NESCO smart-meter or Titas gas APIs) would replace the ESTIMATED balance in
    current_balance() with a real reading. Until such a licensed key exists this
    module never calls out and never fabricates a live reading; it returns a
    clear 'not available' marker so the UI can stay honest.
    """
    return {
        "available": False,
        "reason": "no_live_utility_key",
        "note": {
            "bn": "লাইভ মিটার সংযোগ এখনো নেই — সব হিসাব আপনার দেওয়া তথ্য থেকে "
                  "অনুমান।",
            "en": "No live meter link yet — all figures are estimated from the "
                  "data you enter.",
        },
    }
