"""cctvprice — the CCTV plan on Google Play (DB side). Pure rules + prices live
in core/logic/cctv_plan.py; this file only reads/writes rows.

  * Purchases: the existing Play pipeline (core/payments/play.py) verifies
    every token with Google; sync_subscription() hands a CCTV product token
    to sync_from_play() here. Same PlayPurchase rows, same account binding
    (obfuscatedExternalAccountId), same acknowledge, same revenue counter
    (PaymentEvent "play.charge", once per Play order id), same refund path
    (refunds._void_legacy marks the token revoked). RTDN, the daily
    reconcile and the ack sweep all go through sync_subscription, so they
    cover CCTV with no extra wiring.
  * Entitlement: the camera count comes from the base plan id of the
    newest entitled, not-replaced token (c03-monthly -> 3 cameras).
  * Trial: Play's own eligibility ("never had this subscription") decides;
    the server ALSO remembers any CCTV purchase on the account and then the
    app stops offering the trial.
  * Unpaid end: lifecycle_sweep() (daily, billing_daily) — notices, unbind
    from OUR Imou/EZVIZ developer account, keep 30 days, delete.
  * Video add-on: video_addon_days(camera) is the seam the evidence/clip
    code reads (7 / 30 / 0). Storage itself is not here.
"""
import logging
from datetime import datetime, timedelta, timezone as dt_tz

from django.core.cache import cache
from django.utils import timezone

from .logic import cctv_plan as CP

log = logging.getLogger("assisto.cctvprice")

STATE_COLLECTION = "cctv_plan"
ENTITLED = ("SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_CANCELED",
            "SUBSCRIPTION_STATE_IN_GRACE_PERIOD")
HOLD = ("SUBSCRIPTION_STATE_ON_HOLD", "SUBSCRIPTION_STATE_PAUSED")
HOLD_MAX_DAYS = 60          # Play keeps a sub on hold for at most 60 days
CACHE_S = 60


# ---------------------------------------------------------------- config
def cfg():
    try:
        from . import billing
        return CP.normalize_cfg(billing.cfg().get("cctv_plan"))
    except Exception:
        return CP.defaults()


def is_cctv_product(product_id, c=None):
    c = c or cfg()
    return bool(product_id) and product_id in (c["product_id"], c["addon_product_id"])


def feature_on(user, play=False):
    """Behind the existing CCTV switch (cctv_watchman)."""
    try:
        from . import feature_flags as FF
        return FF.is_on("cctv_watchman", user, play)
    except Exception:
        return True


# ---------------------------------------------------------------- state row
def _state_row(user, create=False):
    from .models import PaCollectionItem
    row = PaCollectionItem.objects.filter(user=user, collection=STATE_COLLECTION).first()
    if row is None and create:
        row = PaCollectionItem.objects.create(user=user, collection=STATE_COLLECTION,
                                              data={})
    return row


def get_state(user):
    row = _state_row(user)
    return dict(row.data or {}) if row else {}


def save_state(user, data):
    row = _state_row(user, create=True)
    row.data = data
    row.save(update_fields=["data", "updated_at"])
    cache.delete(_ckey(user))


def _ckey(user):
    return "cctvplan:cams:%s" % user.pk


# ---------------------------------------------------------------- Play sync
def _offer_phase(line):
    ph = line.get("offerPhase") or {}
    for k in ("freeTrial", "introductoryPrice", "prorationPeriod", "basePrice"):
        if k in ph:
            return k
    return ""


def sync_from_play(js, token, line, product_id, base_plan, user=None, now=None, c=None):
    """Mirror one VERIFIED CCTV subscription token (js = Google's
    subscriptionsv2 answer). Returns the same dict shape as
    play.sync_subscription so the verify view / RTDN need no change."""
    from .models import PlayPurchase
    from .payments import play as P
    now = now or timezone.now()
    cc = cfg()
    is_addon = product_id == cc["addon_product_id"]
    parsed = CP.parse_addon_plan(base_plan) if is_addon else CP.parse_base_plan(base_plan)
    if not parsed:
        raise P.PlayError("unknown_product", 400)
    sku = CP.addon_sku(*parsed) if is_addon else CP.plan_sku(*parsed)
    aid = (js.get("externalAccountIdentifiers") or {}).get("obfuscatedExternalAccountId", "")
    owner = P._owner_for(token, aid, user)
    state = str(js.get("subscriptionState") or "")
    expiry = P._ts(line.get("expiryTime")) or now
    entitled = state in ENTITLED and expiry > now
    auto = bool((line.get("autoRenewingPlan") or {}).get("autoRenewEnabled"))
    is_test = "testPurchase" in js
    th = P.token_hash(token)
    pp, _ = PlayPurchase.objects.get_or_create(
        token_hash=th, defaults={"user": owner, "purchase_token": token, "kind": "sub",
                                 "product_id": product_id, "owner_ref": P.account_id(owner)})
    linked = str(js.get("linkedPurchaseToken") or "")
    order_id = P.order_id_of(js, line)
    offer_id = str((line.get("offerDetails") or {}).get("offerId") or "")
    phase = _offer_phase(line)
    start = P._ts(js.get("startTime")) or now
    in_trial = phase == "freeTrial" or (
        not phase and offer_id == cc["trial_offer_id"]
        and now < start + timedelta(days=CP.TRIAL_DAYS))
    pp.product_id, pp.base_plan_id, pp.sku = product_id, base_plan, sku
    pp.state, pp.expires_at, pp.auto_renewing = state, expiry, auto
    pp.order_id = (order_id or pp.order_id)[:64]
    pp.linked_token_hash = P.token_hash(linked) if linked else ""
    pp.is_test = is_test
    if not pp.owner_ref:
        pp.owner_ref = P.account_id(owner)
    raw = dict(pp.raw or {})
    raw.update({"subscriptionState": state, "startTime": js.get("startTime"),
                "cctv": True, "offer_id": offer_id, "offer_phase": phase,
                "trial": bool(raw.get("trial")) or offer_id == cc["trial_offer_id"]
                or phase == "freeTrial", "in_trial": in_trial,
                "latestSuccessfulOrderId": line.get("latestSuccessfulOrderId")})
    pp.raw = raw
    price, cur = P._money((line.get("autoRenewingPlan") or {}).get("recurringPrice"))
    if is_addon:
        catalog_price = CP.addon_price(*parsed)
    else:
        catalog_price = CP.price(*parsed)
    amount = price if (price and cur == "BDT") else catalog_price
    pp.price_bdt = amount
    pp.save()
    cache.delete(_ckey(owner))
    if pp.revoked:
        return {"ok": False, "state": "revoked", "sku": sku, "plan": "cctv",
                "entitled": False, "expires_at": expiry.isoformat()}
    if entitled and js.get("acknowledgementState") != "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" \
            and not pp.acknowledged:
        try:
            P.ack_subscription(product_id, token, c)
            pp.acknowledged = True
            pp.save(update_fields=["acknowledged", "updated_at"])
        except P.PlayError as e:
            log.warning("cctv plan: acknowledge failed %s", e.reason)
    elif js.get("acknowledgementState") == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" \
            and not pp.acknowledged:
        pp.acknowledged = True
        pp.save(update_fields=["acknowledged", "updated_at"])
    # revenue: once per paid Play order (a free-trial period is not revenue)
    if entitled and pp.order_id and not in_trial and not is_test:
        P._charge_once(owner, pp.order_id, sku, amount, "subs")
    # a purchase / renewal / recovery brings an ended account straight back
    try:
        lifecycle_for(owner, now)
    except Exception:
        log.exception("cctv plan: lifecycle after sync failed")
    return {"ok": True, "state": state, "sku": sku, "plan": "cctv",
            "entitled": entitled, "expires_at": expiry.isoformat(), "user": owner,
            "cctv": status(owner, now)}


# ---------------------------------------------------------------- status
def _rows(user, product_id):
    from .models import PlayPurchase
    rows = list(PlayPurchase.objects.filter(user=user, kind="sub", product_id=product_id)
                .order_by("-updated_at", "-id"))
    gone = {r.linked_token_hash for r in rows if r.linked_token_hash}
    return rows, gone


def _current(user, product_id, now):
    """(row, status) — status active|hold|ended|none."""
    rows, gone = _rows(user, product_id)
    if not rows:
        return None, "none"
    live = [r for r in rows if r.token_hash not in gone and not r.revoked]
    for r in live:
        if r.state in ENTITLED and r.expires_at and r.expires_at > now:
            return r, "active"
    for r in live:
        if r.state in HOLD and r.expires_at and \
                r.expires_at > now - timedelta(days=HOLD_MAX_DAYS):
            return r, "hold"
    return rows[0], "ended"


def trial_used(user):
    """Server record: any CCTV plan purchase ever on this account (Play's
    own offer eligibility is the other, per-Google-account half)."""
    from .models import PlayPurchase
    c = cfg()
    return PlayPurchase.objects.filter(user=user, product_id=c["product_id"]).exists()


def status(user, now=None):
    now = now or timezone.now()
    c = cfg()
    row, st = _current(user, c["product_id"], now)
    out = {"status": st, "cameras": 0, "period": "", "base_plan": "",
           "expires_at": None, "auto_renew": False, "in_trial": False,
           "sub_state": "", "trial_used": trial_used(user)}
    if row is not None:
        p = CP.parse_base_plan(row.base_plan_id)
        if p:
            out["cameras"], out["period"] = p
        out.update(base_plan=row.base_plan_id, sub_state=row.state,
                   expires_at=row.expires_at.isoformat() if row.expires_at else None,
                   auto_renew=bool(row.auto_renewing),
                   in_trial=bool((row.raw or {}).get("in_trial")) and st == "active",
                   grace=row.state == "SUBSCRIPTION_STATE_IN_GRACE_PERIOD")
    arow, ast = _current(user, c["addon_product_id"], now)
    out["addon"] = {"status": ast, "days": 0, "cameras": 0}
    if arow is not None:
        ap = CP.parse_addon_plan(arow.base_plan_id)
        if ap:
            out["addon"].update(days=ap[0], cameras=ap[1], base_plan=arow.base_plan_id,
                                expires_at=arow.expires_at.isoformat()
                                if arow.expires_at else None)
    return out


def plan_cameras(user, now=None):
    """Cameras the CCTV plan pays for right now (0 = no active CCTV plan).
    Cached 60 s: this is read on the alert path through owner_caps()."""
    if user is None or not getattr(user, "pk", None):
        return 0
    key = _ckey(user)
    v = cache.get(key)
    if v is not None and now is None:
        return v
    try:
        row, st = _current(user, cfg()["product_id"], now or timezone.now())
        p = CP.parse_base_plan(row.base_plan_id) if (row and st == "active") else None
        v = p[0] if p else 0
    except Exception:
        v = 0
    cache.set(key, v, CACHE_S)
    return v


def counted_cameras(user):
    """Every ENABLED camera of the owner counts — phone cameras included
    (vendor 'phone'), gateway cameras, Imou/EZVIZ cloud cameras."""
    from .models import ShopCamera
    return ShopCamera.objects.filter(site__owner=user, enabled=True).count()


# ---------------------------------------------------------------- add-on seam
def addon_camera_ids(user, now=None):
    """The camera ids that carry the video add-on right now: the owner's own
    choice first (state.addon_cams), then the oldest enabled cameras, up to
    the add-on's camera count. [] without an active plan + add-on."""
    from .models import ShopCamera
    st = status(user, now)
    a = st["addon"]
    if st["status"] != "active" or a["status"] != "active" or not a["cameras"]:
        return [], 0
    ids = list(ShopCamera.objects.filter(site__owner=user, enabled=True)
               .order_by("created", "id").values_list("id", flat=True))
    chosen = [i for i in (get_state(user).get("addon_cams") or []) if i in ids]
    rest = [i for i in ids if i not in chosen]
    return (chosen + rest)[:a["cameras"]], a["days"]


def video_addon_days(camera, now=None):
    """SEAM for the evidence/clip code (another agent): 7 or 30 when this
    camera carries the paid video add-on, else 0. Never raises."""
    try:
        owner = camera.site.owner
        ids, days = addon_camera_ids(owner, now)
        return days if camera.id in ids else 0
    except Exception:
        return 0


def set_addon_cameras(user, ids):
    from .models import ShopCamera
    mine = set(ShopCamera.objects.filter(site__owner=user, id__in=list(ids or []))
               .values_list("id", flat=True))
    data = get_state(user)
    data["addon_cams"] = [int(i) for i in ids if int(i) in mine][:CP.MAX_CAMERAS]
    save_state(user, data)
    return data["addon_cams"]


# ---------------------------------------------------------------- unpaid end
def _bn_date(ts):
    d = datetime.fromtimestamp(ts, tz=dt_tz(timedelta(hours=6)))   # Asia/Dhaka
    return CP.bn_num(d.strftime("%d/%m/%Y")), d.strftime("%d %b %Y")


def _notify(user, action, ts=None):
    t = CP.notice_text(action, *(_bn_date(ts) if ts else ("", "")))
    if not t:
        return 0
    try:
        from .push import push_to_user
        return push_to_user(user, "shop_alert", t[0], t[1], t[2], t[3],
                            data={"type": "cctv_plan", "step": action})
    except Exception:
        return 0


def _covered_by_other_plan(user):
    """Cameras the user's OTHER plan already includes (the existing free /
    Premium / Business camera caps) — those are never unbound."""
    try:
        from . import shop_views as SV
        return int(SV._included_cameras(user, include_cctv=False))
    except Exception:
        return 0


def _clients():
    out = {}
    try:
        from .watchman_views import imou_cloud_on
        from .logic import imou as IM
        if imou_cloud_on():
            out["imou"] = IM.ImouClient.from_integration()
    except Exception:
        pass
    try:
        from .cashguard_views import ezviz_on
        from .logic import ezviz as EZ
        if ezviz_on():
            out["ezviz"] = EZ.EzvizClient.from_integration()
    except Exception:
        pass
    return out


def _device_of(cam):
    """(vendor, device id) of a cloud camera, or None."""
    ref = cam.vendor_ref or ""
    if not ref:
        return None
    if ref.startswith("EZ:"):
        parts = ref.split(":")
        return ("ezviz", parts[1]) if len(parts) > 1 and parts[1] else None
    return ("imou", ref.split(":")[0]) if cam.vendor in ("imou", "dahua", "") else None


def unbind_cameras(user, now=None, clients=None):
    """Release the owner's cameras beyond what another plan covers: cloud
    devices are unbound from OUR developer account (once per device), every
    released camera is switched off and remembered for a later restore.
    Returns {"released", "unbound", "errors"}."""
    from .models import ShopCamera
    now = now or timezone.now()
    keep = _covered_by_other_plan(user)
    cams = list(ShopCamera.objects.filter(site__owner=user, enabled=True)
                .order_by("created", "id"))
    release = cams[keep:]
    clients = _clients() if clients is None else clients
    done, errors, unbound = set(), [], 0
    disabled = []
    for cam in release:
        dev = _device_of(cam)
        if dev and dev not in done:
            done.add(dev)
            client = clients.get(dev[0])
            try:
                if client is None:
                    raise RuntimeError("client_off")
                if dev[0] == "ezviz":
                    client.delete_device(dev[1])
                else:
                    client.unbind_device(dev[1])
                unbound += 1
            except Exception as e:
                errors.append({"vendor": dev[0], "error": type(e).__name__})
        compat = dict(cam.compat or {})
        if dev:
            # the vendor id is freed so the user can add the camera again
            compat["unbound_ref"] = cam.vendor_ref
            compat["needs_rebind"] = True
            cam.vendor_ref = ""
        compat["plan_released_at"] = int(now.timestamp())
        cam.compat = compat
        cam.enabled = False
        cam.save(update_fields=["vendor_ref", "compat", "enabled"])
        disabled.append(cam.id)
    return {"released": disabled, "unbound": unbound, "errors": errors}


def restore_cameras(user, ids):
    """Plan back on: switch released cameras on again (a cloud camera whose
    device was unbound stays off until the user adds it again)."""
    from .models import ShopCamera
    n = 0
    for cam in ShopCamera.objects.filter(site__owner=user, id__in=list(ids or [])):
        if (cam.compat or {}).get("needs_rebind"):
            continue
        cam.enabled = True
        cam.save(update_fields=["enabled"])
        n += 1
    return n


def _wipe_files(qs, depth=0):
    """Remove uploaded bytes of every File/Image field on these rows and on
    their CASCADE children (two levels) before the DB cascade drops them."""
    from django.db import models as M
    n = 0
    model = qs.model
    ffields = [f.name for f in model._meta.fields if isinstance(f, M.FileField)]
    if ffields:
        for obj in qs.only("pk", *ffields).iterator():
            for f in ffields:
                ff = getattr(obj, f)
                try:
                    if ff:
                        ff.delete(save=False)
                        n += 1
                except Exception:
                    pass
    if depth < 2:
        for rel in model._meta.related_objects:
            if rel.one_to_many and rel.on_delete is M.CASCADE:
                child = rel.related_model.objects.filter(**{rel.field.name + "__in": qs})
                n += _wipe_files(child, depth + 1)
    return n


def delete_cctv_data(user):
    """The 30-day keep is over: the owner's CCTV sites (cameras, alerts,
    snapshots, clips, settings) are deleted — files first."""
    from .models import ShopSite
    qs = ShopSite.objects.filter(owner=user)
    files = _wipe_files(qs)
    sites = qs.count()
    qs.delete()
    return {"sites": sites, "files": files}


def lifecycle_for(user, now=None):
    """One step for one account (idempotent). Returns the action taken."""
    now = now or timezone.now()
    c = cfg()
    _, st = _current(user, c["product_id"], now)
    state = get_state(user)
    action, new = CP.lifecycle_step(state, st, int(now.timestamp()), c)
    if action == "none":
        if new != state:
            save_state(user, new)
        return action
    if action == "unbind":
        res = unbind_cameras(user, now)
        new["disabled_ids"] = res["released"]
        new["unbind_errors"] = res["errors"]
        _notify(user, "unbind", new["delete_at"])
    elif action == "delete":
        new["deleted"] = delete_cctv_data(user)
        _notify(user, "delete")
    elif action == "restore":
        restore_cameras(user, new.get("disabled_ids"))
        new.pop("disabled_ids", None)
        _notify(user, "restore")
    elif action == "notice_ended":
        _notify(user, action, new["unbind_at"])
    elif action == "notice_unbind_soon":
        _notify(user, action, new["unbind_at"])
    elif action == "notice_delete_soon":
        _notify(user, action, new["delete_at"])
    else:
        _notify(user, action)
    save_state(user, new)
    try:
        from .payments import entitlement as E
        E.event(user, "cctv_plan." + action, "play", "")
    except Exception:
        pass
    return action


def lifecycle_sweep(now=None, limit=2000):
    """Daily (billing_daily): every account that ever had the CCTV plan."""
    from .models import PlayPurchase, PaCollectionItem, User
    now = now or timezone.now()
    c = cfg()
    ids = set(PlayPurchase.objects.filter(product_id=c["product_id"])
              .exclude(user=None).values_list("user_id", flat=True)[:limit])
    ids |= set(PaCollectionItem.objects.filter(collection=STATE_COLLECTION)
               .values_list("user_id", flat=True)[:limit])
    out = {"checked": 0, "actions": 0, "errors": 0}
    for u in User.objects.filter(pk__in=ids):
        out["checked"] += 1
        try:
            if lifecycle_for(u, now) != "none":
                out["actions"] += 1
        except Exception:
            out["errors"] += 1
            log.exception("cctv plan lifecycle failed")
    return out


def notice_for(user, now=None):
    """The in-app banner for the plan screen (bn, en) or None."""
    s = get_state(user)
    if s.get("deleted_at"):
        return None
    if s.get("unbound_at") and s.get("delete_at"):
        t = CP.notice_text("unbind", *_bn_date(s["delete_at"]))
    elif s.get("ended_at") and s.get("unbind_at"):
        t = CP.notice_text("notice_ended", *_bn_date(s["unbind_at"]))
    elif s.get("hold_at"):
        t = CP.notice_text("notice_hold")
    else:
        return None
    return {"bn": t[2], "en": t[3], "title_bn": t[0], "title_en": t[1]}
