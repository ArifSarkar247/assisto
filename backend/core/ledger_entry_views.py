"""ledger_entry_views.py — API for the accounting UI (acctui; flag
`accounting_v2`, OFF). Thin: rules in core.logic.ledger_entry, DB in
core.ledger_entry_service; the core books API (core.ledger_views) is reused
for P&L / balance sheet / trial balance / lock. OWNER ONLY, like the books.

  GET  business/acct/entries?before=<id>        my simple entries (newest first)
  POST business/acct/entries                    {client_id, kind, amount, account,
                                                 ...} idempotent on client_id
  POST business/acct/entries/<client_id>/void   {reason}  reversal, never delete
  GET  business/acct/opening                    opening balances + khata hints
  POST business/acct/opening                    {cash, bkash, nagad, bank,
                                                 receivable, payable, stock}
  GET  business/acct/cash-flow?from=&to=        direct method, ties to the books
  GET  business/acct/vat?from=&to=              Mushak summary (not a return)
  GET  business/acct/audit?page=                who / when / what + reversals
  POST business/acct/export-log {what}          records an accountant export
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
        return Response({"entries": rows, "has_more": more, "book": _book_meta(prof)})

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


class AcctOpeningView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        return Response(ES.get_opening(prof))

    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        out, err = ES.set_opening(prof, request.user, request.data)
        if err:
            return _err(request, err)
        return Response(out)


class AcctCashFlowView(_Books):
    def get(self, request):
        from .logic import ledger_entry as E
        prof, bad = self.biz(request)
        if bad:
            return bad
        S.maybe_sync(prof, request.user)
        start, end = _range(request)
        if start > end:
            return _err(request, "bad_date")
        out = E.cash_flow(ES.entry_lines(prof, end), start, end)
        out["book"] = _book_meta(prof)
        return Response(out)


class AcctVatView(_Books):
    def get(self, request):
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
