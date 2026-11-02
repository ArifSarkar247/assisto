"""ledger_service.py — DB layer of Business Accounting (flag accounting_v2).

Reads the shop's existing books (POS sales, khata, expenses, cashbox rows),
turns them into postings with the pure rules (core.logic.ledger) and writes
the journal. `sync_books` is idempotent (fingerprints), serialised per business
(row lock on LedgerBook) and append-only (reversal entries, never edits).
"""
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

from .logic import ledger as L

FLAG = "accounting_v2"


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


def _day(dt):
    if dt is None:
        return None
    if timezone.is_aware(dt):
        return timezone.localtime(dt).date()
    return dt.date() if hasattr(dt, "date") else dt


def _poisha(taka):
    return int((Decimal(str(taka or 0)) * 100).quantize(Decimal("1")))


# ------------------------------------------------------------------ sources
def gather_sources(prof):
    from .models import CashEntry, Expense, KhataEntry, Sale
    sales = []
    for s in Sale.objects.filter(business=prof).select_related("customer") \
            .prefetch_related("lines"):
        sales.append({
            "id": s.id, "date": _day(s.created_at), "total": s.total,
            "discount": s.discount, "due": s.due, "payment_method": s.payment_method,
            "customer": (s.customer.name or s.customer.phone) if s.customer_id else "",
            "cogs": sum(max(l.cost_price, 0) * max(l.qty, 0) for l in s.lines.all()),
            # ledger2: per-product VAT (only used when a product has a rate)
            "lines": [{"product_id": l.product_id, "amount": l.qty * l.unit_price}
                      for l in s.lines.all()],
            "void_date": _day(s.voided_at)})
    khata = [{"id": k.id, "date": _day(k.at), "book": k.party.book,
              "direction": k.direction, "amount": k.amount_poisha,
              "party": k.party.name, "note": k.note,
              "method": getattr(k, "method", "") or ""}
             for k in KhataEntry.objects.filter(party__business=prof).select_related("party")]
    expenses = [{"id": x.id, "date": x.date, "amount": x.amount,
                 "category": x.category, "note": x.note}
                for x in Expense.objects.filter(business=prof)]
    cash = [{"id": c.id, "date": _day(c.at), "kind": c.kind,
             "amount": c.amount_poisha, "note": c.note}
            for c in CashEntry.objects.filter(day__business=prof)]
    return {"sales": sales, "khata": khata, "expenses": expenses, "cash": cash,
            "invoices": invoice_sources(prof)}


# ---- invoices (agent/invoices stores them as PaCollectionItem rows) ----------
INVOICE_COLLECTION = "biz_invoices"
INVOICE_CFG = "biz_invoice_cfg"


def _biz_rows(prof, collection):
    from .models import PaCollectionItem
    return [r for r in PaCollectionItem.objects.filter(user_id=prof.user_id,
                                                        collection=collection)
            if (r.data or {}).get("business_id") == prof.id]


def invoice_sources(prof):
    out = []
    for r in _biz_rows(prof, INVOICE_COLLECTION):
        d = r.data or {}
        calc = d.get("calc") or {}
        day = L.parse_day(d.get("issued_at")) or _day(r.created_at)
        out.append({"id": r.id, "date": day, "number": d.get("number") or "",
                    "buyer": (d.get("buyer") or {}).get("name", ""),
                    "buyer_bin": (d.get("buyer") or {}).get("bin", ""),
                    "total": int(calc.get("total") or 0),
                    "taxable": int(calc.get("taxable") or 0),
                    "sd": int(calc.get("sd") or 0), "vat": int(calc.get("vat") or 0),
                    "paid": int(d.get("paid") or 0),
                    "payment_method": d.get("payment_method") or "cash",
                    "cancelled": bool(d.get("cancelled"))})
    return out


VAT_RATE_COLLECTION = "acct_vat_rate"


def product_vat_rates(prof):
    """{product_id: history} — the owner's per-product VAT treatment (exempt /
    reduced rate he typed), PaCollectionItem rows, no migration."""
    from .models import PaCollectionItem
    rows = PaCollectionItem.objects.filter(user_id=prof.user_id, collection=VAT_RATE_COLLECTION,
                                           data__business=prof.id)
    return {int(r.data["product_id"]): r.data.get("history") or []
            for r in rows if r.data.get("product_id")}


def apply_sale_tax(s, periods, rates):
    """Set s['tax'] when a product in this sale has its own VAT treatment on
    the sale day (inside a VAT period only). Untouched sales keep the shop
    rate — so their postings (fingerprints) never change."""
    vat_bp, sd_bp = L.vat_rate_on(periods, s["date"])
    s["exempt"] = 0
    if not (vat_bp or sd_bp) or not rates:
        return s
    tr = {}
    for l in s.get("lines") or ():
        h = rates.get(l.get("product_id"))
        if h:
            mode, bp = L.product_rate_on(h, s["date"])
            if mode != L.VAT_STANDARD:
                tr[l["product_id"]] = (mode, bp)
    if tr:
        t = L.sale_tax(s["total"], s["lines"], vat_bp, sd_bp, tr)
        s["tax"], s["exempt"] = t[:3], t[3]
    return s


def vat_settings(prof):
    """(vat_bp, sd_bp) when the shop's invoice settings make it a VAT seller
    (a VAT mode AND a seller BIN — Mushak-6.3), else (0, 0)."""
    rows = _biz_rows(prof, INVOICE_CFG)
    d = (rows[0].data or {}) if rows else {}
    has_bin = any(c.isdigit() for c in str(d.get("bin") or ""))
    if d.get("vat_mode") in ("exclusive", "inclusive") and has_bin:
        try:
            return max(int(d.get("vat_bp") or 0), 0), max(int(d.get("sd_bp") or 0), 0)
        except (TypeError, ValueError):
            return 0, 0
    return 0, 0


def update_vat_periods(periods, rate, today):
    """Keep VAT history: open a period when VAT starts / the rate changes,
    close it (yesterday) when VAT stops. Past sales never change rate."""
    periods = [dict(p) for p in periods or []]
    cur = next((p for p in periods if not p.get("to")), None)
    on = rate[0] > 0 or rate[1] > 0
    want = {"vat_bp": rate[0], "sd_bp": rate[1]}
    if cur and (not on or (cur["vat_bp"], cur["sd_bp"]) != rate):
        if cur["from"] >= str(today):          # opened today: just replace/drop
            periods.remove(cur)
        else:
            cur["to"] = str(today - timedelta(days=1))
        cur = None
    if on and cur is None:
        periods.append(dict(want, **{"from": str(today), "to": None}))
    return periods


def stock_value_now(prof):
    """Σ stock × cost (poisha) over the catalog; negative stock counts as 0."""
    from .models import Product
    total = 0
    for p in Product.objects.filter(business=prof).prefetch_related("variants"):
        vs = list(p.variants.all())
        if vs:
            total += sum(max(v.stock, 0) * _poisha(v.cost_price) for v in vs)
        else:
            total += max(p.stock, 0) * _poisha(p.cost_price)
    return total


def _opening(book, prof, src):
    """Freeze the opening inventory on the first sync (never recomputed).
    None when the owner gave an opening stock value himself."""
    days = [r["date"] for k in ("sales", "khata", "expenses", "cash", "invoices")
            for r in src[k] if r.get("date")]
    ob_day = L.parse_day((book.opening or {}).get("date"))
    if ob_day:
        days.append(ob_day)
    if book.start_date is None or (ob_day and ob_day < book.start_date):
        book.start_date = min(days) if days else timezone.localdate()
    if (book.opening or {}).get("inventory") is not None:
        book.opening_warning = {}       # the owner counted it himself
        return None
    if book.opening_inventory is None:
        cogs = sum(s["cogs"] for s in src["sales"] if not s.get("void_date"))
        goods = sum(k["amount"] for k in src["khata"]
                    if k["book"] == "supplier" and k["direction"] == "got"
                    and not L.is_bridge(k["note"]))
        amount, warn = L.opening_inventory(stock_value_now(prof), cogs, goods)
        book.opening_inventory = amount
        book.opening_warning = warn or {}
    return L.post_opening_inventory(book.start_date, book.opening_inventory)


def ensure_accounts(prof):
    from .models import LedgerAccount
    have = set(LedgerAccount.objects.filter(business=prof).values_list("code", flat=True))
    LedgerAccount.objects.bulk_create([
        LedgerAccount(business=prof, code=c, type=t, group=g, name_bn=bn,
                      name_en=en, contra=contra)
        for c, t, g, bn, en, contra in L.CHART if c not in have])
    return {a.code: a for a in LedgerAccount.objects.filter(business=prof)}


# ------------------------------------------------------------------ sync
def _write(prof, book, accounts, user, posting, status, reversal_of=None,
           memo=None, late=False):
    """Persist one balanced posting as a journal entry (append-only)."""
    from .models import JournalEntry, JournalLine
    memo = memo or posting["memo"]
    je = JournalEntry.objects.create(
        business=prof, number=book.next_number, date=posting["date"],
        source_key=posting["source_key"], status=status,
        fingerprint=posting.get("fingerprint", ""),
        memo_bn=memo["bn"][:200], memo_en=memo["en"][:200],
        total=sum(l["debit"] for l in posting["lines"]),
        late=late, reversal_of=reversal_of, created_by=user)
    book.next_number += 1
    JournalLine.objects.bulk_create([
        JournalLine(entry=je, account=accounts[l["account"]], debit=l["debit"],
                    credit=l["credit"], party=(l.get("party") or "")[:120])
        for l in posting["lines"]])
    return je


def _entry_lines(je):
    return [L.line(l.account.code, l.debit, l.credit, l.party) for l in je.lines.all()]


def _reverse(prof, book, accounts, user, orig, day, reason=""):
    """Reversal entry for `orig` (marks it reversed). Never deletes."""
    orig.status = "reversed"
    orig.save(update_fields=["status"])
    why = (" — %s" % reason) if reason else ""
    return _write(prof, book, accounts, user,
                  {"source_key": orig.source_key, "date": day,
                   "lines": L.mirror(_entry_lines(orig))},
                  "reversal", reversal_of=orig,
                  memo={"bn": ("উল্টো এন্ট্রি #%d (%s)%s" % (orig.number, orig.memo_bn, why))[:200],
                        "en": ("Reversal of #%d (%s)%s" % (orig.number, orig.memo_en, why))[:200]},
                  late=day != orig.date)


def _locked_book(prof):
    from django.db import IntegrityError
    from .models import LedgerBook
    try:
        LedgerBook.objects.get_or_create(business=prof)
    except IntegrityError:      # a parallel first sync created it
        pass
    return LedgerBook.objects.select_for_update().get(business=prof)


def sync_books(prof, user=None):
    """Post / reverse whatever changed since the last sync. Returns a summary."""
    from .models import AuditLog, JournalEntry
    with transaction.atomic():
        book = _locked_book(prof)
        accounts = ensure_accounts(prof)
        src = gather_sources(prof)
        opening = _opening(book, prof, src)
        book.vat_periods = update_vat_periods(book.vat_periods, vat_settings(prof),
                                              timezone.localdate())
        rates = product_vat_rates(prof)
        for s in src["sales"]:
            s["vat_bp"], s["sd_bp"] = L.vat_rate_on(book.vat_periods, s["date"])
            apply_sale_tax(s, book.vat_periods, rates)
        desired = L.desired_postings(src["sales"], src["khata"], src["expenses"],
                                     src["cash"], opening, src["invoices"],
                                     L.post_opening_balances(book.opening))
        # acctui: the simple-entry screen (own file, no change to the rules
        # above): core.ledger_entry_service
        from .ledger_entry_service import extra_postings
        desired.update(extra_postings(prof, book))
        # ledger2: cashbox rows the owner classified (reclass entries)
        from .ledger2_service import reclass_postings
        desired.update(reclass_postings(prof, src["cash"]))
        live = {}
        for je in JournalEntry.objects.filter(business=prof, status="posted") \
                .exclude(source_key__startswith="manual:") \
                .exclude(source_key__startswith="yearclose:") \
                .prefetch_related("lines__account"):
            live[je.source_key] = {"id": je.id, "fingerprint": je.fingerprint,
                                   "date": je.date, "lines": _entry_lines(je)}
        plan = L.plan_sync(desired, live, book.lock_date)
        for rev in plan["reverse"]:
            orig = JournalEntry.objects.prefetch_related("lines__account").get(pk=rev["id"])
            _reverse(prof, book, accounts, user, orig, rev["date"])
        for p in plan["post"]:
            _write(prof, book, accounts, user, p, "posted", late=p.get("late", False))
        book.last_sync_at = timezone.now()
        book.save()
        summary = {"posted": len(plan["post"]), "reversed": len(plan["reverse"]),
                   "unchanged": plan["unchanged"]}
        if user is not None and (summary["posted"] or summary["reversed"]):
            AuditLog.objects.create(user=user, action="ledger.sync",
                                    detail=dict(summary, business=prof.id))
    return summary


def notify_change(prof):
    """POSTING HOOK for other modules (invoices, purchases…): call after writing
    a source row. No-op when the flag is off for the shop owner; never raises;
    idempotent (it only syncs), so it can never double-post."""
    try:
        if prof is not None and flag_on(prof.user):
            return sync_books(prof)
    except Exception:
        pass
    return None


class BooksError(Exception):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code, self.status = code, status


def _check_open(book, day):
    if book.lock_date and day <= book.lock_date:
        raise BooksError("locked", 409)


def set_opening(prof, raw, user):
    """Save the owner's opening balances and re-post them (idempotent)."""
    from .models import AuditLog
    ob, err = L.clean_opening(raw)
    if err:
        raise BooksError(err)
    with transaction.atomic():
        book = _locked_book(prof)
        _check_open(book, L.parse_day(ob["date"]))
        book.opening = ob
        book.save(update_fields=["opening"])
        AuditLog.objects.create(user=user, action="ledger.opening",
                                detail={"business": prof.id, "date": ob["date"]})
    sync_books(prof, user)
    return ob


def create_manual(prof, raw, user):
    """The owner's own balanced journal entry (capital, drawings, loan, asset)."""
    from .models import AuditLog
    raw = raw if isinstance(raw, dict) else {}
    day = L.parse_day(raw.get("date"), timezone.localdate())
    if day is None:
        raise BooksError("bad_date")
    with transaction.atomic():
        book = _locked_book(prof)
        _check_open(book, day)
        try:
            e = L.manual_entry(book.next_number, day, raw.get("lines"), raw.get("memo"))
        except L.Unbalanced:
            raise BooksError("unbalanced")
        except ValueError:
            raise BooksError("bad_account")
        if e is None:
            raise BooksError("unbalanced")
        accounts = ensure_accounts(prof)
        je = _write(prof, book, accounts, user, e, "posted")
        book.save(update_fields=["next_number"])
        AuditLog.objects.create(user=user, action="ledger.manual",
                                detail={"business": prof.id, "entry": je.number,
                                        "total": je.total})
    return je


def reverse_entry(prof, pk, reason, user):
    from .models import AuditLog, JournalEntry
    with transaction.atomic():
        book = _locked_book(prof)
        je = JournalEntry.objects.filter(business=prof, pk=pk) \
            .prefetch_related("lines__account").first()
        if je is None:
            raise BooksError("not_found", 404)
        if je.status != "posted":
            raise BooksError("already_reversed", 409)
        accounts = ensure_accounts(prof)
        day = L.open_day(max(je.date, timezone.localdate()), book.lock_date)
        rev = _reverse(prof, book, accounts, user, je, day, str(reason or "")[:120])
        book.save(update_fields=["next_number"])
        AuditLog.objects.create(user=user, action="ledger.reverse",
                                detail={"business": prof.id, "entry": je.number,
                                        "reason": str(reason or "")[:120]})
    return rev


def create_expense(prof, raw, user):
    """The simple screen's expense: a real Expense row, then posted."""
    from .models import Expense, LedgerBook
    raw = raw if isinstance(raw, dict) else {}
    try:
        amount = int(raw.get("amount") or 0)
    except (TypeError, ValueError):
        amount = 0
    if amount <= 0:
        raise BooksError("amount")
    day = L.parse_day(raw.get("date"), timezone.localdate()) if raw.get("date") \
        else timezone.localdate()
    if day is None or day > timezone.localdate():
        raise BooksError("bad_date")
    book = LedgerBook.objects.filter(business=prof).first()
    if book is not None:
        _check_open(book, day)
    x = Expense.objects.create(user_id=prof.user_id, business=prof, amount=amount,
                               category=str(raw.get("category") or "")[:80],
                               note=str(raw.get("note") or "")[:200], date=day)
    sync_books(prof, user)
    return x


def invoice_register(prof, start, end, periods):
    """Mushak-6.2-style sales register rows (data of Mushak-6.3 invoices):
    manual invoices + POS sales made while the shop was a VAT seller."""
    from .models import Sale
    rows = []
    for i in invoice_sources(prof):
        if i["cancelled"] or not (start <= i["date"] <= end):
            continue
        rows.append({"number": i["number"], "date": str(i["date"]), "buyer": i["buyer"],
                     "buyer_bin": i["buyer_bin"], "taxable": i["total"] - i["sd"] - i["vat"],
                     "sd": i["sd"], "vat": i["vat"], "total": i["total"], "exempt": 0,
                     "source": "invoice"})
    rates = product_vat_rates(prof)
    for s in Sale.objects.filter(business=prof, voided_at__isnull=True) \
            .select_related("customer").prefetch_related("lines"):
        d = _day(s.created_at)
        if not (start <= d <= end):
            continue
        vat_bp, sd_bp = L.vat_rate_on(periods, d)
        if not (vat_bp or sd_bp):
            continue
        src = apply_sale_tax({"date": d, "total": s.total, "lines": [
            {"product_id": l.product_id, "amount": l.qty * l.unit_price}
            for l in s.lines.all()]}, periods, rates)
        taxable, sd, vat = src.get("tax") or L.inclusive_tax(s.total, vat_bp, sd_bp)
        rows.append({"number": "POS-%d" % s.id, "date": str(d),
                     "buyer": (s.customer.name if s.customer_id else ""), "buyer_bin": "",
                     "taxable": taxable, "sd": sd, "vat": vat, "total": s.total,
                     "exempt": src.get("exempt") or 0, "source": "sale"})
    rows.sort(key=lambda r: (r["date"], r["number"]))
    return rows


def maybe_sync(prof, user=None, min_gap_s=30):
    """Sync unless one ran in the last `min_gap_s` seconds (report GETs)."""
    from .models import LedgerBook
    book = LedgerBook.objects.filter(business=prof).first()
    if book and book.last_sync_at and \
            (timezone.now() - book.last_sync_at).total_seconds() < min_gap_s:
        return None
    return sync_books(prof, user)


# ------------------------------------------------------------------ reads
def report_lines(prof, end=None, closing=True):
    """Per-(account, day) sums of every journal line (reversals included —
    an entry and its reversal net to zero, so history stays visible).
    closing=False leaves out year-end closing entries (ledger2) — P&L and
    cash flow show the year's real income, not the zeroed-out accounts."""
    from .models import JournalLine
    qs = JournalLine.objects.filter(entry__business=prof)
    if end:
        qs = qs.filter(entry__date__lte=end)
    if not closing:
        qs = qs.exclude(entry__source_key__startswith="yearclose:")
    rows = qs.values("account__code", "entry__date").annotate(
        d=Sum("debit"), c=Sum("credit"))
    return [{"account": r["account__code"], "date": r["entry__date"],
             "debit": r["d"] or 0, "credit": r["c"] or 0} for r in rows]


def set_lock_date(prof, day, user):
    """Close the books up to `day` (inclusive). Moving it back is allowed only
    to an earlier day than today and is audited both ways."""
    from .models import AuditLog, LedgerBook
    book, _ = LedgerBook.objects.get_or_create(business=prof)
    old = book.lock_date
    book.lock_date = day
    book.save(update_fields=["lock_date"])
    AuditLog.objects.create(user=user, action="ledger.lock",
                            detail={"business": prof.id, "from": str(old) if old else None,
                                    "to": str(day) if day else None})
    return book


def entry_lines(prof, end=None):
    """One row per journal line with its entry id (the VAT summary needs to
    see each entry whole). ledger2: moved here from ledger_entry_service."""
    from .models import JournalLine
    qs = JournalLine.objects.filter(entry__business=prof)
    if end:
        qs = qs.filter(entry__date__lte=end)
    return [{"entry": r["entry_id"], "date": r["entry__date"],
             "account": r["account__code"], "debit": r["debit"], "credit": r["credit"]}
            for r in qs.values("entry_id", "entry__date", "account__code",
                               "debit", "credit")]
