"""
P1 — Assisto Business AI Agent: the Django service layer.

Flow (one inbound customer message):
  webhook view → verify X-Hub-Signature-256 → ingest() stores one
  BizWebhookEvent per message id (idempotent) → fast 200 → process_event()
  (worker thread right away; `manage.py bizagent_process` sweeps anything left
  pending, e.g. after a restart) → handle_message():
    thread + inbound Message → kill switch / channel off / human handover / AI
    off checks → compose() (order flow → bargain → risk → LLM or mock draft →
    NUMBER POST-CHECK) → risky? holding line to the customer + approval queue +
    push to the seller : consume one reply (plan first, then credits) → send
    through the official Graph API (24 h window) → Message row with the honest
    send status.

Pure decisions live in core.logic.bizagent / business_ai. This module touches
the DB, billing, push and the Graph/courier clients.
"""
import json
import logging
import threading
import uuid
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.db import IntegrityError, transaction
from django.db.models import F, Q, Sum
from django.utils import timezone

from . import bizagent_graph as G
from . import couriers as C
from .logic import bizagent as BZ
from .logic import business_ai as bai

log = logging.getLogger(__name__)

PLAN_DAYS = 30


# ===================================================================== config
def full_cfg():
    from . import billing
    return billing.cfg()


def sa_cfg():
    return full_cfg()["seller_agent"]


def meta_app():
    from . import integrations
    try:
        return integrations.get("meta_app") or {}
    except Exception:
        return {}


# ===================================================================== crypto
def enc(data):
    from . import integrations
    return integrations._encrypt(data)


def dec(blob):
    from . import integrations
    if not blob:
        return {}
    try:
        return integrations._decrypt(blob)
    except Exception:
        return {}


def channel_token(ch):
    return (dec(ch.token_enc) or {}).get("token", "")


def channel_test_secret(ch):
    return (dec(ch.test_secret_enc) or {}).get("secret", "")


# ===================================================================== agent
def agent_for(business):
    from .models import SellerAgent
    a, _ = SellerAgent.objects.get_or_create(business=business)
    return a


def catalog_for(business):
    """The seller's REAL catalog as plain dicts (source of truth for prices)."""
    from .models import Product
    qs = Product.objects.filter(user=business.user).filter(
        Q(business=business) | Q(business__isnull=True)).prefetch_related("variants")
    out = []
    for p in qs:
        out.append({
            "id": p.id, "name": p.name, "price": str(p.price), "stock": p.stock,
            "min_price": str(p.min_price), "description": p.description,
            "low_stock_at": p.low_stock_at,
            "variants": [{"vkey": v.vkey, "size": v.size, "colour": v.colour,
                          "price": str(v.sell_price or p.price), "stock": v.stock,
                          "min_price": str(v.min_price)}
                         for v in p.variants.all() if v.vkey != "__base__"]})
    return out


def delivery_for(business):
    pol = business.policies.first()
    if not pol:
        return {}
    return {"inside_dhaka": str(pol.delivery_inside), "outside_dhaka": str(pol.delivery_outside),
            "free_over": str(pol.free_delivery_over) if pol.free_delivery_over else ""}


def policies_for(business, agent):
    pol = business.policies.first()
    out = {}
    if pol:
        if pol.returns:
            out["returns"] = pol.returns
        if pol.payment_note:
            out["payment"] = pol.payment_note
    pay = []
    if agent.cod_enabled:
        pay.append("cash on delivery")
    if agent.payment_link_enabled:
        pay.append("payment link (licensed partner)")
    if pay and "payment" not in out:
        out["payment"] = ", ".join(pay)
    ht = BZ.hours_text(agent.hours)
    if ht:
        out["hours"] = ht
    return out


def context_for(business, agent, lang, only=None):
    """build_context() from the real catalog. `only` = product dicts to keep
    the facts focused on what the customer asked about."""
    catalog = catalog_for(business)
    facts_catalog = only if only else catalog
    ctx = bai.build_context(catalog=facts_catalog, delivery=delivery_for(business) or None,
                            policies=policies_for(business, agent),
                            shop_name=business.shop_name, style=business.style_sample, lang=lang)
    ctx["catalog"] = catalog          # the post-check sees the whole catalog
    ctx["delivery"] = delivery_for(business)
    return ctx


# ===================================================================== billing
def _quota(agent, cfg):
    if agent.plan == "trial":
        return int(cfg["trial_replies"])
    row = cfg["plans"].get(agent.plan)
    return int(row["replies"]) if row else 0


def _purchasable(flavour):
    """NO SHOWPIECES: seller plans are sold through the payment gateway only;
    the app shows Buy only while the gateway is on AND configured for this
    build (the Play build also needs the owner's gateway_on_play switch)."""
    try:
        from .payments import service as PS
        return any(c["id"] == "gateway" and c["enabled"] and c["ready"]
                   for c in PS.channel_state(flavour))
    except Exception:
        return False


def plan_status(agent, now=None, flavour="apk"):
    now = now or timezone.now()
    cfg = sa_cfg()
    q = _quota(agent, cfg)
    st = BZ.plan_state(agent.plan, agent.period_end.timestamp() if agent.period_end else None,
                       agent.replies_used, q, now.timestamp())
    credits = int(getattr(agent.business.user, "ai_credits", 0) or 0)
    from .logic import pricing
    per = pricing.credit_cost("ai_sales", full_cfg()) or 1
    return {"plan": agent.plan if st["active"] else "none", "active": st["active"],
            "period_end": agent.period_end.isoformat() if agent.period_end else None,
            "quota": q if st["active"] else 0, "used": agent.replies_used if st["active"] else 0,
            "left": st["left"], "credits": credits, "credit_replies": credits // per,
            "trial_available": trial_available(agent),
            "purchasable": _purchasable(flavour),
            "trial_days": cfg["trial_days"], "trial_replies": cfg["trial_replies"],
            "plans": [{"id": k, "price": v["price"], "replies": v["replies"],
                       "sku": "seller_%s_monthly" % k} for k, v in cfg["plans"].items()]}


def consume_reply(agent, now=None):
    """Pay for ONE AI reply: the plan's monthly replies first (atomic, never
    past the quota), then purchased credits (billing.charge('ai_sales')).
    Returns ('plan'|'credits', charged) or (None, reason)."""
    from . import billing
    from .models import SellerAgent
    now = now or timezone.now()
    cfg = sa_cfg()
    q = _quota(agent, cfg)
    if agent.plan in ("trial", "starter", "pro") and agent.period_end and agent.period_end > now:
        # Profit Guard: the free trial pauses while the daily guard is over.
        if agent.plan == "trial":
            try:
                if billing.guard_state(now)["over"]:
                    return (None, "guard_over")
            except Exception:
                pass
        n = SellerAgent.objects.filter(pk=agent.pk, replies_used__lt=q,
                                       period_end__gt=now).update(replies_used=F("replies_used") + 1)
        if n:
            agent.replies_used += 1
            return ("plan", 1)
    if agent.plan == "trial":
        return (None, "trial_used_up")
    res = billing.charge(agent.business.user, "ai_sales", qty=1, note="bizagent.reply")
    if res["ok"] and res["charged"] > 0:
        return ("credits", res["charged"])
    if res["ok"]:
        return ("credits", 0)
    return (None, res.get("reason") or "insufficient")


def refund_reply(agent, via, charged):
    from . import billing
    from .models import SellerAgent
    if via == "plan":
        SellerAgent.objects.filter(pk=agent.pk, replies_used__gt=0).update(
            replies_used=F("replies_used") - 1)
    elif via == "credits" and charged:
        billing.credit(agent.business.user, "adjust", charged, note="bizagent_refund")


def trial_available(agent):
    """The 7-day trial: once per business AND once per owner account."""
    from .models import SellerAgent
    if agent.trial_started_at:
        return False
    return not SellerAgent.objects.filter(business__user=agent.business.user,
                                          trial_started_at__isnull=False).exists()


def start_trial(agent, now=None):
    now = now or timezone.now()
    if not trial_available(agent):
        return False
    if agent.plan in ("starter", "pro") and agent.period_end and agent.period_end > now:
        return False
    cfg = sa_cfg()
    agent.plan = "trial"
    agent.trial_started_at = now
    agent.period_start = now
    agent.period_end = now + timedelta(days=int(cfg["trial_days"]))
    agent.replies_used = 0
    agent.save()
    return True


def activate_plan(agent, plan, months=1, now=None):
    now = now or timezone.now()
    if plan not in sa_cfg()["plans"]:
        raise ValueError("unknown seller plan")
    start = now
    if agent.plan == plan and agent.period_end and agent.period_end > now:
        start = agent.period_end         # renewal stacks after the current month
        agent.period_end = start + timedelta(days=PLAN_DAYS * months)
    else:
        agent.plan = plan
        agent.period_start = now
        agent.period_end = now + timedelta(days=PLAN_DAYS * months)
        agent.replies_used = 0
    agent.save()
    return agent


def activate_plan_for_user(user, plan, months=1, now=None):
    from .models import BusinessProfile
    biz = BusinessProfile.objects.filter(user=user).first() or BusinessProfile.objects.create(user=user)
    return activate_plan(agent_for(biz), plan, months=months, now=now)


def revoke_plan_for_user(user, now=None):
    from .models import SellerAgent
    now = now or timezone.now()
    SellerAgent.objects.filter(business__user=user, plan__in=("starter", "pro")).update(
        period_end=now)


def charge_wa_billable(channel, status_event):
    """Meta charges the business per billable WhatsApp message/conversation.
    Charge the seller the owner-set rate + margin from credits, ONCE per
    conversation (CBP) or message (PMP). Rate 0 = not set → no charge."""
    from . import billing
    from .logic import pricing  # noqa: F401
    from .models import WebhookReceipt
    b = BZ.wa_billable(status_event)
    if not b:
        return 0
    _, cat, key = b
    credits = BZ.wa_charge_credits(cat, full_cfg())
    if credits <= 0:
        return 0
    try:
        with transaction.atomic():
            WebhookReceipt.objects.create(source="wa_bill", message_id=key[:128])
    except IntegrityError:
        return 0
    user = channel.business.user
    from .models import User, CreditLedger
    with transaction.atomic():
        locked = User.objects.select_for_update().get(pk=user.pk)
        take = min(int(locked.ai_credits or 0), credits)
        if take:
            User.objects.filter(pk=locked.pk).update(ai_credits=F("ai_credits") - take)
            CreditLedger.objects.create(user=locked, delta=-take, reason="consume",
                                        note=("wa_%s" % cat)[:120])
    sa = BZ.cfg_normalize(full_cfg().get("seller_agent"))
    try:
        billing.record_cost("whatsapp", float(sa["wa_cost_bdt"].get(cat, 0)))
    except Exception:
        pass
    return take


# ===================================================================== push
def notify_seller(business, kind, title_bn, title_en, body_bn="", body_en="", data=None):
    from . import push
    payload = {"route": "bizagent", "section": kind}
    payload.update(data or {})
    try:
        push.safe_push(business.user, "shop_alert", title_bn, title_en, body_bn, body_en,
                       data=payload)
    except Exception:
        pass


# ===================================================================== ingest
def find_channel(kind, account_id):
    from .models import SellerChannel
    return SellerChannel.objects.filter(kind=kind, external_id=str(account_id)).select_related(
        "business", "business__user").first()


def test_secrets_for(payload, parser):
    """Self-test: the test-mode channels named in an (unverified) payload and
    their test secrets. ONLY test_mode rows are ever considered."""
    out = []
    try:
        evs = parser(payload)
    except Exception:
        return out
    seen = set()
    for e in evs:
        key = (e["channel"], e["account_id"])
        if key in seen:
            continue
        seen.add(key)
        ch = find_channel(*key)
        if ch and ch.test_mode:
            sec = channel_test_secret(ch)
            if sec:
                out.append((ch, sec))
    return out


def ingest(source, payload, test_only_ids=None):
    """Parse + store one BizWebhookEvent per event id. Returns the NEW event
    pks (redeliveries are skipped = idempotent). `test_only_ids` = set of
    channel pks: when given (self-test signature), events for any other channel
    are dropped."""
    from .models import BizWebhookEvent
    events = BZ.parse_whatsapp(payload) if source == "whatsapp" else BZ.parse_meta(payload)
    new = []
    for e in events:
        if test_only_ids is not None:
            ch = find_channel(e["channel"], e["account_id"])
            if not ch or ch.pk not in test_only_ids:
                continue
        try:
            with transaction.atomic():
                row = BizWebhookEvent.objects.create(source=source, event_id=e["event_id"][:160],
                                                     kind=e["kind"][:12], payload=e)
            new.append(row.pk)
        except IntegrityError:
            continue
    return new


def kick(ids):
    """Process right after the 200: inline in tests (BIZAGENT_SYNC) or in a
    daemon thread. The cron sweep picks up anything a crash left pending."""
    if not ids:
        return
    if getattr(settings, "BIZAGENT_SYNC", False):
        for i in ids:
            process_event_id(i)
        return

    def run():
        from django.db import close_old_connections, connection
        try:
            close_old_connections()
            for i in ids:
                process_event_id(i)
        finally:
            try:
                connection.close()
            except Exception:
                pass
    # after commit, so the worker always sees the stored rows
    transaction.on_commit(
        lambda: threading.Thread(target=run, daemon=True, name="bizagent").start())


def process_event_id(pk):
    from .models import BizWebhookEvent
    with transaction.atomic():
        n = BizWebhookEvent.objects.filter(pk=pk, status="pending").update(
            status="working", attempts=F("attempts") + 1)
    if not n:
        return None
    row = BizWebhookEvent.objects.get(pk=pk)
    try:
        res = process_event(row.payload)
        row.status = "done" if res != "skipped" else "skipped"
        row.error = "" if res in ("ok", "skipped", None) else str(res)[:300]
    except Exception as e:  # noqa: BLE001 — record honestly, retry by sweep
        log.exception("bizagent event %s failed", pk)
        row.status = "error" if row.attempts >= 3 else "pending"
        row.error = ("%s: %s" % (type(e).__name__, e))[:300]
    row.processed_at = timezone.now()
    row.save(update_fields=["status", "error", "processed_at"])
    return row.status


def process_pending(limit=200):
    from .models import BizWebhookEvent
    stale = timezone.now() - timedelta(minutes=5)
    BizWebhookEvent.objects.filter(status="working", created_at__lt=stale).update(status="pending")
    ids = list(BizWebhookEvent.objects.filter(status="pending", attempts__lt=3)
               .order_by("created_at").values_list("pk", flat=True)[:limit])
    for i in ids:
        process_event_id(i)
    return len(ids)


def process_event(e):
    ch = find_channel(e.get("channel"), e.get("account_id"))
    if ch is None:
        return "no_channel"
    kind = e.get("kind")
    if kind == "status":
        return handle_status(ch, e)
    if kind == "echo":
        return handle_echo(ch, e)
    if kind == "comment":
        return handle_comment(ch, e)
    if kind in ("message", "postback"):
        return handle_message(ch, e)
    return "skipped"


# ===================================================================== threads
def _ts(e):
    ts = int(e.get("ts") or 0)
    if ts > 0:
        from datetime import datetime, timezone as dtz
        return datetime.fromtimestamp(ts, tz=dtz.utc)
    return timezone.now()


def thread_for(ch, user_id, name=""):
    from .models import ChatThread
    t = ChatThread.objects.filter(seller_channel=ch, external_user_id=user_id).first()
    if t is None:
        t = ChatThread.objects.create(
            user=ch.business.user, business=ch.business, seller_channel=ch,
            external_user_id=user_id, channel=ch.kind, customer_name=name[:120],
            customer_phone=user_id if ch.kind == BZ.CH_WHATSAPP else "")
    elif name and not t.customer_name:
        t.customer_name = name[:120]
        t.save(update_fields=["customer_name"])
    return t


def _channel_off(ch, cfg):
    return (not ch.enabled) or ch.status == "disabled" or bool(cfg["kill"].get(ch.kind))


# ===================================================================== send
def send_text(thread, text, *, kind="text", is_ai=True, comment_id="", public=False,
              status_on_ok="sent", meta=None):
    """Send one message on the thread's official channel and record it.
    Honest: no token → 'queued' (needs key), outside 24 h → 'blocked', Graph
    error → 'failed' with the reason. test_mode channels never hit the network."""
    from .models import Message
    ch = thread.seller_channel
    now = timezone.now()
    m = Message(thread=thread, direction="out", text=text, is_ai=is_ai, kind=kind,
                meta=dict(meta or {}))
    if comment_id:
        m.meta["comment_id"] = comment_id
    if ch is None:
        m.status, m.send_error = "queued", "no_channel"
        m.save()
        return m
    if ch.test_mode:
        m.status, m.external_id = status_on_ok, "test-" + uuid.uuid4().hex[:16]
        m.meta["test_mode"] = True
        m.save()
        return m
    token = channel_token(ch)
    if not token:
        m.status, m.send_error = "queued", "no_token"
        m.save()
        return m
    last_in = thread.last_inbound_at.timestamp() if thread.last_inbound_at else None
    if not comment_id and not bai.within_service_window(last_in, now.timestamp()):
        m.status = "blocked"
        m.send_error = ("outside_24h_window_template_required" if ch.kind == BZ.CH_WHATSAPP
                        else "outside_24h_window")
        m.save()
        return m
    if comment_id and public:
        r = G.public_comment_reply(token, comment_id, text, instagram=(ch.kind == BZ.CH_INSTAGRAM))
    elif comment_id:
        r = G.private_reply(token, comment_id, text, page_id=ch.external_id)
    elif ch.kind == BZ.CH_WHATSAPP:
        r = G.send_whatsapp_text(token, ch.external_id, thread.external_user_id, text)
    elif ch.kind == BZ.CH_INSTAGRAM:
        r = G.send_instagram(token, thread.external_user_id, text)
    else:
        r = G.send_messenger(token, thread.external_user_id, text, page_id=ch.external_id)
    if r["ok"]:
        m.status, m.external_id = status_on_ok, r.get("id", "")[:128]
    else:
        m.status, m.send_error = "failed", r.get("error", "")[:200]
    m.save()
    return m


def send_template(thread, name, lang_code="bn", params=None):
    """Outside the 24 h window WhatsApp allows ONLY an approved template."""
    from .models import Message
    ch = thread.seller_channel
    m = Message(thread=thread, direction="out", text="[template:%s]" % name, is_ai=False,
                kind="template", meta={"template": name, "params": params or []})
    if ch is None or ch.kind != BZ.CH_WHATSAPP:
        m.status, m.send_error = "blocked", "templates_whatsapp_only"
    elif ch.test_mode:
        m.status, m.external_id = "sent", "test-" + uuid.uuid4().hex[:16]
    else:
        token = channel_token(ch)
        if not token:
            m.status, m.send_error = "queued", "no_token"
        else:
            r = G.send_whatsapp_template(token, ch.external_id, thread.external_user_id, name,
                                         lang_code, params)
            if r["ok"]:
                m.status, m.external_id = "sent", r["id"][:128]
            else:
                m.status, m.send_error = "failed", r["error"][:200]
    m.save()
    return m


# ===================================================================== compose
def _llm_draft(ctx, lang, tone, text, history):
    """Real LLM via core.ai when a key exists. user=None: the reply is billed
    ONCE by consume_reply (ai_sales), not again by ai.generate; the provider
    spend is still booked into AIUsage + the daily P&L ledger."""
    from . import ai
    if not ai.key_present():
        return None
    try:
        out, _cost = ai.generate(task=BZ.llm_task(ctx, lang, tone), data=text, tier="cheap",
                                 max_tokens=300, feature="bizagent.reply", user=None,
                                 history=history)
    except ai.AIUnavailable:
        return None
    return BZ.parse_llm(out)


def _history(thread, limit=6):
    rows = list(thread.messages.filter(status__in=("received", "sent", "delivered", "read", ""))
                .order_by("-created_at", "-id")[:limit])
    out = []
    for m in reversed(rows):
        out.append({"role": "user" if m.direction == "in" else "assistant", "content": m.text})
    if out and out[-1]["role"] == "user":
        out = out[:-1]     # the current message goes in `data`
    while out and out[0]["role"] != "user":
        out = out[1:]
    return out


def _offer_in(text):
    import re
    for m in re.finditer(r"\d[\d,]*", BZ.norm_digits(text or "")):
        v = int(m.group(0).replace(",", ""))
        if v >= 10:
            return v
    return None


def compose(business, agent, thread, text, lang, *, allow_order=True):
    """Decide the reply. Returns dict:
      {"text", "kind", "risk", "proposal", "confidence", "order_action"}
    risk != None → the customer gets `text` (an honest holding line) and the
    seller gets `proposal` to approve/edit/reject."""
    catalog = catalog_for(business)
    matched = BZ.match_products(text, catalog)
    intent = bai.classify_intent(text)
    hours = BZ.hours_text(agent.hours)

    if BZ.asks_if_human(text):
        return {"text": bai.assistant_disclosure(lang)["full"], "kind": "text", "risk": None,
                "confidence": 1.0}

    # complaints / refunds go to a person BEFORE anything else ("refund chai"
    # must never be read as an order)
    if bai.handoff_trigger(text) in (bai.HANDOFF_REFUND, bai.HANDOFF_ANGRY):
        risk = BZ.pre_risk(text, intent, matched)
        return {"text": BZ.holding_message(lang, risk, hours), "kind": "holding", "risk": risk,
                "proposal": bai.handoff_message(lang, bai.handoff_trigger(text)),
                "confidence": 0.0}

    # ---- order flow (deterministic; every number from the catalog) ----
    draft = dict(thread.order_draft or {})
    if allow_order:
        if draft.get("state") == "awaiting_confirm":
            if BZ.is_yes(text):
                return {"order_action": "confirm", "kind": "order", "risk": None,
                        "text": "", "confidence": 1.0}
            if BZ.is_no(text):
                return {"order_action": "cancel", "kind": "order", "risk": None,
                        "text": BZ.order_cancelled_line(lang), "confidence": 1.0}
        wants_order = intent == "order" or draft.get("active") or (
            BZ.find_phone(text) and (matched or draft.get("product")))
        if wants_order:
            draft = BZ.extract_order(text, draft, catalog)
            draft["active"] = True
            draft.pop("state", None)
            thread.order_draft = draft
            thread.save(update_fields=["order_draft"])
            if draft.get("product"):
                priced = BZ.price_order(draft, catalog, delivery_for(business))
                if priced and not priced["stock_ok"]:
                    return {"text": BZ.out_of_stock_line(lang, priced["product"], priced["stock"]),
                            "kind": "text", "risk": None, "confidence": 1.0}
            miss = BZ.missing_fields(draft)
            if miss:
                return {"text": BZ.ask_missing(lang, miss, draft.get("phone_invalid")),
                        "kind": "order", "risk": None, "confidence": 1.0}
            priced = BZ.price_order(draft, catalog, delivery_for(business))
            if priced is None:
                return {"text": BZ.holding_message(lang, BZ.RISK_UNKNOWN_PRODUCT, hours),
                        "kind": "holding", "risk": BZ.RISK_UNKNOWN_PRODUCT,
                        "proposal": "", "confidence": 0.0}
            big = priced["total"] >= bai.BIG_ORDER_THRESHOLD
            draft["state"] = "awaiting_confirm"
            draft["total"] = str(priced["total"])
            thread.order_draft = draft
            thread.save(update_fields=["order_draft"])
            summary = BZ.order_summary(lang, draft, priced)
            if big:
                return {"text": BZ.holding_message(lang, BZ.RISK_BIG_ORDER, hours),
                        "kind": "holding", "risk": BZ.RISK_BIG_ORDER, "proposal": summary,
                        "confidence": 1.0}
            return {"text": summary, "kind": "order", "risk": None, "confidence": 1.0,
                    "extra": [priced["subtotal"], priced["total"], priced["unit"]]}

    # ---- bargaining: arithmetic only, the minimum price is never crossed ----
    offer_decision = None
    proposal = ""
    if intent == "bargain" and matched:
        offer = _offer_in(text)
        if offer:
            p = matched[0]
            # an unset minimum (0) means NO discount: the floor is the list price
            floor = p["min_price"] if (BZ._dec(p["min_price"]) or 0) > 0 else p["price"]
            neg = bai.negotiate(offer, {"name": p["name"], "price": p["price"],
                                        "min_price": floor}, lang=lang)
            offer_decision = neg.get("action")
            if offer_decision in (bai.ACTION_ACCEPT, bai.ACTION_COUNTER):
                if neg.get("price") is not None:
                    draft = dict(thread.order_draft or {})
                    draft["agreed"] = {"product_id": p["id"], "price": str(neg["price"])}
                    thread.order_draft = draft
                    thread.save(update_fields=["order_draft"])
                return {"text": neg.get("message") or neg.get("text") or "", "kind": "text",
                        "risk": None, "confidence": 1.0,
                        "extra": [neg.get("price"), neg.get("counter"), offer]}
            proposal = neg.get("message") or neg.get("text") or ""

    risk = BZ.pre_risk(text, intent, matched, offer_decision)
    if risk:
        if not proposal:
            proposal = bai.handoff_message(lang, {BZ.RISK_COMPLAINT: bai.HANDOFF_ANGRY,
                                                  BZ.RISK_REFUND: bai.HANDOFF_REFUND}.get(
                risk, "low_confidence"))
        return {"text": BZ.holding_message(lang, risk, hours), "kind": "holding", "risk": risk,
                "proposal": proposal, "confidence": 0.0}

    # ---- free reply: LLM (key) or deterministic mock, then POST-CHECK ----
    ctx = context_for(business, agent, lang, only=matched or None)
    d = _llm_draft(ctx, lang, agent.tone, text, _history(thread))
    used_ai = d is not None
    if d is None:
        d = bai.default_mock_provider({"lang": lang, "customer_text": text, "intent": intent,
                                       "facts": ctx["facts"] if matched or intent != "price_stock"
                                       else "", "shop_name": business.shop_name})
    reply = (d.get("text") or "").strip()
    conf = float(d.get("confidence") or 0)
    problems = BZ.check_numbers(reply, ctx, text)
    if problems:
        return {"text": BZ.holding_message(lang, BZ.RISK_NUMBERS, hours), "kind": "holding",
                "risk": BZ.RISK_NUMBERS, "proposal": reply, "confidence": conf,
                "problems": problems, "used_ai": used_ai}
    if not reply or conf < bai.HANDOFF_CONFIDENCE:
        return {"text": BZ.holding_message(lang, BZ.RISK_LOW_CONF, hours), "kind": "holding",
                "risk": BZ.RISK_LOW_CONF, "proposal": reply, "confidence": conf,
                "used_ai": used_ai}
    if agent.approve_all:
        return {"text": "", "kind": "text", "risk": BZ.RISK_APPROVE_ALL, "proposal": reply,
                "confidence": conf, "used_ai": used_ai}
    return {"text": reply, "kind": "text", "risk": None, "confidence": conf, "used_ai": used_ai}


# ===================================================================== handlers
def _queue_approval(thread, proposal, risk, *, comment_id="", problems=None, confidence=0.0):
    from .models import Message
    m = Message.objects.create(
        thread=thread, direction="out", text=proposal or "", is_ai=True,
        status="pending_approval", risk_reason=risk, needs_human=True,
        handoff_reason=risk, confidence=confidence, kind="text",
        meta={"comment_id": comment_id} if comment_id else {"problems": problems or []})
    notify_seller(thread.business, "approvals",
                  "অনুমোদন দরকার", "Approval needed",
                  "একটি AI উত্তর আপনার অনুমোদনের অপেক্ষায়।",
                  "An AI reply is waiting for your approval.",
                  data={"thread_id": str(thread.pk), "message_id": str(m.pk)})
    return m


def _out_of_replies(thread, agent, lang, reason, comment_id=""):
    """Never silent: the customer gets a polite line (once per thread per day),
    the seller is told (once per day)."""
    now = timezone.now()
    if not thread.oor_notice_at or now - thread.oor_notice_at > timedelta(hours=24):
        send_text(thread, BZ.out_of_replies_customer(lang), kind="holding", is_ai=False,
                  comment_id=comment_id)
        thread.oor_notice_at = now
        thread.save(update_fields=["oor_notice_at"])
    key = "oor:%s" % now.date().isoformat()
    t_bn, b_bn = BZ.out_of_replies_seller("bn")
    t_en, b_en = BZ.out_of_replies_seller("en")
    from .models import WebhookReceipt
    try:
        with transaction.atomic():
            WebhookReceipt.objects.create(source="ba_oor",
                                          message_id=("%s:%s" % (agent.pk, key))[:128])
        notify_seller(thread.business, "plan", t_bn, t_en, b_bn, b_en, data={"reason": reason})
    except IntegrityError:
        pass
    return "out_of_replies"


def _deliver_ai(thread, agent, text, lang, kind="text", comment_id="", public_too=False):
    """Pay for + send one AI reply (disclosure on the first AI reply)."""
    via, charged = consume_reply(agent)
    if via is None:
        return _out_of_replies(thread, agent, lang, charged, comment_id=comment_id)
    first = not thread.ai_disclosed
    body = BZ.with_disclosure(lang, text, first)
    m = send_text(thread, body, kind=kind, is_ai=True, comment_id=comment_id)
    if m.status in ("failed", "blocked", "queued"):
        refund_reply(agent, via, charged)
        if m.status == "failed":
            notify_seller(thread.business, "errors", "মেসেজ পাঠানো যায়নি",
                          "A message could not be sent", m.send_error, m.send_error,
                          data={"thread_id": str(thread.pk)})
        return m.status
    m.meta["billed"] = via
    m.save(update_fields=["meta"])
    if first:
        thread.ai_disclosed = True
        thread.save(update_fields=["ai_disclosed"])
    if public_too and comment_id and sa_cfg()["public_comment_reply"]:
        send_text(thread, BZ.comment_public_reply(lang), kind="comment", is_ai=True,
                  comment_id=comment_id, public=True)
    return "ok"


def handle_message(ch, e):
    from .models import Message
    if e.get("event_id") and Message.objects.filter(thread__seller_channel=ch,
                                                    external_id=e["event_id"]).exists():
        return "skipped"
    t = thread_for(ch, e["user_id"], e.get("name", ""))
    text = e.get("text") or ""
    lang = bai.reply_lang(text)
    at = _ts(e)
    t.last_inbound_at = at
    t.last_message_at = at
    t.lang = lang
    t.save(update_fields=["last_inbound_at", "last_message_at", "lang"])
    Message.objects.create(thread=t, direction="in", text=text, external_id=e.get("event_id", ""),
                           status="received", kind="text")
    return respond(ch, t, text, lang)


def respond(ch, t, text, lang, comment_id=""):
    cfg = sa_cfg()
    biz = ch.business
    agent = agent_for(biz)
    if _channel_off(ch, cfg):
        return "channel_off"
    if t.owner_takeover or not agent.ai_enabled or cfg["ai_kill"]:
        notify_seller(biz, "inbox", "নতুন মেসেজ", "New message",
                      (t.customer_name or "") + ": " + text[:80],
                      (t.customer_name or "") + ": " + text[:80],
                      data={"thread_id": str(t.pk)})
        return "human"
    d = compose(biz, agent, t, text, lang, allow_order=not comment_id)
    if d.get("order_action") == "confirm":
        return confirm_order(t, agent, lang)
    if d.get("order_action") == "cancel":
        t.order_draft = {}
        t.save(update_fields=["order_draft"])
    if d.get("risk"):
        if d.get("text"):
            send_text(t, d["text"], kind="holding", is_ai=True, comment_id=comment_id)
        _queue_approval(t, d.get("proposal", ""), d["risk"], comment_id=comment_id,
                        problems=d.get("problems"), confidence=d.get("confidence", 0.0))
        return "approval"
    return _deliver_ai(t, agent, d["text"], lang, kind=d.get("kind") or "text",
                       comment_id=comment_id, public_too=bool(comment_id))


def handle_comment(ch, e):
    from .models import Message
    if e.get("user_id") and str(e["user_id"]) == str(ch.external_id):
        return "skipped"           # the Page's own comment
    t = thread_for(ch, "comment:" + (e.get("user_id") or e.get("comment_id")), e.get("name", ""))
    text = e.get("text") or ""
    lang = bai.reply_lang(text)
    t.last_message_at = _ts(e)
    t.lang = lang
    t.save(update_fields=["last_message_at", "lang"])
    Message.objects.create(thread=t, direction="in", text=text, external_id=e["event_id"],
                           status="received", kind="comment",
                           meta={"comment_id": e.get("comment_id"), "post_id": e.get("post_id")})
    return respond(ch, t, text, lang, comment_id=e.get("comment_id", ""))


def handle_echo(ch, e):
    """A message the Page sent. Ours → already recorded. A person replying from
    Meta Business Suite → record it and HAND OVER (AI pauses on that thread)."""
    from .models import Message
    if Message.objects.filter(external_id=e["event_id"]).exists():
        return "skipped"
    app_id = str((e.get("raw") or {}).get("app_id") or "")
    if app_id and app_id == str(meta_app().get("app_id") or ""):
        return "skipped"
    t = thread_for(ch, e["user_id"])
    Message.objects.create(thread=t, direction="out", text=e.get("text") or "", is_ai=False,
                           external_id=e["event_id"], status="sent", kind="text",
                           meta={"from": "page_inbox"})
    if not t.owner_takeover:
        t.owner_takeover = True
        t.save(update_fields=["owner_takeover"])
    return "ok"


def handle_status(ch, e):
    from .models import Message
    raw = e.get("raw") or {}
    wamid = raw.get("wamid") or ""
    order = {"sent": 1, "delivered": 2, "read": 3, "failed": 9}
    st = e.get("status")
    m = Message.objects.filter(external_id=wamid).first()
    if m is not None and st in order:
        cur = order.get(m.status, 0)
        if st == "failed" or order[st] > cur:
            m.status = st
            if st == "failed":
                m.send_error = (raw.get("error") or "failed")[:200]
            m.save(update_fields=["status", "send_error"])
    charge_wa_billable(ch, e)
    return "ok"


# ===================================================================== approvals
def approve(message, text=None, actor=None):
    """Seller approves (optionally edited) → send now (billing applies)."""
    t = message.thread
    agent = agent_for(t.business)
    if message.status != "pending_approval":
        return {"ok": False, "reason": "not_pending"}
    body = (text if text is not None else message.text or "").strip()
    if not body:
        return {"ok": False, "reason": "empty"}
    edited = text is not None and text.strip() != (message.text or "").strip()
    comment_id = (message.meta or {}).get("comment_id", "")
    message.status = "approved"
    message.meta = dict(message.meta or {}, approved=True, edited=edited)
    message.save(update_fields=["status", "meta"])
    if edited:
        # the seller wrote it: a human message, not billed as an AI reply
        m = send_text(t, body, kind="text", is_ai=False, comment_id=comment_id)
        res = m.status
    else:
        res = _deliver_ai(t, agent, body, t.lang or "bn", comment_id=comment_id)
    return {"ok": res in ("ok", "sent"), "status": res}


def reject(message):
    if message.status != "pending_approval":
        return False
    message.status = "rejected"
    message.save(update_fields=["status"])
    return True


def seller_send(thread, text):
    """Seller types a reply in the app (human, not billed as AI)."""
    return send_text(thread, text, kind="text", is_ai=False)


# ===================================================================== orders
def _decrement_stock(item):
    from .models import Product, ProductVariant
    qty = int(item["qty"])
    if item.get("variant"):
        n = ProductVariant.objects.filter(product_id=item["product_id"], vkey=item["variant"],
                                          stock__gte=qty).update(stock=F("stock") - qty)
        if not n:
            return False
        Product.objects.filter(pk=item["product_id"]).update(stock=F("stock") - qty)
        return True
    return bool(Product.objects.filter(pk=item["product_id"], stock__gte=qty)
                .update(stock=F("stock") - qty))


def confirm_order(thread, agent, lang):
    """Customer said yes → create the real Order (stock reserved atomically),
    upsert the Customer, send the invoice."""
    from .models import Customer, Order
    from .logic import business_selling as selling
    biz = thread.business
    draft = dict(thread.order_draft or {})
    catalog = catalog_for(biz)
    priced = BZ.price_order(draft, catalog, delivery_for(biz))
    if not priced or BZ.missing_fields(draft):
        thread.order_draft = {}
        thread.save(update_fields=["order_draft"])
        return _deliver_ai(thread, agent, BZ.ask_missing(lang, BZ.ORDER_FIELDS), lang)
    item = {"product_id": draft["product_id"], "name": priced["product"]
            + ((" " + draft["variant_label"]) if draft.get("variant_label") else ""),
            "qty": priced["qty"], "price": str(priced["unit"]), "variant": draft.get("variant", "")}
    with transaction.atomic():
        if not _decrement_stock(item):
            transaction.set_rollback(True)
            ok = False
        else:
            ok = True
            o = Order.objects.create(
                user=biz.user, business=biz, thread=thread, customer_name=draft["name"][:120],
                customer_phone=draft["phone"], address=draft["address"], items=[item],
                total=priced["total"], delivery_charge=priced["delivery"], area=draft["area"],
                status="confirmed", payment="cod", channel=thread.channel)
    if not ok:
        fresh = BZ.price_order(draft, catalog_for(biz), delivery_for(biz))
        return _deliver_ai(thread, agent, BZ.out_of_stock_line(
            lang, priced["product"], fresh["stock"] if fresh else 0), lang)
    key = selling.normalize_phone(draft["phone"])
    if key and not Customer.objects.filter(user=biz.user, business=biz, phone_key=key).exists():
        Customer.objects.create(user=biz.user, business=biz, name=draft["name"][:120],
                                phone=draft["phone"], phone_key=key, address=draft["address"],
                                area=draft["area"])
    thread.order_draft = {}
    if not thread.customer_phone:
        thread.customer_phone = draft["phone"]
    thread.save(update_fields=["order_draft", "customer_phone"])
    inv = BZ.invoice_text(lang, {"id": o.id, "items": [item], "delivery_charge": o.delivery_charge,
                                 "total": o.total}, biz.shop_name)
    res = _deliver_ai(thread, agent, inv, lang, kind="invoice")
    if res == "ok":
        o.invoice_sent_at = timezone.now()
        o.save(update_fields=["invoice_sent_at"])
    notify_seller(biz, "orders", "নতুন অর্ডার", "New order",
                  "অর্ডার #%s — ৳%s" % (o.id, BZ._fmt_money(o.total)),
                  "Order #%s — ৳%s" % (o.id, BZ._fmt_money(o.total)),
                  data={"order_id": str(o.id)})
    return "order_created"


def record_sale(order):
    """Delivered (cash collected by the courier) → a real Sale in the books."""
    from .models import Product, Sale, SaleLine
    from .logic import business_selling as selling
    if order.sale_id or order.business is None:
        return order.sale
    lines, sub, profit = [], 0, 0
    for it in order.items or []:
        p = Product.objects.filter(pk=it.get("product_id")).first()
        unit = selling.taka_to_poisha(it.get("price") or 0)
        qty = int(it.get("qty") or 1)
        cost = selling.taka_to_poisha(p.cost_price) if p else 0
        sub += unit * qty
        profit += (unit - cost) * qty if cost else 0
        lines.append((p, it, unit, qty, cost))
    total = sub + selling.taka_to_poisha(order.delivery_charge or 0)
    from .models import Customer
    cust = Customer.objects.filter(user=order.user, business=order.business,
                                   phone_key=selling.normalize_phone(order.customer_phone)).first()
    sale = Sale.objects.create(user=order.user, business=order.business, customer=cust,
                               subtotal=sub, discount=0, total=total, paid=total, change=0,
                               due=0, profit=profit, payment_method="cash")
    for p, it, unit, qty, cost in lines:
        SaleLine.objects.create(sale=sale, product=p, product_name=(it.get("name") or "")[:160],
                                qty=qty, unit_price=unit, sell_price=unit, cost_price=cost,
                                min_price=selling.taka_to_poisha(p.min_price) if p else 0,
                                variant_key=it.get("variant") or "")
    order.sale = sale
    order.save(update_fields=["sale"])
    return sale


# ===================================================================== couriers
def courier_keys(agent, courier):
    keys = (dec(agent.courier_enc) or {}).get(courier) or {}
    if C.has_keys(courier, keys):
        return keys, "seller"
    from . import integrations
    try:
        own = integrations.get("courier_" + courier) or {}
    except Exception:
        own = {}
    if C.has_keys(courier, own):
        return own, "owner"
    return {}, ""


def save_courier_keys(agent, courier, data):
    if courier not in C.FIELDS:
        raise ValueError("unknown courier")
    cur = dec(agent.courier_enc) or {}
    row = dict(cur.get(courier) or {})
    for k in C.FIELDS[courier]:
        v = data.get(k)
        if v not in (None, ""):
            row[k] = str(v).strip()[:300]
    cur[courier] = row
    agent.courier_enc = enc(cur)
    agent.save(update_fields=["courier_enc", "updated_at"])


def courier_state(agent):
    out = {}
    for c in bai.COURIERS:
        keys, src = courier_keys(agent, c)
        out[c] = {"connected": bool(src), "source": src or None}
    return out


def book_courier(order, courier, lang="bn"):
    """Book on the courier's official merchant API. Honest: no key → nothing
    booked, the seller sees 'connect <courier> in setup'."""
    from .models import CourierShipment
    biz = order.business
    agent = agent_for(biz)
    keys, src = courier_keys(agent, courier)
    if not src:
        return {"ok": False, "error": "no_key"}
    if order.status not in ("confirmed", "packed"):
        return {"ok": False, "error": "bad_status"}
    item_qty = sum(int(i.get("qty") or 1) for i in order.items or [])
    payload = {"id": order.id, "name": order.customer_name, "phone": order.customer_phone,
               "address": order.address, "qty": item_qty, "cod": str(bai.cod_amount(
                   {"payment": order.payment, "total": str(order.total)})),
               "value": str(order.total), "area": order.area,
               "description": ", ".join(i.get("name", "") for i in order.items or [])[:200]}
    r = C.create(courier, keys, payload)
    if not r["ok"]:
        order.courier_error = r["error"][:200]
        order.save(update_fields=["courier_error"])
        return {"ok": False, "error": r["error"]}
    order.courier = courier
    order.tracking = r["tracking"][:80]
    order.consignment_id = r["consignment_id"][:80]
    order.courier_status = r["status"][:60]
    order.courier_live = True
    order.courier_error = ""
    order.status = "shipped"
    order.courier_checked_at = timezone.now()
    order.save()
    CourierShipment.objects.create(order=order, courier=courier, tracking=order.tracking,
                                   live=True, cod_amount=bai.cod_amount(
                                       {"payment": order.payment, "total": str(order.total)}))
    if order.thread_id:
        t = order.thread
        label = bai.parcel_status({"status": "shipped"}, t.lang or lang)["message"]
        send_text(t, BZ.courier_update_line(t.lang or lang, order.id, courier, order.tracking,
                                            label.split(": ", 1)[-1]), kind="text", is_ai=False)
    return {"ok": True, "tracking": order.tracking, "consignment_id": order.consignment_id}


def poll_couriers(limit=200):
    """Cron: ask the courier for every shipped parcel; on a change, update the
    order and tell the customer (delivered → a real Sale)."""
    from .models import Order
    n = 0
    qs = Order.objects.filter(status="shipped", courier_live=True).exclude(consignment_id="")
    for o in qs.select_related("business", "thread")[:limit]:
        if o.business is None:
            continue
        keys, src = courier_keys(agent_for(o.business), o.courier)
        if not src:
            continue
        r = C.status(o.courier, keys, o.consignment_id)
        o.courier_checked_at = timezone.now()
        if not r["ok"]:
            o.courier_error = r["error"][:200]
            o.save(update_fields=["courier_checked_at", "courier_error"])
            continue
        new = C.map_status(r["status"])
        changed = r["status"] != o.courier_status
        o.courier_status = r["status"][:60]
        if new != o.status and bai.can_transition(o.status, new):
            o.status = new
            if new == "delivered":
                record_sale(o)
        o.save()
        if changed and o.thread_id:
            t = o.thread
            label = bai.parcel_status({"status": o.status}, t.lang or "bn")["message"]
            send_text(t, BZ.courier_update_line(t.lang or "bn", o.id, o.courier, o.tracking,
                                                label.split(": ", 1)[-1]), kind="text",
                      is_ai=False)
        n += 1
    return n


# ===================================================================== reports
def daily_stats(business, day):
    from .models import ChatThread, Message, Order
    start = timezone.make_aware(timezone.datetime.combine(day, timezone.datetime.min.time()))
    end = start + timedelta(days=1)
    orders = Order.objects.filter(business=business, created_at__gte=start, created_at__lt=end)
    msgs = Message.objects.filter(thread__business=business, created_at__gte=start,
                                  created_at__lt=end)
    agent = agent_for(business)
    th = sa_cfg()["low_stock_default"]
    return {"day": day.isoformat(), "orders": orders.count(),
            "revenue": str(orders.exclude(status="cancelled").aggregate(s=Sum("total"))["s"] or 0),
            "messages": msgs.filter(direction="in").count(),
            "ai_replies": msgs.filter(direction="out", is_ai=True,
                                      status__in=("sent", "delivered", "read")).count(),
            "pending_approvals": Message.objects.filter(thread__business=business,
                                                        status="pending_approval").count(),
            "threads": ChatThread.objects.filter(business=business).count(),
            "low_stock": BZ.low_stock(catalog_for(business), th) if agent.low_stock_alert else []}


def run_daily_reports(now=None):
    """Cron (evening): one summary per seller per day — saved for the app and
    pushed. Idempotent per (business, day)."""
    from .models import BizAgentReport, SellerAgent
    now = now or timezone.now()
    day = timezone.localtime(now).date()
    n = 0
    for a in SellerAgent.objects.filter(daily_report=True).select_related("business",
                                                                         "business__user"):
        if not a.business.seller_channels.exists():
            continue
        stats = daily_stats(a.business, day)
        _, created = BizAgentReport.objects.update_or_create(business=a.business, day=day,
                                                             defaults={"data": stats})
        if created:
            bn, en = BZ.daily_report("bn", stats), BZ.daily_report("en", stats)
            notify_seller(a.business, "report", bn["title"], en["title"], bn["body"], en["body"])
            n += 1
    return n


def run_low_stock(now=None):
    from .models import SellerAgent
    now = now or timezone.now()
    th = sa_cfg()["low_stock_default"]
    n = 0
    for a in SellerAgent.objects.filter(low_stock_alert=True).select_related("business"):
        if a.last_low_stock_at and now - a.last_low_stock_at < timedelta(hours=24):
            continue
        items = BZ.low_stock(catalog_for(a.business), th)
        if not items:
            continue
        names = ", ".join("%s (%d)" % (x["name"], x["stock"]) for x in items[:5])
        notify_seller(a.business, "stock", "কম স্টক", "Low stock",
                      "স্টক কমে গেছে: " + names, "Running low: " + names)
        a.last_low_stock_at = now
        a.save(update_fields=["last_low_stock_at"])
        n += 1
    return n


# ===================================================================== self-test
def selftest_setup(business, secret, page_id, wa_phone_number_id):
    """Create/refresh TEST-MODE channels for the live-proof self-test. They use
    their OWN secret (never the Meta app secret) and never send to Graph."""
    from .models import SellerChannel
    out = []
    for kind, ext in ((BZ.CH_MESSENGER, page_id), (BZ.CH_WHATSAPP, wa_phone_number_id)):
        ch, _ = SellerChannel.objects.get_or_create(kind=kind, external_id=str(ext),
                                                    defaults={"business": business})
        if ch.business_id != business.pk:
            raise ValueError("that test id belongs to another business")
        ch.test_mode = True
        ch.status = "connected"
        ch.display_name = "SELFTEST"
        ch.test_secret_enc = enc({"secret": secret})
        ch.connected_at = timezone.now()
        ch.save()
        out.append(ch)
    return out


def dumps(o):
    return json.dumps(o, ensure_ascii=False, default=str)


def money(v):
    return BZ._fmt_money(v if v is not None else Decimal(0))
