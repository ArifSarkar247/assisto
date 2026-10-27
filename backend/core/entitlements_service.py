"""plans-v2 — the ONE server answer for plan gates (owner order 27 Oct).

Every gate in the CRM, the shop (business_views), retention, booking and the
AI sales agent asks HERE, so the rules live in one place:

  * on(user)            feature flag plans_v2 for that account (default OFF:
                        every caller then keeps its old behaviour unchanged)
  * tier(user)          free | premium | business — founder counts as
                        Business; a running free trial counts as the
                        configured trial plan (default Business)
  * allows(user, cap)   one capability (core.logic.entitlements.CAPS)
  * crm_contacts(owner) {used, limit, unlimited, can_add, over}
  * refuse(...)         the structured 402 body / exception

RESOURCE OWNER, NOT THE ACTOR: for a shop or a CRM the plan that counts is
the BUSINESS OWNER's (BusinessProfile.user / CrmOrg.owner) — a staff member's
own plan never unlocks (or locks) the owner's shop.

NO DATA LOSS: gates refuse only NEW records / new automations. Reading,
editing and deleting what already exists always works, even over a limit.
"""
from rest_framework.exceptions import APIException

from .logic import entitlements as E

FLAG = "plans_v2"


def cfg():
    from . import billing
    try:
        return billing.cfg()["plans_v2"]
    except Exception:
        return E.normalize({})


def on(user, play=False):
    if user is None or not getattr(user, "pk", None):
        return False
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


def _paid_active(user):
    from . import plans
    return plans.lifetime_founder(user) or plans.plan_active(user)


def tier(user, c=None):
    """free | premium | business for this account right now."""
    from . import plans
    if user is None:
        return "free"
    c = c or cfg()
    return E.tier_for(plans.effective_plan(user), _paid_active(user),
                      plans.trial_active(user), c)


def allows(user, cap, c=None):
    c = c or cfg()
    return E.allows(tier(user, c), cap, c)


def crm_contacts_used(owner):
    """CRM people (leads + contacts) over EVERY CRM org the account owns —
    a second org is never a way around the limit."""
    from crm.models import Contact, Lead
    return (Lead.objects.filter(org__owner=owner).count()
            + Contact.objects.filter(org__owner=owner).count())


def crm_contacts(owner, c=None):
    c = c or cfg()
    return E.contact_status(tier(owner, c), crm_contacts_used(owner), c)


class UpgradeRequired(APIException):
    status_code = 402
    default_code = "upgrade_required"

    def __init__(self, body):
        super().__init__()
        self.detail = body


def body(feature, owner, lang="bn", limit=None, used=None, c=None):
    c = c or cfg()
    if feature == "crm_contacts":
        needed = E.needed_for_contacts(used or 0, c, tier(owner, c)) or "business"
    else:
        needed = E.needed_plan(feature, c) or "business"
    return E.upgrade_body(feature, needed, tier(owner, c), lang, limit, used)


def refuse(feature, owner, lang="bn", limit=None, used=None):
    raise UpgradeRequired(body(feature, owner, lang, limit, used))


def response(feature, owner, lang="bn", limit=None, used=None):
    from rest_framework.response import Response
    return Response(body(feature, owner, lang, limit, used), status=402)


def check(owner, cap, lang="bn"):
    """None when allowed (or plans_v2 is off for the owner); else the 402
    Response. For views that return early instead of raising."""
    if not on(owner):
        return None
    if allows(owner, cap):
        return None
    return response(cap, owner, lang)


def require_contact_room(owner, lang="bn", adding=1):
    """Raise UpgradeRequired when `adding` more CRM people would pass the
    owner's limit (plans_v2 on only)."""
    if not on(owner):
        return
    c = cfg()
    st = crm_contacts(owner, c)
    if st["used"] + adding > st["limit"]:
        raise UpgradeRequired(body("crm_contacts", owner, lang,
                                   limit=st["limit"], used=st["used"], c=c))


# ---------------------------------------------------------------- payload
def payload(user, lang="bn", crm_owner=None, shop_owner=None):
    """GET /plans/v2 — what the app needs to lock buttons honestly and show
    usage. `crm_owner` / `shop_owner` = the owner of the CRM org / shop the
    caller is looking at (their plan decides)."""
    from . import plans
    c = cfg()
    out = {"on": on(user), "tier": tier(user, c),
           "trial_active": plans.trial_active(user),
           "trial_until": user.trial_until.isoformat() if user.trial_until else None,
           "trial_available": plans.trial_available(user),
           "trial_days": plans.trial_days(user),
           "trial_plan": c["trial_plan"],
           "matrix": E.matrix(c),
           "needed": {cap: E.needed_plan(cap, c) for cap in E.CAPS},
           "unlimited_display_at": c["unlimited_display_at"]}
    out["caps"] = {cap: E.allows(out["tier"], cap, c) for cap in E.CAPS}
    # billapp: the caller's OWN CRM contact usage (when they own a CRM org),
    # for the Plan screen's usage meter. Additive; the CRM screens keep ?org=.
    try:
        from crm.models import CrmOrg
        if CrmOrg.objects.filter(owner=user).exists():
            out["own_crm_contacts"] = crm_contacts(user, c)
    except Exception:
        pass
    if crm_owner is not None:
        t = tier(crm_owner, c)
        out["crm"] = {"on": on(crm_owner), "owner_tier": t,
                      "is_owner": crm_owner.pk == user.pk,
                      "caps": {cap: E.allows(t, cap, c) for cap in E.CAPS},
                      "contacts": crm_contacts(crm_owner, c)}
    if shop_owner is not None:
        t = tier(shop_owner, c)
        out["shop"] = {"on": on(shop_owner), "owner_tier": t,
                       "is_owner": shop_owner.pk == user.pk,
                       "caps": {cap: E.allows(t, cap, c) for cap in E.CAPS}}
    return out
