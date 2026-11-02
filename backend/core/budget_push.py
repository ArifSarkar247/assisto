"""
budget_push.py — remhbud: a phone notification when a NEW expense pushes a
budget category over 80 % ("near the limit") or over 100 % ("over budget").

Honest rules (feature card FEATURE_CARD_BUDGET_REMIT_BN.md):
  * Only the expense that CROSSES a line notifies — 80 % once on the way up,
    100 % once on the way up. No state is stored: "before" is the month's
    spend without this expense, so a second expense above the line is silent.
  * Same numbers as the Budget page (core.logic.budget.budget_line: the exact
    category, the base monthly limit, Asia/Dhaka month): the push never says
    something the page does not.
  * Only expenses dated in the CURRENT month (a back-dated entry never rings).
  * Quiet hours 22:00–07:00 Dhaka (then the page + alerts list still show it),
    and at most `DAILY_CAP` budget notifications per person per day (a bank
    statement import of 300 rows must not ring 30 times).
  * The text carries the category and the percent only — never other amounts.
  * Never raises: a push problem can never break saving an expense.
"""
import logging

from django.db.models.signals import post_save
from django.utils import timezone

log = logging.getLogger(__name__)

KIND = "budget_alert"
DAILY_CAP = 3
QUIET_FROM, QUIET_TO = 22, 7   # local (Asia/Dhaka) hours


def crossing(before_line, after_line):
    """'over' / 'near' when this expense moved the line across 100 % / 80 %;
    None otherwise. Lines are core.logic.budget.budget_line dicts."""
    rank = {"none": -1, "ok": 0, "near": 1, "over": 2}
    b, a = rank.get(before_line["state"], -1), rank.get(after_line["state"], -1)
    if a == 2 and b < 2:
        return "over"
    if a == 1 and b < 1:
        return "near"
    return None


def _label(lang, category):
    from .logic import remittance as R
    key = (category or "").strip().lower()
    return R.label(lang, R.CATEGORY_LABELS, key) if key in R.CATEGORY_LABELS else category


def texts(level, category, pct):
    """(title_bn, title_en, body_bn, body_en) for a crossing."""
    from .logic.remittance import digits
    cb, ce = _label("bn", category), _label("en", category)
    pb = digits("bn", pct)
    if level == "over":
        return ("বাজেট পার হয়েছে: %s" % cb, "Over budget: %s" % ce,
                "এ মাসে %s খাতে পরিকল্পনার %s%% খরচ হয়েছে।" % (cb, pb),
                "This month's %s spending is at %d%% of your plan." % (ce, pct))
    return ("বাজেটের সীমার কাছে: %s" % cb, "Near your budget: %s" % ce,
            "এ মাসে %s খাতে পরিকল্পনার %s%% খরচ হয়ে গেছে।" % (cb, pb),
            "You have used %d%% of this month's %s budget." % (pct, ce))


def check(txn, now=None):
    """Decide and send for one newly created Transaction. Returns the level
    sent ('near' / 'over') or None. `now` = an aware datetime (tests)."""
    try:
        if txn.kind != "expense" or not txn.category:
            return None
        now = timezone.localtime(now or timezone.now())
        today = now.date()
        if (txn.date.year, txn.date.month) != (today.year, today.month):
            return None
        from .models import Budget, Transaction
        from .logic import budget as bg
        b = Budget.objects.filter(user_id=txn.user_id, category=txn.category).first()
        if b is None or not b.monthly_limit or b.monthly_limit <= 0:
            return None
        rows = list(Transaction.objects.filter(
            user_id=txn.user_id, kind="expense", category=b.category,
            date__year=today.year, date__month=today.month).values_list("id", "amount"))
        after = sum((a for _, a in rows), start=0)
        before = sum((a for i, a in rows if i != txn.id), start=0)
        la = bg.budget_line(b.category, b.monthly_limit, after)
        lb = bg.budget_line(b.category, b.monthly_limit, before)
        level = crossing(lb, la)
        if level is None:
            return None
        if now.hour >= QUIET_FROM or now.hour < QUIET_TO:
            return None
        from django.core.cache import cache
        key = "budget_push:%s:%s" % (txn.user_id, today.isoformat())
        n = cache.get(key, 0)
        if n >= DAILY_CAP:
            return None
        cache.set(key, n + 1, 86400)
        from . import push
        tb, te, bb, be = texts(level, b.category, int(la["pct"]))
        push.push_to_user_async(txn.user, KIND, tb, te, bb, be,
                                data={"route": "budget", "category": b.category, "level": level})
        return level
    except Exception:
        log.warning("budget_push: check failed", exc_info=True)
        return None


def _on_txn(sender, instance, created, raw=False, **kwargs):
    if created and not raw:
        check(instance)


def connect():
    from .models import Transaction
    post_save.connect(_on_txn, sender=Transaction, dispatch_uid="remhbud_budget_push")
