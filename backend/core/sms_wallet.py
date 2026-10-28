"""
sms_wallet.py — tagada2: the SMS PARTS a shop owner spends on Assisto-sent
SMS (owner order 28 Oct, part B). Never AI credits, never cash.

Two buckets, spent in this order:
  allowance  the Business plan's monthly SMS allowance (Owner Admin ->
             Pricing -> sms.business_monthly_parts; proposal 30). Counted per
             Asia/Dhaka calendar month, resets on the 1st, never rolls over.
             Only a PAID Business plan (or a lifetime founder) gets it — a
             free trial does not (an SMS costs real money).
  pack       parts bought as an SMS pack through Play Billing
             (smspack_<parts>, core/payments). Never expire.

    w = sms_wallet.state(user)                 # balance for the screens
    res = sms_wallet.reserve(user, parts, ref) # None = not enough (never send)
    sms_wallet.release(user, res)              # the gateway failed: give back
    sms_wallet.grant_pack(user, sku, parts, key=..., ref=...)  # idempotent
    sms_wallet.revoke_order(user, sku_parts, key)              # Google refund

Every change holds the wallet row lock (select_for_update) and writes ONE
SmsPartLedger row, so two parallel sends can never spend the same part.
"""
from django.db import IntegrityError, transaction
from django.utils import timezone

from .logic import tagada_route as TR

PACK_SKU_PREFIX = "smspack_"


def _month(now=None):
    from .logic import msg_guard as MG
    return MG.local(now or timezone.now()).strftime("%Y-%m")


def cfg():
    from . import sms_service
    return sms_service.cfg()


def has_allowance_plan(user):
    """A PAID Business plan right now (or a lifetime founder)."""
    from . import plans
    try:
        if plans.lifetime_founder(user):
            return True
        return plans.plan_active(user) and getattr(user, "plan", "") == "business"
    except Exception:  # noqa: BLE001 — unreadable = no allowance (safe)
        return False


def allowance_total(user, c=None):
    c = c or cfg()
    if not has_allowance_plan(user):
        return 0
    return max(0, int(c.get("business_monthly_parts", TR.DEFAULT_BUSINESS_MONTHLY_PARTS)))


def _wallet(user, lock=False):
    from .models import SmsWallet
    qs = SmsWallet.objects.select_for_update() if lock else SmsWallet.objects
    w = qs.filter(user=user).first()
    if w is None:
        try:
            with transaction.atomic():
                SmsWallet.objects.create(user=user)
        except IntegrityError:
            pass
        w = qs.get(user=user)
    return w


def _roll(w, now):
    m = _month(now)
    if w.month != m:
        w.month, w.month_used = m, 0
    return w


def _state_of(user, w, now, c):
    total = allowance_total(user, c)
    used = w.month_used if w.month == _month(now) else 0
    a_left = max(0, total - used)
    p_left = max(0, int(w.pack_parts))
    left = a_left + p_left
    low_at = max(0, int(c.get("low_balance_parts", TR.DEFAULT_LOW_PARTS)))
    return {"allowance_total": total, "allowance_used": min(used, total),
            "allowance_left": a_left, "allowance_month": _month(now),
            "pack_left": p_left, "parts_left": left,
            "low": left <= low_at, "low_threshold": low_at,
            "business_plan": total > 0 or has_allowance_plan(user)}


def state(user, now=None):
    now = now or timezone.now()
    c = cfg()
    return _state_of(user, _wallet(user), now, c)


def _ledger(user, bucket, delta, reason, ref="", key=None, pack_after=0):
    from .models import SmsPartLedger
    return SmsPartLedger.objects.create(user=user, bucket=bucket, delta=int(delta),
                                        reason=reason, ref=(ref or "")[:120],
                                        grant_key=key, pack_after=int(pack_after))


def reserve(user, parts, ref="", now=None):
    """Take `parts` (allowance first, then pack). Returns
    {"allowance": n, "pack": m, "ref"} or None when the balance is short —
    the caller must then NOT send."""
    now = now or timezone.now()
    c = cfg()
    with transaction.atomic():
        w = _roll(_wallet(user, lock=True), now)
        st = _state_of(user, w, now, c)
        split = TR.spend_split(parts, st["allowance_left"], st["pack_left"])
        if split is None:
            return None
        w.month_used += split["allowance"]
        w.pack_parts -= split["pack"]
        w.save(update_fields=["month", "month_used", "pack_parts", "updated_at"])
        if split["allowance"]:
            _ledger(user, "allowance", -split["allowance"], "spend", ref,
                    pack_after=w.pack_parts)
        if split["pack"]:
            _ledger(user, "pack", -split["pack"], "spend", ref, pack_after=w.pack_parts)
    return {**split, "ref": ref, "month": w.month}


def release(user, res, now=None):
    """Give a reservation back (the SMS did not go). Allowance goes back to
    the month it came from only while that month is still running."""
    if not res:
        return
    now = now or timezone.now()
    with transaction.atomic():
        w = _wallet(user, lock=True)
        back_a = int(res.get("allowance") or 0) if w.month == res.get("month") else 0
        back_p = int(res.get("pack") or 0)
        w.month_used = max(0, w.month_used - back_a)
        w.pack_parts += back_p
        w.save(update_fields=["month_used", "pack_parts", "updated_at"])
        if back_a:
            _ledger(user, "allowance", back_a, "refund", res.get("ref", ""),
                    pack_after=w.pack_parts)
        if back_p:
            _ledger(user, "pack", back_p, "refund", res.get("ref", ""),
                    pack_after=w.pack_parts)


# ------------------------------------------------------------------ packs
def pack_parts_of(sku):
    """smspack_300 -> 300; 0 for anything else / an unknown size."""
    if not str(sku or "").startswith(PACK_SKU_PREFIX):
        return 0
    try:
        n = int(sku[len(PACK_SKU_PREFIX):])
    except ValueError:
        return 0
    return n if n in TR.PACK_PARTS else 0


def grant_pack(user, sku, parts=None, *, key, ref=""):
    """Add a bought pack's parts once per `key` (a retried grant is a no-op).
    Returns the parts added (0 when it was already granted)."""
    n = int(parts if parts is not None else pack_parts_of(sku))
    if n <= 0 or user is None:
        return 0
    from .models import SmsPartLedger
    with transaction.atomic():
        w = _wallet(user, lock=True)
        if SmsPartLedger.objects.filter(grant_key=key).exists():
            return 0
        w.pack_parts += n
        w.save(update_fields=["pack_parts", "updated_at"])
        _ledger(user, "pack", n, "grant", ref or sku, key=key, pack_after=w.pack_parts)
    return n


def revoke_pack(user, parts, *, key, ref=""):
    """Google refunded a pack: remove its parts that are still unspent (the
    balance never goes below 0; spent parts were real SMS). Once per key."""
    from .models import SmsPartLedger
    n = int(parts or 0)
    if n <= 0 or user is None:
        return 0
    with transaction.atomic():
        w = _wallet(user, lock=True)
        if SmsPartLedger.objects.filter(grant_key=key).exists():
            return 0
        take = min(n, max(0, w.pack_parts))
        w.pack_parts -= take
        w.save(update_fields=["pack_parts", "updated_at"])
        _ledger(user, "pack", -take, "revoke", ref, key=key, pack_after=w.pack_parts)
    return take


def packs(lang="bn", c=None):
    """The SMS-pack list for the balance screen. on_sale only when the owner
    switched packs on (sms.packs_on_sale) AND Play verified the product."""
    from .payments import catalog
    c = c or cfg()
    cost = float(c.get("default_cost_per_segment_bdt") or TR.DEFAULT_COST_PER_PART)
    out = []
    for row in TR.pack_table(cost):
        sku = "%s%d" % (PACK_SKU_PREFIX, row["parts"])
        pid, _ = catalog.play_product(sku)
        out.append({"sku": sku, "parts": row["parts"], "price_bdt": row["price"],
                    "on_sale": catalog.price(sku, "play") is not None,
                    "play_product_id": pid})
    return out
