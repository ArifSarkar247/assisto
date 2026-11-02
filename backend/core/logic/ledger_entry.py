"""
ledger_entry.py — the SIMPLE ENTRY layer of Business Accounting (acctui, flag
`accounting_v2`). Pure: no Django. The shop owner says WHAT happened in plain
words — sale / purchase / expense / due / money in-out / transfer — and which
money account (cash, bKash, Nagad, bank); these rules turn it into a balanced
double-entry posting with the core's own helpers (core.logic.ledger). The user
never sees debit or credit.

  kind      what the user picked          posting (Dr / Cr)
  sale      বিক্রি (money received)       Dr account / Cr Sales—shop, Cr Output VAT
                                          (+ optional cost: Dr COGS / Cr Inventory)
  purchase  কেনা (stock bought)            Dr Inventory, Dr Input VAT / Cr account
                                          (pay='due' -> Cr Payable, supplier)
  expense   খরচ                           Dr <60xx category> / Cr account
  due       বাকি (customer took on credit) Dr Receivable (party) / Cr Sales—khata
                                          (+ optional cost: Dr COGS / Cr Inventory)
  money_in  টাকা পেলাম                     Dr account / Cr <purpose>
            purpose customer -> Receivable (party), capital -> Owner's capital,
            loan -> Loans payable, other -> Other income
  money_out টাকা দিলাম                     Dr <purpose> / Cr account
            purpose supplier -> Payable (party), drawings -> Owner's drawings,
            loan -> Loans payable (repaid), vat -> Output VAT (paid to NBR)
  transfer  টাকা সরালাম (cash -> bank ..)  Dr to-account / Cr from-account

Opening balances (wizard): acctopen:<code> — Dr asset / Cr Opening balance
equity (payable: Dr Opening balance equity / Cr Payable), dated the books'
start day. Opening STOCK uses the core's own frozen opening inventory.

Source keys: acct:<client_id>, acctopen:<code>. A voided entry posts nothing,
so the core's sync reverses it (never deleted — audit trail). An entry linked
to a khata row / expense row follows that row's CURRENT amount and day (the
khata stays the one truth); the row gone = nothing posted.

MONEY: integer poisha. VAT amount is TYPED by the user (no rate in code).
"""
from datetime import date, timedelta

from . import ledger as L

KINDS = ("sale", "purchase", "expense", "due", "money_in", "money_out", "transfer")
ACCOUNTS = {"cash": "1010", "bkash": "1020", "nagad": "1030", "bank": "1040"}
CASH_CODES = tuple(ACCOUNTS.values())
INPUT_VAT, OUTPUT_VAT, LOANS = "1310", "2100", "2300"
CAPITAL, DRAWINGS, OTHER_INCOME = "3010", "3020", "4100"
FIXED = ("1500", "1510")
EXPENSE_CODES = tuple(c[0] for c in L.CHART if c[2] == "operating")
IN_PURPOSES = {"customer": L.AR, "capital": CAPITAL, "loan": LOANS, "other": OTHER_INCOME}
OUT_PURPOSES = {"supplier": L.AP, "drawings": DRAWINGS, "loan": LOANS, "vat": OUTPUT_VAT}
PARTY_BOOK = {("due", None): "customer", ("money_in", "customer"): "customer",
              ("money_out", "supplier"): "supplier", ("purchase", "due"): "supplier"}
OPENING_FIELDS = (("cash", "1010"), ("bkash", "1020"), ("nagad", "1030"),
                  ("bank", "1040"), ("receivable", L.AR), ("payable", L.AP))
MAX_AMOUNT = 10 ** 13        # 10 crore taka in poisha x 100 — typo guard
MARKER = "[acct#%s]"


def party_book(kind, purpose=None, pay=None):
    """'customer' | 'supplier' when this entry needs a khata party, else None."""
    if kind == "purchase":
        return PARTY_BOOK.get((kind, pay))
    if kind == "due":
        return "customer"
    return PARTY_BOOK.get((kind, purpose))


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def validate(data, today, lock_date=None):
    """data from the app -> (clean dict, None) or (None, error_code).
    Error codes are translated by the view."""
    kind = data.get("kind")
    if kind not in KINDS:
        return None, "bad_kind"
    amount = _int(data.get("amount"))
    if amount is None or amount <= 0 or amount > MAX_AMOUNT:
        return None, "bad_amount"
    cid = str(data.get("client_id") or "").strip()
    if not (8 <= len(cid) <= 32) or not cid.replace("-", "").isalnum():
        return None, "bad_client_id"
    day = L.parse_day(data.get("date"), today)
    if day is None or day > today:
        return None, "bad_date"
    if lock_date and day <= lock_date:
        return None, "locked_period"
    out = {"client_id": cid, "kind": kind, "amount": amount, "date": str(day),
           "note": str(data.get("note") or "").strip()[:160]}
    acct = data.get("account") or "cash"
    pay = data.get("pay") or None
    if kind == "purchase" and pay == "due":
        out["pay"] = "due"
    elif acct not in ACCOUNTS:
        return None, "bad_account"
    else:
        out["account"] = acct
    if kind == "transfer":
        to = data.get("to_account")
        if to not in ACCOUNTS:
            return None, "bad_account"
        if to == acct:
            return None, "same_account"
        out["to_account"] = to
    if kind == "expense":
        cat = str(data.get("category") or L.OTHER_EXP)
        if cat not in EXPENSE_CODES:
            return None, "bad_category"
        out["category"] = cat
    if kind in ("money_in", "money_out"):
        purposes = IN_PURPOSES if kind == "money_in" else OUT_PURPOSES
        p = data.get("purpose") or ("customer" if kind == "money_in" else "supplier")
        if p not in purposes:
            return None, "bad_purpose"
        out["purpose"] = p
    vat = _int(data.get("vat") or 0)
    if kind in ("sale", "purchase"):
        if vat is None or vat < 0 or vat >= amount:
            return None, "bad_vat"
        out["vat"] = vat
    if kind in ("sale", "due"):
        cost = _int(data.get("cost") or 0)
        if cost is None or cost < 0 or cost > MAX_AMOUNT:
            return None, "bad_cost"
        out["cost"] = cost
    book = party_book(kind, out.get("purpose"), out.get("pay"))
    if book:
        out["party_book"] = book
        pid = _int(data.get("party_id"))
        name = str(data.get("party_name") or "").strip()[:120]
        phone = str(data.get("party_phone") or "").strip()[:40]
        if not pid and not name and not phone:
            return None, "need_party"
        out.update({"party_id": pid, "party_name": name, "party_phone": phone})
    elif data.get("party_name"):
        out["party_name"] = str(data["party_name"]).strip()[:120]   # label only
    return out, None


def khata_direction(e):
    """Direction of the khata row this entry writes (owner POV), or None."""
    book = e.get("party_book")
    if not book:
        return None
    if book == "customer":
        return "gave" if e["kind"] == "due" else "got"
    return "got" if e["kind"] == "purchase" else "gave"


def memo(e):
    p = e.get("party_name") or ""
    n = e.get("note") or ""
    lab = {
        "sale": ("বিক্রি", "Sale"), "purchase": ("মাল কেনা", "Purchase"),
        "expense": ("খরচ", "Expense"), "due": ("বাকিতে বিক্রি", "Sold on credit"),
        "money_in": ("টাকা পেলাম", "Money received"),
        "money_out": ("টাকা দিলাম", "Money paid"),
        "transfer": ("টাকা সরানো", "Transfer"),
    }[e["kind"]]
    tail = " — ".join(x for x in (p, n) if x)
    return L._m("%s%s" % (lab[0], " — " + tail if tail else ""),
                "%s%s" % (lab[1], " — " + tail if tail else ""))


def lines_for(e, amount=None):
    """Balanced lines for an entry (amount overrides e['amount'])."""
    amt = int(amount if amount is not None else e["amount"])
    k = e["kind"]
    acct = ACCOUNTS.get(e.get("account") or "cash", L.CASH)
    party = e.get("party_name") or ""
    vat = min(int(e.get("vat") or 0), amt)
    cost = int(e.get("cost") or 0)
    if k == "sale":
        ls = [L.line(acct, debit=amt, party=party),
              L.line(L.SALES_POS, credit=amt - vat), L.line(OUTPUT_VAT, credit=vat)]
    elif k == "due":
        ls = [L.line(L.AR, debit=amt, party=party), L.line(L.SALES_KHATA, credit=amt)]
    elif k == "purchase":
        credit = L.line(L.AP, credit=amt, party=party) if e.get("pay") == "due" \
            else L.line(acct, credit=amt, party=party)
        ls = [L.line(L.INVENTORY, debit=amt - vat), L.line(INPUT_VAT, debit=vat), credit]
    elif k == "expense":
        ls = [L.line(e.get("category") or L.OTHER_EXP, debit=amt, party=party),
              L.line(acct, credit=amt)]
    elif k == "money_in":
        ctr = IN_PURPOSES[e.get("purpose") or "customer"]
        ls = [L.line(acct, debit=amt),
              L.line(ctr, credit=amt, party=party if ctr == L.AR else "")]
    elif k == "money_out":
        ctr = OUT_PURPOSES[e.get("purpose") or "supplier"]
        ls = [L.line(ctr, debit=amt, party=party if ctr == L.AP else ""),
              L.line(acct, credit=amt)]
    else:   # transfer
        ls = [L.line(ACCOUNTS[e["to_account"]], debit=amt), L.line(acct, credit=amt)]
    if cost and k in ("sale", "due"):
        ls += [L.line(L.COGS, debit=cost), L.line(L.INVENTORY, credit=cost)]
    return ls


def post_entry(e, linked=None):
    """Posting for a stored entry, or None (voided / linked row gone).
    linked: None = not linked; {'gone': True}; or {'amount', 'date'} from the
    khata / expense row it wrote (that row wins — one truth)."""
    if e.get("void"):
        return None
    amount, day = e["amount"], L.parse_day(e["date"])
    if linked is not None:
        if linked.get("gone"):
            return None
        amount, day = linked["amount"], linked["date"]
    if day is None or amount <= 0:
        return None
    return L.make_entry("acct:%s" % e["client_id"], day, lines_for(e, amount), memo(e))


def post_opening(values, start):
    """values: {cash, bkash, nagad, bank, receivable, payable} poisha ->
    {source_key: posting} dated the books' start day."""
    out = {}
    for field, code in OPENING_FIELDS:
        v = max(_int(values.get(field)) or 0, 0)
        if not v:
            continue
        if code == L.AP:
            ls = [L.line(L.OPENING_EQ, debit=v), L.line(code, credit=v)]
        else:
            ls = [L.line(code, debit=v), L.line(L.OPENING_EQ, credit=v)]
        name = L.ACC[code]["name"]
        e = L.make_entry("acctopen:%s" % code, start, ls,
                         L._m("শুরুর ব্যালান্স — %s" % name["bn"],
                              "Opening balance — %s" % name["en"]))
        out[e["source_key"]] = e
    return out


def validate_opening(data):
    """-> (clean {field: poisha, 'stock': poisha|None}, None) or (None, code)."""
    out = {}
    for field, _ in OPENING_FIELDS + (("stock", None),):
        raw = data.get(field)
        if raw in (None, ""):
            out[field] = None if field == "stock" else 0
            continue
        v = _int(raw)
        if v is None or v < 0 or v > MAX_AMOUNT:
            return None, "bad_amount"
        out[field] = v
    return out, None


# --------------------------------------------------------------------------
# reports the core does not have yet: cash flow (direct) and VAT summary.
# `entry_lines`: [{entry, date, source, account, debit, credit}] — one per
# journal line (reversals included: they net to zero inside a period).
# --------------------------------------------------------------------------
def _cf_bucket(code):
    a = L.ACC[code]
    if code == L.OPENING_EQ:
        return "opening"
    if code in FIXED:
        return "investing"
    if a["type"] == L.EQUITY or code == LOANS:
        return "financing"
    return "operating"


def _cf_line(code):
    """Operating detail row for an account (plain words in the app)."""
    a = L.ACC[code]
    if code in (L.AR,) or a["group"] in ("sales",):
        return "customers"
    if code in (L.INVENTORY, L.AP, INPUT_VAT):
        return "suppliers"
    if code == OUTPUT_VAT:
        return "vat"
    if a["type"] == L.EXPENSE:
        return "expenses"
    if a["group"] == "other_income":
        return "other_income"
    return "other"


def cash_flow(entry_lines, start, end):
    """Direct-method cash flow over [start, end]. Every cash movement is
    explained by the OTHER lines of the same entry (their credit - debit sums
    to the entry's cash change), so operating + investing + financing +
    opening == closing - opening cash exactly."""
    by_entry = {}
    opening_cash = 0
    closing_cash = 0
    for l in entry_lines:
        d = l["date"]
        delta = int(l["debit"]) - int(l["credit"])
        if l["account"] in CASH_CODES:
            if d < start:
                opening_cash += delta
            if d <= end:
                closing_cash += delta
        if start <= d <= end:
            by_entry.setdefault(l["entry"], []).append(l)
    ops = {k: 0 for k in ("customers", "suppliers", "expenses", "vat",
                          "other_income", "other")}
    totals = {"operating": 0, "investing": 0, "financing": 0, "opening": 0}
    fin = {"capital": 0, "drawings": 0, "loans": 0}
    for ls in by_entry.values():
        if not any(x["account"] in CASH_CODES for x in ls):
            continue
        for x in ls:
            if x["account"] in CASH_CODES:
                continue          # transfers between money accounts net out
            eff = int(x["credit"]) - int(x["debit"])
            b = _cf_bucket(x["account"])
            totals[b] += eff
            if b == "operating":
                ops[_cf_line(x["account"])] += eff
            elif b == "financing":
                key = {CAPITAL: "capital", DRAWINGS: "drawings"}.get(x["account"], "loans")
                fin[key] += eff
    net = totals["operating"] + totals["investing"] + totals["financing"]
    return {"from": str(start), "to": str(end),
            "opening_cash": opening_cash, "opening_balances": totals["opening"],
            "operating": dict(ops, total=totals["operating"]),
            "investing": {"total": totals["investing"]},
            "financing": dict(fin, total=totals["financing"]),
            "net_change": net, "closing_cash": closing_cash,
            "balanced": opening_cash + totals["opening"] + net == closing_cash}


def vat_summary(entry_lines, start, end):
    """Output VAT (on sales — Mushak-6.3 invoices), input VAT (purchases),
    VAT paid to NBR, net payable for the period. A summary for the owner and
    the accountant; NOT a filed return (Mushak-9.1 is filed by the owner)."""
    out_vat = in_vat = paid = 0
    taxable_sales = taxable_purchases = 0
    n_sales = n_purchases = 0
    by_entry = {}
    for l in entry_lines:
        if start <= l["date"] <= end:
            by_entry.setdefault(l["entry"], []).append(l)
    for ls in by_entry.values():
        ov = sum(int(x["credit"]) - int(x["debit"]) for x in ls if x["account"] == OUTPUT_VAT)
        iv = sum(int(x["debit"]) - int(x["credit"]) for x in ls if x["account"] == INPUT_VAT)
        other = [x for x in ls if x["account"] not in CASH_CODES]
        if ov and all(x["account"] == OUTPUT_VAT for x in other):
            paid -= ov                 # Dr Output VAT / Cr money = paid to NBR
            continue                   # (its reversal subtracts it again)
        if ov:
            out_vat += ov
            n_sales += 1 if ov > 0 else -1
            taxable_sales += sum(int(x["credit"]) - int(x["debit"]) for x in ls
                                 if L.ACC[x["account"]]["group"] == "sales")
        if iv:
            in_vat += iv
            n_purchases += 1 if iv > 0 else -1
            taxable_purchases += sum(int(x["debit"]) - int(x["credit"]) for x in ls
                                     if x["account"] == L.INVENTORY)
    return {"from": str(start), "to": str(end),
            "output_vat": out_vat, "input_vat": in_vat,
            "net_payable": out_vat - in_vat, "paid": paid,
            "still_due": out_vat - in_vat - paid,
            "taxable_sales": taxable_sales, "taxable_purchases": taxable_purchases,
            "sale_invoices": n_sales, "purchase_bills": n_purchases}


def period_range(kind, today, offset=0):
    """('month'|'quarter'|'year', today, 0 = current / -1 = previous) ->
    (start, end) with end capped at today."""
    if kind == "year":
        y = today.year + offset
        s, e = date(y, 1, 1), date(y, 12, 31)
    elif kind == "quarter":
        q0 = (today.month - 1) // 3 + offset * 1
        y = today.year + q0 // 4
        q = q0 % 4
        s = date(y, q * 3 + 1, 1)
        e = (date(y + (q == 3), (q * 3 + 3) % 12 + 1, 1)) - timedelta(days=1)
    else:
        m0 = today.month - 1 + offset
        y = today.year + m0 // 12
        m = m0 % 12 + 1
        s = date(y, m, 1)
        e = date(y + (m == 12), m % 12 + 1, 1) - timedelta(days=1)
    return s, min(e, today)
