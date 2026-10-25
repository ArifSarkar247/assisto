"""
Business AI Agent v2 ("own Page + own number first"): the guard layer that
sits around the existing pipeline in core.bizagent_service /
core.bizagent_g1_service. Ported ideas from the Asalify auto-reply cron
(read-only reference, never called): per-chat daily cap, human-suppress
window, honest skip counters — plus what the owner asked for on 25 Oct:

  * owner takeover with an editable IDLE timeout (agent resumes by itself
    when the owner has been silent in a taken-over chat for N minutes)
  * per-business daily cap on PAID AI calls (LLM replies + vision) — over
    the cap the customer gets the honest "I'll ask the owner" line and the
    owner is told once a day; rule replies (cost 0) keep working
  * per-chat daily cap on agent replies + a burst limiter (anti-loop /
    anti-spam: a bot or an angry customer can never drain credits)
  * image → DRAFT order (status "new", stock untouched) the owner confirms
    or cancels from the Business inbox
  * Business inbox: per-chat status (agent / owner / attention), unread,
    search, channel filter
  * audit log (no tokens, no message bodies)

Pure-ish: every function takes model rows and returns plain values; the
callers decide what to send.
"""
import logging
from datetime import timedelta

from django.db import IntegrityError, transaction
from django.db.models import Q
from django.utils import timezone

log = logging.getLogger(__name__)

IDLE_MAX_MIN = 7 * 24 * 60
DAILY_AI_CAP_MAX = 5000
THREAD_CAP_MAX = 500
BURST_WINDOW_S = 60
BURST_MAX = 8                 # inbound messages per chat per minute the agent answers

ST_AGENT, ST_OWNER, ST_ATTENTION = "agent", "owner", "attention"
STATUSES = (ST_AGENT, ST_OWNER, ST_ATTENTION)


def clamp(v, lo, hi, fb):
    try:
        n = int(v)
    except (TypeError, ValueError):
        return fb
    return max(lo, min(hi, n))


def _day_start(now=None):
    lt = timezone.localtime(now or timezone.now())
    return lt.replace(hour=0, minute=0, second=0, microsecond=0)


# ===================================================================== audit
def audit(business, action, *, actor=None, thread=None, **detail):
    from .models import BizAuditLog
    try:
        BizAuditLog.objects.create(
            business=business, action=action[:32],
            actor=actor if getattr(actor, "pk", None) else None,
            thread=thread, detail={k: v for k, v in detail.items() if k not in ("token",)})
    except Exception:  # noqa: BLE001 — an audit failure never breaks a reply
        log.exception("bizagent audit %s failed", action)


def _once_today(key):
    """True the first time `key` is seen today (WebhookReceipt dedupe)."""
    from .models import WebhookReceipt
    try:
        with transaction.atomic():
            WebhookReceipt.objects.create(
                source="bizv2", message_id=("%s:%s" % (key, _day_start().date()))[:128])
        return True
    except IntegrityError:
        return False


# ===================================================================== takeover
def take_over(thread, actor=None, now=None):
    from . import bizagent_g1_service as G1S
    now = now or timezone.now()
    G1S.set_reply_mode(thread, "human")
    thread.takeover_at = now
    thread.save(update_fields=["takeover_at"])
    audit(thread.business, "takeover", actor=actor, thread=thread)
    return thread


def hand_back(thread, actor=None, reason="manual"):
    from . import bizagent_g1_service as G1S
    G1S.set_reply_mode(thread, "ai")
    thread.takeover_at = None
    thread.save(update_fields=["takeover_at"])
    audit(thread.business, "handback" if reason == "manual" else "handback_idle",
          actor=actor, thread=thread)
    return thread


def touch_takeover(thread, now=None):
    """The owner wrote in a taken-over chat: the idle clock restarts."""
    from .models import ChatThread
    if thread.owner_takeover:
        now = now or timezone.now()
        ChatThread.objects.filter(pk=thread.pk).update(takeover_at=now)
        thread.takeover_at = now


def idle_expired(agent, thread, now=None):
    """A taken-over chat whose owner has been silent for the idle timeout.
    Legacy takeovers (no takeover_at) never expire by themselves."""
    if not thread.owner_takeover or not thread.takeover_at:
        return False
    mins = clamp(agent.takeover_idle_minutes, 0, IDLE_MAX_MIN, 60)
    if mins <= 0:
        return False
    now = now or timezone.now()
    return thread.takeover_at + timedelta(minutes=mins) <= now


def maybe_auto_handback(agent, thread, now=None):
    if idle_expired(agent, thread, now):
        hand_back(thread, reason="idle")
        return True
    return False


def sweep_idle_takeovers(now=None, limit=200):
    """Cron: hand idle takeovers back to the agent; a customer still waiting
    gets the agent's answer (same path as the human-pause resume)."""
    from . import bizagent_service as S
    from .logic import bizagent_g1 as G1
    from .models import ChatThread
    now = now or timezone.now()
    n = 0
    qs = ChatThread.objects.filter(owner_takeover=True, takeover_at__isnull=False) \
        .select_related("business", "seller_channel")[:limit]
    for t in qs:
        if t.business is None:
            continue
        agent = S.agent_for(t.business)
        if not maybe_auto_handback(agent, t, now):
            continue
        n += 1
        msgs = list(t.messages.order_by("-created_at", "-id")[:12])[::-1]
        rows = [{"direction": m.direction, "status": m.status} for m in msgs]
        last_in = next((m for m in reversed(msgs) if m.direction == "in"), None)
        if t.seller_channel is not None and last_in is not None and G1.customer_waiting(rows):
            S.respond(t.seller_channel, t, last_in.text, t.lang or "bn", resumed=True)
    return n


# ===================================================================== caps
def ai_calls_today(business, now=None):
    """Paid AI calls today for this business: LLM replies (sent or waiting
    for approval) + vision answers. Rule replies cost 0 and do not count."""
    from .models import Message
    start = _day_start(now)
    qs = Message.objects.filter(thread__business=business, direction="out",
                                created_at__gte=start)
    return qs.filter(Q(reply_source="ai") | Q(status="pending_approval", meta__source="ai")) \
        .count()


def ai_budget_ok(agent, now=None):
    cap = clamp(agent.daily_ai_cap, 0, DAILY_AI_CAP_MAX, 300)
    return ai_calls_today(agent.business, now) < cap


def note_cap_hit(agent, kind, thread=None):
    """Tell the owner ONCE a day per cap; audit every hit."""
    from . import bizagent_service as S
    audit(agent.business, "cap_" + kind, thread=thread)
    if _once_today("cap:%s:%s" % (kind, agent.pk)):
        if kind == "daily_ai":
            S.notify_seller(agent.business, "plan", "আজকের AI সীমা শেষ", "Today's AI limit reached",
                            "আজকের AI উত্তরের সীমা পূর্ণ — নিয়মভিত্তিক উত্তর চলবে, বাকি প্রশ্ন আপনার কাছে আসবে।",
                            "Today's AI reply limit is used up — rule answers continue, other questions come to you.")
        else:
            S.notify_seller(agent.business, "inbox", "একটি চ্যাট সীমা ছুঁয়েছে",
                            "A chat reached its limit",
                            "এই চ্যাটে আজ এজেন্ট আর উত্তর দেবে না — আপনি দেখে নিন।",
                            "The agent will not reply in this chat again today — please take a look.",
                            data={"thread_id": str(thread.pk)} if thread else None)


def thread_replies_today(thread, now=None):
    return thread.messages.filter(direction="out", is_ai=True,
                                  created_at__gte=_day_start(now)).count()


def thread_capped(agent, thread, now=None):
    cap = clamp(agent.thread_daily_cap, 1, THREAD_CAP_MAX, 50)
    return thread_replies_today(thread, now) >= cap


def burst(thread, now=None):
    now = now or timezone.now()
    return thread.messages.filter(direction="in",
                                  created_at__gte=now - timedelta(seconds=BURST_WINDOW_S)) \
        .count() > BURST_MAX


def gate(agent, thread, now=None):
    """None = the agent may reply; else the reason it stays quiet in this
    chat (the owner sees the chat as needs-attention)."""
    if thread_capped(agent, thread, now):
        note_cap_hit(agent, "thread", thread)
        return "thread_cap"
    if burst(thread, now):
        if _once_today("burst:%s" % thread.pk):
            audit(agent.business, "burst", thread=thread)
        return "burst"
    return None


# ===================================================================== image → draft order
def open_draft(thread):
    from .models import Order
    return Order.objects.filter(thread=thread, status="new", via_agent=True) \
        .order_by("-created_at").first()


def image_draft_order(thread, product):
    """A customer photo matched a catalogue item → a DRAFT order (status
    'new', qty 1, the catalogue price, stock untouched) for the owner to
    confirm. One open draft per chat: a new match replaces the item."""
    from .models import Order
    from .logic import bizagent as BZ
    price = BZ._dec(product.get("price")) or 0
    if price <= 0:
        return None
    item = {"product_id": product["id"], "name": product["name"], "qty": 1,
            "price": str(price), "variant": "", "source": "image"}
    o = open_draft(thread)
    if o is None:
        o = Order.objects.create(
            user=thread.business.user, business=thread.business, thread=thread,
            customer_name=(thread.customer_name or "")[:120],
            customer_phone=thread.customer_phone or "", items=[item], total=price,
            status="new", payment="cod", channel=thread.channel, via_agent=True)
        audit(thread.business, "draft_order", thread=thread, order_id=o.id,
              product_id=product["id"])
    else:
        o.items, o.total = [item], price
        o.save(update_fields=["items", "total"])
    return o


def draft_line(lang):
    from .logic import business_ai as bai
    return bai.pick(lang, "আমি এটি আপনার জন্য খসড়া অর্ডার হিসেবে রেখেছি — দোকানের মালিক নিশ্চিত করবেন।",
                    "I've noted this as a draft order for you — the shop owner will confirm it.")


def owner_confirm(order, actor=None, lang="bn"):
    """The owner confirms a draft: stock is reduced atomically (never below
    0); out of stock → refused honestly."""
    from . import bizagent_service as S
    from .models import Order
    if order.status != "new":
        return {"ok": False, "reason": "not_draft"}
    items = list(order.items or [])
    with transaction.atomic():
        locked = Order.objects.select_for_update().get(pk=order.pk)
        if locked.status != "new":
            return {"ok": False, "reason": "not_draft"}
        for it in items:
            if not S._decrement_stock(it):
                transaction.set_rollback(True)
                return {"ok": False, "reason": "out_of_stock", "product": it.get("name", "")}
        locked.status = "confirmed"
        locked.save(update_fields=["status"])
    order.status = "confirmed"
    audit(order.business, "draft_confirm", actor=actor, thread=order.thread, order_id=order.id)
    return {"ok": True}


def owner_cancel(order, actor=None):
    if order.status != "new":
        return {"ok": False, "reason": "not_draft"}
    order.status = "cancelled"
    order.save(update_fields=["status"])
    audit(order.business, "draft_cancel", actor=actor, thread=order.thread, order_id=order.id)
    return {"ok": True}


# ===================================================================== inbox
def thread_status(t, now=None, *, pending=None, last_out=None, drafts=None):
    """attention > owner > agent. attention = something only the owner can
    resolve: a reply waiting for approval, a failed/blocked send, the agent's
    honest holding line with no human answer after it, a draft order."""
    now = now or timezone.now()
    if pending is None:
        pending = t.messages.filter(status="pending_approval").count()
    if last_out is None:
        last_out = t.messages.filter(direction="out").exclude(status="pending_approval") \
            .order_by("-created_at", "-id").first()
    if drafts is None:
        drafts = t.orders.filter(status="new", via_agent=True).count()
    if pending or drafts:
        return ST_ATTENTION
    if last_out is not None and (last_out.status in ("failed", "blocked", "queued")
                                 or last_out.kind == "holding"):
        return ST_ATTENTION
    if t.owner_takeover or (t.ai_paused_until and t.ai_paused_until > now):
        return ST_OWNER
    return ST_AGENT


def unread(t):
    qs = t.messages.filter(direction="in")
    if t.owner_read_at:
        qs = qs.filter(created_at__gt=t.owner_read_at)
    return qs.count()


def mark_read(t, now=None):
    from .models import ChatThread
    now = now or timezone.now()
    ChatThread.objects.filter(pk=t.pk).update(owner_read_at=now)
    t.owner_read_at = now


def inbox(business, *, status="", channel="", q="", unread_only=False, limit=100):
    """(rows, counts) for the Business inbox. Rows are (thread, status,
    unread) — the view formats them."""
    from .models import Message
    qs = business.chat_threads.exclude(seller_channel=None)
    if channel:
        qs = qs.filter(channel=channel)
    q = (q or "").strip()[:80]
    if q:
        ids = Message.objects.filter(thread__business=business, text__icontains=q) \
            .values_list("thread_id", flat=True)[:500]
        qs = qs.filter(Q(customer_name__icontains=q) | Q(customer_phone__icontains=q)
                       | Q(pk__in=list(ids)))
    qs = qs.order_by("-last_message_at", "-created_at")[:300]
    now = timezone.now()
    counts = {"all": 0, ST_AGENT: 0, ST_OWNER: 0, ST_ATTENTION: 0, "unread": 0}
    rows = []
    for t in qs:
        st = thread_status(t, now)
        un = unread(t)
        counts["all"] += 1
        counts[st] += 1
        counts["unread"] += 1 if un else 0
        if status in STATUSES and st != status:
            continue
        if unread_only and not un:
            continue
        if len(rows) < limit:
            rows.append((t, st, un))
    return rows, counts


def recent_audit(business, limit=50):
    from .models import BizAuditLog
    return [{"id": a.id, "action": a.action, "thread_id": a.thread_id,
             "actor": bool(a.actor_id), "detail": a.detail,
             "created_at": a.created_at.isoformat()}
            for a in BizAuditLog.objects.filter(business=business)[:limit]]


def features(business, meta_ready, vision_ready):
    """What the app may SHOW (no showpieces): Messenger/WhatsApp connect only
    when the server's Meta app is configured; the inbox only once a channel
    is connected; vision only with a provider key."""
    connected = business.seller_channels.filter(status="connected").exists()
    meta_ok = bool(meta_ready.get("app") and meta_ready.get("secret")
                   and meta_ready.get("verify_token"))
    return {"own_channels": meta_ok, "inbox": connected, "image_order": connected,
            "vision": bool(vision_ready)}
