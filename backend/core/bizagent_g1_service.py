"""
G1 — Business AI Agent "Night Salesman": the Django side of the advanced
agent. Pure decisions: core.logic.bizagent_rules (rule-first answers, FAQ) and
core.logic.bizagent_g1 (who replies, follow-ups, bundle/upsell, payment
screenshots, vision JSON, reports). The base pipeline stays in
core.bizagent_service (compose/respond/send); this module adds:

  * rules context + FAQ hits, rules-vs-AI stats
  * per-chat single-flight lease (never two replies at once) + human pause /
    resume after the seller's timeout
  * priced order with bundle rules (min price enforced in code), summary
    extras, upsell, auto courier booking (test channels: MOCK, labelled)
  * customer photos (free perceptual match → paid vision description →
    catalog match / closest 2-3 with photos), payment screenshots →
    payment PENDING, voice notes → transcript
  * follow-ups, quiet hours, morning summary, agent report, FAQ learning
  * website chat widget channel
"""
import logging
import secrets
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.db import transaction
from django.db.models import Count, F, Q, Sum
from django.utils import timezone

from .logic import bizagent as BZ
from .logic import bizagent_g1 as G1
from .logic import bizagent_rules as R
from .logic import business_ai as bai
from . import bizagent_guard as GD

log = logging.getLogger(__name__)

PUBLIC_BASE = "https://api.lifeassisto.com"


def S():
    from . import bizagent_service
    return bizagent_service


def _minute_of_day(now=None):
    lt = timezone.localtime(now or timezone.now())
    return lt.hour * 60 + lt.minute


# ===================================================================== rules
def faqs_for(business):
    from .models import BizFaq
    return [{"id": f.id, "q": f.question, "a": f.answer}
            for f in BizFaq.objects.filter(business=business, status="approved")[:200]]


def orders_for_thread(thread, limit=3):
    return [{"id": o.id, "status": o.status, "tracking": o.tracking, "courier": o.courier,
             "payment_status": o.payment_status, "total": str(o.total)}
            for o in thread.orders.order_by("-created_at")[:limit]]


def post_product(business, catalog, post_id):
    if not post_id:
        return None
    from .models import BizPostLink
    link = BizPostLink.objects.filter(business=business, post_id=str(post_id)).first()
    if not link:
        return None
    return next((p for p in catalog if p.get("id") == link.product_id), None)


def wallets_for(business):
    """sales2: the seller's OWN bKash / Nagad numbers (OwnerWallet) for the
    payment steps — never anyone else's number."""
    from .models import OwnerWallet
    rows = OwnerWallet.objects.filter(user=business.user).filter(
        Q(business=business) | Q(business__isnull=True)).order_by("id")
    out, seen = [], set()
    for w in rows:
        if w.provider in seen or not (w.merchant_number or "").strip():
            continue
        seen.add(w.provider)
        out.append({"provider": w.provider, "number": w.merchant_number.strip(),
                    "name": (w.merchant_name or "").strip()})
    return out


def address_for(business):
    """sales2: the address the seller published on their booking page (the
    only shop-address field we hold); '' when none."""
    page = getattr(business, "booking_page", None) if hasattr(business, "booking_page") else None
    try:
        return (page.address or "").strip() if page is not None else ""
    except Exception:  # noqa: BLE001
        return ""


def hours_text_for(business, agent, pol=None):
    """The agent's hours, else the seller's policy / profile hours text."""
    ht = BZ.hours_text(agent.hours)
    if ht:
        return ht
    pol = pol if pol is not None else business.policies.first()
    return ((pol.hours if pol else "") or business.hours or "").strip()


def rules_ctx(business, agent, thread, lang, catalog, post_id=""):
    pol = business.policies.first()
    return {"lang": lang, "catalog": catalog, "delivery": S().delivery_for(business),
            "hours_text": hours_text_for(business, agent, pol),
            "policies": {"returns": pol.returns if pol else "",
                         "payment": pol.payment_note if pol else ""},
            "faqs": faqs_for(business), "orders": orders_for_thread(thread),
            "shop_name": business.shop_name, "cod": agent.cod_enabled,
            "post_product": post_product(business, catalog, post_id)
            or focus_product(thread, catalog),
            "wallets": wallets_for(business), "address": address_for(business)}


def focus_product(thread, catalog):
    """sales2: the product this chat is about (the last one the agent
    described, or the order draft's) — so "L size ache?" / "last price?" /
    "bkash e dibo" right after "Panjabi dam koto?" need no product name."""
    d = (thread.order_draft or {}) if thread is not None else {}
    pid = (d.get("focus") or {}).get("id") or d.get("product_id")
    if not pid:
        return None
    return next((p for p in catalog or [] if p.get("id") == pid), None)


def remember_focus(thread, product_id, catalog):
    """Store the described product as the chat's focus (not an order)."""
    from .models import ChatThread
    p = next((x for x in catalog or [] if x.get("id") == product_id), None)
    if p is None or thread is None or thread.pk is None:
        return
    d = dict(thread.order_draft or {})
    if (d.get("focus") or {}).get("id") == p["id"]:
        return
    d["focus"] = {"id": p["id"], "name": p["name"]}
    ChatThread.objects.filter(pk=thread.pk).update(order_draft=d)
    thread.order_draft = d


def rule_answer(business, agent, thread, text, lang, catalog, post_id=""):
    """The rule-first reply dict for compose(), or None (→ AI). Every number
    is post-checked like an AI draft; an FAQ answer that states a price the
    catalog does not have is skipped (a stale price never goes out)."""
    if not agent.rules_enabled:
        return None
    ctx = rules_ctx(business, agent, thread, lang, catalog, post_id)
    r = R.answer(text, ctx)
    if not r:
        return None
    check_ctx = {"catalog": catalog, "delivery": ctx["delivery"],
                 "policies": S().policies_for(business, agent)}
    extra = [o["id"] for o in ctx["orders"]] + list(r.get("numbers") or [])
    probs = BZ.check_numbers(r["text"], check_ctx, text, extra=extra)
    if r["rule"] == R.R_FAQ:
        probs = [p for p in probs if p["type"] in ("money", "stock_claim")]
    if probs:
        return None
    if r.get("faq_id"):
        from .models import BizFaq
        BizFaq.objects.filter(pk=r["faq_id"]).update(hits=F("hits") + 1)
    return {"text": r["text"], "kind": "text", "risk": None, "confidence": 1.0,
            "source": "rule", "rule": r["rule"], "product_id": r.get("product_id")}


# ===================================================================== lease
def acquire(thread, seconds=G1.LOCK_SECONDS):
    """Per-chat single-flight lease (atomic compare-and-set). False = another
    worker is replying in this chat right now."""
    from .models import ChatThread
    now = timezone.now()
    n = ChatThread.objects.filter(pk=thread.pk).filter(
        Q(reply_lock_until__isnull=True) | Q(reply_lock_until__lt=now)).update(
        reply_lock_until=now + timedelta(seconds=seconds))
    return bool(n)


def release(thread):
    from .models import ChatThread
    ChatThread.objects.filter(pk=thread.pk).update(reply_lock_until=None)


# ===================================================================== who replies
def ai_state(agent, thread, now=None):
    """(allowed, reason) for an AI reply in this chat right now."""
    now = now or timezone.now()
    cfg = S().sa_cfg()
    paused = thread.ai_paused_until.timestamp() if thread.ai_paused_until else None
    return G1.may_ai_reply(
        mode=agent.ai_mode, ai_enabled=agent.ai_enabled and not cfg["ai_kill"],
        in_business_hours=G1.in_business_hours(agent.hours, _minute_of_day(now)),
        human_mode=thread.owner_takeover, paused_until_ts=paused, now_ts=now.timestamp())


def pause_for_human(thread, by, agent=None, now=None):
    """A person replied in THIS chat (Assisto app or Page inbox echo): the AI
    pauses here only, for the seller's resume timeout."""
    from .models import ChatThread
    now = now or timezone.now()
    agent = agent or S().agent_for(thread.business)
    until = now + timedelta(minutes=G1.clamp_int(agent.resume_minutes, 1, G1.MAX_RESUME_MIN,
                                                 G1.DEFAULT_RESUME_MIN))
    ChatThread.objects.filter(pk=thread.pk).update(ai_paused_until=until, paused_by=by[:12])
    thread.ai_paused_until, thread.paused_by = until, by[:12]
    return until


def set_reply_mode(thread, mode):
    """Per-chat toggle: 'human' = I will reply (AI silent until switched
    back) · 'ai' = Let AI reply (clears any pause)."""
    thread.owner_takeover = mode == "human"
    thread.ai_paused_until = None
    thread.paused_by = ""
    thread.save(update_fields=["owner_takeover", "ai_paused_until", "paused_by"])
    return thread


def human_replied_since(thread, since):
    return thread.messages.filter(direction="out", is_ai=False, created_at__gt=since,
                                  reply_source="human").exists()


def resume_waiting(now=None, limit=100):
    """Cron (every minute): a pause that ran out while the customer is still
    waiting → the AI answers their latest message (once, under the lease)."""
    from .models import ChatThread
    now = now or timezone.now()
    n = 0
    qs = ChatThread.objects.filter(ai_paused_until__isnull=False, ai_paused_until__lte=now,
                                   owner_takeover=False).select_related(
        "seller_channel", "business", "business__user")[:limit]
    for t in qs:
        ChatThread.objects.filter(pk=t.pk).update(ai_paused_until=None, paused_by="")
        t.ai_paused_until = None
        msgs = list(t.messages.order_by("-created_at", "-id")[:12])[::-1]
        rows = [{"direction": m.direction, "status": m.status} for m in msgs]
        if not G1.customer_waiting(rows) or t.seller_channel is None:
            continue
        last_in = next((m for m in reversed(msgs) if m.direction == "in"), None)
        if last_in is None:
            continue
        res = S().respond(t.seller_channel, t, last_in.text, t.lang or "bn",
                          resumed=True)
        if res not in ("human", "paused", "channel_off", "deferred"):
            n += 1
    return n


def process_deferred(now=None, limit=50):
    """Cron: a message that arrived while another worker held the chat's
    lease and was not picked up (rare race) → answer it now."""
    from .models import Message
    now = now or timezone.now()
    n = 0
    seen = set()
    for m in Message.objects.filter(direction="in", meta__deferred=True,
                                    created_at__lt=now - timedelta(seconds=20)) \
            .select_related("thread", "thread__seller_channel").order_by("-created_at")[:limit]:
        t = m.thread
        dm_meta = {k: v for k, v in (m.meta or {}).items() if k != "deferred"}
        dm_meta["deferred_done"] = True
        Message.objects.filter(pk=m.pk).update(meta=dm_meta)
        if t.pk in seen or t.seller_channel is None:
            continue
        seen.add(t.pk)
        if t.messages.filter(id__gt=m.id, direction="out").exclude(
                status__in=("pending_approval", "rejected")).exists():
            continue                     # already answered after it
        S().respond(t.seller_channel, t, m.text, bai.reply_lang(m.text))
        n += 1
    return n


def run_sweeps(now=None):
    """Everything the per-minute cron (manage.py bizagent_process) does for
    G1: human pause ran out → answer the waiting customer; leftover deferred
    messages; follow-ups; the morning summary."""
    out = {}
    from . import bizagent_guard as GD
    for name, fn in (("idle_handback", GD.sweep_idle_takeovers), ("resumed", resume_waiting), ("deferred", process_deferred),
                     ("followups", run_followups), ("morning", run_morning)):
        try:
            out[name] = fn(now)
        except Exception:  # noqa: BLE001 — one failing sweep never blocks the rest
            log.exception("bizagent g1 sweep %s failed", name)
            out[name] = -1
    return out


# ===================================================================== pricing
def price_for(draft, catalog, business, agent):
    """BZ.price_order() + the seller's bundle rule (never below the min price,
    never on top of a negotiated price) + free delivery recomputed."""
    delivery = S().delivery_for(business)
    priced = BZ.price_order(draft, catalog, delivery)
    if not priced:
        return None
    ag = draft.get("agreed") or {}
    if ag.get("product_id") == draft.get("product_id"):
        return priced
    prod = next((p for p in catalog if p.get("id") == draft.get("product_id")), None) or {}
    floor = prod.get("min_price")
    if draft.get("variant"):
        for v in prod.get("variants") or []:
            if v.get("vkey") == draft["variant"] and BZ._dec(v.get("min_price")):
                floor = v.get("min_price")
    unit, rule = G1.bundle_unit_price(priced["unit"], floor, priced["qty"], agent.bundle_rules)
    if rule:
        priced["list_unit"] = priced["unit"]
        priced["unit"] = unit
        priced["subtotal"] = unit * priced["qty"]
        priced["delivery"] = BZ.delivery_charge(draft.get("area"), delivery, priced["subtotal"])
        priced["total"] = priced["subtotal"] + priced["delivery"]
        priced["bundle"] = rule
    return priced


def summary_extras(lang, priced, business):
    """Extra lines under the order summary + the numbers they contain (for
    the post-check)."""
    lines, nums = [], []
    if priced.get("bundle"):
        b = priced["bundle"]
        lines.append(bai.pick(
            lang, f"বান্ডেল ছাড়: {b['min_qty']}টি বা বেশি নিলে প্রতি পিস ৳{BZ._fmt_money(priced['list_unit'])}-এর বদলে ৳{BZ._fmt_money(priced['unit'])}।",
            f"Bundle price: {b['min_qty']}+ pieces at ৳{BZ._fmt_money(priced['unit'])} each instead of ৳{BZ._fmt_money(priced['list_unit'])}."))
        nums += [priced["list_unit"], priced["unit"], b["min_qty"]]
    nudge, gap = G1.free_delivery_nudge(lang, priced["subtotal"], S().delivery_for(business))
    if nudge and priced.get("delivery"):
        lines.append(nudge)
        nums.append(gap)
    return lines, nums


# ===================================================================== couriers
def mock_book(order, courier, lang="bn"):
    """TEST-MODE ONLY (self-test channels): a clearly labelled MOCK booking —
    courier_live=False, tracking 'TEST-…'. Never used for a real channel."""
    from .models import CourierShipment
    order.courier = courier
    order.tracking = ("TEST-%s-%s" % (courier.upper(), order.id))[:80]
    order.consignment_id = ""
    order.courier_status = "test_mode_mock"
    order.courier_live = False
    order.status = "shipped"
    order.courier_checked_at = timezone.now()
    order.save()
    CourierShipment.objects.create(order=order, courier=courier, tracking=order.tracking,
                                   live=False, cod_amount=bai.cod_amount(
                                       {"payment": order.payment, "total": str(order.total)}))
    return {"ok": True, "tracking": order.tracking, "mock": True}


def auto_courier(order, agent, thread, lang):
    """Book the seller's default courier right after the customer confirms
    (seller setting). Real channels: the courier's real API (needs the
    seller's keys); test channels: MOCK, labelled TEST."""
    if not (agent.auto_courier and agent.default_courier):
        return None
    ch = thread.seller_channel
    if ch is not None and ch.test_mode:
        r = mock_book(order, agent.default_courier, lang)
        S().send_text(thread, bai.pick(
            lang, f"অর্ডার #{order.id}: কুরিয়ার বুক হয়েছে ({agent.default_courier} ট্র্যাকিং: {order.tracking}) — টেস্ট মোড, আসল কুরিয়ার নয়।",
            f"Order #{order.id}: courier booked ({agent.default_courier} tracking: {order.tracking}) — TEST MODE, not a real courier."),
            kind="text", is_ai=True, meta={"source": "system", "courier_mock": True},
            source="system")
        return r
    r = S().book_courier(order, agent.default_courier, lang)
    if not r.get("ok"):
        S().notify_seller(order.business, "orders", "কুরিয়ার বুক হয়নি", "Courier not booked",
                          "অর্ডার #%s: %s" % (order.id, r.get("error", "")),
                          "Order #%s: %s" % (order.id, r.get("error", "")),
                          data={"order_id": str(order.id)})
    return r


def upsell_text(agent, thread, catalog, product_id, lang):
    if not agent.upsell_enabled or thread.upsell_done:
        return ""
    p = G1.pick_upsell(catalog, product_id)
    if not p:
        return ""
    from .models import ChatThread
    ChatThread.objects.filter(pk=thread.pk).update(upsell_done=True)
    thread.upsell_done = True
    return G1.upsell_line(lang, p)


# ===================================================================== payment proof
def mark_payment_pending(thread, lang):
    """A payment screenshot NEVER confirms a payment: the latest open order
    (or the order being drafted) becomes payment-pending and the owner is
    asked to verify in their own wallet/bank."""
    from .models import ChatThread
    o = thread.orders.exclude(status__in=("cancelled", "delivered", "returned")) \
        .order_by("-created_at").first()
    if o is not None:
        o.payment_status = "pending_verification"
        o.save(update_fields=["payment_status"])
    else:
        d = dict(thread.order_draft or {})
        d["payment_proof"] = True
        ChatThread.objects.filter(pk=thread.pk).update(order_draft=d)
        thread.order_draft = d
    S().notify_seller(thread.business, "orders", "পেমেন্ট যাচাই করুন", "Verify a payment",
                      "গ্রাহক একটি পেমেন্ট স্ক্রিনশট পাঠিয়েছেন। নিজের বিকাশ/নগদ/ব্যাংকে মিলিয়ে দেখুন — স্ক্রিনশট দিয়ে পেমেন্ট নিশ্চিত হয় না।",
                      "A customer sent a payment screenshot. Check your own bKash/Nagad/bank — a screenshot never proves a payment.",
                      data={"thread_id": str(thread.pk), "order_id": str(o.id) if o else ""})
    return {"text": G1.payment_pending_reply(lang, o.id if o else None), "kind": "text",
            "risk": None, "confidence": 1.0, "source": "rule", "rule": "payment_proof"}


# ===================================================================== photos
def _photo_url(p_obj):
    try:
        u = p_obj.photo.url
    except Exception:
        return ""
    if not u:
        return ""
    return u if u.startswith("http") else (getattr(settings, "PUBLIC_API_BASE", PUBLIC_BASE) + u)


def compose_image(business, agent, thread, data, mime, caption, lang):
    """Reply for a customer PHOTO. Order: payment words → payment pending;
    free perceptual match; paid vision (when connected + credits) for
    description / text / payment kind; never a price from the model."""
    from . import bizagent_media as M
    from .models import Product
    catalog = S().catalog_for(business)
    if G1.is_payment_proof(caption):
        return mark_payment_pending(thread, lang)
    vis = M.visual_matches(business, data)
    best = vis[0] if vis else (0.0, None)
    meta = {"image": True, "hash_score": best[0]}
    if best[1] is not None and best[0] >= G1.MATCH_SURE:
        p = next((x for x in catalog if x["id"] == best[1]), None)
        if p:
            _remember_product(thread, p)
            return {"text": _with_draft(thread, p, lang, G1.matched_reply(
                        lang, p, R.product_card(lang, p))), "kind": "text",
                    "risk": None, "confidence": 1.0, "source": "rule", "rule": "image_match",
                    "meta": meta, "product_id": p["id"]}
    parsed, info = (None, {"error": "vision_off", "charged": 0, "cost_bdt": 0.0})
    if agent.vision_enabled and not GD.ai_budget_ok(agent):
        # biz-v2: the daily AI cap also covers paid vision
        GD.note_cap_hit(agent, "daily_ai", thread)
        info = {"error": "daily_ai_cap", "charged": 0, "cost_bdt": 0.0}
    elif agent.vision_enabled:
        parsed, info = M.describe(business.user, data, mime, lang, [p["name"] for p in catalog])
    meta.update({"vision": info.get("provider", ""), "vision_error": info.get("error", "")})
    cost = {"credits": info.get("charged", 0), "cost_bdt": info.get("cost_bdt", 0.0)}
    if parsed is None:
        close = [next((x for x in catalog if x["id"] == pid), None) for s, pid in vis
                 if s >= 0.55]
        close = [c for c in close if c]
        if close:
            out = {"text": G1.closest_reply(lang, close), "kind": "text", "risk": None,
                   "confidence": 0.8, "source": "rule", "rule": "image_closest", "meta": meta,
                   "photos": [c["id"] for c in close[:3]]}
            return out
        return {"text": BZ.holding_message(lang, BZ.RISK_UNKNOWN_PRODUCT), "kind": "holding",
                "risk": BZ.RISK_UNKNOWN_PRODUCT, "confidence": 0.0, "source": "rule",
                "proposal": bai.pick(lang, "গ্রাহক একটি ছবি পাঠিয়েছেন — পণ্যটি দেখে উত্তর দিন।",
                                     "The customer sent a photo — check the product and reply."),
                "meta": meta}
    meta["vision_kind"] = parsed["kind"]
    if G1.is_payment_proof(caption, parsed.get("text"), parsed["kind"]):
        d = mark_payment_pending(thread, lang)
        d.update(meta=meta, **cost)
        return d
    if parsed["kind"] in ("address", "size_chart") or parsed.get("phone") or parsed.get("address"):
        bits = [parsed.get("text") or ""]
        if parsed.get("phone"):
            bits.append(parsed["phone"])
        if parsed.get("address"):
            bits.append("address: " + parsed["address"])
        synthetic = "\n".join(b for b in bits if b)
        if parsed["kind"] == "size_chart" and not (parsed.get("phone") or parsed.get("address")):
            pid = (thread.order_draft or {}).get("product_id")
            p = next((x for x in catalog if x["id"] == pid), None)
            line = R.sizes_line(lang, p) if p else ""
            if line:
                return dict({"text": bai.pick(lang, "আপনার সাইজ চার্ট দেখেছি। ", "We read your size chart. ") + line,
                             "kind": "text", "risk": None, "confidence": 0.9, "source": "ai",
                             "rule": "image_size_chart", "meta": meta, "charged_vision": True}, **cost)
        d = dict(thread.order_draft or {})
        d["active"] = True
        from .models import ChatThread
        ChatThread.objects.filter(pk=thread.pk).update(order_draft=d)
        thread.order_draft = d
        out = S().compose(business, agent, thread, synthetic, lang)
        out.setdefault("meta", {}).update(meta)
        out.update(cost)
        out["charged_vision"] = True
        return out
    # product photo: combine the free hash score with the description match
    tscores = {p["id"]: s for s, p in G1.text_match_scores(parsed, catalog)}
    hscores = {pid: s for s, pid in vis}
    combined = []
    for p in catalog:
        s = max(tscores.get(p["id"], 0.0), 0.0) + 0.5 * max(0.0, hscores.get(p["id"], 0.0) - 0.5)
        combined.append((round(s, 3), p))
    combined.sort(key=lambda x: -x[0])
    meta["text_score"] = combined[0][0] if combined else 0
    if combined and combined[0][0] >= G1.MATCH_TEXT_SURE and \
            (len(combined) < 2 or combined[0][0] - combined[1][0] >= 0.15):
        p = combined[0][1]
        _remember_product(thread, p)
        return dict({"text": _with_draft(thread, p, lang, G1.matched_reply(
                         lang, p, R.product_card(lang, p))), "kind": "text",
                     "risk": None, "confidence": 0.9, "source": "ai", "rule": "image_vision",
                     "meta": meta, "product_id": p["id"], "charged_vision": True}, **cost)
    close = [p for s, p in combined if s > 0][:3]
    return dict({"text": G1.closest_reply(lang, close), "kind": "text", "risk": None,
                 "confidence": 0.7, "source": "ai", "rule": "image_closest", "meta": meta,
                 "photos": [p["id"] for p in close], "charged_vision": True}, **cost)


def _with_draft(thread, p, lang, text):
    """biz-v2 image → order: a sure catalogue match becomes a DRAFT order the
    owner confirms (stock untouched until then). No price → no draft."""
    if GD.image_draft_order(thread, p) is None:
        return text
    return text + "\n" + GD.draft_line(lang)


def _remember_product(thread, p):
    """The matched product becomes the order draft's product (the customer
    usually says "I want this one" next)."""
    from .models import ChatThread
    d = dict(thread.order_draft or {})
    if d.get("state") == "awaiting_confirm":
        return
    d["product_id"], d["product"] = p["id"], p["name"]
    d.setdefault("qty", 1)
    ChatThread.objects.filter(pk=thread.pk).update(order_draft=d)
    thread.order_draft = d


def send_photos(thread, product_ids, lang):
    """The 2-3 closest products WITH photos (one image message each)."""
    from .models import Product
    sent = 0
    for p in Product.objects.filter(pk__in=list(product_ids or [])[:3]):
        url = _photo_url(p) if p.photo else ""
        if not url:
            continue
        cap = "%s — ৳%s" % (p.name, BZ._fmt_money(p.price))
        S().send_image(thread, url, cap)
        sent += 1
    return sent


# ===================================================================== voice
def voice_text(business, agent, thread, data, mime, lang):
    """(text, info) — '' when no key / no credits / failure."""
    from . import bizagent_media as M
    if not agent.voice_enabled:
        return "", {"error": "voice_off", "charged": 0, "cost_bdt": 0.0}
    return M.transcribe(business.user, data, mime, lang)


def voice_fallback_line(lang):
    return bai.pick(lang, "দুঃখিত, ভয়েস মেসেজটি এখন শুনতে পারছি না। অনুগ্রহ করে লিখে পাঠান — দোকানের একজনকেও জানানো হয়েছে।",
                    "Sorry, I can't listen to voice messages right now. Please type your message — someone from the shop has been told too.")


# ===================================================================== follow-ups
def run_followups(now=None, limit=200):
    """Cron: ONE gentle follow-up to a customer who went silent after the
    agent asked something. Inside the 24 h window only, capped per chat,
    opt-out honoured, never in quiet hours or while a human handles the chat."""
    from .models import ChatThread, SellerAgent
    now = now or timezone.now()
    mod = _minute_of_day(now)
    n = 0
    agents = {a.business_id: a for a in SellerAgent.objects.filter(followups_enabled=True,
                                                                    ai_enabled=True)}
    if not agents:
        return 0
    since = now - timedelta(hours=24)
    qs = ChatThread.objects.filter(business_id__in=list(agents), last_inbound_at__gte=since,
                                   opted_out=False, owner_takeover=False) \
        .exclude(seller_channel=None).select_related("seller_channel", "business")[:limit]
    for t in qs:
        a = agents[t.business_id]
        if t.seller_channel.kind == "website":
            continue
        last = t.messages.order_by("-created_at", "-id").first()
        if last is None:
            continue
        paused = bool(t.ai_paused_until and t.ai_paused_until > now)
        ok = G1.followup_due(
            enabled=True, opted_out=t.opted_out, human_mode=t.owner_takeover, paused=paused,
            quiet=G1.in_window(a.quiet_hours, mod), last_dir=last.direction,
            last_out_kind=last.kind, last_at_ts=last.created_at.timestamp(),
            last_inbound_ts=t.last_inbound_at.timestamp() if t.last_inbound_at else None,
            now_ts=now.timestamp(), sent=t.followups_sent, max_n=a.followup_max,
            after_hours=a.followup_after_hours)
        if not ok or last.reply_source == "system" and (last.meta or {}).get("followup"):
            continue
        if not acquire(t):
            continue
        try:
            m = S().send_text(t, G1.followup_text(t.lang or "bn", t.order_draft), kind="followup",
                              is_ai=True, meta={"followup": True}, source="system")
            if m.status == "sent":
                ChatThread.objects.filter(pk=t.pk).update(followups_sent=F("followups_sent") + 1,
                                                          last_followup_at=now)
                n += 1
        finally:
            release(t)
    return n


# ===================================================================== morning summary
def overnight_stats(business, since, now):
    from .models import ChatThread, Message, Order
    orders = Order.objects.filter(business=business, via_agent=True, created_at__gte=since,
                                  created_at__lt=now).exclude(status="cancelled")
    threads = ChatThread.objects.filter(business=business, last_inbound_at__gte=since)
    unanswered = 0
    for t in threads[:300]:
        last = t.messages.order_by("-created_at", "-id").first()
        if last and (last.direction == "in" or last.kind == "holding"):
            unanswered += 1
    return {"orders": orders.count(),
            "revenue": str(orders.aggregate(s=Sum("total"))["s"] or 0),
            "chats": threads.count(),
            "pending_approvals": Message.objects.filter(thread__business=business,
                                                        status="pending_approval").count(),
            "unanswered": unanswered,
            "payment_pending": Order.objects.filter(business=business,
                                                    payment_status="pending_verification")
            .count()}


def run_morning(now=None):
    """Cron (every minute via bizagent_process): at the seller's morning hour,
    ONE push per day: overnight orders, revenue, pending approvals,
    unanswered questions. Stored on today's BizAgentReport too."""
    from .models import BizAgentReport, SellerAgent
    now = now or timezone.now()
    lt = timezone.localtime(now)
    n = 0
    for a in SellerAgent.objects.filter(morning_summary=True).exclude(
            last_morning_day=lt.date()).select_related("business", "business__user"):
        if lt.hour < G1.clamp_int(a.morning_hour, 0, 23, 8):
            continue
        if not a.business.seller_channels.exists():
            continue
        stats = overnight_stats(a.business, now - timedelta(hours=14), now)
        rep, _ = BizAgentReport.objects.get_or_create(business=a.business, day=lt.date())
        rep.data = dict(rep.data or {}, morning=stats)
        rep.save(update_fields=["data"])
        bn, en = G1.morning_text("bn", stats), G1.morning_text("en", stats)
        S().notify_seller(a.business, "morning", bn["title"], en["title"], bn["body"], en["body"],
                          force=True)
        SellerAgent.objects.filter(pk=a.pk).update(last_morning_day=lt.date())
        n += 1
    return n


def in_quiet(agent, now=None):
    return G1.in_window(agent.quiet_hours, _minute_of_day(now))


# ===================================================================== report
def agent_report(business, days=30, now=None):
    """Chats, orders, revenue the AGENT brought (orders it took in chat,
    cancelled excluded), AI cost the seller paid, profit."""
    from .models import ChatThread, Message, Order, Product
    from . import billing
    now = now or timezone.now()
    since = now - timedelta(days=days)
    orders = list(Order.objects.filter(business=business, via_agent=True, created_at__gte=since)
                  .exclude(status__in=("cancelled", "returned")))
    revenue = sum((o.total or 0) for o in orders)
    gp, known = Decimal(0), True
    pids = {it.get("product_id") for o in orders for it in (o.items or [])}
    costs = {p.id: p.cost_price for p in Product.objects.filter(pk__in=[x for x in pids if x])}
    for o in orders:
        for it in o.items or []:
            c = costs.get(it.get("product_id"))
            if not c:
                known = False
                continue
            gp += (BZ._dec(it.get("price")) - c) * int(it.get("qty") or 1)
    msgs = Message.objects.filter(thread__business=business, created_at__gte=since,
                                  direction="out")
    agg = msgs.aggregate(cr=Sum("credits"))
    credit_bdt = float(billing.cfg().get("credit_bdt") or 1.0)
    plan_replies = msgs.filter(reply_source="ai", meta__billed="plan").count()
    plan_cost = 0.0
    agent = S().agent_for(business)
    row = S().sa_cfg()["plans"].get(agent.plan)
    if row and row["replies"]:
        plan_cost = plan_replies * (float(row["price"]) / float(row["replies"]))
    ai_cost = float(agg["cr"] or 0) * credit_bdt + plan_cost
    counts = dict(msgs.values_list("reply_source").annotate(n=Count("id")))
    return G1.agent_report(
        chats=ChatThread.objects.filter(business=business, last_message_at__gte=since).count(),
        orders=len(orders), revenue=revenue, gross_profit=gp, cost_known=known and bool(orders),
        ai_cost_bdt=ai_cost, rule_replies=counts.get("rule", 0), ai_replies=counts.get("ai", 0),
        images=msgs.filter(meta__image=True).count(),
        voice=Message.objects.filter(thread__business=business, created_at__gte=since,
                                     direction="in", kind="voice").count())


def rules_stats(days=30, now=None, business=None):
    """Owner Admin / seller: share of automatic replies answered by RULES
    (cost 0) vs the AI, and the money saved."""
    from .models import Message
    from . import billing
    from .logic import pricing
    now = now or timezone.now()
    qs = Message.objects.filter(direction="out", created_at__gte=now - timedelta(days=days),
                                reply_source__in=("rule", "ai"))
    if business is not None:
        qs = qs.filter(thread__business=business)
    counts = dict(qs.values_list("reply_source").annotate(n=Count("id")))
    rule_n, ai_n = counts.get("rule", 0), counts.get("ai", 0)
    cfg = billing.cfg()
    per_cost = BZ.reply_cost_bdt(cfg)                                 # our provider ৳ / reply
    per_credits = pricing.credit_cost("ai_sales", cfg)
    by_rule = dict(qs.filter(reply_source="rule").values_list("meta__rule").annotate(n=Count("id")))
    vision = Message.objects.filter(direction="out", created_at__gte=now - timedelta(days=days),
                                    meta__image=True, cost_bdt__gt=0)
    if business is not None:
        vision = vision.filter(thread__business=business)
    vagg = vision.aggregate(n=Count("id"), c=Sum("cost_bdt"), cr=Sum("credits"))
    return {"rule": rule_n, "ai": ai_n, "rule_pct": R.rule_share(rule_n, ai_n),
            "saved_provider_bdt": round(rule_n * per_cost, 2),
            "saved_seller_credits": rule_n * per_credits,
            "saved_seller_bdt": round(rule_n * per_credits * float(cfg.get("credit_bdt") or 1), 2),
            "by_rule": {str(k or "other"): v for k, v in by_rule.items()},
            "vision_images": vagg["n"] or 0,
            "vision_cost_bdt": round(vagg["c"] or 0, 2),
            "vision_cost_per_image": round((vagg["c"] or 0) / vagg["n"], 2) if vagg["n"] else 0.0,
            "vision_credits": vagg["cr"] or 0}


# ===================================================================== FAQ learning
def learn_faqs(business, limit=20):
    """Owner's past HUMAN replies → FAQ SUGGESTIONS (status 'suggested',
    never used until the seller approves). Also refreshes the tone sample the
    LLM sees (style only, never facts)."""
    from .models import BizFaq, Message
    outs = list(Message.objects.filter(thread__business=business, direction="out", is_ai=False,
                                       reply_source__in=("human", ""), kind="text")
                .exclude(status__in=("failed", "blocked", "pending_approval"))
                .select_related("thread").order_by("-created_at")[:400])
    pairs = []
    for m in outs:
        q = m.thread.messages.filter(direction="in", created_at__lte=m.created_at) \
            .order_by("-created_at", "-id").first()
        if q:
            pairs.append((q.text, m.text))
    existing = list(BizFaq.objects.filter(business=business).values_list("question", flat=True))
    made = 0
    for s in R.learn_faq(pairs, existing_q=existing, limit=limit):
        BizFaq.objects.create(business=business, question=s["q"], answer=s["a"],
                              status="suggested", source="learned", has_price=s["has_price"])
        made += 1
    sample = R.tone_sample([m.text for m in outs])
    if sample and sample != (business.style_sample or ""):
        business.style_sample = sample
        business.save(update_fields=["style_sample"])
    return made


# ===================================================================== website widget
def widget_channel(business, create=True):
    from .models import SellerChannel
    ext = "web%d" % business.pk
    ch = SellerChannel.objects.filter(kind="website", external_id=ext).first()
    if ch is None and create:
        ch = SellerChannel.objects.create(business=business, kind="website", external_id=ext,
                                          display_name=(business.shop_name or "Website")[:120],
                                          status="connected", connected_at=timezone.now())
    return ch


def ensure_widget_key(agent):
    if not agent.widget_key:
        agent.widget_key = "w_" + secrets.token_urlsafe(24)[:40]
        agent.save(update_fields=["widget_key", "updated_at"])
    return agent.widget_key


def agent_by_widget_key(key):
    from .models import SellerAgent
    if not key or len(key) > 48:
        return None
    return SellerAgent.objects.filter(widget_key=key, widget_enabled=True).select_related(
        "business", "business__user").first()


def widget_snippet(key):
    return ('<script src="%s/api/v1/bizagent/chat.js" data-key="%s" async></script>'
            % (getattr(settings, "PUBLIC_API_BASE", PUBLIC_BASE), key))
