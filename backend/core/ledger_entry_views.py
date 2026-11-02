"""ledger_entry_views.py — API for the accounting UI (acctui; flag
`accounting_v2`, OFF). Thin: rules in core.logic.ledger_entry, DB in
core.ledger_entry_service; the core books API (core.ledger_views) is reused
for P&L / balance sheet / trial balance / lock. OWNER ONLY, like the books.

  GET  business/acct/entries?before=<id>        my simple entries (newest first)
  POST business/acct/entries                    {client_id, kind, amount, account,
                                                 ...} idempotent on client_id
  POST business/acct/entries/<client_id>/void   {reason}  reversal, never delete
  GET  business/acct/hints                      opening wizard hints (khata dues,
                                                 start / lock day, stock estimate)
  GET  business/acct/vat?from=&to=              VAT detail: VAT paid to NBR kept
                                                 apart, invoice / bill counts
(opening balances, cash flow, P&L ... are the core's business/books/*)
  GET  business/acct/audit?page=                who / when / what + reversals
  POST business/acct/export-log {what}          records an accountant export
  POST business/acct/lock {lock_date|null, reason}  close / reopen a period;
                                                 reopening needs a reason (audited)
Money: integer poisha.
"""
from django.utils import timezone
from rest_framework.response import Response

from . import ledger_entry_service as ES
from . import ledger_service as S
from .i18n import pick, req_lang
from .ledger_views import _Books, _book_meta
from .logic import ledger as L

_ERR = {
    "bad_kind": ("এন্ট্রির ধরন বাছুন।", "Choose what kind of entry this is."),
    "bad_amount": ("টাকার অঙ্ক ঠিক নেই।", "That amount is not valid."),
    "bad_client_id": ("অ্যাপ আপডেট করে আবার চেষ্টা করুন।", "Please update the app and try again."),
    "bad_date": ("তারিখ ঠিক নেই — আজকের পরের তারিখ দেওয়া যায় না।",
                 "That date is not valid — it cannot be after today."),
    "locked_period": ("এই সময়ের হিসাব বন্ধ (লক) করা আছে। পরের তারিখ দিন, অথবা আগে মাস খুলুন।",
                      "The books are closed (locked) for that day. Use a later date, or reopen the period first."),
    "bad_account": ("টাকা কোথায় — নগদ, ব্যাংক, বিকাশ না নগদ — বাছুন।",
                    "Choose where the money is — cash, bank, bKash or Nagad."),
    "same_account": ("একই হিসাবে টাকা সরানো যায় না।", "Pick two different accounts."),
    "bad_category": ("খরচের ধরন বাছুন।", "Choose the kind of expense."),
    "bad_purpose": ("কিসের টাকা — বাছুন।", "Choose what the money is for."),
    "bad_vat": ("ভ্যাট মোট টাকার চেয়ে কম হতে হবে।", "VAT must be less than the total."),
    "bad_cost": ("কেনা দাম ঠিক নেই।", "The cost is not valid."),
    "need_party": ("কার সাথে — খাতা থেকে একজন বাছুন বা নাম লিখুন।",
                   "Who with — pick someone from the khata or type a name."),
    "not_found": ("এন্ট্রিটি পাওয়া যায়নি।", "That entry was not found."),
    "future_lock": ("আজকের পরের তারিখ পর্যন্ত বই বন্ধ করা যায় না।",
                    "You cannot close the books past today."),
    "reason_required": ("আবার খোলার কারণ লিখুন (অন্তত ৫ অক্ষর) — অডিটে থাকবে।",
                        "Write why you are reopening (at least 5 letters) — it goes in the audit trail."),
    "year_closed": ("ওই বছর বন্ধ (বছর-শেষ এন্ট্রি আছে) — আগে বছরটি খুলুন।",
                    "That year is closed (year-end entry) — reopen the year first."),
}


def _err(request, code, status=400):
    return Response({"error": code, "detail": pick(req_lang(request), *_ERR[code])},
                    status=status)


def _range(request):
    today = timezone.localdate()
    start = L.parse_day(request.query_params.get("from"), today.replace(day=1))
    end = L.parse_day(request.query_params.get("to"), today)
    return start, end


class AcctEntriesView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        try:
            before = int(request.query_params.get("before") or 0) or None
        except ValueError:
            before = None
        rows, more = ES.list_entries(prof, before=before)
        return Response({"entries": rows, "has_more": more, "book": _book_meta(prof),
                         "shop": prof.shop_name})

    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        e, created, err = ES.create_entry(prof, request.user, request.data)
        if err:
            return _err(request, err)
        return Response({"entry": e, "created": created, "book": _book_meta(prof)},
                        status=201 if created else 200)


class AcctVoidView(_Books):
    def post(self, request, client_id):
        prof, bad = self.biz(request)
        if bad:
            return bad
        e, err = ES.void_entry(prof, request.user, client_id, request.data.get("reason"))
        if err:
            return _err(request, err, 404 if err == "not_found" else 400)
        return Response({"entry": e})


class AcctHintsView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        return Response(ES.hints(prof))


class AcctVatView(_Books):
    def get(self, request):
        # ledger2: the core's numbers (one source of truth); kept for old apps
        from .logic import ledger_entry as E
        prof, bad = self.biz(request)
        if bad:
            return bad
        S.maybe_sync(prof, request.user)
        start, end = _range(request)
        if start > end:
            return _err(request, "bad_date")
        out = E.vat_summary(ES.entry_lines(prof, end), start, end)
        out["book"] = _book_meta(prof)
        out["shop"] = prof.shop_name
        return Response(out)


class AcctAuditView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        try:
            page = max(int(request.query_params.get("page") or 1), 1)
        except ValueError:
            page = 1
        out = ES.audit(prof, page)
        out["book"] = _book_meta(prof)
        return Response(out)


class AcctExportLogView(_Books):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        ES.log_export(prof, request.user, request.data.get("what") or "")
        return Response({"ok": True})


class AcctLockView(_Books):
    """The core lock (core.ledger_service.set_lock_date) plus a REASON when
    the books are reopened (lock moved earlier or cleared) — audited."""

    def post(self, request):
        from .models import LedgerBook
        prof, bad = self.biz(request)
        if bad:
            return bad
        raw = request.data.get("lock_date")
        day = L.parse_day(raw) if raw else None
        if raw and day is None:
            return _err(request, "bad_date")
        if day and day >= timezone.localdate():
            return _err(request, "future_lock")
        book = LedgerBook.objects.filter(business=prof).first()
        old = book.lock_date if book else None
        reason = str(request.data.get("reason") or "").strip()[:200]
        reopening = old is not None and (day is None or day < old)
        if reopening and len(reason) < 5:
            return _err(request, "reason_required")
        # ledger2: a closed YEAR reopens only through year-reopen (which
        # reverses its closing entry) — never by moving the month lock
        from .models import JournalEntry
        closed = JournalEntry.objects.filter(business=prof, status="posted",
                                             source_key__startswith="yearclose:")
        if reopening and (closed.exists() if day is None else closed.filter(date__gt=day).exists()):
            return _err(request, "year_closed", 409)
        S.set_lock_date(prof, day, request.user)
        ES.log_lock(prof, request.user, old, day, reason)
        return Response({"book": _book_meta(prof)})
