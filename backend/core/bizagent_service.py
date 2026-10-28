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
MAX_INBOUND = 4096          # e2e-sales: characters kept from one customer message


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
            "low_stock_at": p.low_stock_at, "sku": p.sku, "category": p.category,
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
    # plans-v2: the AI Sales Agent is a Business feature (shop owner's plan;
    # founder and a running Business trial count). Not entitled -> no AI
    # reply (the customer gets the polite holding line, the seller is told);
    # rule replies (FAQ, price, stock, order flow) still answer for free.
    try:
        from . import entitlements_service as ES
        owner = agent.business.user
        if ES.on(owner) and not ES.allows(owner, "ai_sales_agent"):
            return (None, "plan_required")
    except Exception:
        pass
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
    # billing-v2: through the bucketed engine (row lock, owner spend order);
    # takes what the balance covers, never below zero
    from . import credits as CR
    with transaction.atomic():
        u = CR._lock(user)
        CR._settle(u, timezone.now())
        take = min(max(0, int(u.ai_credits or 0)), credits)
        if take:
            CR.spend(None, take, note=("wa_%s" % cat)[:120], _u=u)
    sa = BZ.cfg_normalize(full_cfg().get("seller_agent"))
    try:
        billing.record_cost("whatsapp", float(sa["wa_cost_bdt"].get(cat, 0)))
    except Exception:
        pass
    return take


# ===================================================================== push
def notify_seller(business, kind, title_bn, title_en, body_bn="", body_en="", data=None,
                  force=False):
    """Push to the seller. g1: inside the seller's QUIET HOURS pushes are held
    (they are in the morning summary); force=True (the morning summary
    itself) always goes."""
    from . import push
    if not force:
        try:
            from . import bizagent_g1_service as G1S
            if G1S.in_quiet(agent_for(business)):
                return
        except Exception:
            pass
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
              status_on_ok="sent", meta=None, source=None):
    """Send one message on the thread's official channel and record it.
    Honest: no token → 'queued' (needs key), outside 24 h → 'blocked', Graph
    error → 'failed' with the reason. test_mode channels never hit the network.
    g1: `source` = rule | ai | fallback | human | system (rules-vs-AI stats);
    the website widget channel stores the reply for the visitor's poll."""
    from .models import Message
    ch = thread.seller_channel
    now = timezone.now()
    m = Message(thread=thread, direction="out", text=text, is_ai=is_ai, kind=kind,
                meta=dict(meta or {}),
                reply_source=(source or ("human" if not is_ai else ""))[:12])
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
    if ch.kind == "website":
        m.status, m.external_id = status_on_ok, "web-" + uuid.uuid4().hex[:16]
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


def send_image(thread, url, caption=""):
    """g1: one product photo (+ caption) on the thread's channel. Same honesty
    rules as send_text (test channels never hit the network)."""
    from .models import Message
    ch = thread.seller_channel
    m = Message(thread=thread, direction="out", text=caption, is_ai=True, kind="image",
                meta={"image_url": url}, reply_source="rule")
    now = timezone.now()
    if ch is None:
        m.status, m.send_error = "queued", "no_channel"
    elif ch.test_mode or ch.kind == "website":
        m.status, m.external_id = "sent", "test-" + uuid.uuid4().hex[:16]
        m.meta["test_mode"] = ch.test_mode
    else:
        token = channel_token(ch)
        last_in = thread.last_inbound_at.timestamp() if thread.last_inbound_at else None
        if not token:
            m.status, m.send_error = "queued", "no_token"
        elif not bai.within_service_window(last_in, now.timestamp()):
            m.status, m.send_error = "blocked", "outside_24h_window"
        else:
            if ch.kind == BZ.CH_WHATSAPP:
                r = G.send_whatsapp_image(token, ch.external_id, thread.external_user_id, url,
                                          caption)
            else:
                r = G.send_messenger_image(token, thread.external_user_id, url,
                                           page_id=ch.external_id if ch.kind == BZ.CH_MESSENGER
                                           else "me")
            if r["ok"]:
                m.status, m.external_id = "sent", r.get("id", "")[:128]
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
    spend is still booked into AIUsage + the daily P&L ledger.

    AF-2 (Agentforce trust parity): the customer's message, the chat history
    and the shop facts go through Agent Core's trust Vault (pii=True) — the
    provider sees ⟦PHONE_1⟧ / ⟦EMAIL_1⟧ / ⟦NID_1⟧ / ⟦ACCT_1⟧, never the raw
    value; the router puts the originals back in the reply BEFORE the
    floor-price / number post-check runs on it. `pii_tokens` = how many values
    were masked (logged on the reply, never the values)."""
    from . import ai
    from .agentcore import trust as _T
    if not ai.key_present():
        return None
    meta = {}
    vault = _T.Vault()
    try:
        task = BZ.llm_task(ctx, lang, tone)
        if ctx.get("style"):
            task += ("\n\nTONE ONLY (the owner's own past wording — copy the style, never "
                     "facts or numbers from it):\n" + str(ctx["style"])[:400])
        out, _cost = ai.generate(task=task, data=text, tier="cheap",
                                 max_tokens=300, feature="bizagent.reply", user=None,
                                 history=history, pii=vault, out_meta=meta)
    except ai.AIUnavailable:
        return None
    d = BZ.parse_llm(out)
    # a JSON reply may carry the token \u-escaped ("\u27e6EMAIL_1\u27e7"): the
    # router's unmask saw no token, the parsed text has it -> unmask again
    d["text"] = vault.unmask(d.get("text") or "")
    d["pii_tokens"] = int(meta.get("pii_masked") or 0)
    return d


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


def _offer_in(text, list_price=None):
    """The customer's offered unit price (int) or None — see BZ.find_offer
    (phone numbers, quantities, sizes and decimal tails are handled)."""
    v = BZ.find_offer(text, list_price)
    return int(v) if v is not None else None


def _bargain(thread, text, lang, matched, intent):
    """e2e-sales: bargaining runs BEFORE the order flow and the rule layer
    whenever the customer names a price for a product, in any wording
    ("800 taka te diben?", "৮০০ টাকায় দিবেন?", "last price 900 hobe?",
    "1050 e dile nibo") — not only when the intent classifier said
    'bargain'. Returns the negotiate() dict (+ the offer) or None."""
    if not matched:
        return None
    p = matched[0]
    offer = _offer_in(text, p["price"])
    if not offer:
        return None
    if intent != "bargain" and not BZ.bargain_cue(text):
        return None
    # an unset minimum (0) means NO discount: the floor is the list price
    floor = p["min_price"] if (BZ._dec(p["min_price"]) or 0) > 0 else p["price"]
    neg = bai.negotiate(offer, {"name": p["name"], "price": p["price"],
                                "min_price": floor}, lang=lang)
    neg["offer_value"] = offer
    neg["product"] = p
    return neg


def compose(business, agent, thread, text, lang, *, allow_order=True, post_id=""):
    """Decide the reply. Returns dict:
      {"text", "kind", "risk", "proposal", "confidence", "order_action", "source"}
    risk != None → the customer gets `text` (an honest holding line) and the
    seller gets `proposal` to approve/edit/reject.
    g1: source = rule (deterministic: order flow, bargaining arithmetic, the
    RULE-FIRST layer — instant, cost 0, no credit) | ai (an LLM call — the only
    replies that use a plan reply or credits) | fallback (no key: mock)."""
    from . import bizagent_g1_service as G1S
    d = _compose(business, agent, thread, text, lang, allow_order=allow_order, post_id=post_id,
                 G1S=G1S)
    d.setdefault("source", "rule")
    return d


def _compose(business, agent, thread, text, lang, *, allow_order, post_id, G1S):
    catalog = catalog_for(business)
    matched = BZ.match_products(text, catalog)
    intent = bai.classify_intent(text)
    hours = BZ.hours_text(agent.hours)

    # AF-4 INBOUND guard (before anything, 0 credits): abuse / threat / hate /
    # sexual text -> one calm fixed line, the seller is called in, the AI
    # cools down in this chat (_send_reply). A rude insult goes the
    # complaint way. Never mirrored; only the score is stored.
    from . import ai_guard
    tox = ai_guard.toxicity(text)
    if tox["severity"] >= 2:
        return {"text": BZ.holding_message(lang, BZ.RISK_ABUSE), "kind": "holding",
                "risk": BZ.RISK_ABUSE, "proposal": bai.handoff_message(lang, bai.HANDOFF_ABUSE),
                "confidence": 0.0, "source": "rule", "rule": "abuse",
                "meta": {"tox": ai_guard.tox_log(tox)}}
    if tox["severity"] == 1:
        return {"text": BZ.holding_message(lang, BZ.RISK_COMPLAINT, hours), "kind": "holding",
                "risk": BZ.RISK_COMPLAINT, "proposal": bai.handoff_message(lang, bai.HANDOFF_ANGRY),
                "confidence": 0.0, "source": "rule", "rule": "insult",
                "meta": {"tox": ai_guard.tox_log(tox)}}

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

    # ---- booking-bot (flag booking_bot): appointment chats — REAL free slots
    # from the business' calendar only, rule reply (no AI, cost 0) ----
    from . import booking_service as BKS
    bk = BKS.bot_reply(business, thread, text, lang)
    if bk:
        return bk

    # ---- bargaining: arithmetic only, the minimum price is never crossed ----
    draft = dict(thread.order_draft or {})
    neg = None
    if not (allow_order and draft.get("state") == "awaiting_confirm"
            and (BZ.is_yes(text) or BZ.is_no(text))):
        neg = _bargain(thread, text, lang, matched, intent)
    offer_decision = neg.get("action") if neg else None
    proposal = ""
    neg_line = ""
    if neg and offer_decision in (bai.ACTION_ACCEPT, bai.ACTION_COUNTER):
        p = neg["product"]
        if neg.get("price") is not None:
            draft = dict(thread.order_draft or {})
            draft["agreed"] = {"product_id": p["id"], "price": str(neg["price"])}
            draft.pop("state", None)
            if draft.get("product_id") != p["id"]:
                # the agreed product is THE product of a later "order korbo"
                draft.update({"product_id": p["id"], "product": p["name"]})
                draft.pop("variant", None)
                draft.pop("variant_label", None)
            thread.order_draft = draft
            thread.save(update_fields=["order_draft"])
        neg_line = neg.get("message") or neg.get("text") or ""
        if not (allow_order and (intent == "order" or draft.get("active"))):
            return {"text": neg_line, "kind": "text", "risk": None, "confidence": 1.0,
                    "extra": [neg.get("price"), neg.get("counter"), neg["offer_value"]],
                    "rule": "bargain"}
    elif neg:
        # below the minimum → the seller decides; the customer gets the honest
        # line. The PROPOSAL is what the customer would receive on an unedited
        # Approve, so it never contains the minimum (only the list price); the
        # seller sees the "below minimum" chip + the customer's own words.
        p = neg["product"]
        risk = BZ.RISK_BELOW_MIN
        lp = BZ._fmt_money(p["price"])
        return {"text": BZ.holding_message(lang, risk, hours), "kind": "holding", "risk": risk,
                "proposal": bai.pick(
                    lang, "দুঃখিত, %s ৳%s-এ দেওয়া সম্ভব নয়। এর দাম ৳%s।" % (p["name"], neg["offer_value"], lp),
                    "Sorry, we can't do %s at ৳%s. The price is ৳%s." % (p["name"], neg["offer_value"], lp)),
                "confidence": 0.0, "rule": "bargain"}

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
        wants_order = intent == "order" or draft.get("active") or bool(neg_line) or (
            BZ.find_phone(text) and (matched or draft.get("product")))
        if wants_order:
            draft = BZ.extract_order(text, draft, catalog)
            draft["active"] = True
            draft.pop("state", None)
            thread.order_draft = draft
            thread.save(update_fields=["order_draft"])
            pre = (neg_line + "\n") if neg_line else ""
            if draft.get("product"):
                priced = G1S.price_for(draft, catalog, business, agent)
                if priced and not priced["stock_ok"]:
                    return {"text": BZ.out_of_stock_line(lang, priced["product"], priced["stock"]),
                            "kind": "text", "risk": None, "confidence": 1.0}
            miss = BZ.missing_fields(draft)
            if miss:
                return {"text": pre + BZ.ask_missing(lang, miss, draft.get("phone_invalid")),
                        "kind": "order", "risk": None, "confidence": 1.0}
            priced = G1S.price_for(draft, catalog, business, agent)
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
            extra_lines, extra_nums = G1S.summary_extras(lang, priced, business)
            if extra_lines:
                summary = summary + "\n" + "\n".join(extra_lines)
            if big:
                return {"text": BZ.holding_message(lang, BZ.RISK_BIG_ORDER, hours),
                        "kind": "holding", "risk": BZ.RISK_BIG_ORDER, "proposal": summary,
                        "confidence": 1.0}
            return {"text": pre + summary, "kind": "order", "risk": None, "confidence": 1.0,
                    "extra": [priced["subtotal"], priced["total"], priced["unit"]] + extra_nums}

    # ---- g1 RULE-FIRST: FAQ / price / stock / sizes / delivery / hours /
    # payment / returns / order status from the seller's own data — no AI ----
    if not offer_decision:
        r = G1S.rule_answer(business, agent, thread, text, lang, catalog, post_id)
        if r:
            return r

    risk = BZ.pre_risk(text, intent, matched, offer_decision)
    if risk:
        if not proposal:
            proposal = bai.handoff_message(lang, {BZ.RISK_COMPLAINT: bai.HANDOFF_ANGRY,
                                                  BZ.RISK_REFUND: bai.HANDOFF_REFUND}.get(
                risk, "low_confidence"))
        return {"text": BZ.holding_message(lang, risk, hours), "kind": "holding", "risk": risk,
                "proposal": proposal, "confidence": 0.0}

    # ---- biz-v2: per-business daily cap on PAID AI calls. Over the cap the
    # customer gets the honest "I'll ask the owner" line (never invented). ----
    from . import ai as _ai
    from . import bizagent_guard as GD
    if _ai.key_present() and not GD.ai_budget_ok(agent):
        GD.note_cap_hit(agent, "daily_ai", thread)
        return {"text": BZ.holding_message(lang, BZ.RISK_LOW_CONF, hours), "kind": "holding",
                "risk": "daily_ai_cap", "proposal": "", "confidence": 0.0, "source": "rule"}

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
    src = "ai" if used_ai else "fallback"
    # AF-2 / AF-4: a vault token the router could not put back (the model
    # damaged or invented one) or toxic wording -> never sent; the seller
    # writes the reply (the toxic draft is NOT offered for one-tap approve).
    from .agentcore import trust as _T
    tox_out = ai_guard.toxicity(reply)
    left = _T.leftover_tokens(reply)
    if tox_out["toxic"] or left:
        return {"text": BZ.holding_message(lang, BZ.RISK_UNSAFE, hours), "kind": "holding",
                "risk": BZ.RISK_UNSAFE, "proposal": "" if tox_out["toxic"] else
                _T.TOKEN_RX.sub("…", reply), "confidence": conf,
                "problems": ([{"type": "toxic", "value": tox_out["category"]}] if tox_out["toxic"]
                             else []) + [{"type": "pii_token", "value": "token"} for _ in left],
                "used_ai": used_ai, "source": src,
                "meta": {"tox": ai_guard.tox_log(tox_out)} if tox_out["toxic"] else {}}
    # aieval: price + delivery / qty x price totals of the asked-about product
    # are arithmetic, not inventions (they were wrongly held before).
    problems = BZ.check_numbers(reply, ctx, text,
                                extra=ai_guard.price_totals(matched, ctx.get("delivery")))
    # aieval guard: refund promises and "I am human" claims are the owner's
    # call / never true — they go to the seller like an unverified number.
    problems += [{"type": "refund_promise", "value": w} for w in ai_guard.refund_promises(reply)]
    problems += [{"type": "human_claim", "value": w} for w in ai_guard.human_claims(reply)]
    echo = BZ.offer_echo(reply, text, matched)
    if echo:
        # the AI repeated a below-minimum number the customer wrote ("ok, 800
        # te dibo") — never sent; the seller decides
        return {"text": BZ.holding_message(lang, BZ.RISK_BELOW_MIN, hours), "kind": "holding",
                "risk": BZ.RISK_BELOW_MIN, "proposal": reply, "confidence": conf,
                "problems": [{"type": "below_min_echo", "value": v} for v in echo],
                "used_ai": used_ai, "source": src}
    if problems:
        return {"text": BZ.holding_message(lang, BZ.RISK_NUMBERS, hours), "kind": "holding",
                "risk": BZ.RISK_NUMBERS, "proposal": reply, "confidence": conf,
                "problems": problems, "used_ai": used_ai, "source": src}
    if not reply or conf < bai.HANDOFF_CONFIDENCE:
        return {"text": BZ.holding_message(lang, BZ.RISK_LOW_CONF, hours), "kind": "holding",
                "risk": BZ.RISK_LOW_CONF, "proposal": reply, "confidence": conf,
                "used_ai": used_ai, "source": src}
    if agent.approve_all:
        return {"text": "", "kind": "text", "risk": BZ.RISK_APPROVE_ALL, "proposal": reply,
                "confidence": conf, "used_ai": used_ai, "source": src}
    out = {"text": reply, "kind": "text", "risk": None, "confidence": conf, "used_ai": used_ai,
           "source": src}
    if d.get("pii_tokens"):
        out["meta"] = {"pii_masked": int(d["pii_tokens"])}     # a count, never the values
    return out


# ===================================================================== handlers
def handoff_card(thread, risk, problems=None):
    """AF-10: the 3-line rule-made handoff summary (bn + en, contacts partly
    hidden, 0 credits) — None if it cannot be built (never blocks a handoff)."""
    from .logic import bizagent_handoff as HC
    try:
        rows = list(thread.messages.exclude(status="pending_approval")
                    .order_by("-created_at", "-id")[:12])
        msgs = [{"direction": m.direction, "text": m.text} for m in reversed(rows)]
        return HC.build(msgs, catalog_for(thread.business), thread.order_draft or {}, risk,
                        problems)
    except Exception:  # noqa: BLE001
        log.exception("bizagent: handoff card failed for thread %s", thread.pk)
        return None


def _queue_approval(thread, proposal, risk, *, comment_id="", problems=None, confidence=0.0,
                    source="ai", meta=None):
    from .models import Message
    extra = {k: v for k, v in (meta or {}).items() if k in ("tox", "rule")}
    meta = {"comment_id": comment_id} if comment_id else {"problems": problems or []}
    meta["source"] = source
    meta.update(extra)
    card = handoff_card(thread, risk, problems)
    if card:
        meta["card"] = card
    m = Message.objects.create(
        thread=thread, direction="out", text=proposal or "", is_ai=True,
        status="pending_approval", risk_reason=risk, needs_human=True,
        handoff_reason=risk, confidence=confidence, kind="text", meta=meta)
    body_bn, body_en = ("একটি AI উত্তর আপনার অনুমোদনের অপেক্ষায়।",
                        "An AI reply is waiting for your approval.")
    if card:
        body_bn, body_en = "\n".join(card["lines"]["bn"]), "\n".join(card["lines"]["en"])
    notify_seller(thread.business, "approvals",
                  "অনুমোদন দরকার", "Approval needed", body_bn, body_en,
                  data={"thread_id": str(thread.pk), "message_id": str(m.pk)})
    return m


ABUSE_COOLDOWN_MIN = 30


def _abuse_cooldown(thread, agent):
    """AF-4: after abuse the AI stays quiet in THIS chat (at least 30 min or
    the seller's resume time, whichever is longer); the seller was called in.
    Further messages meanwhile reach the seller as 'New message' pushes."""
    from .models import ChatThread
    from .logic import bizagent_g1 as G1
    mins = max(ABUSE_COOLDOWN_MIN, G1.clamp_int(agent.resume_minutes, 1, G1.MAX_RESUME_MIN,
                                                G1.DEFAULT_RESUME_MIN))
    until = timezone.now() + timedelta(minutes=mins)
    ChatThread.objects.filter(pk=thread.pk).update(ai_paused_until=until, paused_by="abuse")
    thread.ai_paused_until, thread.paused_by = until, "abuse"
    return until


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


def _deliver_ai(thread, agent, text, lang, kind="text", comment_id="", public_too=False,
                source="ai", meta=None, extra_credits=0, cost_bdt=0.0, prepaid=False):
    """Pay for + send one agent reply (disclosure on the first AI reply).
    g1: ONLY an LLM reply (source 'ai') uses a plan reply / credits; a rule
    reply (FAQ, price, stock, order flow, …) is instant and costs 0.
    extra_credits / cost_bdt = an already-charged vision/voice call (stored
    on the row for the agent report + Profit Guard). prepaid=True: the reply
    IS that paid vision answer (one charge, not two)."""
    if source == "ai" and not prepaid:
        via, charged = consume_reply(agent)
        if via is None:
            return _out_of_replies(thread, agent, lang, charged, comment_id=comment_id)
    else:
        via, charged = "free", 0
    first = not thread.ai_disclosed
    body = BZ.with_disclosure(lang, text, first)
    m = send_text(thread, body, kind=kind, is_ai=True, comment_id=comment_id,
                  meta=meta, source=source)
    if m.status in ("failed", "blocked", "queued"):
        if source == "ai" and not prepaid:
            refund_reply(agent, via, charged)
        if m.status == "failed":
            notify_seller(thread.business, "errors", "মেসেজ পাঠানো যায়নি",
                          "A message could not be sent", m.send_error, m.send_error,
                          data={"thread_id": str(thread.pk)})
        return m.status
    m.meta["billed"] = via
    m.credits = (int(charged or 0) if via == "credits" else 0) + int(extra_credits or 0)
    m.cost_bdt = float(cost_bdt or 0) + (reply_cost_bdt() if source == "ai" and not prepaid
                                         else 0.0)
    m.save(update_fields=["meta", "credits", "cost_bdt"])
    if first:
        thread.ai_disclosed = True
        thread.save(update_fields=["ai_disclosed"])
    if public_too and comment_id and sa_cfg()["public_comment_reply"]:
        send_text(thread, BZ.comment_public_reply(lang), kind="comment", is_ai=True,
                  comment_id=comment_id, public=True)
    return "ok"


def reply_cost_bdt():
    try:
        return round(BZ.reply_cost_bdt(full_cfg()), 4)
    except Exception:
        return 0.0


def handle_message(ch, e):
    from .models import Message
    if e.get("event_id") and Message.objects.filter(thread__seller_channel=ch,
                                                    external_id=e["event_id"]).exists():
        return "skipped"
    t = thread_for(ch, e["user_id"], e.get("name", ""))
    # e2e-sales: one chat message is at most MAX_INBOUND characters (abuse /
    # cost guard — the AI never gets a 20 000-character "message")
    text = (e.get("text") or "")[:MAX_INBOUND]
    atts = [a for a in (e.get("attachments") or []) if isinstance(a, dict)]
    if atts and text in ("[attachment]", "[image]", "[audio]"):
        text = ""
    lang = BZ.sticky_lang(text, t.lang) if text else (t.lang or "bn")
    at = _ts(e)
    t.last_inbound_at = at
    t.last_message_at = at
    t.lang = lang
    t.save(update_fields=["last_inbound_at", "last_message_at", "lang"])
    image = next((a for a in atts if a.get("type") == "image"), None)
    audio = next((a for a in atts if a.get("type") == "audio"), None)
    kind = "image" if image else ("voice" if audio else "text")
    meta = {"attachments": [{"type": a.get("type")} for a in atts]} if atts else {}
    if text:
        # AF-4: the score only (never the words) on the inbound row
        from . import ai_guard
        tx = ai_guard.toxicity(text)
        if tx["toxic"]:
            meta = dict(meta, tox=ai_guard.tox_log(tx))
    inbound = Message.objects.create(thread=t, direction="in", text=text or ("[%s]" % kind if atts else ""),
                                     external_id=e.get("event_id", ""), status="received",
                                     kind=kind, meta=meta)
    # retention1: a reply to an automated message counts as "replied"; a STOP
    # here opts the customer out of every retention automation of the shop
    try:
        from . import retention_service as RS
        RS.on_inbound(t, text)
    except Exception:
        pass
    # g1: opt-out of follow-ups ("stop") is honoured at once
    from .logic import bizagent_g1 as G1
    if text and G1.is_opt_out(text):
        t.opted_out = True
        t.save(update_fields=["opted_out"])
        from . import booking_service as BKS
        BKS.note_chat_stop(t)          # booking-bot: no more booking reminders
        send_text(t, G1.opt_out_ack(lang), kind="text", is_ai=True, source="system")
        return "opted_out"
    if e.get("cart"):
        return _handle_cart(ch, t, e["cart"], text, lang, inbound)
    media = None
    if image or audio:
        media = {"att": image or audio, "type": "image" if image else "audio",
                 "inbound_id": inbound.pk}
    return respond(ch, t, text, lang, media=media, inbound=inbound)


def _handle_cart(ch, t, cart, text, lang, inbound):
    """e2e-sales: a WhatsApp catalog cart (type=order). ONE known product →
    it becomes the order draft (our catalog price, the cart's qty) and the
    normal order flow asks for name / phone / address and the "yes". Several
    products or an unknown retailer id → the customer gets an honest holding
    line and the seller gets the cart to handle (never guessed)."""
    lines, unknown = BZ.resolve_cart(cart, catalog_for(ch.business))
    note = "" if text == "[order]" else text
    if not note:
        lang = t.lang or "bn"
    names = ", ".join("%s × %d" % (r["product"]["name"], r["qty"]) for r in lines)
    from .models import Message
    Message.objects.filter(pk=inbound.pk).update(
        text=("[order] " + (names or ", ".join(unknown)))[:MAX_INBOUND],
        kind="order", meta=dict(inbound.meta or {}, cart=cart[:20]))
    if len(lines) == 1 and not unknown:
        p, qty = lines[0]["product"], lines[0]["qty"]
        draft = dict(t.order_draft or {})
        draft.pop("state", None)
        if draft.get("product_id") != p["id"]:
            draft.pop("variant", None)
            draft.pop("variant_label", None)
        draft.update({"product_id": p["id"], "product": p["name"], "qty": qty,
                      "active": True, "source": "wa_cart"})
        t.order_draft = draft
        t.save(update_fields=["order_draft"])
        return respond(ch, t, note or "order", lang, inbound=inbound)
    risk = BZ.RISK_UNKNOWN_PRODUCT if unknown else BZ.RISK_LOW_CONF
    proposal = bai.pick(lang, "গ্রাহক WhatsApp ক্যাটালগ থেকে কার্ট পাঠিয়েছেন: ",
                        "The customer sent a WhatsApp catalog cart: ") + \
        (names or "") + ((" | ? " + ", ".join(unknown)) if unknown else "")
    preset = {"text": BZ.holding_message(lang, risk, BZ.hours_text(agent_for(ch.business).hours)),
              "kind": "holding", "risk": risk, "proposal": proposal[:1000],
              "confidence": 0.0, "source": "rule", "rule": "wa_cart"}
    return respond(ch, t, note, lang, inbound=inbound, preset=preset)


def _media_bytes(ch, att):
    from . import bizagent_media as M
    return M.fetch_attachment(ch, att, channel_token(ch) if not ch.test_mode else "")


def respond(ch, t, text, lang, comment_id="", *, media=None, inbound=None, resumed=False,
            post_id="", preset=None):
    """Decide + send ONE reply for the customer's latest message.
    g1: who replies is decided first (business mode, per-chat toggle, the
    human pause); the reply runs under a per-chat lease so two workers can
    never answer the same chat at once; if a person replied while we were
    composing, our reply is dropped (never two replies at once)."""
    from . import bizagent_g1_service as G1S
    from .models import Message
    cfg = sa_cfg()
    biz = ch.business
    agent = agent_for(biz)
    if _channel_off(ch, cfg):
        return "channel_off"
    # biz-v2: a takeover the owner left idle past the timeout → agent resumes
    from . import bizagent_guard as GD
    GD.maybe_auto_handback(agent, t)
    allowed, why = G1S.ai_state(agent, t)
    if not allowed:
        notify_seller(biz, "inbox", "নতুন মেসেজ", "New message",
                      (t.customer_name or "") + ": " + (text or "[media]")[:80],
                      (t.customer_name or "") + ": " + (text or "[media]")[:80],
                      data={"thread_id": str(t.pk)})
        return "paused" if why == "paused" else "human"
    # biz-v2: per-chat daily cap + burst limiter (Asalify-proven anti-loop)
    capped = GD.gate(agent, t)
    if capped:
        return capped
    if not G1S.acquire(t):
        # another worker is replying in this chat: it picks this message up
        if inbound is not None:
            inbound.meta = dict(inbound.meta or {}, deferred=True)
            inbound.save(update_fields=["meta"])
        return "deferred"
    started = timezone.now()
    try:
        if preset is not None:
            res = _send_reply(t, agent, preset, lang, comment_id, started)
        else:
            res = _respond_locked(ch, t, biz, agent, text, lang, comment_id, media, started,
                                  post_id=post_id)
        # a message that arrived while we held the lease → answer the newest one
        for _ in range(2):
            later = t.messages.filter(direction="in", created_at__gte=started,
                                      meta__deferred=True).order_by("-created_at", "-id").first()
            if later is None:
                break
            for dm in Message.objects.filter(thread=t, direction="in", meta__deferred=True):
                dm.meta = {k: v for k, v in (dm.meta or {}).items() if k != "deferred"}
                dm.meta["deferred_done"] = True
                dm.save(update_fields=["meta"])
            started = timezone.now()
            res = _respond_locked(ch, t, biz, agent, later.text, bai.reply_lang(later.text),
                                  "", None, started)
        return res
    finally:
        G1S.release(t)


def _respond_locked(ch, t, biz, agent, text, lang, comment_id, media, started, post_id=""):
    from . import bizagent_g1_service as G1S
    d = None
    if media and media["type"] == "audio":
        data, mime, err = _media_bytes(ch, media["att"])
        heard, info = ("", {"error": err})
        if data:
            heard, info = G1S.voice_text(biz, agent, t, data, mime, lang)
        if not heard:
            notify_seller(biz, "inbox", "ভয়েস মেসেজ", "Voice message",
                          "একজন গ্রাহক ভয়েস মেসেজ পাঠিয়েছেন — শুনে উত্তর দিন।",
                          "A customer sent a voice message — please listen and reply.",
                          data={"thread_id": str(t.pk)})
            return _send_reply(t, agent, {"text": G1S.voice_fallback_line(lang), "kind": "holding",
                                          "source": "rule", "rule": "voice_unavailable",
                                          "meta": {"voice_error": info.get("error", "")}},
                               lang, comment_id, started)
        from .models import Message
        Message.objects.filter(pk=media["inbound_id"]).update(
            text=heard[:2000], meta={"voice": True, "transcribed": True,
                                     "attachments": [{"type": "audio"}]})
        lang = bai.reply_lang(heard)
        text = heard
        d = compose(biz, agent, t, text, lang, allow_order=not comment_id, post_id=post_id)
        d["extra_credits"] = info.get("charged", 0)
        d["cost_bdt"] = info.get("cost_bdt", 0.0)
        d.setdefault("meta", {})["voice"] = True
    elif media and media["type"] == "image":
        data, mime, err = _media_bytes(ch, media["att"])
        if not data:
            d = {"text": BZ.holding_message(lang, BZ.RISK_UNKNOWN_PRODUCT), "kind": "holding",
                 "risk": BZ.RISK_UNKNOWN_PRODUCT, "source": "rule", "confidence": 0.0,
                 "proposal": bai.pick(lang, "গ্রাহক একটি ছবি পাঠিয়েছেন (খোলা যায়নি) — দেখে উত্তর দিন।",
                                      "The customer sent a photo (could not be opened) — please reply."),
                 "meta": {"image": True, "fetch_error": err}}
        else:
            d = G1S.compose_image(biz, agent, t, data, mime, text, lang)
            d["extra_credits"] = d.pop("credits", 0)
    else:
        d = compose(biz, agent, t, text, lang, allow_order=not comment_id, post_id=post_id)
    return _send_reply(t, agent, d, lang, comment_id, started)


def _send_reply(t, agent, d, lang, comment_id, started):
    from . import bizagent_g1_service as G1S
    t.refresh_from_db(fields=["owner_takeover", "ai_paused_until", "order_draft"])
    if G1S.human_replied_since(t, started) or not G1S.ai_state(agent, t)[0]:
        return "human_replied"          # a person answered meanwhile: stay quiet
    if d.get("order_action") == "confirm":
        return confirm_order(t, agent, lang)
    if d.get("order_action") == "cancel":
        t.order_draft = {}
        t.save(update_fields=["order_draft"])
    meta = dict(d.get("meta") or {})
    if d.get("rule"):
        meta["rule"] = d["rule"]
    src = d.get("source") or "rule"
    if not d.get("risk") and src == "ai" and d.get("text"):
        # AF-4 last gate: no AI-made text reaches a customer with abusive /
        # hateful / threatening / sexual wording, whatever path made it
        from . import ai_guard
        tx = ai_guard.toxicity(d["text"])
        if tx["toxic"]:
            meta["tox"] = ai_guard.tox_log(tx)
            d = dict(d, risk=BZ.RISK_UNSAFE, proposal="", kind="holding",
                     problems=[{"type": "toxic", "value": tx["category"]}],
                     text=BZ.holding_message(lang, BZ.RISK_UNSAFE))
    if d.get("risk"):
        if d.get("text"):
            send_text(t, d["text"], kind="holding", is_ai=True, comment_id=comment_id,
                      meta=meta, source="system")
        _queue_approval(t, d.get("proposal", ""), d["risk"], comment_id=comment_id,
                        problems=d.get("problems"), confidence=d.get("confidence", 0.0),
                        source=src, meta=meta)
        if d["risk"] == BZ.RISK_ABUSE:
            _abuse_cooldown(t, agent)
        return "approval"
    res = _deliver_ai(t, agent, d["text"], lang, kind=d.get("kind") or "text",
                      comment_id=comment_id, public_too=bool(comment_id), source=src,
                      meta=meta, extra_credits=d.get("extra_credits", 0),
                      cost_bdt=d.get("cost_bdt", 0.0), prepaid=bool(d.get("charged_vision")))
    if res == "ok" and d.get("photos"):
        G1S.send_photos(t, d["photos"], lang)
    return res


def handle_comment(ch, e):
    from .models import Message
    if e.get("user_id") and str(e["user_id"]) == str(ch.external_id):
        return "skipped"           # the Page's own comment
    agent = agent_for(ch.business)
    t = thread_for(ch, "comment:" + (e.get("user_id") or e.get("comment_id")), e.get("name", ""))
    text = e.get("text") or ""
    lang = bai.reply_lang(text)
    t.last_message_at = _ts(e)
    t.lang = lang
    t.save(update_fields=["last_message_at", "lang"])
    Message.objects.create(thread=t, direction="in", text=text, external_id=e["event_id"],
                           status="received", kind="comment",
                           meta={"comment_id": e.get("comment_id"), "post_id": e.get("post_id")})
    if not agent.comment_dm:
        return "comment_dm_off"
    # Meta rule: ONE private reply per comment (Messenger/IG inbox)
    if Message.objects.filter(thread__seller_channel=ch, direction="out",
                              meta__comment_id=e.get("comment_id", "")).exists():
        return "skipped"
    return respond(ch, t, text, lang, comment_id=e.get("comment_id", ""),
                   post_id=e.get("post_id", ""))


def handle_echo(ch, e):
    """A message the Page sent. Ours → already recorded. A person replying
    from Meta Business Suite / the WhatsApp Business app → record it and
    PAUSE the AI in that chat only; it resumes after the seller's timeout
    (default 15 min) if the customer is still waiting (g1 correction:
    24/7 by default, human takeover any time)."""
    from . import bizagent_g1_service as G1S
    from .models import Message
    if Message.objects.filter(external_id=e["event_id"]).exists():
        return "skipped"
    app_id = str((e.get("raw") or {}).get("app_id") or "")
    if app_id and app_id == str(meta_app().get("app_id") or ""):
        return "skipped"
    t = thread_for(ch, e["user_id"])
    Message.objects.create(thread=t, direction="out", text=e.get("text") or "", is_ai=False,
                           external_id=e["event_id"], status="sent", kind="text",
                           reply_source="human", meta={"from": "page_inbox"})
    G1S.pause_for_human(t, "echo")
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
    """Seller approves (optionally edited) → send now. An unedited LLM draft
    is billed as an AI reply; an unedited rule proposal is free; an edited
    text is the seller's own (human) message and pauses the AI in that chat."""
    from . import bizagent_g1_service as G1S
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
        m = send_text(t, body, kind="text", is_ai=False, comment_id=comment_id, source="human")
        G1S.pause_for_human(t, "app", agent)
        res = m.status
    else:
        src = (message.meta or {}).get("source") or "ai"
        res = _deliver_ai(t, agent, body, t.lang or "bn", comment_id=comment_id,
                          source="ai" if src == "ai" else "rule")
    return {"ok": res in ("ok", "sent"), "status": res}


def reject(message):
    if message.status != "pending_approval":
        return False
    message.status = "rejected"
    message.save(update_fields=["status"])
    return True


def seller_send(thread, text):
    """Seller/staff types a reply in the app (human, not billed as AI). g1:
    the AI pauses in THIS chat for the resume timeout."""
    from . import bizagent_g1_service as G1S
    from . import bizagent_guard as GD
    m = send_text(thread, text, kind="text", is_ai=False, source="human")
    if m.status in ("sent", "queued"):
        G1S.pause_for_human(thread, "app")
        GD.touch_takeover(thread)
    GD.audit(thread.business, "owner_reply", thread=thread, status=m.status)
    return m


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
    """Customer said yes → create the real Order (stock reduced atomically),
    upsert the Customer, send the invoice with the order number (+ one polite
    upsell), optionally book the courier. COD by default; a payment
    screenshot only ever makes it payment-PENDING (the owner verifies)."""
    from . import bizagent_g1_service as G1S
    from .models import Customer, Order
    from .logic import business_selling as selling
    biz = thread.business
    draft = dict(thread.order_draft or {})
    catalog = catalog_for(biz)
    priced = G1S.price_for(draft, catalog, biz, agent)
    if not priced or BZ.missing_fields(draft):
        thread.order_draft = {}
        thread.save(update_fields=["order_draft"])
        return _deliver_ai(thread, agent, BZ.ask_missing(lang, BZ.ORDER_FIELDS), lang,
                           source="rule")
    item = {"product_id": draft["product_id"], "name": priced["product"]
            + ((" " + draft["variant_label"]) if draft.get("variant_label") else ""),
            "qty": priced["qty"], "price": str(priced["unit"]), "variant": draft.get("variant", "")}
    from . import bizagent_guard as GD
    image_draft = GD.open_draft(thread)     # biz-v2: a photo draft becomes THE order
    fields = dict(customer_name=draft["name"][:120], customer_phone=draft["phone"],
                  address=draft["address"], items=[item], total=priced["total"],
                  delivery_charge=priced["delivery"], area=draft["area"], status="confirmed",
                  payment="cod", channel=thread.channel, via_agent=True,
                  payment_status="pending_verification" if draft.get("payment_proof") else "")
    with transaction.atomic():
        if not _decrement_stock(item):
            transaction.set_rollback(True)
            ok = False
        else:
            ok = True
            if image_draft is not None:
                o = image_draft
                for k, v in fields.items():
                    setattr(o, k, v)
                o.save()
            else:
                o = Order.objects.create(user=biz.user, business=biz, thread=thread, **fields)
    if not ok:
        fresh = BZ.price_order(draft, catalog_for(biz), delivery_for(biz))
        return _deliver_ai(thread, agent, BZ.out_of_stock_line(
            lang, priced["product"], fresh["stock"] if fresh else 0), lang, source="rule")
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
    if o.payment_status == "pending_verification":
        inv += "\n" + bai.pick(lang, "আপনার পাঠানো পেমেন্ট স্ক্রিনশট দোকানের মালিক যাচাই করবেন; যাচাইয়ের আগে এটি পরিশোধিত ধরা হবে না।",
                               "The owner will verify the payment screenshot you sent; until then it is not treated as paid.")
    up = G1S.upsell_text(agent, thread, catalog, draft["product_id"], lang)
    if up:
        inv += "\n" + up
    res = _deliver_ai(thread, agent, inv, lang, kind="invoice", source="rule",
                      meta={"order_id": o.id, "rule": "order_confirmed"})
    if res == "ok":
        o.invoice_sent_at = timezone.now()
        o.save(update_fields=["invoice_sent_at"])
    notify_seller(biz, "orders", "নতুন অর্ডার", "New order",
                  "অর্ডার #%s — ৳%s" % (o.id, BZ._fmt_money(o.total)),
                  "Order #%s — ৳%s" % (o.id, BZ._fmt_money(o.total)),
                  data={"order_id": str(o.id)})
    G1S.auto_courier(o, agent, thread, lang)
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
            "low_stock": BZ.low_stock(catalog_for(business), th) if agent.low_stock_alert else [],
            # AF-9: chats of 3-10 days ago (their 72 h window has closed)
            "resolution_7d": resolution_stats(business, timezone.now() - timedelta(days=10),
                                              timezone.now() - timedelta(days=3))}


def resolution_stats(business, since, until, now=None, limit=2000):
    """AF-9: resolution / deflection / handoff-by-reason / AI-assisted orders /
    first-response p50-p95 / knowledge gaps for chats with a customer message
    in [since, until). See core.logic.bizagent_metrics."""
    from .logic import bizagent_metrics as BM
    from .models import ChatThread, Message, Order
    now = now or timezone.now()
    horizon = until + timedelta(seconds=BM.WINDOW_S)
    ids = list(Message.objects.filter(thread__business=business, direction="in",
                                      created_at__gte=since, created_at__lt=until)
               .values_list("thread_id", flat=True).distinct()[:limit])
    rows = {i: {"messages": [], "orders": []} for i in ids}
    for m in Message.objects.filter(thread_id__in=ids, created_at__gte=since,
                                    created_at__lt=horizon).order_by("created_at", "id") \
            .values("thread_id", "direction", "reply_source", "status", "risk_reason",
                    "created_at", "text"):
        rows[m["thread_id"]]["messages"].append({
            "direction": m["direction"], "source": m["reply_source"], "status": m["status"],
            "risk": m["risk_reason"], "ts": m["created_at"].timestamp(),
            "text": (m["text"] or "")[:300] if m["direction"] == "in" else ""})
    for o in Order.objects.filter(thread_id__in=ids, created_at__gte=since,
                                  created_at__lt=horizon).values("thread_id", "total", "status",
                                                                 "created_at"):
        rows[o["thread_id"]]["orders"].append({"total": str(o["total"] or 0),
                                               "status": o["status"],
                                               "ts": o["created_at"].timestamp()})
    out = BM.summarize(list(rows.values()), now.timestamp())
    out.update({"since": since.isoformat(), "until": until.isoformat()})
    return out


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
