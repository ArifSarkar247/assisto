"""Personal Secretary (PS) — server glue for the Today brief (flag ps_secretary).

Reads ONLY the user's own rows (PA schedule + follow-ups, reminders, bills)
and hands them to the pure core.logic.ps_brief. No AI, no notification text
(notification pick-up stays on the phone — see FEATURE_CARD_PERSONAL_SECRETARY_BN.md §6).
"""
from datetime import timedelta

from django.utils import timezone

from .logic import ps_brief as PB

FLAG = "ps_secretary"


def flag_on(user, play=False):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user, play))
    except Exception:
        return False


def _rows(user, collection):
    from .models import PaCollectionItem
    out = []
    for it in PaCollectionItem.objects.filter(user=user, collection=collection) \
            .order_by("id")[:500]:
        d = dict(it.data or {})
        d["id"] = it.id
        out.append(d)
    return out


_SIMPLE_RULES = {"daily": "daily", "weekly": "weekly", "monthly": "monthly",
                 "yearly": "yearly"}


def _rule_of(r):
    """The reminder's repeat rule (rich NL rule first, else the simple enum)."""
    rule = r.recurrence_rule if isinstance(r.recurrence_rule, dict) else {}
    if rule.get("freq"):
        return rule
    freq = _SIMPLE_RULES.get(r.recurrence or "none")
    return {"freq": freq, "interval": 1} if freq else None


def _reminders(user, local):
    """Today's reminders in the user's clock `local` (aware). bizassist S1: a
    REPEATING reminder whose anchor is an earlier day (daily medicine at 9 pm,
    every Friday...) is projected onto today with its rule."""
    from .logic import reminders_engine as RE
    from .models import Reminder
    tz = local.tzinfo
    day0 = local.replace(hour=0, minute=0, second=0, microsecond=0)
    day1 = day0 + timedelta(days=1)
    n0, n1 = day0.replace(tzinfo=None), day1.replace(tzinfo=None) - timedelta(seconds=1)
    out, seen = [], set()
    for r in Reminder.objects.filter(user=user, done=False, due_at__gte=day0,
                                     due_at__lt=day1).order_by("due_at")[:20]:
        seen.add(r.id)
        out.append({"id": r.id, "title": r.title,
                    "due_at": r.due_at.astimezone(tz).replace(tzinfo=None)})
    rep = (Reminder.objects.filter(user=user, done=False, due_at__lt=day0)
           .exclude(recurrence="none", recurrence_rule={}).order_by("-due_at")[:200])
    for r in rep:
        rule = _rule_of(r)
        if not rule or r.id in seen:
            continue
        anchor = r.due_at.astimezone(tz).replace(tzinfo=None)
        try:
            hits = RE.expand(anchor, rule, start=n0, end=n1, limit=3)
        except Exception:  # noqa: BLE001 — one odd rule never breaks the brief
            continue
        for h in hits[:1]:
            out.append({"id": r.id, "title": r.title, "due_at": h, "repeat": True})
    out.sort(key=lambda d: d["due_at"])
    return out[:20]


def _bills_section(user, today):
    try:
        from .agentcore import proactive as PR
        lines = []
        for kind, rid, name, amount, due, _has in PR._bill_rows(user, today, "bn"):
            days = (due - today).days
            if days > 2 or days < -7:
                continue
            if days < 0:
                w = ("%s দিন পেরিয়েছে" % PB.bn(-days), "%d day(s) overdue" % -days)
            elif days == 0:
                w = ("আজ", "today")
            else:
                w = ("%s দিন পরে" % PB.bn(days), "in %d day(s)" % days)
            lines.append({"bn": "%s — %s (%s)" % (name, PR._money(amount, "bn"), w[0]),
                          "en": "%s — %s (%s)" % (name, PR._money(amount, "en"), w[1]),
                          "src": {"kind": "bill_" + kind, "id": rid}, "_due": due})
        lines.extend(_subscription_lines(user, today))
        lines.sort(key=lambda l: l.pop("_due"))
        return {"key": "bills", "title_bn": "বিল ও দেনা", "title_en": "Bills & dues",
                "lines": lines[:6]}
    except Exception:
        return None


def _when_words(days):
    if days < 0:
        return ("%s দিন পেরিয়েছে" % PB.bn(-days), "%d day(s) overdue" % -days)
    if days == 0:
        return ("আজ", "today")
    return ("%s দিন পরে" % PB.bn(days), "in %d day(s)" % days)


def _subscription_lines(user, today):
    """bizassist S3: subscriptions (internet, dish, streaming...) due from 7
    days ago to 2 days ahead, not paused/cancelled."""
    from .agentcore import proactive as PR
    from .models import Subscription
    out = []
    for s in Subscription.objects.filter(user=user, next_due__gte=today - timedelta(days=7),
                                         next_due__lte=today + timedelta(days=2))[:20]:
        st = str((s.details or {}).get("status") or "active")
        if st != "active":
            continue
        w = _when_words((s.next_due - today).days)
        out.append({"bn": "%s — %s (%s)" % (s.name, PR._money(s.amount, "bn"), w[0]),
                    "en": "%s — %s (%s)" % (s.name, PR._money(s.amount, "en"), w[1]),
                    "src": {"kind": "subscription", "id": s.id}, "_due": s.next_due})
    return out


def missed_calls(user, local):
    """bizassist S4: My Circle calls I MISSED in the last 24 h that I have not
    returned yet (no later answered call, no call back from me). One row per
    person: [{"peer_id", "name", "count", "last" (aware), "call_id", "circle"}]."""
    from django.db.models import Q
    from .a1_circle import call_category, dedupe_calls
    from .logic import call_signal as CS
    from .models import CallRecord, CallSession, CircleMember
    since = local - timedelta(hours=24)
    recs = list(CallRecord.objects.filter(Q(caller=user) | Q(callee=user),
                                          started_at__gte=since)
                .exclude(state__in=CS.LIVE_STATES)
                .select_related("caller", "callee").order_by("started_at", "id")[:300])
    if not recs:
        return []
    reasons = dict(CallSession.objects.filter(call__in=recs)
                   .values_list("call_id", "end_reason"))
    items = dedupe_calls([(r, reasons.get(r.id) or "") for r in recs])
    items.sort(key=lambda t: (t[0].started_at, t[0].id))
    open_ = {}
    for rec, reason in items:
        peer = rec.callee if rec.caller_id == user.id else rec.caller
        cat = call_category(rec, reason, user.id)
        if cat == "missed":
            row = open_.setdefault(peer.id, {"peer": peer, "count": 0})
            row["count"] += 1
            row["last"], row["call_id"] = rec.started_at, rec.id
        elif cat == "answered" or rec.caller_id == user.id:
            open_.pop(peer.id, None)        # talked since, or I called back
    out = []
    for pid, row in open_.items():
        peer = row["peer"]
        edge = (CircleMember.objects.filter(user=user, peer_user=peer, state="accepted").first()
                or CircleMember.objects.filter(user=user, phone=peer.phone or "-",
                                               state="accepted").first())
        name = ((edge.name if edge else "") or peer.name or "").strip() or "—"
        out.append({"peer_id": pid, "name": name, "count": row["count"],
                    "last": row["last"], "call_id": row["call_id"],
                    "circle": [{"id": edge.id, "name": name}] if edge else []})
    out.sort(key=lambda d: d["last"], reverse=True)
    return out[:8]


def _missed_section(user, local):
    try:
        rows = missed_calls(user, local)
    except Exception:  # noqa: BLE001 — call history never breaks the brief
        return None
    lines = []
    for m in rows:
        at = m["last"].astimezone(local.tzinfo).replace(tzinfo=None)
        n = m["count"]
        cb = ("%sটি মিসড কল" % PB.bn(n)) if n > 1 else "মিসড কল"
        ce = ("%d missed calls" % n) if n > 1 else "missed call"
        lines.append({"bn": "%s — %s, শেষ %s · ফিরতি কল দিন" % (m["name"], cb, PB._hm(at, "bn")),
                      "en": "%s — %s, last %s · call back" % (m["name"], ce, PB._hm(at, "en")),
                      "src": {"kind": "missed_call", "id": m["call_id"]},
                      "counterpart": m["name"], "circle": m["circle"],
                      "circle_ids": [c["id"] for c in m["circle"]], "count": n})
    return {"key": "missed_calls", "title_bn": "মিসড কল — ফিরতি কল দিন",
            "title_en": "Missed calls — call back", "lines": lines}


def _bookings_section(user, local):
    """bizassist S5: today's ACTIVE bookings — my shop's appointments and the
    ones I booked as a customer."""
    try:
        from .logic import booking as BL
        from .models import Booking
        day0 = local.replace(hour=0, minute=0, second=0, microsecond=0)
        day1 = day0 + timedelta(days=1)
        base = Booking.objects.filter(status__in=BL.ACTIVE, start__gte=day0, start__lt=day1)
        lines = []
        for b in base.filter(business__user=user).select_related("staff").order_by("start")[:8]:
            at = b.start.astimezone(local.tzinfo).replace(tzinfo=None)
            who = b.customer_name or "—"
            wait = b.status == "requested"
            lines.append({
                "bn": "%s — %s · %s%s" % (PB._hm(at, "bn"), b.service_name, who,
                                         " · নিশ্চিত করুন" if wait else ""),
                "en": "%s — %s · %s%s" % (PB._hm(at, "en"), b.service_name, who,
                                         " · please confirm" if wait else ""),
                "src": {"kind": "booking_biz", "id": b.id}, "state": b.status})
        for b in (base.filter(customer_user=user).exclude(business__user=user)
                  .select_related("business").order_by("start")[:8]):
            at = b.start.astimezone(local.tzinfo).replace(tzinfo=None)
            shop = b.business.shop_name or "—"
            lines.append({
                "bn": "%s — %s, %s-এ" % (PB._hm(at, "bn"), b.service_name, shop),
                "en": "%s — %s at %s" % (PB._hm(at, "en"), b.service_name, shop),
                "src": {"kind": "booking_mine", "id": b.id}, "state": b.status})
        return {"key": "bookings", "title_bn": "আজকের বুকিং", "title_en": "Today's bookings",
                "lines": lines}
    except Exception:  # noqa: BLE001
        return None


def clock(now=None, tz_offset_min=None):
    """The user's local AWARE time: the phone's UTC offset when it sent one
    (bizassist S2 — a probashi's brief in their own clock), else Dhaka."""
    from datetime import timezone as dtz
    now = now or timezone.now()
    if tz_offset_min is not None:
        try:
            off = int(tz_offset_min)
        except (TypeError, ValueError):
            off = None
        if off is not None and -720 <= off <= 840:
            return now.astimezone(dtz(timedelta(minutes=off)))
    return timezone.localtime(now)


def today(user, now=None, tz_offset_min=None):
    local = clock(now, tz_offset_min)
    naive = local.replace(tzinfo=None)
    out = PB.build(_rows(user, "schedule"), _rows(user, "followups"),
                   _reminders(user, local), naive, tz=local.tzinfo,
                   extra_sections=[_missed_section(user, local),
                                   _bookings_section(user, local),
                                   _bills_section(user, local.date())])
    c = out["counts"]
    for s in out["sections"]:
        if s["key"] in ("missed_calls", "bookings", "bills"):
            c[s["key"]] = len(s["lines"])
    return out


def proactive_lines(user, now):
    """Morning-brief lines for Agent Core (empty when the flag is off)."""
    if not flag_on(user, True):
        return []
    local = timezone.localtime(now)
    out = PB.proactive_lines(_rows(user, "schedule"), _rows(user, "followups"),
                             local.replace(tzinfo=None), local.tzinfo)
    try:   # bizassist S8: missed calls not returned
        miss = missed_calls(user, local)
        if miss:
            names = ", ".join(m["name"] for m in miss[:3])
            out.append({"bn": "%sজনকে ফিরতি কল দেওয়া বাকি: %s" % (PB.bn(len(miss)), names),
                        "en": "%d missed call(s) to return: %s" % (len(miss), names)})
    except Exception:  # noqa: BLE001
        pass
    return out
