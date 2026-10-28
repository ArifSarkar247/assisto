"""billing-v2 — refunds, voided purchases and refund requests (owner order
27 Oct; rules J, K, L, T).

Google refunds by itself (RTDN voided / REVOKED, confirmed with Google, plus
the DAILY Voided Purchases API poll):
    void_play()  -> that order's credits are removed; credits already spent
                    become a NEGATIVE balance (all credit features blocked
                    until it is back to zero); the plan ends only when the
                    refunded order is the CURRENT paid period (an old renewal
                    never revokes the running subscription); the order's
                    revenue is reversed once; the user's refund counter goes
                    up — the SECOND Google refund blocks new purchases until
                    the owner unblocks; the user is flagged in Owner Admin.

A user's refund request (app button, only inside the window):
    create_request() -> RefundRequest(pending); it never refunds by itself.
    Owner Admin -> Payments -> Refund requests: approve suggested / custom /
    reject with a note.
      Play, full amount   -> orders.refund?revoke=true (Play Developer API)
      Play, partial       -> exact Play Console steps + the amount
      EPS                 -> gateway refund API when the gateway has one,
                             else the manual EPS-panel step
    Our side (always): the order's unused credits leave the ledger (refund
    rows), the plan of that period ends now, revenue is reversed by the
    refunded amount, the user gets the decision in bn/en (in-app alert).
    The voided RTDN Google later sends for the same order is then a no-op.
"""
import logging
from datetime import timedelta
from decimal import Decimal

from django.db import IntegrityError, transaction
from django.utils import timezone

from . import catalog, entitlement as E

log = logging.getLogger(__name__)

POLICY_URL = "/refund-policy"


def window_hours():
    from .. import credits as CR
    return int(CR.bcfg()["refund_window_hours"])


def in_window(order, now=None):
    now = now or timezone.now()
    return (now - order.purchased_at) <= timedelta(hours=window_hours())


def policy(lang="bn"):
    from ..i18n import pick
    w = window_hours()
    return {
        "window_hours": w,
        "url": POLICY_URL + ("?lang=en" if lang == "en" else ""),
        "text": pick(lang,
                     "কেনা বা নবায়নের %d ঘণ্টার মধ্যে অ্যাপ থেকে রিফান্ড চাওয়া যায়। শুধু অব্যবহৃত অংশ ফেরত হয়; ব্যবহার করা ক্রেডিট ও দিন ফেরত হয় না। %d ঘণ্টার পরে রিফান্ড হয় না, শুধু ডুপ্লিকেট চার্জ বা আমাদের ভুলে ফিচার কাজ না করলে মালিকের অনুমোদনে। সাবস্ক্রিপশন বাতিল করলে পরের নবায়ন বন্ধ হয়, এটা রিফান্ড নয়।" % (w, w),
                     "You can ask for a refund in the app within %d hours of a purchase or renewal. Only the unused part is refunded; used credits and used days are not. After %d hours there is no refund, except a duplicate charge or a paid feature that failed through our fault, with the owner's approval. Cancelling stops the next renewal and is not a refund." % (w, w)),
    }


# ----------------------------------------------------------------- abuse state
def account(user):
    from ..models import CreditAccount
    return CreditAccount.objects.get_or_create(user=user)[0]


def purchase_blocked(user):
    from ..models import CreditAccount
    if user is None or not getattr(user, "pk", None):
        return False
    a = CreditAccount.objects.filter(user=user).first()
    return bool(a and a.purchase_blocked)


def _count_refund(user, why, now):
    from ..models import CreditAccount
    with transaction.atomic():
        a = CreditAccount.objects.select_for_update().get_or_create(user=user)[0]
        a.refund_count += 1
        a.flagged = True
        a.flag_reason = ("google refund x%d (%s)" % (a.refund_count, why))[:120]
        if a.refund_count >= 2 and not a.purchase_blocked:
            a.purchase_blocked = True
            a.blocked_at = now
        a.save()
    E.event(user, "refund.counted", "", why, count=a.refund_count, blocked=a.purchase_blocked)
    return a


def unblock(user, actor, note=""):
    a = account(user)
    a.purchase_blocked = False
    a.unblocked_by = actor if getattr(actor, "pk", None) else None
    a.unblocked_at = timezone.now()
    a.save()
    E.event(user, "refund.unblocked", "", "owner", by=getattr(actor, "pk", 0) or 0,
            note=(note or "")[:120])
    return a


# ----------------------------------------------------------------- notify
def notify(user, title_bn, title_en, body_bn, body_en, payload=None):
    """In-app (FamilyAlert, the foreground-polled inbox) + push, bn/en."""
    if user is None:
        return
    try:
        from ..models import FamilyAlert
        from ..i18n import pick
        lang = getattr(user, "language", "bn") or "bn"
        FamilyAlert.objects.create(user=user, kind="billing", severity="info",
                                   title=pick(lang, title_bn, title_en)[:160],
                                   body=pick(lang, body_bn, body_en),
                                   payload={"route": "plans", **(payload or {})})
    except Exception:
        pass
    try:
        from .. import push
        push.push_to_user(user, "reminder", title_bn, title_en, body_bn, body_en,
                          data={"route": "plans"})
    except Exception:
        pass


# ----------------------------------------------------------------- revenue
def _reverse_revenue(order, amount, why):
    """Reverse `amount` of this order's revenue once (PaymentEvent kind
    play.refund is DB-unique per order id)."""
    from ..models import PaymentEvent
    if order.is_test or amount <= 0:
        return False
    if order.channel == "play":
        if PaymentEvent.objects.filter(kind="play.refund", ref=order.order_id[:80]).exists():
            return False
        if not PaymentEvent.objects.filter(kind="play.charge", ref=order.order_id[:80]).exists():
            return False
        net = catalog.net(amount, order.sku, "play")
        try:
            with transaction.atomic():
                E.event(order.user, "play.refund", "play", order.order_id, amount=-amount,
                        net=-net, reason=why)
        except IntegrityError:
            return False
        E.ledger("subs" if order.kind == "sub" else "packs", -float(net))
        return True
    net = catalog.net(amount, order.sku, "gateway")
    E.ledger({"sub": "subs", "seller": "seller"}.get(order.kind, "packs"), -float(net))
    return True


def _end_plan_if_current(order, why, now):
    """End the plan now only when `order` is the CURRENT paid period."""
    from . import orders as O
    from ..models import PlayPurchase
    if order.kind != "sub":
        return False
    if order.channel == "play":
        cur = O.current_sub_order(order.token_hash)
        if cur is None or cur.pk != order.pk:
            return False
        pp = PlayPurchase.objects.filter(token_hash=order.token_hash).first()
        if pp is not None and not pp.revoked:
            pp.revoked = True
            pp.save(update_fields=["revoked", "updated_at"])
        from .play import ref_for
        E.revoke_period("play", ref_for(pp.purchase_token) if pp else "", why, now)
        return True
    E.revoke_period("gateway", "gw:" + order.order_id, why, now)
    return True


# ----------------------------------------------------------------- Google refunds
def void_play(pp, *, order_id="", reason="play_voided", refund_type=1, source="google",
              now=None):
    """A Google refund of one order of a Play token (already confirmed with
    Google by the caller). Idempotent."""
    from ..models import PaidOrder
    from . import orders as O
    now = now or timezone.now()
    oid = str(order_id or "")[:80]
    order = None
    if oid:
        order = PaidOrder.objects.filter(channel="play", order_id=oid).first()
    if order is None and pp.kind == "sub" and not oid:
        order = O.current_sub_order(pp.token_hash)
    if order is None and pp.kind == "pack":
        order = (PaidOrder.objects.filter(channel="play", token_hash=pp.token_hash, kind="pack")
                 .first())
    if order is None and pp.kind == "sub" and PaidOrder.objects.filter(
            channel="play", token_hash=pp.token_hash).exists():
        # an older (pre-v2) renewal of a token we track: reverse that order's
        # revenue only, never revoke the running subscription (audit #9)
        _reverse_legacy_revenue(pp, oid, reason)
        if pp.user_id:
            _count_refund(pp.user, reason, now)
        return None
    if order is None:
        return _void_legacy(pp, oid, reason, now)
    if order.status in ("voided",):
        return order
    if order.refund_source == "owner":
        # the owner already refunded it through a refund request: Google's
        # voided notice for that refund is the confirmation, not a 2nd refund
        PaidOrder.objects.filter(pk=order.pk).update(status="voided")
        return order
    from .. import credits as CR
    res = CR.revoke_order(order, why=reason, debt=True, refund_reason="revoke", now=now)
    if order.user_id and catalog.is_smspack(order.sku or ""):
        # tagada2: an SMS pack — take back its still-unspent SMS parts.
        from .. import sms_wallet
        sms_wallet.revoke_pack(order.user, sms_wallet.pack_parts_of(order.sku),
                               key="revoke:play:%s" % order.order_id,
                               ref="refund:%s" % order.order_id[-12:])
    ended = _end_plan_if_current(order, reason, now)
    if pp.kind == "pack" and not pp.revoked:
        pp.revoked = True
        pp.save(update_fields=["revoked", "updated_at"])
        from ..models import CreditPurchase
        CreditPurchase.objects.filter(txn_ref__startswith="play:" + pp.token_hash[:40]).update(
            granted=False, status="failed")
    PaidOrder.objects.filter(pk=order.pk).update(
        status="voided", refund_source=source, refunded_at=now,
        refunded_amount=order.price, raw={**(order.raw or {}), "refund_type": refund_type})
    _reverse_revenue(order, Decimal(order.price), reason)
    E.event(order.user, "credits.revoke", "play", order.order_id, credits=res["removed"],
            debt=res["debt"], plan_ended=ended, reason=reason, test=order.is_test)
    if order.user_id:
        _count_refund(order.user, reason, now)
        notify(order.user, "রিফান্ড হয়েছে", "Refund processed",
               "Google এই কেনাকাটার টাকা ফেরত দিয়েছে। এর ক্রেডিট ও প্ল্যান সরানো হয়েছে।",
               "Google refunded this purchase. Its credits and plan were removed.",
               {"order": order.order_id[-6:]})
    return order


def _void_legacy(pp, oid, reason, now):
    """Pre-v2 purchase (no PaidOrder): the old revoke, with buckets."""
    from ..models import PaymentEvent
    from .play import ref_for
    if not pp.revoked:
        pp.revoked = True
        pp.save(update_fields=["revoked", "updated_at"])
        if pp.kind == "sub":
            E.revoke_period("play", ref_for(pp.purchase_token), reason, now)
        else:
            E.revoke_pack(pp.user, channel="play", ref=ref_for(pp.purchase_token),
                          reason=reason, debt=True, now=now)
        if pp.user_id:
            _count_refund(pp.user, reason, now)
    _reverse_legacy_revenue(pp, oid, reason)
    return None


def _reverse_legacy_revenue(pp, oid, reason):
    from ..models import PaymentEvent
    ref = str(oid or pp.order_id or "")[:80]
    ch = PaymentEvent.objects.filter(kind="play.charge", ref=ref).first() if ref else None
    if ch and ch.user_id not in (None, pp.user_id):
        ch = None
    if ch and not PaymentEvent.objects.filter(kind="play.refund", ref=ch.ref).exists():
        try:
            with transaction.atomic():
                E.event(pp.user, "play.refund", "play", ch.ref, amount=-ch.amount_bdt,
                        net=-ch.net_bdt, reason=reason)
            E.ledger("subs" if pp.kind == "sub" else "packs", -float(ch.net_bdt))
        except IntegrityError:
            pass
    return None


def voided_poll(now=None, days=3):
    """DAILY: list Google's voided purchases of the last `days` days and
    process every one we have not processed (a missed RTDN). Saves a
    BillingReport. Never raises."""
    from ..models import BillingReport, PlayPurchase
    from . import play
    now = now or timezone.now()
    out = {"seen": 0, "processed": 0, "unknown": 0, "errors": 0}
    if not play.configured():
        out["skipped"] = "not_configured"
        BillingReport.objects.create(kind="voided_poll", ok=True, summary=out)
        return out
    try:
        items = play.voided_list(int((now - timedelta(days=days)).timestamp() * 1000))
    except Exception as e:
        out["errors"] += 1
        out["error"] = getattr(e, "reason", type(e).__name__)
        BillingReport.objects.create(kind="voided_poll", ok=False, summary=out)
        return out
    from ..models import PaidOrder
    for v in items:
        out["seen"] += 1
        tok = str(v.get("purchaseToken") or "")
        oid = str(v.get("orderId") or "")
        pp = PlayPurchase.objects.filter(token_hash=play.token_hash(tok)).first() if tok else None
        if pp is None:
            out["unknown"] += 1
            continue
        o = PaidOrder.objects.filter(channel="play", order_id=oid[:80]).first() if oid else None
        if o is not None and o.status == "voided":
            continue
        if o is None and pp.revoked:
            continue
        try:
            void_play(pp, order_id=oid, reason="play_voided_poll",
                      refund_type=int(v.get("refundType") or 1), now=now)
            out["processed"] += 1
        except Exception:
            log.exception("voided poll: one purchase failed")
            out["errors"] += 1
    BillingReport.objects.create(kind="voided_poll", ok=out["errors"] == 0, summary=out)
    return out


# ----------------------------------------------------------------- refund requests
class RefundError(Exception):
    def __init__(self, reason, status=400, **extra):
        super().__init__(reason)
        self.reason, self.status, self.extra = reason, status, extra


def refundable(user, now=None, lang="bn"):
    """The user's recent orders for the app's "Request a refund" list."""
    from ..models import PaidOrder, RefundRequest
    from . import orders as O
    now = now or timezone.now()
    w = window_hours()
    rows = []
    for o in PaidOrder.objects.filter(user=user, purchased_at__gte=now - timedelta(days=60)):
        req = RefundRequest.objects.filter(order=o).order_by("-id").first()
        ok = o.status == "paid" and in_window(o, now) and req is None
        why = "" if ok else ("already_requested" if req is not None else
                             "refunded" if o.status != "paid" else "outside_window")
        # billapp: the suggested amount and the usage behind it are shown to
        # the user BEFORE they ask (the owner still decides; never a promise)
        sug, use = (O.suggested_refund(o, now) if ok else (None, None))
        rows.append({"suggested": str(sug) if sug is not None else None, "usage": use,
                     "id": o.pk, "channel": o.channel, "order_ref": o.order_id[-6:],
                     "sku": o.sku, "kind": o.kind, "plan": o.plan,
                     "price": str(o.price), "currency": o.currency, "test": o.is_test,
                     "purchased_at": o.purchased_at.isoformat(),
                     "window_ends_at": (o.purchased_at + timedelta(hours=w)).isoformat(),
                     "eligible": ok, "reason": why,
                     "request": _req_json(req) if req else None})
    return {"window_hours": w, "policy": policy(lang), "purchases": rows,
            "requests": [_req_json(r) for r in RefundRequest.objects.filter(user=user)[:20]]}


def _req_json(r):
    return {"id": r.pk, "status": r.status, "order": r.order_id,
            "requested_at": r.requested_at.isoformat(),
            "decided_at": r.decided_at.isoformat() if r.decided_at else None,
            "note": r.decision_note, "approved_amount": str(r.approved_amount)}


RATE_PER_HOUR = 6


def rate_limited(user):
    """billapp: at most RATE_PER_HOUR refund-request attempts per user per
    hour (good or bad), so the endpoint cannot be hammered."""
    from django.core.cache import cache
    key = "refund_req:%s:%s" % (user.pk, timezone.now().strftime("%Y%m%d%H"))
    if cache.add(key, 1, 3600):
        return False
    try:
        n = cache.incr(key)
    except ValueError:
        cache.set(key, 1, 3600)
        n = 1
    return n > RATE_PER_HOUR


def create_request(user, order_pk, reason="", now=None):
    from ..models import PaidOrder, RefundRequest
    from . import orders as O
    now = now or timezone.now()
    o = PaidOrder.objects.filter(pk=order_pk, user=user).first()
    if o is None:
        raise RefundError("not_found", 404)
    if o.status != "paid":
        raise RefundError("not_refundable", 409)
    if not in_window(o, now):
        raise RefundError("outside_window", 409)
    if RefundRequest.objects.filter(order=o).exists():
        raise RefundError("already_requested", 409)
    sug, u = O.suggested_refund(o, now)
    snap = {"price": str(o.price), "currency": o.currency, "suggested": str(sug),
            "hours_since": round((now - o.purchased_at).total_seconds() / 3600.0, 2), **u}
    r = RefundRequest.objects.create(user=user, order=o, reason=(reason or "")[:2000],
                                     requested_at=now, snapshot=snap)
    E.event(user, "refund.requested", o.channel, o.order_id, sku=o.sku, suggested=str(sug))
    return r


def review_row(r, now=None):
    """Everything the Owner Admin refund page shows for one request."""
    from . import orders as O
    now = now or timezone.now()
    o = r.order
    sug, u = O.suggested_refund(o, now) if o else (Decimal(0), {})
    return {"r": r, "o": o, "suggested": sug, "usage": u,
            "hours_since": round((now - o.purchased_at).total_seconds() / 3600.0, 1) if o else None,
            "in_window": in_window(o, now) if o else False,
            "steps": console_steps(o, sug) if o else []}


def console_steps(order, amount):
    if order.channel == "play":
        return [
            "Play Console -> Order management -> search the order id %s" % order.order_id,
            "Open it -> Refund -> choose 'Partial refund'",
            "Amount: %s %s -> reason 'Unused part (Assisto refund policy)' -> Refund" % (amount, order.currency),
            "For a subscription: also choose 'Cancel subscription' so it does not renew",
        ]
    return [
        "EPS merchant panel -> Transactions -> find merchant tx %s" % order.order_id,
        "Refund %s %s and note the EPS refund reference" % (amount, order.currency),
    ]


def approve(req, actor, amount=None, note="", now=None):
    """Approve a refund request (suggested amount when `amount` is None).
    Returns the request. The Google / EPS call goes through the seam."""
    from ..models import PaidOrder, RefundRequest
    from . import orders as O
    from .. import credits as CR
    now = now or timezone.now()
    with transaction.atomic():
        r = RefundRequest.objects.select_for_update().get(pk=req.pk)
        if r.status != "pending":
            raise RefundError("already_decided", 409)
        o = PaidOrder.objects.select_for_update().get(pk=r.order_id)
        if o.status != "paid":
            raise RefundError("not_refundable", 409)
        sug, _u = O.suggested_refund(o, now)
        amt = Decimal(str(sug if amount is None else amount)).quantize(Decimal("0.01"))
        if amt <= 0 or amt > o.price:
            raise RefundError("bad_amount", 400)
        full = amt >= o.price
        action, result = "", {}
        if o.channel == "play":
            if full:          # test orders too: a license tester's refund costs nothing
                from . import play
                try:
                    play.refund_order_api(o.order_id, revoke=True)
                    action, result = "play_api", {"ok": True}
                except Exception as e:
                    raise RefundError("google_error", 502, detail=getattr(e, "reason", ""))
            else:
                action, result = "play_console", {"steps": console_steps(o, amt)}
        else:
            from . import gateway as G
            gw = G.get()
            fn = getattr(gw, "refund", None) if gw is not None else None
            if callable(fn):
                try:
                    result = {"ok": True, "ref": str(fn(o, amt))[:80]}
                    action = "eps_api"
                except Exception as e:
                    action, result = "eps_manual", {"steps": console_steps(o, amt),
                                                    "error": type(e).__name__}
            else:
                action, result = "eps_manual", {"steps": console_steps(o, amt)}
        r.status = "approved" if action in ("play_api", "eps_api") else "manual"
        r.decided_by = actor if getattr(actor, "pk", None) else None
        r.decided_at = now
        r.decision_note = (note or "")[:300]
        r.approved_amount = amt
        r.action = action
        r.result = result
        r.save()
        PaidOrder.objects.filter(pk=o.pk).update(
            status="refunded" if full else "partial", refunded_amount=amt,
            refund_source="owner", refunded_at=now)
    o.refresh_from_db()
    res = CR.revoke_order(o, why="refund_request", debt=False, refund_reason="refund", now=now)
    _end_plan_if_current(o, "refund_request", now)
    if o.channel == "gateway":
        from ..models import PaymentOrder
        PaymentOrder.objects.filter(merchant_tx_id=o.order_id, status="paid").update(
            status="refunded", detail=("refund request #%d" % r.pk)[:200])
    _reverse_revenue(o, amt, "refund_request")
    E.event(o.user, "refund.approved", o.channel, o.order_id, amount=-amt, credits=res["removed"],
            action=action, by=getattr(actor, "pk", 0) or 0, test=o.is_test)
    notify(o.user, "রিফান্ড অনুমোদিত", "Refund approved",
           "আপনার রিফান্ড অনুমোদিত হয়েছে: %s %s। অব্যবহৃত ক্রেডিট সরানো হয়েছে।" % (amt, o.currency),
           "Your refund was approved: %s %s. The unused credits were removed." % (amt, o.currency),
           {"refund": r.pk})
    return r


def reject(req, actor, note="", now=None):
    from ..models import RefundRequest
    now = now or timezone.now()
    with transaction.atomic():
        r = RefundRequest.objects.select_for_update().get(pk=req.pk)
        if r.status != "pending":
            raise RefundError("already_decided", 409)
        r.status = "rejected"
        r.decided_by = actor if getattr(actor, "pk", None) else None
        r.decided_at = now
        r.decision_note = (note or "")[:300]
        r.save()
    E.event(r.user, "refund.rejected", "", str(r.order_id), by=getattr(actor, "pk", 0) or 0)
    notify(r.user, "রিফান্ডের অনুরোধ গ্রহণ হয়নি", "Refund request declined",
           "আপনার রিফান্ডের অনুরোধ গ্রহণ করা যায়নি। কারণ: %s" % (note or "রিফান্ড নীতি"),
           "Your refund request was declined. Reason: %s" % (note or "refund policy"),
           {"refund": r.pk})
    return r


def owner_refund_gateway(order, actor=None, reason="", now=None):
    """Owner 'mark refunded' of a whole EPS order (refund made in the EPS
    panel). Same rules: credits removed with ledger rows, plan ends, revenue
    reversed. No debt (the owner chose a full refund)."""
    from ..models import PaidOrder
    from .. import credits as CR
    now = now or timezone.now()
    po = PaidOrder.objects.filter(channel="gateway", order_id=order.merchant_tx_id).first()
    if po is None or po.status != "paid":
        return None
    PaidOrder.objects.filter(pk=po.pk).update(status="refunded", refunded_amount=po.price,
                                             refund_source="owner", refunded_at=now)
    po.refresh_from_db()
    CR.revoke_order(po, why="owner_refund", debt=False, refund_reason="refund", now=now)
    return po
