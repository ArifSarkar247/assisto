"""
Stolen-While-Unlocked Protection — PURE decision logic.

No DB writes except where a function is explicitly a mutator on a passed model
(register_signal mutates the in-memory ProtectedPhone; the caller saves). No
network, no AI. These are the rules a thief-with-an-unlocked-phone must lose
against: sensitive actions from an untrusted place are delayed (24h) so the
real owner can cancel, and a theft signal freezes the handset (48h) and blocks
ownership transfer entirely.
"""
from datetime import timedelta

from core.logic.safety import haversine_m

TRUSTED_RADIUS_M = 200
DELAY_HOURS = 24
FREEZE_HOURS = 48
WRONG_PIN_LOCK = 5

# Actions that always require family-approver sign-off (if an approver is set).
APPROVAL_ACTIONS = {"sell_transfer", "disarm"}
# Actions that would hand the phone to someone else — blocked while a recent
# theft signal exists (see recent_theft_signal). Transfer/registry endpoints
# are a LATER batch; this is the hook they must consult.
TRANSFER_ACTIONS = {"sell_transfer"}


def is_trusted_location(user, lat, lng):
    """True only if (lat,lng) is within TRUSTED_RADIUS_M of one of the user's
    SavedPlaces. Missing coordinates -> False (the SAFER default: no fix means
    we cannot prove the user is home, so we treat it as untrusted)."""
    if lat is None or lng is None:
        return False
    from core.models import SavedPlace
    for p in SavedPlace.objects.filter(user=user):
        if p.lat is None or p.lng is None:
            continue
        if haversine_m(lat, lng, p.lat, p.lng) <= TRUSTED_RADIUS_M:
            return True
    return False


def is_frozen(phone, now):
    """True if the handset is inside its post-theft freeze window."""
    return bool(phone.frozen_until and phone.frozen_until > now)


def recent_theft_signal(phone, now, days=7):
    """True if any theft signal was registered in the last `days`. Used to
    reject ownership transfers (a thief cannot sell a phone that just screamed
    'stolen')."""
    cutoff = now - timedelta(days=days)
    for s in (phone.signals or []):
        at = s.get("at")
        if not at:
            continue
        try:
            from django.utils.dateparse import parse_datetime
            dt = parse_datetime(at) if isinstance(at, str) else at
        except Exception:
            dt = None
        if dt is not None and dt >= cutoff:
            return True
    return False


def decide_action(phone, action, trusted, now):
    """Return (verdict, effective_at).

    verdict ∈ {'blocked','immediate','delayed','awaiting_approval'}.
    Rules (checked in this order):
      1. frozen handset           -> 'blocked'          (effective_at None)
      2. approver set + sensitive -> 'awaiting_approval' (effective_at None)
      3. trusted location         -> 'immediate'         (effective_at None)
      4. otherwise                -> 'delayed', effective_at = now + 24h
    """
    if is_frozen(phone, now):
        return ("blocked", None)
    if phone.family_approver_id and action in APPROVAL_ACTIONS:
        return ("awaiting_approval", None)
    if trusted:
        return ("immediate", None)
    return ("delayed", now + timedelta(hours=DELAY_HOURS))


def register_signal(phone, kind, now):
    """Record a theft signal: freeze the handset for 48h and append the signal.
    Mutates `phone` in place; the caller is responsible for .save()."""
    phone.frozen_until = now + timedelta(hours=FREEZE_HOURS)
    sigs = list(phone.signals or [])
    sigs.append({"kind": kind, "at": now.isoformat()})
    phone.signals = sigs
    return phone
