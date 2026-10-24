"""
photo_final.py — PURE decisions of the Photo Studio "final" order (owner,
24 Oct 2026: "beat Remini without losing money"). No Django, no DB, no
network, no clock: the stateful side (core/photo_final.py) feeds plain values.

1. PROVIDER SWITCH (server-side only — the app never talks to an AI provider):
       assisto_face  >  runpod_serverless  >  replicate  >  local_worker
   Each paid provider gets an owner-set % of users (`rollout_<slug>` in the
   photo_studio pricing block). A user's bucket (0..99) is a stable hash of
   their id, so the same person always lands on the same provider while the
   rollout is unchanged. Only CONFIGURED providers (key + price) count; the
   rest of the users — and every fallback — go to `local_worker` (our own CPU,
   cost 0). On error / timeout the job falls back to the previous provider
   (the one that served this user before the rollout = local_worker).

2. COST CONTROL: result cache key = (photo hash, preset, provider, version);
   a global per-day spend cap on all paid providers together (default 1 USD):
   a paid run that would cross it WAITS in the queue (or, if the owner turns
   `cap_fallback_local` on, runs on local_worker for free).

3. ULTRA HD quota: per user per month, so quota x cost <= the owner-set share
   of the plan's NET price (price after Play fee / VAT).
"""
import hashlib
import math

PAID_PROVIDERS = ("assisto_face", "runpod_serverless", "replicate")
LOCAL = "local_worker"
PROVIDERS = PAID_PROVIDERS + (LOCAL,)
PRESETS = ("natural", "strong")


def preset_of(strength):
    return "strong" if str(strength or "") == "strong" else "natural"


def bucket(user_key, salt="photo-final"):
    h = hashlib.sha256(("%s:%s" % (salt, user_key)).encode()).hexdigest()
    return int(h[:8], 16) % 100


def pick_provider(user_key, ps, configured):
    """-> slug. `ps` = normalized photo_studio cfg, `configured` = set of paid
    slugs that have a key + price. Rollouts are stacked in priority order; a
    total above 100 % is simply cut at 100."""
    b = bucket(user_key)
    edge = 0
    for slug in PAID_PROVIDERS:
        pct = int(ps.get("rollout_%s" % slug, 0) or 0)
        if slug not in configured or pct <= 0:
            continue
        edge += pct
        if b < edge:
            return slug
    return LOCAL


def chain(first):
    """Providers to try in order: the picked one, then the previous provider
    (local_worker). Never two paid providers for one photo (no double cost)."""
    return [first] if first == LOCAL else [first, LOCAL]


def cache_key(photo_sha256, preset, provider, version, extra=""):
    raw = "|".join(str(x) for x in (photo_sha256, preset, provider, version or "-", extra))
    return hashlib.sha256(raw.encode()).hexdigest()


def cap_allows(spent_today_usd, estimate_usd, cap_usd):
    """A paid run may start only if it cannot push today's spend over the cap."""
    est = max(0.0, float(estimate_usd or 0))
    if est <= 0:
        return True
    return float(spent_today_usd or 0) + est <= max(0.0, float(cap_usd or 0)) + 1e-9


def fit_mp(w, h, max_mp):
    """(w, h) scaled down (never up) to at most max_mp megapixels."""
    px = float(w) * float(h)
    lim = max(0.1, float(max_mp)) * 1e6
    if px <= lim:
        return int(w), int(h)
    f = math.sqrt(lim / px)
    return max(1, int(w * f)), max(1, int(h * f))


def plan_net_bdt(price_bdt, play_fee=0.15, vat=0.0, gateway_fee=0.0):
    """What a monthly plan really earns us (worst store route)."""
    p = max(0.0, float(price_bdt or 0))
    fee = max(float(play_fee or 0), float(gateway_fee or 0))
    return p * (1.0 - min(0.95, fee)) / (1.0 + max(0.0, float(vat or 0)))


def ultra_quota(*, plan_net_bdt_, budget_pct, cost_usd, usd_bdt):
    """Ultra HD images per user per month: floor(budget / cost). 0 when the
    cost is unknown (we never run what we cannot price)."""
    cost_bdt = max(0.0, float(cost_usd or 0)) * max(0.01, float(usd_bdt or 0))
    if cost_bdt <= 0:
        return 0
    budget = max(0.0, float(plan_net_bdt_)) * max(0.0, min(60.0, float(budget_pct or 0))) / 100.0
    return int(math.floor(budget / cost_bdt + 1e-9))


def run_cost_usd(*, seconds=0.0, usd_per_second=0.0, flat_usd=0.0):
    """Real cost of one provider call: billed seconds x price, or a flat
    per-image price (fal.ai / Replicate official models)."""
    sec = max(0.0, float(seconds or 0)) * max(0.0, float(usd_per_second or 0))
    return round(max(sec, max(0.0, float(flat_usd or 0))), 6)
