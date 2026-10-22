"""
f1-founders — "Founding Member" grants (owner panel /owner/founders).

A Founding Member gets FREE PREMIUM for N months (N = PricingConfig
limits.founding_member_months, admin-editable, default 12) plus a permanent
badge (User.is_founder). Consistent with core/plans.py:

* is_founder + founder_since None  -> the legacy LIFETIME founder ("founder"
  plan). Never touched by a grant (already better than N months).
* is_founder + founder_since set   -> Founding Member. Entitlement runs through
  the normal plan/plan_until path: plan "premium" until
  founder_since + N months. An existing LONGER paid plan is never shortened,
  and an active Business plan is never downgraded.

Idempotent: the target end date is anchored at the ORIGINAL grant date, so
re-applying the same list is a no-op. Revocable: the badge goes and — only if
nothing changed the plan since the grant — the previous plan is restored.
"""
import calendar

from django.db import transaction
from django.utils import timezone

DEFAULT_MONTHS = 12
MAX_BULK = 500


def months():
    try:
        from . import billing
        return int(billing.cfg()["limits"]["founding_member_months"])
    except Exception:
        return DEFAULT_MONTHS


def add_months(dt, n):
    """Calendar months (31 Jan + 1 month = 28/29 Feb)."""
    m = dt.month - 1 + int(n)
    y, m = dt.year + m // 12, m % 12 + 1
    d = min(dt.day, calendar.monthrange(y, m)[1])
    return dt.replace(year=y, month=m, day=d)


def _active_until(user, now):
    from . import plans
    if user.plan_until and user.plan_until > now and user.plan in plans.PLANS \
            and user.plan != "free":
        return user.plan_until
    return None


def plan_for(user, n=None, now=None):
    """What a grant WOULD do to this user. Pure read (no save).

    outcome: 'grant'        -> becomes Premium until `new_until`
             'extend'       -> existing shorter paid plan moved to `new_until`
             'keep_longer'  -> already has a paid plan ending later; kept as is
             'keep_business'-> active Business plan kept (never downgraded)
             'already'      -> already a Founding Member (no change)
             'lifetime'     -> legacy lifetime founder (no change)
    """
    from . import plans
    now = now or timezone.now()
    n = int(n or months())
    if plans.lifetime_founder(user):
        return {"outcome": "lifetime", "new_until": None, "changes_plan": False}
    if user.is_founder and user.founder_since:
        # idempotent: an existing Founding Member is never re-anchored or
        # extended by a repeat grant (revoke + grant to start a new period).
        return {"outcome": "already", "new_until": user.founder_until,
                "changes_plan": False}
    target = add_months(now, n)
    cur = _active_until(user, now)
    if cur is not None and user.plan == "business":
        return {"outcome": "keep_business", "new_until": user.plan_until,
                "changes_plan": False}
    if cur is not None and cur >= target:
        return {"outcome": "keep_longer", "new_until": user.plan_until,
                "changes_plan": False}
    return {"outcome": "extend" if cur is not None else "grant",
            "new_until": target, "changes_plan": True}


def state(user):
    """Small JSON-able snapshot for OwnerAudit before/after."""
    from . import plans
    return {"is_founder": bool(user.is_founder),
            "founder_since": user.founder_since.isoformat() if user.founder_since else None,
            "founder_until": user.founder_until.isoformat() if user.founder_until else None,
            "plan": user.plan,
            "plan_until": user.plan_until.isoformat() if user.plan_until else None,
            "effective": plans.effective_plan(user)}


def grant(user, actor=None, reason="", n=None, now=None):
    """Make `user` a Founding Member. Returns (outcome, before, after)."""
    from .models import FounderGrant, User
    now = now or timezone.now()
    n = int(n or months())
    with transaction.atomic():
        u = User.objects.select_for_update().get(pk=user.pk)
        before = state(u)
        p = plan_for(u, n, now)
        if p["outcome"] in ("lifetime", "already"):
            return p["outcome"], before, before
        prev_plan, prev_until = u.plan, u.plan_until
        fields = ["is_founder", "founder_since", "founder_until"]
        u.is_founder = True
        u.founder_since = now
        u.founder_until = add_months(now, n)
        if p["changes_plan"]:
            u.plan = "premium"
            u.plan_until = p["new_until"]
            fields += ["plan", "plan_until"]
        u.save(update_fields=fields)
        FounderGrant.objects.create(
            user=u, months=n, granted_at=now, granted_by=actor,
            reason=(reason or "")[:200], prev_plan=prev_plan,
            prev_plan_until=prev_until,
            new_plan_until=u.plan_until if p["changes_plan"] else None,
            plan_changed=p["changes_plan"])
        user.refresh_from_db()
        return p["outcome"], before, state(u)


def revoke(user, actor=None, reason="", now=None):
    """Remove the Founding Member status. Restores the previous plan only when
    the plan is still exactly what the grant set. Returns (changed, before, after)."""
    from .models import FounderGrant, User
    now = now or timezone.now()
    with transaction.atomic():
        u = User.objects.select_for_update().get(pk=user.pk)
        before = state(u)
        if not u.is_founder:
            return False, before, before
        g = (FounderGrant.objects.filter(user=u, revoked_at__isnull=True)
             .order_by("-granted_at", "-id").first())
        fields = ["is_founder", "founder_since", "founder_until"]
        if g is not None and g.plan_changed and u.plan == "premium" \
                and u.plan_until == g.new_plan_until:
            u.plan = g.prev_plan or "free"
            u.plan_until = g.prev_plan_until
            if u.plan == "free":
                u.plan_until = None
            fields += ["plan", "plan_until"]
        u.is_founder = False
        u.founder_since = None
        u.founder_until = None
        u.save(update_fields=fields)
        FounderGrant.objects.filter(user=u, revoked_at__isnull=True).update(
            revoked_at=now, revoked_by=actor, revoke_reason=(reason or "")[:200])
        user.refresh_from_db()
        return True, before, state(u)


def parse_numbers(text):
    """Split a pasted list (newlines, commas, semicolons, tabs) into entries;
    keeps spaces/dashes inside one number ("017 1234-5678")."""
    import re
    raw = re.split(r"[\n\r,;\t|]+", str(text or ""))
    return [x.strip() for x in raw if x.strip()][:MAX_BULK]


def resolve(text="", user_ids=()):
    """Pasted numbers (any format, via core.phone) + picked user ids ->
    {"users": [User…] (unique, in input order), "unknown": [raw…],
     "invalid": [raw…]}."""
    from .models import User
    from .phone import canonical_phone, find_user
    seen, users, unknown, invalid = set(), [], [], []
    for raw in parse_numbers(text):
        c = canonical_phone(raw)
        if not c:
            invalid.append(raw)
            continue
        u = find_user(c)
        if u is None:
            unknown.append(raw)
        elif u.pk not in seen:
            seen.add(u.pk)
            users.append(u)
    ids = []
    for v in user_ids or ():
        try:
            ids.append(int(v))
        except (TypeError, ValueError):
            continue
    if ids:
        by_id = {u.pk: u for u in User.objects.filter(pk__in=ids[:MAX_BULK])}
        for i in ids:
            u = by_id.get(i)
            if u is not None and u.pk not in seen:
                seen.add(u.pk)
                users.append(u)
    return {"users": users, "unknown": unknown, "invalid": invalid}


def preview_rows(users, n=None, now=None):
    from . import plans
    now = now or timezone.now()
    n = int(n or months())
    rows = []
    for u in users:
        p = plan_for(u, n, now)
        rows.append({"u": u, "outcome": p["outcome"], "new_until": p["new_until"],
                     "effective": plans.effective_plan(u)})
    return rows


def members():
    from .models import User
    return User.objects.filter(is_founder=True).order_by("-founder_since", "-id")

