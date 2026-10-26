"""
remittance_views.py — BUDGET & REMITTANCE API (flag `budget_remittance`,
default OFF): every endpoint answers 403 `feature_off` while hidden (owner /
staff / allow-listed testers preview it — core.feature_flags). Token auth;
a user only ever sees their OWN rows.

  GET    remit/overview?month=YYYY-MM   month card: received, expected status,
                                        plan vs actual, goal, bills, entries
  GET    remit/entries?month=|year=     remittance entries (decrypted for you)
  POST   remit/entries                  {client_id, amount, currency, rate?,
                                         taka?, received_on, channel,
                                         sender_member_id? | sender_name, note,
                                         source} — idempotent on client_id
  PATCH  remit/entries/<id>             DELETE remit/entries/<id>
  PUT    remit/settings                 {expected_taka, expected_day,
                                         expected_sender, guide_done}
  PUT    remit/plan                     {lines: {food: "5000", ...}} -> the
                                        EXISTING Budget rows (0 removes)
  POST   remit/spend                    {client_id, category, amount, date,
                                         note} -> an EXISTING Money expense
  PUT    remit/goal                     {title, target} (the EXISTING SavingsGoal)
  POST   remit/goal/add                 {client_id, amount} saved += amount
  POST   remit/bills                    {name, amount, due_day, category}
  PATCH  remit/bills/<bid>              DELETE remit/bills/<bid>
  POST   remit/bills/<bid>/paid         {client_id, month} -> expense + paid mark
  GET    remit/report?month=            the plain summary to share (the app
                                        sends it ONLY when the user taps Share)
  GET    remit/year?year=               total, by month / sender / channel, savings
  GET    remit/export?fmt=csv|txt[&as=json] download everything (UTF-8)
  POST   remit/delete-all               {confirm: true} delete everything here

Nothing here is used for ads, analytics or AI, and nothing is sent anywhere.
"""
import csv
import io
from datetime import date

from django.http import HttpResponse
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick, is_play_flavour
from . import remittance_service as S
from .logic import remittance as L
from .logic.budget import to_poisha

_ERR = {
    "feature_off": ("এই ফিচারটি এখনো চালু হয়নি।", "This feature is not available yet."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "bad_input": ("তথ্যগুলো ঠিক নেই — আবার দেখুন।", "Some details are not right — please check."),
    "bad_number": ("সংখ্যাটি ঠিক নেই।", "That number is not right."),
    "bad_amount": ("সঠিক পরিমাণ লিখুন (০-এর বেশি)।", "Enter a correct amount (more than 0)."),
    "bad_currency": ("মুদ্রাটি ঠিক নেই।", "That currency is not right."),
    "bad_rate": ("রেটটি ঠিক নেই — আপনি আসলে যে রেট পেয়েছেন সেটা লিখুন।",
                 "That rate is not right — enter the rate you actually got."),
    "need_rate": ("রেট অথবা টাকায় কত পেলেন — একটা লিখুন।",
                  "Enter the rate or how many taka you got."),
    "bad_channel": ("কোন পথে এল তা বেছে নিন।", "Choose how it came."),
    "bad_sender": ("এই মানুষটি আপনার My Circle-এ নেই।", "This person is not in your My Circle."),
    "bad_date": ("তারিখটি ঠিক নেই।", "That date is not right."),
    "bad_day": ("মাসের দিন ১ থেকে ৩১-এর মধ্যে দিন।", "Pick a day of the month from 1 to 31."),
    "bad_bill": ("বিলের নাম লিখুন।", "Enter the bill's name."),
    "bad_category": ("খাত বেছে নিন।", "Choose a category."),
    "bad_client_id": ("অ্যাপটি আপডেট করে আবার চেষ্টা করুন।", "Please update the app and try again."),
    "no_goal": ("আগে একটি সঞ্চয়-লক্ষ্য ঠিক করুন।", "Set a savings goal first."),
    "daily_cap": ("আজকের লেখার সীমা পূর্ণ হয়েছে — কাল আবার লিখুন।",
                  "Today's entry limit is reached — please add more tomorrow."),
    "too_many": ("সীমা পূর্ণ হয়েছে।", "Limit reached."),
    "confirm": ("মুছতে নিশ্চিত করুন।", "Please confirm the delete."),
}


def err(lang, code, status=400, **extra):
    bn, en = _ERR.get(code, _ERR["bad_input"])
    d = {"error": code, "detail": pick(lang, bn, en)}
    d.update(extra)
    return Response(d, status=status)


class _Gated(APIView):
    permission_classes = [IsAuthenticated]

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not S.flag_on(request.user, is_play_flavour(request)):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied(detail={"error": "feature_off",
                                           "detail": pick(req_lang(request), *_ERR["feature_off"])})

    def handle_exception(self, exc):
        if isinstance(exc, S.RemitError):
            return err(req_lang(self.request), exc.code, exc.status, **exc.extra)
        return super().handle_exception(exc)


def _month(request):
    m = request.query_params.get("month") or L.month_key(S.today())
    return m if L.valid_month(m) else L.month_key(S.today())


def _lines_out(lines):
    return [{"key": ln["key"], "plan": L.p2s(ln["plan_p"]), "actual": L.p2s(ln["actual_p"]),
             "pct": ln["pct"], "state": ln["state"]} for ln in lines]


def _bills_out(bills, month):
    return [{**b, "paid": month in (b.get("paid_months") or [])} for b in bills]


def _month_card(user, month, lang, mark_alert=False):
    from .models import RemittanceEntry
    p = S.profile(user)
    pd = S.profile_data(p)
    rows = list(RemittanceEntry.objects.filter(user=user, month=month))
    entries = [S.entry_dict(r) for r in rows]
    received = L.entries_total(entries)
    lines = L.plan_vs_actual(S.plan(user), S.money_txns(user), month)
    exp_p = to_poisha(pd.get("expected_taka"))
    exp_day = int(pd.get("expected_day") or 0)
    status = L.expected_status(S.today(), month, exp_p, exp_day, received)
    alert_now = False
    if mark_alert and month == L.month_key(S.today()) and \
            L.should_alert(status, month, p.missing_alert_month):
        alert_now = True
        p.missing_alert_month = month
        p.save(update_fields=["missing_alert_month", "updated_at"])
    spent = sum(ln["actual_p"] for ln in lines)
    planned = sum(ln["plan_p"] for ln in lines)
    goal = p.goal if p.goal_id else None
    return p, pd, {
        "month": month,
        "received": L.p2s(received), "count": len(entries),
        "entries": entries,
        "expected": {"taka": L.p2s(exp_p), "day": exp_day,
                     "sender": pd.get("expected_sender", ""), "status": status,
                     "due_date": L.due_date(month, exp_day).isoformat() if exp_day else None,
                     "alert_now": alert_now},
        "plan": {"lines": _lines_out(lines), "planned": L.p2s(planned),
                 "spent": L.p2s(spent), "left": L.p2s(received - spent),
                 "unplanned": L.p2s(max(0, received - planned))},
        "goal": S.goal_dict(goal),
        "bills": _bills_out(pd.get("bills") or [], month),
        "guide_done": p.guide_done,
    }


class OverviewView(_Gated):
    def get(self, request):
        lang = req_lang(request)
        _, _, card = _month_card(request.user, _month(request), lang, mark_alert=True)
        card["channels"] = list(L.CHANNELS)
        card["currencies"] = list(L.CURRENCIES)
        card["categories"] = list(L.CATEGORIES)
        return Response(card)


class EntriesView(_Gated):
    def get(self, request):
        q = {}
        if request.query_params.get("month"):
            q["month"] = _month(request)
        elif request.query_params.get("year"):
            try:
                q["received_on__year"] = int(request.query_params["year"])
            except ValueError:
                return err(req_lang(request), "bad_input")
        return Response({"results": S.decrypted_entries(request.user, **q)})

    def post(self, request):
        row, created = S.create_entry(request.user, request.data or {})
        d = S.entry_dict(row)
        d["duplicate"] = not created
        return Response(d, status=201 if created else 200)


class EntryView(_Gated):
    def _row(self, request, pk):
        from .models import RemittanceEntry
        return RemittanceEntry.objects.filter(user=request.user, pk=pk).first()

    def patch(self, request, pk):
        row = self._row(request, pk)
        if row is None:
            return err(req_lang(request), "not_found", 404)
        return Response(S.entry_dict(S.update_entry(row, request.data or {})))

    def delete(self, request, pk):
        row = self._row(request, pk)
        if row is None:
            return err(req_lang(request), "not_found", 404)
        row.delete()
        return Response({"ok": True})


class SettingsView(_Gated):
    def put(self, request):
        p = S.profile(request.user)
        d = S.clean_settings(request.data or {}, S.profile_data(p))
        if "guide_done" in (request.data or {}):
            p.guide_done = bool(request.data.get("guide_done"))
        S.save_profile(p, d)
        return Response({"expected_taka": d["expected_taka"], "expected_day": d["expected_day"],
                         "expected_sender": d["expected_sender"], "guide_done": p.guide_done})

    post = put


class PlanView(_Gated):
    def put(self, request):
        from .models import Budget
        lines = (request.data or {}).get("lines") or {}
        if not isinstance(lines, dict):
            return err(req_lang(request), "bad_input")
        for k, v in lines.items():
            if k not in L.CATEGORIES:
                return err(req_lang(request), "bad_category")
            amt = S._money(v, k, required=False, allow_zero=True)
            if not amt:
                request.user.budgets.filter(category=k).delete()
            else:
                Budget.objects.update_or_create(user=request.user, category=k,
                                                defaults={"monthly_limit": amt})
        lines = L.plan_vs_actual(S.plan(request.user), S.money_txns(request.user), _month(request))
        return Response({"lines": _lines_out(lines)})

    post = put


class SpendView(_Gated):
    def post(self, request):
        t, created = S.add_spending(request.user, req_lang(request), request.data or {})
        return Response({"id": t.id, "category": t.category, "amount": str(t.amount),
                         "date": t.date.isoformat(), "duplicate": not created},
                        status=201 if created else 200)


class GoalView(_Gated):
    def put(self, request):
        from .models import SavingsGoal
        b = request.data or {}
        title = S._text(b.get("title"), 120)
        target = S._money(b.get("target"), "target")
        if not title:
            title = pick(req_lang(request), "পরিবারের সঞ্চয়", "Family savings")
        p = S.profile(request.user)
        g = request.user.goals.filter(pk=p.goal_id).first() if p.goal_id else None
        if g is None:
            g = SavingsGoal.objects.create(user=request.user, title=title, target_amount=target)
            p.goal = g
            p.save(update_fields=["goal", "updated_at"])
        else:
            g.title, g.target_amount = title, target
            g.save(update_fields=["title", "target_amount", "updated_at"])
        return Response(S.goal_dict(g))

    post = put


class GoalAddView(_Gated):
    def post(self, request):
        from decimal import Decimal
        p = S.profile(request.user)
        g = request.user.goals.filter(pk=p.goal_id).first() if p.goal_id else None
        if g is None:
            return err(req_lang(request), "no_goal", 404)
        body = dict(request.data or {})
        body["category"] = "savings"
        t, created = S.add_spending(request.user, req_lang(request), body)
        if created:
            g.saved_amount = (g.saved_amount or Decimal("0")) + t.amount
            g.save(update_fields=["saved_amount", "updated_at"])
        return Response({**S.goal_dict(g), "duplicate": not created},
                        status=201 if created else 200)


class BillsView(_Gated):
    def post(self, request):
        p = S.profile(request.user)
        d = S.profile_data(p)
        bills = d.get("bills") or []
        if len(bills) >= S.knob("remit_bills_max"):
            return err(req_lang(request), "too_many", 429)
        bill = S.clean_bill(request.data or {})
        bill["id"] = max([int(b.get("id") or 0) for b in bills] + [0]) + 1
        bills.append(bill)
        d["bills"] = bills
        S.save_profile(p, d)
        return Response(bill, status=201)


class BillView(_Gated):
    def _find(self, request, bid):
        p = S.profile(request.user)
        d = S.profile_data(p)
        bills = d.get("bills") or []
        for i, b in enumerate(bills):
            if int(b.get("id") or 0) == int(bid):
                return p, d, bills, i
        return p, d, bills, None

    def patch(self, request, bid):
        p, d, bills, i = self._find(request, bid)
        if i is None:
            return err(req_lang(request), "not_found", 404)
        bills[i] = S.clean_bill(request.data or {}, bills[i])
        S.save_profile(p, {**d, "bills": bills})
        return Response(bills[i])

    def delete(self, request, bid):
        p, d, bills, i = self._find(request, bid)
        if i is None:
            return err(req_lang(request), "not_found", 404)
        gone = bills.pop(i)
        S.save_profile(p, {**d, "bills": bills})
        return Response({"ok": True, "reminder_local_id": gone.get("reminder_local_id", "")})


class BillPaidView(BillView):
    def post(self, request, bid):
        p, d, bills, i = self._find(request, bid)
        if i is None:
            return err(req_lang(request), "not_found", 404)
        b = bills[i]
        month = str((request.data or {}).get("month") or L.month_key(S.today()))
        if not L.valid_month(month):
            return err(req_lang(request), "bad_input")
        paid = list(b.get("paid_months") or [])
        if month in paid:
            return Response({**b, "paid": True, "duplicate": True})
        first, nxt = L.month_bounds(month)
        day = min(S.today(), date.fromordinal(nxt.toordinal() - 1))
        S.add_spending(request.user, req_lang(request), {
            "client_id": (request.data or {}).get("client_id"), "category": b.get("category", "other"),
            "amount": b.get("amount"), "date": max(first, day).isoformat(), "note": b.get("name", "")})
        p = S.profile(request.user)          # add_spending may have saved the profile
        d = S.profile_data(p)
        bills = d.get("bills") or []
        for x in bills:
            if int(x.get("id") or 0) == int(bid):
                x["paid_months"] = (list(x.get("paid_months") or []) + [month])[-24:]
                b = x
        S.save_profile(p, {**d, "bills": bills})
        return Response({**b, "paid": True, "duplicate": False}, status=201)


class ReportView(_Gated):
    def get(self, request):
        lang = request.query_params.get("lang") or req_lang(request)
        lang = "en" if lang == "en" else "bn"
        month = _month(request)
        p, _, card = _month_card(request.user, month, lang)
        lines = L.plan_vs_actual(S.plan(request.user), S.money_txns(request.user), month)
        goal = None
        if card["goal"]:
            goal = {"title": card["goal"]["title"], "target_p": to_poisha(card["goal"]["target"]),
                    "saved_p": to_poisha(card["goal"]["saved"])}
        text = L.report_text(lang, month, to_poisha(card["received"]), card["count"], lines, goal)
        return Response({"month": month, "lang": lang, "text": text,
                         "received": card["received"], "spent": card["plan"]["spent"],
                         "left": card["plan"]["left"]})


class YearView(_Gated):
    def get(self, request):
        try:
            year = int(request.query_params.get("year") or S.today().year)
        except ValueError:
            year = S.today().year
        year = max(2000, min(2100, year))
        entries = S.decrypted_entries(request.user, received_on__year=year)
        v = L.year_view(entries, year, S.savings_by_month(request.user, year))
        return Response({
            "year": year, "total": L.p2s(v["total_p"]), "count": v["count"],
            "months": [L.p2s(x) for x in v["months_p"]],
            "by_sender": [{"name": r["name"], "total": L.p2s(r["total_p"]), "count": r["count"]}
                          for r in v["by_sender"]],
            "by_channel": [{"key": r["key"], "total": L.p2s(r["total_p"]), "count": r["count"]}
                           for r in v["by_channel"]],
            "savings": L.p2s(v["savings_p"]), "avg_month": L.p2s(v["avg_month_p"]),
        })


class ExportView(_Gated):
    def get(self, request):
        from django.core.cache import cache
        lang = req_lang(request)
        key = "remit_export:%d:%s" % (request.user.id, S.today().isoformat())
        n = cache.get(key, 0)
        if n >= S.knob("remit_exports_per_day"):
            return err(lang, "daily_cap", 429)
        cache.set(key, n + 1, 86400)
        fmt = request.query_params.get("fmt", "csv")
        entries = S.decrypted_entries(request.user)
        p = S.profile(request.user)
        pd = S.profile_data(p)
        if fmt == "txt":
            out = [pick(lang, "Assisto — বাজেট ও রেমিট্যান্স (আপনার সব তথ্য)",
                        "Assisto — Budget and Remittance (all your data)"), ""]
            for e in entries:
                out.append("%s  %s %s  x %s = %s  %s  %s  %s" % (
                    e["received_on"], e["amount"], e["currency"], e["rate"],
                    L.taka(lang, to_poisha(e["taka"])),
                    L.label(lang, L.CHANNEL_LABELS, e["channel"]), e["sender_name"], e["note"]))
            out.append("")
            out.append(pick(lang, "প্রত্যাশিত মাসিক টাকা: ", "Expected each month: ")
                       + L.taka(lang, to_poisha(pd.get("expected_taka"))))
            for b in pd.get("bills") or []:
                out.append(pick(lang, "বিল: ", "Bill: ") + "%s %s (%s)" % (
                    b.get("name"), L.taka(lang, to_poisha(b.get("amount"))), b.get("due_day")))
            body = "\n".join(out)
            if request.query_params.get("as") == "json":
                return Response({"filename": "assisto-remittance.txt", "text": body})
            resp = HttpResponse(body, content_type="text/plain; charset=utf-8")
            resp["Content-Disposition"] = 'attachment; filename="assisto-remittance.txt"'
            return resp
        buf = io.StringIO()
        buf.write("﻿")   # Excel opens UTF-8 (Bangla names) correctly
        w = csv.writer(buf)
        w.writerow(["date", "amount", "currency", "rate", "taka", "channel", "sender", "note", "source"])
        for e in entries:
            w.writerow([e["received_on"], e["amount"], e["currency"], e["rate"], e["taka"],
                        e["channel"], e["sender_name"], e["note"], e["source"]])
        if request.query_params.get("as") == "json":
            return Response({"filename": "assisto-remittance.csv", "text": buf.getvalue()})
        resp = HttpResponse(buf.getvalue(), content_type="text/csv; charset=utf-8")
        resp["Content-Disposition"] = 'attachment; filename="assisto-remittance.csv"'
        return resp


class DeleteAllView(_Gated):
    def post(self, request):
        if (request.data or {}).get("confirm") is not True:
            return err(req_lang(request), "confirm")
        n = S.delete_all(request.user)
        return Response({"ok": True, "deleted": n})
