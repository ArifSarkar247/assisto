"""buyinside (owner order 10 Nov 00:50): ONE free trial per shop AND per
Google account / person — enforced on the server.

Two trials exist:
  * kind "trial"      — the 7-day Premium/Business trial (no card, the
                        server grants it; core/plans.start_trial_button).
  * kind "cctv_trial" — the 7-day CCTV trial, a Google Play subscription
                        free-trial offer (cctv_plan_service.sync_from_play).

The keys of a claim (all salted hashes, never raw values — no personal data
is stored, FreeGrantClaim has no user link and is never deleted):
  * the person: phone, email, device ids (core/antifarm.keys_for),
  * the shop: the user's own BusinessProfile, every shop the user is active
    staff of (BusinessStaff), and every CRM org (shop team) the user owns or
    is a member of — a second staff member of the same shop
    cannot start the shop's trial again,
  * the Google side: the purchase's obfuscatedExternalAccountId (our own
    per-account id) and its linkedPurchaseToken chain. Google Play's own
    offer eligibility ("new customers only") is the per-GOOGLE-ACCOUNT half:
    Play never lists the trial offer again to a Google account that ever had
    the subscription, even on another Assisto account.
"""
import logging

from . import antifarm

log = logging.getLogger("assisto.trial")

KINDS = ("trial", "cctv_trial")


def shop_keys(user):
    keys = set()
    try:
        b = getattr(user, "business", None)
        if b is not None and b.pk:
            keys.add(antifarm._h("shop:biz:%d" % b.pk))
    except Exception:
        pass
    try:
        from .models import BusinessStaff
        for bid in BusinessStaff.objects.filter(member=user, active=True) \
                .values_list("business_id", flat=True)[:20]:
            keys.add(antifarm._h("shop:biz:%d" % bid))
    except Exception:
        pass
    try:
        from crm.models import CrmMember, CrmOrg
        for oid in CrmOrg.objects.filter(owner=user).values_list("pk", flat=True)[:20]:
            keys.add(antifarm._h("shop:crm:%d" % oid))
        for oid in CrmMember.objects.filter(user=user).values_list("org_id", flat=True)[:20]:
            keys.add(antifarm._h("shop:crm:%d" % oid))
    except Exception:
        pass
    return keys


def shop_claimed(kind, user):
    """True when the user's SHOP (not the person) already had the trial."""
    try:
        return antifarm.claimed(kind, sorted(shop_keys(user)))
    except Exception:
        return False


def keys_for(user, device_id="", play_account="", linked_token_hash=""):
    keys = set(antifarm.keys_for(user, device_id))
    keys |= shop_keys(user)
    if play_account:
        keys.add(antifarm._h("gpa:%s" % play_account))
    if linked_token_hash:
        keys.add(antifarm._h("gpt:%s" % linked_token_hash))
    return sorted(keys)


def claimed(kind, user, device_id="", **kw):
    """True when this person, shop or Google purchase chain already had the
    `kind` trial."""
    try:
        return antifarm.claimed(kind, keys_for(user, device_id, **kw))
    except Exception:
        log.exception("trial guard: claimed() failed")
        return False


def claim(kind, user, device_id="", **kw):
    """Record the trial on every key. True when NONE of the keys had the
    trial before."""
    try:
        return bool(antifarm.claim(kind, keys_for(user, device_id, **kw)))
    except Exception:
        log.exception("trial guard: claim() failed")
        return False
