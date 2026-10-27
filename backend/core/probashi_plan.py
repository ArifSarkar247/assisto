"""
probashi_plan.py — the Probashi FAMILY plan engine (owner decision 27 Oct,
flag `probashi_plan`, default OFF; design: owner_actions/PROBASHI_PLAN_BN.md).

  * The PAYER (abroad) buys the Play subscription `assisto_probashi`
    (monthly / annual base plans). core/payments/play.py verifies it like any
    other subscription and the payer's plan becomes "probashi" (Premium tier).
  * The payer gives up to `seats` (3 or 4, owner) family SEATS to accepted
    My Circle members with a Bangladesh (+880) number. The member must ACCEPT
    (and chooses what the payer may see). A live seat = Premium features for
    the member (core.plans.effective_plan) and budget & remittance turned on
    (core.feature_flags.resolve).
  * SHARED POOL: the plan's monthly allowance (`pool_credits`) lands on the
    payer's account as ordinary PLAN credit lots (paid-period rules: staged
    unlock, never rolled over, refund -> debt). A member whose own balance
    cannot cover an AI action spends from that pool (ONLY the plan bucket —
    never the payer's packs or free credits), under a per-member monthly cap
    the payer sets. Every pool spend is a payer ledger row with source_type
    "fam:<member id>", so "who spent what" is exact. Credits are never cash,
    never withdrawable, never transferable outside this.
  * Everything is DERIVED from the payer's plan right now: renewal, grace
    (kept), on hold / expired / refunded (benefits stop at once, seats stay
    so a fix brings them back; after `lapse_close_days` they close), so no
    state is copied that could drift.
  * ANTI-ABUSE: one live seat per PERSON anywhere (hashed phone / email /
    device keys, core.antifarm), a removal or leave holds the slot and the
    person for `cooldown_days`, at most `transfers_per_window` immediate swaps.
"""
import logging
from datetime import timedelta

from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

from .logic import probashi_plan as L

log = logging.getLogger(__name__)

FLAG = "probashi_plan"
LIVE_INVITE = ("invited", "active")
COOLDOWN_STATUSES = ("removed", "left", "transferred")


class SeatError(Exception):
    def __init__(self, code, status=400, **extra):
        super().__init__(code)
        self.code, self.status, self.extra = code, status, extra


# ------------------------------------------------------------------ config
def cfg():
    try:
        from . import billing
        return billing.cfg()["probashi_plan"]
    except Exception:
        return L.defaults()


def flag_on(user, play=False):
    """The flag for this account, computed from the flag ROW directly (not
    through feature_flags.resolve, whose probashi hook calls back in here —
    that would recurse). Same rules: on for all / rollout / allow-list, and
    owner / staff preview."""
    if user is None or not getattr(user, "pk", None):
        return False
    try:
        from . import feature_flags as FF
        r = FF.rows().get(FLAG)
        if not r:
            return False
        if (r["enabled_all"] and (r["enabled_play"] or not play)
                and FF.in_rollout(FLAG, user.pk, r["rollout_pct"])):
            return True
        return FF.is_privileged(user) or user.pk in r["allow_user_ids"]
    except Exception:
        return False


def _flag_rows_on():
    """Cheap pre-check: is the flag on for ANYONE (all / rollout / allow-list)?
    Lets the hot paths (effective_plan, /features) skip every seat query while
    the feature is off."""
    try:
        from . import feature_flags as FF
        r = FF.rows().get(FLAG) or {}
        return bool(r.get("enabled_all") or r.get("allow_user_ids"))
    except Exception:
        return False


def _now(now=None):
    return now or timezone.now()


def month_start(now=None):
    loc = timezone.localtime(_now(now))
    return loc.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def month_end(now=None):
    """Start of the NEXT local month (exclusive upper bound)."""
    return (month_start(now) + timedelta(days=32)).replace(day=1)


def month_key(now=None):
    return L.month_key(timezone.localtime(_now(now)))


# ------------------------------------------------------------------ payer / seat state
def payer_paid(payer):
    """The payer's own plan is probashi right now (Play: active, cancelled
    until expiry, or grace)."""
    # the payer's OWN plan only (never effective_plan: its seat hook would
    # loop between two families that once invited each other)
    from . import plans
    try:
        return (payer.plan or "") == "probashi" and plans.plan_active(payer)
    except Exception:
        return False


def payer_live(payer):
    return payer_paid(payer) and flag_on(payer)


def live_seat(member):
    """The member's active seat whose payer is live, else None."""
    if member is None or not getattr(member, "pk", None) or not _flag_rows_on():
        return None
    from .models import ProbashiSeat
    for s in ProbashiSeat.objects.filter(member_id=member.pk, status="active").select_related("payer"):
        if s.payer_id != member.pk and payer_live(s.payer):
            return s
    return None


def member_premium(user):
    """core.plans.effective_plan hook: Premium through a live family seat."""
    try:
        return live_seat(user) is not None
    except Exception:
        return False


def in_live_family(user):
    """Payer with a live plan, or a member of a live seat (feature unlocks)."""
    if user is None or not getattr(user, "pk", None) or not _flag_rows_on():
        return False
    try:
        if payer_live(user):
            return True
        return live_seat(user) is not None
    except Exception:
        return False


# ------------------------------------------------------------------ helpers
def _circle_ok(payer, member):
    """Both sides connected in My Circle (accepted, not blocked)."""
    from .models import CircleMember
    a = CircleMember.objects.filter(user=payer, peer_user=member, state="accepted",
                                    blocked=False).exists()
    b = CircleMember.objects.filter(user=member, peer_user=payer, state="accepted",
                                    blocked=False).exists()
    return a and b


def _keys(member):
    from . import antifarm
    try:
        return antifarm.keys_for(member)
    except Exception:
        return []


def _canon(user):
    try:
        from .phone import canonical_phone
        return canonical_phone(getattr(user, "phone", "") or "") or ""
    except Exception:
        return ""


def expire_invites(payer=None, now=None):
    from .models import ProbashiSeat
    now = _now(now)
    ttl = timedelta(days=int(cfg()["invite_ttl_days"]))
    qs = ProbashiSeat.objects.filter(status="invited", invited_at__lt=now - ttl)
    if payer is not None:
        qs = qs.filter(payer=payer)
    return qs.update(status="expired", ended_at=now, end_reason="invite_timeout")


def _cooldown_since(now):
    return now - timedelta(days=int(cfg()["cooldown_days"]))


def slots_used(payer, now=None):
    from .models import ProbashiSeat
    now = _now(now)
    live = ProbashiSeat.objects.filter(payer=payer, status__in=LIVE_INVITE).count()
    held = ProbashiSeat.objects.filter(payer=payer, counts_cooldown=True,
                                       ended_at__gt=_cooldown_since(now)).count()
    return live + held


def slot_free_at(payer, now=None):
    """When the earliest cooling-down slot frees (None if none)."""
    from .models import ProbashiSeat
    now = _now(now)
    s = (ProbashiSeat.objects.filter(payer=payer, counts_cooldown=True,
                                     ended_at__gt=_cooldown_since(now))
         .order_by("ended_at").first())
    if s is None:
        return None
    return s.ended_at + timedelta(days=int(cfg()["cooldown_days"]))


def _person_check(member, payer, now, exclude_seat=None):
    """One live seat per person anywhere; no hopping inside the cooldown."""
    from .models import ProbashiSeat, ProbashiSeatKey
    keys = _keys(member)
    live = ProbashiSeat.objects.filter(member=member, status="active")
    if exclude_seat is not None:
        live = live.exclude(pk=exclude_seat.pk)
    if live.exists():
        raise SeatError("person_seated", 409)
    if keys:
        hits = ProbashiSeatKey.objects.filter(key_hash__in=keys).select_related("seat")
        if exclude_seat is not None:
            hits = hits.exclude(seat=exclude_seat)
        since = _cooldown_since(now)
        for k in hits:
            s = k.seat
            if s.status == "active":
                raise SeatError("person_seated", 409)
            if s.status in COOLDOWN_STATUSES and s.ended_at and s.ended_at > since:
                raise SeatError("person_cooldown", 409, until=(
                    s.ended_at + timedelta(days=int(cfg()["cooldown_days"]))).isoformat())
    return keys


def _notify(user, title_bn, title_en, body_bn, body_en, route="probashi", kind="probashi"):
    """Push (key-gated, never raises) + the in-app card (foreground fallback)."""
    try:
        from .models import FamilyAlert
        lang = getattr(user, "language", "bn") or "bn"
        FamilyAlert.objects.create(
            user=user, kind=kind, severity="info",
            title=(title_en if lang == "en" else title_bn)[:160],
            body=body_en if lang == "en" else body_bn,
            payload={"route": route, "title_bn": title_bn, "title_en": title_en,
                     "body_bn": body_bn, "body_en": body_en})
    except Exception:
        log.warning("probashi: in-app card failed", exc_info=True)
    try:
        from .push import safe_push
        safe_push(user, "family_alert", title_bn, title_en, body_bn, body_en,
                  data={"route": route, "kind": kind})
    except Exception:
        pass


def _name(u):
    return (getattr(u, "name", "") or "").strip() or "Assisto"


# ------------------------------------------------------------------ seat actions
def invite(payer, member_id, now=None):
    from .models import ProbashiSeat, User
    now = _now(now)
    c = cfg()
    if not flag_on(payer):
        raise SeatError("feature_off", 403)
    if not payer_paid(payer):
        raise SeatError("not_probashi", 402)
    try:
        member = User.objects.get(pk=int(member_id), is_active=True)
    except (User.DoesNotExist, TypeError, ValueError):
        raise SeatError("member_not_found", 404)
    if member.pk == payer.pk:
        raise SeatError("self", 400)
    if not _circle_ok(payer, member):
        raise SeatError("not_in_circle", 400)
    if c["bd_members_only"] and not L.is_bd_phone(_canon(member)):
        raise SeatError("bd_phone_required", 400)
    with transaction.atomic():
        User.objects.select_for_update().get(pk=payer.pk)       # serialise per family
        expire_invites(payer, now)
        if ProbashiSeat.objects.filter(payer=payer, member=member,
                                       status__in=LIVE_INVITE).exists():
            raise SeatError("already_invited", 409)
        if slots_used(payer, now) >= int(c["seats"]):
            raise SeatError("seats_full", 409, free_at=(
                slot_free_at(payer, now).isoformat() if slot_free_at(payer, now) else None))
        if payer_paid(member) and member.plan == "probashi":
            raise SeatError("member_is_payer", 409)
        _person_check(member, payer, now)
        seat = ProbashiSeat.objects.create(
            payer=payer, member=member, status="invited",
            monthly_cap=int(c["default_member_cap"]), invited_at=now)
    pn = _name(payer)
    _notify(member, "%s আপনাকে প্রবাসী পরিবারে যোগ দিতে বলেছেন" % pn,
            "%s invited you to their Probashi family" % pn,
            "যোগ দিলে প্রিমিয়াম সুবিধা ও পরিবারের শেয়ার করা ক্রেডিট পাবেন। কী দেখাবেন তা আপনি বেছে নেবেন।",
            "Join for Premium and the family's shared credits. You choose what they can see.",
            route="probashi/invite")
    return seat


def _seat_for(user, seat_id, role):
    from .models import ProbashiSeat
    try:
        q = ProbashiSeat.objects.select_related("payer", "member")
        seat = q.get(pk=int(seat_id), **({"payer": user} if role == "payer" else {"member": user}))
    except (ProbashiSeat.DoesNotExist, TypeError, ValueError):
        raise SeatError("seat_not_found", 404)
    return seat


def respond(member, seat_id, accept, consent=None, now=None):
    from .models import ProbashiSeat, ProbashiSeatKey, User
    now = _now(now)
    if not flag_on(member):
        raise SeatError("feature_off", 403)
    with transaction.atomic():
        User.objects.select_for_update().get(pk=member.pk)
        seat = _seat_for(member, seat_id, "member")
        seat = ProbashiSeat.objects.select_for_update().get(pk=seat.pk)
        expire_invites(seat.payer, now)
        seat.refresh_from_db()
        if seat.status != "invited":
            raise SeatError("not_pending", 409)
        if not accept:
            seat.status, seat.ended_at, seat.end_reason = "declined", now, "declined"
            seat.save()
            return seat
        if not payer_paid(seat.payer):
            raise SeatError("payer_plan_off", 409)
        keys = _person_check(member, seat.payer, now, exclude_seat=seat)
        seat.status, seat.accepted_at = "active", now
        seat.consent = L.clean_consent(consent)
        seat.save()
        ProbashiSeatKey.objects.filter(seat=seat).delete()
        ProbashiSeatKey.objects.bulk_create(
            [ProbashiSeatKey(seat=seat, key_hash=k) for k in keys])
    mn = _name(member)
    _notify(seat.payer, "%s প্রবাসী পরিবারে যোগ দিয়েছেন" % mn,
            "%s joined your Probashi family" % mn,
            "এখন থেকে তিনি প্রিমিয়াম ও শেয়ার করা ক্রেডিট ব্যবহার করতে পারবেন।",
            "They now have Premium and can use the shared credits.")
    return seat


def _end(seat, status, reason, cooldown, now):
    seat.status, seat.ended_at, seat.end_reason = status, now, reason
    seat.counts_cooldown = cooldown
    seat.save()


def remove(payer, seat_id, now=None):
    now = _now(now)
    with transaction.atomic():
        seat = _seat_for(payer, seat_id, "payer")
        if seat.status == "invited":           # cancelling an invite costs nothing
            _end(seat, "expired", "cancelled", False, now)
            return seat
        if seat.status != "active":
            raise SeatError("not_active", 409)
        _end(seat, "removed", "removed_by_payer", True, now)
    _notify(seat.member, "প্রবাসী পরিবারের সিট শেষ হয়েছে", "Your Probashi family seat ended",
            "%s সিটটি সরিয়ে নিয়েছেন। আপনার নিজের তথ্য আপনার কাছেই আছে।" % _name(payer),
            "%s removed the seat. Your own data stays with you." % _name(payer))
    return seat


def leave(member, seat_id, now=None):
    now = _now(now)
    seat = _seat_for(member, seat_id, "member")
    if seat.status != "active":
        raise SeatError("not_active", 409)
    _end(seat, "left", "left_by_member", True, now)
    _notify(seat.payer, "%s প্রবাসী পরিবার ছেড়েছেন" % _name(member),
            "%s left your Probashi family" % _name(member),
            "সিটটি %s দিন পরে আবার দেওয়া যাবে।" % L.bn_digits(cfg()["cooldown_days"]),
            "The seat can be given again after %s days." % cfg()["cooldown_days"])
    return seat


def transfer(payer, seat_id, new_member_id, now=None):
    """Swap an active seat to another circle member at once (no slot
    cooldown), at most `transfers_per_window` times per cooldown window."""
    from .models import ProbashiSeat
    now = _now(now)
    c = cfg()
    seat = _seat_for(payer, seat_id, "payer")
    if seat.status != "active":
        raise SeatError("not_active", 409)
    used = ProbashiSeat.objects.filter(payer=payer, status="transferred",
                                       ended_at__gt=_cooldown_since(now)).count()
    if used >= int(c["transfers_per_window"]):
        raise SeatError("transfer_limit", 429)
    with transaction.atomic():
        _end(seat, "transferred", "transferred", False, now)
        try:
            new = invite(payer, new_member_id, now=now)
        except SeatError:
            transaction.set_rollback(True)
            raise
    _notify(seat.member, "প্রবাসী পরিবারের সিট অন্যজনকে দেওয়া হয়েছে",
            "Your Probashi family seat was moved",
            "%s সিটটি পরিবারের অন্য একজনকে দিয়েছেন।" % _name(payer),
            "%s gave the seat to another family member." % _name(payer))
    return new


def set_cap(payer, seat_id, cap):
    seat = _seat_for(payer, seat_id, "payer")
    if seat.status not in LIVE_INVITE:
        raise SeatError("not_active", 409)
    n = L.clean_cap(cap, cfg()["pool_credits"])
    if n is None:
        raise SeatError("bad_cap", 400)
    seat.monthly_cap = n
    seat.save(update_fields=["monthly_cap", "updated_at"])
    return seat


def set_consent(member, seat_id, consent):
    seat = _seat_for(member, seat_id, "member")
    if seat.status != "active":
        raise SeatError("not_active", 409)
    seat.consent = L.clean_consent(consent)
    seat.save(update_fields=["consent", "updated_at"])
    return seat


# ------------------------------------------------------------------ shared pool
def _fam_type(member_pk):
    return "fam:%d" % member_pk


def member_used(payer, member_pk, now=None):
    """Pool credits this member used this calendar month (consumed minus
    returned for failed calls)."""
    from .models import CreditLedger
    since, until = month_start(now), month_end(now)
    rows = CreditLedger.objects.filter(user=payer, reason="consume",
                                       source_type=_fam_type(member_pk), created_at__gte=since,
                                       created_at__lt=until)
    used = -int(rows.aggregate(s=Sum("delta"))["s"] or 0)
    refs = list(rows.values_list("source_id", flat=True).distinct())
    back = 0
    if refs:
        back = int(CreditLedger.objects.filter(user=payer, reason="return",
                                               source_id__in=refs)
                   .aggregate(s=Sum("delta"))["s"] or 0)
    return max(0, used - back)


def pool_left(payer):
    from .models import CreditLot
    from . import credits as CR
    return int(CreditLot.objects.filter(user=payer, status="active", bucket=CR.PLAN)
               .aggregate(s=Sum("remaining"))["s"] or 0)


def pool_can(member, need):
    """guard_can hook (no debit): would the family pool cover `need` now?"""
    seat = live_seat(member)
    if seat is None:
        return False
    if member_used(seat.payer, member.pk) + int(need) > int(seat.monthly_cap):
        return False
    return pool_left(seat.payer) >= int(need)


def charge_pool(member, need, note=""):
    """billing.charge hook: the member's own balance cannot cover `need`.
    Returns a billing.charge-shaped dict, or None when the member has no live
    seat (the caller then answers 'insufficient' as before)."""
    from . import credits as CR
    seat = live_seat(member)
    if seat is None:
        return None
    payer = seat.payer
    with transaction.atomic():
        u = CR._lock(payer)
        used = member_used(payer, member.pk)
        if used + int(need) > int(seat.monthly_cap):
            return {"ok": False, "reason": "family_cap", "charged": 0,
                    "balance": int(member.ai_credits or 0),
                    "family": {"used": used, "cap": int(seat.monthly_cap)}}
        res = CR.spend(None, need, note=(note or "ai")[:120], source_type=_fam_type(member.pk),
                       _u=u, only_buckets=(CR.PLAN,))
    if not res["ok"]:
        return {"ok": False, "reason": "family_pool_empty", "charged": 0,
                "balance": int(member.ai_credits or 0)}
    return {"ok": True, "reason": "family_pool", "charged": res["charged"],
            "balance": int(member.ai_credits or 0),
            "spend_ref": "fam:%d:%s" % (payer.pk, res["spend_ref"])}


def return_pool(spend_ref, note="returned"):
    """Return a failed call's pool spend to the payer's SAME lots."""
    from . import credits as CR
    from .models import User
    try:
        _, pid, ref = spend_ref.split(":", 2)
        payer = User.objects.get(pk=int(pid))
    except Exception:
        return 0
    return CR.return_spend(payer, ref, note=note)


# ------------------------------------------------------------------ lifecycle
def on_plan_change(user, before, after):
    """core.payments.entitlement.recompute hook: the payer's plan turned
    probashi on or off (renewal, grace end, hold, expiry, refund). Seats are
    never deleted here — members are told honestly."""
    if before == after or "probashi" not in (before, after):
        return 0
    from .models import ProbashiSeat
    n = 0
    for s in ProbashiSeat.objects.filter(payer=user, status="active").select_related("member"):
        if after == "probashi":
            _notify(s.member, "প্রবাসী পরিবারের সুবিধা আবার চালু", "Probashi family benefits are back",
                    "প্রিমিয়াম ও শেয়ার করা ক্রেডিট আবার পাবেন।",
                    "Premium and the shared credits are available again.")
        else:
            _notify(s.member, "প্রবাসী পরিবারের সুবিধা এখন বন্ধ", "Probashi family benefits paused",
                    "%s-এর প্ল্যানের পেমেন্ট এখন সক্রিয় নেই। পেমেন্ট ঠিক হলে নিজে থেকেই আবার চালু হবে।" % _name(user),
                    "%s's plan payment is not active now. It comes back by itself when the payment is fixed." % _name(user))
        n += 1
    return n


def close_lapsed(now=None):
    """Daily: seats of payers whose plan has been off for lapse_close_days
    close (no cooldown — it was not the family's doing); stale invites
    expire. Returns {"closed", "expired"}."""
    from .models import ProbashiSeat
    now = _now(now)
    out = {"closed": 0, "expired": expire_invites(None, now)}
    limit = now - timedelta(days=int(cfg()["lapse_close_days"]))
    for s in ProbashiSeat.objects.filter(status="active").select_related("payer"):
        p = s.payer
        if payer_paid(p):
            continue
        ended = p.plan_until
        if ended is None or ended < limit:
            _end(s, "expired", "plan_ended", False, now)
            out["closed"] += 1
    return out


# ------------------------------------------------------------------ read models
def seat_dict(s, lang="bn", now=None, with_usage=True):
    from .i18n import pick
    m, p = s.member, s.payer
    d = {"id": s.id, "status": s.status, "monthly_cap": int(s.monthly_cap),
         "consent": L.clean_consent(s.consent),
         "member": {"id": m.pk, "name": _name(m)},
         "payer": {"id": p.pk, "name": _name(p)},
         "invited_at": s.invited_at.isoformat() if s.invited_at else None,
         "accepted_at": s.accepted_at.isoformat() if s.accepted_at else None,
         "ended_at": s.ended_at.isoformat() if s.ended_at else None,
         "end_reason": s.end_reason,
         "status_label": pick(lang, *{
             "invited": ("আমন্ত্রণ পাঠানো হয়েছে", "Invited"),
             "active": ("সক্রিয়", "Active"),
             "declined": ("রাজি হননি", "Declined"),
             "expired": ("মেয়াদ শেষ", "Expired"),
             "removed": ("সরানো হয়েছে", "Removed"),
             "left": ("ছেড়ে গেছেন", "Left"),
             "transferred": ("অন্যজনকে দেওয়া হয়েছে", "Moved to someone else"),
         }.get(s.status, (s.status, s.status)))}
    if with_usage and s.status == "active":
        d["used_this_month"] = member_used(p, m.pk, now)
    return d


def _benefits(lang):
    """ONLY what is built and enforced (owner: no empty promise)."""
    from .i18n import pick
    c = cfg()
    seats, pool = int(c["seats"]), int(c["pool_credits"])
    rows = [
        ("আপনার জন্য প্রিমিয়াম: বিজ্ঞাপন নেই, প্রিমিয়ামের সব সুবিধা",
         "Premium for you: no ads, everything in Premium"),
        ("দেশের পরিবারের %s জন পর্যন্ত (আমার সার্কেল থেকে, বাংলাদেশি নম্বর) প্রিমিয়াম পান" % L.bn_digits(seats),
         "Up to %d family members in Bangladesh (from My Circle) get Premium" % seats),
        ("প্রতি মাসে %s ক্রেডিটের শেয়ার করা পুল — কে কত খরচ করবে তার সীমা আপনি ঠিক করেন" % L.bn_digits(pool),
         "A shared pool of %d credits a month — you set each member's limit" % pool),
        ("পরিবারের জন্য বাজেট ও রেমিট্যান্স চালু (আসা টাকা বনাম বাজেট)",
         "Budget & remittance turned on for the family (money received vs budget)"),
        ("নিরাপদ যাত্রা, SOS ও লোকেশন শেয়ার — সদস্য নিজে রাজি হলে তবেই দেখবেন",
         "Safe Journey, SOS and location sharing — only what each member agrees to share"),
        ("মাসিক পরিবার রিপোর্ট (বাংলা/ইংরেজি) — অ্যাপে ও নোটিফিকেশনে",
         "A monthly family report (Bangla/English) — in the app and by notification"),
    ]
    return [pick(lang, bn, en) for bn, en in rows]


def overview(user, lang="bn", now=None):
    """GET /probashi — what this account sees: the plan facts, its role
    (payer / member / none), seats, pool, pending invites to it."""
    from .models import ProbashiSeat
    now = _now(now)
    c = cfg()
    paid = payer_paid(user)
    out = {"flag": flag_on(user), "seats_max": int(c["seats"]),
           "pool_credits": int(c["pool_credits"]),
           "cooldown_days": int(c["cooldown_days"]),
           "bd_members_only": bool(c["bd_members_only"]),
           "benefits": _benefits(lang), "is_payer": paid,
           "product_id": "assisto_probashi",
           "base_plans": ["monthly", "annual"], "month": month_key(now)}
    if paid:
        expire_invites(user, now)
        seats = list(ProbashiSeat.objects.filter(payer=user).exclude(
            status__in=("declined",)).select_related("member", "payer").order_by("-invited_at")[:20])
        out["seats"] = [seat_dict(s, lang, now) for s in seats
                        if s.status in LIVE_INVITE or (s.ended_at and s.ended_at > now - timedelta(days=60))]
        out["slots_used"] = slots_used(user, now)
        fa = slot_free_at(user, now)
        out["slot_free_at"] = fa.isoformat() if fa else None
        out["pool"] = {"total": int(c["pool_credits"]), "left": pool_left(user),
                       "plan_until": user.plan_until.isoformat() if user.plan_until else None}
        try:
            from .payments import play
            out["subscription"] = play.sub_status(user, now)
        except Exception:
            out["subscription"] = None
    s = (ProbashiSeat.objects.filter(member=user, status="active")
         .select_related("payer", "member").first())
    if s is not None:
        md = seat_dict(s, lang, now)
        md["live"] = payer_live(s.payer)
        md["pool_left"] = pool_left(s.payer) if md["live"] else 0
        out["membership"] = md
    out["invites"] = [seat_dict(x, lang, now, with_usage=False) for x in
                      ProbashiSeat.objects.filter(member=user, status="invited")
                      .select_related("payer", "member")]
    return out


def pool_ledger(payer, lang="bn", now=None, limit=60):
    """Who spent what from the pool this month (payer view)."""
    from .models import CreditLedger, ProbashiSeat, User
    from .i18n import pick
    since = month_start(now)
    rows = (CreditLedger.objects.filter(user=payer, created_at__gte=since, bucket="plan",
                                        reason__in=("consume", "return"))
            .order_by("-created_at", "-id")[:limit])
    ids = {int(r.source_type[4:]) for r in rows if r.source_type.startswith("fam:")}
    names = {u.pk: _name(u) for u in User.objects.filter(pk__in=ids)}
    me = pick(lang, "আপনি", "You")
    out = []
    for r in rows:
        who = me
        if r.source_type.startswith("fam:"):
            who = names.get(int(r.source_type[4:]), "?")
        out.append({"at": r.created_at.isoformat(), "who": who, "delta": int(r.delta),
                    "what": r.note, "kind": r.reason})
    per = [{"member": {"id": s.member_id, "name": _name(s.member)},
            "used": member_used(payer, s.member_id, now), "cap": int(s.monthly_cap)}
           for s in ProbashiSeat.objects.filter(payer=payer, status="active").select_related("member")]
    return {"rows": out, "per_member": per, "left": pool_left(payer)}


def _member_month(member, payer, consent, now, lang):
    """One member's section — ONLY what the member consented to."""
    from .i18n import pick
    from .models import FamilyAlert, Journey, Reminder
    since, until = month_start(now), month_end(now)
    sec = {"member": {"id": member.pk, "name": _name(member)}, "shared": []}
    # location sharing status is the member's REAL My Circle setting
    from .models import CircleMember
    e = CircleMember.objects.filter(user=member, peer_user=payer).first()
    sec["location_sharing"] = bool(e and (e.sharing or {}).get("location"))
    if consent.get("journeys"):
        js = list(Journey.objects.filter(traveller=member).order_by("-created_at")[:5])
        sec["journeys"] = [{"at": j.created_at.isoformat(), "status": j.status,
                            "mode": j.mode, "sos": bool(j.sos_active)} for j in js]
        sec["journeys_month"] = Journey.objects.filter(traveller=member, created_at__gte=since,
                                                     created_at__lt=until).count()
        sec["shared"].append("journeys")
    if consent.get("sos"):
        al = (FamilyAlert.objects.filter(user=payer, payload__from_user_id=member.pk,
                                         kind__in=("sos", "sos_resolved", "checkin_overdue",
                                                   "wellness_alert", "journey"))
              .order_by("-created_at")[:5])
        sec["safety"] = [{"at": a.created_at.isoformat(), "kind": a.kind, "title": a.title}
                         for a in al]
        sec["safety_month"] = FamilyAlert.objects.filter(
            user=payer, payload__from_user_id=member.pk, created_at__gte=since,
            created_at__lt=until,
            kind__in=("sos", "checkin_overdue", "wellness_alert")).count()
        sec["shared"].append("sos")
    if consent.get("budget"):
        try:
            from . import remittance_service as RS
            from .logic.budget import to_poisha
            mk = month_key(now)
            got = sum(to_poisha(e["taka"]) for e in RS.decrypted_entries(member, month=mk))
            plan = sum(to_poisha(v) for v in RS.plan(member).values())
            spent = sum(to_poisha(t["amount"]) for t in RS.money_txns(member, mk))
            sec["money"] = {"received_poisha": got, "budget_poisha": plan, "spent_poisha": spent}
        except Exception:
            log.warning("probashi: money section failed", exc_info=True)
            sec["money"] = None
        sec["shared"].append("budget")
    if consent.get("reminders"):
        sec["reminders_done_month"] = Reminder.objects.filter(
            user=member, done=True, updated_at__gte=since, updated_at__lt=until).count()
        sec["shared"].append("reminders")
    return sec


def dashboard(payer, lang="bn", now=None):
    """GET /probashi/family — the payer's family dashboard."""
    from .models import ProbashiSeat
    now = _now(now)
    if not payer_paid(payer):
        raise SeatError("not_probashi", 402)
    out = []
    for s in ProbashiSeat.objects.filter(payer=payer, status="active").select_related("member", "payer"):
        sec = _member_month(s.member, payer, L.clean_consent(s.consent), now, lang)
        sec["seat"] = seat_dict(s, lang, now)
        out.append(sec)
    return {"members": out, "month": month_key(now), "pool_left": pool_left(payer)}


# ------------------------------------------------------------------ monthly report
def _fmt_taka(p, lang):
    t = int(p) // 100
    s = "{:,}".format(t)
    return ("৳" + L.bn_digits(s)) if lang == "bn" else ("Tk " + s)


def _report_lines(sec, lang):
    from .i18n import pick
    n = sec["member"]["name"]
    lines = []
    if "budget" in sec["shared"] and sec.get("money"):
        m = sec["money"]
        lines.append(pick(lang, "%s: এসেছে %s, বাজেট %s, খরচ %s" % (
            n, _fmt_taka(m["received_poisha"], "bn"), _fmt_taka(m["budget_poisha"], "bn"),
            _fmt_taka(m["spent_poisha"], "bn")),
            "%s: received %s, budget %s, spent %s" % (
            n, _fmt_taka(m["received_poisha"], "en"), _fmt_taka(m["budget_poisha"], "en"),
            _fmt_taka(m["spent_poisha"], "en"))))
    if "journeys" in sec["shared"]:
        k = sec.get("journeys_month", 0)
        lines.append(pick(lang, "%s: %sটি নিরাপদ যাত্রা" % (n, L.bn_digits(k)),
                          "%s: %d Safe Journeys" % (n, k)))
    if "sos" in sec["shared"]:
        k = sec.get("safety_month", 0)
        lines.append(pick(lang, "%s: %sটি নিরাপত্তা সতর্কতা/SOS" % (n, L.bn_digits(k)),
                          "%s: %d safety alerts / SOS" % (n, k)))
    if "reminders" in sec["shared"]:
        k = sec.get("reminders_done_month", 0)
        lines.append(pick(lang, "%s: %sটি রিমাইন্ডার সম্পন্ন" % (n, L.bn_digits(k)),
                          "%s: %d reminders done" % (n, k)))
    return lines


def build_report(payer, month_dt, now=None):
    """Build (idempotent per recipient + month) the payer's report and each
    member's own copy. A member who did not consent to `report` gets no
    section in the payer's report at all. Returns reports created."""
    from .models import ProbashiReport, ProbashiSeat
    now = _now(now)
    mk = L.month_key(month_dt)
    made = 0
    seats = list(ProbashiSeat.objects.filter(payer=payer, status="active").select_related("member"))
    sections = []
    for s in seats:
        consent = L.clean_consent(s.consent)
        sec = _member_month(s.member, payer, consent, month_dt, "bn")
        own = {"bn": _report_lines(sec, "bn"), "en": _report_lines(sec, "en")}
        if consent.get("report"):
            sections.append({"member": sec["member"], "lines": own,
                             "location_sharing": sec["location_sharing"]})
        _, c = ProbashiReport.objects.get_or_create(
            recipient=s.member, month=mk,
            defaults={"payer": payer, "payload": {"sections": [
                {"member": sec["member"], "lines": own, "own": True}]}})
        made += int(c)
    pool = {"total": int(cfg()["pool_credits"]),
            "per_member": [{"name": _name(s.member), "used": member_used(payer, s.member_id, month_dt)}
                           for s in seats]}
    _, c = ProbashiReport.objects.get_or_create(
        recipient=payer, month=mk,
        defaults={"payer": payer, "payload": {"sections": sections, "pool": pool,
                                              "members_total": len(seats)}})
    made += int(c)
    if c:
        _notify(payer, "আপনার মাসিক পরিবার রিপোর্ট তৈরি", "Your monthly family report is ready",
                "দেশের পরিবারের এই মাসের খবর এক নজরে দেখুন।",
                "See your family's month at a glance.", route="probashi/report",
                kind="probashi_report")
    return made


def build_all_reports(now=None):
    """Monthly job (1st of the month, Asia/Dhaka): last month's report for
    every payer with a live plan and at least one active seat."""
    from .models import ProbashiSeat, User
    now = _now(now)
    if not _flag_rows_on():
        return 0
    last = month_start(now) - timedelta(days=1)
    n = 0
    for pid in set(ProbashiSeat.objects.filter(status="active").values_list("payer_id", flat=True)):
        p = User.objects.filter(pk=pid).first()
        if p is None or not payer_live(p):
            continue
        try:
            n += build_report(p, last, now)
        except Exception:
            log.warning("probashi: report failed for %s", pid, exc_info=True)
    return n


def report_dict(r, lang="bn"):
    p = r.payload or {}
    return {"id": r.id, "month": r.month, "read": bool(r.read_at),
            "created_at": r.created_at.isoformat(),
            "sections": [{"member": s.get("member"), "own": bool(s.get("own")),
                          "location_sharing": s.get("location_sharing"),
                          "lines": (s.get("lines") or {}).get(lang) or []}
                         for s in p.get("sections") or []],
            "pool": p.get("pool")}
