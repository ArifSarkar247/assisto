"""
probashi_plan.py — pure config + rules for the Probashi FAMILY plan (owner
decision 27 Oct). No DB, no network. The engine is core/probashi_plan.py.

Owner-editable block PricingConfig.data["probashi_plan"] (kept by
core.logic.pricing.normalize). Every value is bounded; a bad value falls back
to the default.
"""
from __future__ import annotations

DEFAULTS = {
    # family seats the payer can give (owner decides 3 or 4)
    "seats": 4,
    # SHARED pool, credits per month, for payer + all seats (40 % rule:
    # owner_actions/PROBASHI_PLAN_BN.md §৩ — 194 is the most every country
    # carries; 180 keeps ~7 % headroom for FX moves)
    "pool_credits": 180,
    # annual base plan (owner 27 Oct): 10 x monthly price AND 10 x monthly
    # credits = 1800 a year, granted 150 a month (never rolled over)
    "annual_pool_credits": 1800,
    # default per-member monthly cap the payer can change (0 = no pool use)
    "default_member_cap": 40,
    "invite_ttl_days": 7,
    # a removal / leave holds the slot AND the person for this long
    "cooldown_days": 30,
    # at most one immediate swap (transfer) per cooldown window
    "transfers_per_window": 1,
    # family members must have a Bangladesh (+880) phone number
    "bd_members_only": True,
    # a seat whose payer plan has been off this long is closed (not a cooldown)
    "lapse_close_days": 30,
}

BOUNDS = {
    "seats": (3, 4),
    "pool_credits": (0, 2000),
    "annual_pool_credits": (0, 24000),
    "default_member_cap": (0, 2000),
    "invite_ttl_days": (1, 30),
    "cooldown_days": (0, 365),
    "transfers_per_window": (0, 5),
    "lapse_close_days": (1, 365),
}

CONSENT_KEYS = ("journeys", "sos", "budget", "reminders", "report")


def _int(v, fb):
    try:
        if isinstance(v, bool):
            return fb
        return int(v)
    except (TypeError, ValueError):
        return fb


def defaults():
    return dict(DEFAULTS)


def normalize(raw):
    raw = raw if isinstance(raw, dict) else {}
    out = defaults()
    for k, (lo, hi) in BOUNDS.items():
        out[k] = max(lo, min(hi, _int(raw.get(k), DEFAULTS[k])))
    v = raw.get("bd_members_only")
    out["bd_members_only"] = v if isinstance(v, bool) else DEFAULTS["bd_members_only"]
    return out


def clean_consent(raw):
    """Only known keys, only real booleans; default is share NOTHING."""
    raw = raw if isinstance(raw, dict) else {}
    return {k: raw.get(k) is True for k in CONSENT_KEYS}


def clean_cap(v, pool):
    n = _int(v, None)
    if n is None or n < 0:
        return None
    return min(n, max(0, int(pool)))


def is_bd_phone(canon):
    """canonical E.164 (+8801XXXXXXXXX) Bangladesh mobile?"""
    s = str(canon or "")
    return s.startswith("+8801") and len(s) == 14 and s[1:].isdigit()


def month_key(dt_local):
    return "%04d-%02d" % (dt_local.year, dt_local.month)


_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(v):
    return str(v).translate(_BN)
