"""
ledger.py — pure double-entry core for Business Accounting (flag `accounting_v2`,
owner_actions/FEATURE_CARD_ACCOUNTING_BN.md). NO Django imports: every function
takes plain dicts / ints / dates and returns plain dicts, so the posting rules
and reports are deterministic and unit-testable in isolation. The DB layer
(core.ledger_service) feeds it rows and persists what it returns.

MONEY: integer POISHA everywhere (১ টাকা = ১০০ পয়সা). A line carries either a
debit or a credit (never both, never negative). Every journal entry balances
(sum debit == sum credit) — `make_entry` refuses one that does not.

POSTING RULES (source -> journal), one source key per source row:
  sale:<id>        POS checkout (core.Sale)
      Dr Cash/bKash/Nagad   total - due            (money received)
      Dr Receivable         due                    (sold on credit)
      Dr Sales discounts    discount               (contra-revenue)
         Cr Sales — shop    total + discount       (gross)
      Dr Cost of goods sold Σ qty × cost           (perpetual inventory)
         Cr Inventory       Σ qty × cost
  salevoid:<id>    a voided sale — the exact mirror (Dr<->Cr) of sale:<id>,
                   dated the void day; the original is never deleted.
  khata:<id>       a khata entry (core.KhataEntry)
      customer gave  Dr Receivable / Cr Sales — khata credit
      customer got   Dr Cash / Cr Receivable
      supplier got   Dr Inventory / Cr Payable          (goods on credit)
      supplier gave  Dr Payable / Cr Cash               (payment)
      NO DOUBLE COUNT: the due-sale bridge entry ('[sale#N]') and its void
      ('[void-sale#N]') are skipped — sale:/salevoid: already carry them.
  expense:<id>     Dr <expense account by category> / Cr Cash
  cash:<id>        manual cashbox row: in = Dr Cash / Cr Suspense,
                   out = Dr Suspense / Cr Cash (unclassified until reviewed).
  opening:inventory  Dr Inventory / Cr Opening balance equity (once).

IDEMPOTENT + REVERSIBLE: each posting carries a fingerprint of its source-
derived (date, lines). `plan_sync` compares desired postings with the active
ones: same fingerprint = nothing; changed = reverse old + post new; source gone
= reverse only. Nothing is ever edited or deleted. A date on/before the lock
date moves to the first open day (the original period stays untouched).

I18N: user-facing labels are {'bn','en'} pairs; the app picks one.
"""
import hashlib
import json
from datetime import date, timedelta

# --------------------------------------------------------------------------
# chart of accounts — Bangladesh SME (retail / wholesale shop)
# --------------------------------------------------------------------------
ASSET, LIABILITY, EQUITY, INCOME, EXPENSE = (
    "asset", "liability", "equity", "income", "expense")
TYPES = (ASSET, LIABILITY, EQUITY, INCOME, EXPENSE)
DEBIT_NORMAL = {ASSET, EXPENSE}

# code, type, group, bn, en, contra
CHART = (
    ("1010", ASSET, "current", "হাতে নগদ", "Cash in hand", False),
    ("1020", ASSET, "current", "বিকাশ", "bKash", False),
    ("1030", ASSET, "current", "নগদ (মোবাইল)", "Nagad", False),
    ("1040", ASSET, "current", "ব্যাংক", "Bank", False),
    ("1100", ASSET, "current", "পাওনা (গ্রাহকের বাকি)", "Accounts receivable (customers)", False),
    ("1200", ASSET, "current", "মজুদ মাল", "Inventory (stock)", False),
    ("1300", ASSET, "current", "অগ্রিম ও প্রিপেইড", "Advances & prepayments", False),
    ("1310", ASSET, "current", "উপকরণ কর রেয়াত (ইনপুট ভ্যাট)", "Input VAT receivable", False),
    ("1500", ASSET, "fixed", "আসবাব ও যন্ত্রপাতি", "Furniture & equipment", False),
    ("1510", ASSET, "fixed", "পুঞ্জীভূত অবচয়", "Accumulated depreciation", True),
    ("2010", LIABILITY, "current", "দেনা (সাপ্লায়ার)", "Accounts payable (suppliers)", False),
    ("2100", LIABILITY, "current", "প্রদেয় ভ্যাট (আউটপুট)", "Output VAT payable", False),
    ("2200", LIABILITY, "current", "বকেয়া খরচ", "Accrued expenses", False),
    ("2300", LIABILITY, "long_term", "ঋণ", "Loans payable", False),
    ("2900", LIABILITY, "current", "অশ্রেণীকৃত নগদ (যাচাই বাকি)", "Suspense — unclassified cash", False),
    ("3010", EQUITY, "equity", "মালিকের মূলধন", "Owner's capital", False),
    ("3020", EQUITY, "equity", "মালিকের উত্তোলন", "Owner's drawings", True),
    ("3030", EQUITY, "equity", "শুরুর ব্যালান্স মূলধন", "Opening balance equity", False),
    ("3100", EQUITY, "equity", "সঞ্চিত মুনাফা", "Retained earnings", False),
    ("4010", INCOME, "sales", "বিক্রি — দোকান", "Sales — shop (POS)", False),
    ("4020", INCOME, "sales", "বিক্রি — খাতায় বাকি", "Sales — khata credit", False),
    ("4050", INCOME, "sales", "বিক্রয় ছাড়", "Sales discounts", True),
    ("4100", INCOME, "other_income", "অন্যান্য আয়", "Other income", False),
    ("5010", EXPENSE, "cogs", "বিক্রিত মালের খরচ", "Cost of goods sold", False),
    ("6010", EXPENSE, "operating", "দোকান ভাড়া", "Rent", False),
    ("6020", EXPENSE, "operating", "বেতন ও মজুরি", "Salaries & wages", False),
    ("6030", EXPENSE, "operating", "বিদ্যুৎ, গ্যাস, পানি", "Utilities", False),
    ("6040", EXPENSE, "operating", "পরিবহন ও ডেলিভারি", "Transport & delivery", False),
    ("6050", EXPENSE, "operating", "মোবাইল ও ইন্টারনেট", "Phone & internet", False),
    ("6060", EXPENSE, "operating", "বিজ্ঞাপন ও প্রচার", "Marketing & ads", False),
    ("6070", EXPENSE, "operating", "মেরামত ও রক্ষণাবেক্ষণ", "Repairs & maintenance", False),
    ("6080", EXPENSE, "operating", "ব্যাংক ও বিকাশ চার্জ", "Bank & MFS charges", False),
    ("6090", EXPENSE, "operating", "প্যাকেজিং", "Packaging", False),
    ("6100", EXPENSE, "operating", "আপ্যায়ন ও খাবার", "Food & entertainment", False),
    ("6110", EXPENSE, "operating", "লাইসেন্স, ফি ও কর", "Licences, fees & taxes", False),
    ("6900", EXPENSE, "operating", "অন্যান্য খরচ", "Other expenses", False),
)
ACC = {c[0]: {"code": c[0], "type": c[1], "group": c[2], "name": {"bn": c[3], "en": c[4]},
              "contra": c[5]} for c in CHART}

CASH, BKASH, NAGAD = "1010", "1020", "1030"
AR, INVENTORY, AP, SUSPENSE = "1100", "1200", "2010", "2900"
OPENING_EQ, RETAINED = "3030", "3100"
SALES_POS, SALES_KHATA, DISCOUNT = "4010", "4020", "4050"
COGS, OTHER_EXP = "5010", "6900"
METHOD_ACCOUNT = {"cash": CASH, "bkash": BKASH, "nagad": NAGAD, "due": CASH}

# expense category -> account (keywords, bn + en, lower-case substring match)
EXPENSE_KEYWORDS = (
    ("6010", ("rent", "ভাড়া", "ভাড়া")),
    ("6020", ("salary", "salaries", "wage", "staff", "বেতন", "মজুরি")),
    ("6030", ("electric", "utility", "utilities", "gas", "water", "bill",
              "বিদ্যুৎ", "বিদ্যুৎ", "গ্যাস", "পানি", "কারেন্ট")),
    ("6040", ("transport", "delivery", "courier", "fuel", "rickshaw", "van",
              "পরিবহন", "ডেলিভারি", "কুরিয়ার", "তেল")),
    ("6050", ("mobile", "phone", "internet", "recharge", "wifi", "মোবাইল", "ইন্টারনেট", "রিচার্জ")),
    ("6060", ("marketing", "ads", "advert", "boost", "facebook", "promotion", "বিজ্ঞাপন", "প্রচার")),
    ("6070", ("repair", "maintenance", "মেরামত")),
    ("6080", ("bank charge", "fee bkash", "cash out", "cashout", "charge", "চার্জ")),
    ("6090", ("packag", "polybag", "carton", "প্যাকেট", "প্যাকেজিং")),
    ("6100", ("food", "tea", "snack", "entertain", "খাবার", "চা", "নাস্তা", "আপ্যায়ন")),
    ("6110", ("licence", "license", "trade", "tax", "fee", "লাইসেন্স", "ফি", "কর")),
)


def expense_account(category, note=""):
    """Pick the expense account for a free-text category (first match wins)."""
    text = ("%s %s" % (category or "", note or "")).strip().lower()
    for code, words in EXPENSE_KEYWORDS:
        if any(w in text for w in words):
            return code
    return OTHER_EXP


# --------------------------------------------------------------------------
# entries
# --------------------------------------------------------------------------
class Unbalanced(ValueError):
    pass


def line(account, debit=0, credit=0, party=""):
    return {"account": account, "debit": int(debit), "credit": int(credit),
            "party": (party or "")[:120]}


def _clean(lines):
    """Drop zero lines, fold negatives onto the other side, validate codes."""
    out = []
    for ln in lines:
        d, c = int(ln.get("debit") or 0), int(ln.get("credit") or 0)
        if d < 0:
            c, d = c - d, 0
        if c < 0:
            d, c = d - c, 0
        net = d - c
        if net == 0:
            continue
        if ln["account"] not in ACC:
            raise ValueError("unknown account %r" % ln["account"])
        out.append({"account": ln["account"], "debit": max(net, 0),
                    "credit": max(-net, 0), "party": ln.get("party", "")})
    return out


def make_entry(source_key, day, lines, memo):
    """A balanced posting (or None when every line is zero). Raises Unbalanced."""
    ls = _clean(lines)
    if not ls:
        return None
    dr = sum(l["debit"] for l in ls)
    cr = sum(l["credit"] for l in ls)
    if dr != cr:
        raise Unbalanced("%s: debit %d != credit %d" % (source_key, dr, cr))
    e = {"source_key": source_key, "date": day, "lines": ls, "memo": memo,
         "total": dr}
    e["fingerprint"] = fingerprint(e)
    return e


def fingerprint(e):
    body = json.dumps({"d": str(e["date"]),
                       "l": sorted([l["account"], l["debit"], l["credit"], l["party"]]
                                   for l in e["lines"])}, sort_keys=True)
    return hashlib.sha256(body.encode()).hexdigest()[:32]


def mirror(lines):
    return [{"account": l["account"], "debit": l["credit"], "credit": l["debit"],
             "party": l.get("party", "")} for l in lines]


def _m(bn, en):
    return {"bn": bn, "en": en}


# --------------------------------------------------------------------------
# posting rules — sources arrive as plain dicts (see core.ledger_service)
# --------------------------------------------------------------------------
def post_sale(s):
    """s: {id, date, total, discount, due, payment_method, customer, cogs}"""
    total = max(int(s.get("total") or 0), 0)
    disc = max(int(s.get("discount") or 0), 0)
    due = min(max(int(s.get("due") or 0), 0), total)
    cogs = max(int(s.get("cogs") or 0), 0)
    party = s.get("customer") or ""
    method = METHOD_ACCOUNT.get(s.get("payment_method") or "cash", CASH)
    lines = [line(method, debit=total - due),
             line(AR, debit=due, party=party),
             line(DISCOUNT, debit=disc),
             line(SALES_POS, credit=total + disc),
             line(COGS, debit=cogs),
             line(INVENTORY, credit=cogs)]
    return make_entry("sale:%s" % s["id"], s["date"], lines,
                      _m("দোকানে বিক্রি #%s" % s["id"], "Shop sale #%s" % s["id"]))


def post_sale_void(s):
    """The mirror of post_sale(s), dated s['void_date']."""
    orig = post_sale(s)
    if orig is None:
        return None
    return make_entry("salevoid:%s" % s["id"], s["void_date"], mirror(orig["lines"]),
                      _m("বিক্রি বাতিল #%s" % s["id"], "Sale #%s voided" % s["id"]))


# acctui: '[acct#<client_id>]' = a khata / expense row written by the simple
# entry screen; core.ledger_entry_service posts it with its real money account.
BRIDGE_MARKERS = ("[sale#", "[void-sale#", "[acct#")


def is_bridge(note):
    """A khata row the POS wrote for a due sale (or its void) — already in sale:."""
    n = note or ""
    return any(m in n for m in BRIDGE_MARKERS)


def post_khata(k):
    """k: {id, date, book 'customer'|'supplier', direction 'gave'|'got',
    amount, party, note}. None for bridge rows and zero amounts."""
    if is_bridge(k.get("note")):
        return None
    amt = max(int(k.get("amount") or 0), 0)
    p = k.get("party") or ""
    book, d = k.get("book"), k.get("direction")
    if book == "customer" and d == "gave":
        lines = [line(AR, debit=amt, party=p), line(SALES_KHATA, credit=amt)]
        memo = _m("খাতায় বাকি — %s" % p, "Credit sale (khata) — %s" % p)
    elif book == "customer":
        lines = [line(CASH, debit=amt), line(AR, credit=amt, party=p)]
        memo = _m("বাকি আদায় — %s" % p, "Due collected — %s" % p)
    elif d == "got":
        lines = [line(INVENTORY, debit=amt), line(AP, credit=amt, party=p)]
        memo = _m("সাপ্লায়ার থেকে মাল — %s" % p, "Goods from supplier — %s" % p)
    else:
        lines = [line(AP, debit=amt, party=p), line(CASH, credit=amt)]
        memo = _m("সাপ্লায়ারকে টাকা — %s" % p, "Paid supplier — %s" % p)
    return make_entry("khata:%s" % k["id"], k["date"], lines, memo)


def post_expense(x):
    """x: {id, date, amount, category, note}"""
    if is_bridge(x.get("note")):     # acctui: posted by the simple entry layer
        return None
    amt = max(int(x.get("amount") or 0), 0)
    acc = expense_account(x.get("category"), x.get("note"))
    label = x.get("category") or x.get("note") or ""
    return make_entry("expense:%s" % x["id"], x["date"],
                      [line(acc, debit=amt), line(CASH, credit=amt)],
                      _m("খরচ — %s" % label, "Expense — %s" % label))


def post_cash(c):
    """c: {id, date, kind 'in'|'out', amount, note} — manual drawer row."""
    amt = max(int(c.get("amount") or 0), 0)
    if c.get("kind") == "in":
        lines = [line(CASH, debit=amt), line(SUSPENSE, credit=amt)]
    else:
        lines = [line(SUSPENSE, debit=amt), line(CASH, credit=amt)]
    n = c.get("note") or ""
    return make_entry("cash:%s" % c["id"], c["date"], lines,
                      _m("ক্যাশবক্স (যাচাই বাকি) — %s" % n,
                         "Cashbox (to classify) — %s" % n))


def post_opening_inventory(day, amount):
    amount = max(int(amount or 0), 0)
    return make_entry("opening:inventory", day,
                      [line(INVENTORY, debit=amount), line(OPENING_EQ, credit=amount)],
                      _m("শুরুর মজুদ মাল", "Opening inventory"))


def opening_inventory(stock_value_now, cogs_posted, supplier_goods):
    """Value of stock on the books' start day, reconstructed:
    today's stock value + cost of everything sold since − goods bought since.
    Returns (amount, warning|None); never negative."""
    v = int(stock_value_now) + int(cogs_posted) - int(supplier_goods)
    if v < 0:
        return 0, _m("শুরুর মজুদ ঋণাত্মক হিসাব হয়েছে — ০ ধরা হলো; স্টক গুনে ঠিক করুন।",
                     "Opening stock worked out negative — set to 0; please count stock.")
    return v, None


def desired_postings(sales=(), khata=(), expenses=(), cash=(), opening=None):
    """{source_key: posting} for every source row (bridge rows excluded)."""
    out = {}
    for s in sales:
        e = post_sale(s)
        if e:
            out[e["source_key"]] = e
        if s.get("void_date"):
            v = post_sale_void(s)
            if v:
                out[v["source_key"]] = v
    for fn, rows in ((post_khata, khata), (post_expense, expenses), (post_cash, cash)):
        for r in rows:
            e = fn(r)
            if e:
                out[e["source_key"]] = e
    if opening:
        out[opening["source_key"]] = opening
    return out


# --------------------------------------------------------------------------
# sync plan
# --------------------------------------------------------------------------
def open_day(day, lock_date):
    """The posting date: `day`, or the first day after the lock date."""
    if lock_date and day <= lock_date:
        return lock_date + timedelta(days=1)
    return day


def plan_sync(desired, active, lock_date=None):
    """desired: {source_key: posting}; active: {source_key: {id, fingerprint,
    date, lines}} (the posted, not-yet-reversed entries).
    Returns {'post': [posting], 'reverse': [{id, date, lines, source_key}],
    'unchanged': n}. Every posting date respects the lock date."""
    post, reverse, same = [], [], 0
    for key, act in active.items():
        want = desired.get(key)
        if want is not None and want["fingerprint"] == act["fingerprint"]:
            same += 1
            continue
        reverse.append({"id": act["id"], "source_key": key,
                        "date": open_day(act["date"], lock_date),
                        "lines": mirror(act["lines"])})
    for key, want in desired.items():
        act = active.get(key)
        if act is not None and act["fingerprint"] == want["fingerprint"]:
            continue
        p = dict(want)
        p["date"] = open_day(want["date"], lock_date)
        p["late"] = p["date"] != want["date"]
        post.append(p)
    post.sort(key=lambda p: (p["date"], p["source_key"]))
    return {"post": post, "reverse": reverse, "unchanged": same}


# --------------------------------------------------------------------------
# reports — `lines` is a list of {account, debit, credit, date}
# --------------------------------------------------------------------------
def _in(d, start, end):
    return (start is None or d >= start) and (end is None or d <= end)


def balances(lines, start=None, end=None):
    """{account: debit - credit} over lines dated in [start, end]."""
    b = {}
    for l in lines:
        if _in(l["date"], start, end):
            b[l["account"]] = b.get(l["account"], 0) + int(l["debit"]) - int(l["credit"])
    return b


def _row(code, amount):
    a = ACC[code]
    return {"code": code, "name": a["name"], "type": a["type"],
            "group": a["group"], "amount": amount}


def trial_balance(lines, end=None):
    b = balances(lines, None, end)
    rows, dr, cr = [], 0, 0
    for code in sorted(b):
        net = b[code]
        if net == 0:
            continue
        r = _row(code, abs(net))
        r["debit"], r["credit"] = (net, 0) if net > 0 else (0, -net)
        dr += r["debit"]
        cr += r["credit"]
        rows.append(r)
    return {"as_of": str(end) if end else None, "rows": rows,
            "total_debit": dr, "total_credit": cr, "balanced": dr == cr}


def profit_and_loss(lines, start=None, end=None):
    b = balances(lines, start, end)

    def inc(codes):   # income shown positive (credit balance)
        return [_row(c, -b[c]) for c in sorted(codes) if b.get(c)]

    def exp(codes):
        return [_row(c, b[c]) for c in sorted(codes) if b.get(c)]

    sales = inc(c for c in b if ACC[c]["group"] == "sales" and not ACC[c]["contra"])
    discounts = exp(c for c in b if ACC[c]["group"] == "sales" and ACC[c]["contra"])
    gross_sales = sum(r["amount"] for r in sales)
    disc_total = sum(r["amount"] for r in discounts)
    net_sales = gross_sales - disc_total
    cogs = exp(c for c in b if ACC[c]["group"] == "cogs")
    cogs_total = sum(r["amount"] for r in cogs)
    gross_profit = net_sales - cogs_total
    opex = exp(c for c in b if ACC[c]["group"] == "operating")
    opex_total = sum(r["amount"] for r in opex)
    other = inc(c for c in b if ACC[c]["group"] == "other_income")
    other_total = sum(r["amount"] for r in other)
    net = gross_profit - opex_total + other_total
    return {"from": str(start) if start else None, "to": str(end) if end else None,
            "sales": sales, "gross_sales": gross_sales,
            "discounts": discounts, "discounts_total": disc_total,
            "net_sales": net_sales, "cogs": cogs, "cogs_total": cogs_total,
            "gross_profit": gross_profit,
            "gross_margin_pct": round(gross_profit * 100.0 / net_sales, 1) if net_sales else None,
            "operating_expenses": opex, "operating_expenses_total": opex_total,
            "other_income": other, "other_income_total": other_total,
            "net_profit": net}


def balance_sheet(lines, end=None):
    """Assets = Liabilities + Equity (+ profit not yet closed into retained)."""
    b = balances(lines, None, end)

    def section(t, sign):
        rows = [_row(c, sign * b[c]) for c in sorted(b)
                if b[c] and ACC[c]["type"] == t]
        return rows, sum(r["amount"] for r in rows)

    assets, ta = section(ASSET, 1)
    liabilities, tl = section(LIABILITY, -1)
    equity, te = section(EQUITY, -1)
    profit = -sum(v for c, v in b.items() if ACC[c]["type"] in (INCOME, EXPENSE))
    total_eq = te + profit
    return {"as_of": str(end) if end else None,
            "assets": assets, "total_assets": ta,
            "liabilities": liabilities, "total_liabilities": tl,
            "equity": equity, "profit_to_date": profit, "total_equity": total_eq,
            "total_liabilities_equity": tl + total_eq,
            "balanced": ta == tl + total_eq}


def accounts_payload():
    return [{"code": c[0], "type": c[1], "group": c[2],
             "name": {"bn": c[3], "en": c[4]}, "contra": c[5]} for c in CHART]


def parse_day(s, default=None):
    try:
        return date.fromisoformat(str(s)[:10]) if s else default
    except ValueError:
        return default
