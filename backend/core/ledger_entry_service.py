"""ledger_entry_service.py — DB layer of the SIMPLE ENTRY screen, opening
balances, audit trail, cash flow and VAT summary (acctui; flag accounting_v2).

Storage needs NO migration: entries live in the generic PaCollectionItem store
(user = the business owner, collection 'acct_entry'; the opening balances are
one 'acct_opening' row). Entries that touch a customer / supplier ALSO write
the khata row (so the khata balance, tagada and statements stay the one
truth); an expense also writes core.Expense (so the existing business reports
see it). Those rows carry the '[acct#<client_id>]' marker, which the core
ledger skips (core.logic.ledger.BRIDGE_MARKERS) — this layer posts them with
the RIGHT money account (bKash / Nagad / bank, not always cash).

Hook into the core: core.ledger_service.sync_books calls `extra_postings`.
"""
from datetime import datetime, time

from django.db import transaction
from django.utils import timezone

from . import ledger_service as S
from .logic import ledger as L
from .logic import ledger_entry as E

COL_ENTRY = "acct_entry"
COL_OPENING = "acct_opening"


def _items(prof, col):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(user=prof.user, collection=col,
                                           data__business=prof.id)


def _marker(cid):
    return E.MARKER % cid


# ------------------------------------------------------------------ postings
def extra_postings(prof, book):
    """{source_key: posting} for every simple entry + the opening balances.
    Called by the core sync inside its transaction (book is row-locked)."""
    from .models import Expense, KhataEntry
    out = {}
    rows = [it.data for it in _items(prof, COL_ENTRY)]
    kids = [r["khata_entry_id"] for r in rows if r.get("khata_entry_id")]
    xids = [r["expense_id"] for r in rows if r.get("expense_id")]
    kh = {k.id: k for k in KhataEntry.objects.filter(pk__in=kids,
                                                     party__business=prof)}
    ex = {x.id: x for x in Expense.objects.filter(pk__in=xids, business=prof)}
    for r in rows:
        linked = None
        if r.get("khata_entry_id"):
            k = kh.get(r["khata_entry_id"])
            linked = {"gone": True} if k is None else \
                {"amount": k.amount_poisha, "date": S._day(k.at)}
        elif r.get("expense_id"):
            x = ex.get(r["expense_id"])
            linked = {"gone": True} if x is None else {"amount": x.amount, "date": x.date}
        try:
            p = E.post_entry(r, linked)
        except (ValueError, KeyError):
            p = None          # a corrupt row never blocks the whole books
        if p:
            out[p["source_key"]] = p
    op = _items(prof, COL_OPENING).first()
    if op and book.start_date:
        out.update(E.post_opening(op.data.get("values") or {}, book.start_date))
    return out


# ------------------------------------------------------------------ entries
def _book(prof):
    from .models import LedgerBook
    b = LedgerBook.objects.filter(business=prof).first()
    if b is None or b.start_date is None:
        S.sync_books(prof)
        b = LedgerBook.objects.get(business=prof)
    return b


def _party(prof, book, e):
    """The KhataParty for an entry: by id (this business, right book), else
    find-or-create by phone / name (a CRM / My Circle pick)."""
    from .models import KhataParty
    if e.get("party_id"):
        p = KhataParty.objects.filter(pk=e["party_id"], business=prof, book=book).first()
        if p is None:
            return None
        return p
    phone, name = e.get("party_phone") or "", e.get("party_name") or ""
    p = None
    if phone:
        p = KhataParty.objects.filter(business=prof, book=book, phone=phone,
                                      archived=False).first()
    if p is None and name and not phone:
        p = KhataParty.objects.filter(business=prof, book=book, name=name,
                                      archived=False).first()
    if p is None:
        p = KhataParty.objects.create(business=prof, book=book,
                                      name=name or phone, phone=phone)
    return p


def entry_dict(it, users=None):
    d = dict(it.data)
    d.pop("business", None)
    by = (users or {}).get(d.get("by"))
    d["by_name"] = by or ""
    d["id"] = it.id
    return d


def create_entry(prof, user, data):
    """-> (entry dict, created bool, error_code|None). Idempotent on client_id:
    an offline queue that replays the same entry gets the first one back."""
    from .models import AuditLog, Expense, KhataEntry, LedgerBook, PaCollectionItem
    book = _book(prof)
    clean, err = E.validate(data, timezone.localdate(), book.lock_date)
    if err:
        return None, False, err
    with transaction.atomic():
        LedgerBook.objects.select_for_update().get(pk=book.pk)
        old = _items(prof, COL_ENTRY).filter(data__client_id=clean["client_id"]).first()
        if old is not None:
            return entry_dict(old), False, None
        if clean.get("party_book"):
            p = _party(prof, clean["party_book"], clean)
            if p is None:
                return None, False, "need_party"
            clean["party_id"], clean["party_name"] = p.id, p.name
        marker = _marker(clean["client_id"])
        at = timezone.now() if clean["date"] == str(timezone.localdate()) else \
            timezone.make_aware(datetime.combine(L.parse_day(clean["date"]), time(12, 0)))
        d = E.khata_direction(clean)
        if d:
            k = KhataEntry.objects.create(
                party_id=clean["party_id"], direction=d, amount_poisha=clean["amount"],
                note=("%s %s" % (clean["note"], marker)).strip()[:200], at=at,
                client_id="acct-%s" % clean["client_id"])
            clean["khata_entry_id"] = k.id
        if clean["kind"] == "expense":
            name = L.ACC[clean["category"]]["name"]["bn"]
            x = Expense.objects.create(
                user=prof.user, business=prof, amount=clean["amount"],
                category=name[:80], date=L.parse_day(clean["date"]),
                note=("%s %s" % (clean["note"], marker)).strip()[:200])
            clean["expense_id"] = x.id
        clean.update({"business": prof.id, "by": user.id,
                      "created_at": timezone.now().isoformat()})
        it = PaCollectionItem.objects.create(user=prof.user, collection=COL_ENTRY,
                                             data=clean)
        AuditLog.objects.create(user=user, action="acct.entry", detail={
            "business": prof.id, "client_id": clean["client_id"],
            "kind": clean["kind"], "amount": clean["amount"]})
    S.sync_books(prof, user)
    return entry_dict(it, {user.id: user.name}), True, None


def void_entry(prof, user, client_id, reason=""):
    """Cancel an entry: the books get a reversal (never a delete); the khata /
    expense row it wrote is removed so the khata matches the books."""
    from .models import AuditLog, Expense, KhataEntry, LedgerBook
    book = _book(prof)
    with transaction.atomic():
        LedgerBook.objects.select_for_update().get(pk=book.pk)
        it = _items(prof, COL_ENTRY).filter(data__client_id=client_id).first()
        if it is None:
            return None, "not_found"
        if it.data.get("void"):
            return entry_dict(it), None
        if book.lock_date and L.parse_day(it.data["date"]) <= book.lock_date:
            return None, "locked_period"
        if it.data.get("khata_entry_id"):
            KhataEntry.objects.filter(pk=it.data["khata_entry_id"],
                                      party__business=prof).delete()
        if it.data.get("expense_id"):
            Expense.objects.filter(pk=it.data["expense_id"], business=prof).delete()
        it.data = dict(it.data, void={"at": timezone.now().isoformat(), "by": user.id,
                                      "reason": str(reason or "")[:160]})
        it.save(update_fields=["data", "updated_at"])
        AuditLog.objects.create(user=user, action="acct.void", detail={
            "business": prof.id, "client_id": client_id, "reason": str(reason or "")[:160]})
    S.sync_books(prof, user)
    return entry_dict(it), None


def list_entries(prof, limit=50, before=None):
    from .models import User
    qs = _items(prof, COL_ENTRY).order_by("-id")
    if before:
        qs = qs.filter(id__lt=before)
    rows = list(qs[:limit + 1])
    ids = {r.data.get("by") for r in rows}
    users = dict(User.objects.filter(pk__in=[i for i in ids if i]).values_list("id", "name"))
    return [entry_dict(r, users) for r in rows[:limit]], len(rows) > limit


# ------------------------------------------------------------------ opening
def khata_totals(prof):
    """What the khata already says is owed (customers) / owing (suppliers)."""
    from django.db.models import Sum
    from .models import KhataEntry
    out = {}
    for book in ("customer", "supplier"):
        qs = KhataEntry.objects.filter(party__business=prof, party__book=book)
        gave = qs.filter(direction="gave").aggregate(s=Sum("amount_poisha"))["s"] or 0
        got = qs.filter(direction="got").aggregate(s=Sum("amount_poisha"))["s"] or 0
        out[book] = gave - got if book == "customer" else got - gave
    return {"receivable": max(out["customer"], 0), "payable": max(out["supplier"], 0)}


def get_opening(prof):
    book = _book(prof)
    op = _items(prof, COL_OPENING).first()
    vals = (op.data.get("values") if op else None) or {}
    return {"values": vals, "set": op is not None,
            "start_date": str(book.start_date) if book.start_date else None,
            "lock_date": str(book.lock_date) if book.lock_date else None,
            "locked": bool(book.lock_date and book.start_date
                           and book.start_date <= book.lock_date),
            "stock_estimate": book.opening_inventory,
            "stock_warning": book.opening_warning or None,
            "khata": khata_totals(prof)}


def set_opening(prof, user, data):
    from .models import AuditLog, LedgerBook, PaCollectionItem
    book = _book(prof)
    clean, err = E.validate_opening(data)
    if err:
        return None, err
    with transaction.atomic():
        book = LedgerBook.objects.select_for_update().get(pk=book.pk)
        if book.lock_date and book.start_date and book.start_date <= book.lock_date:
            return None, "locked_period"
        stock = clean.pop("stock")
        op = _items(prof, COL_OPENING).first()
        doc = {"business": prof.id, "values": clean, "stock": stock, "by": user.id,
               "at": timezone.now().isoformat()}
        old = op.data if op else None
        if op:
            op.data = doc
            op.save(update_fields=["data", "updated_at"])
        else:
            PaCollectionItem.objects.create(user=prof.user, collection=COL_OPENING, data=doc)
        if stock is not None:
            # the core's own frozen opening inventory, now the owner's count
            book.opening_inventory = stock
            book.opening_warning = {}
            book.save(update_fields=["opening_inventory", "opening_warning"])
        AuditLog.objects.create(user=user, action="acct.opening", detail={
            "business": prof.id, "from": (old or {}).get("values"), "to": clean,
            "stock": stock})
    S.sync_books(prof, user)
    return get_opening(prof), None


# ------------------------------------------------------------------ reports
def entry_lines(prof, end=None):
    from .models import JournalLine
    qs = JournalLine.objects.filter(entry__business=prof)
    if end:
        qs = qs.filter(entry__date__lte=end)
    return [{"entry": r["entry_id"], "date": r["entry__date"],
             "account": r["account__code"], "debit": r["debit"], "credit": r["credit"]}
            for r in qs.values("entry_id", "entry__date", "account__code",
                               "debit", "credit")]


AUDIT_ACTIONS = ("ledger.sync", "ledger.lock", "acct.entry", "acct.void",
                 "acct.opening", "acct.export")


def audit(prof, page=1, per=40):
    """The journal newest first with WHO / WHEN / WHAT, reversal pairs, plus
    the owner's lock / opening / void / export actions."""
    from .models import AuditLog, JournalEntry, User
    qs = JournalEntry.objects.filter(business=prof).order_by("-created_at", "-number")
    rows = list(qs.select_related("created_by", "reversal_of", "reversed_by")
                .prefetch_related("lines__account")[(page - 1) * per: page * per + 1])
    authors = {}
    keys = [je.source_key[5:] for je in rows if je.source_key.startswith("acct:")]
    if keys:
        for it in _items(prof, COL_ENTRY).filter(data__client_id__in=keys):
            authors[it.data["client_id"]] = it.data.get("by")
    names = dict(User.objects.filter(pk__in=[v for v in authors.values() if v])
                 .values_list("id", "name"))
    out = []
    for je in rows[:per]:
        who = je.created_by.name if je.created_by_id else ""
        if je.source_key.startswith("acct:"):
            who = names.get(authors.get(je.source_key[5:]), who)
        out.append({
            "id": je.id, "number": je.number, "date": str(je.date),
            "created_at": je.created_at.isoformat(), "status": je.status,
            "source": je.source_key.split(":")[0], "late": je.late,
            "memo": {"bn": je.memo_bn, "en": je.memo_en}, "total": je.total,
            "who": who, "reversal_of": je.reversal_of.number if je.reversal_of_id else None,
            "reversed_by": getattr(getattr(je, "reversed_by", None), "number", None),
            "lines": [{"code": l.account.code, "debit": l.debit, "credit": l.credit,
                       "name": {"bn": l.account.name_bn, "en": l.account.name_en},
                       "party": l.party} for l in je.lines.all()]})
    events = []
    if page == 1:
        for a in AuditLog.objects.filter(action__in=AUDIT_ACTIONS,
                                         detail__business=prof.id) \
                .select_related("user")[:30]:
            events.append({"action": a.action, "at": a.created_at.isoformat(),
                           "who": a.user.name, "detail": a.detail})
    return {"entries": out, "events": events, "page": page,
            "has_more": len(rows) > per}


def log_export(prof, user, what):
    from .models import AuditLog
    AuditLog.objects.create(user=user, action="acct.export",
                            detail={"business": prof.id, "what": str(what)[:60]})
