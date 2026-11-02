"""ledger_service.py — DB layer of Business Accounting (flag accounting_v2).

Reads the shop's existing books (POS sales, khata, expenses, cashbox rows),
turns them into postings with the pure rules (core.logic.ledger) and writes
the journal. `sync_books` is idempotent (fingerprints), serialised per business
(row lock on LedgerBook) and append-only (reversal entries, never edits).
"""
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
            "void_date": _day(s.voided_at)})
    khata = [{"id": k.id, "date": _day(k.at), "book": k.party.book,
              "direction": k.direction, "amount": k.amount_poisha,
              "party": k.party.name, "note": k.note}
             for k in KhataEntry.objects.filter(party__business=prof).select_related("party")]
    expenses = [{"id": x.id, "date": x.date, "amount": x.amount,
                 "category": x.category, "note": x.note}
                for x in Expense.objects.filter(business=prof)]
    cash = [{"id": c.id, "date": _day(c.at), "kind": c.kind,
             "amount": c.amount_poisha, "note": c.note}
            for c in CashEntry.objects.filter(day__business=prof)]
    return {"sales": sales, "khata": khata, "expenses": expenses, "cash": cash}


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
    """Freeze the opening inventory on the first sync (never recomputed)."""
    days = [r["date"] for k in ("sales", "khata", "expenses", "cash")
            for r in src[k] if r.get("date")]
    if book.start_date is None:
        book.start_date = min(days) if days else timezone.localdate()
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
def sync_books(prof, user=None):
    """Post / reverse whatever changed since the last sync. Returns a summary."""
    from .models import AuditLog, JournalEntry, JournalLine, LedgerBook
    from django.db import IntegrityError
    try:
        LedgerBook.objects.get_or_create(business=prof)
    except IntegrityError:      # a parallel first sync created it
        pass
    with transaction.atomic():
        book = LedgerBook.objects.select_for_update().get(business=prof)
        accounts = ensure_accounts(prof)
        src = gather_sources(prof)
        opening = _opening(book, prof, src)
        desired = L.desired_postings(src["sales"], src["khata"], src["expenses"],
                                     src["cash"], opening)
        # acctui: the simple-entry screen + opening wizard (own file, no
        # change to the rules above): core.ledger_entry_service
        from .ledger_entry_service import extra_postings
        desired.update(extra_postings(prof, book))
        live = {}
        for je in JournalEntry.objects.filter(business=prof, status="posted") \
                .prefetch_related("lines__account"):
            live[je.source_key] = {
                "id": je.id, "fingerprint": je.fingerprint, "date": je.date,
                "lines": [L.line(l.account.code, l.debit, l.credit, l.party)
                          for l in je.lines.all()]}
        plan = L.plan_sync(desired, live, book.lock_date)

        def write(posting, status, reversal_of=None, memo=None, late=False):
            je = JournalEntry.objects.create(
                business=prof, number=book.next_number, date=posting["date"],
                source_key=posting["source_key"], status=status,
                fingerprint=posting.get("fingerprint", ""),
                memo_bn=(memo or posting["memo"])["bn"][:200],
                memo_en=(memo or posting["memo"])["en"][:200],
                total=sum(l["debit"] for l in posting["lines"]),
                late=late, reversal_of=reversal_of, created_by=user)
            book.next_number += 1
            JournalLine.objects.bulk_create([
                JournalLine(entry=je, account=accounts[l["account"]], debit=l["debit"],
                            credit=l["credit"], party=l.get("party", "")[:120])
                for l in posting["lines"]])
            return je

        for rev in plan["reverse"]:
            orig = JournalEntry.objects.get(pk=rev["id"])
            orig.status = "reversed"
            orig.save(update_fields=["status"])
            write(rev, "reversal", reversal_of=orig,
                  memo={"bn": "উল্টো এন্ট্রি #%d (%s)" % (orig.number, orig.memo_bn),
                        "en": "Reversal of #%d (%s)" % (orig.number, orig.memo_en)},
                  late=rev["date"] != orig.date)
        for p in plan["post"]:
            write(p, "posted", late=p.get("late", False))
        book.last_sync_at = timezone.now()
        book.save()
        summary = {"posted": len(plan["post"]), "reversed": len(plan["reverse"]),
                   "unchanged": plan["unchanged"]}
        if user is not None and (summary["posted"] or summary["reversed"]):
            AuditLog.objects.create(user=user, action="ledger.sync",
                                    detail=dict(summary, business=prof.id))
    return summary


def maybe_sync(prof, user=None, min_gap_s=30):
    """Sync unless one ran in the last `min_gap_s` seconds (report GETs)."""
    from .models import LedgerBook
    book = LedgerBook.objects.filter(business=prof).first()
    if book and book.last_sync_at and \
            (timezone.now() - book.last_sync_at).total_seconds() < min_gap_s:
        return None
    return sync_books(prof, user)


# ------------------------------------------------------------------ reads
def report_lines(prof, end=None):
    """Per-(account, day) sums of every journal line (reversals included —
    an entry and its reversal net to zero, so history stays visible)."""
    from .models import JournalLine
    qs = JournalLine.objects.filter(entry__business=prof)
    if end:
        qs = qs.filter(entry__date__lte=end)
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
