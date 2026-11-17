"""bizai pillar 5 — Prochar (marketing engine) closes the loop:

  * ATTRIBUTION: every marketing post / offer gets a short tracked code
    (P + 4) and a shop-chat link (…/shop/<code>?p=<ref>). A customer who
    opens that link or types the code in ANY chat channel is marked on the
    chat; the order the AI sales agent then takes carries the code. So the
    owner sees "this post brought N orders worth ৳X" — real orders only.
  * LEARNS: the best-selling post is named and "post more like this" is
    suggested (same product / same kind); never a guessed number.
  * BEST TIME: the hours this shop's customers actually message (last 30
    days of inbound chats) — the time to post.
  * WEEKLY BANGLA REPORT: sales, AI orders, best post, best product,
    customers back, and next week's plan (upcoming festival + what to push +
    when to post). Saved + pushed once a week (cron bizai_weekly).
  * Lead follow-up + support autopilot = the AI sales agent itself: a post's
    link opens the shop chat, where the agent answers from the FAQ and the
    catalog and takes the order.
"""
import hashlib
import hmac
import logging
import re
from collections import Counter
from datetime import timedelta

from django.conf import settings
from django.db.models import Count, Sum
from django.utils import timezone

from .i18n import pick

log = logging.getLogger(__name__)

REF_RE = re.compile(r"(?<![A-Za-z0-9])[Pp]-?([A-Za-z0-9]{4})(?![A-Za-z0-9])")
_ALPHA = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
COL_WEEKLY = "bizai_weekly"


def post_ref(business, item_id):
    key = (settings.SECRET_KEY or "x").encode()
    h = hmac.new(key, ("bizai-post:%d:%s" % (business.pk, item_id)).encode(),
                 hashlib.sha256).digest()
    return "P" + "".join(_ALPHA[b % len(_ALPHA)] for b in h[:4])


def _plan_items(business):
    from . import mktengine_service as MS
    plan = MS.get_plan(business.user, business) or {}
    return [it for it in plan.get("items") or []
            if it.get("section") == "content" or it.get("kind") in ("post", "reel", "poster", "offer")]


def refs_for(business):
    """{ref: item} for the shop's marketing items (deterministic codes)."""
    return {post_ref(business, it.get("id", "")): it for it in _plan_items(business)}


def tracked(business, item_id, lang="bn"):
    from . import bizai_service as BA
    it = next((x for x in _plan_items(business) if x.get("id") == item_id), None)
    if it is None:
        return None
    ref = post_ref(business, item_id)
    link = "%s?p=%s" % (BA.share_url(business), ref)
    cta = pick(lang, "অর্ডার বা প্রশ্ন: %s (কোড %s)" % (link, ref),
               "Order or ask: %s (code %s)" % (link, ref))
    return {"ref": ref, "link": link, "item_id": item_id, "title": it.get("title", ""),
            "text": (it.get("body") or "").rstrip() + "\n\n" + cta}


def capture(thread, text="", ref=""):
    """Mark the chat with the first valid tracked code (link ?p= or typed)."""
    if thread is None or thread.business is None or thread.source_ref:
        return ""
    cands = [ref] if ref else []
    cands += ["P" + m.group(1) for m in REF_RE.finditer(text or "")]
    if not cands:
        return ""
    known = refs_for(thread.business)
    for c in cands:
        c = str(c or "").upper().replace("-", "")[:12]
        if c in known:
            type(thread).objects.filter(pk=thread.pk).update(source_ref=c)
            thread.source_ref = c
            return c
    return ""


def attribution(business, days=30, now=None):
    from .models import ChatThread, Order
    now = now or timezone.now()
    since = now - timedelta(days=days)
    known = refs_for(business)
    orders = {r["source_ref"]: r for r in Order.objects.filter(
        business=business, created_at__gte=since).exclude(source_ref="").exclude(
        status="cancelled").values("source_ref").annotate(n=Count("id"), v=Sum("total"))}
    chats = {r["source_ref"]: r["n"] for r in ChatThread.objects.filter(
        business=business, created_at__gte=since).exclude(source_ref="").values(
        "source_ref").annotate(n=Count("id"))}
    rows = []
    for ref in set(orders) | set(chats):
        it = known.get(ref) or {}
        o = orders.get(ref) or {}
        rows.append({"ref": ref, "item_id": it.get("id", ""), "title": it.get("title", ""),
                     "product": it.get("product", ""), "kind": it.get("kind", ""),
                     "chats": chats.get(ref, 0), "orders": o.get("n", 0),
                     "bdt": str(o.get("v") or 0)})
    rows.sort(key=lambda r: (-float(r["bdt"]), -r["orders"], -r["chats"]))
    best = rows[0] if rows and rows[0]["orders"] > 0 else None
    return {"days": days, "posts": rows, "best": best, "suggestion": suggest(best)}


def suggest(best):
    if not best:
        return None
    return {"product": best.get("product", ""), "kind": best.get("kind", ""),
            "ref": best["ref"]}


def best_hours(business, days=30, now=None, top=2):
    from .logic import msg_guard as MG
    from .models import Message
    now = now or timezone.now()
    c = Counter()
    for at in Message.objects.filter(thread__business=business, direction="in",
                                     created_at__gte=now - timedelta(days=days)) \
            .values_list("created_at", flat=True)[:5000]:
        c[MG.local(at).hour] += 1
    if sum(c.values()) < 5:
        return []                       # too few chats to say honestly
    return [h for h, _ in c.most_common(top)]


DEFAULT_POST_HOUR = 20     # 8 pm Dhaka when the shop has too few chats to say


def hour_label(h, lang):
    """20 -> "রাত ৮টা" / "8 pm" — never a bare 24-hour "20:00" for Bangla."""
    h = int(h) % 24
    if lang == "en":
        return "%s %s" % (12 if h % 12 == 0 else h % 12, "am" if h < 12 else "pm")
    part = ("রাত" if h < 4 or h >= 20 else "ভোর" if h < 6 else "সকাল" if h < 12
            else "দুপুর" if h < 15 else "বিকেল" if h < 18 else "সন্ধ্যা")
    return "%s %sটা" % (part, _bn(12 if h % 12 == 0 else h % 12))


def remind(business, user, item_id, lang="bn", now=None, hour=None):
    """gap-bizai — the honest Prochar scheduler (no Meta page-publish yet):
    a reminder at the shop's best posting hour carrying the post's tracked
    text, so the owner posts it in one tap at the right time. One pending
    reminder per post (asking again moves it). -> dict or None."""
    from .logic import msg_guard as MG
    from .models import Reminder
    d = tracked(business, item_id, lang)
    if d is None:
        return None
    now = now or timezone.now()
    hours = best_hours(business, now=now)
    basis = "customers" if hours else "default"
    h = int(hour) if hour is not None and 0 <= int(hour) <= 23 else \
        (hours[0] if hours else DEFAULT_POST_HOUR)
    loc = MG.local(now)
    at = loc.replace(hour=h, minute=0, second=0, microsecond=0)
    if at <= loc + timedelta(minutes=10):
        at += timedelta(days=1)
    title = (pick(lang, "পোস্ট দিন: %s", "Post now: %s") % (d["title"] or "Prochar"))[:200]
    link = {"type": "prochar", "id": str(item_id)[:64], "label": pick(lang, "প্রচার", "Prochar")}
    r = (Reminder.objects.filter(user=user, done=False, link__type="prochar",
                                 link__id=link["id"]).order_by("-id").first())
    if r is None:
        r = Reminder(user=user, source="manual", category="prochar")
    r.title, r.notes, r.due_at, r.link = title, d["text"][:4000], at, link
    r.save()
    when = pick(lang, "%s, %s" % ("আজ" if at.date() == loc.date() else "কাল", hour_label(h, "bn")),
                "%s, %s" % ("today" if at.date() == loc.date() else "tomorrow", hour_label(h, "en")))
    why = pick(lang, "আপনার গ্রাহকেরা এই সময়ে সবচেয়ে বেশি মেসেজ করেন।",
               "Your customers message you most at this time.") if basis == "customers" else \
        pick(lang, "এখনো যথেষ্ট চ্যাট নেই, তাই সন্ধ্যার পরের সময় — রিমাইন্ডারে বদলাতে পারবেন।",
             "Not enough chats yet to tell, so the evening — you can change it in Reminders.")
    return {"ok": True, "reminder_id": r.pk, "due_at": at.isoformat(), "hour": h,
            "basis": basis, "when": when, "why": why,
            "detail": pick(lang, "মনে করিয়ে দেব %s — লেখা আর লিংক রিমাইন্ডারে থাকবে।" % when,
                           "I'll remind you %s — the text and link are in the reminder." % when)}


def _bn(v):
    return str(v).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))


def _money(v):
    from .logic.bizagent import _fmt_money
    return _fmt_money(v)


def weekly_report(business, lang="bn", now=None):
    """The weekly Bangla business report — real numbers only."""
    from . import bizai_service as BA
    from . import retention_service as RS
    from .logic import mktengine as M
    from .logic import msg_guard as MG
    from .models import SaleLine
    now = now or timezone.now()
    since = now - timedelta(days=7)
    # bizai2: EVERY sale of the week (walk-in cash sales have no customer —
    # RS._sales() is the retention audience and left them out, so the
    # weekly "sales" line undercounted a typical shop)
    from .models import Sale
    sales = Sale.objects.filter(RS._cust_q(business), voided_at__isnull=True,
                                created_at__gte=since)
    n_sales = sales.count()
    v_sales = BA._taka(sales.aggregate(s=Sum("total"))["s"])
    top = SaleLine.objects.filter(sale__in=sales).values("product_name").annotate(
        q=Sum("qty")).order_by("-q").first()
    out = BA.outcomes(business, days=7, now=now)
    rows = {r["key"]: r for r in out["rows"]}
    att = attribution(business, days=7, now=now)
    hours = best_hours(business, now=now)
    start = MG.local(now).date()
    fest = [e for e in M.events_between(start, start + timedelta(days=14), lang)
            if not e.get("solemn")][:1]
    L = (lambda bn, en: en if lang == "en" else bn)
    D = (lambda v: str(v) if lang == "en" else _bn(v))
    lines = [L("এই সপ্তাহে বিক্রি: %sটি, মোট ৳%s।" % (D(n_sales), D(_money(v_sales))),
               "Sales this week: %s, total ৳%s." % (n_sales, _money(v_sales)))]
    ai = rows["ai_orders"]
    lines.append(L("AI নিজে %sটি অর্ডার নিয়েছে — ৳%s।" % (D(ai["count"]), D(_money(ai["bdt"]))),
                   "The AI took %s orders — ৳%s." % (ai["count"], _money(ai["bdt"]))))
    back = rows["customers_back"]
    lines.append(L("ফিরে এসেছেন %s জন গ্রাহক — ৳%s।" % (D(back["count"]), D(_money(back["bdt"]))),
                   "%s customers came back — ৳%s." % (back["count"], _money(back["bdt"]))))
    due = rows["dues_collected"]
    if due["count"]:
        lines.append(L("তাগাদার পরে আদায়: ৳%s।" % D(_money(due["bdt"])),
                       "Collected after reminders: ৳%s." % _money(due["bdt"])))
    if att["best"]:
        b = att["best"]
        lines.append(L("সেরা পোস্ট: %s — %sটি অর্ডার, ৳%s।" % (b["title"], D(b["orders"]), D(_money(b["bdt"]))),
                       "Best post: %s — %s orders, ৳%s." % (b["title"], b["orders"], _money(b["bdt"]))))
    if top:
        lines.append(L("সবচেয়ে বেশি বিক্রি: %s (%sটি)।" % (top["product_name"], D(top["q"])),
                       "Best seller: %s (%s sold)." % (top["product_name"], top["q"])))
    plan = []
    if fest:
        plan.append(L("সামনে %s (%s) — আগেভাগে পোস্ট দিন।" % (fest[0]["title"], D(fest[0]["date"])),
                      "Coming up: %s (%s) — post early." % (fest[0]["title"], fest[0]["date"])))
    if att["best"] and att["best"].get("product"):
        plan.append(L("যে পোস্ট বিক্রি করেছে তেমন আরেকটি দিন: %s।" % att["best"]["product"],
                      "Post another like the one that sold: %s." % att["best"]["product"]))
    elif top:
        plan.append(L("%s নিয়ে একটা পোস্ট দিন — এটাই বেশি চলছে।" % top["product_name"],
                      "Post about %s — it is selling most." % top["product_name"]))
    if hours:
        hs = ", ".join(hour_label(h, lang) for h in hours)   # gap-bizai: "রাত ৮টা", not "২০:০০"
        plan.append(L("পোস্টের সেরা সময় (আপনার গ্রাহকেরা তখন মেসেজ করেন): %s।" % hs,
                      "Best time to post (when your customers message): %s." % hs))
    if not plan:
        plan.append(L("আগামী সপ্তাহে একটা পোস্ট দিন আর তার কোডসহ লিংক শেয়ার করুন — কোন পোস্ট বিক্রি আনে তা এখানে দেখাবে।",
                      "Post once next week and share its tracked link — the post that sells will show here."))
    title = L("সাপ্তাহিক ব্যবসার রিপোর্ট", "Weekly business report")
    return {"title": title, "lines": lines, "plan": plan, "best_hours": hours,
            "best_post": att["best"], "week_end": now.isoformat()}


def run_weekly(now=None):
    """Cron: once per shop per ISO week — saved + one push. Idempotent."""
    from .models import PaCollectionItem, SellerAgent
    from . import bizagent_service as S
    now = now or timezone.now()
    wk = "%d-W%02d" % now.isocalendar()[:2]
    n = 0
    for a in SellerAgent.objects.filter(daily_report=True).select_related("business",
                                                                         "business__user"):
        b = a.business
        if PaCollectionItem.objects.filter(user=b.user, collection=COL_WEEKLY,
                                           data__business_id=b.pk, data__week=wk).exists():
            continue
        bn, en = weekly_report(b, "bn", now), weekly_report(b, "en", now)
        PaCollectionItem.objects.create(user=b.user, collection=COL_WEEKLY,
                                        data={"business_id": b.pk, "week": wk, "bn": bn, "en": en})
        S.notify_seller(b, "report", bn["title"], en["title"], bn["lines"][0], en["lines"][0])
        n += 1
    return n
