"""ledger_views.py — Business Accounting API (flag `accounting_v2`, OFF).

OWNER ONLY (staff get 403 staff_restricted — the books expose cost and profit).
Every endpoint answers 403 `feature_off` while the flag is off for the user.

  GET  business/books/accounts                  chart of accounts + balances
  GET  business/books/journal?from=&to=&page=   journal (newest first, 50/page)
  GET  business/books/trial-balance?as_of=
  GET  business/books/profit-loss?from=&to=     default: this month to today
  GET  business/books/balance-sheet?as_of=
  POST business/books/sync                      post what changed (idempotent)
  POST business/books/lock {lock_date|null}     close the books up to a day

Report GETs sync first (at most every 30 s), so the books follow the shop's
sales / khata / expenses with nothing typed twice. Money is integer poisha.
"""
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import ledger_service as S
from .i18n import is_play_flavour, pick, req_lang
from .logic import ledger as L

_ERR = {
    "feature_off": ("এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet."),
    "bad_date": ("তারিখ ঠিক নেই (YYYY-MM-DD)।", "That date is not valid (YYYY-MM-DD)."),
    "future_lock": ("আজকের পরের তারিখ পর্যন্ত বই বন্ধ করা যায় না।",
                    "You cannot close the books past today."),
}


def _err(request, code, status=400):
    return Response({"error": code, "detail": pick(req_lang(request), *_ERR[code])},
                    status=status)


class _Books(APIView):
    permission_classes = [IsAuthenticated]

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not S.flag_on(request.user, is_play_flavour(request)):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied(detail={"error": "feature_off",
                                           "detail": pick(req_lang(request), *_ERR["feature_off"])})

    def biz(self, request):
        """(business, error Response|None) — owner only."""
        from .business_views import _owner_only, _require_business
        prof, role, bad = _require_business(request)
        if bad:
            return None, bad
        bad = _owner_only(request, role)
        return (None, bad) if bad else (prof, None)


def _named(rows, lang):
    for r in rows:
        r["name"] = r["name"][lang] if lang in ("bn", "en") else r["name"]["en"]
    return rows


def _book_meta(prof):
    from .models import LedgerBook
    b = LedgerBook.objects.filter(business=prof).first()
    if b is None:
        return {"start_date": None, "lock_date": None, "last_sync_at": None,
                "opening_inventory": None, "warning": None}
    return {"start_date": str(b.start_date) if b.start_date else None,
            "lock_date": str(b.lock_date) if b.lock_date else None,
            "last_sync_at": b.last_sync_at.isoformat() if b.last_sync_at else None,
            "opening_inventory": b.opening_inventory,
            "warning": b.opening_warning or None}


def _lang(request):
    return "bn" if req_lang(request) == "bn" else "en"


class BooksSyncView(_Books):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        out = S.sync_books(prof, request.user)
        out["book"] = _book_meta(prof)
        return Response(out)


class BooksAccountsView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        S.maybe_sync(prof, request.user)
        bal = L.balances(S.report_lines(prof))
        lang = _lang(request)
        rows = L.accounts_payload()
        for r in rows:
            r["name"] = r["name"][lang]
            r["balance"] = bal.get(r["code"], 0)       # debit - credit
        return Response({"accounts": rows, "book": _book_meta(prof)})


class BooksJournalView(_Books):
    PAGE = 50

    def get(self, request):
        from .models import JournalEntry
        prof, bad = self.biz(request)
        if bad:
            return bad
        S.maybe_sync(prof, request.user)
        qs = JournalEntry.objects.filter(business=prof)
        f = L.parse_day(request.query_params.get("from"))
        t = L.parse_day(request.query_params.get("to"))
        if f:
            qs = qs.filter(date__gte=f)
        if t:
            qs = qs.filter(date__lte=t)
        try:
            page = max(int(request.query_params.get("page") or 1), 1)
        except ValueError:
            page = 1
        lang = _lang(request)
        qs = qs.order_by("-date", "-number").prefetch_related("lines__account")
        items = list(qs[(page - 1) * self.PAGE: page * self.PAGE + 1])
        out = []
        for je in items[:self.PAGE]:
            out.append({
                "id": je.id, "number": je.number, "date": str(je.date),
                "status": je.status, "source": je.source_key, "late": je.late,
                "memo": je.memo_bn if lang == "bn" else je.memo_en, "total": je.total,
                "reversal_of": je.reversal_of_id,
                "created_at": je.created_at.isoformat(),
                "lines": [{"code": l.account.code,
                           "name": l.account.name_bn if lang == "bn" else l.account.name_en,
                           "debit": l.debit, "credit": l.credit, "party": l.party}
                          for l in je.lines.all()]})
        return Response({"entries": out, "page": page,
                         "has_more": len(items) > self.PAGE})


class BooksTrialBalanceView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        S.maybe_sync(prof, request.user)
        end = L.parse_day(request.query_params.get("as_of"), timezone.localdate())
        tb = L.trial_balance(S.report_lines(prof, end), end)
        _named(tb["rows"], _lang(request))
        tb["book"] = _book_meta(prof)
        return Response(tb)


class BooksProfitLossView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        S.maybe_sync(prof, request.user)
        today = timezone.localdate()
        start = L.parse_day(request.query_params.get("from"), today.replace(day=1))
        end = L.parse_day(request.query_params.get("to"), today)
        if start > end:
            return _err(request, "bad_date")
        pl = L.profit_and_loss(S.report_lines(prof, end), start, end)
        lang = _lang(request)
        for k in ("sales", "discounts", "cogs", "operating_expenses", "other_income"):
            _named(pl[k], lang)
        pl["book"] = _book_meta(prof)
        return Response(pl)


class BooksBalanceSheetView(_Books):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        S.maybe_sync(prof, request.user)
        end = L.parse_day(request.query_params.get("as_of"), timezone.localdate())
        bs = L.balance_sheet(S.report_lines(prof, end), end)
        lang = _lang(request)
        for k in ("assets", "liabilities", "equity"):
            _named(bs[k], lang)
        bs["book"] = _book_meta(prof)
        return Response(bs)


class BooksLockView(_Books):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        raw = request.data.get("lock_date")
        day = L.parse_day(raw) if raw else None
        if raw and day is None:
            return _err(request, "bad_date")
        if day and day >= timezone.localdate():
            return _err(request, "future_lock")
        S.set_lock_date(prof, day, request.user)
        return Response({"book": _book_meta(prof)})
