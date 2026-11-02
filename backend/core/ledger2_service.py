"""ledger2_service.py — Business Accounting phase 2 (flag accounting_v2):
cashbox reclassification, Mushak-6.1 purchase register, per-product VAT
treatment, year-end close / reopen, and the "cost price 0" profit warning.

Rules stay pure in core.logic.ledger (post_reclass, year_close, sale_tax,
product_rate_on); this file is the DB layer. Storage: PaCollectionItem rows
(no migration) — 'acct_reclass' (one per cashbox row) and 'acct_vat_rate'
(one per product, with a dated history so past sales never change rate).
Everything the owner does here is written to the AuditLog.
"""
from datetime import date, timedelta
from decimal import Decimal

from django.db import transaction
from django.db.models import F
from django.utils import timezone

from . import ledger_service as S
from .logic import ledger as L

COL_RECLASS = "acct_reclass"
NOTE_MAX = 120


def _rows(prof, col):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(user_id=prof.user_id, collection=col,
                                           data__business=prof.id)


def _audit(user, action, **detail):
    from .models import AuditLog
    AuditLog.objects.create(user=user, action=action, detail=detail)


def _name(code):
    return dict(L.ACC[code]["name"])


# ------------------------------------------------------------ cashbox reclass
def reclass_postings(prof, cash_src):
    """{source_key: posting} — one reclass entry per classified cashbox row.
    Called by core.ledger_service.sync_books inside its transaction. A row
    that is gone (deleted from the cashbox) posts nothing -> reversed."""
    by_id = {c["id"]: c for c in cash_src}
    out = {}
    for it in _rows(prof, COL_RECLASS):
        c = by_id.get(it.data.get("cash_id"))
        if c is None:
            continue
        try:
            e = L.post_reclass(c, it.data.get("code"))
        except ValueError:
            continue           # a stale code never blocks the books
        if e:
            out[e["source_key"]] = e
    return out


def cashbox_rows(prof, limit=200):
    """Manual cashbox rows newest first, each with its classification."""
    from .models import CashEntry
    cls = {it.data.get("cash_id"): it.data for it in _rows(prof, COL_RECLASS)}
    rows = []
    qs = CashEntry.objects.filter(day__business=prof).order_by("-at", "-id")
    for c in qs[:limit]:
        code = (cls.get(c.id) or {}).get("code") or ""
        rows.append({"id": c.id, "date": str(S._day(c.at)), "kind": c.kind,
                     "amount": c.amount_poisha, "note": c.note,
                     "code": code, "name": _name(code) if code in L.ACC else None})
    pending = [r for r in rows if not r["code"]]
    return {"rows": rows, "unclassified": len(pending),
            "unclassified_amount": sum(r["amount"] for r in pending),
            "choices": {"in": [{"code": c, "name": _name(c)} for c in L.RECLASS_IN],
                        "out": [{"code": c, "name": _name(c)} for c in L.RECLASS_OUT]}}


def classify_cash(prof, user, cash_id, code):
    """Set (or clear, code '') what a cashbox row really was. The original
    cash:<id> entry is never touched; a reclass:<id> entry moves the amount
    out of Suspense (changing it later = reversal + new entry)."""
    from .models import CashEntry, PaCollectionItem
    c = CashEntry.objects.filter(pk=cash_id, day__business=prof).first()
    if c is None:
        raise S.BooksError("not_found", 404)
    code = str(code or "")
    if code and code not in (L.RECLASS_IN if c.kind == "in" else L.RECLASS_OUT):
        raise S.BooksError("bad_code")
    day = S._day(c.at)
    from .models import LedgerBook
    book = LedgerBook.objects.filter(business=prof).first()
    if book and book.lock_date and day <= book.lock_date:
        raise S.BooksError("locked", 409)
    with transaction.atomic():
        it = _rows(prof, COL_RECLASS).filter(data__cash_id=c.id).first()
        old = (it.data.get("code") if it else "") or ""
        if not code:
            if it:
                it.delete()
        elif it:
            it.data = dict(it.data, code=code, by=user.id, at=timezone.now().isoformat())
            it.save(update_fields=["data", "updated_at"])
        else:
            PaCollectionItem.objects.create(
                user_id=prof.user_id, collection=COL_RECLASS,
                data={"business": prof.id, "cash_id": c.id, "code": code,
                      "by": user.id, "at": timezone.now().isoformat()})
        _audit(user, "acct.reclass", business=prof.id, cash_id=c.id,
               amount=c.amount_poisha, **{"from": old, "to": code})
    S.sync_books(prof, user)
    return {"id": c.id, "code": code, "name": _name(code) if code else None}


# ------------------------------------------------------------ purchases (6.1)
def purchase_register(prof, start, end):
    """Mushak-6.1-style purchase register rows from the simple entry screen's
    purchases (not cancelled): date, supplier, supplier BIN, bill number,
    value, input VAT, total. A summary for the owner / accountant."""
    from .ledger_entry_service import COL_ENTRY
    out = []
    for it in _rows(prof, COL_ENTRY).filter(data__kind="purchase"):
        d = it.data
        if d.get("void"):
            continue
        day = L.parse_day(d.get("date"))
        if day is None or not (start <= day <= end):
            continue
        amt, vat = int(d.get("amount") or 0), int(d.get("vat") or 0)
        out.append({"date": str(day), "supplier": d.get("party_name") or d.get("note") or "",
                    "supplier_bin": d.get("supplier_bin") or "",
                    "bill_no": d.get("bill_no") or "", "value": amt - vat, "vat": vat,
                    "total": amt, "on_credit": d.get("pay") == "due"})
    out.sort(key=lambda r: (r["date"], r["bill_no"]))
    return out


# ------------------------------------------------------------ per-product VAT
def vat_rates(prof, q="", limit=300):
    """Products with their VAT treatment today, plus the shop's own rate."""
    from .models import LedgerBook, Product
    rates = S.product_vat_rates(prof)
    today = timezone.localdate()
    book = LedgerBook.objects.filter(business=prof).first()
    periods = (book.vat_periods if book else []) or []
    shop_bp, shop_sd = L.vat_rate_on(periods, today)
    if not (shop_bp or shop_sd):
        shop_bp, shop_sd = S.vat_settings(prof)
    qs = Product.objects.filter(business=prof)
    if q:
        qs = qs.filter(name__icontains=str(q)[:60])
    rows = []
    for p in qs.order_by("name")[:limit]:
        mode, bp = L.product_rate_on(rates.get(p.id), today)
        hist = rates.get(p.id) or []
        rows.append({"product_id": p.id, "name": p.name, "category": p.category,
                     "mode": mode, "vat_bp": bp,
                     "note": (hist[-1].get("note") if hist and mode != L.VAT_STANDARD else "") or "",
                     "since": (hist[-1].get("from") if hist else None)})
    return {"shop_vat_bp": shop_bp, "shop_sd_bp": shop_sd,
            "vat_seller": bool(shop_bp or shop_sd), "products": rows,
            "custom": sum(1 for r in rows if r["mode"] != L.VAT_STANDARD)}


def set_vat_rate(prof, user, raw):
    """{product_id, mode standard|exempt|reduced, vat_bp (reduced: the rate the
    owner reads in the NBR Third Schedule, basis points), note, from?}.
    Effective from `from` (default today; never inside a closed period), so
    sales before it keep the rate they were made at."""
    from .models import LedgerBook, PaCollectionItem, Product
    raw = raw if isinstance(raw, dict) else {}
    try:
        pid = int(raw.get("product_id"))
    except (TypeError, ValueError):
        raise S.BooksError("not_found", 404)
    p = Product.objects.filter(pk=pid, business=prof).first()
    if p is None:
        raise S.BooksError("not_found", 404)
    mode = raw.get("mode")
    if mode not in (L.VAT_STANDARD, L.VAT_EXEMPT, L.VAT_REDUCED):
        raise S.BooksError("bad_mode")
    bp = None
    if mode == L.VAT_REDUCED:
        try:
            bp = int(raw.get("vat_bp"))
        except (TypeError, ValueError):
            bp = -1
        if not (0 < bp < 10000):
            raise S.BooksError("bad_rate")
    today = timezone.localdate()
    since = L.parse_day(raw.get("from"), today) if raw.get("from") else today
    book = LedgerBook.objects.filter(business=prof).first()
    if since is None or since > today:
        raise S.BooksError("bad_date")
    if book and book.lock_date and since <= book.lock_date:
        raise S.BooksError("locked", 409)
    note = str(raw.get("note") or "").strip()[:NOTE_MAX]
    with transaction.atomic():
        it = _rows(prof, S.VAT_RATE_COLLECTION).filter(data__product_id=pid).first()
        hist = [h for h in ((it.data.get("history") if it else None) or [])
                if h.get("from") != str(since)]
        hist.append({"from": str(since), "mode": mode, "vat_bp": bp, "note": note,
                     "by": user.id})
        hist.sort(key=lambda h: h["from"])
        data = {"business": prof.id, "product_id": pid, "history": hist}
        if it:
            it.data = data
            it.save(update_fields=["data", "updated_at"])
        else:
            PaCollectionItem.objects.create(user_id=prof.user_id,
                                            collection=S.VAT_RATE_COLLECTION, data=data)
        _audit(user, "acct.vatrate", business=prof.id, product=pid, mode=mode,
               vat_bp=bp, since=str(since), note=note)
    S.sync_books(prof, user)
    mode_now, bp_now = L.product_rate_on(hist, today)
    return {"product_id": pid, "mode": mode_now, "vat_bp": bp_now, "since": str(since)}


# ------------------------------------------------------------ year-end close
def _year_start(end):
    try:
        return end.replace(year=end.year - 1) + timedelta(days=1)
    except ValueError:                       # 29 Feb
        return end.replace(year=end.year - 1, day=28) + timedelta(days=1)


def year_closes(prof):
    from .models import JournalEntry
    rows = []
    for je in JournalEntry.objects.filter(business=prof, source_key__startswith="yearclose:",
                                          status__in=("posted", "reversed")).order_by("-date"):
        rows.append({"end": je.source_key.split(":", 1)[1], "number": je.number,
                     "status": je.status, "total": je.total,
                     "memo": {"bn": je.memo_bn, "en": je.memo_en}})
    today = timezone.localdate()
    # the two year-ends a BD shop uses: calendar year and the income-tax
    # year (1 July – 30 June); only past days can be closed
    dec = date(today.year - 1, 12, 31)
    jun = date(today.year, 6, 30) if today > date(today.year, 6, 30) else date(today.year - 1, 6, 30)
    live = {r["end"] for r in rows if r["status"] == "posted"}
    sugg = [{"end": str(d), "kind": k} for d, k in sorted(((dec, "calendar"), (jun, "tax")),
                                                         key=lambda x: x[0], reverse=True)
            if str(d) not in live]
    return {"closes": rows, "suggestions": sugg}


def close_year(prof, user, end):
    """Post the closing entry for the year ending `end` (income & expenses ->
    retained earnings) and lock the books through `end`. Years close in
    order; the closing entry is the owner's (never touched by sync)."""
    from .models import JournalEntry
    today = timezone.localdate()
    if end is None or end >= today:
        raise S.BooksError("future_lock")
    S.sync_books(prof, user)                 # everything up to date first
    with transaction.atomic():
        book = S._locked_book(prof)
        live = JournalEntry.objects.filter(business=prof, status="posted",
                                           source_key__startswith="yearclose:")
        if live.filter(date__gte=end).exists():
            raise S.BooksError("already_closed", 409)
        e = L.year_close(S.report_lines(prof, end), end)
        if e is None:
            raise S.BooksError("nothing_to_close")
        accounts = S.ensure_accounts(prof)
        je = S._write(prof, book, accounts, user, e, "posted")
        prev = book.lock_date
        if not prev or prev < end:
            book.lock_date = end
        book.save()
        _audit(user, "acct.yearclose", business=prof.id, end=str(end), entry=je.number,
               profit=e["profit"], prev_lock=str(prev) if prev else None)
    return {"end": str(end), "number": je.number, "profit": e["profit"],
            "lock_date": str(book.lock_date)}


def reopen_year(prof, user, end, reason):
    """Reverse a year's closing entry (never deleted) — needs a written
    reason (audited), and only the LATEST closed year can reopen. The lock
    goes back to before that year (or to the owner's earlier lock)."""
    from .models import AuditLog, JournalEntry
    reason = str(reason or "").strip()[:200]
    if len(reason) < 5:
        raise S.BooksError("reason_required")
    with transaction.atomic():
        book = S._locked_book(prof)
        je = JournalEntry.objects.filter(business=prof, status="posted",
                                         source_key="yearclose:%s" % end) \
            .prefetch_related("lines__account").first()
        if je is None:
            raise S.BooksError("not_found", 404)
        if JournalEntry.objects.filter(business=prof, status="posted",
                                       source_key__startswith="yearclose:",
                                       date__gt=end).exists():
            raise S.BooksError("later_year_closed", 409)
        accounts = S.ensure_accounts(prof)
        S._reverse(prof, book, accounts, user, je, end, reason)
        old_lock = book.lock_date
        a = AuditLog.objects.filter(action="acct.yearclose", detail__business=prof.id,
                                    detail__end=str(end)).order_by("-id").first()
        prev = L.parse_day((a.detail or {}).get("prev_lock")) if a else None
        before_year = _year_start(end) - timedelta(days=1)
        book.lock_date = min(prev, before_year) if prev else None
        book.save()
        _audit(user, "acct.yearopen", business=prof.id, end=str(end), reason=reason)
        from .ledger_entry_service import log_lock
        log_lock(prof, user, old_lock, book.lock_date, reason)
    return {"end": str(end), "lock_date": str(book.lock_date) if book.lock_date else None}


# ------------------------------------------------------------ cost price 0
def _cost_poisha(line):
    v = line.variant if line.variant_id else None
    src = v.cost_price if v is not None else (line.product.cost_price if line.product_id else 0)
    return int((Decimal(str(src or 0)) * 100).quantize(Decimal("1")))


def cost_gaps(prof, start=None, end=None):
    """Sale lines sold with cost price 0 (non-voided) — their profit is
    overstated. Grouped per product with what the catalog says today."""
    from .models import SaleLine
    qs = SaleLine.objects.filter(sale__business=prof, sale__voided_at__isnull=True,
                                 cost_price__lte=0).select_related("sale", "product", "variant")
    by, sales, lines, revenue = {}, set(), 0, 0
    for l in qs:
        d = S._day(l.sale.created_at)
        if (start and d < start) or (end and d > end):
            continue
        amt = l.qty * l.unit_price
        lines += 1
        revenue += amt
        sales.add(l.sale_id)
        key = l.product_id or ("name:" + l.product_name)
        r = by.setdefault(key, {"product_id": l.product_id, "name": l.product_name,
                                "lines": 0, "qty": 0, "revenue": 0, "current_cost": 0,
                                "last_sold": str(d)})
        r["lines"] += 1
        r["qty"] += l.qty
        r["revenue"] += amt
        r["last_sold"] = max(r["last_sold"], str(d))
        if l.product_id:
            r["current_cost"] = max(r["current_cost"], _cost_poisha(l))
    products = sorted(by.values(), key=lambda r: -r["revenue"])
    return {"sales": len(sales), "lines": lines, "revenue": revenue,
            "products": products[:100]}


def apply_cost(prof, user, raw):
    """The owner's ONE tap: (optionally) set the product's cost price, then
    put the catalog cost on his OLD sale lines of it that still say 0 —
    only outside closed periods; each sale's stored profit follows. Never
    automatic: nothing changes until he asks (audited)."""
    from .models import LedgerBook, Product, Sale, SaleLine
    raw = raw if isinstance(raw, dict) else {}
    try:
        pid = int(raw.get("product_id"))
    except (TypeError, ValueError):
        raise S.BooksError("not_found", 404)
    p = Product.objects.filter(pk=pid, business=prof).first()
    if p is None:
        raise S.BooksError("not_found", 404)
    cost = raw.get("cost")
    if cost not in (None, ""):
        try:
            cost = int(cost)
        except (TypeError, ValueError):
            cost = -1
        if cost <= 0 or cost > 10 ** 12:
            raise S.BooksError("bad_cost")
        taka = (Decimal(cost) / 100).quantize(Decimal("0.01"))
        p.cost_price = taka
        p.save(update_fields=["cost_price", "updated_at"])
        p.variants.filter(cost_price__lte=0).update(cost_price=taka)
    book = LedgerBook.objects.filter(business=prof).first()
    lock = book.lock_date if book else None
    fixed = skipped = 0
    with transaction.atomic():
        qs = SaleLine.objects.select_for_update().filter(
            sale__business=prof, sale__voided_at__isnull=True, product=p,
            cost_price__lte=0).select_related("sale", "product", "variant")
        for l in qs:
            if lock and S._day(l.sale.created_at) <= lock:
                skipped += 1
                continue
            c = _cost_poisha(l)
            if c <= 0:
                continue
            l.cost_price = c
            l.save(update_fields=["cost_price"])
            Sale.objects.filter(pk=l.sale_id).update(profit=F("profit") - c * max(l.qty, 0))
            fixed += 1
        _audit(user, "acct.costfix", business=prof.id, product=pid, lines=fixed,
               skipped_locked=skipped, cost=cost if cost not in (None, "") else None)
    S.sync_books(prof, user)
    return {"product_id": pid, "fixed": fixed, "skipped_locked": skipped}
