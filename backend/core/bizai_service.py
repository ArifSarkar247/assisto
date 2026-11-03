"""bizai (owner 4 Nov 02:05 "BUSINESS AI REAL IMPACT", pillar 1 + outcome card).

The AI sales agent inside Assisto itself — no Meta token, no App Review:

  * IN-APP SHOP CHAT (channel kind "assisto"): a customer opens a shop's chat
    (shop link / My Circle contact who runs a shop) and the SAME agent
    pipeline as Messenger/WhatsApp answers (bizagent_service.handle_message:
    rule-first, prices/stock only from the catalog, photo → product, voice
    note → shared voice path, order → invoice → courier). Personal My Circle
    chats stay end-to-end encrypted and untouched: this is a SEPARATE chat,
    and before the first message the customer sees that it is with the shop
    and its AI assistant and is NOT end-to-end encrypted. AI replies carry an
    "AI" label; "Talk to a person" hands the chat to the shop.
  * COD RETURN-RISK: delivered vs returned counts of the buyer's phone across
    Assisto shops (counts only — never another shop's name/orders). High
    risk → no auto-courier, the owner is told; the customer is never accused.
  * LEARNS FROM OWNER CORRECTIONS: an edited AI draft becomes a shop FAQ
    (used at once when it states no price; a price answer waits for the
    owner because prices come from the catalog only).
  * OUTCOME CARD: this week, in BDT, from real rows only — orders the AI
    took, customers brought back (retention attribution), dues collected
    after a tagada, losses prevented (risky COD orders held and cancelled).
"""
import hashlib
import hmac
import logging
import time
from datetime import timedelta
from decimal import Decimal

from django.conf import settings
from django.db.models import Sum
from django.utils import timezone

from .i18n import pick

log = logging.getLogger(__name__)

KIND = "assisto"
MAX_TEXT = 1000
MAX_UPLOAD = 6 * 1024 * 1024
PER_MIN = 8            # customer messages / chat / minute
PER_HOUR = 60
REPLY_TARGET_MS = 5000  # owner: answer within 5 seconds
CUSTOMER_PREFIX = "u"
SHARE_BASE = "https://lifeassisto.com/shop/"

DISCLOSURE = {
    "bn": "এই দোকান উত্তর দিতে Assisto AI ব্যবহার করে। এখানের মেসেজ এন্ড-টু-এন্ড এনক্রিপ্টেড নয় — "
          "দোকান ও তার AI সহকারী দেখতে পান। আপনার ব্যক্তিগত My Circle চ্যাট আগের মতোই এনক্রিপ্টেড।",
    "en": "This shop uses Assisto AI to reply. Messages here are not end-to-end encrypted and are "
          "visible to the shop and its AI assistant. Your personal My Circle chats stay encrypted.",
}


def _S():
    from . import bizagent_service as S
    return S


# ===================================================================== shop link
def _sig(pk):
    key = (settings.SECRET_KEY or "x").encode()
    return hmac.new(key, ("bizai-shop:%d" % pk).encode(), hashlib.sha256).hexdigest()[:8]


def shop_code(business):
    return "%d-%s" % (business.pk, _sig(business.pk))


def business_for_code(code):
    from .models import BusinessProfile
    code = str(code or "").strip().rsplit("/", 1)[-1]
    if "-" not in code or len(code) > 32:
        return None
    pk, sig = code.split("-", 1)
    if not pk.isdigit() or not hmac.compare_digest(sig, _sig(int(pk))):
        return None
    return BusinessProfile.objects.filter(pk=int(pk)).select_related("user").first()


def share_url(business):
    return SHARE_BASE + shop_code(business)


def app_channel(business, create=True):
    from .models import SellerChannel
    ext = "app%d" % business.pk
    ch = SellerChannel.objects.filter(kind=KIND, external_id=ext).first()
    if ch is None and create:
        ch = SellerChannel.objects.create(business=business, kind=KIND, external_id=ext,
                                          display_name=(business.shop_name or "Assisto")[:120],
                                          status="connected", connected_at=timezone.now())
    return ch


def chat_open(business):
    """(open, reason). The chat is open while the shop has it on; the agent's
    own switches (AI on/off, hours, takeover) decide WHO answers inside."""
    if business is None:
        return False, "not_found"
    agent = _S().agent_for(business)
    if not agent.app_chat_enabled:
        return False, "chat_off"
    return True, ""


# ===================================================================== customer side
def customer_key(user):
    return "%s%d" % (CUSTOMER_PREFIX, user.pk)


def customer_thread(user, business, create=True):
    from .models import ChatThread
    ch = app_channel(business, create=create)
    if ch is None:
        return None
    t = ChatThread.objects.filter(seller_channel=ch, external_user_id=customer_key(user)).first()
    if t is None and create:
        name = (getattr(user, "first_name", "") or "").strip() or ""
        t = _S().thread_for(ch, customer_key(user), name)
    return t


def msg_row(m):
    meta = m.meta or {}
    return {"id": m.id, "dir": m.direction, "text": m.text, "kind": m.kind,
            "ai": bool(m.direction == "out" and m.is_ai),
            "image": meta.get("image_url", ""), "voice": bool(meta.get("voice")),
            "at": m.created_at.isoformat()}


VISIBLE_OUT = ("sent", "delivered", "read", "queued")


def visible_messages(thread, after=0, limit=60):
    """Customer view: their own messages + replies that really went out
    (never a pending draft, a rejected one or a failed one)."""
    if thread is None:
        return []
    qs = thread.messages.filter(id__gt=after).order_by("-created_at", "-id")
    rows = []
    for m in qs[:limit * 2]:
        if m.direction == "out" and m.status not in VISIBLE_OUT:
            continue
        rows.append(m)
        if len(rows) >= limit:
            break
    return [msg_row(m) for m in reversed(rows)]


def shop_view(user, business, lang="bn"):
    ok, why = chat_open(business)
    t = customer_thread(user, business, create=False) if ok else None
    agent = _S().agent_for(business)
    human = bool(t and t.owner_takeover)
    return {"ok": ok, "reason": why, "code": shop_code(business),
            "shop": business.shop_name or "", "lang": lang,
            "disclosure": DISCLOSURE["en" if lang == "en" else "bn"],
            # the app shows the disclosure above the composer until the
            # customer's first message (and keeps a short line after)
            "disclosure_seen": bool(t and t.messages.filter(direction="in").exists()),
            "ai_on": bool(agent.ai_enabled), "with_person": human,
            "own_shop": business.user_id == user.pk,
            "messages": visible_messages(t)}


def _rate_limited(thread, now):
    mine = thread.messages.filter(direction="in")
    return (mine.filter(created_at__gte=now - timedelta(minutes=1)).count() >= PER_MIN or
            mine.filter(created_at__gte=now - timedelta(hours=1)).count() >= PER_HOUR)


def customer_send(user, business, text="", upload=None, lang="bn", ref=""):
    """One customer message → the agent answers in the same request (the
    reply is in the response; target ≤ 5 s, measured). upload = {"type":
    image|audio, "bytes", "mime"}. -> (status, body)."""
    ok, why = chat_open(business)
    if not ok:
        return 404 if why == "not_found" else 409, {"ok": False, "reason": why}
    if business.user_id == user.pk:
        return 422, {"ok": False, "reason": "own_shop"}
    text = str(text or "").strip()[:MAX_TEXT]
    if not text and not upload:
        return 422, {"ok": False, "reason": "empty"}
    if upload and (not upload.get("bytes") or len(upload["bytes"]) > MAX_UPLOAD
                   or upload.get("type") not in ("image", "audio")):
        return 413, {"ok": False, "reason": "bad_upload"}
    t = customer_thread(user, business)
    now = timezone.now()
    if _rate_limited(t, now):
        return 429, {"ok": False, "reason": "rate_limited"}
    if ref and not t.source_ref:
        # bizai pillar 5: opened from a tracked post link (…/shop/<code>?p=<ref>)
        from . import bizai_prochar as BP
        BP.capture(t, ref=ref)
    last = t.messages.order_by("-id").values_list("id", flat=True).first() or 0
    eid = "app-in-" + hashlib.sha256(("%s|%s|%s" % (t.pk, text, now.isoformat()))
                                     .encode()).hexdigest()[:24]
    atts = []
    if upload:
        atts = [{"type": upload["type"], "_bytes": upload["bytes"],
                 "mime": upload.get("mime") or ""}]
    ev = {"channel": KIND, "account_id": t.seller_channel.external_id,
          "user_id": customer_key(user), "event_id": eid,
          "text": text or ("[image]" if upload and upload["type"] == "image" else
                           "[audio]" if upload else ""),
          "ts": int(now.timestamp()), "name": t.customer_name or "",
          "kind": "message", "attachments": atts}
    t0 = time.monotonic()
    try:
        res = _S().handle_message(t.seller_channel, ev)
    except Exception:  # noqa: BLE001 — the customer's message is kept; the shop answers
        log.exception("bizai.customer_send")
        res = "error"
    ms = int((time.monotonic() - t0) * 1000)
    t.refresh_from_db()
    rows = visible_messages(t, after=last)
    replied = any(r["dir"] == "out" for r in rows)
    if not replied:
        # nobody answered right now (AI off / outside hours / a person handles
        # it): the shop gets the message; the customer is told honestly
        rows.append({"id": 0, "dir": "system", "kind": "notice", "ai": False, "image": "",
                     "voice": False, "at": timezone.now().isoformat(),
                     "text": pick(lang, "দোকানকে জানানো হয়েছে — তারা শিগগিরই উত্তর দেবেন।",
                                  "The shop has your message — they will reply soon.")})
    return 200, {"ok": True, "status": res, "ms": ms, "within_target": ms <= REPLY_TARGET_MS,
                 "replied": replied, "messages": rows,
                 "with_person": bool(t.owner_takeover)}


def talk_to_person(user, business, lang="bn"):
    """The customer asks for a person: AI goes silent in THIS chat, the shop
    is pushed; the owner hands it back to the AI from the Business inbox."""
    from . import bizagent_g1_service as G1S
    t = customer_thread(user, business)
    if t is None:
        return 404, {"ok": False, "reason": "not_found"}
    G1S.set_reply_mode(t, "human")
    _S().notify_seller(business, "inbox", "একজন গ্রাহক মানুষের সাথে কথা বলতে চান",
                       "A customer wants to talk to a person",
                       (t.customer_name or "") + " — Assisto", (t.customer_name or "") + " — Assisto",
                       data={"thread_id": str(t.pk)})
    m = _S().send_text(t, pick(t.lang or lang, "ঠিক আছে, দোকানের একজন মানুষ এই চ্যাটে উত্তর দেবেন।",
                               "Okay — a person from the shop will reply in this chat."),
                       kind="text", is_ai=True, source="system")
    return 200, {"ok": True, "with_person": True, "messages": [msg_row(m)]}


def push_customer(thread, m):
    """A reply in the in-app shop chat → one push to the customer's phone."""
    key = thread.external_user_id or ""
    if not key.startswith(CUSTOMER_PREFIX) or not key[1:].isdigit():
        return 0
    from django.contrib.auth import get_user_model
    from . import push
    u = get_user_model().objects.filter(pk=int(key[1:])).first()
    if u is None:
        return 0
    shop = (thread.business.shop_name if thread.business else "") or "Assisto"
    body = (m.text or "")[:120]
    try:
        return push.push_to_user(u, "shop_alert", shop, shop,
                                 ("AI: " if m.is_ai else "") + body,
                                 ("AI: " if m.is_ai else "") + body,
                                 data={"route": "shop_chat", "code": shop_code(thread.business)})
    except Exception:  # noqa: BLE001
        return 0


def my_shops(user):
    """Shops the customer already chats with + shops run by accepted My
    Circle contacts (one tap to open)."""
    from .models import BusinessProfile, ChatThread, CircleMember, SellerAgent
    out, seen = [], set()
    for t in ChatThread.objects.filter(channel=KIND, external_user_id=customer_key(user)) \
            .select_related("business").order_by("-last_message_at")[:30]:
        if t.business_id in seen or t.business is None:
            continue
        seen.add(t.business_id)
        last = t.messages.filter(status__in=VISIBLE_OUT + ("received",)).order_by("-id").first()
        out.append({"code": shop_code(t.business), "shop": t.business.shop_name or "",
                    "last": (last.text if last else "")[:80], "circle": False,
                    "at": t.last_message_at.isoformat() if t.last_message_at else None})
    peers = list(CircleMember.objects.filter(user=user, state="accepted", blocked=False)
                 .exclude(peer_user=None).values_list("peer_user_id", flat=True)[:500])
    on = set(SellerAgent.objects.filter(business__user_id__in=peers, app_chat_enabled=True)
             .values_list("business_id", flat=True))
    for b in BusinessProfile.objects.filter(pk__in=on).exclude(pk__in=seen)[:30]:
        out.append({"code": shop_code(b), "shop": b.shop_name or "", "last": "",
                    "circle": True, "at": None})
    return out


# ===================================================================== COD risk
HIGH, MEDIUM, LOW, NEW = "high", "medium", "low", "new"


def risk_level(delivered, returned):
    """Pure: counts → level. New buyer = no history (not 'low')."""
    done = delivered + returned
    if done == 0:
        return NEW
    rate = returned / done
    if returned >= 2 and rate >= 0.5:
        return HIGH
    if returned >= 1 and rate >= 0.34:
        return MEDIUM
    return LOW


def cod_risk(phone, exclude_order=None):
    """{level, delivered, returned} for this phone across every Assisto shop
    (Business orders). Counts only; nothing else about other shops leaves."""
    from .models import Order
    from .logic.business_selling import normalize_phone
    key = normalize_phone(phone or "")
    if not key or len(key) < 10:
        return {"level": NEW, "delivered": 0, "returned": 0}
    qs = Order.objects.filter(customer_phone__endswith=key[-10:],
                              status__in=("delivered", "returned"))
    if exclude_order is not None:
        qs = qs.exclude(pk=exclude_order.pk)
    d = r = 0
    for st, ph in qs.values_list("status", "customer_phone")[:2000]:
        if normalize_phone(ph) != key:
            continue
        if st == "delivered":
            d += 1
        else:
            r += 1
    return {"level": risk_level(d, r), "delivered": d, "returned": r}


def check_order_risk(order, agent):
    """Stamp the order; True = HOLD (do not auto-book the courier). The owner
    is told in plain words; the customer is never accused or told."""
    info = cod_risk(order.customer_phone, exclude_order=order)
    order.cod_risk = info["level"]
    order.save(update_fields=["cod_risk"])
    hold = info["level"] == HIGH and agent.cod_risk_guard and order.payment == "cod"
    if info["level"] in (HIGH, MEDIUM) and order.business is not None:
        from .logic.bizagent import _bn_num
        _S().notify_seller(
            order.business, "orders", "COD ঝুঁকি — অর্ডার #%s" % _bn_num(order.id),
            "COD risk — order #%s" % order.id,
            "এই নম্বরের আগের পার্সেল: ডেলিভারি %s, ফেরত %s। %s" % (
                _bn_num(info["delivered"]), _bn_num(info["returned"]),
                "কুরিয়ার নিজে বুক হয়নি — ফোন করে নিশ্চিত হোন বা ডেলিভারি চার্জ আগে নিন।" if hold
                else "পাঠানোর আগে ফোনে নিশ্চিত হয়ে নিন।"),
            "This number's past parcels: %s delivered, %s returned. %s" % (
                info["delivered"], info["returned"],
                "The courier was NOT auto-booked — call to confirm or take the delivery charge first."
                if hold else "Confirm by phone before you ship."),
            data={"order_id": str(order.id)})
    return hold


# ===================================================================== learning
def learn_from_edit(message, body):
    """Owner edited an AI draft → the shop's own answer for that question.
    No price in it → approved FAQ (used at once, cost 0). A price answer →
    'suggested' (prices only ever come from the catalog; the owner decides)."""
    from .models import BizFaq
    from .logic import bizagent_rules as R
    t = message.thread
    q = t.messages.filter(direction="in", created_at__lte=message.created_at) \
        .exclude(text="").order_by("-created_at", "-id").first()
    body = (body or "").strip()
    if q is None or not body or len(q.text) < 3 or q.text.startswith("["):
        return None
    has_price = R.has_money(body)
    status = "suggested" if has_price else "approved"
    question = q.text.strip()[:500]
    f = BizFaq.objects.filter(business=t.business, question=question).first()
    if f is None:
        f = BizFaq.objects.create(business=t.business, question=question, answer=body[:1000],
                                  status=status, source="correction", has_price=has_price)
    elif f.status != "rejected":
        f.answer, f.has_price = body[:1000], has_price
        f.status = status if f.status != "approved" or has_price else "approved"
        f.source = "correction"
        f.save(update_fields=["answer", "has_price", "status", "source", "updated_at"])
    return f


# ===================================================================== AI orders
def ai_orders(business, since, until):
    from .models import Order
    qs = Order.objects.filter(business=business, via_agent=True, created_at__gte=since,
                              created_at__lt=until).exclude(status="cancelled")
    return qs.count(), (qs.aggregate(s=Sum("total"))["s"] or Decimal("0"))


# ===================================================================== outcome card
def _taka(poisha):
    return Decimal(int(poisha or 0)) / 100


def outcomes(business, days=7, now=None):
    """The Business-home outcome card: real rows only, each with how it was
    measured. Nothing is estimated; a line with no data says so."""
    from .models import KhataEntry, Order, RetentionSend, TagadaSend
    now = now or timezone.now()
    since = now - timedelta(days=days)
    n_orders, v_orders = ai_orders(business, since, now)
    try:
        from . import retention_service as RS
        RS.attribute_business(business, now)
    except Exception:  # noqa: BLE001
        log.exception("bizai.outcomes attribution")
    back = RetentionSend.objects.filter(business=business, purchase_sale__isnull=False,
                                        purchase_sale__created_at__gte=since)
    n_back = back.values("audience_key").distinct().count()
    v_back = _taka(back.aggregate(s=Sum("purchase_poisha"))["s"])
    # dues: a payment ('got') this week from a party the shop sent a tagada
    # to in the 7 days before that payment
    sends = list(TagadaSend.objects.filter(business=business, party__isnull=False,
                                           created_at__gte=since - timedelta(days=7))
                 .values_list("party_id", "created_at"))
    first = {}
    for pid, at in sends:
        first[pid] = min(at, first.get(pid, at))
    n_due, v_due = 0, Decimal("0")
    if first:
        for pid, amt, at in KhataEntry.objects.filter(
                party_id__in=list(first), direction="got", at__gte=since, at__lte=now) \
                .values_list("party_id", "amount_poisha", "at")[:5000]:
            if first[pid] < at <= first[pid] + timedelta(days=7):
                n_due += 1
                v_due += _taka(amt)
    held = Order.objects.filter(business=business, cod_risk=HIGH, status="cancelled",
                                created_at__gte=since)
    n_loss = held.count()
    v_loss = held.aggregate(s=Sum("total"))["s"] or Decimal("0")
    rows = [
        {"key": "ai_orders", "count": n_orders, "bdt": str(v_orders),
         "how_bn": "AI চ্যাটে নিজে যে অর্ডার নিয়েছে (বাতিল বাদে)",
         "how_en": "Orders the AI took in chat (cancelled excluded)"},
        {"key": "customers_back", "count": n_back, "bdt": str(v_back),
         "how_bn": "অটো-মেসেজের পরে আবার কিনেছেন — কেনার আসল টাকা",
         "how_en": "Bought again after an automatic message — real sale amount"},
        {"key": "dues_collected", "count": n_due, "bdt": str(v_due),
         "how_bn": "তাগাদা পাঠানোর ৭ দিনের মধ্যে খাতায় জমা",
         "how_en": "Paid into the khata within 7 days of a reminder"},
        {"key": "losses_prevented", "count": n_loss, "bdt": str(v_loss),
         "how_bn": "ফেরতের ঝুঁকি বেশি — আটকানো ও বাতিল করা COD অর্ডার",
         "how_en": "High return-risk COD orders held and cancelled"},
    ]
    total = sum(Decimal(r["bdt"]) for r in rows)
    best = None
    try:   # pillar 5: the post that sold (its orders are already in ai_orders)
        from . import bizai_prochar as BP
        best = BP.attribution(business, days=days, now=now)["best"]
    except Exception:  # noqa: BLE001
        log.exception("bizai.outcomes best_post")
    return {"days": days, "since": since.isoformat(), "until": now.isoformat(),
            "rows": rows, "total_bdt": str(total), "best_post": best,
            "empty": all(r["count"] == 0 for r in rows)}
