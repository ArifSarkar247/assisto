"""crm100 — send a message to ONE customer from the CRM. Never automatic.

Three ways, all started by the seller's own tap:
  whatsapp_link  a wa.me link with the text filled in — the seller's own
                 WhatsApp sends it. Free. We log "opened", never "sent".
  sms_app        the phone's own SMS composer (sms: link). Free. "opened".
  assisto_sms    Assisto's SMS gateway (core.sms_service purpose "crm"):
                 credits shown BEFORE sending (segments × the "sms" price),
                 charged to the business OWNER only, refunded if the gateway
                 fails; the customer's STOP + quiet hours 21:00-09:00
                 (core.logic.msg_guard) + daily caps (Pricing → sms.crm_*).
                 Only to the shop's / CRM's OWN customers (never a typed
                 stranger's number). The text carries the shop name and a
                 STOP line.

Bulk = one card per customer (each with its own name filled in and its own
buttons), exactly like the khata bulk tagada — never one message to many.
"""
import re
import secrets

from django.utils import timezone

MAX_TEXT = 600
MAX_BULK = 200


def _khata():
    from core.logic import business_khata as K
    return K


def sms_text(scope, text, lang):
    """What an Assisto SMS actually carries: "<shop>: text" + STOP line."""
    from core.logic import msg_guard as MG
    shop = (scope.business.shop_name or "").strip() if scope.business else ""
    body = str(text or "").strip()
    if shop and not body.startswith(shop):
        body = "%s: %s" % (shop, body)
    return body + "\n" + MG.stop_footer(lang, "sms")


def sms_quote(text):
    from core import billing, sms_segments
    from core.logic import pricing as P
    si = sms_segments.info(text)
    try:
        per = P.credits_for("sms", 1, billing.cfg())
        total = P.credits_for("sms", si["segments"], billing.cfg())
    except Exception:  # noqa: BLE001
        per, total = 1, si["segments"]
    return {"segments": si["segments"], "credits": total, "per_segment": per,
            "encoding": si.get("encoding", "")}


def sms_offer(request, scope, person, text, lang, now=None):
    """Everything the app must show BEFORE an Assisto SMS: cost, balance,
    whether it can go now and, if not, the honest reason."""
    from core import sms_service
    from core.logic import msg_guard as MG
    now = now or timezone.now()
    owner = scope.business is not None and scope.role == "owner"
    final = sms_text(scope, text, lang)
    q = sms_quote(final)
    bal = int(getattr(request.user, "ai_credits", 0) or 0) if owner else 0
    blocked = None
    if not sms_service.ready():
        blocked = "sms_not_configured"
    elif scope.business is None:
        blocked = "no_business"
    elif not owner:
        blocked = "owner_only"
    elif not _khata().bd_msisdn(person.phone or person.key):
        blocked = "bad_phone"
    elif q["segments"] > sms_service.cfg().get("max_segments", 4):
        blocked = "too_long"
    else:
        try:
            if MG.is_opted_out(scope.business.pk, person.key):
                blocked = "opted_out"
        except Exception:  # noqa: BLE001
            pass
        if blocked is None and MG.in_quiet_hours(now):
            blocked = "quiet_hours"
        if blocked is None and bal < q["credits"]:
            blocked = "insufficient_credits"
    retry = MG.next_allowed_at(now) if blocked == "quiet_hours" else None
    return {"ready": sms_service.ready(), "owner_only": not owner,
            "available": blocked is None, "blocked": blocked or "",
            "balance": bal, "text": final, "retry_at": retry.isoformat() if retry else None,
            **q}


def links(person, text):
    K = _khata()
    phone = person.phone or person.key
    return {"phone_ok": bool(K.bd_msisdn(phone)),
            "wa_url": K.wa_link(phone, text), "sms_uri": K.sms_uri(phone, text)}


def log(scope, person, channel, status, text, *, purpose="message", reason="",
        credits=0, lead_id=None, bulk_id=""):
    from .models import CustomerMessage, Lead
    org_id = None
    lead = None
    if lead_id:
        lead = Lead.objects.filter(pk=lead_id, org_id__in=scope.org_ids).first()
    if lead is None and person.lead_ids:
        lead = Lead.objects.filter(pk=person.lead_ids[0]).first()
    if lead is not None:
        org_id = lead.org_id
    row = CustomerMessage.objects.create(
        business=scope.business, org_id=org_id, lead=lead, user=scope.user, phone_key=person.key, name=(person.name or "")[:120],
        channel=channel, purpose=purpose if purpose in ("message", "tagada", "quote",
                                                        "offer") else "message",
        status=status, reason=(reason or "")[:40], text=str(text or "")[:1000],
        credits=int(credits or 0), bulk_id=(bulk_id or "")[:24])
    if lead is not None:
        _lead_activity(scope, lead, channel, status, text)
    return row


def _lead_activity(scope, lead, channel, status, text):
    """Mirror onto the lead timeline (CRM side) so the lead page agrees."""
    try:
        from .models import Activity, CrmMember
        member = CrmMember.objects.filter(org_id=lead.org_id, user=scope.user).first()
        Activity.objects.create(
            org_id=lead.org_id, lead=lead, actor=member,
            kind=Activity.WHATSAPP if channel == "whatsapp_link" else Activity.SYSTEM,
            subject={"whatsapp_link": "WhatsApp", "sms_app": "SMS",
                     "assisto_sms": "Assisto SMS"}.get(channel, channel) + " · " + status,
            body=str(text or "")[:1000], done=True, done_at=timezone.now())
    except Exception:  # noqa: BLE001
        pass


def new_bulk_id():
    return secrets.token_hex(6)


def fill(text, name):
    """{name} → the customer's own name (blank names leave a clean text)."""
    t = str(text or "")
    n = (name or "").strip()
    if "{name}" in t:
        t = t.replace("{name}", n)
        t = re.sub(r"[ ]{2,}", " ", t).replace(" ,", ",").strip()
    return t[:MAX_TEXT]
