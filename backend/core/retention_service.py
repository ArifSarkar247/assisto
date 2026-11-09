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
from django.db.models import Count, Max, Q, Sum
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
    caps = MG.effective_caps({"per_customer_day": s.per_customer_day,
                              "per_customer_week": s.per_customer_week,
                              "business_daily": s.business_daily}, server_max())
    # bizauto: + ONE cap across every path (tagada / CRM SMS count too)
    caps["all_per_customer_day"] = MG.all_cap(cfg())
    return caps


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


def plan_ok(user):
    """`user` = the shop owner. plans-v2 ON: the central entitlement module
    (Business, founder, a running Business trial). OFF: the old rule."""
    from . import plans
    try:
        from . import entitlements_service as ES
        if ES.on(user):
            return ES.allows(user, "automation")
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
                                      "at": r["last"]}], now, p["days_without"],
                                     p.get("days_until", 0)):
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
    elif k == R.KIND_REORDER:
        out += _reorder_events(biz, now, p, limit)
    elif k == R.KIND_DELIVERY:
        out += _delivery_events(biz, now, p, limit)
    elif k == R.KIND_QUOTE:
        out += _quote_events(biz, now, p, limit)
    return out


# ---- crmauto: reorder / delivery feedback / quote follow-up sources
def _reorder_rows(biz, now, limit):
    """[{key, product, purchases, customer}] per (customer, product) over the
    last year — the shop's own sale lines, voided sales excluded."""
    from .models import SaleLine
    rows = {}
    custs = {}
    qs = (SaleLine.objects.filter(sale__in=_sales(biz).filter(
        created_at__gte=now - timedelta(days=365)))
        .select_related("sale", "sale__customer").order_by("-sale__created_at")[:limit * 10])
    for ln in qs:
        c = ln.sale.customer
        name = (ln.product_name or "").strip()
        if not c or not c.phone_key or not name:
            continue
        custs[c.phone_key] = c
        r = rows.setdefault((c.phone_key, name.lower()),
                            {"key": c.phone_key, "product": name, "purchases": []})
        if all(sid != ln.sale.id for sid, _ in r["purchases"]):
            r["purchases"].append((ln.sale.id, ln.sale.created_at))
    return list(rows.values()), custs


def _reorder_events(biz, now, p, limit):
    rows, custs = _reorder_rows(biz, now, limit)
    out = []
    for ev in R.due_reorder(rows, now, p["min_purchases"], p["days_before"]):
        c = custs[ev["key"]]
        out.append(dict(ev, customer=c, party=None, name=c.name))
    return out


def _delivery_rows(biz, now, days_after, limit):
    """Delivered online orders of this shop whose delivery (= the Sale the
    delivery created) is inside the feedback window."""
    from .models import Order
    since = now - timedelta(days=days_after + 3)
    out = []
    for o in (Order.objects.filter(business=biz, status="delivered", sale__isnull=False,
                                   sale__created_at__gte=since, sale__voided_at__isnull=True)
              .select_related("sale", "sale__customer").order_by("-id")[:limit]):
        key = (o.sale.customer.phone_key if o.sale.customer_id else "") or \
            normalize_phone(o.customer_phone or "")
        if not key:
            continue
        items = o.items if isinstance(o.items, list) else []
        first = items[0] if items and isinstance(items[0], dict) else {}
        out.append({"order_id": o.id, "key": key, "delivered_at": o.sale.created_at,
                    "product": str(first.get("name") or "")[:80],
                    "customer": o.sale.customer, "name": (o.customer_name or (
                        o.sale.customer.name if o.sale.customer_id else ""))})
    return out


def _delivery_events(biz, now, p, limit):
    rows = _delivery_rows(biz, now, p["days_after"], limit)
    by_id = {r["order_id"]: r for r in rows}
    out = []
    for ev in R.due_delivery(rows, now, p["days_after"]):
        r = by_id[int(ev["ref"].split(":")[1])]
        out.append(dict(ev, customer=r["customer"], party=None, name=r["name"]))
    return out


def quote_link(q):
    try:
        from crm import shop_quote as SQ
        return (getattr(settings, "ASSISTO_BASE_URL", "") or "").rstrip("/") + SQ.public_path(q)
    except Exception:
        return ""


def _open_quotes(biz, now, limit, since=None):
    from crm.models import ShopQuote
    qs = ShopQuote.objects.filter(business=biz, state__in=("issued", "viewed"),
                                  valid_until__gt=now).exclude(phone_key="")
    if since is not None:
        qs = qs.filter(created_at__gte=since)
    return list(qs.order_by("-created_at")[:limit])


def _quote_events(biz, now, p, limit):
    quotes = _open_quotes(biz, now, limit, since=now - timedelta(days=p["days_after"] + 3))
    by_id = {q.id: q for q in quotes}
    out = []
    for ev in R.due_quote([{"quote_id": q.id, "key": q.phone_key, "created_at": q.created_at,
                            "state": q.state, "valid_until": q.valid_until,
                            "link": quote_link(q), "total_poisha": q.total_poisha}
                           for q in quotes], now, p["days_after"]):
        q = by_id[int(ev["ref"].split(":")[1])]
        out.append(dict(ev, customer=None, party=None, name=q.customer_name))
    return out


def _in_stock(product):
    if (product.stock or 0) > 0:
        return True
    try:
        return product.variants.filter(stock__gt=0).exists()
    except Exception:
        return False


def _base_audience(auto, limit, now=None):
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
    elif k == R.KIND_REORDER:
        p = R.normalize_params(k, auto.params)
        rows, _ = _reorder_rows(biz, now or timezone.now(), limit)
        keys = {r["key"] for r in rows
                if len({MG.local(at).date() for _, at in r["purchases"]})
                >= max(2, p["min_purchases"])}
        no_phone = 0
    elif k == R.KIND_DELIVERY:
        from .models import Order
        keys = set()
        for o in (Order.objects.filter(business=biz, status="delivered")
                  .select_related("sale__customer").order_by("-id")[:limit]):
            key = (o.sale.customer.phone_key if o.sale_id and o.sale.customer_id else "") \
                or normalize_phone(o.customer_phone or "")
            if key:
                keys.add(key)
        no_phone = 0
    elif k == R.KIND_QUOTE:
        keys = {q.phone_key for q in _open_quotes(biz, now or timezone.now(), limit)}
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
    keys, no_phone = _base_audience(auto, limit, now)
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
    p = R.normalize_params(auto.kind, auto.params)
    sent_today = _sent_today(auto, now)
    will_send = max(0, min(len(due_now), p["daily_cap"] - sent_today))
    return {"cost": cost_estimate(auto, sample_text, will_send),
            "daily_cap": p["daily_cap"], "sent_today": sent_today,
            "will_send_today": will_send,
            "audience": len(keys - opted), "opted_out": len(opted & keys),
            "no_phone": no_phone, "due_now": len(due_now),
            "on_assisto": on_assisto, "on_assisto_checked": min(300, len(keys - opted))
            if auto.channel == R.CH_IN_APP else None,
            "sample_names": [e["name"] for e in due_now[:3] if e.get("name")],
            "sample_text": sample_text, "quiet_now": MG.in_quiet_hours(now),
            "next_send_at": MG.next_allowed_at(now).isoformat()}


def _sent_today(auto, now):
    from .models import RetentionSend
    if auto.pk is None:
        return 0
    return RetentionSend.objects.filter(automation=auto, status__in=MG.SENT_STATES,
                                        created_at__gte=MG.day_start(now)).count()


def cost_estimate(auto, sample_text, n):
    """Credits per message on this channel (as billing will charge it) and
    the estimate for `n` messages — shown BEFORE the owner turns it on.
    WhatsApp: free-form inside the customer's 24 h window costs nothing;
    outside it only an approved template goes, at Meta's price."""
    from . import billing
    try:
        costs = billing.cfg().get("action_costs") or {}
    except Exception:
        costs = {}

    def cr(action):
        return int((costs.get(action) or {}).get("credits") or 0)
    ch = auto.channel
    if ch == R.CH_IN_APP:
        per, basis = cr("retention_in_app"), "in_app"
    elif ch == R.CH_SMS:
        per, basis = cr("sms") * R.sms_segments(sample_text), "sms_parts"
    elif ch == R.CH_WHATSAPP:
        try:
            from . import bizagent_service as BS
            from .logic import bizagent as BZ
            cat = (auto.wa_template or {}).get("category") or "marketing"
            per = int(BZ.wa_charge_credits(cat, BS.full_cfg()))
        except Exception:
            per = 0
        basis = "wa_template"      # upper bound: 0 when inside the 24 h window
    else:
        per, basis = 0, "messenger_24h"
    owner = auto.business.user
    return {"per_message": per, "basis": basis, "estimate": per * max(0, int(n)),
            "balance": int(getattr(owner, "ai_credits", 0) or 0),
            "segments": R.sms_segments(sample_text) if ch == R.CH_SMS else None}


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
    if "total_poisha" in v:
        out["total"] = R.money_text(v["total_poisha"], lang)
    if "link" in v:
        out["link"] = v["link"]
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
    left = R.normalize_params(auto.kind, auto.params)["daily_cap"] - _sent_today(auto, now)
    for ev in events:
        if (ev["key"], ev["ref"]) in done or ev["key"] in stopped:
            continue
        if left <= 0:
            out["rule_cap"] = True
            break
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
            left -= 1
        elif s.status == "blocked":
            out["blocked"] += 1
            if s.reason in ("insufficient_credits", "guard_over"):
                break      # nothing more this tick; the owner is told in results
    auto.last_run_at = now
    auto.save(update_fields=["last_run_at"])
    if out["sent"] or out["blocked"]:
        audit(auto.business, None, "auto_run", {"id": auto.id, "kind": auto.kind,
                                                "sent": out["sent"], "blocked": out["blocked"],
                                                "rule_cap": bool(out.get("rule_cap"))})
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
    from . import sms_service
    floor = sms_service.min_credits_for(ad, parts)
    ch = (billing.charge(owner, "sms", parts, note="retention sms", min_credits=floor) if floor
          else billing.charge(owner, "sms", parts, note="retention sms"))
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
        # bizauto: the gateway's REAL per-part cost (was the USD estimate)
        from . import sms_service
        billing.record_cost("sms", round(parts * sms_service.cost_per_part(ad), 4))
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
        record_feedback(s, text)


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


# ===================================================================== crmauto: audit
AUDIT_ACTIONS = ("auto_create", "auto_on", "auto_off", "auto_edit", "auto_delete",
                 "caps_edit", "auto_run", "feedback", "opt_out_owner")


def audit(business, actor, action, detail):
    """One BizAuditLog row (never a message body or a full phone number)."""
    from .models import BizAuditLog
    try:
        BizAuditLog.objects.create(business=business, actor=actor, action=action[:32],
                                   detail=detail or {})
    except Exception:
        log.exception("retention audit failed")


def _kind_label(kind, lang):
    return {
        R.KIND_THANKS: ("ধন্যবাদ ও রিভিউ", "Thanks & review"),
        R.KIND_WINBACK: ("হারানো গ্রাহক ফেরানো", "Win-back"),
        R.KIND_KHATA: ("বাকির মনে করানো", "Due reminder"),
        R.KIND_STOCK: ("স্টক ফিরল", "Back in stock"),
        R.KIND_BIRTHDAY: ("জন্মদিন", "Birthday"),
        R.KIND_REORDER: ("আবার কেনার মনে করানো", "Reorder reminder"),
        R.KIND_DELIVERY: ("ডেলিভারির পর মতামত", "After-delivery feedback"),
        R.KIND_QUOTE: ("দামের প্রস্তাবের ফলো-আপ", "Quote follow-up"),
    }.get(kind, (kind, kind))[1 if lang == "en" else 0]


def _audit_text(row, lang):
    d = row.detail or {}
    en = lang == "en"
    n = (lambda v: str(v)) if en else (lambda v: R._bn_digits(v))
    name = d.get("name") or _kind_label(d.get("kind", ""), lang)
    a = row.action
    if a == "auto_create":
        return ("Created rule: %s (off)" if en else "নিয়ম তৈরি: %s (বন্ধ)") % name
    if a == "auto_on":
        return ("Turned ON: %s" if en else "চালু করলেন: %s") % name
    if a == "auto_off":
        return ("Turned OFF: %s" if en else "বন্ধ করলেন: %s") % name
    if a == "auto_edit":
        return ("Edited: %s" if en else "বদলালেন: %s") % name
    if a == "auto_delete":
        return ("Deleted: %s" if en else "মুছলেন: %s") % name
    if a == "caps_edit":
        return ("Limits changed: %s/day per customer, %s/week, shop %s/day" if en else
                "সীমা বদল: প্রতি গ্রাহক দিনে %s, সপ্তাহে %s, দোকান দিনে %s") % (
            n(d.get("per_customer_day", "")), n(d.get("per_customer_week", "")),
            n(d.get("business_daily", "")))
    if a == "auto_run":
        t = ("%s: sent %s, not sent %s" if en else "%s: পাঠানো %s, যায়নি %s") % (
            name, n(d.get("sent", 0)), n(d.get("blocked", 0)))
        if d.get("rule_cap"):
            t += " — daily limit reached" if en else " — দিনের সীমা পূর্ণ"
        return t
    if a == "feedback":
        return ("%s rated %s/5" if en else "%s মতামত দিলেন %s/৫") % (
            d.get("customer") or ("Customer" if en else "গ্রাহক"), n(d.get("rating", "")))
    if a == "opt_out_owner":
        return ("Stopped messages to %s (owner)" if en else "%s-কে মেসেজ বন্ধ (মালিক)") % (
            d.get("phone") or "")
    return a


def audit_rows(business, lang="bn", limit=100):
    from .models import BizAuditLog
    rows = (BizAuditLog.objects.filter(business=business, action__in=AUDIT_ACTIONS)
            .select_related("actor").order_by("-created_at", "-id")[:max(1, min(300, limit))])
    out = []
    for r in rows:
        who = getattr(r.actor, "name", "") if r.actor_id else ""
        out.append({"id": r.id, "action": r.action, "at": r.created_at.isoformat(),
                    "by": who or ("" if r.actor_id else ("Automatic" if lang == "en"
                                                           else "স্বয়ংক্রিয়")),
                    "text": _audit_text(r, lang)})
    return out


def audit_change(business, actor, before, after):
    """Owner edit of one automation -> on / off / edit rows."""
    d = {"id": after.id, "kind": after.kind, "name": after.name}
    if before is None:
        audit(business, actor, "auto_create", d)
        if after.enabled:
            audit(business, actor, "auto_on", d)
        return
    if bool(before.get("enabled")) != bool(after.enabled):
        audit(business, actor, "auto_on" if after.enabled else "auto_off", d)
    keys = ("params", "template_bn", "template_en", "channel", "send_hour", "name",
            "wa_template")
    if any(before.get(k) != getattr(after, k) for k in keys):
        audit(business, actor, "auto_edit", d)


# ===================================================================== crmauto: feedback
def record_feedback(send, text, now=None):
    """A reply to an after-delivery feedback message: a 1-5 rating is logged;
    1-2 alerts the owner at once (call before it becomes a bad review)."""
    try:
        auto = send.automation
    except Exception:
        return None
    if auto is None or auto.kind != R.KIND_DELIVERY:
        return None
    rating = R.parse_rating(text)
    if rating is None:
        return None
    audit(send.business, None, "feedback",
          {"send_id": send.pk, "rating": rating, "ref": send.ref_key,
           "customer": (send.customer_name or "")[:60]})
    if rating <= 2:
        try:
            from . import bizagent_service as BS
            nm = send.customer_name or ""
            BS.notify_seller(send.business, "unhappy_customer",
                             "অখুশি গ্রাহক: %s (%s/৫) — এখনই ফোন করুন" % (nm, R._bn_digits(rating)),
                             "Unhappy customer: %s (%s/5) — call now" % (nm, rating),
                             (text or "")[:200], (text or "")[:200],
                             data={"route": "retention_auto"})
        except Exception:
            log.exception("unhappy-customer alert failed")
    return rating


def ratings_by_key(business, keys=None, days=365):
    """{audience_key: latest rating} from the feedback audit rows."""
    from .models import BizAuditLog, RetentionSend
    rows = list(BizAuditLog.objects.filter(
        business=business, action="feedback",
        created_at__gte=timezone.now() - timedelta(days=days)).order_by("created_at")
        .values_list("detail", flat=True)[:5000])
    ids = {int(d.get("send_id") or 0): int(d.get("rating") or 0) for d in rows
           if isinstance(d, dict)}
    keymap = dict(RetentionSend.objects.filter(pk__in=list(ids)).values_list("pk", "audience_key"))
    out = {}
    for sid, rating in ids.items():      # dict keeps insertion order = oldest first
        k = keymap.get(sid)
        if k and (keys is None or k in keys):
            out[k] = rating
    return out


# ===================================================================== crmauto: score
def scores(business, lang="bn", limit=50, q=""):
    """Every customer (and open-quote lead) of this shop with a transparent
    0-100 score and the rules behind it, best first."""
    from .logic import customer_score as CS
    from .models import Customer, Order, RetentionSend
    now = timezone.now()
    yr = now - timedelta(days=365)
    scan = cfg()["max_audience_scan"]
    agg = {}
    for r in (_sales(business).filter(created_at__gte=yr).order_by().values("customer__phone_key")
              .annotate(n=Count("id"), spend=Sum("total"), last=Max("created_at"))[:scan]):
        agg[r["customer__phone_key"]] = r
    people = {}
    for c in (Customer.objects.filter(_cust_q(business)).exclude(phone_key="")
              .order_by("-id")[:scan]):
        people.setdefault(c.phone_key, {"name": c.name, "customer_id": c.id})
    quotes = _open_quotes(business, now, scan)
    open_q = {qq.phone_key for qq in quotes}
    for qq in quotes:
        people.setdefault(qq.phone_key, {"name": qq.customer_name, "customer_id": None})
    if q:
        ql = q.strip().lower()
        qk = normalize_phone(q) or "\x00"
        people = {k: v for k, v in people.items()
                  if ql in (v["name"] or "").lower() or qk in k}
    keys = set(people)
    due = {key: d for _, key, d in _khata_due(business, scan)}
    returns = {}
    for ph in (Order.objects.filter(business=business, status__in=("returned", "cancelled"),
                                    created_at__gte=yr).values_list("customer_phone", flat=True)[:scan]):
        k = normalize_phone(ph or "")
        if k:
            returns[k] = returns.get(k, 0) + 1
    replied = set(RetentionSend.objects.filter(business=business, replied_at__gte=now - timedelta(days=30))
                  .values_list("audience_key", flat=True))
    ratings = ratings_by_key(business, keys)
    opted = MG.opted_out_keys(business.id)
    out = []
    for k, who in people.items():
        a = agg.get(k)
        sig = {"days_since_last": (now - a["last"]).days if a else None,
               "purchases": a["n"] if a else 0, "spend_poisha": int(a["spend"] or 0) if a else 0,
               "due_poisha": max(0, due.get(k, 0)), "returns": returns.get(k, 0),
               "replied_recent": k in replied, "open_quote": k in open_q,
               "last_rating": ratings.get(k), "opted_out": k in opted}
        r = CS.score(sig, lang)
        if not r["parts"] and not r["do_not_message"]:
            continue          # nothing known about this person yet — no fake score
        out.append(dict(r, key_masked=R.mask_phone(k), name=who["name"] or "",
                        customer_id=who["customer_id"], lead=a is None))
    out.sort(key=lambda x: (-x["score"], x["name"]))
    return {"people": out[:max(1, min(200, limit))], "total": len(out),
            "rule_book": CS.rule_book(lang)}
