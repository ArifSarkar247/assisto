"""bizsales-proof: COD (cash on delivery) confirmation — board row 25.

The best COD-confirmation apps (Shopify COD apps, Releasit / EasySell style)
message the buyer before the parcel ships, take a one-tap yes/no, remind once,
and cancel orders nobody confirms — so the shop stops paying couriers for
fake or forgotten orders. This module does that on the shop's OWN official
channel (Messenger / Instagram / WhatsApp Cloud API):

  ask(order)        an open COD order (status "new") → one confirmation
                    message with the order lines, delivery charge, COD total
                    and address + two reply buttons (Messenger/IG quick
                    replies, WhatsApp interactive buttons; outside WhatsApp's
                    24 h window an approved template with quick-reply
                    buttons). Messenger/IG outside 24 h → honest "call the
                    customer" (Meta allows no automated message there).
  on_reply(...)     the tapped button (payload COD_YES:<id> / COD_NO:<id>) or a
                    short typed "হ্যাঁ"/"না" → order confirmed / cancelled
                    (stock given back), thank-you line, the owner is told.
  sweep(now)        no reply after REMIND_AFTER → ONE reminder; still nothing
                    CANCEL_AFTER later → the order is cancelled as "no reply"
                    (stock back), the customer gets a polite line, the owner a
                    push. Nothing is ever sent twice (stage on the message).
  risk_detail(o)    the COD return-risk shown to the OWNER only, honestly: the
                    real delivered / returned counts behind the level; a buyer
                    with no history is "new" (unknown), never "safe".

ISOLATION (owner_actions/AI_SALES_BRAIN_BN.md, P0): every lookup is scoped to
the thread's business AND the thread itself — a payload naming another shop's
(or another customer's) order changes nothing. The customer is never told
the risk level. No migration: the state lives on the confirmation Message
(kind="cod_confirm", meta.cod_order / cod_stage / timestamps).
"""
import logging
import re
from datetime import timedelta

from django.db import transaction
from django.db.models import F
from django.utils import timezone

from .logic import bizagent as BZ
from .logic import business_ai as bai

log = logging.getLogger(__name__)

YES_P, NO_P = "COD_YES", "COD_NO"
KIND_ASK, KIND_REMIND = "cod_confirm", "cod_remind"
OPEN_STAGES = ("asked", "reminded")
REMIND_AFTER = timedelta(hours=6)
CANCEL_AFTER = timedelta(hours=12)       # after the reminder (18 h in all)
MAX_AGE = timedelta(days=3)              # an older question is never acted on
TEMPLATE_DEFAULT = "assisto_cod_confirm"
_PAYLOAD = re.compile(r"^(COD_YES|COD_NO):(\d{1,12})$")
_SHORT_WORDS = 4


def _S():
    from . import bizagent_service as S
    return S


def _pick(lang, bn, en):
    return bai.pick(lang, bn, en)


def _num(lang, v):
    return BZ._bn_num(v) if lang == "bn" else str(v)


def _money(lang, v):
    return _num(lang, BZ._fmt_money(v))


def quick(order_id, lang):
    return [{"id": "%s:%d" % (YES_P, order_id), "title": _pick(lang, "হ্যাঁ, পাঠান", "Yes, confirm")},
            {"id": "%s:%d" % (NO_P, order_id), "title": _pick(lang, "না, বাতিল", "No, cancel")}]


def is_open_cod(order):
    return order.status == "new" and (order.payment or "cod") in ("cod", "cash")


# ------------------------------------------------------------------ texts
def ask_text(order, shop, lang):
    name = order.customer_name or _pick(lang, "প্রিয় গ্রাহক", "Dear customer")
    shop = shop or _pick(lang, "আমাদের দোকান", "our shop")
    lines = [_pick(lang, "%s, %s থেকে আপনার অর্ডার #%s নিশ্চিত করুন:" % (name, shop, _num(lang, order.id)),
                   "%s, please confirm your order #%d from %s:" % (name, order.id, shop))]
    for it in (order.items or [])[:10]:
        q = int(it.get("qty") or 1)
        lines.append("• %s × %s = ৳%s" % (it.get("name") or "?", _num(lang, q),
                                           _money(lang, BZ._dec(it.get("price") or 0) * q)))
    if BZ._dec(order.delivery_charge):
        lines.append(_pick(lang, "ডেলিভারি চার্জ: ৳%s" % _money(lang, order.delivery_charge),
                           "Delivery: ৳%s" % _money(lang, order.delivery_charge)))
    lines.append(_pick(lang, "মোট (ক্যাশ অন ডেলিভারি): ৳%s" % _money(lang, order.total),
                       "Total (cash on delivery): ৳%s" % _money(lang, order.total)))
    if order.address:
        lines.append(_pick(lang, "ঠিকানা: %s" % order.address[:200], "Address: %s" % order.address[:200]))
    lines.append(_pick(lang, "পাঠাব? নিচের বোতাম চাপুন বা \"হ্যাঁ\" / \"না\" লিখুন।",
                       "Shall we ship it? Tap a button below or reply \"yes\" / \"no\"."))
    return "\n".join(lines)


def remind_text(order, lang):
    return _pick(lang, "মনে করিয়ে দিচ্ছি: অর্ডার #%s (মোট ৳%s, ক্যাশ অন ডেলিভারি) এখনো নিশ্চিত হয়নি। "
                       "পাঠাব? \"হ্যাঁ\" বা \"না\" চাপুন। উত্তর না পেলে অর্ডারটি বাতিল হয়ে যাবে।"
                 % (_num(lang, order.id), _money(lang, order.total)),
                 "Reminder: order #%d (total ৳%s, cash on delivery) is not confirmed yet. Shall we "
                 "ship it? Tap \"yes\" or \"no\". Without a reply the order will be cancelled."
                 % (order.id, _money(lang, order.total)))


def yes_text(order, lang):
    return _pick(lang, "ধন্যবাদ! অর্ডার #%s নিশ্চিত হয়েছে। পার্সেল পাঠানো হলে জানিয়ে দেব।" % _num(lang, order.id),
                 "Thank you! Order #%d is confirmed. We'll let you know when the parcel ships." % order.id)


def no_text(order, lang):
    return _pick(lang, "ঠিক আছে, অর্ডার #%s বাতিল করা হলো। আবার দরকার হলে যেকোনো সময় লিখুন।" % _num(lang, order.id),
                 "Okay, order #%d has been cancelled. Write any time if you need it again." % order.id)


def expired_text(order, lang):
    return _pick(lang, "অর্ডার #%s-এর নিশ্চিতকরণ পাইনি, তাই অর্ডারটি বাতিল করা হলো। আবার নিতে চাইলে এখানে লিখুন।"
                 % _num(lang, order.id),
                 "We did not get a confirmation for order #%d, so it has been cancelled. Write here "
                 "if you still want it." % order.id)


def closed_text(order, lang):
    return _pick(lang, "অর্ডার #%s এখন আর নিশ্চিতকরণের অপেক্ষায় নেই। দোকানের একজন আপনাকে জানাবেন।" % _num(lang, order.id),
                 "Order #%d is no longer waiting for confirmation. Someone from the shop will reply." % order.id)


# ------------------------------------------------------------------ risk
def risk_detail(order):
    """Owner-only, honest: the counts behind the level (never shown to the
    customer). Counts only — no other shop's name or order ever leaves."""
    from . import bizai_service as BA
    info = BA.cod_risk(order.customer_phone, exclude_order=order)
    d, r = info["delivered"], info["returned"]
    lvl = info["level"]
    if lvl == BA.NEW:
        bn = "নতুন ক্রেতা: এই নম্বরে Assisto-তে আগের কোনো পার্সেলের হিসাব নেই। ঝুঁকি জানা নেই, তাই নিরাপদ ধরা হয়নি।"
        en = "New buyer: no earlier parcels for this number on Assisto. The risk is unknown, so it is not treated as safe."
    else:
        bn = "এই নম্বরের আগের পার্সেল (সব Assisto দোকান মিলিয়ে, শুধু সংখ্যা): ডেলিভারি %s, ফেরত %s।" % (
            BZ._bn_num(d), BZ._bn_num(r))
        en = "This number's earlier parcels (all Assisto shops, counts only): %d delivered, %d returned." % (d, r)
    return {"level": lvl, "delivered": d, "returned": r, "based_on": d + r,
            "text_bn": bn, "text_en": en}


# ------------------------------------------------------------------ state
def _asks(order):
    from .models import Message
    return Message.objects.filter(thread__business=order.business, kind=KIND_ASK,
                                  direction="out", meta__cod_order=order.pk).order_by("-id")


def state(order):
    """For the owner's app: where the confirmation stands + the risk."""
    m = _asks(order).first() if order.business_id else None
    out = {"stage": "none", "asked_at": None, "reminded_at": None, "answered_at": None,
           "auto_cancel_at": None, "send_status": "", "send_error": "",
           "can_ask": bool(order.business_id) and is_open_cod(order) and (
               m is None or m.meta.get("cod_stage") not in OPEN_STAGES)}
    if m is not None:
        meta = m.meta or {}
        out.update(stage=meta.get("cod_stage") or "asked", asked_at=m.created_at.isoformat(),
                   reminded_at=meta.get("reminded_at"), answered_at=meta.get("answered_at"),
                   send_status=m.status, send_error=m.send_error or "")
        if out["stage"] == "asked":
            out["auto_cancel_at"] = (m.created_at + REMIND_AFTER + CANCEL_AFTER).isoformat()
        elif out["stage"] == "reminded" and meta.get("reminded_ts"):
            from datetime import datetime, timezone as dtz
            out["auto_cancel_at"] = (datetime.fromtimestamp(meta["reminded_ts"], tz=dtz.utc)
                                     + CANCEL_AFTER).isoformat()
    try:
        out["risk"] = risk_detail(order)
    except Exception:  # noqa: BLE001 — the risk line never blocks the card
        log.exception("bizsales cod risk")
        out["risk"] = None
    return out


def _live(ch):
    return ch is not None and ch.enabled and ch.status == "connected"


def thread_for_order(order):
    """The order's own chat; else the shop's live WhatsApp number + the
    customer's phone. None = no official channel can reach this buyer."""
    S = _S()
    t = order.thread
    if t is not None and t.business_id == order.business_id and _live(t.seller_channel):
        return t
    from .logic.business_selling import normalize_phone
    from .models import SellerChannel
    key = normalize_phone(order.customer_phone or "")
    if not key or len(key) < 10:
        return None
    wa = SellerChannel.objects.filter(business=order.business, kind=BZ.CH_WHATSAPP,
                                      status="connected", enabled=True).first()
    if wa is None:
        return None
    wa_id = "880" + key[-10:]
    return S.thread_for(wa, wa_id, order.customer_name or "")


def _send(t, order, text, lang, kind, meta):
    """Buttons inside the window; WhatsApp template outside it; never a
    message Meta forbids (send_text records 'blocked' honestly)."""
    S = _S()
    q = quick(order.pk, lang)
    m = S.send_text(t, text, kind=kind, is_ai=False, source="system",
                    meta=dict(meta, quick=q))
    if m.status == "blocked" and t.seller_channel.kind == BZ.CH_WHATSAPP:
        # outside 24 h: only an approved template (Meta) — the owner registers
        # it once (owner doc); its 2 quick-reply buttons carry our payloads
        m.delete()
        name = (S.sa_cfg().get("cod_template") or TEMPLATE_DEFAULT)
        m = S.send_template(t, name, "bn" if lang == "bn" else "en",
                            [order.customer_name or "-", str(order.pk), BZ._fmt_money(order.total)],
                            button_payloads=[x["id"] for x in q], kind=kind,
                            meta=dict(meta, quick=q, via_template=True))
    return m


def ask(order, lang=None, now=None):
    """Send the confirmation. {ok, reason, status, message_id}. reasons:
    sent | not_open_cod | already_asked | opted_out | no_channel | blocked |
    failed | queued."""
    from .logic import msg_guard as MG
    from .logic.business_selling import normalize_phone
    out = {"ok": False, "reason": "", "status": "", "message_id": None}
    if order.business_id is None or not is_open_cod(order):
        out["reason"] = "not_open_cod"
        return out
    prev = _asks(order).first()
    if prev is not None and prev.meta.get("cod_stage") in OPEN_STAGES:
        out.update(reason="already_asked", status=prev.status, message_id=prev.pk)
        return out
    t = thread_for_order(order)
    if t is None:
        out["reason"] = "no_channel"
        return out
    key = normalize_phone(order.customer_phone or "") or ("psid:" + t.external_user_id)
    if t.opted_out or MG.is_opted_out(order.business_id, key):
        out["reason"] = "opted_out"
        return out
    lang = lang or t.lang or "bn"
    m = _send(t, order, ask_text(order, order.business.shop_name, lang), lang, KIND_ASK,
              {"cod_order": order.pk, "cod_stage": "asked", "cod_lang": lang})
    ok = m.status in ("sent", "delivered", "read")
    if not ok:
        # not reachable now: never an open question nobody received
        m.meta = dict(m.meta, cod_stage="not_sent")
        m.save(update_fields=["meta"])
    out.update(ok=ok, reason="sent" if ok else m.status, status=m.status, message_id=m.pk,
               error=m.send_error or "")
    if order.thread_id is None and ok:
        order.thread = t
        order.save(update_fields=["thread"])
    return out


# ------------------------------------------------------------------ replies
def _open_ask(thread, order_id=None, now=None):
    from .models import Message
    now = now or timezone.now()
    qs = Message.objects.filter(thread=thread, kind=KIND_ASK, direction="out",
                                created_at__gte=now - MAX_AGE).order_by("-id")
    for m in qs[:20]:
        meta = m.meta or {}
        if meta.get("cod_stage") not in OPEN_STAGES:
            continue
        if order_id is None or int(meta.get("cod_order") or 0) == int(order_id):
            return m
    return None


def _short_answer(text):
    t = re.sub(r"[,.!।?]+", " ", (text or "").strip().lower())
    t = " ".join(t.split())
    if not t or len(t.split()) > _SHORT_WORDS:
        return None
    first = t.split()[0]
    if BZ.is_no(t) or first in ("না", "no", "na"):
        return "no"
    if BZ.is_yes(t) or BZ.is_yes(first):
        return "yes"
    return None


def restock(order):
    """Give the order's stock back — ONLY this shop's own products."""
    from .models import Product, ProductVariant
    uid = order.business.user_id
    for it in order.items or []:
        if it.get("product_id"):
            q = int(it.get("qty") or 1)
            Product.objects.filter(pk=it["product_id"], user_id=uid).update(stock=F("stock") + q)
            if it.get("variant"):
                ProductVariant.objects.filter(product_id=it["product_id"], product__user_id=uid,
                                              vkey=it["variant"]).update(stock=F("stock") + q)


def _close(ask_msg, stage, now):
    meta = dict(ask_msg.meta or {}, cod_stage=stage, answered_at=now.isoformat())
    ask_msg.meta = meta
    ask_msg.save(update_fields=["meta"])


def on_reply(thread, text, payload, lang):
    """None = not a COD answer (the normal agent replies). Otherwise the
    handled result string."""
    from .models import Order
    S = _S()
    m = _PAYLOAD.match(payload or "")
    if m:
        want = "yes" if m.group(1) == YES_P else "no"
        ask_msg = _open_ask(thread, int(m.group(2)))
        if ask_msg is None:
            # an old / foreign / forged button: never touches any order
            o = Order.objects.filter(pk=int(m.group(2)), business=thread.business,
                                     thread=thread).first()
            if o is None:
                return None
            S.send_text(thread, closed_text(o, lang), kind="text", is_ai=False, source="system")
            return "cod_closed"
    else:
        if (thread.order_draft or {}).get("state") == "awaiting_confirm":
            return None          # the chat order flow owns this yes/no
        want = _short_answer(text)
        if want is None:
            return None
        ask_msg = _open_ask(thread)
        if ask_msg is None:
            return None
    now = timezone.now()
    with transaction.atomic():
        o = Order.objects.select_for_update().filter(
            pk=int(ask_msg.meta.get("cod_order") or 0), business=thread.business).first()
        if o is None:
            _close(ask_msg, "closed", now)
            return None
        if not is_open_cod(o):
            _close(ask_msg, "closed", now)
            closed = True
        else:
            closed = False
            o.status = "confirmed" if want == "yes" else "cancelled"
            o.save(update_fields=["status"])
            if want == "no":
                restock(o)
            _close(ask_msg, "confirmed" if want == "yes" else "declined", now)
    biz = thread.business
    if closed:
        S.send_text(thread, closed_text(o, lang), kind="text", is_ai=False, source="system")
        return "cod_closed"
    S.send_text(thread, yes_text(o, lang) if want == "yes" else no_text(o, lang), kind="text",
                is_ai=False, source="system", meta={"cod_order": o.pk, "cod_answer": want})
    num = BZ._bn_num(o.id)
    if want == "yes":
        S.notify_seller(biz, "orders", "COD নিশ্চিত — অর্ডার #%s" % num, "COD confirmed — order #%s" % o.id,
                        "গ্রাহক অর্ডারটি নিশ্চিত করেছেন। এখন প্যাক করে পাঠাতে পারেন।",
                        "The customer confirmed the order. You can pack and ship it now.",
                        data={"order_id": str(o.id)})
        try:
            from . import bizai_service as BA
            from . import bizagent_g1_service as G1S
            agent = S.agent_for(biz)
            if not BA.check_order_risk(o, agent):
                G1S.auto_courier(o, agent, thread, lang)
        except Exception:  # noqa: BLE001 — the confirmation itself is saved
            log.exception("bizsales cod after-confirm order=%s", o.pk)
        return "cod_confirmed"
    S.notify_seller(biz, "orders", "COD বাতিল — অর্ডার #%s" % num, "COD declined — order #%s" % o.id,
                    "গ্রাহক অর্ডারটি বাতিল করেছেন। স্টক ফেরত যোগ হয়েছে।",
                    "The customer cancelled the order. The stock was added back.",
                    data={"order_id": str(o.id)})
    return "cod_declined"


# ------------------------------------------------------------------ sweep
def sweep(now=None, limit=200):
    """Per-minute cron (bizagent run_sweeps): one reminder, then cancel."""
    from .models import Message, Order
    S = _S()
    now = now or timezone.now()
    n = 0
    qs = Message.objects.filter(kind=KIND_ASK, direction="out",
                                created_at__gte=now - MAX_AGE - CANCEL_AFTER) \
        .select_related("thread", "thread__business", "thread__seller_channel").order_by("id")
    for m in qs[:limit]:
        meta = dict(m.meta or {})
        stage = meta.get("cod_stage")
        if stage not in OPEN_STAGES:
            continue
        t = m.thread
        o = Order.objects.filter(pk=int(meta.get("cod_order") or 0), business=t.business).first()
        if o is None or not is_open_cod(o):
            _close(m, "closed", now)        # the owner already decided
            continue
        lang = meta.get("cod_lang") or t.lang or "bn"
        if stage == "asked" and now - m.created_at >= REMIND_AFTER:
            r = _send(t, o, remind_text(o, lang), lang, KIND_REMIND, {"cod_order": o.pk})
            meta.update(cod_stage="reminded", reminded_at=now.isoformat(),
                        reminded_ts=now.timestamp(), remind_status=r.status)
            m.meta = meta
            m.save(update_fields=["meta"])
            n += 1
        elif stage == "reminded" and now.timestamp() - float(meta.get("reminded_ts") or 0) \
                >= CANCEL_AFTER.total_seconds():
            with transaction.atomic():
                cur = Order.objects.select_for_update().filter(pk=o.pk).first()
                if cur is None or not is_open_cod(cur):
                    _close(m, "closed", now)
                    continue
                cur.status = "cancelled"
                cur.save(update_fields=["status"])
                restock(cur)
                _close(m, "no_reply", now)
            S.send_text(t, expired_text(cur, lang), kind="text", is_ai=False, source="system",
                        meta={"cod_order": cur.pk, "cod_answer": "none"})
            S.notify_seller(t.business, "orders", "COD উত্তর নেই — অর্ডার #%s বাতিল" % BZ._bn_num(cur.id),
                            "No COD reply — order #%s cancelled" % cur.id,
                            "গ্রাহক মনে করিয়ে দেওয়ার পরেও উত্তর দেননি, তাই অর্ডারটি বাতিল হয়েছে। স্টক ফেরত যোগ হয়েছে। "
                            "দরকার হলে ফোন করে আবার অর্ডার নিন।",
                            "The customer did not reply even after the reminder, so the order was "
                            "cancelled and the stock added back. Call them to re-order if needed.",
                            data={"order_id": str(cur.id)})
            n += 1
    return n
