"""bizops: the BUSINESS AI AGENT's daily-operations tools (owner order PART 1
i), second half; card owner_actions/FEATURE_CARD_BIZ_OPS_AGENT_BN.md).

Every number comes from the shop's OWN rows (POS Sale/SaleLine, Expense,
khata, catalog, CRM, the cashbox close) — the summaries are templates, so a
read never needs an LLM call and can never state an invented number.

  biz.profit          read       sales / profit / expenses for a period vs the
                                 same span a week (or a period) earlier
  stock.running_out   read       sales speed (14 days) -> days left, reorder qty
  biz.cash_check      read       a day's cash box: expected (from the books) vs
                                 counted at close
  biz.daily_brief     read       the morning business card: all of the above +
                                 dues to collect today + CRM follow-ups +
                                 suggested one-tap actions
  supplier.reorder    external   a reorder message to ONE own supplier; after
                                 the owner's approval it is PREPARED for him to
                                 send on WhatsApp — the server never sends it
  crm.followup_task   write_low  a CRM task on one visible lead + the lead's
                                 next follow-up date + a phone reminder
                                 (idempotent per agent step)
"""
import math
from datetime import date, datetime, time, timedelta

from django.db.models import Count, F, Q, Sum
from django.utils import timezone

from .contract import Tool, ToolError, obj
from .tools import _BOOL, _INT, _NUM, _STR, _cnt, _flag, _list_out, _pick, _tk

VELOCITY_DAYS = 14          # sales speed window
RUNOUT_DAYS = 7             # "running out" = gone within a week at this speed
COVER_DAYS = 14             # a reorder covers two weeks of sales
PERIODS = ("today", "yesterday", "week", "month")


def _need_flag(ctx, key):
    if key and not _flag(ctx, key):
        raise ToolError("feature_off", key)


def _biz(ctx):
    from ..models import BusinessProfile
    return BusinessProfile.objects.filter(user=ctx.user).first()


def _tk100(poisha):
    return round((poisha or 0) / 100.0, 2)


def _day0(ctx):
    local = timezone.localtime(ctx.now)
    return local.replace(hour=0, minute=0, second=0, microsecond=0)


def _pct(now, before):
    """Change in % (int) or None when there is nothing to compare with."""
    if not before:
        return None
    return int(round((now - before) * 100.0 / abs(before)))


# ------------------------------------------------------------------ biz.profit
def _span(ctx, period):
    """-> (start, end, prev_start, prev_end) aware datetimes."""
    d0 = _day0(ctx)
    now = timezone.localtime(ctx.now)
    if period == "today":
        return d0, now, d0 - timedelta(days=7), now - timedelta(days=7)
    if period == "yesterday":
        s = d0 - timedelta(days=1)
        return s, d0, s - timedelta(days=7), d0 - timedelta(days=7)
    if period == "week":
        s = d0 - timedelta(days=6)
        return s, now, s - timedelta(days=7), now - timedelta(days=7)
    # month to date vs the same number of days of the previous month
    s = d0.replace(day=1)
    pe = s
    ps = (s - timedelta(days=1)).replace(day=1)
    elapsed = now - s
    return s, now, ps, min(pe, ps + elapsed)


def _sales(ctx, start, end):
    from ..models import Expense, Sale, SaleLine
    qs = Sale.objects.filter(user=ctx.user, voided_at__isnull=True,
                             created_at__gte=start, created_at__lt=end)
    agg = qs.aggregate(n=Count("id"), rev=Sum("total"), pr=Sum("profit"), due=Sum("due"))
    el = timezone.localtime(end)
    e_day = el.date() if el.time() == time(0) else el.date() + timedelta(days=1)
    exp = Expense.objects.filter(user=ctx.user, date__gte=timezone.localtime(start).date(),
                                 date__lt=e_day).aggregate(s=Sum("amount"))["s"] or 0
    missing = SaleLine.objects.filter(sale__in=qs, cost_price=0).values("sale_id").distinct().count()
    return {"count": agg["n"] or 0, "revenue": agg["rev"] or 0, "profit": agg["pr"] or 0,
            "due": agg["due"] or 0, "expenses": exp, "missing_cost": missing}


def profit(ctx, a):
    period = a.get("period") or "today"
    if period not in PERIODS:
        raise ToolError("bad_period")
    s, e, ps, pe = _span(ctx, period)
    cur, prev = _sales(ctx, s, e), _sales(ctx, ps, pe)
    return {"period": period, "sales_count": cur["count"],
            "revenue": _tk100(cur["revenue"]), "profit": _tk100(cur["profit"]),
            "expenses": _tk100(cur["expenses"]),
            "net": _tk100(cur["profit"] - cur["expenses"]),
            "due_sales": _tk100(cur["due"]),
            "prev_revenue": _tk100(prev["revenue"]), "prev_profit": _tk100(prev["profit"]),
            "profit_change_pct": _pct(cur["profit"], prev["profit"]),
            "revenue_change_pct": _pct(cur["revenue"], prev["revenue"]),
            "missing_cost": cur["missing_cost"]}


_PERIOD_BN = {"today": "আজ", "yesterday": "গতকাল", "week": "গত ৭ দিনে", "month": "এ মাসে"}
_PERIOD_EN = {"today": "Today", "yesterday": "Yesterday", "week": "In the last 7 days",
              "month": "This month"}
_PREV_BN = {"today": "গত সপ্তাহের এই দিনের এই সময় পর্যন্ত", "yesterday": "গত সপ্তাহের একই দিনে",
            "week": "তার আগের ৭ দিনে", "month": "গত মাসের একই কয়দিনে"}
_PREV_EN = {"today": "same day last week, up to this time", "yesterday": "same day last week",
            "week": "the 7 days before", "month": "the same days last month"}


def _change(p, lang):
    if p is None:
        return ""
    if lang == "bn":
        return "%s%%%s" % (_cnt(abs(p), lang), " বেশি" if p > 0 else (" কম" if p < 0 else " — একই"))
    return "%d%%%s" % (abs(p), " more" if p > 0 else (" less" if p < 0 else " — the same"))


def profit_sum(o, lang):
    per = o["period"]
    if not o["sales_count"]:
        return _pick(lang, "%s কোনো বিক্রি লেখা হয়নি — লাভ ৳০।" % _PERIOD_BN[per],
                     "%s: no sales recorded — profit ৳0." % _PERIOD_EN[per])
    bn = "%s %sটি বিক্রি, মোট %s; লাভ %s" % (_PERIOD_BN[per], _cnt(o["sales_count"], "bn"),
                                          _tk(o["revenue"], "bn"), _tk(o["profit"], "bn"))
    en = "%s: %d sales, %s in total; profit %s" % (_PERIOD_EN[per], o["sales_count"],
                                                   _tk(o["revenue"], "en"), _tk(o["profit"], "en"))
    if o["expenses"]:
        bn += "; খরচ %s বাদে নিট %s" % (_tk(o["expenses"], "bn"), _tk(o["net"], "bn"))
        en += "; after %s expenses, net %s" % (_tk(o["expenses"], "en"), _tk(o["net"], "en"))
    if o["profit_change_pct"] is not None:
        bn += " (%s লাভ ছিল %s — %s)" % (_PREV_BN[per], _tk(o["prev_profit"], "bn"),
                                       _change(o["profit_change_pct"], "bn"))
        en += " (%s profit was %s — %s)" % (_PREV_EN[per], _tk(o["prev_profit"], "en"),
                                           _change(o["profit_change_pct"], "en"))
    bn += "।"
    en += "."
    if o["missing_cost"]:
        bn += " %sটি বিক্রিতে পণ্যের কেনা-দাম দেওয়া নেই, তাই লাভ কম দেখাতে পারে।" % _cnt(o["missing_cost"], "bn")
        en += " %d sale(s) have products without a cost price, so profit may show low." % o["missing_cost"]
    return _pick(lang, bn, en)


# ------------------------------------------------------------------ stock.running_out
def _velocity(ctx):
    """{product_id: units sold per day} over the last VELOCITY_DAYS."""
    from ..models import SaleLine
    since = ctx.now - timedelta(days=VELOCITY_DAYS)
    rows = (SaleLine.objects.filter(sale__user=ctx.user, sale__voided_at__isnull=True,
                                    sale__created_at__gte=since, product__isnull=False)
            .values("product_id").annotate(q=Sum("qty")))
    return {r["product_id"]: max(0, r["q"] or 0) / float(VELOCITY_DAYS) for r in rows}


def running_out_items(ctx):
    from ..models import Product
    vel = _velocity(ctx)
    items = []
    for p in Product.objects.filter(user=ctx.user).only("id", "name", "stock", "low_stock_at"):
        v = vel.get(p.id, 0.0)
        days = None if v <= 0 else int(math.floor(max(0, p.stock) / v))
        low = p.stock <= p.low_stock_at
        if not (low or (days is not None and days <= RUNOUT_DAYS)):
            continue
        if v > 0:
            need = int(math.ceil(v * COVER_DAYS)) - max(0, p.stock)
        else:
            need = max(1, p.low_stock_at) * 2 - max(0, p.stock)
        items.append({"name": p.name, "stock": p.stock, "low_at": p.low_stock_at,
                      "per_day": round(v, 1), "days_left": days,
                      "suggest_qty": max(1, need)})
    items.sort(key=lambda i: (i["stock"] > 0,
                              i["days_left"] if i["days_left"] is not None else 10 ** 6,
                              i["stock"], i["name"]))
    return items


def running_out(ctx, a):
    items = running_out_items(ctx)
    lim = int(a.get("limit") or 10)
    return {"count": len(items), "out_now": sum(1 for i in items if i["stock"] <= 0),
            "window_days": VELOCITY_DAYS, "items": items[:lim]}


def _days_txt(i, lang):
    if i["stock"] <= 0:
        return _pick(lang, "শেষ", "out")
    if i["days_left"] is None:
        return _pick(lang, "স্টক %s" % _cnt(i["stock"], lang), "%d left" % i["stock"])
    return _pick(lang, "স্টক %s, ~%s দিন চলবে" % (_cnt(i["stock"], lang), _cnt(i["days_left"], lang)),
                 "%d left, ~%d day(s)" % (i["stock"], i["days_left"]))


def running_out_sum(o, lang):
    if not o["count"]:
        return _pick(lang, "কোনো পণ্য শেষ হওয়ার পথে নেই (গত %s দিনের বিক্রি ধরে)।" % _cnt(o["window_days"], lang),
                     "No product is running out (based on the last %d days of sales)." % o["window_days"])
    names = ", ".join("%s (%s)" % (i["name"], _days_txt(i, lang)) for i in o["items"][:5])
    return _pick(lang, "%sটি পণ্য শেষ হচ্ছে: %s।" % (_cnt(o["count"], lang), names),
                 "%d product(s) are running out: %s." % (o["count"], names))


# ------------------------------------------------------------------ biz.cash_check
def cash_check(ctx, a):
    biz = _biz(ctx)
    which = a.get("day") or "yesterday"
    if which not in ("today", "yesterday"):
        raise ToolError("bad_day")
    d = _day0(ctx).date() - timedelta(days=1 if which == "yesterday" else 0)
    out = {"day": d.isoformat(), "which": which, "has_business": biz is not None,
           "closed": False, "expected": 0.0, "counted": None, "variance": 0.0, "state": "open"}
    if biz is None:
        return out
    from .. import business_views as BV
    v = BV._cashbox_payload(None, biz, d.isoformat(), ctx.lang)
    out["expected"] = _tk100(v["expected_poisha"])
    if v.get("reconciled"):
        out.update(closed=True, counted=_tk100(v["counted_poisha"]),
                   variance=_tk100(v["variance_poisha"]), state=v["variance_state"])
    return out


def cash_check_sum(o, lang):
    when = _pick(lang, "গতকাল" if o["which"] == "yesterday" else "আজ",
                 "Yesterday" if o["which"] == "yesterday" else "Today")
    if not o["has_business"]:
        return _pick(lang, "আপনার কোনো ব্যবসার খাতা নেই।", "You have no business ledger yet.")
    if not o["closed"]:
        return _pick(lang, "%s ক্যাশ গোনা (দিন বন্ধ) হয়নি — হিসাব অনুযায়ী বাক্সে থাকার কথা %s।" % (
            when, _tk(o["expected"], lang)),
            "%s the cash was not counted (day not closed) — the books say %s should be in the box." % (
            when, _tk(o["expected"], lang)))
    if o["state"] == "balanced":
        return _pick(lang, "%s ক্যাশ মিলে গেছে: %s।" % (when, _tk(o["counted"], lang)),
                     "%s the cash matched: %s." % (when, _tk(o["counted"], lang)))
    diff = _tk(abs(o["variance"]), lang)
    if o["state"] == "shortage":
        return _pick(lang, "%s ক্যাশ %s কম: হিসাবে %s, গোনা %s।" % (when, diff, _tk(o["expected"], lang),
                                                                  _tk(o["counted"], lang)),
                     "%s the cash was %s short: books %s, counted %s." % (when, diff, _tk(o["expected"], lang),
                                                                         _tk(o["counted"], lang)))
    return _pick(lang, "%s ক্যাশ %s বেশি: হিসাবে %s, গোনা %s (কোনো বিক্রি লেখা বাকি?)।" % (
        when, diff, _tk(o["expected"], lang), _tk(o["counted"], lang)),
        "%s the cash was %s over: books %s, counted %s (a sale not recorded?)." % (
        when, diff, _tk(o["expected"], lang), _tk(o["counted"], lang)))


# ------------------------------------------------------------------ dues today
def dues_today(ctx, limit=3):
    """Customers to remind today: a tagada schedule due by tonight first, then
    the biggest dues. Exact names (the one-tap tagada uses them)."""
    from ..models import KhataEntry, TagadaSchedule
    biz = _biz(ctx)
    if biz is None:
        return {"count": 0, "total": 0.0, "items": []}
    rows = (KhataEntry.objects.filter(party__business=biz, party__book="customer",
                                      party__archived=False)
            .values("party_id", "party__name")
            .annotate(gave=Sum("amount_poisha", filter=Q(direction="gave")),
                      got=Sum("amount_poisha", filter=Q(direction="got"))))
    due = {}
    for r in rows:
        bal = (r["gave"] or 0) - (r["got"] or 0)
        if bal > 0:
            due[r["party_id"]] = (r["party__name"], bal)
    tonight = _day0(ctx) + timedelta(days=1)
    sched = set(TagadaSchedule.objects.filter(party_id__in=list(due), enabled=True,
                                              next_at__lt=tonight).values_list("party_id", flat=True))
    from collections import Counter
    names = Counter(n.strip().lower() for n, _ in due.values())
    items = [{"name": n, "due": _tk100(b), "scheduled": pid in sched,
              "unique": names[n.strip().lower()] == 1}
             for pid, (n, b) in due.items()]
    items.sort(key=lambda i: (not i["scheduled"], -i["due"], i["name"]))
    return {"count": len(items), "total": round(sum(i["due"] for i in items), 2),
            "items": items[:limit]}


# ------------------------------------------------------------------ CRM follow-ups
def _visible_leads(ctx):
    from crm.models import CrmMember, Lead
    orgs = list(CrmMember.objects.filter(user=ctx.user).values_list("org_id", flat=True))
    if not orgs:
        return None
    qs = Lead.objects.filter(org_id__in=orgs)
    mine = CrmMember.objects.filter(user=ctx.user, org_id__in=orgs, role="sales")
    if mine.exists() and not CrmMember.objects.filter(
            user=ctx.user, org_id__in=orgs, role__in=("owner", "manager")).exists():
        qs = qs.filter(assigned_to__in=mine)
    return qs


def followups_due(ctx, limit=3):
    qs = _visible_leads(ctx) if _flag(ctx, "crm") else None
    if qs is None:
        return {"has_crm": False, "count": 0, "items": []}
    today = _day0(ctx).date()
    due = qs.filter(next_follow_up__lte=today).exclude(status__in=("won", "lost")) \
        .order_by("next_follow_up", "-score")
    return {"has_crm": True, "count": due.count(),
            "items": [{"name": l.name or l.company or "", "overdue_days": (today - l.next_follow_up).days,
                       "status": l.status} for l in due[:limit]]}


# ------------------------------------------------------------------ biz.daily_brief
def daily_brief(ctx, a):
    biz = _biz(ctx)
    y = profit(ctx, {"period": "yesterday"})
    t = profit(ctx, {"period": "today"})
    dues = dues_today(ctx)
    stock = running_out(ctx, {"limit": 5})
    fu = followups_due(ctx)
    cash = cash_check(ctx, {"day": "yesterday"})
    from ..models import Order
    unpaid = (Order.objects.filter(user=ctx.user)
              .exclude(status__in=("cancelled", "returned", "delivered"))
              .exclude(payment_status="verified").count())
    actions = []
    for i in dues["items"]:
        if i["unique"]:
            actions.append({"kind": "tagada", "tool": "khata.tagada", "target": i["name"],
                            "args": {"customer": i["name"], "channel": "whatsapp"}, "approval": True})
    if stock["items"]:
        actions.append({"kind": "reorder", "tool": "supplier.reorder", "target": "",
                        "args": {"items": [{"product": i["name"], "qty": i["suggest_qty"]}
                                           for i in stock["items"][:5]]}, "approval": True})
    for i in fu["items"]:
        if i["name"]:
            actions.append({"kind": "followup", "tool": "crm.followup_task", "target": i["name"],
                            "args": {"lead": i["name"], "when": "today"}, "approval": False})
    return {"date": _day0(ctx).date().isoformat(), "has_business": biz is not None,
            "shop": (biz.shop_name if biz else "") or "",
            "yesterday": y, "today": t, "dues": dues, "stock": stock, "followups": fu,
            "cash": cash, "unpaid_orders": unpaid, "actions": actions[:8],
            "empty": not (y["sales_count"] or t["sales_count"] or dues["count"] or stock["count"]
                          or fu["count"] or cash["closed"] or unpaid)}


def brief_lines(o, lang):
    """[(key, line)] — every number from the shop's rows (templates)."""
    out = []
    if o["yesterday"]["sales_count"] or o["yesterday"]["prev_profit"]:
        out.append(("sales", profit_sum(o["yesterday"], lang)))
    if o["dues"]["count"]:
        names = ", ".join("%s %s%s" % (i["name"], _tk(i["due"], lang),
                                       _pick(lang, " (আজ তাগাদার দিন)", " (reminder due today)")
                                       if i["scheduled"] else "") for i in o["dues"]["items"])
        out.append(("dues", _pick(lang, "%sজনের কাছে মোট %s বাকি — আজ তাগাদা দিন: %s।" % (
            _cnt(o["dues"]["count"], lang), _tk(o["dues"]["total"], lang), names),
            "%d customer(s) owe %s — remind today: %s." % (o["dues"]["count"], _tk(o["dues"]["total"], lang),
                                                          names))))
    if o["stock"]["count"]:
        out.append(("stock", running_out_sum(o["stock"], lang)))
    if o["followups"]["count"]:
        names = ", ".join(i["name"] for i in o["followups"]["items"] if i["name"])
        out.append(("followups", _pick(lang, "আজ %sটি CRM ফলো-আপ: %s।" % (_cnt(o["followups"]["count"], lang), names),
                                       "%d CRM follow-up(s) due today: %s." % (o["followups"]["count"], names))))
    if o["has_business"]:
        out.append(("cash", cash_check_sum(o["cash"], lang)))
    if o["unpaid_orders"]:
        out.append(("orders", _pick(lang, "%sটি অর্ডারের টাকা এখনো আসেনি।" % _cnt(o["unpaid_orders"], lang),
                                    "%d order(s) are still unpaid." % o["unpaid_orders"])))
    return out


def daily_brief_sum(o, lang):
    if not o["has_business"]:
        return _pick(lang, "আপনার কোনো ব্যবসার খাতা নেই।", "You have no business ledger yet.")
    lines = [ln for _, ln in brief_lines(o, lang)]
    if not lines:
        return _pick(lang, "আজকের ব্যবসায় দেখার মতো কিছু নেই।", "Nothing to act on in the shop today.")
    return "\n".join(lines)


# ------------------------------------------------------------------ supplier.reorder
def _supplier(ctx, name):
    from ..models import KhataParty
    biz = _biz(ctx)
    if biz is None:
        raise ToolError("no_business")
    want = (name or "").strip()
    if not want:
        raise ToolError("supplier_required")
    rows = list(KhataParty.objects.filter(business=biz, book="supplier", archived=False,
                                          name__iexact=want)[:2])
    if not rows:
        raise ToolError("supplier_not_found")
    if len(rows) > 1:
        raise ToolError("ambiguous_supplier")
    return biz, rows[0]


def _reorder_items(ctx, a):
    from ..models import Product
    items = a.get("items") or []
    if not items:
        items = [{"product": i["name"], "qty": i["suggest_qty"]} for i in running_out_items(ctx)[:10]]
    if not items:
        raise ToolError("nothing_to_reorder")
    out = []
    for it in items:
        rows = list(Product.objects.filter(user=ctx.user, name__iexact=(it.get("product") or "").strip())
                    .values_list("name", flat=True)[:2])
        if not rows:
            raise ToolError("product_not_found")
        if len(rows) > 1:
            raise ToolError("ambiguous_product")
        out.append({"product": rows[0], "qty": int(it.get("qty") or 1)})
    return out


def reorder_text(shop, supplier, items, lang):
    rows = "\n".join("• %s — %s" % (i["product"], _cnt(i["qty"], lang) if lang == "bn" else i["qty"])
                     for i in items)
    if lang == "bn":
        return "আসসালামু আলাইকুম %s ভাই,\n%sএর জন্য এই মালগুলো পাঠাবেন:\n%s\nদাম ও কবে দিতে পারবেন জানাবেন। ধন্যবাদ।" % (
            supplier, (shop + "-") if shop else "দোকান", rows)
    return "Hello %s,\nPlease send these for %s:\n%s\nPlease confirm the price and delivery date. Thank you." % (
        supplier, shop or "our shop", rows)


def reorder(ctx, a):
    """Runs ONLY after the owner approved the card (risk external). Prepares
    the message for the owner's own WhatsApp — nothing is sent by us."""
    from ..logic import business_khata as K
    from ..models import AuditLog
    _need_flag(ctx, "business")
    biz, sup = _supplier(ctx, a.get("supplier"))
    items = _reorder_items(ctx, a)
    text = reorder_text(biz.shop_name or "", sup.name, items, ctx.lang)
    share = K.share_descriptor("whatsapp_share", sup.phone or "", text)
    if ctx.idem_key and not AuditLog.objects.filter(user=ctx.user, action="agent.reorder_draft",
                                                    detail__idem=ctx.idem_key).exists():
        AuditLog.objects.create(user=ctx.user, action="agent.reorder_draft",
                                detail={"idem": ctx.idem_key, "supplier_id": sup.id,
                                        "items": items})
    return {"supplier": sup.name, "count": len(items), "items": items, "prepared": True,
            "sent": False, "share_text": share["text"], "share_to": share["to"]}


def reorder_sum(o, lang):
    return _pick(lang, "%s-এর জন্য %sটি পণ্যের অর্ডার তৈরি — WhatsApp খুলে আপনি নিজে পাঠান।" % (
        o["supplier"], _cnt(o["count"], lang)),
        "Reorder of %d product(s) for %s is ready — open WhatsApp and send it yourself." % (
        o["count"], o["supplier"]))


def reorder_title(ctx, a, lang):
    try:
        items = _reorder_items(ctx, a)
    except ToolError:
        items = a.get("items") or []
    names = ", ".join("%s %s" % (i["product"], _cnt(i["qty"], lang)) for i in items[:4])
    return _pick(lang, "%s-কে অর্ডার পাঠানোর খসড়া বানাবেন? (%s)" % (a.get("supplier") or "", names),
                 "Prepare a reorder for %s? (%s)" % (a.get("supplier") or "", names))


def reorder_pre(ctx, a):
    _supplier(ctx, a.get("supplier"))
    _reorder_items(ctx, a)


def suppliers(ctx):
    """Own supplier book names (the card's one-tap picker)."""
    from ..models import KhataParty
    biz = _biz(ctx)
    if biz is None:
        return []
    return list(KhataParty.objects.filter(business=biz, book="supplier", archived=False)
                .order_by("name").values_list("name", flat=True)[:30])


# ------------------------------------------------------------------ crm.followup_task
def _when(ctx, w):
    d0 = _day0(ctx)
    if w in (None, "", "today"):
        now = timezone.localtime(ctx.now)
        due = min(now + timedelta(hours=1), d0 + timedelta(hours=21))
        if due <= now:
            due = now + timedelta(minutes=5)
    elif w == "tomorrow":
        due = d0 + timedelta(days=1, hours=10)
    else:
        try:
            d = date.fromisoformat(w)
        except ValueError:
            raise ToolError("bad_when")
        if d < d0.date():
            raise ToolError("due_in_past")
        due = timezone.make_aware(datetime.combine(d, time(10)), timezone.get_current_timezone())
    return due


def followup_task(ctx, a):
    from crm.models import Activity
    from ..models import Reminder
    _need_flag(ctx, "crm")
    link = {"type": "agent_step", "id": ctx.idem_key}
    if ctx.idem_key:
        old = Reminder.objects.filter(user=ctx.user, link=link).first()
        if old is not None:
            return {"lead": a.get("lead") or "", "due": old.due_at.date().isoformat(),
                    "created": False, "reminder_id": old.id}
    qs = _visible_leads(ctx)
    if qs is None:
        raise ToolError("no_crm")
    want = (a.get("lead") or "").strip()
    rows = list(qs.filter(Q(name__iexact=want) | Q(name="", company__iexact=want))[:2])
    if not rows:
        raise ToolError("lead_not_found")
    if len(rows) > 1:
        raise ToolError("ambiguous_lead")
    lead = rows[0]
    due = _when(ctx, a.get("when"))
    note = (a.get("note") or "").strip()[:200]
    who = lead.name or lead.company
    subject = ("ফলো-আপ: %s" % who) if ctx.lang == "bn" else ("Follow up: %s" % who)
    Activity.objects.create(org=lead.org, kind="task", subject=subject[:240], body=note,
                            lead=lead, due_at=due)
    lead.next_follow_up = timezone.localtime(due).date()
    lead.save(update_fields=["next_follow_up", "updated_at"])
    r = Reminder.objects.create(user=ctx.user, title=subject[:200], notes=note, due_at=due,
                                source="ai", link=link)
    return {"lead": who, "due": timezone.localtime(due).date().isoformat(), "created": True,
            "reminder_id": r.id}


def followup_task_sum(o, lang):
    d = o["due"][8:10] + "/" + o["due"][5:7]
    return _pick(lang, "%s-এর ফলো-আপ টাস্ক তৈরি — %s, ফোনে রিমাইন্ডারও থাকবে।" % (o["lead"], _cnt(d, lang)),
                 "Follow-up task for %s created — %s, with a phone reminder." % (o["lead"], d))


# ------------------------------------------------------------------ registry
_LIMIT = {"type": "integer", "minimum": 1, "maximum": 20}
_ITEMS = {"type": "array", "maxItems": 15,
          "items": obj({"product": {"type": "string", "minLength": 1, "maxLength": 160},
                        "qty": {"type": "integer", "minimum": 1, "maximum": 10000}},
                       ("product", "qty"))}
_PROFIT_OUT = obj({"period": _STR, "sales_count": _INT, "revenue": _NUM, "profit": _NUM,
                   "expenses": _NUM, "net": _NUM, "due_sales": _NUM, "prev_revenue": _NUM,
                   "prev_profit": _NUM, "profit_change_pct": {"type": ["integer", "null"]},
                   "revenue_change_pct": {"type": ["integer", "null"]}, "missing_cost": _INT},
                  ("period", "sales_count", "revenue", "profit", "expenses", "net",
                   "prev_profit", "profit_change_pct", "missing_cost"))

TOOLS = (
    Tool("biz.profit", 1, "বিক্রি ও লাভ", "Sales & profit",
         "The shop's POS sales, profit, expenses and net for today / yesterday / last 7 days / "
         "this month, compared with the same span a week (or month) earlier.", "read",
         obj({"period": {"type": "string", "enum": list(PERIODS)}}),
         _PROFIT_OUT, profit, profit_sum, rate_per_hour=60, feature="business",
         topics=("business",)),
    Tool("stock.running_out", 1, "শেষ হচ্ছে এমন পণ্য", "Running out",
         "Catalog products that are out, at their low level, or will run out within 7 days at "
         "the last 14 days' sales speed; with a suggested reorder quantity.", "read",
         obj({"limit": _LIMIT}),
         obj({"count": _INT, "out_now": _INT, "window_days": _INT,
              "items": _list_out({"name": _STR, "stock": _INT, "suggest_qty": _INT})},
             ("count", "out_now", "window_days", "items")),
         running_out, running_out_sum, rate_per_hour=60, feature="business",
         topics=("business",)),
    Tool("biz.cash_check", 1, "ক্যাশ বনাম হিসাব", "Cash vs books",
         "A day's cash box (yesterday by default): what the books say should be there vs what "
         "was counted at close.", "read",
         obj({"day": {"type": "string", "enum": ["today", "yesterday"]}}),
         obj({"day": _STR, "which": _STR, "has_business": _BOOL, "closed": _BOOL, "expected": _NUM,
              "counted": {"type": ["number", "null"]}, "variance": _NUM, "state": _STR},
             ("day", "has_business", "closed", "expected", "counted", "variance", "state")),
         cash_check, cash_check_sum, rate_per_hour=60, feature="business",
         topics=("business",)),
    Tool("biz.daily_brief", 1, "আজকের ব্যবসা", "Today's business",
         "The shop owner's morning brief: yesterday's sales/profit vs last week, dues to collect "
         "today, products running out, CRM follow-ups due, cash vs books, unpaid orders.",
         "read", obj({}),
         obj({"date": _STR, "has_business": _BOOL, "yesterday": {"type": "object"},
              "dues": {"type": "object"}, "stock": {"type": "object"},
              "followups": {"type": "object"}, "cash": {"type": "object"},
              "unpaid_orders": _INT, "actions": {"type": "array", "maxItems": 8}, "empty": _BOOL},
             ("date", "has_business", "yesterday", "dues", "stock", "followups", "cash",
              "unpaid_orders", "actions", "empty"), extra=True),
         daily_brief, daily_brief_sum, rate_per_hour=30, feature="business",
         topics=("business",)),
    Tool("supplier.reorder", 1, "সাপ্লায়ারকে অর্ডার", "Reorder from a supplier",
         "Prepare a reorder message to ONE supplier from the owner's supplier book (exact name) "
         "for catalog products (exact names; empty = the running-out list with suggested qty). "
         "The owner sends it himself on WhatsApp. Always needs the owner's approval.", "external",
         obj({"supplier": {"type": "string", "minLength": 1, "maxLength": 120}, "items": _ITEMS},
             ("supplier",)),
         obj({"supplier": _STR, "count": _INT, "items": {"type": "array", "maxItems": 15},
              "prepared": _BOOL, "sent": _BOOL, "share_text": _STR},
             ("supplier", "count", "items", "prepared", "sent", "share_text"), extra=True),
         reorder, reorder_sum, rate_per_hour=10, feature="business", topics=("business",),
         pii_out=("share_to",), approval_title=reorder_title, precheck=reorder_pre),
    Tool("crm.followup_task", 1, "ফলো-আপ টাস্ক", "Follow-up task",
         "Create a CRM follow-up task for ONE lead (exact name from crm.leads) today, tomorrow "
         "or on a date (YYYY-MM-DD); sets the lead's next follow-up and a phone reminder.",
         "write_low",
         obj({"lead": {"type": "string", "minLength": 1, "maxLength": 160},
              "when": {"type": "string", "maxLength": 10},
              "note": {"type": "string", "maxLength": 200}}, ("lead",)),
         obj({"lead": _STR, "due": _STR, "created": _BOOL, "reminder_id": _INT},
             ("lead", "due", "created")),
         followup_task, followup_task_sum, rate_per_hour=20, feature="crm",
         topics=("business",)),
)
