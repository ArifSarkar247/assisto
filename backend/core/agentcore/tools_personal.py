"""WP-TOOLS-A: personal-life tools (birthdays, documents, money log,
remittance, prepaid meter, scam check, reminder update/complete).

Same contract as tools.py: every query filters on the CALLER (ownership is
the filter, never a check afterwards), outputs match their schema, and each
tool has a template `summarize(out, lang)` so the answer needs no second LLM
call. Read tools cost 0 credits (the planner call is what is charged).

Data minimisation:
  * documents.expiring returns METADATA ONLY (title, type, expiry) — never the
    file, the note or the structured `details` (passport / NID numbers).
  * meter.balance is an ESTIMATE from the user's own recharge history (there
    is no live utility link) and every answer says so.
  * scam.check runs the existing rule engine (core.logic.scam) on the text;
    no AI call, no storage.
Write tools (money.log, reminders.update/complete) are write_low: own data,
idempotent on the step's idempotency key, reversible from the app.
"""
import re
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation

from django.utils import timezone
from django.utils.dateparse import parse_datetime

from .contract import Tool, ToolError, obj
from .tools import (_BOOL, _INT, _MONTH, _NUM, _STR, _cnt, _flag, _iso, _list_out, _pick, _tk)

MONEY_MAX = Decimal("10000000")       # ৳1 crore per entry — beyond is a typo


def _today(ctx):
    return timezone.localdate(ctx.now)


def _need_flag(ctx, key):
    """Write tools re-check their module's switch at run time (an approval or
    a queued step can outlive a flag change)."""
    if key and not _flag(ctx, key):
        raise ToolError("feature_off", key)


# ------------------------------------------------------------------ birthdays
def _birthdays(ctx, a):
    from ..models import Birthday
    from ..logic import birthdays as B
    days = int(a.get("days") or 30)
    today = _today(ctx)
    occ = [{"name": b.name, "date": b.date.isoformat(), "kind": b.kind}
           for b in Birthday.objects.filter(user=ctx.user)]
    rows = B.upcoming(occ, within_days=days, today=today, lang=ctx.lang)
    items = [{"name": r["name"], "kind": r["kind"], "date": r["next_date"],
              "days_until": int(r["days_until"]),
              "turning_age": r["turning_age"] if isinstance(r.get("turning_age"), int) else None}
             for r in rows[:20]]
    return {"days": days, "count": len(rows), "items": items}


_KIND_BN = {"birthday": "জন্মদিন", "anniversary": "বিবাহবার্ষিকী",
            "death_anniversary": "মৃত্যুবার্ষিকী", "memorable": "স্মরণীয় দিন"}
_KIND_EN = {"birthday": "birthday", "anniversary": "anniversary",
            "death_anniversary": "death anniversary", "memorable": "memorable day"}


def _birthdays_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "আগামী %s দিনে কোনো জন্মদিন বা বিশেষ দিন নেই।" % _cnt(o["days"], lang),
                     "No birthdays or special days in the next %d days." % o["days"])
    parts = []
    for i in o["items"][:5]:
        if lang == "bn":
            when = "আজ" if i["days_until"] == 0 else "%s দিন পরে" % _cnt(i["days_until"], lang)
            parts.append("%s — %s, %s" % (i["name"], _KIND_BN.get(i["kind"], i["kind"]), when))
        else:
            when = "today" if i["days_until"] == 0 else "in %d days" % i["days_until"]
            parts.append("%s — %s, %s" % (i["name"], _KIND_EN.get(i["kind"], i["kind"]), when))
    return _pick(lang, "আগামী %s দিনে %sটি বিশেষ দিন: %s।" % (_cnt(o["days"], lang), _cnt(o["count"], lang),
                                                          "; ".join(parts)),
                 "%d special days in the next %d days: %s." % (o["count"], o["days"], "; ".join(parts)))


# ------------------------------------------------------------------ documents
def _docs_expiring(ctx, a):
    from ..models import Document
    days = int(a.get("days") or 90)
    today = _today(ctx)
    qs = Document.objects.filter(user=ctx.user, expiry_date__isnull=False,
                                 expiry_date__lte=today + timedelta(days=days))
    if not a.get("include_expired", True):
        qs = qs.filter(expiry_date__gte=today)
    # metadata ONLY: never file / note / details
    rows = list(qs.order_by("expiry_date").values("id", "title", "doc_type", "expiry_date")[:20])
    items = [{"id": r["id"], "title": r["title"], "doc_type": r["doc_type"],
              "expiry_date": r["expiry_date"].isoformat(),
              "days_left": (r["expiry_date"] - today).days,
              "expired": r["expiry_date"] < today} for r in rows]
    return {"days": days, "count": qs.count(),
            "expired_count": sum(1 for i in items if i["expired"]), "items": items}


def _docs_expiring_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "আগামী %s দিনে কোনো ডকুমেন্টের মেয়াদ শেষ হচ্ছে না।" % _cnt(o["days"], lang),
                     "No document expires in the next %d days." % o["days"])
    parts = []
    for i in o["items"][:5]:
        if i["expired"]:
            parts.append(_pick(lang, "%s — মেয়াদ শেষ (%s দিন আগে)" % (i["title"], _cnt(-i["days_left"], lang)),
                               "%s — expired %d days ago" % (i["title"], -i["days_left"])))
        else:
            parts.append(_pick(lang, "%s — %s দিন বাকি" % (i["title"], _cnt(i["days_left"], lang)),
                               "%s — %d days left" % (i["title"], i["days_left"])))
    return _pick(lang, "%sটি ডকুমেন্টের মেয়াদ নিয়ে খেয়াল রাখুন: %s।" % (_cnt(o["count"], lang), "; ".join(parts)),
                 "%d documents need attention: %s." % (o["count"], "; ".join(parts)))


# ------------------------------------------------------------------ money.log
def _clean_amount(v):
    try:
        d = Decimal(str(v)).quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError, TypeError):
        raise ToolError("bad_amount")
    if d <= 0 or d > MONEY_MAX:
        raise ToolError("bad_amount")
    return d


def _clean_category(v, kind):
    from ..logic import money_engine as ME
    c = re.sub(r"\s+", " ", str(v or "")).strip().lower()[:60]
    if not c:
        return "income" if kind == "income" else "uncategorized"
    for slug, (bn, en) in ME.CATEGORY_LABELS.items():   # "Food"/"খাবার" -> food
        if c in (slug, bn.lower(), en.lower()):
            return slug
    return c


def _money_log(ctx, a):
    """Same rules as the app's own quick-entry (views agent intent expense /
    income): the user's first account (a Cash account is made if none),
    source tagged, plus server-side validation the plan cannot bypass:
    amount 0 < x <= ৳1 crore, date not in the future and within a year."""
    from ..models import Account, Transaction
    _need_flag(ctx, "money")
    old = Transaction.objects.filter(user=ctx.user, ref=ctx.idem_key[:40]).first() \
        if ctx.idem_key else None
    if old:
        return {"id": old.id, "kind": old.kind, "amount": float(old.amount),
                "category": old.category, "date": old.date.isoformat(), "created": False}
    kind = a["kind"]
    amount = _clean_amount(a["amount"])
    today = _today(ctx)
    d = today
    if a.get("date"):
        try:
            d = date.fromisoformat(a["date"])
        except ValueError:
            raise ToolError("bad_date")
        if d > today:
            raise ToolError("date_in_future")
        if d < today - timedelta(days=366):
            raise ToolError("date_too_old")
    acc = Account.objects.filter(user=ctx.user).order_by("id").first()
    if acc is None:
        acc = Account.objects.create(user=ctx.user, name="ক্যাশ", acc_type="cash")
    t = Transaction.objects.create(
        user=ctx.user, account=acc, kind=kind, amount=amount,
        category=_clean_category(a.get("category"), kind),
        note=(a.get("note") or "").strip()[:200], date=d, source="agent",
        ref=(ctx.idem_key or "")[:40])
    return {"id": t.id, "kind": t.kind, "amount": float(t.amount), "category": t.category,
            "date": t.date.isoformat(), "created": True}


def _money_log_sum(o, lang):
    if o["kind"] == "income":
        return _pick(lang, "আয় লেখা হয়েছে: %s (%s)। ভুল হলে অ্যাপ থেকে মুছে দিন।" % (_tk(o["amount"], lang), o["category"]),
                     "Income logged: %s (%s). Undo it from the app if wrong." % (_tk(o["amount"], lang), o["category"]))
    return _pick(lang, "খরচ লেখা হয়েছে: %s (%s)। ভুল হলে অ্যাপ থেকে মুছে দিন।" % (_tk(o["amount"], lang), o["category"]),
                 "Expense logged: %s (%s). Undo it from the app if wrong." % (_tk(o["amount"], lang), o["category"]))


# ------------------------------------------------------------------ remittance
def _remit_card(ctx, month):
    from .. import remittance_views as RV
    from ..logic import remittance as RL
    if month and not RL.valid_month(month):
        raise ToolError("bad_month")
    m = month or RL.month_key(_today(ctx))
    _, _, card = RV._month_card(ctx.user, m, ctx.lang, mark_alert=False)   # read-only
    return card


def _remit_overview(ctx, a):
    c = _remit_card(ctx, a.get("month"))
    ex = c["expected"]
    return {"month": c["month"], "received": float(c["received"]), "count": int(c["count"]),
            "expected": float(ex["taka"]), "expected_day": int(ex["day"] or 0),
            "status": ex["status"], "due_date": ex["due_date"],
            "spent": float(c["plan"]["spent"]), "left": float(c["plan"]["left"])}


_REMIT_BN = {"none": "প্রত্যাশিত টাকা সেট করা নেই", "future": "মাস এখনো শুরু হয়নি",
             "arrived": "পুরো টাকা এসেছে", "partial": "কিছু টাকা এসেছে",
             "waiting": "এখনো আসার সময় আছে", "missing": "নির্ধারিত দিন পেরিয়ে গেছে, টাকা আসেনি"}
_REMIT_EN = {"none": "no expected amount set", "future": "month not started",
             "arrived": "fully arrived", "partial": "partly arrived",
             "waiting": "not due yet", "missing": "the expected day has passed and nothing arrived"}


def _remit_overview_sum(o, lang):
    if not o["count"] and o["status"] == "none":
        return _pick(lang, "%s মাসে কোনো রেমিট্যান্স লেখা নেই।" % _cnt(o["month"], lang),
                     "No remittance recorded for %s." % o["month"])
    bn = "%s: রেমিট্যান্স এসেছে %s (%sটি), খরচ %s, বাকি %s।" % (
        _cnt(o["month"], lang), _tk(o["received"], lang), _cnt(o["count"], lang),
        _tk(o["spent"], lang), _tk(o["left"], lang))
    en = "%s: remittance received %s (%d entries), spent %s, left %s." % (
        o["month"], _tk(o["received"], lang), o["count"], _tk(o["spent"], lang), _tk(o["left"], lang))
    if o["status"] != "none":
        bn += " প্রত্যাশিত %s — %s।" % (_tk(o["expected"], lang), _REMIT_BN[o["status"]])
        en += " Expected %s — %s." % (_tk(o["expected"], lang), _REMIT_EN[o["status"]])
    return _pick(lang, bn, en)


def _remit_missing(ctx, a):
    c = _remit_card(ctx, a.get("month"))
    ex = c["expected"]
    late = 0
    if ex["status"] == "missing" and ex["due_date"]:
        late = max(0, (_today(ctx) - date.fromisoformat(ex["due_date"])).days)
    return {"month": c["month"], "status": ex["status"], "missing": ex["status"] == "missing",
            "expected": float(ex["taka"]), "received": float(c["received"]),
            "due_date": ex["due_date"], "days_late": late}


def _remit_missing_sum(o, lang):
    if o["status"] == "none":
        return _pick(lang, "প্রত্যাশিত রেমিট্যান্সের পরিমাণ ও দিন সেট করা নেই।",
                     "No expected remittance amount and day are set.")
    if o["missing"]:
        return _pick(lang, "এ মাসের রেমিট্যান্স (%s) এখনো আসেনি — নির্ধারিত দিনের %s দিন পেরিয়েছে।" % (
            _tk(o["expected"], lang), _cnt(o["days_late"], lang)),
            "This month's remittance (%s) has not arrived — %d days past the expected day." % (
            _tk(o["expected"], lang), o["days_late"]))
    return _pick(lang, "রেমিট্যান্স: %s (এসেছে %s, প্রত্যাশিত %s)।" % (
        _REMIT_BN[o["status"]], _tk(o["received"], lang), _tk(o["expected"], lang)),
        "Remittance: %s (received %s of %s)." % (_REMIT_EN[o["status"]], _tk(o["received"], lang),
                                                 _tk(o["expected"], lang)))


# ------------------------------------------------------------------ meter
def _meter_balance(ctx, a):
    from ..models import PaCollectionItem
    from ..logic import prepaid_meter as PM
    meters = list(PaCollectionItem.objects.filter(user=ctx.user, collection="meter/meters"))
    rech = {}
    for r in PaCollectionItem.objects.filter(user=ctx.user, collection="meter/recharges"):
        rech.setdefault(str((r.data or {}).get("meter")), []).append(r.data or {})
    rows = PM.meters_overview([dict(m.data or {}, id=m.id) for m in meters],
                              {m.id: rech.get(str(m.id), []) for m in meters},
                              as_of=_today(ctx))
    items = [{"name": r["name"] or "Meter", "kind": r["kind"],
              "balance": round(r["balance"] / 100.0, 2), "days_left": r["days_left"],
              "runout_date": r["runout_date"], "state": r["state"], "basis": r["basis"]}
             for r in rows[:20]]
    return {"count": len(rows), "estimate": True,
            "low_count": sum(1 for i in items if i["state"] in ("low", "empty")), "items": items}


def _meter_balance_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "কোনো প্রিপেইড মিটার যোগ করা নেই।", "No prepaid meter has been added.")
    parts = []
    for i in o["items"][:5]:
        if i["state"] == "unknown":
            parts.append(_pick(lang, "%s: আনুমানিক %s (কত দিন চলবে বলা যাচ্ছে না)" % (i["name"], _tk(i["balance"], lang)),
                               "%s: about %s (cannot tell how long it lasts yet)" % (i["name"], _tk(i["balance"], lang))))
        else:
            parts.append(_pick(lang, "%s: আনুমানিক %s, প্রায় %s দিন চলবে" % (
                i["name"], _tk(i["balance"], lang), _cnt(i["days_left"] or 0, lang)),
                "%s: about %s, roughly %d days left" % (i["name"], _tk(i["balance"], lang), i["days_left"] or 0)))
    return _pick(lang, "মিটারের অনুমান (আপনার রিচার্জের হিসাব থেকে, লাইভ রিডিং নয়): %s।" % "; ".join(parts),
                 "Meter estimate (from your recharge history, not a live reading): %s." % "; ".join(parts))


# ------------------------------------------------------------------ scam
def _scam_check(ctx, a):
    from ..logic import scam as SC
    r = SC.check_message(a.get("text") or "", lang=ctx.lang)
    return {"verdict": r["verdict"], "score": int(r["score"]), "level": r["level"],
            "label": r["label"], "signals": [p["name"] for p in r["patterns"]][:10],
            "advice": r["advice"]}


def _scam_check_sum(o, lang):
    sig = ", ".join(o["signals"][:3])
    head = "%s (%s/100)" % (o["label"], _cnt(o["score"], lang))
    if sig:
        return _pick(lang, "%s। সংকেত: %s। %s" % (head, sig, o["advice"]),
                     "%s. Signals: %s. %s" % (head, sig, o["advice"]))
    return _pick(lang, "%s। %s" % (head, o["advice"]), "%s. %s" % (head, o["advice"]))


# ------------------------------------------------------------------ reminders
def _own_reminder(ctx, rid):
    from ..models import Reminder
    r = Reminder.objects.filter(user=ctx.user, pk=rid).first()
    if r is None:
        raise ToolError("not_found")
    return r


def _reminders_update(ctx, a):
    _need_flag(ctx, "reminders")
    r = _own_reminder(ctx, a["id"])
    fields = []
    if a.get("title"):
        r.title = a["title"].strip()[:200]
        fields.append("title")
    if a.get("due_at"):
        due = parse_datetime(a["due_at"])
        if due is None:
            raise ToolError("bad_due_at")
        if timezone.is_naive(due):
            due = timezone.make_aware(due, timezone.get_current_timezone())
        if due < ctx.now - timedelta(minutes=5):
            raise ToolError("due_in_past")
        r.due_at = due
        fields.append("due_at")
    if not fields:
        raise ToolError("nothing_to_change")
    r.save(update_fields=fields + ["updated_at"])       # same args -> same row: idempotent
    return {"id": r.id, "title": r.title, "due_at": _iso(r.due_at), "changed": fields}


def _reminders_update_sum(o, lang):
    when = timezone.localtime(parse_datetime(o["due_at"])).strftime("%d/%m %H:%M") if o["due_at"] else "—"
    return _pick(lang, "রিমাইন্ডার বদলানো হয়েছে: “%s” — %s।" % (o["title"], _cnt(when, lang)),
                 "Reminder updated: “%s” — %s." % (o["title"], when))


def _reminders_complete(ctx, a):
    _need_flag(ctx, "reminders")
    r = _own_reminder(ctx, a["id"])
    was = r.done
    if not was:
        r.done = True
        r.save(update_fields=["done", "updated_at"])
    return {"id": r.id, "title": r.title, "done": True, "changed": not was}


def _reminders_complete_sum(o, lang):
    return _pick(lang, "রিমাইন্ডার সম্পন্ন: “%s”।" % o["title"], "Reminder marked done: “%s”." % o["title"])


# ------------------------------------------------------------------ registry
_DUE = {"type": "string", "minLength": 10, "maxLength": 40}

TOOLS = (
    Tool("birthdays.upcoming", 1, "আসন্ন জন্মদিন", "Upcoming birthdays",
         "Birthdays, anniversaries and memorable days of the user's people within N days.", "read",
         obj({"days": {"type": "integer", "minimum": 1, "maximum": 90}}),
         obj({"days": _INT, "count": _INT,
              "items": _list_out({"name": _STR, "kind": _STR, "date": _STR, "days_until": _INT})},
             ("days", "count", "items")),
         _birthdays, _birthdays_sum, feature="birthdays", topics=("family",)),
    Tool("documents.expiring", 1, "মেয়াদ শেষের ডকুমেন্ট", "Expiring documents",
         "The user's documents (passport, NID, licence...) expiring within N days — "
         "metadata only (title, type, expiry), never contents.", "read",
         obj({"days": {"type": "integer", "minimum": 1, "maximum": 365}, "include_expired": _BOOL}),
         obj({"days": _INT, "count": _INT, "expired_count": _INT,
              "items": _list_out({"title": _STR, "doc_type": _STR, "expiry_date": _STR,
                                  "days_left": _INT, "expired": _BOOL})},
             ("days", "count", "expired_count", "items")),
         _docs_expiring, _docs_expiring_sum, rate_per_hour=30, feature="documents",
         topics=("documents", "travel")),
    Tool("money.log", 1, "খরচ/আয় লেখা", "Log expense/income",
         "Record ONE expense or income the user states (amount in taka). date = YYYY-MM-DD, "
         "default today. Never for money the user wants SENT — this only writes his own book.",
         "write_low",
         obj({"kind": {"type": "string", "enum": ["expense", "income"]},
              "amount": {"type": "number", "minimum": 0.01, "maximum": 10000000},
              "category": {"type": "string", "maxLength": 60},
              "note": {"type": "string", "maxLength": 200},
              "date": {"type": "string", "minLength": 10, "maxLength": 10}}, ("kind", "amount")),
         obj({"id": _INT, "kind": _STR, "amount": _NUM, "category": _STR, "date": _STR,
              "created": _BOOL}, ("id", "kind", "amount", "category", "date", "created")),
         _money_log, _money_log_sum, rate_per_hour=30, feature="money", topics=("money",)),
    Tool("remit.overview", 1, "রেমিট্যান্সের হিসাব", "Remittance overview",
         "Money from abroad for a month (YYYY-MM, default this month): received, spent, left, "
         "expected amount and its status.", "read", obj({"month": _MONTH}),
         obj({"month": _STR, "received": _NUM, "count": _INT, "expected": _NUM, "status": _STR,
              "spent": _NUM, "left": _NUM, "due_date": {"type": ["string", "null"]}},
             ("month", "received", "count", "expected", "status", "spent", "left"), extra=True),
         _remit_overview, _remit_overview_sum, rate_per_hour=30, feature="budget_remittance",
         topics=("money", "family")),
    Tool("remit.missing", 1, "রেমিট্যান্স আসেনি?", "Remittance missing?",
         "Has this month's expected remittance arrived? status none|future|arrived|partial|waiting|missing.",
         "read", obj({"month": _MONTH}),
         obj({"month": _STR, "status": _STR, "missing": _BOOL, "expected": _NUM, "received": _NUM,
              "days_late": _INT, "due_date": {"type": ["string", "null"]}},
             ("month", "status", "missing", "expected", "received", "days_late")),
         _remit_missing, _remit_missing_sum, rate_per_hour=30, feature="budget_remittance",
         topics=("money", "family")),
    Tool("meter.balance", 1, "মিটারের ব্যালান্স (অনুমান)", "Meter balance (estimate)",
         "Prepaid electricity/gas meters: ESTIMATED balance and days left from the user's own "
         "recharge history (no live meter reading exists).", "read", obj({}),
         obj({"count": _INT, "estimate": _BOOL, "low_count": _INT,
              "items": _list_out({"name": _STR, "balance": _NUM, "state": _STR})},
             ("count", "estimate", "low_count", "items")),
         _meter_balance, _meter_balance_sum, rate_per_hour=30, feature="prepaid_meter",
         topics=("money",)),
    Tool("scam.check", 1, "প্রতারণা যাচাই", "Scam check",
         "Check a suspicious SMS/message text with Assisto's scam rules (verdict scam|suspicious|safe).",
         "read", obj({"text": {"type": "string", "maxLength": 2000}}),
         obj({"verdict": {"type": "string", "enum": ["scam", "suspicious", "safe"]}, "score": _INT,
              "level": _STR, "label": _STR, "signals": {"type": "array", "maxItems": 10, "items": _STR},
              "advice": _STR}, ("verdict", "score", "level", "label", "signals", "advice")),
         _scam_check, _scam_check_sum, rate_per_hour=30, feature="scam_check",
         topics=("safety", "family", "money")),
    Tool("reminders.update", 1, "রিমাইন্ডার বদলানো", "Update a reminder",
         "Change the title and/or time of one of the user's reminders (id from reminders.list).",
         "write_low",
         obj({"id": {"type": "integer", "minimum": 1},
              "title": {"type": "string", "minLength": 1, "maxLength": 200}, "due_at": _DUE}, ("id",)),
         obj({"id": _INT, "title": _STR, "due_at": {"type": ["string", "null"]},
              "changed": {"type": "array", "maxItems": 2, "items": _STR}},
             ("id", "title", "changed")),
         _reminders_update, _reminders_update_sum, rate_per_hour=20, feature="reminders",
         topics=("family", "money", "business", "travel", "health", "learning")),
    Tool("reminders.complete", 1, "রিমাইন্ডার সম্পন্ন", "Complete a reminder",
         "Mark one of the user's reminders done (id from reminders.list).", "write_low",
         obj({"id": {"type": "integer", "minimum": 1}}, ("id",)),
         obj({"id": _INT, "title": _STR, "done": _BOOL, "changed": _BOOL},
             ("id", "title", "done", "changed")),
         _reminders_complete, _reminders_complete_sum, rate_per_hour=20, feature="reminders",
         topics=("family", "money", "business", "travel", "health", "learning")),
)
