"""ledger100 — fires the owner's SCHEDULED tagada (due reminders).

Run by `manage.py tagada_sweep` every 5 minutes (flock, see the command).

For every enabled TagadaSchedule whose next_at has come:

  * the customer owes nothing any more → the schedule stops ("paid") when it
    is "until paid" or a one-off; a fixed-cadence one just moves on;
  * quiet hours (21:00-09:00 Dhaka, core/logic/msg_guard) → nothing is sent;
    next_at moves to 09:00 — for the owner's push too (no 3 am nudges);
  * at most ONE firing per customer per Dhaka day, and at most
    PER_BUSINESS_DAY firings per shop per day (the rest wait for tomorrow
    09:00) — on top of sms_service's own SMS caps;
  * channel "sms" / "assisto" → core/tagada_engine.send (tagada2): a
    VERIFIED Assisto customer gets it in the app, free; otherwise ("sms")
    the gateway SMS paid in SMS parts (refused at 0 parts), STOP
    opt-out, caps. If it cannot go (no credits, no gateway, a cap, STOP…)
    the owner gets the push below instead, with the reason;
  * otherwise → a push to the shop OWNER: "time to remind <name> (৳…)".
    Tapping it opens the khata, where the reminder waits with one-tap send.
    Nothing reaches the customer without the owner's tap.

Idempotent: a schedule is CLAIMED with a conditional UPDATE on its current
next_at before anything is sent, so two overlapping runs (or a retry) can
never send the same reminder twice. At-most-once: a crash after the claim
loses that one reminder rather than double-sending (the next slot still
fires).
"""
import logging
from collections import Counter
from datetime import timedelta

from django.db.models import F
from django.utils import timezone

log = logging.getLogger(__name__)

PER_BUSINESS_DAY = 100     # scheduled firings per shop per Dhaka day
BATCH = 500                # schedules looked at per run


def _balance(party):
    from .logic import business_khata as khata
    rows = [{"direction": e.direction, "amount": e.amount_poisha}
            for e in party.entries.all()]
    return khata.running_balance(rows, party.book)


def _tomorrow_9(now):
    from .logic import msg_guard as MG
    return MG.next_allowed_at(MG.day_start(now) + timedelta(days=1, hours=1))


def _move(s, **upd):
    """Conditional update on the next_at we read (the claim)."""
    from .models import TagadaSchedule
    return TagadaSchedule.objects.filter(pk=s.pk, next_at=s.next_at,
                                         enabled=True).update(**upd)


def _push_owner(owner, party, bal, s, reason=""):
    from . import push
    from .logic import business_khata as khata
    amt = khata.fmt_amount(bal)
    why_bn = why_en = ""
    if reason:
        why_bn = " (Assisto SMS যায়নি: %s)" % _REASON_BN.get(reason, reason)
        why_en = " (Assisto SMS not sent: %s)" % _REASON_EN.get(reason, reason)
    return push.push_to_user(
        owner, "reminder",
        "তাগাদার সময়: %s" % party.name, "Time to remind %s" % party.name,
        "%s বাকি — এক ট্যাপে পাঠান।%s" % (amt["bn"], why_bn),
        "%s due — send it with one tap.%s" % (amt["en"], why_en),
        data={"route": "business/khata", "party_id": party.id,
              "schedule_id": s.id})


_REASON_BN = {"insufficient_credits": "ক্রেডিট নেই", "sms_not_configured": "SMS গেটওয়ে নেই",
              "no_balance": "SMS ব্যালান্স নেই", "not_reachable": "গ্রাহককে পাওয়া যাচ্ছে না",
              "not_assisto_user": "গ্রাহক Assisto-তে নেই",
              "opted_out": "গ্রাহক STOP করেছেন", "bad_phone": "নম্বর ঠিক নেই",
              "phone_daily_cap": "আজকের সীমা শেষ", "business_daily_cap": "আজকের সীমা শেষ",
              "user_daily_cap": "আজকের সীমা শেষ", "global_daily_cap": "আজকের সীমা শেষ",
              "purpose_off": "SMS বন্ধ", "send_failed": "পাঠানো যায়নি, SMS ব্যালান্স ফেরত"}
_REASON_EN = {"insufficient_credits": "no credits", "sms_not_configured": "no SMS gateway",
              "no_balance": "no SMS balance", "not_reachable": "customer not reachable",
              "not_assisto_user": "customer not on Assisto",
              "opted_out": "customer sent STOP", "bad_phone": "no valid number",
              "phone_daily_cap": "today's limit", "business_daily_cap": "today's limit",
              "user_daily_cap": "today's limit", "global_daily_cap": "today's limit",
              "purpose_off": "SMS is off", "send_failed": "failed, SMS balance given back"}


def fire_one(s, now, stats):
    from .logic import business_khata as khata
    from .logic import msg_guard as MG
    from .models import TagadaSchedule
    party = s.party
    prof = party.business
    owner = prof.user
    if party.archived or party.book != khata.CUSTOMER or owner is None:
        TagadaSchedule.objects.filter(pk=s.pk).update(enabled=False,
                                                      last_result="party_gone")
        stats["party_gone"] += 1
        return
    bal = _balance(party)
    nxt = khata.next_fire_at(s.next_at, s.interval_days, now)
    if bal <= 0:
        if s.until_paid or nxt is None:
            if _move(s, enabled=False, last_result="paid", awaiting_owner=False):
                stats["paid_stopped"] += 1
        elif _move(s, next_at=nxt, last_result="no_due"):
            stats["no_due"] += 1
        return
    if MG.in_quiet_hours(now):
        if _move(s, next_at=MG.next_allowed_at(now)):
            stats["quiet_deferred"] += 1
        return
    day0 = MG.day_start(now)
    if s.last_fired_at and s.last_fired_at >= day0:
        # never twice in one day for one customer (e.g. an edited schedule)
        if _move(s, next_at=max(nxt or _tomorrow_9(now), _tomorrow_9(now))):
            stats["same_day_skipped"] += 1
        return
    fired_today = TagadaSchedule.objects.filter(
        party__business=prof, last_fired_at__gte=day0).count()
    if fired_today >= PER_BUSINESS_DAY:
        if _move(s, next_at=_tomorrow_9(now)):
            stats["business_cap_deferred"] += 1
        return
    claim = dict(last_fired_at=now, fire_count=F("fire_count") + 1)
    if nxt is None:
        claim["enabled"] = False
    else:
        claim["next_at"] = nxt
    if not _move(s, **claim):
        stats["lost_claim"] += 1          # another run took it — nothing sent
        return

    result, awaiting = "", True
    # tagada2: an automatic schedule ("sms" = Assisto SMS, "assisto" = in-app)
    # goes through the SEND ORDER: a VERIFIED Assisto customer gets it free in
    # the app first; only then (channel "sms") the paid gateway SMS, from the
    # owner's SMS parts. One per customer per day across every channel.
    if s.channel in ("sms", "assisto"):
        from . import push as P
        from . import tagada_engine as TE
        lang = P.user_lang(owner) or "bn"
        kw = dict(owner=True, preset=s.preset or "reminder",
                  pay_hint=(s.pay_hint or None), lang=lang, by=None, now=now)
        st, body = TE.send(prof, party, channel="assisto", **kw)
        if s.channel == "sms" and body.get("reason") == "not_assisto_user":
            st, body = TE.send(prof, party, channel="gateway_sms", **kw)
        if body.get("ok"):
            via = body.get("channel")
            result, awaiting = ("sms_sent" if via == "gateway_sms" else "assisto_sent"), False
            stats["sms_sent" if via == "gateway_sms" else "assisto_sent"] += 1
        elif body.get("reason") == "daily_limit":
            result, awaiting = "already_today", False
            stats["already_today"] += 1
        else:
            reason = body.get("reason") or "error"
            n = _push_owner(owner, party, bal, s, reason=reason)
            result = ("sms_%s" % reason)[:40]
            stats["sms_refused"] += 1
            stats["push_sent" if n else "push_no_device"] += 1
    else:
        n = _push_owner(owner, party, bal, s)
        result = "push" if n else "push_no_device"
        stats["push_sent" if n else "push_no_device"] += 1
    TagadaSchedule.objects.filter(pk=s.pk).update(last_result=result,
                                                  awaiting_owner=awaiting)


def sweep(now=None, batch=BATCH):
    """One pass. Returns a Counter of what happened (for the cron log)."""
    from .models import TagadaSchedule
    now = now or timezone.now()
    stats = Counter()
    due = list(TagadaSchedule.objects.filter(enabled=True, next_at__lte=now)
               .select_related("party", "party__business", "party__business__user")
               .order_by("next_at", "id")[:batch])
    for s in due:
        try:
            fire_one(s, now, stats)
        except Exception as e:  # noqa: BLE001 — one bad row never stops the run
            stats["errors"] += 1
            log.warning("tagada_sweep: schedule %s failed (%s)", s.pk, type(e).__name__)
    stats["looked"] = len(due)
    return stats
