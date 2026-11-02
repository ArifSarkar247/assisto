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


def _reminders(user, local):
    from .models import Reminder
    day0 = local.replace(hour=0, minute=0, second=0, microsecond=0)
    out = []
    for r in Reminder.objects.filter(user=user, done=False, due_at__gte=day0,
                                     due_at__lt=day0 + timedelta(days=1)) \
            .order_by("due_at")[:20]:
        out.append({"id": r.id, "title": r.title,
                    "due_at": timezone.localtime(r.due_at).replace(tzinfo=None)})
    return out


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
