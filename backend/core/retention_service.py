"""
retention_service.py — RETENTION AUTOMATION (big-week H): the DB + channel
side of core/logic/retention.py. Every send goes through core/logic/msg_guard
(caps, quiet hours 21:00-09:00 Dhaka, STOP across all automations of the
business, Meta 24 h window / template rules).

Channels, in order of preference:
  in_app     the customer's Assisto account (matched by the phone the shop
             already has) — a notification-centre item + push with "Reply"
             and "Stop". Free (credits row retention_in_app = 0), capped.
  whatsapp   ONLY through the business's connected WhatsApp Cloud API channel
             (business AI agent). Inside 24 h of the customer's last message:
             free-form text; outside: ONLY an approved template (Meta bills
             it; the existing webhook charge_wa_billable debits credits, we
             refuse up front when the balance cannot cover it).
  messenger  ONLY inside the 24 h window of the customer's own chat.
  sms        ONLY through the owner-connected SMS gateway, charged per SMS
             part from credits ("sms" action) before sending, refunded if the
             gateway fails; refused at zero balance. Carries a stop link.

Never: purchased lists, strangers, cold calls, unlimited sends.
"""
import hashlib
import hmac
import logging
from datetime import timedelta

from django.conf import settings
from django.db import IntegrityError, transaction
from django.db.models import Max, Q, Sum
from django.utils import timezone

from .logic import msg_guard as MG
from .logic import retention as R
from .logic.business_selling import normalize_phone

log = logging.getLogger("assisto.retention")

FLAG = "retention_auto"
ALLOWED_PLANS = ("business", "founder")


# ===================================================================== config
def cfg():
    from . import billing
    from .logic import pricing
    try:
        return pricing.retention_cfg(billing.cfg())
    except Exception:
        return pricing.retention_cfg({})


def server_max():
    return MG.server_caps(cfg())


def settings_for(business):
    from .models import RetentionSettings
    row, _ = RetentionSettings.objects.get_or_create(business=business)
    return row


def caps_for(business):
    s = settings_for(business)
    return MG.effective_caps({"per_customer_day": s.per_customer_day,
                              "per_customer_week": s.per_customer_week,
                              "business_daily": s.business_daily}, server_max())


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


def plan_ok(user):
    from . import plans
    try:
        return plans.effective_plan(user) in ALLOWED_PLANS
    except Exception:
        return False


def shop_name(business):
    return (business.shop_name or getattr(business.user, "name", "") or "").strip()[:60]


def _channel(business, kind):
    from .models import SellerChannel
    return (SellerChannel.objects.filter(business=business, kind=kind, enabled=True)
            .exclude(status="disabled").order_by("-test_mode", "id").first())


def channels_ready(business):
    out = [R.CH_IN_APP]
    if _channel(business, "whatsapp_cloud"):
        out.append(R.CH_WHATSAPP)
    if _channel(business, "messenger"):
        out.append(R.CH_MESSENGER)
    try:
        from . import sms_gateway
        if sms_gateway.adapter() is not None:
            out.append(R.CH_SMS)
    except Exception:
        pass
    return out


# ===================================================================== audience
def _cust_q(business):
    # legacy single-shop rows carry business=NULL + user=owner
    return Q(business=business) | Q(business__isnull=True, user=business.user)


def _sales(business):
    from .models import Sale
    return Sale.objects.filter(_cust_q(business), voided_at__isnull=True,
                               customer__isnull=False).exclude(customer__phone_key="")


def _khata_due(business, limit):
    """[(party, key, due_poisha)] for customer-book parties with a phone."""
    from .models import KhataEntry, KhataParty
    parties = list(KhataParty.objects.filter(business=business, book="customer",
                                             archived=False).exclude(phone="")[:limit])
    if not parties:
        return []
    sums = {}
    for row in (KhataEntry.objects.filter(party__in=parties).values("party_id", "direction")
                .annotate(t=Sum("amount_poisha"))):
        sums.setdefault(row["party_id"], 0)
        sums[row["party_id"]] += row["t"] if row["direction"] == "gave" else -row["t"]
    out = []
    for p in parties:
        key = normalize_phone(p.phone)
        if key:
            out.append((p, key, int(sums.get(p.id, 0))))
    return out


def _events(auto, now, limit):
    """All trigger events due now for this automation (before the guard):
    [{key, ref, values, customer, party, name}]."""
    from .models import Customer, RetentionStockAsk
    biz = auto.business
    k = auto.kind
    p = R.normalize_params(k, auto.params)
    out = []
    if k == R.KIND_THANKS:
        since = now - timedelta(days=p["days_after"] + 3)
        seen = set()
        for s in (_sales(biz).filter(created_at__gte=since).select_related("customer")
                  .prefetch_related("lines").order_by("-created_at")[:limit]):
            c = s.customer
            if c.phone_key in seen:
                continue
            seen.add(c.phone_key)
            first = next(iter(s.lines.all()), None)
            for ev in R.due_thanks([{"sale_id": s.id, "key": c.phone_key, "at": s.created_at,
                                     "product": first.product_name if first else ""}],
                                   now, p["days_after"]):
                out.append(dict(ev, customer=c, party=None, name=c.name))
    elif k == R.KIND_WINBACK:
        rows = list(_sales(biz).values("customer_id").annotate(last=Max("created_at"))
                    .filter(last__lte=now - timedelta(days=p["days_without"]))[:limit])
        custs = {c.id: c for c in Customer.objects.filter(id__in=[r["customer_id"] for r in rows])}
        for r in rows:
            c = custs.get(r["customer_id"])
            if not c or not c.phone_key:
                continue
            last = _sales(biz).filter(customer=c, created_at=r["last"]).order_by("-id").first()
            for ev in R.due_winback([{"key": c.phone_key, "last_sale_id": last.id if last else 0,
                                      "at": r["last"]}], now, p["days_without"]):
                out.append(dict(ev, customer=c, party=None, name=c.name))
    elif k == R.KIND_KHATA:
        rows = _khata_due(biz, limit)
        by_id = {party.id: party for party, _, _ in rows}
        for ev in R.due_khata([{"party_id": party.id, "key": key, "due_poisha": due}
                               for party, key, due in rows], now, p["min_due_taka"],
                              p["every_days"]):
            party = by_id[int(ev["ref"].split(":")[1])]
            out.append(dict(ev, customer=None, party=party, name=party.name))
    elif k == R.KIND_BIRTHDAY:
        custs = list(Customer.objects.filter(_cust_q(biz), birthday__isnull=False,
                                             sales__voided_at__isnull=True)
                     .exclude(phone_key="").distinct()[:limit])
        by_key = {c.phone_key: c for c in custs}
        for ev in R.due_birthday([{"key": c.phone_key, "birthday": c.birthday} for c in custs], now):
            c = by_key[ev["key"]]
            out.append(dict(ev, customer=c, party=None, name=c.name))
    elif k == R.KIND_STOCK:
        asks = list(RetentionStockAsk.objects.filter(business=biz, notified_at__isnull=True)
                    .select_related("product", "customer")[:limit])
        by_id = {a.id: a for a in asks}
        for ev in R.due_stock([{"ask_id": a.id, "key": a.customer.phone_key,
                                "product": a.product.name, "in_stock": _in_stock(a.product),
                                "notified": False} for a in asks if a.customer.phone_key]):
            a = by_id[int(ev["ref"].split(":")[1])]
            out.append(dict(ev, customer=a.customer, party=None, name=a.customer.name))
    return out


def _in_stock(product):
    if (product.stock or 0) > 0:
        return True
    try:
        return product.variants.filter(stock__gt=0).exists()
    except Exception:
        return False


def _base_audience(auto, limit):
    """(people, keys, no_phone) — everyone this kind could ever reach."""
    from .models import Customer, RetentionStockAsk
    biz = auto.business
    k = auto.kind
    if k in (R.KIND_THANKS, R.KIND_WINBACK):
        ids = _sales(biz).values_list("customer_id", flat=True).distinct()
        keys = set(Customer.objects.filter(id__in=ids[:limit]).values_list("phone_key", flat=True))
        no_phone = (Customer.objects.filter(_cust_q(biz), phone_key="", sales__isnull=False)
                    .distinct().count())
    elif k == R.KIND_KHATA:
        p = R.normalize_params(k, auto.params)
        keys = {key for _, key, due in _khata_due(biz, limit) if due >= p["min_due_taka"] * 100}
        from .models import KhataParty
        no_phone = KhataParty.objects.filter(business=biz, book="customer", archived=False,
                                             phone="").count()
    elif k == R.KIND_BIRTHDAY:
        keys = set(Customer.objects.filter(_cust_q(biz), birthday__isnull=False)
                   .exclude(phone_key="").values_list("phone_key", flat=True)[:limit])
        no_phone = 0
    else:
        keys = set(RetentionStockAsk.objects.filter(business=biz, notified_at__isnull=True)
                   .values_list("customer__phone_key", flat=True)[:limit])
        no_phone = 0
    keys.discard("")
    return keys, no_phone


def preview(auto, now=None, lang="bn"):
    """Audience preview with honest counts + one rendered sample message."""
    now = now or timezone.now()
    limit = cfg()["max_audience_scan"]
    keys, no_phone = _base_audience(auto, limit)
    opted = MG.opted_out_keys(auto.business_id) & keys
    events = _events(auto, now, limit) if auto.kind in R.KINDS else []
    due_now = [e for e in events if e["key"] not in opted]
    done = set(_done_refs(auto, due_now))
    due_now = [e for e in due_now if (e["key"], e["ref"]) not in done]
    on_assisto = None
    if auto.channel == R.CH_IN_APP:
        from . import phone as PH
        sample = list(keys - opted)[:300]
        on_assisto = sum(1 for k in sample if PH.find_user(k) is not None)
    ev = due_now[0] if due_now else {"values": {}, "name": ""}
    sample_text = R.compose(R.pick_template(lang, auto.template_bn, auto.template_en),
                            _values(auto, ev, lang), lang, auto.channel,
                            link=(_stop_base() + "…") if auto.channel == R.CH_SMS else "")
    return {"audience": len(keys - opted), "opted_out": len(opted & keys),
            "no_phone": no_phone, "due_now": len(due_now),
            "on_assisto": on_assisto, "on_assisto_checked": min(300, len(keys - opted))
            if auto.channel == R.CH_IN_APP else None,
            "sample_names": [e["name"] for e in due_now[:3] if e.get("name")],
            "sample_text": sample_text, "quiet_now": MG.in_quiet_hours(now),
            "next_send_at": MG.next_allowed_at(now).isoformat()}


def _done_refs(auto, events):
    from .models import RetentionSend
    refs = [e["ref"] for e in events]
    # a draft preview (unsaved automation) has sent nothing yet
    if not refs or auto.pk is None:
        return []
    return list(RetentionSend.objects.filter(automation=auto, ref_key__in=refs)
                .values_list("audience_key", "ref_key"))


def _values(auto, ev, lang):
    v = dict(ev.get("values") or {})
    out = {"name": (ev.get("name") or "").strip(), "shop": shop_name(auto.business),
           "product": v.get("product") or ""}
    if "days" in v:
        out["days"] = R._bn_digits(v["days"]) if lang != "en" else v["days"]
    if "due_poisha" in v:
        out["due"] = R.money_text(v["due_poisha"], lang)
    return out


# ===================================================================== stop link
def _stop_sig(send_id):
    key = (settings.SECRET_KEY + ":retention-stop").encode()
    return hmac.new(key, str(send_id).encode(), hashlib.sha256).hexdigest()[:10]


def _stop_base():
    return (getattr(settings, "ASSISTO_BASE_URL", "") or "").rstrip("/") + "/api/v1/retention/u/"


def stop_link(send_id):
    return "%s%s-%s" % (_stop_base(), send_id, _stop_sig(send_id))


def send_for_token(token):
    from .models import RetentionSend
    try:
        sid, sig = str(token).split("-", 1)
        sid = int(sid)
    except (ValueError, TypeError):
        return None
    if not hmac.compare_digest(sig, _stop_sig(sid)):
        return None
    return RetentionSend.objects.filter(pk=sid).select_related("business").first()


def opt_out_send(send, source):
    """STOP from one message -> the WHOLE business (every automation, every
    channel). Instant; idempotent."""
    now = timezone.now()
    MG.record_opt_out(send.business_id, send.audience_key, source)
    if not send.opted_out_at:
        send.opted_out_at = now
        send.save(update_fields=["opted_out_at"])
    return True


# ===================================================================== run
def run_all(now=None):
    """The scheduler tick (management command retention_run, every 15 min).
    Returns {"automations": n, "sent": n}."""
    from .models import RetentionAutomation
    now = now or timezone.now()
    stats = {"automations": 0, "sent": 0, "blocked": 0}
    if MG.in_quiet_hours(now):
        return stats
    seen_biz = set()
    for auto in (RetentionAutomation.objects.filter(enabled=True)
                 .select_related("business", "business__user").order_by("business_id", "id")):
        owner = auto.business.user
        if not plan_ok(owner) or not flag_on(owner):
            continue
        r = run_automation(auto, now)
        stats["automations"] += 1
        stats["sent"] += r["sent"]
        stats["blocked"] += r["blocked"]
        seen_biz.add(auto.business_id)
    from .models import BusinessProfile
    for biz in BusinessProfile.objects.filter(id__in=seen_biz):
        try:
            attribute_business(biz, now)
        except Exception:
            log.exception("retention attribution failed biz=%s", biz.id)
    return stats


def run_automation(auto, now):
    out = {"sent": 0, "blocked": 0}
    if MG.in_quiet_hours(now) or MG.local(now).hour < auto.send_hour:
        return out
    caps = caps_for(auto.business)
    events = _events(auto, now, cfg()["max_audience_scan"])
    done = set(_done_refs(auto, events))
    stopped = MG.opted_out_keys(auto.business_id) if events else set()
    for ev in events:
        if (ev["key"], ev["ref"]) in done or ev["key"] in stopped:
            continue
        v = MG.gate(auto.business_id, ev["key"], now=now, caps=caps, opted_out_set=stopped)
        if not v.ok:
            if v.reason == "business_daily_cap":
                break
            continue
        s = send_one(auto, ev, now)
        if s is None:
            continue
        done.add((ev["key"], ev["ref"]))
        if s.status in MG.SENT_STATES:
            out["sent"] += 1
        elif s.status == "blocked":
            out["blocked"] += 1
            if s.reason in ("insufficient_credits", "guard_over"):
                break      # nothing more this tick; the owner is told in results
    auto.last_run_at = now
    auto.save(update_fields=["last_run_at"])
    return out


def _lang_for(auto, recipient=None, thread=None):
    if recipient is not None:
        lang = (getattr(recipient, "language", "") or "bn")[:2]
    elif thread is not None:
        lang = thread.lang or "bn"
    else:
        lang = "bn"
    lang = "en" if lang == "en" else "bn"
    if lang == "en" and not auto.template_en:
        return "bn"
    if lang == "bn" and not auto.template_bn:
        return "en"
    return lang


def send_one(auto, ev, now):
    """Create the RetentionSend row for one event and deliver it on the
    automation's channel. Returns the row (None if another worker won)."""
    from .models import RetentionSend
    try:
        with transaction.atomic():
            s = RetentionSend.objects.create(
                automation=auto, business=auto.business, audience_key=ev["key"][:80],
                ref_key=ev["ref"][:80], customer=ev.get("customer"), party=ev.get("party"),
                customer_name=(ev.get("name") or "")[:120], channel=auto.channel,
                status="sending", created_at=now)
    except IntegrityError:
        return None
    try:
        fn = {R.CH_IN_APP: _send_in_app, R.CH_SMS: _send_sms,
              R.CH_WHATSAPP: _send_whatsapp, R.CH_MESSENGER: _send_messenger}[auto.channel]
        fn(auto, ev, s, now)
    except Exception as e:  # noqa: BLE001 — one bad send never stops the run
        log.exception("retention send failed")
        s.status, s.reason = "failed", ("error:%s" % type(e).__name__)[:60]
    s.save()
    if s.status in MG.SENT_STATES and auto.kind == R.KIND_STOCK:
        from .models import RetentionStockAsk
        RetentionStockAsk.objects.filter(pk=int(ev["ref"].split(":")[1])).update(notified_at=now)
    return s


def _text(auto, ev, lang, channel, link=""):
    return R.compose(R.pick_template(lang, auto.template_bn, auto.template_en),
                     _values(auto, ev, lang), lang, channel, link)


def _send_in_app(auto, ev, s, now):
    from . import billing, push
    from . import phone as PH
    from .models import NotifEvent
    owner = auto.business.user
    rec = PH.find_user(ev["key"])
    if rec is None or rec.pk == owner.pk or not rec.is_active:
        s.status, s.reason = "skipped", "not_on_assisto"
        return
    if not flag_on(rec):
        s.status, s.reason = "skipped", "recipient_not_enabled"
        return
    ch = billing.charge(owner, "retention_in_app", 1, note="retention in-app")
    if not ch["ok"]:
        s.status, s.reason = "blocked", ("insufficient_credits" if ch["reason"] == "insufficient"
                                         else ch["reason"])[:60]
        return
    s.credits = ch["charged"]
    lang = _lang_for(auto, recipient=rec)
    s.lang, s.recipient = lang, rec
    s.text = _text(auto, ev, lang, R.CH_IN_APP)
    shop = shop_name(auto.business) or ("Shop" if lang == "en" else "দোকান")
    t_bn, t_en = "%s থেকে মেসেজ" % shop, "Message from %s" % shop
    NotifEvent.objects.create(user=rec, type="business", title_bn=t_bn[:200], title_en=t_en[:200],
                              body_bn=s.text if lang != "en" else "",
                              body_en=s.text if lang == "en" else "",
                              route="retention_inbox",
                              meta={"source": "retention", "send_id": s.pk})
    s.status = "sent"
    # "delivered" is set only when the customer's app actually loads it
    # (inbox fetch) — a queued push is not proof of delivery.
    push.safe_push(rec, "offer", t_bn, t_en, s.text, s.text,
                   data={"route": "retention_inbox", "send_id": s.pk})


def _send_sms(auto, ev, s, now):
    from . import billing, sms_gateway
    from . import phone as PH
    from .logic import pricing
    ad = sms_gateway.adapter()
    if ad is None:
        s.status, s.reason = "blocked", "sms_not_connected"
        return
    to = PH.canonical_bd(ev["key"])
    if not to:
        s.status, s.reason = "skipped", "bad_phone"
        return
    lang = _lang_for(auto)
    s.lang = lang
    s.text = _text(auto, ev, lang, R.CH_SMS, link=stop_link(s.pk))
    parts = R.sms_segments(s.text)
    owner = auto.business.user
    ch = billing.charge(owner, "sms", parts, note="retention sms")
    if not ch["ok"]:
        s.status, s.reason = "blocked", ("insufficient_credits" if ch["reason"] == "insufficient"
                                         else ch["reason"])[:60]
        return
    s.credits = ch["charged"]
    ok, detail = ad.send(to, s.text)
    if not ok:
        if ch["charged"]:
            billing.credit(owner, "adjust", ch["charged"], note="retention sms refund")
        s.credits = 0
        s.status, s.reason = "failed", ("sms:%s" % detail)[:60]
        return
    s.status = "sent"
    try:
        c = billing.cfg()
        row = c["action_costs"].get("sms") or {}
        billing.record_cost("sms", float(row.get("provider_cost", 0)) * c["usd_bdt"] * parts)
    except Exception:
        pass


def _thread_for_key(business, kinds, key):
    from .models import ChatThread
    for t in (ChatThread.objects.filter(business=business, channel__in=kinds)
              .exclude(customer_phone="").order_by("-last_inbound_at", "-id")[:3000]):
        if normalize_phone(t.customer_phone) == key:
            return t
    return None


def _map_msg(s, m):
    s.chat_message = m
    if m.status in ("sent", "delivered", "read"):
        s.status = m.status
        if m.status in ("delivered", "read"):
            s.delivered_at = timezone.now()
    elif m.status == "queued":
        s.status, s.reason = "blocked", (m.send_error or "queued")[:60]
    elif m.status == "blocked":
        s.status, s.reason = "blocked", (m.send_error or "blocked")[:60]
    else:
        s.status, s.reason = "failed", (m.send_error or "failed")[:60]


def _send_whatsapp(auto, ev, s, now):
    from . import bizagent_service as S
    from .logic import bizagent as BZ
    from .logic import business_ai as bai
    ch = _channel(auto.business, "whatsapp_cloud")
    if ch is None:
        s.status, s.reason = "blocked", "whatsapp_not_connected"
        return
    t = _thread_for_key(auto.business, ("whatsapp_cloud",), ev["key"])
    if t is None:
        from . import phone as PH
        canon = PH.canonical_bd(ev["key"])
        if not canon:
            s.status, s.reason = "skipped", "bad_phone"
            return
        t = S.thread_for(ch, canon.lstrip("+"), ev.get("name") or "")
    s.thread = t
    lang = _lang_for(auto, thread=t)
    s.lang = lang
    last_in = t.last_inbound_at.timestamp() if t.last_inbound_at else None
    within = bai.within_service_window(last_in, now.timestamp())
    purpose = R.CATALOG[auto.kind]["purpose"]
    mode, reason = MG.meta_plan("whatsapp", within, auto.wa_template, purpose)
    if mode == "blocked":
        s.status, s.reason = "blocked", reason
        return
    if mode == "free_form":
        s.text = _text(auto, ev, lang, R.CH_WHATSAPP)
        m = S.send_text(t, s.text, kind="text", is_ai=False, source="system",
                        meta={"retention_send": s.pk})
        _map_msg(s, m)
        return
    wt = auto.wa_template or {}
    need = BZ.wa_charge_credits(wt.get("category") or "marketing", S.full_cfg())
    owner = auto.business.user
    from . import billing
    billing.ensure_monthly_pool(owner)
    owner.refresh_from_db(fields=["ai_credits"])
    if need > int(owner.ai_credits or 0):
        s.status, s.reason = "blocked", "insufficient_credits"
        return
    s.credits = need       # debited by Meta's billable status webhook (charge_wa_billable)
    vals = _values(auto, ev, lang)
    s.text = "[template:%s] %s" % (wt.get("name"), vals.get("name") or "")
    m = S.send_template(t, wt.get("name"), wt.get("lang") or lang,
                        params=[vals.get("name") or ""])
    _map_msg(s, m)


def _send_messenger(auto, ev, s, now):
    from . import bizagent_service as S
    from .logic import business_ai as bai
    t = _thread_for_key(auto.business, ("messenger",), ev["key"])
    if t is None:
        s.status, s.reason = "blocked", "no_chat_on_channel"
        return
    s.thread = t
    lang = _lang_for(auto, thread=t)
    s.lang = lang
    last_in = t.last_inbound_at.timestamp() if t.last_inbound_at else None
    mode, reason = MG.meta_plan("messenger",
                                bai.within_service_window(last_in, now.timestamp()))
    if mode == "blocked":
        s.status, s.reason = "blocked", reason
        return
    s.text = _text(auto, ev, lang, R.CH_MESSENGER)
    m = S.send_text(t, s.text, kind="text", is_ai=False, source="system",
                    meta={"retention_send": s.pk})
    _map_msg(s, m)


# ===================================================================== inbound hook
def on_inbound(thread, text, now=None):
    """Called by the business agent for every customer message on an official
    channel: a reply to a recent automated message counts as 'replied'; a
    STOP opts the customer out of every automation of that business."""
    from .models import RetentionSend
    now = now or timezone.now()
    s = (RetentionSend.objects.filter(thread=thread, status__in=MG.SENT_STATES,
                                      created_at__gte=now - timedelta(days=7))
         .order_by("-created_at").first())
    if MG.is_stop_text(text):
        key = normalize_phone(thread.customer_phone) if thread.customer_phone else (
            "psid:" + thread.external_user_id if thread.external_user_id else "")
        if key and thread.business_id:
            MG.record_opt_out(thread.business_id, key, "chat")
        if s is not None and not s.opted_out_at:
            s.opted_out_at = now
            s.save(update_fields=["opted_out_at"])
        return
    if s is not None and not s.replied_at:
        s.replied_at, s.reply_text = now, (text or "")[:500]
        s.save(update_fields=["replied_at", "reply_text"])


# ===================================================================== results
def _sync_meta_status(sends):
    from .models import RetentionSend
    for s in sends:
        m = s.chat_message
        if m is None:
            continue
        new = None
        if m.status in ("delivered", "read") and s.status == "sent":
            new = m.status
        elif m.status == "read" and s.status == "delivered":
            new = "read"
        elif m.status == "failed" and s.status in ("sent",):
            new = "failed"
        if new:
            upd = {"status": new}
            if new in ("delivered", "read") and not s.delivered_at:
                upd["delivered_at"] = timezone.now()
            RetentionSend.objects.filter(pk=s.pk).update(**upd)
            for k, v in upd.items():
                setattr(s, k, v)


def attribute_business(business, now=None):
    """Write purchase attribution for recent sends (honest last-touch inside
    the attribution window; each sale once)."""
    from .models import RetentionSend, Sale
    now = now or timezone.now()
    win = cfg()["attribution_days"]
    sends = list(RetentionSend.objects.filter(
        business=business, status__in=MG.SENT_STATES, purchase_sale__isnull=True,
        created_at__gte=now - timedelta(days=win * 2)).values("id", "audience_key", "created_at"))
    if not sends:
        return 0
    taken = set(RetentionSend.objects.filter(business=business, purchase_sale__isnull=False)
                .values_list("purchase_sale_id", flat=True))
    keys = {s["audience_key"] for s in sends}
    earliest = min(s["created_at"] for s in sends)
    sales = [{"id": x.id, "key": x.customer.phone_key, "at": x.created_at, "total": x.total}
             for x in _sales(business).filter(created_at__gt=earliest,
                                              customer__phone_key__in=keys)
             .select_related("customer")[:5000] if x.id not in taken]
    got = R.attribute([{"id": s["id"], "key": s["audience_key"], "at": s["created_at"]}
                       for s in sends], sales, win)
    for sid, (sale_id, total) in got.items():
        RetentionSend.objects.filter(pk=sid, purchase_sale__isnull=True).update(
            purchase_sale_id=sale_id, purchase_poisha=int(total or 0))
    return len(got)


def _payments_after(sends, win):
    """khata_due: a 'got' (payment) entry from that party within the window."""
    from .models import KhataEntry
    n = 0
    for s in sends:
        if s.party_id and s.status in MG.SENT_STATES and KhataEntry.objects.filter(
                party_id=s.party_id, direction="got", at__gt=s.created_at,
                at__lte=s.created_at + timedelta(days=win)).exists():
            n += 1
    return n


def results(auto, now=None, recent=30):
    from .models import RetentionSend
    now = now or timezone.now()
    try:
        attribute_business(auto.business, now)
    except Exception:
        log.exception("attribution")
    qs = RetentionSend.objects.filter(automation=auto).select_related("chat_message")
    rows = list(qs[:2000])
    _sync_meta_status(rows)
    sent = [s for s in rows if s.status in MG.SENT_STATES]
    win = cfg()["attribution_days"]
    reasons = {}
    for s in rows:
        if s.status in ("blocked", "skipped", "failed"):
            reasons[s.reason or s.status] = reasons.get(s.reason or s.status, 0) + 1
    out = {
        "sent": len(sent),
        "delivered": sum(1 for s in sent if s.status in ("delivered", "read") or s.delivered_at),
        "read": sum(1 for s in sent if s.status == "read" or s.read_at),
        "replied": sum(1 for s in rows if s.replied_at),
        "opted_out": sum(1 for s in rows if s.opted_out_at),
        "purchases": sum(1 for s in rows if s.purchase_sale_id),
        "revenue_poisha": sum(s.purchase_poisha for s in rows if s.purchase_sale_id),
        "credits": sum(s.credits for s in rows),
        "not_sent": sum(reasons.values()),
        "not_sent_reasons": reasons,
        "attribution_days": win,
    }
    if auto.kind == R.KIND_KHATA:
        out["payments_after"] = _payments_after(sent[:500], win)
    out["recent"] = [send_row(s) for s in rows[:recent]]
    return out


def send_row(s):
    return {"id": s.pk, "name": s.customer_name, "phone": R.mask_phone(s.audience_key),
            "channel": s.channel, "status": s.status, "reason": s.reason,
            "at": s.created_at.isoformat(), "replied": bool(s.replied_at),
            "reply_text": s.reply_text, "opted_out": bool(s.opted_out_at),
            "purchase_poisha": s.purchase_poisha if s.purchase_sale_id else 0,
            "text": s.text}


def summary(auto):
    from .models import RetentionSend
    qs = RetentionSend.objects.filter(automation=auto)
    return {"sent": qs.filter(status__in=MG.SENT_STATES).count(),
            "replied": qs.filter(replied_at__isnull=False).count(),
            "purchases": qs.filter(purchase_sale__isnull=False).count(),
            "opted_out": qs.filter(opted_out_at__isnull=False).count()}
