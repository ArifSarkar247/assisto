"""
THE server-side SMS API (smsotp). Every SMS Assisto sends on purpose goes
through `send_sms` — caps, segments, failover, credits and cost logging live
here, once.

    from core import sms_service
    r = sms_service.send_sms("01712345678", text, "safety", user=request.user)
    r -> {"ok", "reason", "provider", "message_id", "segments", "encoding",
          "cost_bdt", "credits", "failover", "log_id"}

    sms_service.send_safety_sms(user, to, text)   # SOS / journey / family alerts
    sms_service.ready()                           # a gateway is CONNECTED

PURPOSES (never marketing — refused):
  otp           login / password reset / delete / Section 8 codes. Free to the
                user; provider cost logged as company cost.
  phone_verify  sign-up / change number / booking phone proof. Same.
  tagada        ledger due reminder to a business's customer. Charged to the
                business OWNER as credits ("sms" action × segments, refunded
                if the gateway fails); STOP opt-out + quiet hours 21:00-09:00
                (core/logic/msg_guard). Refused at zero credits.
  safety        SOS / Safe Journey / family alerts to trusted contacts. Free
                to the user, strict per-day caps, company cost logged.

CAPS (Owner Admin → Pricing → sms, per Dhaka calendar day, 0 = purpose off):
  <purpose>_per_phone_day / _per_user_day / _global_day, and
  tagada_per_business_day. Only rows with status 'sent' count.

COST: segments × cost_per_segment_bdt of the gateway that sent it (its
integration entry), else Pricing → sms.default_cost_per_segment_bdt. Logged
per message in SmsLog and added to the daily company cost ("sms") that the
Profit Guard watches.

The text is never stored or logged; `secret` (an OTP) is scrubbed from any
gateway reply kept in SmsLog.detail.
"""
import logging
from datetime import timedelta

from django.utils import timezone

from . import sms_gateway, sms_segments

log = logging.getLogger(__name__)

PURPOSES = ("otp", "phone_verify", "tagada", "safety")
_CAP_PREFIX = {"otp": "otp", "phone_verify": "verify", "tagada": "tagada",
               "safety": "safety"}


def ready():
    return sms_gateway.ready()


def cfg():
    from .logic import pricing as P
    try:
        from . import billing
        return P.sms_cfg(billing.get_config().data)
    except Exception:  # noqa: BLE001
        return P.sms_cfg({})


def _day_start(now):
    from .logic import msg_guard as MG
    return MG.day_start(now)


def _cost_per_segment(ad, c):
    raw = (getattr(ad, "cfg", None) or {}).get("cost_per_segment_bdt")
    try:
        v = float(str(raw).strip())
        if v >= 0:
            return v
    except (TypeError, ValueError):
        pass
    return float(c["default_cost_per_segment_bdt"])


def caps_for(purpose, c=None):
    c = c or cfg()
    p = _CAP_PREFIX[purpose]
    return {"per_phone_day": c.get(p + "_per_phone_day", 0),
            "per_user_day": c.get(p + "_per_user_day", 0),
            "per_business_day": c.get(p + "_per_business_day"),
            "global_day": c.get(p + "_global_day", 0)}


def cap_check(purpose, canon, user=None, business=None, now=None, c=None):
    """None when one more SMS fits under every cap of `purpose` today, else
    the reason: purpose_off | phone_daily_cap | user_daily_cap |
    business_daily_cap | global_daily_cap."""
    from .models import SmsLog
    now = now or timezone.now()
    caps = caps_for(purpose, c)
    if not caps["global_day"] or not caps["per_phone_day"]:
        return "purpose_off"
    base = SmsLog.objects.filter(purpose=purpose, status="sent",
                                 created_at__gte=_day_start(now))
    if base.count() >= caps["global_day"]:
        return "global_daily_cap"
    if base.filter(phone=canon).count() >= caps["per_phone_day"]:
        return "phone_daily_cap"
    if user is not None and caps["per_user_day"] and \
            base.filter(user=user).count() >= caps["per_user_day"]:
        return "user_daily_cap"
    if business is not None and caps["per_business_day"] is not None and \
            base.filter(business=business).count() >= caps["per_business_day"]:
        return "business_daily_cap"
    return None


def _out(ok, reason, **kw):
    out = {"ok": ok, "reason": reason, "provider": "", "message_id": "",
           "segments": 0, "encoding": "", "cost_bdt": 0.0, "credits": 0,
           "failover": False, "log_id": None}
    out.update(kw)
    return out


def _record(purpose, canon, user, business, status, reason, **kw):
    from .models import SmsLog
    try:
        row = SmsLog.objects.create(
            purpose=purpose, phone=canon or "", user=user, business=business,
            status=status, reason=(reason or "")[:40],
            provider=(kw.get("provider") or "")[:32],
            message_id=(kw.get("message_id") or "")[:80],
            segments=int(kw.get("segments") or 0), encoding=kw.get("encoding", ""),
            cost_bdt=float(kw.get("cost_bdt") or 0.0), credits=int(kw.get("credits") or 0),
            failover=bool(kw.get("failover")), detail=(kw.get("detail") or "")[:200])
        return row.pk
    except Exception:  # noqa: BLE001
        log.warning("sms_service: log write failed")
        return None


def _tagada_guard(business, canon, now):
    """STOP opt-out + quiet hours for a business → customer reminder."""
    from .logic import msg_guard as MG
    from .logic.business_selling import normalize_phone
    try:
        if MG.is_opted_out(business.pk, normalize_phone(canon)):
            return "opted_out"
    except Exception:  # noqa: BLE001
        pass
    if MG.in_quiet_hours(now):
        return "quiet_hours"
    return None


def send_sms(to, text, purpose, *, user=None, business=None, secret="", now=None):
    """Send one SMS for `purpose` (see module doc). Never raises.
    `user` = the person it is for/from (OTP: the account; safety: the user
    raising the alert; tagada: the business owner who pays). `business` =
    BusinessProfile for tagada (required)."""
    from .otp import normalize_bd_phone
    now = now or timezone.now()
    if purpose not in PURPOSES:
        return _out(False, "bad_purpose")          # marketing is never sent
    canon = normalize_bd_phone(to)
    if not canon:
        return _out(False, "bad_phone")
    text = str(text or "")
    if not text.strip():
        return _out(False, "empty_text")
    c = cfg()
    si = sms_segments.info(text)
    if si["segments"] > c["max_segments"]:
        return _out(False, "too_long", segments=si["segments"], encoding=si["encoding"])
    ads = sms_gateway.active()
    if not ads:
        return _out(False, "sms_not_configured")
    if purpose == "tagada":
        if business is None:
            return _out(False, "business_required")
        user = user or business.user
        why = _tagada_guard(business, canon, now)
        if why:
            _record(purpose, canon, user, business, "blocked", why,
                    segments=si["segments"], encoding=si["encoding"])
            return _out(False, why, segments=si["segments"], encoding=si["encoding"])
    why = cap_check(purpose, canon, user=user, business=business, now=now, c=c)
    if why:
        _record(purpose, canon, user, business, "blocked", why,
                segments=si["segments"], encoding=si["encoding"])
        return _out(False, why, segments=si["segments"], encoding=si["encoding"])

    credits = 0
    if purpose == "tagada":
        from . import billing
        ch = billing.charge(user, "sms", qty=si["segments"], note="tagada.sms")
        if not ch.get("ok"):
            reason = "insufficient_credits" if ch.get("reason") == "insufficient" \
                else (ch.get("reason") or "charge_failed")
            _record(purpose, canon, user, business, "blocked", reason,
                    segments=si["segments"], encoding=si["encoding"])
            return _out(False, reason, segments=si["segments"], encoding=si["encoding"],
                        balance=ch.get("balance"))
        credits = int(ch.get("charged") or 0)

    res, used, failed_over = sms_gateway.send_with_failover(ads, canon, text, secret=secret)
    if not res.ok:
        if credits:
            from . import billing
            billing.credit(user, "adjust", credits, note="tagada.sms_refund")
        lid = _record(purpose, canon, user, business, "failed", "send_failed",
                      provider=res.provider, segments=si["segments"],
                      encoding=si["encoding"], failover=failed_over, detail=res.detail)
        return _out(False, "send_failed", segments=si["segments"],
                    encoding=si["encoding"], failover=failed_over, log_id=lid)

    cost = round(si["segments"] * _cost_per_segment(used, c), 4)
    try:
        from . import billing
        billing.record_cost("sms", cost)
    except Exception:  # noqa: BLE001
        pass
    lid = _record(purpose, canon, user, business, "sent", "ok", provider=res.provider,
                  message_id=res.message_id, segments=si["segments"],
                  encoding=si["encoding"], cost_bdt=cost, credits=credits,
                  failover=failed_over, detail=res.detail)
    return _out(True, "ok", provider=res.provider, message_id=res.message_id,
                segments=si["segments"], encoding=si["encoding"], cost_bdt=cost,
                credits=credits, failover=failed_over, log_id=lid)


def send_safety_sms(user, to, text, now=None):
    """SOS / Safe Journey / family alert to ONE trusted contact. Free to the
    user, strict per-day caps (Pricing → sms.safety_*). For the journey agent:
    call this per contact and show r["reason"] honestly when not ok (e.g.
    "sms_not_configured" → in-app push only)."""
    return send_sms(to, text, "safety", user=user, now=now)


def usage_today(now=None):
    """Owner view: per-purpose sent count, segments and company cost today."""
    from django.db.models import Count, Sum
    from .models import SmsLog
    now = now or timezone.now()
    rows = (SmsLog.objects.filter(status="sent", created_at__gte=_day_start(now))
            .values("purpose").annotate(n=Count("id"), seg=Sum("segments"),
                                        cost=Sum("cost_bdt"), credits=Sum("credits")))
    return {r["purpose"]: {"sent": r["n"], "segments": r["seg"] or 0,
                           "cost_bdt": round(r["cost"] or 0.0, 2),
                           "credits": r["credits"] or 0} for r in rows}


def recent_window(hours=24, now=None):
    from .models import SmsLog
    now = now or timezone.now()
    return SmsLog.objects.filter(created_at__gt=now - timedelta(hours=hours))
