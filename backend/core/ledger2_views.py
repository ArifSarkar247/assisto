"""ledger2_views.py — Business Accounting phase 2 API (flag accounting_v2,
OFF; OWNER ONLY like the books). Rules: core.logic.ledger; DB:
core.ledger2_service. Money is integer poisha; VAT rates in basis points.

  GET  business/acct/cashbox                    cashbox rows + classification
  POST business/acct/cashbox/<id>/classify      {code|''}  reclass entry
  GET  business/acct/vat-rates?q=               products' VAT treatment
  POST business/acct/vat-rates                  {product_id, mode, vat_bp?,
                                                 note?, from?}
  GET  business/acct/year-close                 closings + suggested year-ends
  POST business/acct/year-close                 {end}  closing entry + lock
  POST business/acct/year-reopen                {end, reason}  reversal
  GET  business/acct/cost-gaps?from=&to=        sales with cost price 0
  POST business/acct/cost-gaps/apply            {product_id, cost?}
"""
from rest_framework.response import Response

from . import ledger2_service as L2
from . import ledger_service as S
from .i18n import pick, req_lang
from .ledger_views import _Books, _book_meta
from .logic import ledger as L

_ERR = {
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "bad_code": ("এই টাকার ধরন এখানে বাছা যায় না।", "That kind cannot be picked for this row."),
    "locked": ("এই তারিখের হিসাব বন্ধ (লক) করা আছে — আগে মাস/বছর খুলুন।",
               "The books are closed for that date — reopen the period first."),
    "bad_mode": ("ভ্যাটের ধরন বাছুন: সাধারণ, অব্যাহতি বা হ্রাসকৃত হার।",
                 "Pick the VAT kind: standard, exempt or reduced rate."),
    "bad_rate": ("হ্রাসকৃত হার লিখুন (যেমন ৫ বা ৭.৫) — NBR-এর তৃতীয় তফসিল দেখে।",
                 "Type the reduced rate (e.g. 5 or 7.5) — as in the NBR Third Schedule."),
    "bad_date": ("তারিখ ঠিক নেই — আজকের পরের তারিখ দেওয়া যায় না।",
                 "That date is not valid — it cannot be after today."),
    "future_lock": ("শুধু শেষ হয়ে যাওয়া বছর বন্ধ করা যায়।", "Only a year that has ended can be closed."),
    "already_closed": ("এই বছর (বা পরের বছর) আগেই বন্ধ করা হয়েছে।",
                       "This year (or a later one) is already closed."),
    "nothing_to_close": ("বন্ধ করার মতো আয়-খরচ নেই।", "There is no income or expense to close."),
    "later_year_closed": ("আগে পরের বছরটি খুলুন — বছর পেছন থেকে খোলা হয়।",
                          "Reopen the later year first — years reopen newest first."),
    "reason_required": ("আবার খোলার কারণ লিখুন (অন্তত ৫ অক্ষর) — অডিটে থাকবে।",
                        "Write why you are reopening (at least 5 letters) — it goes in the audit trail."),
    "bad_cost": ("কেনা দাম ঠিক নেই।", "The cost price is not valid."),
}


def _err(request, code, status=400):
    return Response({"error": code, "detail": pick(req_lang(request), *_ERR[code])},
                    status=status)


def _run(request, fn, *args):
    try:
        return fn(*args), None
    except S.BooksError as e:
        return None, _err(request, e.code if e.code in _ERR else "not_found", e.status)


def _lang(request):
    return "bn" if req_lang(request) == "bn" else "en"


class AcctCashboxView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        out = L2.cashbox_rows(prof)
        out["book"] = _book_meta(prof)
        return Response(out)


class AcctCashboxClassifyView(_Books):
    def post(self, request, pk):
        prof, bad = self.biz(request)
        if bad:
            return bad
        out, err = _run(request, L2.classify_cash, prof, request.user, pk,
                        request.data.get("code"))
        return err or Response(dict(out, book=_book_meta(prof)))


class AcctVatRatesView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        return Response(L2.vat_rates(prof, request.query_params.get("q") or ""))

    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        out, err = _run(request, L2.set_vat_rate, prof, request.user, request.data)
        return err or Response(out)


class AcctYearCloseView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        out = L2.year_closes(prof)
        out["book"] = _book_meta(prof)
        return Response(out)

    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        end = L.parse_day(request.data.get("end"))
        if end is None:
            return _err(request, "bad_date")
        out, err = _run(request, L2.close_year, prof, request.user, end)
        return err or Response(dict(out, book=_book_meta(prof)), status=201)


class AcctYearReopenView(_Books):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        end = L.parse_day(request.data.get("end"))
        if end is None:
            return _err(request, "bad_date")
        out, err = _run(request, L2.reopen_year, prof, request.user, end,
                        request.data.get("reason"))
        return err or Response(dict(out, book=_book_meta(prof)))


class AcctCostGapsView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        start = L.parse_day(request.query_params.get("from"))
        end = L.parse_day(request.query_params.get("to"))
        return Response(L2.cost_gaps(prof, start, end))


class AcctCostApplyView(_Books):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        out, err = _run(request, L2.apply_cost, prof, request.user, request.data)
        return err or Response(out)
