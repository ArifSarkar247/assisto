"""
sales2 — AI sales chat -> CRM lead + one customer history (owner order 28 Oct).

When a sales-agent chat shows BUYING INTENT (an order being collected, a
price agreed / asked below the floor, a big order, a confirmed order) the
customer becomes a CRM lead of the seller's own CRM org, and the chat's phone
is stored on the thread so crm100 (crm/customer360.py) shows the chat, the
order and the lead on ONE customer page.

Rules (honest, never in the way of a reply):
  * only the seller's OWN CRM org (CrmOrg.owner == the shop owner); no org =
    nothing created (we never open a CRM for the seller behind their back);
  * the CRM plan limits apply exactly as in the app (plans_v2: crm_write +
    contact room) — a full CRM is never pushed over its limit;
  * one lead per phone (last 10 digits), never a duplicate; a lead without a
    real Bangladesh mobile number is never made (Messenger chats wait until
    the customer gives a number in the order flow);
  * the lead's note carries what the customer wanted (product × qty) from the
    shop's OWN catalog row and a pointer to the chat — no price floor, no
    cost, no other customer's data;
  * a confirmed order marks the lead won; best-effort: any error is logged,
    the customer's reply is never blocked.
"""
import logging

from django.utils import timezone

from .logic import bizagent as BZ

log = logging.getLogger(__name__)

SOURCE = {"whatsapp_cloud": "whatsapp", "messenger": "messenger"}
CHANNEL_LABEL = {"whatsapp_cloud": "WhatsApp", "messenger": "Messenger",
                 "instagram": "Instagram", "website": "Website chat"}
MARK = "[AI sales]"
OPEN_STATUSES = ("new", "contacted", "demo", "proposal")
INTENT_RULES = ("bargain", "last_price")
INTENT_RISKS = (BZ.RISK_BELOW_MIN, BZ.RISK_BIG_ORDER)


def buying_intent(thread, d):
    """True when this reply shows the customer is buying (deterministic)."""
    d = d or {}
    draft = thread.order_draft or {}
    if d.get("order_action") == "cancel":
        return False
    return bool(d.get("kind") == "order" or d.get("order_action") == "confirm"
                or draft.get("active") or draft.get("state") == "awaiting_confirm"
                or d.get("rule") in INTENT_RULES or d.get("risk") in INTENT_RISKS)


def phone_of(thread):
    """The customer's real BD mobile: the order draft's, else the thread's
    (a WhatsApp wa_id is a phone)."""
    draft = thread.order_draft or {}
    for raw in (draft.get("phone"), thread.customer_phone,
                thread.external_user_id if thread.channel == BZ.CH_WHATSAPP else ""):
        p = BZ.normalize_bd_phone(raw or "")
        if p:
            return p
    return ""


def note(thread, d=None, *, order=None):
    """Best effort. Returns 'created' | 'updated' | 'won' | a skip reason."""
    try:
        return _note(thread, d, order)
    except Exception:  # noqa: BLE001
        log.warning("bizagent_crm: lead update failed for thread %s", getattr(thread, "pk", None),
                    exc_info=True)
        return "error"


def _want_line(thread, order):
    if order is not None:
        items = order.items or []
        bits = ["%s × %s" % (i.get("name", ""), i.get("qty", 1)) for i in items[:3]]
        return "order #%s: %s" % (order.id, ", ".join(bits))
    draft = thread.order_draft or {}
    name = draft.get("product") or (draft.get("focus") or {}).get("name") or ""
    if not name:
        return "asked about products"
    return "wants %s × %s" % (name, draft.get("qty") or 1)


def _note(thread, d, order):
    if thread is None or thread.business_id is None:
        return "no_business"
    if order is None and not buying_intent(thread, d):
        return "no_intent"
    phone = phone_of(thread) or (BZ.normalize_bd_phone(order.customer_phone)
                                 if order is not None else "")
    if not phone:
        return "no_phone"
    # a WhatsApp chat IS a number: the lead is that person even when the
    # order's contact number differs (one lead per chat, never two)
    wa = BZ.normalize_bd_phone(thread.external_user_id) \
        if thread.channel == BZ.CH_WHATSAPP else ""
    # the chat is now one customer page (crm100 matches on customer_phone)
    if not thread.customer_phone:
        thread.customer_phone = phone
        thread.save(update_fields=["customer_phone"])
    from crm.models import CrmOrg, Lead
    owner = thread.business.user
    org = CrmOrg.objects.filter(owner=owner).order_by("id").first()
    if org is None:
        return "no_crm"
    lead = None
    for ph in [x for x in (phone, wa) if x]:
        lead = Lead.objects.filter(org=org, phone__endswith=ph[-10:]).order_by("id").first() or \
            Lead.objects.filter(org=org, whatsapp__endswith=ph[-10:]).order_by("id").first()
        if lead is not None:
            break
    ch = CHANNEL_LABEL.get(thread.channel, thread.channel)
    line = "%s %s chat #%s — %s" % (MARK, ch, thread.pk, _want_line(thread, order))
    now = timezone.now()
    if lead is None:
        if not _room(owner):
            return "crm_full"
        draft = thread.order_draft or {}
        lead = Lead.objects.create(
            org=org, name=(draft.get("name") or thread.customer_name or "")[:120],
            phone=phone, whatsapp=wa,
            source=SOURCE.get(thread.channel, "manual"), notes=line,
            first_response_at=now, status="won" if order is not None else "new")
        return "created"
    notes = [ln for ln in (lead.notes or "").splitlines()
             if not ln.startswith("%s %s chat #%s " % (MARK, ch, thread.pk))]
    notes.append(line)
    lead.notes = "\n".join(notes)[-4000:]
    fields = ["notes", "updated_at"]
    if wa and lead.phone and lead.phone[-10:] == wa[-10:] and phone[-10:] != wa[-10:]:
        # the customer gave a delivery number: it becomes the lead's phone,
        # the WhatsApp number stays on the lead
        lead.phone = phone
        lead.whatsapp = lead.whatsapp or wa
        fields += ["phone", "whatsapp"]
    if lead.first_response_at is None:
        lead.first_response_at = now
        fields.append("first_response_at")
    res = "updated"
    if order is not None and lead.status in OPEN_STATUSES:
        lead.status = "won"
        fields.append("status")
        res = "won"
    lead.save(update_fields=fields)
    return res


def _room(owner):
    """The same CRM limits the app applies (crm/plan_gate.web_refusal)."""
    from . import entitlements_service as ES
    if not ES.on(owner):
        return True
    c = ES.cfg()
    if not ES.allows(owner, "crm_write", c):
        return False
    st = ES.crm_contacts(owner, c)
    return st["used"] + 1 <= st["limit"]
