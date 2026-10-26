"""Google Play Billing — server verification (Play Developer API) + RTDN.

Every Play purchase is VERIFIED here with Google before anything is granted:
  subscriptions  GET purchases.subscriptionsv2.get  (state, expiry, product,
                 base plan, linkedPurchaseToken, acknowledgementState,
                 externalAccountIdentifiers.obfuscatedExternalAccountId)
                 POST purchases.subscriptions.acknowledge
  credit packs   GET purchases.products.get (purchaseState, consumptionState,
                 obfuscatedExternalAccountId, orderId)
                 POST purchases.products.consume (server consumes, so a pack
                 is granted exactly once and can be bought again)

RTDN (Real-time developer notifications) arrive as a Pub/Sub PUSH to
POST /api/v1/payments/play/rtdn. Authenticity: the Pub/Sub OIDC token
(Authorization: Bearer <Google-signed JWT>, aud = our configured audience,
email = the push service account) and/or a shared ?token= secret. A message
id is processed once (WebhookReceipt). The notification body is never
trusted for state: we always re-fetch the purchase from Google.

Keys live in Admin -> Integrations -> "Google Play Billing" (never in git):
  service_account_json   (Play Developer API access, role in Play Console)
  package_name           (com.assisto.assisto)
  rtdn_audience          (the audience set on the Pub/Sub push subscription)
  rtdn_sa_email          (the service account the push subscription uses)
  rtdn_token             (optional shared secret appended as ?token=)
"""
import base64
import hashlib
import hmac
import json
import logging
import threading
import time
from datetime import datetime, timedelta, timezone as dt_tz
from decimal import Decimal
from urllib.parse import quote

from django.conf import settings
from django.utils import timezone

from . import catalog, entitlement as E

log = logging.getLogger(__name__)

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
TOKEN_URI = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
CERTS_URI = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISS = ("accounts.google.com", "https://accounts.google.com")
HTTP_TIMEOUT_S = 20

ENTITLED_STATES = ("SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_CANCELED",
                   "SUBSCRIPTION_STATE_IN_GRACE_PERIOD")
# RTDN subscriptionNotification.notificationType
NOTIF = {1: "RECOVERED", 2: "RENEWED", 3: "CANCELED", 4: "PURCHASED", 5: "ON_HOLD",
         6: "IN_GRACE_PERIOD", 7: "RESTARTED", 8: "PRICE_CHANGE_CONFIRMED",
         9: "DEFERRED", 10: "PAUSED", 11: "PAUSE_SCHEDULE_CHANGED", 12: "REVOKED",
         13: "EXPIRED", 19: "PRICE_CHANGE_UPDATED", 20: "PENDING_PURCHASE_CANCELED"}


class PlayError(Exception):
    def __init__(self, reason, status=400, detail=""):
        super().__init__(reason)
        self.reason, self.status, self.detail = reason, status, detail


# ----------------------------------------------------------------- config
def cfg():
    from .. import integrations
    c = dict(integrations.get("play_billing") or {})
    sa = c.get("service_account_json")
    if isinstance(sa, str):
        try:
            sa = json.loads(sa)
        except ValueError:
            sa = None
    c["sa"] = sa if isinstance(sa, dict) and sa.get("client_email") and sa.get("private_key") else None
    c["package_name"] = (c.get("package_name") or getattr(
        settings, "PLAY_PACKAGE_NAME", "com.assisto.assisto")).strip()
    return c


def configured():
    try:
        return cfg()["sa"] is not None
    except Exception:
        return False


def account_id(user):
    """obfuscatedAccountId the app passes to Play: u<pk>-<HMAC16>. Lets an RTDN
    for a not-yet-verified token find its account, and lets us refuse a token
    that was bought by another account. No phone/email/name inside."""
    mac = hmac.new(settings.SECRET_KEY.encode(), b"play-acct:%d" % user.pk,
                   hashlib.sha256).hexdigest()[:16]
    return "u%d-%s" % (user.pk, mac)


def user_for_account_id(aid):
    from ..models import User
    try:
        pk = int(str(aid).split("-", 1)[0][1:])
    except (ValueError, IndexError):
        return None
    u = User.objects.filter(pk=pk).first()
    if u and hmac.compare_digest(account_id(u), str(aid)):
        return u
    return None


def token_hash(token):
    return hashlib.sha256(str(token).encode()).hexdigest()


def ref_for(token):
    return "play:" + token_hash(token)[:40]


# ----------------------------------------------------------------- http + oauth
def _http(method, url, body=None, headers=None):
    """(status, json). Single seam for tests."""
    import requests
    if method == "POST":
        r = requests.post(url, data=body if isinstance(body, (bytes, str)) else
                          json.dumps(body or {}), headers=headers or {},
                          timeout=HTTP_TIMEOUT_S)
    else:
        r = requests.get(url, headers=headers or {}, timeout=HTTP_TIMEOUT_S)
    try:
        return r.status_code, (r.json() if r.content else {})
    except ValueError:
        return r.status_code, {}


def _b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def _b64url_dec(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


_tok_lock = threading.Lock()
_tok = {"v": None, "exp": 0.0, "who": None}


def reset_cache():
    with _tok_lock:
        _tok.update(v=None, exp=0.0, who=None)
    _certs.update(keys=None, exp=0.0)


def _assertion(sa, now):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    head = {"alg": "RS256", "typ": "JWT"}
    if sa.get("private_key_id"):
        head["kid"] = sa["private_key_id"]
    claims = {"iss": sa["client_email"], "scope": SCOPE,
              "aud": sa.get("token_uri") or TOKEN_URI, "iat": int(now), "exp": int(now) + 3600}
    si = (_b64url(json.dumps(head, separators=(",", ":")).encode()) + "." +
          _b64url(json.dumps(claims, separators=(",", ":")).encode()))
    key = serialization.load_pem_private_key(sa["private_key"].encode(), password=None)
    return si + "." + _b64url(key.sign(si.encode(), padding.PKCS1v15(), hashes.SHA256()))


def access_token(c=None):
    c = c or cfg()
    sa = c["sa"]
    if not sa:
        raise PlayError("not_configured", 503)
    with _tok_lock:
        now = time.time()
        if _tok["v"] and _tok["who"] == sa["client_email"] and now < _tok["exp"] - 120:
            return _tok["v"]
        from urllib.parse import urlencode
        body = urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                          "assertion": _assertion(sa, now)})
        st, js = _http("POST", TOKEN_URI, body,
                       {"Content-Type": "application/x-www-form-urlencoded"})
        if st != 200 or not js.get("access_token"):
            raise PlayError("play_auth", 502, str(st))
        _tok.update(v=js["access_token"], exp=now + int(js.get("expires_in", 3600) or 3600),
                    who=sa["client_email"])
        return _tok["v"]


def _api(method, path, c=None):
    c = c or cfg()
    url = "%s/%s/%s" % (API, quote(c["package_name"], safe=""), path)
    try:
        st, js = _http(method, url, {} if method == "POST" else None,
                       {"Authorization": "Bearer " + access_token(c),
                        "Content-Type": "application/json"})
    except PlayError:
        raise
    except Exception as e:
        raise PlayError("network", 502, type(e).__name__)
    if st == 404 or st == 410:
        raise PlayError("not_found", 400)
    if st >= 400:
        raise PlayError("google_error", 502, str((js or {}).get("error", {}).get("message", st))[:120])
    return js or {}


def get_subscription(token, c=None):
    return _api("GET", "purchases/subscriptionsv2/tokens/" + quote(token, safe=""), c)


def ack_subscription(product_id, token, c=None):
    return _api("POST", "purchases/subscriptions/%s/tokens/%s:acknowledge"
                % (quote(product_id, safe=""), quote(token, safe="")), c)


def get_product(product_id, token, c=None):
    return _api("GET", "purchases/products/%s/tokens/%s"
                % (quote(product_id, safe=""), quote(token, safe="")), c)


def consume_product(product_id, token, c=None):
    return _api("POST", "purchases/products/%s/tokens/%s:consume"
                % (quote(product_id, safe=""), quote(token, safe="")), c)


# ----------------------------------------------------------------- helpers
def _ts(v):
    if not v:
        return None
    try:
        d = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=dt_tz.utc)
    except ValueError:
        return None


def _money(m):
    try:
        if not m:
            return None, ""
        units = Decimal(str(m.get("units", 0) or 0))
        nanos = Decimal(int(m.get("nanos", 0) or 0)) / Decimal(10 ** 9)
        return (units + nanos).quantize(Decimal("0.01")), str(m.get("currencyCode", ""))
    except Exception:
        return None, ""


def _owner_for(token, aid, user=None):
    """The account a token belongs to. Raises when it belongs to another."""
    from ..models import PlayPurchase
    bound = PlayPurchase.objects.filter(token_hash=token_hash(token)).select_related(
        "user").first()
    by_aid = user_for_account_id(aid) if aid else None
    if aid and by_aid is None:
        raise PlayError("other_account", 403)
    owner = (bound.user if bound else None) or by_aid or user
    if owner is None:
        raise PlayError("unknown_account", 400)
    if user is not None and owner.pk != user.pk:
        raise PlayError("other_account", 403)
    if by_aid is not None and owner.pk != by_aid.pk:
        raise PlayError("other_account", 403)
    return owner


def _charge_once(user, order_id, sku, amount, kind_src):
    """Count Google revenue once per Play order id (each renewal has its own
    order id, e.g. GPA.1234-..-..0, ..1). NET = after the Play fee."""
    from ..models import PaymentEvent
    if not order_id or PaymentEvent.objects.filter(kind="play.charge", ref=order_id[:80]).exists():
        return False
    net = catalog.net(amount, sku, "play")
    E.event(user, "play.charge", "play", order_id, amount=amount, net=net, sku=sku)
    E.ledger(kind_src, net)
    return True


# ----------------------------------------------------------------- subscriptions
def sync_subscription(token, user=None, now=None, c=None):
    """Fetch the token from Google and mirror it into the entitlement service.
    Returns {"ok", "state", "sku", "plan", "entitled", "expires_at"}."""
    from ..models import PlayPurchase
    now = now or timezone.now()
    c = c or cfg()
    js = get_subscription(token, c)
    items = js.get("lineItems") or []
    if not items:
        raise PlayError("no_line_items", 400)
    line = max(items, key=lambda i: _ts(i.get("expiryTime")) or now)
    product_id = str(line.get("productId") or "")
    base_plan = str((line.get("offerDetails") or {}).get("basePlanId") or "")
    sku = catalog.sku_for_play(product_id, base_plan)
    if not sku or not sku.endswith(("_monthly", "_yearly")):
        raise PlayError("unknown_product", 400)
    d = catalog.describe(sku)
    aid = (js.get("externalAccountIdentifiers") or {}).get("obfuscatedExternalAccountId", "")
    owner = _owner_for(token, aid, user)
    state = str(js.get("subscriptionState") or "")
    expiry = _ts(line.get("expiryTime")) or now
    entitled = state in ENTITLED_STATES and expiry > now
    auto = bool((line.get("autoRenewingPlan") or {}).get("autoRenewEnabled"))
    th = token_hash(token)
    pp, _ = PlayPurchase.objects.get_or_create(
        token_hash=th, defaults={"user": owner, "purchase_token": token, "kind": "sub",
                                 "product_id": product_id})
    linked = str(js.get("linkedPurchaseToken") or "")
    pp.product_id, pp.base_plan_id, pp.sku = product_id, base_plan, sku
    pp.state, pp.expires_at, pp.auto_renewing = state, expiry, auto
    pp.order_id = str(js.get("latestOrderId") or pp.order_id)[:64]
    pp.linked_token_hash = token_hash(linked) if linked else ""
    pp.raw = {k: js.get(k) for k in ("subscriptionState", "startTime", "latestOrderId",
                                    "acknowledgementState", "regionCode")}
    price, cur = _money((line.get("autoRenewingPlan") or {}).get("recurringPrice"))
    amount = price if (price and cur == "BDT") else Decimal(catalog.price(sku, "play") or 0)
    pp.price_bdt = amount
    pp.save()
    if linked:
        E.mark_replaced("play", ref_for(linked), ref_for(token), now)
    if pp.revoked:
        return {"ok": False, "state": "revoked", "sku": sku, "plan": d["plan"],
                "entitled": False, "expires_at": expiry.isoformat()}
    E.upsert_play_period(owner, ref=ref_for(token), plan=d["plan"],
                         starts=_ts(js.get("startTime")) or now, ends=expiry,
                         entitled=entitled, auto_renew=auto, state=state, now=now)
    if entitled and js.get("acknowledgementState") != "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" \
            and not pp.acknowledged:
        try:
            ack_subscription(product_id, token, c)
            pp.acknowledged = True
            pp.save(update_fields=["acknowledged", "updated_at"])
        except PlayError as e:
            log.warning("play: acknowledge failed %s", e.reason)   # retried next sync
    elif js.get("acknowledgementState") == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED":
        if not pp.acknowledged:
            pp.acknowledged = True
            pp.save(update_fields=["acknowledged", "updated_at"])
    if entitled and pp.order_id and "testPurchase" not in js:
        _charge_once(owner, pp.order_id, sku, amount, "subs")
    elif entitled and pp.order_id:
        E.event(owner, "play.test_charge", "play", pp.order_id, sku=sku)
    return {"ok": True, "state": state, "sku": sku, "plan": d["plan"],
            "entitled": entitled, "expires_at": expiry.isoformat(), "user": owner}


def _replaced_hashes(user):
    from ..models import PlayPurchase
    return set(PlayPurchase.objects.filter(user=user, kind="sub").exclude(
        linked_token_hash="").values_list("linked_token_hash", flat=True))


def active_sub_skus(user, now=None):
    """SKUs of the Play subscriptions that entitle `user` right now (not
    revoked, not replaced by an upgrade/downgrade)."""
    from ..models import PlayPurchase
    now = now or timezone.now()
    gone = _replaced_hashes(user)
    return {pp.sku for pp in PlayPurchase.objects.filter(
        user=user, kind="sub", revoked=False, state__in=ENTITLED_STATES,
        expires_at__gt=now) if pp.token_hash not in gone}


# subscriptionState -> what the app shows (pay-e2e)
_STATUS = {"SUBSCRIPTION_STATE_ACTIVE": "active", "SUBSCRIPTION_STATE_CANCELED": "canceled",
           "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": "grace",
           "SUBSCRIPTION_STATE_ON_HOLD": "on_hold", "SUBSCRIPTION_STATE_PAUSED": "paused"}
HOLD_SHOWN_DAYS = 60       # Play keeps a sub on hold for up to 60 days (default 30)


def sub_status(user, now=None):
    """The account's current Play subscription for the app: status
    active|canceled|grace|on_hold|paused + what the "Manage in Google Play" /
    "Fix payment" deep link needs. None when there is nothing to show."""
    from ..models import PlayPurchase
    now = now or timezone.now()
    gone = _replaced_hashes(user)
    for pp in PlayPurchase.objects.filter(user=user, kind="sub", revoked=False,
                                          state__in=tuple(_STATUS)).order_by("-updated_at"):
        if pp.token_hash in gone:
            continue
        st = _STATUS[pp.state]
        if st in ("active", "canceled", "grace") and not (pp.expires_at and pp.expires_at > now):
            continue
        if st in ("on_hold", "paused") and pp.updated_at < now - timedelta(days=HOLD_SHOWN_DAYS):
            continue
        try:
            pkg = cfg()["package_name"]
        except Exception:
            pkg = getattr(settings, "PLAY_PACKAGE_NAME", "com.assisto.assisto")
        return {"status": st, "sku": pp.sku, "product_id": pp.product_id,
                "base_plan": pp.base_plan_id, "package": pkg,
                "auto_renew": bool(pp.auto_renewing),
                "expires_at": pp.expires_at.isoformat() if pp.expires_at else None}
    return None


# ----------------------------------------------------------------- packs
def sync_pack(token, product_id, user=None, now=None, c=None):
    """Verify + grant + consume one credit pack token (idempotent)."""
    from ..models import PlayPurchase
    now = now or timezone.now()
    c = c or cfg()
    sku = catalog.sku_for_play(product_id)
    if not sku.startswith("pack_"):
        raise PlayError("unknown_product", 400)
    js = get_product(product_id, token, c)
    owner = _owner_for(token, js.get("obfuscatedExternalAccountId", ""), user)
    ps = int(js.get("purchaseState", -1) if js.get("purchaseState") is not None else -1)
    th = token_hash(token)
    pp, _ = PlayPurchase.objects.get_or_create(
        token_hash=th, defaults={"user": owner, "purchase_token": token, "kind": "pack",
                                 "product_id": product_id, "sku": sku})
    pp.order_id = str(js.get("orderId") or pp.order_id)[:64]
    pp.state = {0: "PURCHASED", 1: "CANCELED", 2: "PENDING"}.get(ps, "UNKNOWN")
    pp.raw = {k: js.get(k) for k in ("purchaseState", "consumptionState", "orderId",
                                    "acknowledgementState", "purchaseType", "regionCode")}
    pp.save()
    if ps == 2:
        return {"ok": False, "state": "pending", "sku": sku}
    if ps != 0 or pp.revoked:
        return {"ok": False, "state": "canceled", "sku": sku}
    granted = 0
    amount = Decimal(catalog.price(sku, "play") or 0)
    if not pp.granted:
        granted = E.grant_pack(owner, channel="play", ref=ref_for(token), sku=sku,
                               amount_bdt=amount, now=now)
        pp.granted = True
        pp.price_bdt = amount
        pp.save(update_fields=["granted", "price_bdt", "updated_at"])
        if js.get("purchaseType") is None and pp.order_id:   # 0 = test purchase
            _charge_once(owner, pp.order_id, sku, amount, "packs")
        else:
            E.event(owner, "play.test_charge", "play", pp.order_id or ref_for(token), sku=sku)
    if not pp.consumed and int(js.get("consumptionState", 0) or 0) == 0:
        try:
            consume_product(product_id, token, c)
            pp.consumed = True
        except PlayError as e:
            log.warning("play: consume failed %s", e.reason)
    elif int(js.get("consumptionState", 0) or 0) == 1:
        pp.consumed = True
    pp.save(update_fields=["consumed", "updated_at"])
    return {"ok": True, "state": "granted", "sku": sku, "granted": granted,
            "credits": int(owner.ai_credits or 0), "user": owner}


# ----------------------------------------------------------------- refunds / voided
def revoke_token(token, reason, now=None, order_id=""):
    """Refund / revoke. `order_id` is the refunded order when Google names it
    (voidedPurchaseNotification.orderId): a subscription has one order id per
    renewal (GPA.x, GPA.x..0, GPA.x..1), so the refund reverses THAT order's
    revenue, not the latest one. Without it (REVOKED RTDN) the latest order
    is reversed. Each order's revenue is reversed at most once."""
    from ..models import PlayPurchase
    now = now or timezone.now()
    pp = PlayPurchase.objects.filter(token_hash=token_hash(token)).select_related("user").first()
    if pp is None:
        return None
    if not pp.revoked:
        pp.revoked = True
        pp.save(update_fields=["revoked", "updated_at"])
        if pp.kind == "sub":
            E.revoke_period("play", ref_for(token), reason, now)
        else:
            E.revoke_pack(pp.user, channel="play", ref=ref_for(token), reason=reason)
    # reverse the revenue of the refunded order (once)
    from ..models import PaymentEvent
    ref = str(order_id or pp.order_id or "")[:80]
    ch = PaymentEvent.objects.filter(kind="play.charge", ref=ref).first() if ref else None
    if ch and ch.user_id not in (None, pp.user_id):
        ch = None                                   # never another account's order
    if ch and not PaymentEvent.objects.filter(kind="play.refund", ref=ch.ref).exists():
        E.event(pp.user, "play.refund", "play", ch.ref, amount=-ch.amount_bdt,
                net=-ch.net_bdt, reason=reason)
        E.ledger("subs" if pp.kind == "sub" else "packs", -float(ch.net_bdt))
    return pp


# ----------------------------------------------------------------- RTDN auth
_certs = {"keys": None, "exp": 0.0}


def _google_keys():
    if _certs["keys"] and time.time() < _certs["exp"]:
        return _certs["keys"]
    st, js = _http("GET", CERTS_URI)
    if st != 200 or not js.get("keys"):
        raise PlayError("certs_unavailable", 503)
    _certs.update(keys={k["kid"]: k for k in js["keys"] if k.get("kid")},
                  exp=time.time() + 3600)
    return _certs["keys"]


def verify_oidc(jwt, audience, sa_email, now=None):
    """Verify a Pub/Sub push OIDC token. Raises PlayError('bad_auth')."""
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    now = now or time.time()
    try:
        h64, p64, s64 = jwt.split(".")
        head = json.loads(_b64url_dec(h64))
        claims = json.loads(_b64url_dec(p64))
        sig = _b64url_dec(s64)
    except Exception:
        raise PlayError("bad_auth", 401)
    if head.get("alg") != "RS256":
        raise PlayError("bad_auth", 401)
    jwk = _google_keys().get(head.get("kid"))
    if not jwk:
        raise PlayError("bad_auth", 401)
    pub = rsa.RSAPublicNumbers(int.from_bytes(_b64url_dec(jwk["e"]), "big"),
                               int.from_bytes(_b64url_dec(jwk["n"]), "big")).public_key()
    try:
        pub.verify(sig, (h64 + "." + p64).encode(), padding.PKCS1v15(), hashes.SHA256())
    except InvalidSignature:
        raise PlayError("bad_auth", 401)
    if claims.get("iss") not in GOOGLE_ISS or claims.get("aud") != audience:
        raise PlayError("bad_auth", 401)
    if float(claims.get("exp", 0)) < now - 60 or float(claims.get("iat", now)) > now + 300:
        raise PlayError("bad_auth", 401)
    if sa_email and (claims.get("email") != sa_email or not claims.get("email_verified")):
        raise PlayError("bad_auth", 401)
    return claims


def authenticate_push(auth_header, query_token, c=None):
    """Fail closed: at least one of (OIDC audience, shared token) must be set
    and every configured one must pass."""
    c = c or cfg()
    aud = (c.get("rtdn_audience") or "").strip()
    secret = (c.get("rtdn_token") or "").strip()
    if not aud and not secret:
        raise PlayError("rtdn_not_configured", 503)
    if secret and not hmac.compare_digest(str(query_token or ""), secret):
        raise PlayError("bad_auth", 401)
    if aud:
        if not str(auth_header or "").startswith("Bearer "):
            raise PlayError("bad_auth", 401)
        verify_oidc(auth_header[7:].strip(), aud, (c.get("rtdn_sa_email") or "").strip())
    return True


# ----------------------------------------------------------------- RTDN handling
def handle_rtdn(envelope, now=None):
    """Process one Pub/Sub push envelope. Returns a short outcome string.
    Replays (same messageId) are no-ops."""
    from django.db import IntegrityError, transaction
    from ..models import WebhookReceipt
    c = cfg()
    msg = (envelope or {}).get("message") or {}
    mid = str(msg.get("messageId") or msg.get("message_id") or "")[:128]
    if not mid:
        raise PlayError("bad_payload", 400)
    try:
        data = json.loads(base64.b64decode(msg.get("data") or "").decode("utf-8"))
    except Exception:
        raise PlayError("bad_payload", 400)
    if data.get("packageName") and data["packageName"] != c["package_name"]:
        raise PlayError("wrong_package", 400)
    try:
        with transaction.atomic():
            WebhookReceipt.objects.create(source="rtdn", message_id=mid)
    except IntegrityError:
        return "duplicate"
    try:
        out = _dispatch(data, now)
    except Exception:
        # let Pub/Sub redeliver: forget the receipt so the retry is processed
        WebhookReceipt.objects.filter(source="rtdn", message_id=mid).delete()
        raise
    E.event(None, "play.rtdn", "play", mid, outcome=out)
    return out


def _other_account(token):
    """The token is bound to another account than Google now reports. Retrying
    can never fix that, so ACK the Pub/Sub message (2xx) with no entitlement
    change, and leave an audit row for the owner."""
    log.warning("play: rtdn for a token bound to another account (%s)", ref_for(token))
    E.event(None, "play.rtdn_other_account", "play", ref_for(token))
    return "ignored:other_account"


def _dispatch(data, now):
    if "testNotification" in data:
        return "test"
    sn = data.get("subscriptionNotification")
    if sn:
        token = str(sn.get("purchaseToken") or "")
        nt = int(sn.get("notificationType") or 0)
        if not token:
            raise PlayError("bad_payload", 400)
        if nt == 12:                                  # REVOKED (refund)
            revoke_token(token, "play_revoked", now)
            return "revoked"
        try:
            r = sync_subscription(token, None, now)
        except PlayError as e:
            if e.reason in ("unknown_account", "not_found"):
                return "ignored:" + e.reason       # never bought through our app
            if e.reason == "other_account":
                return _other_account(token)
            raise
        return "sub:%s:%s" % (NOTIF.get(nt, nt), r["state"])
    on = data.get("oneTimeProductNotification")
    if on:
        token, sku = str(on.get("purchaseToken") or ""), str(on.get("sku") or "")
        if int(on.get("notificationType") or 0) == 2:      # CANCELED (pending abandoned)
            return "pack:canceled"
        try:
            sync_pack(token, sku, None, now)
        except PlayError as e:
            if e.reason in ("unknown_account", "not_found", "unknown_product"):
                return "ignored:" + e.reason
            if e.reason == "other_account":
                return _other_account(token)
            raise
        return "pack:purchased"
    vp = data.get("voidedPurchaseNotification")
    if vp:
        revoke_token(str(vp.get("purchaseToken") or ""), "play_voided", now,
                     order_id=str(vp.get("orderId") or ""))
        return "voided"
    return "ignored"


# ----------------------------------------------------------------- ack sweep
ACK_WINDOW = timedelta(days=3)    # Google refunds unacknowledged purchases after 3 days
ACK_BACKOFF_MIN = timedelta(minutes=15)
ACK_BACKOFF_MAX = timedelta(hours=6)
_NO_ACK_STATES = ("CANCELED", "PENDING", "SUBSCRIPTION_STATE_PENDING",
                  "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED", "SUBSCRIPTION_STATE_EXPIRED")


def ack_sweep(now=None, limit=200):
    """Retry acknowledge (subscriptions) / consume (credit packs: consuming
    acknowledges a consumable) for purchases younger than 3 days whose
    earlier attempt failed and that got no later RTDN / app verify. Goes
    through sync_subscription / sync_pack, which re-verify with Google first,
    so it is idempotent: nothing is granted or counted twice. Exponential
    backoff per purchase (15 min, 30 min, 1 h ... max 6 h) kept in raw.
    Never raises: one bad purchase never stops the payments sweep."""
    from django.db.models import Q
    from ..models import PlayPurchase
    now = now or timezone.now()
    out = {"tried": 0, "acked": 0, "failed": 0, "skipped": 0}
    if not configured():
        return out
    qs = (PlayPurchase.objects.filter(revoked=False, created_at__gte=now - ACK_WINDOW)
          .filter(Q(kind="sub", acknowledged=False) | Q(kind="pack", consumed=False))
          .exclude(state__in=_NO_ACK_STATES).select_related("user").order_by("created_at"))
    for pp in qs[:limit]:
        meta = dict((pp.raw or {}).get("ack_retry") or {})
        nxt = _ts(meta.get("next"))
        if nxt and nxt > now:
            out["skipped"] += 1
            continue
        n = int(meta.get("n", 0) or 0)
        out["tried"] += 1
        err = ""
        try:
            if pp.kind == "sub":
                sync_subscription(pp.purchase_token, pp.user, now)
            else:
                sync_pack(pp.purchase_token, pp.product_id, pp.user, now)
        except PlayError as e:
            err = e.reason
        except Exception as e:                       # never break the sweep
            err = type(e).__name__
        pp.refresh_from_db()
        if pp.acknowledged if pp.kind == "sub" else pp.consumed:
            out["acked"] += 1
            log.info("play: ack sweep %s ok (try %d)", ref_for(pp.purchase_token), n + 1)
            E.event(pp.user, "play.ack_sweep", "play", ref_for(pp.purchase_token),
                    result="ok", tries=n + 1)
            continue
        out["failed"] += 1
        delay = min(ACK_BACKOFF_MIN * (2 ** min(n, 10)), ACK_BACKOFF_MAX)
        raw = dict(pp.raw or {})
        raw["ack_retry"] = {"n": n + 1, "next": (now + delay).isoformat(), "err": err[:60]}
        pp.raw = raw
        pp.save(update_fields=["raw", "updated_at"])
        log.warning("play: ack sweep %s failed (%s), try %d, next in %s",
                    ref_for(pp.purchase_token), err or "not_acked", n + 1, delay)
    return out
