"""safeplans — Safety plans on the server (owner order 3 Nov 18:40, PARTS 2-5).

Pure rules + numbers: core/logic/safe_plans.py. This file reads/writes rows.

  * Switch: feature flag `safe_plans` (default OFF). While OFF nothing is ever
    charged and no request is ever refused here (charge() answers allowed).
  * ALWAYS FREE (PART 5): charge() returns "allowed, nothing charged" for
    SOS, danger alerts and automatic school alerts BEFORE it reads the flag,
    the plan or any balance. SOS / danger / school-alert code never calls
    charge() at all; tests_safeplans proves both.
  * Plans: Child Plan + Safe Family are Google Play subscriptions verified by
    the existing pipeline (payments/play.py -> sync_from_play here: same
    PlayPurchase rows, account binding, acknowledge, revenue once per order,
    refunds). School Safe is invoiced to the school OUTSIDE Play: the owner
    adds the school (code, paid students, paid-until) in Owner Admin and a
    parent's school code covers that child.
  * Credits (PART 3): one state row per account (PaCollectionItem
    "safe_plans"); the monthly allowance resets on the 1st (Asia/Dhaka) with
    NO rollover; extra requests only from PREPAID Play consumable packs
    (sync_pack: verified, granted once per token, then consumed); never
    postpaid — a request with no balance is refused with the "out" sheet.
  * Rewarded ads (PART 4): guardians only, never child accounts; a ticket per
    ad (PhotoAdTicket placement safe_day / safe_req) and ONLY Google's signed
    SSV callback counts it (photo_studio_service.ssv_callback -> on_ad_verified).
  * Guardian limits for guardian2 (PART 6): max_guardians(child_user).
  * Paid map calls for mapscost (PART 1): paid_maps_allowed / note_paid_maps.
"""
import logging
import secrets
from datetime import datetime, timedelta, timezone as dt_tz

from django.db import transaction
from django.utils import timezone

from .logic import safe_plans as SP

log = logging.getLogger("assisto.safeplans")

FLAG = "safe_plans"
STATE = "safe_plans"
SCHOOL_USE = "safe_school_use"      # per CHILD: school requests used this month
ENTITLED = ("SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_CANCELED",
            "SUBSCRIPTION_STATE_IN_GRACE_PERIOD")
AD_PLACEMENTS = {"day": "safe_day", "request": "safe_req"}
BROADCASTS_PER_DAY = 5


# ---------------------------------------------------------------- config
def cfg():
    try:
        from . import billing
        return SP.normalize_cfg(billing.cfg().get("safe_plans"))
    except Exception:
        return SP.defaults()


def feature_on(user=None, play=False):
    try:
        from . import feature_flags as FF
        return FF.is_on(FLAG, user, play)
    except Exception:
        return False


def _now(now=None):
    return now or timezone.now()


def _local(now):
    return timezone.localtime(now)


def _ts(dt):
    return int(dt.timestamp())


# ---------------------------------------------------------------- state rows
def _row(user, collection=STATE, lock=False):
    from .models import PaCollectionItem
    qs = PaCollectionItem.objects.filter(user=user, collection=collection)
    if lock:
        qs = qs.select_for_update()
    row = qs.order_by("id").first()
    if row is None:
        row = PaCollectionItem.objects.create(user=user, collection=collection, data={})
    return row


def get_state(user, now=None):
    from .models import PaCollectionItem
    row = PaCollectionItem.objects.filter(user=user, collection=STATE).order_by("id").first()
    s = dict(row.data or {}) if row else {}
    return SP.roll_period(s, SP.period_key(_local(_now(now))))


def _save(row, data):
    row.data = data
    row.save(update_fields=["data", "updated_at"])


# ---------------------------------------------------------------- who is who
def is_child_account(user):
    """A child account never sees an ad. Fails CLOSED (error -> child)."""
    try:
        from .guardianship import is_known_minor
        from .models import CircleMember
        if is_known_minor(user):
            return True
        return CircleMember.objects.filter(peer_user=user, relation="child",
                                           state="accepted", blocked=False).exists()
    except Exception:
        return True


def is_guardian(user):
    try:
        from .models import CircleMember
        if CircleMember.objects.filter(user=user, relation="child", state="accepted",
                                       blocked=False).exists():
            return True
        from .guardianship import children_of
        return bool(children_of(user))
    except Exception:
        return False


def _children_ids(user):
    from .models import CircleMember
    ids = set(CircleMember.objects.filter(user=user, relation="child", state="accepted",
                                          blocked=False, peer_user__isnull=False)
              .values_list("peer_user_id", flat=True))
    try:
        from .guardianship import children_of
        ids |= {k["child_user_id"] for k in children_of(user) if k.get("child_user_id")}
    except Exception:
        pass
    return ids


# ---------------------------------------------------------------- plans
def _sub_rows(user, product_id):
    from .models import PlayPurchase
    rows = list(PlayPurchase.objects.filter(user=user, kind="sub", product_id=product_id)
                .order_by("-updated_at", "-id"))
    gone = {r.linked_token_hash for r in rows if r.linked_token_hash}
    return [r for r in rows if r.token_hash not in gone and not r.revoked]


def _active_sub(user, product_id, now):
    for r in _sub_rows(user, product_id):
        if r.state in ENTITLED and r.expires_at and r.expires_at > now:
            return r
    return None


def current_plan(user, now=None, c=None):
    """(plan, source, expires_at) — family > child (Play) > child (ad day
    pass) > free. School coverage is per child (school_for_child)."""
    now = _now(now)
    c = c or cfg()
    for plan in ("family", "child"):
        r = _active_sub(user, c["%s_product_id" % plan], now)
        if r is not None:
            return plan, "play", r.expires_at
    s = get_state(user, now)
    until = int(s.get("day_pass_until") or 0)
    if until > _ts(now):
        return "child", "ads", datetime.fromtimestamp(until, tz=dt_tz.utc)
    return "free", "", None


def _school_active(c, code, now):
    sc = c["schools"].get(code)
    if not sc or not sc["active"] or sc["students"] < c["school_min_students"]:
        return None
    if sc["paid_until"] and sc["paid_until"] < _local(now).date().isoformat():
        return None
    return sc


def school_for_child(child_id, now=None, c=None):
    """The active school code covering this child (a parent redeemed it)."""
    if not child_id:
        return None
    from .models import PaCollectionItem
    c = c or cfg()
    now = _now(now)
    for data in (PaCollectionItem.objects.filter(collection=STATE,
                                                 data__school__child_id=int(child_id))
                 .values_list("data", flat=True)[:10]):
        code = ((data or {}).get("school") or {}).get("code")
        if code and _school_active(c, code, now):
            return code
    return None


def _covered_children(code):
    from .models import PaCollectionItem
    return {int(((d or {}).get("school") or {}).get("child_id") or 0)
            for d in PaCollectionItem.objects.filter(collection=STATE, data__school__code=code)
            .values_list("data", flat=True)} - {0}


def max_guardians(child_user, now=None):
    """PART 6 seam (guardian2 reads exactly this name): how many guardians
    may watch this child. School Safe = 4, Child Plan = 2, otherwise the free
    number (2). Never raises; errors -> 2."""
    try:
        c = cfg()
        cid = getattr(child_user, "pk", child_user)
        if school_for_child(cid, now, c):
            return c["school_guardians"]
        best = c["free_guardians"]
        from .models import CircleMember
        gids = set(CircleMember.objects.filter(peer_user_id=cid, relation="child",
                                               state="accepted", blocked=False)
                   .values_list("user_id", flat=True))
        from .models import User
        for g in User.objects.filter(pk__in=list(gids)[:10]):
            plan, _, _ = current_plan(g, now, c)
            best = max(best, SP.guardian_limit(c, plan))
        return best
    except Exception:
        return 2


def plan_features(user, now=None):
    """History days / update minutes for the live-location code (mapscost)."""
    c = cfg()
    plan, _, _ = current_plan(user, now, c)
    if plan == "family":
        return {"plan": plan, "history_days": c["family_history_days"],
                "update_min": c["family_update_min"]}
    if plan == "child":
        return {"plan": plan, "history_days": c["child_history_days"],
                "update_min": c["child_update_min"]}
    return {"plan": plan, "history_days": 1, "update_min": 15}


# ---------------------------------------------------------------- charging
def _school_left(c, child_id, now):
    if not child_id or not school_for_child(child_id, now, c):
        return 0
    from .models import PaCollectionItem
    row = PaCollectionItem.objects.filter(user_id=child_id, collection=SCHOOL_USE).first()
    d = dict(row.data or {}) if row else {}
    used = int(d.get("used") or 0) if d.get("period") == SP.period_key(_local(now)) else 0
    return max(0, c["school_requests"] - used)


def _school_take(child_id, n, now):
    from .models import User
    child = User.objects.filter(pk=child_id).first()
    if child is None or n == 0:
        return
    row = _row(child, SCHOOL_USE, lock=True)
    d = dict(row.data or {})
    pk = SP.period_key(_local(now))
    if d.get("period") != pk:
        d = {"period": pk, "used": 0}
    d["used"] = max(0, int(d.get("used") or 0) + n)
    _save(row, d)


def charge(user, action, child=None, now=None, play=False):
    """Take the credits for one guardian action. Returns
    {ok, charged, took, reason?, sheet?}. ALWAYS-FREE kinds first, then the
    switch: nothing here can ever block SOS, danger or school alerts."""
    if action in SP.ALWAYS_FREE:
        return {"ok": True, "charged": 0, "took": {}, "always_free": True}
    if not feature_on(user, play):
        return {"ok": True, "charged": 0, "took": {}, "off": True}
    now = _now(now)
    c = cfg()
    cost = SP.action_cost(c, action)
    plan, _, _ = current_plan(user, now, c)
    child_id = getattr(child, "pk", child)
    if plan == "child" and child_id:
        # Child Plan covers ONE child (the first one asked about this plan)
        st = get_state(user, now)
        bound = st.get("child_id")
        if bound and int(bound) != int(child_id) and not _school_left(c, child_id, now):
            plan = "free"
    with transaction.atomic():
        row = _row(user, lock=True)
        s = SP.roll_period(dict(row.data or {}), SP.period_key(_local(now)))
        if plan == "child" and child_id and not s.get("child_id"):
            s["child_id"] = int(child_id)
        sl = _school_left(c, child_id, now)
        ok, s2, took = SP.spend(c, s, plan, cost, _ts(now), school_left=sl)
        if not ok:
            _save(row, s)
            return {"ok": False, "charged": 0, "took": {}, "reason": "safe_credits_out",
                    "plan": plan}
        s2.setdefault("log", [])
        s2["log"] = ([{"a": action, "n": cost, "at": _ts(now), "took": took}]
                     + list(s2["log"]))[:20]
        _save(row, s2)
        if took.get("school"):
            _school_take(child_id, took["school"], now)
    return {"ok": True, "charged": cost, "took": dict(took, child_id=child_id or 0),
            "plan": plan}


def refund_charge(user, res, now=None):
    """The request could not be sent after charge(): give the credits back."""
    took = dict((res or {}).get("took") or {})
    if not took or not (res or {}).get("charged"):
        return
    now = _now(now)
    with transaction.atomic():
        row = _row(user, lock=True)
        s = SP.roll_period(dict(row.data or {}), SP.period_key(_local(now)))
        _save(row, SP.refund(s, took))
        if took.get("school") and took.get("child_id"):
            _school_take(took["child_id"], -took["school"], now)


def out_payload(user, lang="bn", plan=None, play=False):
    """The approved "requests are over" sheet: buy credits / watch ads /
    move to Safe Family. Each option only when it can really work."""
    c = cfg()
    plan = plan or current_plan(user, c=c)[0]
    can_ads = ads_eligible(user)[0]
    return {"reason": "safe_credits_out", "plan": plan,
            "options": {"buy": bool(c["on_sale"]),
                        "ads": can_ads,
                        "upgrade": plan != "family" and bool(c["on_sale"])},
            "packs": c["packs"], "family_product_id": c["family_product_id"],
            "base_plan_id": c["base_plan_id"],
            "ads_for_request": c["ads_for_request"],
            "family_price_bdt": c["family_price_bdt"],
            "family_credits": c["family_credits"]}


# ---------------------------------------------------------------- paid maps
def _paid_maps_cap(c, user, now):
    plan, src, _ = current_plan(user, now, c)
    if src != "play":
        cap = 0
    else:
        cap = c["paid_maps_family"] if plan == "family" else c["paid_maps_child"]
    kids = 0
    try:
        kids = sum(1 for k in _children_ids(user) if school_for_child(k, now, c))
    except Exception:
        pass
    return cap + kids * c["paid_maps_school"]


def paid_maps_allowed(user, now=None):
    """mapscost seam: may this account make one more PAID map call (paid
    Geocoding fallback / Routes ETA) this month? Beyond the cap the phone's
    free geocoder + straight-line ETA are used. SOS never asks."""
    try:
        if not feature_on(user):
            return True
        now = _now(now)
        c = cfg()
        return int(get_state(user, now).get("paid_maps") or 0) < _paid_maps_cap(c, user, now)
    except Exception:
        return False


def note_paid_maps(user, now=None):
    now = _now(now)
    with transaction.atomic():
        row = _row(user, lock=True)
        s = SP.roll_period(dict(row.data or {}), SP.period_key(_local(now)))
        s["paid_maps"] = int(s.get("paid_maps") or 0) + 1
        _save(row, s)


# ---------------------------------------------------------------- status
def status(user, now=None, play=False):
    now = _now(now)
    c = cfg()
    plan, src, exp = current_plan(user, now, c)
    s = get_state(user, now)
    nts = _ts(now)
    schools = []
    for cid in sorted(_children_ids(user)):
        code = school_for_child(cid, now, c)
        if code:
            schools.append({"child_id": cid, "code": code,
                            "name": c["schools"][code]["name"],
                            "left": _school_left(c, cid, now)})
    bal = SP.balance(c, s, plan, nts)
    a = SP.ad_progress(s, SP.day_key(_local(now)))
    ok_ads, why = ads_eligible(user)
    nxt = _local(now).replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    nxt = (nxt + timedelta(days=32)).replace(day=1)
    return {
        "enabled": feature_on(user, play), "on_sale": c["on_sale"],
        "plan": plan, "source": src, "expires_at": exp.isoformat() if exp else None,
        "allowance": SP.allowance(c, plan), "used": int(s.get("used") or 0),
        "balance": bal, "resets_at": nxt.isoformat(),
        "packs": [{"left": p["left"], "n": p["n"],
                   "expires_at": datetime.fromtimestamp(p["exp"], tz=dt_tz.utc).isoformat()}
                  for p in SP.live_packs(s, nts)],
        "costs": {"location_request": c["cost_location_request"],
                  "live_trip": c["cost_live_trip"]},
        "child_id": s.get("child_id"),
        "schools": schools,
        "ads": {"eligible": ok_ads, "why": why,
                "for_day": c["ads_for_day"], "for_request": c["ads_for_request"],
                "day_n": a["day_n"], "req_n": a["req_n"],
                "day_left": max(0, c["day_unlocks_per_day"] - a["day_unlocks"]),
                "req_left": max(0, c["request_unlocks_per_day"] - a["req_unlocks"])},
        "plans": {
            "child": {"price_bdt": c["child_price_bdt"], "requests": c["child_requests"],
                      "children": c["child_children"], "guardians": c["child_guardians"],
                      "product_id": c["child_product_id"]},
            "family": {"price_bdt": c["family_price_bdt"], "credits": c["family_credits"],
                       "members": c["family_members"],
                       "history_days": c["family_history_days"],
                       "update_min": c["family_update_min"],
                       "product_id": c["family_product_id"]},
            # Play Payments policy: the app never shows the school price or
            # steers to the outside purchase — only "enter your school code"
            "school": {"guardians": c["school_guardians"],
                       "requests": c["school_requests"]},
        },
        "base_plan_id": c["base_plan_id"],
        "pack_products": c["packs"], "pack_valid_days": c["pack_valid_days"],
        "free_requests": c["free_requests"],
    }


# ---------------------------------------------------------------- Play
def is_safe_product(product_id, c=None):
    c = c or cfg()
    return bool(SP.plan_for_product(c, product_id)) or SP.pack(c, product_id) is not None


def sync_from_play(js, token, line, product_id, base_plan, user=None, now=None, c=None):
    """Mirror one VERIFIED Child Plan / Safe Family subscription token. Same
    dict shape as play.sync_subscription."""
    from .models import PlayPurchase
    from .payments import play as P
    now = _now(now)
    sc = cfg()
    plan = SP.plan_for_product(sc, product_id)
    if not plan or base_plan != sc["base_plan_id"]:
        raise P.PlayError("unknown_product", 400)
    sku = "safe_%s_m" % plan
    aid = (js.get("externalAccountIdentifiers") or {}).get("obfuscatedExternalAccountId", "")
    owner = P._owner_for(token, aid, user)
    state = str(js.get("subscriptionState") or "")
    expiry = P._ts(line.get("expiryTime")) or now
    entitled = state in ENTITLED and expiry > now
    th = P.token_hash(token)
    pp, _ = PlayPurchase.objects.get_or_create(
        token_hash=th, defaults={"user": owner, "purchase_token": token, "kind": "sub",
                                 "product_id": product_id, "owner_ref": P.account_id(owner)})
    linked = str(js.get("linkedPurchaseToken") or "")
    pp.product_id, pp.base_plan_id, pp.sku = product_id, base_plan, sku
    pp.state, pp.expires_at = state, expiry
    pp.auto_renewing = bool((line.get("autoRenewingPlan") or {}).get("autoRenewEnabled"))
    pp.order_id = (P.order_id_of(js, line) or pp.order_id)[:64]
    pp.linked_token_hash = P.token_hash(linked) if linked else ""
    pp.is_test = "testPurchase" in js
    if not pp.owner_ref:
        pp.owner_ref = P.account_id(owner)
    pp.raw = dict(pp.raw or {}, subscriptionState=state, safe_plan=plan)
    price, cur = P._money((line.get("autoRenewingPlan") or {}).get("recurringPrice"))
    amount = price if (price and cur == "BDT") else sc["%s_price_bdt" % plan]
    pp.price_bdt = amount
    pp.save()
    if pp.revoked:
        return {"ok": False, "state": "revoked", "sku": sku, "plan": plan,
                "entitled": False, "expires_at": expiry.isoformat()}
    if entitled and js.get("acknowledgementState") != "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" \
            and not pp.acknowledged:
        try:
            P.ack_subscription(product_id, token, c)
            pp.acknowledged = True
            pp.save(update_fields=["acknowledged", "updated_at"])
        except P.PlayError as e:
            log.warning("safe plan: acknowledge failed %s", e.reason)
    elif js.get("acknowledgementState") == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED":
        if not pp.acknowledged:
            pp.acknowledged = True
            pp.save(update_fields=["acknowledged", "updated_at"])
    if entitled and pp.order_id and not pp.is_test:
        P._charge_once(owner, pp.order_id, sku, amount, "subs")
    return {"ok": True, "state": state, "sku": sku, "plan": plan, "entitled": entitled,
            "expires_at": expiry.isoformat(), "user": owner,
            "safe_plans": status(owner, now)}


def sync_pack(token, product_id, user=None, now=None, c=None):
    """Verify + grant (once per token) + consume one PREPAID request pack."""
    from .models import PlayPurchase
    from .payments import play as P
    now = _now(now)
    sc = cfg()
    pk = SP.pack(sc, product_id)
    if pk is None:
        raise P.PlayError("unknown_product", 400)
    js = P.get_product(product_id, token, c)
    owner = P._owner_for(token, js.get("obfuscatedExternalAccountId", ""), user)
    ps = int(js.get("purchaseState", -1) if js.get("purchaseState") is not None else -1)
    th = P.token_hash(token)
    pp, _ = PlayPurchase.objects.get_or_create(
        token_hash=th, defaults={"user": owner, "purchase_token": token, "kind": "pack",
                                 "product_id": product_id, "sku": product_id,
                                 "owner_ref": P.account_id(owner)})
    pp.order_id = str(js.get("orderId") or pp.order_id)[:64]
    pp.state = {0: "PURCHASED", 1: "CANCELED", 2: "PENDING"}.get(ps, "UNKNOWN")
    ptype = js.get("purchaseType")
    pp.is_test = ptype is not None and int(ptype) == 0
    pp.raw = {k: js.get(k) for k in ("purchaseState", "consumptionState", "orderId",
                                    "purchaseType")}
    pp.save()
    if ps == 2:
        return {"ok": False, "state": "pending", "sku": product_id}
    if ps != 0 or pp.revoked:
        return {"ok": False, "state": "canceled", "sku": product_id}
    granted = 0
    if not pp.granted:
        with transaction.atomic():
            row = _row(owner, lock=True)
            s = SP.roll_period(dict(row.data or {}), SP.period_key(_local(now)))
            added, s = SP.add_pack(sc, s, th, pk["requests"], _ts(now))
            _save(row, s)
            pp.granted = True
            pp.price_bdt = pk["price_bdt"]
            pp.save(update_fields=["granted", "price_bdt", "updated_at"])
        granted = pk["requests"] if added else 0
        if ptype is None and pp.order_id:
            P._charge_once(owner, pp.order_id, product_id, pk["price_bdt"], "packs")
    if not pp.consumed and int(js.get("consumptionState", 0) or 0) == 0:
        try:
            P.consume_product(product_id, token, c)
            pp.consumed = True
        except P.PlayError as e:
            log.warning("safe pack: consume failed %s", e.reason)
    elif int(js.get("consumptionState", 0) or 0) == 1:
        pp.consumed = True
    pp.save(update_fields=["consumed", "updated_at"])
    return {"ok": True, "state": "granted", "sku": product_id, "granted": granted,
            "consumed": bool(pp.consumed), "user": owner,
            "safe_plans": status(owner, now)}


def on_play_revoked(pp):
    """A refunded / voided pack: its unspent requests are removed."""
    if pp is None or pp.kind != "pack" or SP.pack(cfg(), pp.product_id) is None:
        return False
    with transaction.atomic():
        row = _row(pp.user, lock=True)
        hit, s = SP.revoke_pack(dict(row.data or {}), pp.token_hash)
        if hit:
            _save(row, s)
    return hit


# ---------------------------------------------------------------- ads
def ads_eligible(user):
    """(ok, why). Guardians only; never a child account; never a paid
    Premium/Business account (owner 25 Oct: zero ads there); AdMob must be
    able to verify (real ids + rewarded switch)."""
    try:
        if is_child_account(user):
            return False, "child_account"
        if not is_guardian(user):
            return False, "not_guardian"
        from . import sponsor_service as SS
        if SS.is_paid(user):
            return False, "paid_plan"
        from . import billing
        if not (SS.admob_real() and billing.flag_on("ads_rewarded")):
            return False, "ads_not_configured"
        return True, "ok"
    except Exception:
        return False, "error"


def ad_ticket(user, goal, now=None):
    """One SSV ticket for one rewarded ad toward `goal` (day | request)."""
    from .models import PhotoAdTicket
    now = _now(now)
    if goal not in SP.GOALS:
        return {"ok": False, "reason": "bad_goal"}
    if not feature_on(user):
        return {"ok": False, "reason": "off"}
    ok, why = ads_eligible(user)
    if not ok:
        return {"ok": False, "reason": why}
    c = cfg()
    if not SP.ad_can_start(c, get_state(user, now), goal, SP.day_key(_local(now))):
        return {"ok": False, "reason": "capped"}
    place = AD_PLACEMENTS[goal]
    PhotoAdTicket.objects.filter(user=user, placement=place, status="pending",
                                 created_at__lt=now - timedelta(minutes=30)).update(
        status="expired")
    t = (PhotoAdTicket.objects.filter(user=user, placement=place, status="pending")
         .order_by("-created_at").first())
    if t is None:
        t = PhotoAdTicket.objects.create(user=user, kind="rewarded", placement=place,
                                         nonce=secrets.token_urlsafe(24))
    from .photo_studio_service import _ad_units
    return {"ok": True, "nonce": t.nonce, "custom_data": t.nonce, "user_id": str(user.pk),
            "rewarded_unit": _ad_units().get("rewarded", ""), "goal": goal}


def on_ad_verified(t, value_bdt, now=None):
    """Called by the SSV callback (Google-signed) for a safe_* ticket."""
    goal = "day" if t.placement == AD_PLACEMENTS["day"] else "request"
    now = _now(now)
    if is_child_account(t.user):
        return None                      # defence in depth: never for a child
    c = cfg()
    with transaction.atomic():
        row = _row(t.user, lock=True)
        s = SP.roll_period(dict(row.data or {}), SP.period_key(_local(now)))
        s, unlocked = SP.ad_verified(c, s, goal, _ts(now), SP.day_key(_local(now)))
        s["ad_revenue_bdt"] = round(float(s.get("ad_revenue_bdt") or 0) + value_bdt, 4)
        _save(row, s)
    return unlocked


def ticket_state(user, nonce):
    from .models import PhotoAdTicket
    t = PhotoAdTicket.objects.filter(user=user, nonce=str(nonce)[:48],
                                     placement__in=AD_PLACEMENTS.values()).first()
    if t is None:
        return None
    return {"ok": True, "status": t.status, "credited": t.status == "verified"}


# ---------------------------------------------------------------- School Safe
def redeem_school(user, code, child_id, now=None):
    now = _now(now)
    c = cfg()
    code = SP.norm_code(code)
    sc = _school_active(c, code, now)
    if sc is None:
        return {"ok": False, "reason": "bad_code"}
    try:
        child_id = int(child_id)
    except (TypeError, ValueError):
        return {"ok": False, "reason": "pick_child"}
    if child_id not in _children_ids(user):
        return {"ok": False, "reason": "not_your_child"}
    covered = _covered_children(code)
    if child_id not in covered and len(covered) >= sc["students"]:
        return {"ok": False, "reason": "school_full"}
    from .models import CircleMember
    gids = set(CircleMember.objects.filter(peer_user_id=child_id, relation="child",
                                           state="accepted", blocked=False)
               .values_list("user_id", flat=True))
    if len(gids | {user.pk}) > c["school_guardians"]:
        return {"ok": False, "reason": "too_many_guardians"}
    with transaction.atomic():
        row = _row(user, lock=True)
        s = dict(row.data or {})
        s["school"] = {"code": code, "child_id": child_id, "at": _ts(now)}
        _save(row, s)
    return {"ok": True, "code": code, "name": sc["name"]}


def _school_staff(user, code, now, role="admin_ids"):
    c = cfg()
    sc = _school_active(c, code, now)
    if sc is None or user.pk not in sc[role]:
        return None
    return sc


def attendance(user, code, now=None):
    """Gate arrive/leave list for the school (times only, never coordinates)."""
    now = _now(now)
    code = SP.norm_code(code)
    if _school_staff(user, code, now) is None:
        return None
    from .models import SchoolPlan, User
    today = _local(now).date().isoformat()
    ids = sorted(_covered_children(code))
    names = dict(User.objects.filter(pk__in=ids).values_list("pk", "name"))
    rows = []
    for cid in ids:
        p = SchoolPlan.objects.filter(child_user_id=cid, enabled=True).first()
        day = (p.day or {}) if p else {}
        same = day.get("date") == today
        rows.append({"child_id": cid, "name": (p.child_name if p else "") or names.get(cid, ""),
                     "arrived_at": day.get("arrived_school_at") if same else None,
                     "left_at": day.get("left_school_at") if same else None,
                     "school_mode": p is not None})
    rows.sort(key=lambda r: (r["arrived_at"] is not None, r["name"]))
    return {"date": today, "rows": rows, "students": len(ids)}


def broadcast(user, code, text, now=None):
    now = _now(now)
    code = SP.norm_code(code)
    sc = _school_staff(user, code, now)
    if sc is None:
        return {"ok": False, "reason": "not_school_staff"}
    text = " ".join(str(text or "").split())[:300]
    if not text:
        return {"ok": False, "reason": "empty"}
    from django.core.cache import cache
    key = "safeplans:bc:%s:%s" % (code, SP.day_key(_local(now)))
    n = int(cache.get(key) or 0)
    if n >= BROADCASTS_PER_DAY:
        return {"ok": False, "reason": "capped"}
    cache.set(key, n + 1, 86400 + 3600)
    from .models import CircleMember
    from . import push
    kids = _covered_children(code)
    gids = set(CircleMember.objects.filter(peer_user_id__in=kids, relation="child",
                                           state="accepted", blocked=False)
               .values_list("user_id", flat=True))
    from .models import User
    sent = 0
    for g in User.objects.filter(pk__in=gids):
        if push.safe_push(g, "school_broadcast", sc["name"] or "School", sc["name"] or "School",
                          text, text, data={"route": "safe_plans", "code": code}):
            sent += 1
    return {"ok": True, "parents": len(gids), "sent": sent}


def bus_post(user, code, lat, lng, now=None):
    now = _now(now)
    code = SP.norm_code(code)
    if (_school_staff(user, code, now, "driver_ids") is None
            and _school_staff(user, code, now) is None):
        return {"ok": False, "reason": "not_school_staff"}
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return {"ok": False, "reason": "bad_location"}
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return {"ok": False, "reason": "bad_location"}
    from django.core.cache import cache
    # live only: kept 10 minutes in memory, never stored as history
    cache.set("safeplans:bus:%s" % code, {"lat": round(lat, 5), "lng": round(lng, 5),
                                          "at": now.isoformat()}, 600)
    return {"ok": True}


def bus_get(user, code, now=None):
    now = _now(now)
    code = SP.norm_code(code)
    c = cfg()
    if _school_active(c, code, now) is None:
        return None
    mine = any(school_for_child(k, now, c) == code for k in _children_ids(user))
    if not mine and _school_staff(user, code, now) is None:
        return None
    from django.core.cache import cache
    return {"ok": True, "bus": cache.get("safeplans:bus:%s" % code)}


# ---------------------------------------------------------------- Owner Admin
def admin_report(now=None):
    """Numbers only (no names, no places): plan counts, ad revenue against
    unlocks, packs sold. Owner Admin never sees any location."""
    from django.db.models import Count, Sum
    from .models import PaCollectionItem, PhotoAdTicket, PlayPurchase
    now = _now(now)
    c = cfg()
    subs = {}
    for plan in ("child", "family"):
        pid = c["%s_product_id" % plan]
        subs[plan] = (PlayPurchase.objects.filter(kind="sub", product_id=pid, revoked=False,
                                                  state__in=ENTITLED, expires_at__gt=now)
                      .values("user_id").distinct().count())
    pack_ids = [p["id"] for p in c["packs"]]
    packs = PlayPurchase.objects.filter(kind="pack", product_id__in=pack_ids, granted=True,
                                        revoked=False).aggregate(n=Count("id"),
                                                                 bdt=Sum("price_bdt"))
    ads = (PhotoAdTicket.objects.filter(placement__in=AD_PLACEMENTS.values(),
                                        status="verified")
           .aggregate(n=Count("id"), bdt=Sum("value_bdt")))
    unlock_day = unlock_req = 0
    for d in PaCollectionItem.objects.filter(collection=STATE).values_list("data", flat=True):
        d = d or {}
        unlock_day += int(d.get("unlocks_day") or 0)
        unlock_req += int(d.get("unlocks_request") or 0)
    req_cost = c["request_server_bdt"]
    day_cost = ((c["child_children"] + c["child_guardians"]) * c["member_server_bdt"] / 30.0
                + c["day_pass_requests"] * req_cost)
    unlock_cost = unlock_day * day_cost + unlock_req * req_cost
    rev = float(ads["bdt"] or 0)
    return {"subs": subs, "packs_sold": int(packs["n"] or 0),
            "packs_bdt": float(packs["bdt"] or 0),
            "ads_verified": int(ads["n"] or 0), "ads_revenue_bdt": round(rev, 2),
            "unlocks_day": unlock_day, "unlocks_request": unlock_req,
            "unlock_cost_bdt": round(unlock_cost, 2),
            "ads_profit_pct": round(100.0 * (rev - unlock_cost) / rev, 1) if rev else None,
            "schools": [{"code": k, "name": v["name"], "students": v["students"],
                         "covered": len(_covered_children(k)),
                         "paid_until": v["paid_until"], "active": v["active"]}
                        for k, v in sorted(c["schools"].items())]}
