"""Tool registry: existing Assisto modules as versioned, typed agent tools.

Every tool reads/writes ONLY the calling user's own data (ownership is the
query filter, never a check after the fact), returns a dict that matches its
output schema, and has a template `summarize(out, lang)` so most goals can be
answered WITHOUT a second LLM call (0 credits).

Data minimisation: outputs carry only what a plan needs — e.g. family.status
never returns coordinates; khata.dues returns a phone only so it can be masked
into a token for a later (approved) tagada step.
"""
import re
from datetime import date, datetime, timedelta
from decimal import Decimal

from django.db.models import Q, Sum
from django.utils import timezone
from django.utils.dateparse import parse_datetime

from .contract import Tool, ToolError, obj
from ..ai_prompt import to_bn_digits

LATE_STATES = ("grace", "ask", "alert")

# ------------------------------------------------------------------ helpers
_STR = {"type": "string"}
_INT = {"type": "integer"}
_NUM = {"type": "number"}
_BOOL = {"type": "boolean"}
_MONTH = {"type": "string", "maxLength": 7, "minLength": 7}


def _n(x):
    """Decimal/None -> float rounded to 2."""
    return round(float(x or 0), 2)


def _num(v, lang):
    s = ("{:,.0f}" if float(v) == int(float(v)) else "{:,.2f}").format(float(v))
    return to_bn_digits(s) if lang == "bn" else s


def _tk(v, lang):
    return "৳" + _num(v, lang)


def _cnt(v, lang):
    return to_bn_digits(str(v)) if lang == "bn" else str(v)


def _pick(lang, bn, en):
    return bn if lang == "bn" else en


def _month_range(ctx, month):
    today = timezone.localdate(ctx.now)
    if month:
        if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", month):
            raise ToolError("bad_month")
        y, m = int(month[:4]), int(month[5:])
    else:
        y, m = today.year, today.month
    start = date(y, m, 1)
    end = date(y + (m == 12), (m % 12) + 1, 1)
    return "%04d-%02d" % (y, m), start, end


def _flag(ctx, key):
    try:
        from .. import feature_flags as FF
        return FF.is_on(key, ctx.user, ctx.play)
    except Exception:
        return False


def _iso(dt):
    return timezone.localtime(dt).isoformat() if dt else None


# ------------------------------------------------------------------ reminders
def _reminders_list(ctx, a):
    from ..models import Reminder
    days = int(a.get("days") or 7)
    now = ctx.now
    qs = Reminder.objects.filter(user=ctx.user, due_at__gte=now - timedelta(hours=1),
                                 due_at__lte=now + timedelta(days=days))
    if not a.get("include_done"):
        qs = qs.filter(done=False)
    rows = list(qs.order_by("due_at")[:20])
    return {"days": days, "count": qs.count(),
            "items": [{"id": r.id, "title": r.title, "due_at": _iso(r.due_at),
                       "recurrence": r.recurrence} for r in rows]}


def _reminders_list_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "আগামী %s দিনে কোনো রিমাইন্ডার নেই।" % _cnt(o["days"], lang),
                     "No reminders in the next %d days." % o["days"])
    titles = "، ".join(i["title"] for i in o["items"][:5]) if lang == "bn" else \
        ", ".join(i["title"] for i in o["items"][:5])
    return _pick(lang, "আগামী %s দিনে %sটি রিমাইন্ডার: %s।" % (_cnt(o["days"], lang), _cnt(o["count"], lang), titles),
                 "%d reminders in the next %d days: %s." % (o["count"], o["days"], titles))


def _reminders_create(ctx, a):
    from ..models import Reminder
    link = {"type": "agent_step", "id": ctx.idem_key}
    old = Reminder.objects.filter(user=ctx.user, link=link).first()
    if old:
        return {"id": old.id, "title": old.title, "due_at": _iso(old.due_at), "created": False}
    due = parse_datetime(a["due_at"])
    if due is None:
        raise ToolError("bad_due_at")
    if timezone.is_naive(due):
        due = timezone.make_aware(due, timezone.get_current_timezone())
    if due < ctx.now - timedelta(minutes=5):
        raise ToolError("due_in_past")
    r = Reminder.objects.create(user=ctx.user, title=a["title"].strip()[:200],
                                notes=(a.get("notes") or "")[:2000], due_at=due,
                                source="ai", link=link)
    return {"id": r.id, "title": r.title, "due_at": _iso(r.due_at), "created": True}


def _reminders_create_sum(o, lang):
    when = timezone.localtime(parse_datetime(o["due_at"])).strftime("%d/%m %H:%M")
    return _pick(lang, "রিমাইন্ডার সেট হয়েছে: “%s” — %s।" % (o["title"], to_bn_digits(when)),
                 "Reminder set: “%s” — %s." % (o["title"], when))


# ------------------------------------------------------------------ notes
def _notes_search(ctx, a):
    from ..models import Note
    q = (a.get("query") or "").strip()
    qs = Note.objects.filter(user=ctx.user)
    if q:
        qs = qs.filter(Q(title__icontains=q) | Q(body__icontains=q))
    lim = int(a.get("limit") or 5)
    rows = list(qs[:lim])
    return {"query": q, "count": qs.count(),
            "items": [{"id": n.id, "title": n.title or "", "snippet": (n.body or "")[:160]}
                      for n in rows]}


def _notes_search_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "কোনো মিল থাকা নোট পাওয়া যায়নি।", "No matching notes found.")
    names = ", ".join((i["title"] or i["snippet"][:30]) for i in o["items"][:5])
    return _pick(lang, "%sটি নোট পাওয়া গেছে: %s।" % (_cnt(o["count"], lang), names),
                 "Found %d notes: %s." % (o["count"], names))


def _notes_create(ctx, a):
    from ..models import Note
    title, body = a.get("title", "").strip()[:200], (a.get("body") or "")[:5000]
    dup = Note.objects.filter(user=ctx.user, source="agent", title=title, body=body,
                              created_at__gte=ctx.now - timedelta(minutes=10)).first()
    if dup:
        return {"id": dup.id, "title": dup.title, "created": False}
    n = Note.objects.create(user=ctx.user, title=title, body=body, source="agent")
    return {"id": n.id, "title": n.title, "created": True}


def _notes_create_sum(o, lang):
    return _pick(lang, "নোট লেখা হয়েছে: “%s”।" % o["title"], "Note saved: “%s”." % o["title"])


def _notes_delete(ctx, a):
    from ..models import Note
    n = Note.objects.filter(user=ctx.user, pk=a["id"]).first()
    if n is None:
        # already gone (idempotent re-run) or not the caller's note
        return {"id": a["id"], "deleted": False, "title": ""}
    title = n.title or (n.body or "")[:40]
    n.delete()
    return {"id": a["id"], "deleted": True, "title": title}


def _notes_delete_sum(o, lang):
    if not o["deleted"]:
        return _pick(lang, "নোটটি পাওয়া যায়নি — কিছু মোছা হয়নি।", "Note not found — nothing was deleted.")
    return _pick(lang, "নোট মোছা হয়েছে: “%s”।" % o["title"], "Note deleted: “%s”." % o["title"])


def _notes_delete_title(ctx, a, lang):
    from ..models import Note
    n = Note.objects.filter(user=ctx.user, pk=a.get("id")).first()
    t = (n.title or (n.body or "")[:40]) if n else "#%s" % a.get("id")
    return _pick(lang, "নোট মুছবেন: “%s”?" % t, "Delete note: “%s”?" % t)


# ------------------------------------------------------------------ money
def _money_month(ctx, a):
    from ..models import Transaction
    month, start, end = _month_range(ctx, a.get("month"))
    qs = Transaction.objects.filter(user=ctx.user, date__gte=start, date__lt=end)
    inc = _n(qs.filter(kind="income").aggregate(s=Sum("amount"))["s"])
    exp = _n(qs.filter(kind="expense").aggregate(s=Sum("amount"))["s"])
    cats = (qs.filter(kind="expense").values("category").annotate(s=Sum("amount"))
            .order_by("-s")[:5])
    return {"month": month, "income": inc, "expense": exp, "net": round(inc - exp, 2),
            "count": qs.count(),
            "top_categories": [{"category": c["category"] or "other", "amount": _n(c["s"])}
                               for c in cats]}


def _money_month_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "%s মাসে কোনো আয়-খরচ লেখা নেই।" % _cnt(o["month"], lang),
                     "No income or expenses recorded for %s." % o["month"])
    top = o["top_categories"][0] if o["top_categories"] else None
    bn = "%s: আয় %s, খরচ %s, বাকি %s।" % (_cnt(o["month"], lang), _tk(o["income"], lang),
                                         _tk(o["expense"], lang), _tk(o["net"], lang))
    en = "%s: income %s, expenses %s, net %s." % (o["month"], _tk(o["income"], lang),
                                                  _tk(o["expense"], lang), _tk(o["net"], lang))
    if top:
        bn += " সবচেয়ে বেশি খরচ “%s”-এ (%s)।" % (top["category"], _tk(top["amount"], lang))
        en += " Biggest spend: “%s” (%s)." % (top["category"], _tk(top["amount"], lang))
    return _pick(lang, bn, en)


def _budget_status(ctx, a):
    from ..models import Budget, Transaction
    month, start, end = _month_range(ctx, a.get("month"))
    spent = {r["category"]: _n(r["s"]) for r in
             Transaction.objects.filter(user=ctx.user, kind="expense", date__gte=start,
                                        date__lt=end).values("category").annotate(s=Sum("amount"))}
    items = []
    for b in Budget.objects.filter(user=ctx.user).order_by("category"):
        lim = _n(b.monthly_limit)
        s = spent.get(b.category, 0.0)
        pct = int(round(100 * s / lim)) if lim > 0 else 0
        items.append({"category": b.category, "limit": lim, "spent": s, "pct": pct,
                      "state": "over" if pct >= 100 else ("near" if pct >= 80 else "ok")})
    return {"month": month, "items": items,
            "over_count": sum(1 for i in items if i["state"] == "over"),
            "near_count": sum(1 for i in items if i["state"] == "near")}


def _budget_status_sum(o, lang):
    if not o["items"]:
        return _pick(lang, "কোনো বাজেট সেট করা নেই।", "No budget is set.")
    bad = [i for i in o["items"] if i["state"] != "ok"]
    if not bad:
        return _pick(lang, "সব বাজেট সীমার ভেতরে আছে।", "All budgets are within limits.")
    parts = ["%s %s%%" % (i["category"], _cnt(i["pct"], lang)) for i in bad[:5]]
    return _pick(lang, "সীমার কাছে/পেরিয়েছে: %s।" % ", ".join(parts),
                 "Near or over budget: %s." % ", ".join(parts))


def _loans_dues(ctx, a):
    from ..models import Loan
    kind = a.get("kind") or "all"
    qs = Loan.objects.filter(user=ctx.user, settled=False)
    if kind != "all":
        qs = qs.filter(kind=kind)
    today = timezone.localdate(ctx.now)
    items, tot = [], {"given": 0.0, "taken": 0.0}
    for ln in qs:
        paid = sum(float(r.get("amount") or 0) for r in (ln.repayments or [])
                   if isinstance(r, dict))
        left = round(max(0.0, float(ln.amount) - paid), 2)
        if left <= 0:
            continue
        tot[ln.kind] = round(tot[ln.kind] + left, 2)
        items.append({"person": ln.person, "kind": ln.kind, "amount_left": left,
                      "due_date": ln.due_date.isoformat() if ln.due_date else None,
                      "overdue": bool(ln.due_date and ln.due_date < today)})
    items.sort(key=lambda i: -i["amount_left"])
    return {"kind": kind, "given_total": tot["given"], "taken_total": tot["taken"],
            "items": items[:20]}


def _loans_dues_sum(o, lang):
    if not o["items"]:
        return _pick(lang, "কোনো বাকি ধার নেই।", "No open loans.")
    return _pick(lang, "আপনি পাবেন %s, আপনাকে দিতে হবে %s।" % (_tk(o["given_total"], lang), _tk(o["taken_total"], lang)),
                 "You will get %s; you owe %s." % (_tk(o["given_total"], lang), _tk(o["taken_total"], lang)))


# ------------------------------------------------------------------ business
def _khata_dues(ctx, a):
    from ..models import BusinessProfile, KhataEntry
    biz = BusinessProfile.objects.filter(user=ctx.user).first()
    if biz is None:
        return {"has_business": False, "total_due": 0.0, "count": 0, "items": []}
    rows = (KhataEntry.objects.filter(party__business=biz, party__book="customer",
                                      party__archived=False)
            .values("party_id", "party__name", "party__phone")
            .annotate(gave=Sum("amount_poisha", filter=Q(direction="gave")),
                      got=Sum("amount_poisha", filter=Q(direction="got"))))
    items = []
    for r in rows:
        due = ((r["gave"] or 0) - (r["got"] or 0)) / 100.0
        if due > 0:
            items.append({"name": r["party__name"], "phone": r["party__phone"] or "",
                          "due": round(due, 2)})
    items.sort(key=lambda i: -i["due"])
    lim = int(a.get("limit") or 10)
    return {"has_business": True, "total_due": round(sum(i["due"] for i in items), 2),
            "count": len(items), "items": items[:lim]}


def _khata_dues_sum(o, lang):
    if not o["has_business"]:
        return _pick(lang, "আপনার কোনো ব্যবসার খাতা নেই।", "You have no business ledger yet.")
    if not o["count"]:
        return _pick(lang, "খাতায় কারো কাছে কোনো বাকি নেই।", "No customer owes you anything.")
    top = o["items"][0]
    return _pick(lang, "%sজন গ্রাহকের কাছে মোট %s বাকি; সবচেয়ে বেশি %s (%s)।" % (
        _cnt(o["count"], lang), _tk(o["total_due"], lang), top["name"], _tk(top["due"], lang)),
        "%d customers owe you %s in total; most: %s (%s)." % (
        o["count"], _tk(o["total_due"], lang), top["name"], _tk(top["due"], lang)))


def _crm_leads(ctx, a):
    from crm.models import CrmMember, Lead
    orgs = list(CrmMember.objects.filter(user=ctx.user).values_list("org_id", flat=True))
    if not orgs:
        return {"has_crm": False, "count": 0, "follow_ups_today": 0, "items": []}
    qs = Lead.objects.filter(org_id__in=orgs)
    mine = CrmMember.objects.filter(user=ctx.user, org_id__in=orgs, role="sales")
    if mine.exists() and not CrmMember.objects.filter(
            user=ctx.user, org_id__in=orgs, role__in=("owner", "manager")).exists():
        qs = qs.filter(assigned_to__in=mine)          # sales see only their own leads
    if a.get("status"):
        qs = qs.filter(status=a["status"])
    if a.get("priority"):
        qs = qs.filter(priority=a["priority"])
    today = timezone.localdate(ctx.now)
    fu = qs.filter(next_follow_up__lte=today).exclude(status__in=("won", "lost")).count()
    lim = int(a.get("limit") or 10)
    return {"has_crm": True, "count": qs.count(), "follow_ups_today": fu,
            "items": [{"name": l.name or l.company or "", "company": l.company,
                       "status": l.status, "priority": l.priority, "score": l.score,
                       "next_follow_up": l.next_follow_up.isoformat() if l.next_follow_up else None,
                       "phone": l.phone or ""} for l in qs[:lim]]}


def _crm_leads_sum(o, lang):
    if not o["has_crm"]:
        return _pick(lang, "আপনার CRM চালু নেই।", "You do not have a CRM yet.")
    return _pick(lang, "%sটি লিড; আজ ফলো-আপ বাকি %sটি।" % (_cnt(o["count"], lang), _cnt(o["follow_ups_today"], lang)),
                 "%d leads; %d follow-ups due today." % (o["count"], o["follow_ups_today"]))


def _stock_low(ctx, a):
    from django.db.models import F
    from ..models import Product
    qs = Product.objects.filter(user=ctx.user, stock__lte=F("low_stock_at")).order_by("stock", "name")
    lim = int(a.get("limit") or 10)
    return {"count": qs.count(),
            "items": [{"name": p.name, "stock": p.stock, "low_at": p.low_stock_at} for p in qs[:lim]]}


def _stock_low_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "কোনো পণ্যের স্টক কম নেই।", "No product is low on stock.")
    names = ", ".join("%s (%s)" % (i["name"], _cnt(i["stock"], lang)) for i in o["items"][:5])
    return _pick(lang, "%sটি পণ্যের স্টক কম: %s।" % (_cnt(o["count"], lang), names),
                 "%d products are low on stock: %s." % (o["count"], names))


# ------------------------------------------------------------------ family / safety
def _family_status(ctx, a):
    from ..models import JourneyWatcher
    from .. import journey_watch as JW, push as PUSH
    now = ctx.now
    rows = (JourneyWatcher.objects
            .filter(member__peer_user=ctx.user, member__state="accepted",
                    member__blocked=False, journey__expires_at__gt=now)
            .select_related("journey", "journey__traveller")
            .order_by("-journey__created_at")[:20])
    items = []
    for w in rows:
        j = w.journey
        st, mins = JW.overdue(j, now)
        items.append({"name": PUSH.seen_name(ctx.user, j.traveller), "status": j.status,
                      "sos": bool(j.sos_active),
                      "destination": (j.destination or {}).get("name") or "",
                      "eta": _iso(j.eta), "overdue_state": st or "",
                      "overdue_minutes": int(mins or 0)})
    return {"count": len(items), "alerts": sum(1 for i in items if i["sos"] or
                                               i["overdue_state"] in ("ask", "alert")),
            "items": items}


def _family_status_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "এখন পরিবারের কেউ নিরাপদ যাত্রা শেয়ার করছেন না।",
                     "Nobody in your family is sharing a Safe Journey right now.")
    parts = []
    for i in o["items"][:5]:
        if i["sos"]:
            parts.append(_pick(lang, "%s — SOS চালু!" % i["name"], "%s — SOS active!" % i["name"]))
        elif i["overdue_state"] in ("grace", "ask", "alert"):
            parts.append(_pick(lang, "%s — %s মিনিট দেরি" % (i["name"], _cnt(i["overdue_minutes"], lang)),
                               "%s — %d min late" % (i["name"], i["overdue_minutes"])))
        else:
            parts.append(_pick(lang, "%s — যাত্রা: %s" % (i["name"], i["status"]),
                               "%s — journey: %s" % (i["name"], i["status"])))
    return "; ".join(parts) + ("।" if lang == "bn" else ".")


def _journey_status(ctx, a):
    from ..models import Journey
    from .. import journey_watch as JW
    j = (Journey.objects.filter(traveller=ctx.user, status="active").order_by("-created_at").first())
    if j is None:
        return {"active": False, "destination": "", "eta": None, "overdue_state": "",
                "overdue_minutes": 0, "watchers": 0}
    st, mins = JW.overdue(j, ctx.now)
    return {"active": True, "destination": (j.destination or {}).get("name") or "",
            "eta": _iso(j.eta), "overdue_state": st or "", "overdue_minutes": int(mins or 0),
            "watchers": j.watchers.count()}


def _journey_status_sum(o, lang):
    if not o["active"]:
        return _pick(lang, "আপনার কোনো চলমান নিরাপদ যাত্রা নেই।", "You have no active Safe Journey.")
    return _pick(lang, "চলমান যাত্রা: %s, %sজন দেখছেন।" % (o["destination"] or "—", _cnt(o["watchers"], lang)),
                 "Active journey to %s, %d watching." % (o["destination"] or "—", o["watchers"]))


# ------------------------------------------------------------------ registry
def _list_out(item_props):
    return {"type": "array", "maxItems": 20, "items": obj(item_props, extra=True)}


TOOLS = (
    Tool("reminders.list", 1, "রিমাইন্ডার দেখা", "List reminders",
         "Upcoming reminders of the user within N days.", "read",
         obj({"days": {"type": "integer", "minimum": 1, "maximum": 60}, "include_done": _BOOL}),
         obj({"days": _INT, "count": _INT, "items": _list_out({"title": _STR})},
             ("days", "count", "items"), extra=True),
         _reminders_list, _reminders_list_sum, feature="reminders",
         topics=("family", "safety", "money", "business", "documents", "travel", "health", "learning")),
    Tool("reminders.create", 1, "রিমাইন্ডার সেট", "Create a reminder",
         "Create one reminder for the user. due_at = ISO 8601 local (Asia/Dhaka) datetime.",
         "write_low",
         obj({"title": {"type": "string", "minLength": 1, "maxLength": 200},
              "due_at": {"type": "string", "minLength": 10, "maxLength": 40},
              "notes": {"type": "string", "maxLength": 2000}}, ("title", "due_at")),
         obj({"id": _INT, "title": _STR, "due_at": _STR, "created": _BOOL},
             ("id", "title", "due_at", "created")),
         _reminders_create, _reminders_create_sum, rate_per_hour=20, feature="reminders",
         topics=("family", "money", "business", "travel", "health", "learning")),
    Tool("notes.search", 1, "নোট খোঁজা", "Search notes",
         "Find the user's notes by text (empty query = latest).", "read",
         obj({"query": {"type": "string", "maxLength": 100},
              "limit": {"type": "integer", "minimum": 1, "maximum": 20}}),
         obj({"query": _STR, "count": _INT, "items": _list_out({"id": _INT})},
             ("count", "items"), extra=True),
         _notes_search, _notes_search_sum, feature="notes",
         topics=("family", "money", "business", "documents", "health", "learning")),
    Tool("notes.create", 1, "নোট লেখা", "Create a note",
         "Save a note for the user.", "write_low",
         obj({"title": {"type": "string", "minLength": 1, "maxLength": 200},
              "body": {"type": "string", "maxLength": 5000}}, ("title",)),
         obj({"id": _INT, "title": _STR, "created": _BOOL}, ("id", "title", "created")),
         _notes_create, _notes_create_sum, rate_per_hour=20, feature="notes",
         topics=("family", "money", "business", "documents", "travel", "health", "learning")),
    Tool("notes.delete", 1, "নোট মোছা", "Delete a note",
         "Delete one note by id (always needs the user's approval).", "delete",
         obj({"id": {"type": "integer", "minimum": 1}}, ("id",)),
         obj({"id": _INT, "deleted": _BOOL, "title": _STR}, ("id", "deleted", "title")),
         _notes_delete, _notes_delete_sum, rate_per_hour=10, feature="notes",
         topics=("documents", "learning"), approval_title=_notes_delete_title),
    Tool("money.month_summary", 1, "মাসের আয়-খরচ", "Month income/expense summary",
         "Income, expenses, net and top expense categories for a month (YYYY-MM, default this month).",
         "read", obj({"month": _MONTH}),
         obj({"month": _STR, "income": _NUM, "expense": _NUM, "net": _NUM, "count": _INT,
              "top_categories": _list_out({"category": _STR, "amount": _NUM})},
             ("month", "income", "expense", "net", "count", "top_categories")),
         _money_month, _money_month_sum, feature="money", topics=("money",)),
    Tool("budget.status", 1, "বাজেটের অবস্থা", "Budget status",
         "Each monthly budget category: limit, spent, percent, state ok|near|over.", "read",
         obj({"month": _MONTH}),
         obj({"month": _STR, "items": _list_out({"category": _STR}), "over_count": _INT,
              "near_count": _INT}, ("month", "items", "over_count", "near_count")),
         _budget_status, _budget_status_sum, feature="budget", topics=("money",)),
    Tool("loans.dues", 1, "ধার-দেনা", "Open loans",
         "Open personal loans: money the user will get (given) and owes (taken).", "read",
         obj({"kind": {"type": "string", "enum": ["given", "taken", "all"]}}),
         obj({"kind": _STR, "given_total": _NUM, "taken_total": _NUM,
              "items": _list_out({"person": _STR})},
             ("given_total", "taken_total", "items"), extra=True),
         _loans_dues, _loans_dues_sum, feature="money", topics=("money",)),
    Tool("khata.dues", 1, "খাতার বাকি", "Ledger dues",
         "Business ledger: which customers owe money and how much.", "read",
         obj({"limit": {"type": "integer", "minimum": 1, "maximum": 20}}),
         obj({"has_business": _BOOL, "total_due": _NUM, "count": _INT,
              "items": _list_out({"name": _STR, "due": _NUM})},
             ("has_business", "total_due", "count", "items")),
         _khata_dues, _khata_dues_sum, feature="business", topics=("business",),
         pii_out=("phone",)),
    Tool("crm.leads", 1, "CRM লিড", "CRM leads",
         "CRM leads the user can see, optional status/priority filter, follow-ups due today.",
         "read",
         obj({"status": {"type": "string", "enum": ["new", "contacted", "demo", "proposal", "won", "lost"]},
              "priority": {"type": "string", "enum": ["high", "normal"]},
              "limit": {"type": "integer", "minimum": 1, "maximum": 20}}),
         obj({"has_crm": _BOOL, "count": _INT, "follow_ups_today": _INT,
              "items": _list_out({"name": _STR})},
             ("has_crm", "count", "follow_ups_today", "items")),
         _crm_leads, _crm_leads_sum, feature="crm", topics=("business",), pii_out=("phone",)),
    Tool("stock.low", 1, "কম স্টক", "Low stock",
         "Catalog products at or below their low-stock level.", "read",
         obj({"limit": {"type": "integer", "minimum": 1, "maximum": 20}}),
         obj({"count": _INT, "items": _list_out({"name": _STR, "stock": _INT})},
             ("count", "items")),
         _stock_low, _stock_low_sum, feature="business", topics=("business",)),
    Tool("family.status", 1, "পরিবারের অবস্থা", "Family status",
         "Family members' shared Safe Journeys: status, SOS, late minutes (never locations).",
         "read", obj({}),
         obj({"count": _INT, "alerts": _INT, "items": _list_out({"name": _STR, "status": _STR})},
             ("count", "alerts", "items")),
         _family_status, _family_status_sum, feature="safe_journey",
         topics=("family", "safety")),
    Tool("journey.status", 1, "আমার যাত্রা", "My journey",
         "The user's own active Safe Journey: destination, ETA, late state, watchers.", "read",
         obj({}),
         obj({"active": _BOOL, "destination": _STR, "eta": {"type": ["string", "null"]},
              "overdue_state": _STR, "overdue_minutes": _INT, "watchers": _INT},
             ("active",)),
         _journey_status, _journey_status_sum, feature="safe_journey",
         topics=("family", "safety", "travel")),
)

REGISTRY = {t.name: t for t in TOOLS}


def get(name):
    return REGISTRY.get(name)


def available(ctx, names):
    """The tools of `names` whose feature flag is on for this user."""
    out = []
    for n in names:
        t = REGISTRY.get(n)
        if t and (not t.feature or _flag(ctx, t.feature)):
            out.append(t)
    return out
