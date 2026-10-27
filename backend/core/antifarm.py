"""billing-v2 rule P — free / referral / trial credits cannot be farmed with
many accounts or by delete + re-signup on the same phone or device.

A FreeGrantClaim row (kind, hashed key) is written when a free grant is
given, for the account's phone number AND every device it signed in on. The
rows carry no user link and are never deleted (account purge also writes
them for anything the account had claimed), so a re-signup on the same phone
or device finds them. Hashes are the same HMAC the growth module uses
(core.growth._h), so they match ReferralClaim / InstallPing hashes.
"""
from django.db import IntegrityError, transaction

KINDS = ("founding", "trial", "referral")


def _h(raw):
    from .growth import _h as gh
    return gh(raw)


def keys_for(user, device_id=""):
    keys = set()
    try:
        from .phone import canonical_phone
        canon = canonical_phone(getattr(user, "phone", "") or "")
    except Exception:
        canon = getattr(user, "phone", "") or ""
    if canon:
        keys.add(_h("ph:%s" % canon))
    if device_id:
        keys.add(_h("dev:%s" % device_id))
    # no Google sign-in exists in Assisto's auth; the account email (the
    # sign-in id when the user signed up with email) stands in for it
    email = (getattr(user, "email", "") or "").strip().lower()
    if email:
        keys.add(_h("em:%s" % email))
    try:
        from .models import InstallPing
        for dh in InstallPing.objects.filter(user_id=user.pk).exclude(device_hash="") \
                .values_list("device_hash", flat=True):
            keys.add(dh)
    except Exception:
        pass
    return sorted(keys)


def claimed(kind, keys):
    from .models import FreeGrantClaim
    return bool(keys) and FreeGrantClaim.objects.filter(kind=kind, key_hash__in=keys).exists()


def claim(kind, keys):
    """Record the claim for every key. True when NONE of them had claimed
    before (the grant may go ahead)."""
    from .models import FreeGrantClaim
    fresh = True
    for k in keys:
        try:
            with transaction.atomic():
                FreeGrantClaim.objects.create(kind=kind, key_hash=k)
        except IntegrityError:
            fresh = False
    return fresh


def tombstone(user):
    """Before an account purge: keep hashed claims for everything it got."""
    keys = keys_for(user)
    if not keys:
        return 0
    kinds = []
    try:
        from .models import FoundingSeat, ReferralClaim
        if FoundingSeat.objects.filter(user_id=user.pk).exists():
            kinds.append("founding")
        if ReferralClaim.objects.filter(invitee_id=user.pk, state="rewarded").exists():
            kinds.append("referral")
    except Exception:
        pass
    if getattr(user, "trial_until", None):
        kinds.append("trial")
    for k in kinds:
        claim(k, keys)
    return len(kinds)
