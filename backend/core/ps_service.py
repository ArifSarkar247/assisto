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
                          "src": {"kind": "bill_" + kind, "id": rid}})
        return {"key": "bills", "title_bn": "বিল ও দেনা", "title_en": "Bills & dues",
                "lines": lines[:6]}
    except Exception:
        return None


def today(user, now=None):
    now = now or timezone.now()
    local = timezone.localtime(now)
    naive = local.replace(tzinfo=None)
    return PB.build(_rows(user, "schedule"), _rows(user, "followups"),
                    _reminders(user, local), naive, tz=local.tzinfo,
                    extra_sections=[_bills_section(user, local.date())])


def proactive_lines(user, now):
    """Morning-brief lines for Agent Core (empty when the flag is off)."""
    if not flag_on(user, True):
        return []
    local = timezone.localtime(now)
    return PB.proactive_lines(_rows(user, "schedule"), _rows(user, "followups"),
                              local.replace(tzinfo=None), local.tzinfo)
