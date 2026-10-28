"""
business_khata.py — pure-logic layer for Assisto Business v2 Digital Khata +
Cashbox (BUSINESS_V2_PLAN.md §2). NO Django imports; every function takes plain
dicts/ints and returns plain dicts, so it is deterministic and unit-testable in
isolation (the views layer feeds it ORM rows and persists results).

Scope (free tier, bookkeeping only — we NEVER hold money / act as a wallet):
  - Two-sided ledger: customer receivables (বাকি) + supplier payables (দেনা).
    Each entry: {party_id, direction('gave'|'got'), amount, note, at,
    bill_photo_ref?}. Running balance per party; partial payments; per-party
    statement/history; net position across all parties.
  - Tagada (দেনা আদায়) reminder planners: single + bulk + scheduled. Produces
    bilingual {bn,en} MESSAGE TEXT + a share-descriptor
    {channel, to, text}. WhatsApp share always; SMS only when a provider key is
    present (gated by a bool param; mocked here).
  - Optional "entry added" courtesy message to the customer on a new due.
  - Cashbox: opening cash, cash in/out entries, end-of-day reconciliation
    (expected vs counted → variance).
  - Per-customer statement PDF DATA model (structured dict a PDF layer renders;
    NO PDF generated here).

MONEY: all amounts are **integer poisha** (১ টাকা = ১০০ পয়সা). Integers never
drift. Inputs may arrive as int poisha, or as a Decimal/str/float of TAKA — use
`to_poisha()` at the boundary; everything internal is int. Display uses
`taka_str()` / `fmt_amount()`.

I18N: every user-facing string is returned as a {'bn':..., 'en':...} pair; the
Flutter layer picks. We never mix the two languages inside one string.

OFFLINE-FIRST: pure + deterministic. No wall clock — the caller passes `now`
(an ISO-8601 string) wherever a timestamp is needed.
"""
from decimal import Decimal, ROUND_HALF_UP

# ---------------------------------------------------------------------------
# money: integer poisha (no float drift, ever)
# ---------------------------------------------------------------------------

POISHA_PER_TAKA = 100
_TAKA = Decimal("1")
_HUNDRED = Decimal("100")

# Bangla numeral map (reused style from money_parse.py).
_EN2BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_BN2EN = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def normalize_digits(s):
    """Bangla numerals -> ASCII (so taka strings parse regardless of script)."""
    return (s or "").translate(_BN2EN)


def to_poisha(v):
    """Coerce an amount to **integer poisha**.

    Rules:
      - int           -> already poisha (pass through).
      - Decimal/float/str of TAKA -> rounded to the nearest poisha.
      - None/"" / junk -> 0.
    Accepts Bangla numerals and a leading ৳/Tk/,. Never raises on junk.
    """
    if v is None or v == "":
        return 0
    if isinstance(v, bool):  # guard: bool is an int subclass
        return 0
    if isinstance(v, int):
        return v
    if isinstance(v, Decimal):
        return int((v * _HUNDRED).quantize(_TAKA, rounding=ROUND_HALF_UP))
    if isinstance(v, float):
        return int((Decimal(str(v)) * _HUNDRED).quantize(_TAKA, rounding=ROUND_HALF_UP))
    # string: strip currency markers / separators, allow Bangla digits
    import re
    t = normalize_digits(str(v))
    t = re.sub(r"[^\d.\-]", "", t)
    if t in ("", ".", "-", "-."):
        return 0
    try:
        return int((Decimal(t) * _HUNDRED).quantize(_TAKA, rounding=ROUND_HALF_UP))
    except Exception:
        return 0


def taka_str(poisha, lang="en"):
    """Format integer poisha as a taka string. '12550' -> '125.50' (en) /
    '১২৫.৫০' (bn). Always two decimals; no currency symbol (callers add ৳)."""
    p = int(poisha)
    sign = "-" if p < 0 else ""
    p = abs(p)
    taka, rem = divmod(p, POISHA_PER_TAKA)
    s = f"{sign}{taka}.{rem:02d}"
    return s.translate(_EN2BN) if lang == "bn" else s


def fmt_amount(poisha):
    """A {bn,en} pair with the ৳ symbol, e.g. {'bn':'৳১২৫.৫০','en':'৳125.50'}."""
    return {"bn": "৳" + taka_str(poisha, "bn"), "en": "৳" + taka_str(poisha, "en")}


def bn_en(bn, en):
    """Build a {bn,en} pair. Kept tiny + explicit so strings are never mixed."""
    return {"bn": bn, "en": en}


# ---------------------------------------------------------------------------
# two-sided ledger — customer receivables (বাকি) + supplier payables (দেনা)
# ---------------------------------------------------------------------------
#
# ONE entry shape, used for both books:
#   {party_id, direction, amount, note, at, bill_photo_ref?}
# `direction` is from the OWNER's point of view and is book-dependent:
#
#   CUSTOMER book (receivables / বাকি):
#     'gave' = owner gave goods on credit  -> customer owes MORE (+balance)
#     'got'  = owner got a payment back     -> customer owes LESS (-balance)
#     balance > 0 means the customer owes the owner.
#
#   SUPPLIER book (payables / দেনা):
#     'got'  = owner got goods on credit     -> owner owes MORE (+balance)
#     'gave' = owner gave a payment          -> owner owes LESS (-balance)
#     balance > 0 means the owner owes the supplier.
#
# This mirrors the physical khata: each page is one party, two columns.

CUSTOMER = "customer"
SUPPLIER = "supplier"


def _signed(entry, book):
    """Signed poisha delta an entry applies to a party's running balance."""
    amt = to_poisha(entry.get("amount"))
    direction = entry.get("direction")
    if book == CUSTOMER:
        # owner gave credit (+), owner got payment (-)
        return amt if direction == "gave" else -amt
    # SUPPLIER: owner got goods (+ owes more), owner gave payment (- owes less)
    return amt if direction == "got" else -amt


def running_balance(entries, book):
    """Current signed balance (int poisha) for ONE party in ONE book.

    entries: list of ledger entries for a single party (any order; sorted by
    `at` for determinism). Positive = the OTHER side owes this way (see table
    above). The caller passes only this party's rows."""
    return sum(_signed(e, book) for e in _sorted(entries))


def _sorted(entries):
    """Stable sort by `at` (ISO string) then original index — deterministic."""
    idx = list(enumerate(entries or []))
    idx.sort(key=lambda t: (str(t[1].get("at") or ""), t[0]))
    return [e for _, e in idx]


def party_statement(party, entries, book, lang="en"):
    """Full history for ONE party with a running balance after every entry.

    party: {'id', 'name', 'phone'?, 'area'?}
    Returns a structured dict the UI (or the PDF data model) can render.
    """
    rows = []
    bal = 0
    for e in _sorted(entries):
        delta = _signed(e, book)
        bal += delta
        rows.append({
            "at": e.get("at"),
            "direction": e.get("direction"),
            "amount": to_poisha(e.get("amount")),
            "amount_fmt": fmt_amount(to_poisha(e.get("amount"))),
            "note": e.get("note") or "",
            "bill_photo_ref": e.get("bill_photo_ref"),
            "delta": delta,
            "balance": bal,
            "balance_fmt": fmt_amount(bal),
            # ledger100: pass-through ids so the app can edit / dedupe a row
            "entry_id": e.get("id"),
            "version": e.get("version"),
            "client_id": e.get("client_id") or "",
            "editable": e.get("editable", True),
        })
    return {
        "book": book,
        "party_id": party.get("id"),
        "party_name": party.get("name") or "",
        "party_phone": party.get("phone") or "",
        "entries": rows,
        "balance": bal,
        "balance_fmt": fmt_amount(bal),
        "status": balance_status(bal, book, lang),
        "owes_label": _owes_label(bal, book),
    }


def _owes_label(balance, book):
    """A {bn,en} direction label for who owes whom."""
    if balance == 0:
        return bn_en("পরিশোধিত", "Settled")
    if book == CUSTOMER:
        return (bn_en("গ্রাহক আপনাকে দেবে", "Customer owes you") if balance > 0
                else bn_en("আপনি গ্রাহককে দেবেন", "You owe the customer"))
    # supplier
    return (bn_en("আপনি সরবরাহকারীকে দেবেন", "You owe the supplier") if balance > 0
            else bn_en("সরবরাহকারী আপনাকে দেবে", "Supplier owes you"))


def balance_status(balance, book, lang="en"):
    """A short {bn,en} status line for a party balance."""
    if balance == 0:
        return bn_en("বকেয়া নেই", "No dues")
    amt = fmt_amount(abs(balance))
    if book == CUSTOMER and balance > 0:
        return bn_en(f"বাকি {amt['bn']}", f"Due {amt['en']}")
    if book == SUPPLIER and balance > 0:
        return bn_en(f"দেনা {amt['bn']}", f"Payable {amt['en']}")
    # negative (advance / credit note)
    return bn_en(f"অগ্রিম {amt['bn']}", f"Advance {amt['en']}")


def new_entry(party_id, direction, amount, note="", at=None, bill_photo_ref=None):
    """Build a validated ledger entry dict (pure; caller persists).

    direction must be 'gave' or 'got'; amount coerced to int poisha (>0).
    Raises ValueError on a bad direction or non-positive amount."""
    if direction not in ("gave", "got"):
        raise ValueError("direction must be 'gave' or 'got'")
    amt = to_poisha(amount)
    if amt <= 0:
        raise ValueError("amount must be positive")
    entry = {"party_id": party_id, "direction": direction, "amount": amt,
             "note": note or "", "at": at}
    if bill_photo_ref:
        entry["bill_photo_ref"] = bill_photo_ref
    return entry


def apply_payment(party_id, amount, book, note="", at=None, bill_photo_ref=None):
    """A partial/full payment entry. In the CUSTOMER book a payment is 'got'
    (customer pays owner -> due drops); in the SUPPLIER book it is 'gave' (owner
    pays supplier -> payable drops). Returns a new_entry()."""
    direction = "got" if book == CUSTOMER else "gave"
    return new_entry(party_id, direction, amount, note=note, at=at,
                     bill_photo_ref=bill_photo_ref)


def net_position(customer_balances, supplier_balances):
    """Net position across ALL parties in both books (int poisha).

    customer_balances / supplier_balances: lists of signed per-party balances
    (as returned by running_balance). Returns receivable (what customers owe
    the owner), payable (what the owner owes suppliers), and net."""
    receivable = sum(b for b in customer_balances if b > 0)
    # customers in advance (negative) are a liability to the owner
    customer_advances = sum(-b for b in customer_balances if b < 0)
    payable = sum(b for b in supplier_balances if b > 0)
    supplier_advances = sum(-b for b in supplier_balances if b < 0)
    net = (receivable + supplier_advances) - (payable + customer_advances)
    return {
        "receivable": receivable,
        "receivable_fmt": fmt_amount(receivable),
        "payable": payable,
        "payable_fmt": fmt_amount(payable),
        "customer_advances": customer_advances,
        "supplier_advances": supplier_advances,
        "net": net,
        "net_fmt": fmt_amount(net),
        "label": (bn_en("আপনি এগিয়ে আছেন", "You are ahead") if net >= 0
                  else bn_en("আপনি পিছিয়ে আছেন", "You are behind")),
    }


# ---------------------------------------------------------------------------
# Tagada (তাগাদা) reminder planners — single / bulk / scheduled
# ---------------------------------------------------------------------------
#
# Produces the MESSAGE TEXT as a {bn,en} pair + a share-descriptor
#   {channel, to, text}.
# WhatsApp share is always available (it just opens the share sheet with text).
# SMS is only offered when the caller says a provider key exists (sms_enabled).
# We NEVER embed a payment link we control — only (optionally) the owner's own
# bKash/Nagad number passed in `pay_hint` (plan §6: never hold money).

TAGADA_PRESETS = {
    # tone-slug: (bn_template, en_template). {amount}/{shop}/{name}/{pay} slots.
    "polite": (
        "আসসালামু আলাইকুম {name}। {shop}-এ আপনার বাকি {amount}। "
        "সুবিধামতো পরিশোধ করলে কৃতজ্ঞ থাকব।{pay}",
        "Hello {name}. Your due at {shop} is {amount}. "
        "Kindly clear it at your convenience, thank you.{pay}"),
    "reminder": (
        "প্রিয় {name}, {shop}-এ আপনার {amount} বাকি রয়েছে। "
        "অনুগ্রহ করে পরিশোধ করুন।{pay}",
        "Dear {name}, you have a due of {amount} at {shop}. "
        "Please clear it.{pay}"),
    "firm": (
        "{name}, {shop}-এ আপনার বকেয়া {amount} দীর্ঘদিন ধরে অপরিশোধিত। "
        "দ্রুত পরিশোধের অনুরোধ করছি।{pay}",
        "{name}, your due of {amount} at {shop} has been pending for a while. "
        "Please settle it soon.{pay}"),
    "thanks": (
        "{name}, {shop}-এ আপনার বাকি {amount} পরিশোধের জন্য ধন্যবাদ।",
        "{name}, thank you for clearing your {amount} due at {shop}."),
}


def _pay_hint_text(pay_hint, lang):
    """Optional 'pay to <owner bKash/Nagad>' suffix. pay_hint:
    {'method':'bKash'|'Nagad','number':'017...'} — the OWNER's own merchant
    number (we never create a wallet)."""
    if not pay_hint or not pay_hint.get("number"):
        return ""
    method = pay_hint.get("method") or ("bKash")
    num = pay_hint.get("number")
    if lang == "bn":
        return f" পরিশোধ: {method} {normalize_digits_out(num)}।"
    return f" Pay to {method}: {num}."


def normalize_digits_out(s):
    """ASCII digits -> Bangla (for bn message bodies)."""
    return (s or "").translate(_EN2BN)


def tagada_message(party, balance, shop_name="", preset="polite",
                   pay_hint=None, lang=None):
    """Build the bilingual tagada MESSAGE TEXT for one party.

    party: {'name', ...}; balance: signed int poisha for the CUSTOMER book
    (only a positive due is chased). Returns a {bn,en} pair. If `lang` is given,
    returns that single language's string instead (convenience for the share
    descriptor); otherwise returns the pair."""
    bn_t, en_t = TAGADA_PRESETS.get(preset, TAGADA_PRESETS["polite"])
    name = party.get("name") or ""
    shop = shop_name or ""
    due = fmt_amount(abs(balance))
    bn = bn_t.format(name=name, shop=shop, amount=due["bn"],
                     pay=_pay_hint_text(pay_hint, "bn"))
    en = en_t.format(name=name, shop=shop, amount=due["en"],
                     pay=_pay_hint_text(pay_hint, "en"))
    pair = bn_en(bn, en)
    if lang in ("bn", "en"):
        return pair[lang]
    return pair


def share_descriptor(channel, to, text, sms_enabled=False):
    """Build a {channel,to,text,available,reason?} share descriptor.

    channel: 'whatsapp_share' (always available) or 'sms' (only when
    sms_enabled, i.e. a provider key is configured — mocked via the bool).
    `text` is a single-language string the caller already picked."""
    if channel == "whatsapp_share":
        return {"channel": "whatsapp_share", "to": to, "text": text,
                "available": True}
    if channel == "sms":
        if sms_enabled:
            return {"channel": "sms", "to": to, "text": text, "available": True}
        return {"channel": "sms", "to": to, "text": text, "available": False,
                "reason": bn_en("SMS প্রদানকারী কী যুক্ত করা হয়নি",
                                "SMS provider key not configured")}
    raise ValueError("channel must be 'whatsapp_share' or 'sms'")


def plan_tagada_single(party, balance, shop_name="", preset="polite",
                       pay_hint=None, channel="whatsapp_share",
                       sms_enabled=False, lang="bn"):
    """Plan one tagada reminder. Returns the bilingual message pair + a
    share-descriptor built with the picked `lang`. Returns None (skipped) when
    there is no positive due to chase."""
    if balance <= 0:
        return None
    pair = tagada_message(party, balance, shop_name=shop_name, preset=preset,
                          pay_hint=pay_hint)
    text = pair[lang] if lang in ("bn", "en") else pair["bn"]
    share = share_descriptor(channel, party.get("phone") or "", text,
                             sms_enabled=sms_enabled)
    return {"party_id": party.get("id"), "party_name": party.get("name") or "",
            "balance": balance, "balance_fmt": fmt_amount(balance),
            "message": pair, "share": share}


def plan_tagada_bulk(parties_with_balances, shop_name="", preset="polite",
                     pay_hint=None, channel="whatsapp_share", sms_enabled=False,
                     lang="bn", min_due=0):
    """Plan tagada for many parties at once.

    parties_with_balances: list of {'party': {...}, 'balance': int_poisha}.
    Only parties whose due > max(0, min_due) are included. Returns a list of
    per-party plans (same shape as plan_tagada_single)."""
    threshold = max(0, to_poisha(min_due))
    plans = []
    for row in parties_with_balances:
        bal = int(row.get("balance") or 0)
        if bal <= threshold:
            continue
        plan = plan_tagada_single(
            row.get("party") or {}, bal, shop_name=shop_name, preset=preset,
            pay_hint=pay_hint, channel=channel, sms_enabled=sms_enabled, lang=lang)
        if plan:
            plans.append(plan)
    return {"count": len(plans), "total_due": sum(p["balance"] for p in plans),
            "total_due_fmt": fmt_amount(sum(p["balance"] for p in plans)),
            "plans": plans}


def plan_tagada_scheduled(party, balance, schedule, now, shop_name="",
                          preset="reminder", pay_hint=None,
                          channel="whatsapp_share", sms_enabled=False, lang="bn"):
    """Decide whether a SCHEDULED tagada is due to fire at `now`.

    schedule: {'next_at': ISO-8601 string} — the next time this reminder should
    fire (the caller computes cadence; this layer just compares to `now`, since
    we hold no clock). `now`: ISO-8601 string.
    Returns {'due': bool, 'plan': <plan or None>, 'next_at': ...}."""
    next_at = (schedule or {}).get("next_at")
    due = bool(next_at) and str(now) >= str(next_at) and balance > 0
    plan = None
    if due:
        plan = plan_tagada_single(party, balance, shop_name=shop_name,
                                  preset=preset, pay_hint=pay_hint,
                                  channel=channel, sms_enabled=sms_enabled, lang=lang)
    return {"due": due, "next_at": next_at, "plan": plan}


def entry_added_message(party, entry, shop_name="", lang=None):
    """Optional courtesy message to a CUSTOMER when a new due is added
    ("আপনার খাতায় ৳৫০০ যোগ হলো"). Only meaningful for a 'gave' (credit) entry.
    Returns a {bn,en} pair (or a single string if lang given), or None."""
    if entry.get("direction") != "gave":
        return None
    amt = fmt_amount(to_poisha(entry.get("amount")))
    shop = shop_name or ""
    bn = (f"{party.get('name') or ''}, {shop}-এ আপনার খাতায় {amt['bn']} "
          f"বাকি যোগ হলো।").strip()
    en = (f"{party.get('name') or ''}, {amt['en']} was added to your due "
          f"at {shop}.").strip()
    pair = bn_en(bn, en)
    return pair[lang] if lang in ("bn", "en") else pair


# ---------------------------------------------------------------------------
# Cashbox — opening cash, cash in/out, end-of-day reconciliation
# ---------------------------------------------------------------------------
#
# A cash entry: {kind:'in'|'out', amount, note, at, ref?}.
# All amounts int poisha. We track the drawer; we never move real money.

CASH_IN = "in"
CASH_OUT = "out"


def cash_entry(kind, amount, note="", at=None, ref=None):
    """Build a validated cashbox entry. kind 'in'|'out'; amount>0 poisha."""
    if kind not in (CASH_IN, CASH_OUT):
        raise ValueError("kind must be 'in' or 'out'")
    amt = to_poisha(amount)
    if amt <= 0:
        raise ValueError("amount must be positive")
    e = {"kind": kind, "amount": amt, "note": note or "", "at": at}
    if ref:
        e["ref"] = ref
    return e


def cashbox_expected(opening_cash, entries):
    """Expected drawer cash (int poisha) = opening + ins - outs."""
    opening = to_poisha(opening_cash)
    total_in = sum(to_poisha(e.get("amount")) for e in entries
                   if e.get("kind") == CASH_IN)
    total_out = sum(to_poisha(e.get("amount")) for e in entries
                    if e.get("kind") == CASH_OUT)
    return opening + total_in - total_out


def cashbox_summary(opening_cash, entries, lang="en"):
    """Full cashbox snapshot: opening, totals, expected close, entry ledger."""
    opening = to_poisha(opening_cash)
    total_in = sum(to_poisha(e.get("amount")) for e in entries
                   if e.get("kind") == CASH_IN)
    total_out = sum(to_poisha(e.get("amount")) for e in entries
                    if e.get("kind") == CASH_OUT)
    expected = opening + total_in - total_out
    ledger = []
    bal = opening
    for e in _sorted_cash(entries):
        amt = to_poisha(e.get("amount"))
        bal += amt if e.get("kind") == CASH_IN else -amt
        ledger.append({
            "at": e.get("at"), "kind": e.get("kind"),
            "amount": amt, "amount_fmt": fmt_amount(amt),
            "note": e.get("note") or "", "ref": e.get("ref"),
            "balance": bal, "balance_fmt": fmt_amount(bal),
        })
    return {
        "opening": opening, "opening_fmt": fmt_amount(opening),
        "total_in": total_in, "total_in_fmt": fmt_amount(total_in),
        "total_out": total_out, "total_out_fmt": fmt_amount(total_out),
        "expected": expected, "expected_fmt": fmt_amount(expected),
        "entry_count": len(entries or []),
        "ledger": ledger,
    }


def _sorted_cash(entries):
    idx = list(enumerate(entries or []))
    idx.sort(key=lambda t: (str(t[1].get("at") or ""), t[0]))
    return [e for _, e in idx]


def reconcile_cashbox(opening_cash, entries, counted_cash, now=None, lang="en"):
    """End-of-day reconciliation: expected vs counted -> variance.

    variance = counted - expected. Positive = surplus (too much cash, maybe an
    unrecorded sale); negative = shortage (missing cash). Returns a structured
    result incl. a bilingual status pair."""
    expected = cashbox_expected(opening_cash, entries)
    counted = to_poisha(counted_cash)
    variance = counted - expected
    if variance == 0:
        status = bn_en("মিলে গেছে", "Balanced")
        state = "balanced"
    elif variance > 0:
        status = bn_en(f"উদ্বৃত্ত {fmt_amount(variance)['bn']}",
                       f"Surplus {fmt_amount(variance)['en']}")
        state = "surplus"
    else:
        status = bn_en(f"ঘাটতি {fmt_amount(-variance)['bn']}",
                       f"Shortage {fmt_amount(-variance)['en']}")
        state = "shortage"
    return {
        "at": now,
        "expected": expected, "expected_fmt": fmt_amount(expected),
        "counted": counted, "counted_fmt": fmt_amount(counted),
        "variance": variance, "variance_fmt": fmt_amount(variance),
        "state": state, "status": status,
        "balanced": variance == 0,
    }


# ---------------------------------------------------------------------------
# Per-customer statement PDF DATA model (structured dict — NO PDF here)
# ---------------------------------------------------------------------------

def statement_pdf_data(business, party, entries, book=CUSTOMER,
                       period=None, now=None, lang="en"):
    """Assemble everything a PDF layer needs to render a party statement.

    business: {'shop_name','phone'?,'address'?}
    party:    {'id','name','phone'?,'area'?}
    entries:  this party's ledger rows in this book.
    period:   optional {'from': ISO, 'to': ISO} — rows OUTSIDE it are kept as an
              opening-balance carry so the running balance stays correct.
    Returns a structured dict (all strings as {bn,en} where user-facing).
    NO PDF is generated here — the Flutter/PDF layer renders this.
    """
    rows_sorted = _sorted(entries)
    opening_balance = 0
    in_period = rows_sorted
    if period and (period.get("from") or period.get("to")):
        frm, to = period.get("from"), period.get("to")
        before, within = [], []
        for e in rows_sorted:
            at = str(e.get("at") or "")
            if frm and at < str(frm):
                before.append(e)
            elif to and at > str(to):
                pass  # future rows excluded from this statement period
            else:
                within.append(e)
        opening_balance = sum(_signed(e, book) for e in before)
        in_period = within

    lines = []
    bal = opening_balance
    total_gave = total_got = 0
    for e in in_period:
        delta = _signed(e, book)
        bal += delta
        amt = to_poisha(e.get("amount"))
        if e.get("direction") == "gave":
            total_gave += amt
        else:
            total_got += amt
        lines.append({
            "at": e.get("at"),
            "particular": e.get("note") or "",
            "direction": e.get("direction"),
            "debit": amt if delta > 0 else 0,
            "credit": amt if delta < 0 else 0,
            "amount_fmt": fmt_amount(amt),
            "balance": bal, "balance_fmt": fmt_amount(bal),
            "bill_photo_ref": e.get("bill_photo_ref"),
        })

    closing = bal
    return {
        "doc_type": "customer_statement" if book == CUSTOMER else "supplier_statement",
        "generated_at": now,
        "lang_hint": lang,
        "shop": {
            "name": (business or {}).get("shop_name") or "",
            "phone": (business or {}).get("phone") or "",
            "address": (business or {}).get("address") or "",
        },
        "party": {
            "id": party.get("id"), "name": party.get("name") or "",
            "phone": party.get("phone") or "", "area": party.get("area") or "",
        },
        "period": period or None,
        "headers": {
            "title": (bn_en("গ্রাহক বিবরণী", "Customer Statement") if book == CUSTOMER
                      else bn_en("সরবরাহকারী বিবরণী", "Supplier Statement")),
            "date": bn_en("তারিখ", "Date"),
            "particular": bn_en("বিবরণ", "Particulars"),
            "debit": bn_en("বাকি", "Debit") if book == CUSTOMER else bn_en("দেনা", "Debit"),
            "credit": bn_en("জমা", "Credit"),
            "balance": bn_en("ব্যালেন্স", "Balance"),
            "opening": bn_en("প্রারম্ভিক ব্যালেন্স", "Opening Balance"),
            "closing": bn_en("সমাপনী ব্যালেন্স", "Closing Balance"),
        },
        "opening_balance": opening_balance,
        "opening_balance_fmt": fmt_amount(opening_balance),
        "lines": lines,
        "totals": {
            "gave": total_gave, "gave_fmt": fmt_amount(total_gave),
            "got": total_got, "got_fmt": fmt_amount(total_got),
            "closing_balance": closing, "closing_balance_fmt": fmt_amount(closing),
        },
        "status": balance_status(closing, book, lang),
        "owes_label": _owes_label(closing, book),
        # footer disclaimer — we are a bookkeeping tool, not a lender/wallet.
        "footer": bn_en(
            "এই বিবরণী শুধুমাত্র হিসাব রক্ষার জন্য। Assisto কোনো অর্থ লেনদেন করে না।",
            "This statement is for bookkeeping only. Assisto does not handle money."),
    }


# ---------------------------------------------------------------------------
# ledger100 — per-customer reminder links, app-facing statement lines,
# scheduled-reminder cadence. Pure (no DB, no clock).
# ---------------------------------------------------------------------------

def bd_msisdn(phone):
    """'01712-345678' / '+8801712345678' / '১৭১২…' → '8801712345678' (the
    form wa.me wants), or '' when it is not a Bangladesh mobile number."""
    import re
    d = re.sub(r"\D", "", normalize_digits(str(phone or "")))
    if d.startswith("880"):
        d = d[3:]
    elif d.startswith("88") and len(d) == 13:
        d = d[2:]
    if len(d) == 10 and d.startswith("1"):
        d = "0" + d
    if len(d) == 11 and d.startswith("01") and d[2] in "3456789":
        return "88" + d
    return ""


def wa_link(phone, text):
    """A wa.me deep link for ONE customer (empty when the phone is unusable —
    the app then offers the plain share sheet instead)."""
    from urllib.parse import quote
    m = bd_msisdn(phone)
    if not m:
        return ""
    return "https://wa.me/%s?text=%s" % (m, quote(text or "", safe=""))


def sms_uri(phone, text):
    """An `sms:` composer link (the user's own phone sends it, not Assisto)."""
    from urllib.parse import quote
    m = bd_msisdn(phone)
    if not m:
        return ""
    return "sms:+%s?body=%s" % (m, quote(text or "", safe=""))


_BN_MONTHS = ("জানু", "ফেব্রু", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই", "আগস্ট",
              "সেপ্টে", "অক্টো", "নভে", "ডিসে")
_EN_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep",
              "Oct", "Nov", "Dec")


def day_label(iso):
    """'2026-10-27T…' → {'bn': '২৭ অক্টো ২০২৬', 'en': '27 Oct 2026'}."""
    s = str(iso or "")
    try:
        y, mo, d = int(s[0:4]), int(s[5:7]), int(s[8:10])
        if not 1 <= mo <= 12:
            raise ValueError
    except (ValueError, IndexError):
        return bn_en(s, s)
    en = "%d %s %d" % (d, _EN_MONTHS[mo - 1], y)
    bn = ("%d %s %d" % (d, _BN_MONTHS[mo - 1], y)).translate(_EN2BN)
    return bn_en(bn, en)


def statement_lines(stmt, book):
    """The app's row shape for a party_statement(): newest first, each with
    debit/credit/balance display pairs + the entry id/version for editing.

    debit = the side that RAISES the balance (customer: owner gave on credit;
    supplier: owner got goods on credit); credit = a payment."""
    out = []
    for r in stmt.get("entries") or []:
        raises = (r.get("delta") or 0) > 0
        amt = r.get("amount_fmt") or fmt_amount(0)
        if book == CUSTOMER:
            what = (bn_en("বাকি দিলাম", "Gave on credit") if raises
                    else bn_en("টাকা পেলাম", "Payment received"))
        else:
            what = (bn_en("বাকিতে মাল নিলাম", "Goods on credit") if raises
                    else bn_en("টাকা দিলাম", "Payment made"))
        note = (r.get("note") or "").strip()
        part = bn_en("%s — %s" % (what["bn"], note), "%s — %s" % (what["en"], note)) \
            if note else what
        out.append({
            "entry_id": r.get("entry_id"), "version": r.get("version"),
            "client_id": r.get("client_id") or "",
            "editable": bool(r.get("editable", True)),
            "direction": r.get("direction"), "amount": r.get("amount"),
            "note": note, "at": r.get("at"),
            "at_display": day_label(r.get("at")),
            "particulars": part,
            "debit_display": amt if raises else bn_en("", ""),
            "credit_display": bn_en("", "") if raises else amt,
            "balance_display": r.get("balance_fmt"),
        })
    out.reverse()
    return out


SCHEDULE_MAX_INTERVAL_DAYS = 90


def next_fire_at(next_at, interval_days, now):
    """The next firing after one at `next_at` (aware datetimes). interval 0 →
    None (a one-off: it is done). A long-missed schedule (server down) jumps
    to the first slot AFTER `now` instead of firing once per missed slot."""
    from datetime import timedelta
    n = int(interval_days or 0)
    if n <= 0:
        return None
    step = timedelta(days=min(n, SCHEDULE_MAX_INTERVAL_DAYS))
    nxt = next_at + step
    if nxt <= now:
        missed = int((now - nxt) / step) + 1
        nxt = nxt + step * missed
    return nxt
