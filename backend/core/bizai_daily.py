"""bizai2 — the shop owner's DAILY summary (owner order 4 Nov 02:05 + full
power 9 Nov item 8). Every evening (21:00 Asia/Dhaka, inside the existing
`bizagent_daily` cron — no new cron line) every shop that had activity in
the last 7 days gets ONE plain-Bangla summary:

  * today's sales (count, total, cash / bKash / Nagad / due split) next to
    the same weekday last week;
  * khata: collected today, new credit given today, total still owed and the
    three customers to chase tomorrow (biggest due first, with days since
    their last payment);
  * STOCK-OUT FORECAST from real sales velocity (last 14 days, per variant):
    "Rice 5 kg — 4 left, about 2 days" — not just a fixed threshold;
  * measured outcomes of the week: dues paid within 7 days of a tagada,
    customers who came back after a win-back message (bizai_service.outcomes,
    the same numbers as the Business-home card);
  * one next step for tomorrow.

Deterministic — NO AI call, so no AI spend and no customer data leaves the
server. Real numbers only; a section with no data is left out, never guessed.
Storage: PaCollectionItem collection "bizai_daily" (no migration); the owner
also gets one push (shop_alert) + a notification-centre row. Off switch:
NotifSettings.enabled["shop_daily"] = False (or the whole "business" type).
"""
import logging
from collections import defaultdict
from datetime import timedelta

from django.db.models import Max, Min, Q, Sum
from django.utils import timezone

from .i18n import pick

log = logging.getLogger(__name__)

COL = "bizai_daily"
PREF_KEY = "shop_daily"
VELOCITY_DAYS = 14
FORECAST_DAYS = 3          # warn when stock lasts this many days or less
ACTIVE_DAYS = 7
MAX_CHASE = 3
MAX_STOCK = 5
BATCH = 2000
KEEP_DAYS = 60


# ===================================================================== helpers
def _bn(v):
    return str(v).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))


def _tk(poisha, lang):
    """৳ amount from poisha in the khata's own format (Bangla digits for bn)."""
    from .logic import business_khata as khata
    return khata.fmt_amount(int(poisha or 0))["en" if lang == "en" else "bn"]


def _n(v, lang):
    return _bn(v) if lang == "bn" else str(v)


def _day_bounds(now):
    from .logic import msg_guard as MG
    loc = MG.local(now)
    start = loc.replace(hour=0, minute=0, second=0, microsecond=0)
    return start, start + timedelta(days=1)


def _sales_q(business):
    # legacy single-shop rows carry business=NULL + user=owner
    return Q(business=business) | Q(business__isnull=True, user=business.user)


def sales_day(business, start, end):
    from .models import Sale
    qs = Sale.objects.filter(_sales_q(business), voided_at__isnull=True,
                             created_at__gte=start, created_at__lt=end)
    agg = qs.aggregate(total=Sum("total"), due=Sum("due"))
    split = defaultdict(int)
    for m, t in qs.values_list("payment_method", "total"):
        split[m or "cash"] += int(t or 0)
    return {"count": qs.count(), "total": int(agg["total"] or 0),
            "due": int(agg["due"] or 0), "split": dict(split)}


# ===================================================================== khata
def khata_day(business, start, end, now):
    """Collected / given today, total owed, and who to chase tomorrow."""
    from .models import KhataEntry, KhataParty
    parties = KhataParty.objects.filter(business=business, book="customer", archived=False)
    ents = KhataEntry.objects.filter(party__in=parties)
    today = ents.filter(at__gte=start, at__lt=end)
    got = int(today.filter(direction="got").aggregate(s=Sum("amount_poisha"))["s"] or 0)
    gave = int(today.filter(direction="gave").aggregate(s=Sum("amount_poisha"))["s"] or 0)
    bal = defaultdict(int)
    for pid, d, a in ents.values_list("party_id", "direction", "amount_poisha")[:200000]:
        bal[pid] += int(a) if d == "gave" else -int(a)
    owed = {pid: b for pid, b in bal.items() if b > 0}
    top = sorted(owed.items(), key=lambda kv: -kv[1])[:MAX_CHASE]
    names = dict(parties.filter(pk__in=[p for p, _ in top]).values_list("pk", "name"))
    last_paid = dict(ents.filter(party_id__in=[p for p, _ in top], direction="got")
                     .values("party_id").annotate(m=Max("at")).values_list("party_id", "m"))
    first_due = dict(ents.filter(party_id__in=[p for p, _ in top], direction="gave")
                     .values("party_id").annotate(m=Min("at")).values_list("party_id", "m"))
    chase = []
    for pid, b in top:
        ref = last_paid.get(pid) or first_due.get(pid)
        days = max(0, (now - ref).days) if ref else None
        chase.append({"party_id": pid, "name": names.get(pid, ""), "due": b,
                      "days": days, "paid_before": pid in last_paid})
    return {"got": got, "gave": gave, "owed_total": sum(owed.values()),
            "owed_count": len(owed), "chase": chase}


# ===================================================================== stock
def stock_forecast(business, now, days=VELOCITY_DAYS, warn=FORECAST_DAYS):
    """Variants that will run out soon, from REAL sales speed: units sold in
    the last `days` days / days = per-day speed; days_left = stock / speed.
    Only variants that actually sold (no speed → no forecast, never a
    guess). Out-of-stock items that sold recently come first."""
    from .models import ProductVariant, SaleLine
    since = now - timedelta(days=days)
    sold = dict(SaleLine.objects.filter(
        Q(sale__business=business) | Q(sale__business__isnull=True, sale__user=business.user),
        sale__voided_at__isnull=True, sale__created_at__gte=since, variant__isnull=False)
        .values("variant_id").annotate(q=Sum("qty")).values_list("variant_id", "q"))
    if not sold:
        return []
    out = []
    for v in ProductVariant.objects.filter(pk__in=list(sold), product__user=business.user) \
            .select_related("product"):
        q = int(sold.get(v.pk) or 0)
        if q <= 0:
            continue
        per_day = q / float(days)
        left = max(0, int(v.stock))
        days_left = left / per_day if per_day else None
        if left > 0 and (days_left is None or days_left > warn):
            continue
        name = v.product.name
        extra = " ".join(x for x in (v.size, v.colour) if x)
        out.append({"variant_id": v.pk, "name": (name + (" " + extra if extra else ""))[:80],
                    "stock": left, "sold": q, "per_day": round(per_day, 2),
                    "days_left": 0 if left == 0 else max(1, int(days_left + 0.5)),
                    # enough for one week at today's speed
                    "reorder": max(1, int(per_day * 7 + 0.999) - left)})
    out.sort(key=lambda x: (x["days_left"], -x["per_day"]))
    return out[:MAX_STOCK]


# ===================================================================== summary
def _pct(a, b):
    if not b:
        return None
    return int(round((a - b) * 100.0 / b))


def summary(business, lang="bn", now=None):
    """The day in plain words. -> {title, day, lines[], chase[], stock[],
    outcomes[], next, empty}. Numbers only from the shop's own records."""
    now = now or timezone.now()
    L = (lambda bn, en: en if lang == "en" else bn)
    start, end = _day_bounds(now)
    s = sales_day(business, start, end)
    w = sales_day(business, start - timedelta(days=7), end - timedelta(days=7))
    k = khata_day(business, start, end, now)
    stock = stock_forecast(business, now)
    lines = []
    if s["count"]:
        lines.append(L("আজ বিক্রি: %sটি, মোট %s।" % (_n(s["count"], "bn"), _tk(s["total"], "bn")),
                       "Sales today: %s, total %s." % (s["count"], _tk(s["total"], "en"))))
        parts = []
        for key, bn_, en_ in (("cash", "নগদ", "cash"), ("bkash", "বিকাশ", "bKash"),
                              ("nagad", "নগদ (Nagad)", "Nagad"), ("due", "বাকিতে", "on credit")):
            if s["split"].get(key):
                parts.append(L("%s %s" % (bn_, _tk(s["split"][key], "bn")),
                               "%s %s" % (en_, _tk(s["split"][key], "en"))))
        if len(parts) > 1:
            lines.append(L("ভাগ: ", "Split: ") + ", ".join(parts) + L("।", "."))
        pc = _pct(s["total"], w["total"])
        if pc is not None:
            if pc >= 0:
                lines.append(L("গত সপ্তাহের এই দিনের চেয়ে %s%% বেশি।" % _n(pc, "bn"),
                               "%s%% more than the same day last week." % pc))
            else:
                lines.append(L("গত সপ্তাহের এই দিনের চেয়ে %s%% কম।" % _n(-pc, "bn"),
                               "%s%% less than the same day last week." % -pc))
    else:
        lines.append(L("আজ অ্যাপে কোনো বিক্রি লেখা হয়নি।", "No sales were recorded in the app today."))
    if k["got"]:
        lines.append(L("আজ খাতায় বাকি আদায়: %s।" % _tk(k["got"], "bn"),
                       "Dues collected today: %s." % _tk(k["got"], "en")))
    if k["gave"]:
        lines.append(L("আজ নতুন বাকি দিয়েছেন: %s।" % _tk(k["gave"], "bn"),
                       "New credit given today: %s." % _tk(k["gave"], "en")))
    if k["owed_total"]:
        lines.append(L("মোট পাওনা: %s (%s জনের কাছে)।" % (_tk(k["owed_total"], "bn"),
                                                       _n(k["owed_count"], "bn")),
                       "Total owed to you: %s (%s customers)." % (_tk(k["owed_total"], "en"),
                                                                 k["owed_count"])))
    chase = []
    for c in k["chase"]:
        if c["days"] is None:
            when = ""
        elif c["paid_before"] and c["days"] == 0:
            when = L(" · আজ কিছু জমা দিয়েছেন", " · paid something today")
        elif c["paid_before"]:
            when = L(" · শেষ জমা %s দিন আগে" % _n(c["days"], "bn"),
                     " · last paid %s days ago" % c["days"])
        else:
            when = L(" · %s দিন ধরে বাকি" % _n(c["days"], "bn"),
                     " · owing for %s days" % c["days"])
        chase.append({"party_id": c["party_id"], "name": c["name"], "due_poisha": c["due"],
                      "line": "%s — %s%s" % (c["name"], _tk(c["due"], lang), when)})
    stock_rows = []
    for x in stock:
        if x["stock"] == 0:
            t = L("%s — শেষ হয়ে গেছে (দিনে ~%s বিক্রি হয়)" % (x["name"], _n(x["per_day"], "bn")),
                  "%s — out of stock (sells ~%s a day)" % (x["name"], x["per_day"]))
        else:
            t = L("%s — %sটি আছে, প্রায় %s দিনে শেষ হবে" % (x["name"], _n(x["stock"], "bn"),
                                                       _n(x["days_left"], "bn")),
                  "%s — %s left, runs out in about %s days" % (x["name"], x["stock"],
                                                              x["days_left"]))
        t += L("; এক সপ্তাহের জন্য আরও %sটি আনুন।" % _n(x["reorder"], "bn"),
               "; get %s more for a week." % x["reorder"])
        stock_rows.append({**x, "line": t})
    outcomes = []
    try:
        from . import bizai_service as BA
        rows = {r["key"]: r for r in BA.outcomes(business, days=7, now=now)["rows"]}
        d, b = rows["dues_collected"], rows["customers_back"]
        if d["count"]:
            outcomes.append(L("এই সপ্তাহে তাগাদার পরে আদায়: ৳%s (%sটি জমা)।"
                              % (_bn(_money(d["bdt"])), _n(d["count"], "bn")),
                              "Collected after reminders this week: ৳%s (%s payments)."
                              % (_money(d["bdt"]), d["count"])))
        if b["count"]:
            outcomes.append(L("ফিরিয়ে-আনার মেসেজের পরে ফিরেছেন %s জন — ৳%s।"
                              % (_n(b["count"], "bn"), _bn(_money(b["bdt"]))),
                              "%s customers came back after a win-back message — ৳%s."
                              % (b["count"], _money(b["bdt"]))))
    except Exception:  # noqa: BLE001 — the summary never fails over the card
        log.exception("bizai_daily outcomes")
    if stock_rows:
        nxt = L("কাল সকালে আগে %s আনার ব্যবস্থা করুন — বিক্রি থামবে না।" % stock[0]["name"],
                "Tomorrow morning, restock %s first so sales do not stop." % stock[0]["name"])
    elif chase:
        nxt = L("কাল %s-কে তাগাদা দিন — মেসেজে বাকি-দেখার আর পরিশোধের লিংক নিজে থেকেই থাকে।"
                % chase[0]["name"],
                "Tomorrow, remind %s — the message carries their due link and how to pay."
                % chase[0]["name"])
    elif not s["count"]:
        nxt = L("কাল প্রতিটি বিক্রি অ্যাপে লিখুন — তাহলে সন্ধ্যায় পুরো হিসাব এখানে পাবেন।",
                "Tomorrow, ring up every sale in the app — then the full picture comes here each evening.")
    else:
        nxt = L("আজ সব ঠিক আছে। কাল আবার এই সময়ে হিসাব আসবে।",
                "All good today. The next summary comes tomorrow at this time.")
    return {"title": L("আজকের দোকানের হিসাব", "Today's shop summary"),
            "day": start.date().isoformat(), "lines": lines, "chase": chase,
            "stock": stock_rows, "outcomes": outcomes, "next": nxt,
            "empty": not (s["count"] or k["got"] or k["gave"] or k["owed_total"] or stock_rows)}


def _money(v):
    from .logic.bizagent import _fmt_money
    return _fmt_money(v)


# ===================================================================== prefs
def enabled_for(user):
    from .logic.notif_centre import type_enabled
    from .models import NotifSettings
    row = NotifSettings.objects.filter(user=user).first()
    en = (row.enabled if row else None) or {}
    return type_enabled(PREF_KEY, en) and type_enabled("business", en)


def set_enabled(user, on):
    from .models import NotifSettings
    row, _ = NotifSettings.objects.get_or_create(user=user)
    en = dict(row.enabled or {})
    en[PREF_KEY] = bool(on)
    row.enabled = en
    row.save(update_fields=["enabled", "updated_at"])
    return bool(on)


def latest(business):
    from .models import PaCollectionItem
    return (PaCollectionItem.objects.filter(user=business.user, collection=COL,
                                            data__business_id=business.pk)
            .order_by("-id").first())


# ===================================================================== cron
def _active_businesses(now):
    from .models import BusinessProfile, KhataEntry, Sale
    since = now - timedelta(days=ACTIVE_DAYS)
    ids = set(Sale.objects.filter(created_at__gte=since, business__isnull=False)
              .values_list("business_id", flat=True).distinct()[:BATCH])
    ids |= set(KhataEntry.objects.filter(created_at__gte=since)
               .values_list("party__business_id", flat=True).distinct()[:BATCH])
    return BusinessProfile.objects.filter(pk__in=ids).select_related("user")


def run_daily(now=None):
    """Cron (21:00 Dhaka, bizagent_daily): one summary per active shop per
    Dhaka day — saved + one push + one notification row. Idempotent per
    (business, day); an owner who switched it off gets nothing."""
    from . import push
    from .models import NotifEvent, PaCollectionItem
    now = now or timezone.now()
    n = 0
    for b in _active_businesses(now):
        try:
            owner = b.user
            if owner is None or not owner.is_active or not enabled_for(owner):
                continue
            bn = summary(b, "bn", now)
            if bn["empty"]:
                continue
            day = bn["day"]
            if PaCollectionItem.objects.filter(user=owner, collection=COL,
                                               data__business_id=b.pk, data__day=day).exists():
                continue
            en = summary(b, "en", now)
            PaCollectionItem.objects.create(user=owner, collection=COL,
                                            data={"business_id": b.pk, "day": day,
                                                  "bn": bn, "en": en})
            # keep ~2 months of history per shop, never an ever-growing pile
            PaCollectionItem.objects.filter(user=owner, collection=COL, data__business_id=b.pk,
                                            created_at__lt=now - timedelta(days=KEEP_DAYS)
                                            ).delete()
            body_bn = " ".join(bn["lines"][:2])
            body_en = " ".join(en["lines"][:2])
            NotifEvent.objects.create(user=owner, type="business", title_bn=bn["title"][:200],
                                      title_en=en["title"][:200], body_bn=body_bn,
                                      body_en=body_en, route="business/daily",
                                      meta={"source": COL, "business_id": b.pk, "day": day})
            push.safe_push(owner, "shop_alert", bn["title"], en["title"], body_bn, body_en,
                           data={"route": "business/daily", "business_id": b.pk})
            n += 1
        except Exception:  # noqa: BLE001 — one shop never stops the run
            log.exception("bizai_daily: business %s", b.pk)
    return n


def view_payload(business, user, lang="bn", now=None):
    """GET bizai/daily: today's summary live (so the owner can look any time),
    plus the on/off switch state."""
    d = summary(business, lang, now)
    d["enabled"] = enabled_for(user)
    d["switch_note"] = pick(lang, "প্রতিদিন রাত ৯টায় এই হিসাব একটি নোটিফিকেশনে আসে।",
                            "This summary comes as one notification every day at 9 pm.")
    return d
