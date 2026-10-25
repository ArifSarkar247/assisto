"""EPS (Easy Payment System, eps.com.bd) hosted checkout.

Contract (sources, checked 22 Oct 2026):
  * EPS official integration samples, github.com/EPS-PG — EPS_PHP
    ("Official PHP SDK", file "Sandbox&ProductionPhP.php"), EPS_Laravel
    ("Official Laravel package", app/EPS/EPSPayment.php), EPS_Woocommerce
    (includes/Gateway/Processor.php). Support: integration@eps.com.bd.
  * IPN: https://eps.com.bd/ipn (payload fields, AES-256-CBC "IV:cipher").
  * The response shapes below were confirmed against the PUBLIC EPS sandbox
    (sandboxpgapi.eps.com.bd) with the demo merchant EPS publishes in its
    official PHP sample: GetToken -> {token, expireDate, errorMessage,
    errorCode}; InitializeEPS -> {TransactionId, RedirectURL, ErrorMessage,
    ErrorCode, FinancialEntityList}; CheckMerchantTransactionStatus ->
    {MerchantTransactionId, EPSTransactionId, Status, TotalAmount ("199.00"),
    StoreAmount, FinancialEntity, ErrorCode, ErrorMessage, ...}; a wrong
    x-hash -> ErrorCode 400 "Invalid hash provided.". Recorded (scrubbed)
    copies live in core/tests_pay1.py.

API
  base        sandbox https://sandboxpgapi.eps.com.bd   live https://pgapi.eps.com.bd
  x-hash      Base64( HMAC-SHA512( key = UTF-8(hash_key), msg = UTF-8(value) ) )
              value = userName (GetToken) | merchantTransactionId (Initialize,
              Status)
  POST /v1/Auth/GetToken                       {userName, password}
  POST /v1/EPSEngine/InitializeEPS             Bearer token, body below
  GET  /v1/EPSEngine/CheckMerchantTransactionStatus?merchantTransactionId=..
  browser return (success/fail/cancel URL) carries ?Status=..&MerchantTransactionId=..
  (&EPSTransactionId=..) — used ONLY to find the order; every payment is
  verified with CheckMerchantTransactionStatus before anything is granted.

ASSUMPTIONS (EPS does not publish these; confirm with EPS before going live —
listed in owner_actions/PAYMENTS_SETUP.md):
  A1  IPN AES key: the 32 bytes of Base64-decoded `ipn_key` when it decodes to
      32 bytes, else SHA-256(UTF-8 ipn_key). The IPN is a TRIGGER only: even
      a perfectly forged IPN grants nothing without a matching Success from
      the status API, so a wrong guess here can only delay, never mis-grant.
  A2  Status strings: "Success" = paid; "Failed"/"Failure" = failed;
      "Cancel"/"Canceled"/"Cancelled" = cancelled; anything else = pending.
      The sandbox answers "Cancel" for a session nobody has paid yet, so a
      cancel/fail is never final for us: a later Success still completes it.
"""
import base64
import hashlib
import hmac
import json
import logging
import threading
import time
from datetime import datetime, timedelta, timezone as dt_tz
from decimal import Decimal, InvalidOperation
from urllib.parse import urlparse

from .gateway import GatewayError, PaymentGateway, VerifyResult, register

log = logging.getLogger(__name__)

BASE = {"sandbox": "https://sandboxpgapi.eps.com.bd", "live": "https://pgapi.eps.com.bd"}
REDIRECT_HOSTS = ("eps.com.bd",)
HTTP_TIMEOUT_S = 25
IPN_MAX_AGE_S = 30 * 60
DHAKA = dt_tz(timedelta(hours=6), "Asia/Dhaka")   # Bangladesh: UTC+6, no DST

_tok_lock = threading.Lock()
_tok_cache = {}


def x_hash(value, hash_key):
    return base64.b64encode(hmac.new(str(hash_key).encode("utf-8"),
                                     str(value).encode("utf-8"),
                                     hashlib.sha512).digest()).decode("ascii")


def _http(method, url, body=None, headers=None):
    """(status, json dict). Single seam for tests. Raises on network error."""
    import requests
    if method == "POST":
        r = requests.post(url, data=json.dumps(body or {}), headers=headers or {},
                          timeout=HTTP_TIMEOUT_S)
    else:
        r = requests.get(url, headers=headers or {}, timeout=HTTP_TIMEOUT_S)
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, {}


def _cfg():
    from .. import integrations
    return integrations.get("eps") or {}


def _mode(c):
    return "live" if str(c.get("mode", "sandbox")).strip().lower() == "live" else "sandbox"


def reset_cache():
    with _tok_lock:
        _tok_cache.clear()


def drop_token(c):
    """Forget the cached auth token for this merchant (EPS revoked it early)."""
    with _tok_lock:
        _tok_cache.pop((c.get("username", ""), _mode(c)), None)


def _token_rejected(st, js):
    """EPS refused our Bearer token: HTTP 401, or an error code / message
    about the token (EPS publishes no code list; its messages say 'token')."""
    js = js if isinstance(js, dict) else {}
    if st == 401 or str(js.get("ErrorCode") or "").strip() == "401":
        return True
    msg = str(js.get("ErrorMessage") or js.get("errorMessage") or "").lower()
    return "token" in msg and any(w in msg for w in ("invalid", "expired", "unauthor"))


def _token(c, force=False):
    key = (c.get("username", ""), _mode(c))
    with _tok_lock:
        hit = _tok_cache.get(key)
        if hit and not force and hit[1] > time.time() + 60:
            return hit[0]
    st, js = _http("POST", BASE[_mode(c)] + "/v1/Auth/GetToken",
                   {"userName": c.get("username", ""), "password": c.get("password", "")},
                   {"Content-Type": "application/json",
                    "x-hash": x_hash(c.get("username", ""), c.get("hash_key", ""))})
    tok = (js or {}).get("token")
    if st != 200 or not tok:
        raise GatewayError("eps_auth", str((js or {}).get("errorMessage") or st)[:120])
    exp = time.time() + 50 * 60
    raw = (js or {}).get("expireDate")
    if raw:
        try:
            d = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
            if d.tzinfo is None:
                d = d.replace(tzinfo=dt_tz.utc)
            exp = min(exp, d.timestamp())
        except ValueError:
            pass
    with _tok_lock:
        _tok_cache[key] = (tok, exp)
    return tok


def ipn_fresh(d, now=None):
    """IPN timestamp within +-IPN_MAX_AGE_S of now. EPS does not document the
    time zone of an offset-less timestamp: it may be UTC or Bangladesh local
    time (Asia/Dhaka, UTC+6, no DST). A naive value is accepted if it is fresh
    read EITHER way — the two readings are 6 h apart, so the window is still
    +-30 min around one of them (the IPN is only a trigger; every payment is
    verified with the status API before anything is granted)."""
    now = time.time() if now is None else now
    if d.tzinfo is not None:
        cands = [d]
    else:
        cands = [d.replace(tzinfo=dt_tz.utc), d.replace(tzinfo=DHAKA)]
    return any(abs(now - c.timestamp()) <= IPN_MAX_AGE_S for c in cands)


def map_status(s):
    s = str(s or "").strip().lower()
    if s in ("success", "successful", "completed", "paid"):
        return "paid"
    if s in ("failed", "failure", "fail"):
        return "failed"
    if s in ("cancel", "canceled", "cancelled"):
        return "cancelled"
    return "pending"


def _amount(v):
    try:
        return Decimal(str(v)).quantize(Decimal("0.01"))
    except (InvalidOperation, TypeError, ValueError):
        return Decimal("-1")


def _ipn_key_bytes(k):
    try:
        b = base64.b64decode(k, validate=True)
        if len(b) == 32:
            return b
    except Exception:
        pass
    return hashlib.sha256(str(k).encode("utf-8")).digest()


def decrypt_ipn(data, ipn_key):
    """'IV:cipher' (both Base64) -> dict. AES-256-CBC, PKCS7 (assumption A1)."""
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    iv_b64, _, ct_b64 = str(data or "").partition(":")
    iv, ct = base64.b64decode(iv_b64), base64.b64decode(ct_b64)
    if len(iv) != 16 or not ct:
        raise ValueError("bad envelope")
    dec = Cipher(algorithms.AES(_ipn_key_bytes(ipn_key)), modes.CBC(iv)).decryptor()
    padded = dec.update(ct) + dec.finalize()
    unp = padding.PKCS7(128).unpadder()
    return json.loads((unp.update(padded) + unp.finalize()).decode("utf-8"))


def encrypt_ipn(payload, ipn_key, iv=None):
    """Test helper mirroring decrypt_ipn (same assumption A1)."""
    import os
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    iv = iv or os.urandom(16)
    p = padding.PKCS7(128).padder()
    raw = p.update(json.dumps(payload).encode()) + p.finalize()
    enc = Cipher(algorithms.AES(_ipn_key_bytes(ipn_key)), modes.CBC(iv)).encryptor()
    ct = enc.update(raw) + enc.finalize()
    return base64.b64encode(iv).decode() + ":" + base64.b64encode(ct).decode()


@register
class EpsGateway(PaymentGateway):
    slug = "eps"
    name = "EPS"
    integration = "eps"

    def __init__(self):
        self.c = _cfg()

    def configured(self):
        c = self.c
        return all(str(c.get(k, "")).strip() for k in
                   ("merchant_id", "store_id", "username", "password", "hash_key"))

    def _auth_headers(self, value, force=False):
        return {"Content-Type": "application/json",
                "x-hash": x_hash(value, self.c.get("hash_key", "")),
                "Authorization": "Bearer " + _token(self.c, force=force)}

    def _call(self, method, url, body, value):
        """Authorised EPS call. If EPS rejects the cached token (revoked before
        its expiry), drop it and retry ONCE with a fresh one."""
        st, js = _http(method, url, body, self._auth_headers(value))
        if _token_rejected(st, js):
            log.warning("eps: token rejected (%s), refreshing once", st)
            drop_token(self.c)
            st, js = _http(method, url, body, self._auth_headers(value, force=True))
        return st, js

    def create_session(self, order, customer, urls):
        if not self.configured():
            raise GatewayError("not_configured")
        tx = order.merchant_tx_id
        body = {
            "merchantId": self.c["merchant_id"], "storeId": self.c["store_id"],
            "CustomerOrderId": "AS%s" % order.pk, "merchantTransactionId": tx,
            "transactionTypeId": 2 if order.source == "app" else 1,
            "financialEntityId": 0, "transitionStatusId": 0,
            "totalAmount": float(order.amount_bdt), "ipAddress": customer.get("ip") or "0.0.0.0",
            "version": "1",
            "successUrl": urls["success"], "failUrl": urls["fail"], "cancelUrl": urls["cancel"],
            "customerName": customer.get("name") or "Assisto user",
            "customerEmail": customer.get("email") or "noreply@lifeassisto.com",
            "CustomerAddress": "Dhaka", "CustomerAddress2": "", "CustomerCity": "Dhaka",
            "CustomerState": "Dhaka", "CustomerPostcode": "1000", "CustomerCountry": "BD",
            "CustomerPhone": customer.get("phone") or "",
            "ShipmentName": "", "ShipmentAddress": "", "ShipmentAddress2": "",
            "ShipmentCity": "", "ShipmentState": "", "ShipmentPostcode": "",
            "ShipmentCountry": "", "ValueA": order.sku, "ValueB": str(order.pk),
            "ValueC": "", "ValueD": "", "ShippingMethod": "NO", "NoOfItem": "1",
            "ProductName": customer.get("product") or order.sku,
            "ProductProfile": "general", "ProductCategory": order.kind,
            "ProductList": [],
        }
        try:
            st, js = self._call("POST", BASE[_mode(self.c)] + "/v1/EPSEngine/InitializeEPS",
                                body, tx)
        except GatewayError:
            raise
        except Exception as e:  # network
            raise GatewayError("network", type(e).__name__)
        js = js or {}
        url = js.get("RedirectURL") or ""
        if st != 200 or not url or js.get("ErrorCode") or (js.get("ErrorMessage") or ""):
            raise GatewayError("init_failed", str(js.get("ErrorMessage") or st)[:120])
        if not self.redirect_allowed(url):
            raise GatewayError("bad_redirect", urlparse(url).netloc[:60])
        return {"redirect_url": url, "session_id": str(js.get("TransactionId") or "")[:64]}

    def verify(self, order):
        if not self.configured():
            raise GatewayError("not_configured")
        tx = order.merchant_tx_id
        try:
            st, js = self._call("GET", BASE[_mode(self.c)] +
                                "/v1/EPSEngine/CheckMerchantTransactionStatus"
                                "?merchantTransactionId=" + tx, None, tx)
        except GatewayError:
            raise
        except Exception as e:
            raise GatewayError("network", type(e).__name__)
        js = js or {}
        if st != 200 or js.get("ErrorCode"):
            raise GatewayError("verify_failed", str(js.get("ErrorMessage") or st)[:120])
        return VerifyResult(
            status=map_status(js.get("Status")),
            merchant_tx_id=str(js.get("MerchantTransactionId") or ""),
            provider_tx_id=str(js.get("EPSTransactionId") or "")[:64],
            amount=_amount(js.get("TotalAmount")), currency="BDT",
            method=str(js.get("FinancialEntity") or "")[:40],
            raw={k: js.get(k) for k in ("MerchantTransactionId", "EPSTransactionId",
                                        "Status", "TotalAmount", "StoreAmount",
                                        "FinancialEntity", "TransactionDate")})

    def tx_from_return(self, params):
        for k in ("MerchantTransactionId", "merchantTransactionId", "merchant_transaction_id"):
            v = str(params.get(k) or "").strip()
            if v:
                return v[:32]
        return ""

    def tx_from_ipn(self, body, headers):
        try:
            js = json.loads(body.decode("utf-8") if isinstance(body, bytes) else body or "{}")
        except (ValueError, UnicodeDecodeError):
            raise GatewayError("bad_payload")
        if not isinstance(js, dict):
            raise GatewayError("bad_payload")
        key = str(self.c.get("ipn_key", "") or "").strip()
        if "Data" in js:
            if not key:
                raise GatewayError("ipn_key_missing")
            try:
                js = decrypt_ipn(js["Data"], key)
            except Exception:
                raise GatewayError("bad_signature")
            if not isinstance(js, dict):
                raise GatewayError("bad_payload")
        elif key:
            # an IPN key is set: unencrypted notifications are refused
            raise GatewayError("bad_signature")
        ts = js.get("timestamp")
        if ts:
            try:
                d = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            except ValueError:
                raise GatewayError("bad_payload")
            if not ipn_fresh(d):
                raise GatewayError("stale")
        tx = str(js.get("merchant_transaction_id") or js.get("MerchantTransactionId")
                 or "").strip()
        if not tx:
            raise GatewayError("bad_payload")
        return tx[:32], str(js.get("transaction_id") or js.get("EPSTransactionId") or "")[:64]

    def redirect_allowed(self, url):
        try:
            u = urlparse(url)
        except Exception:
            return False
        host = (u.hostname or "").lower()
        return u.scheme == "https" and any(host == h or host.endswith("." + h)
                                           for h in REDIRECT_HOSTS)

    def test(self):
        """Owner 'Test' button: a real GetToken against the chosen mode."""
        if not self.configured():
            return False, "merchant_id, store_id, username, password, hash_key দরকার / required"
        try:
            _token(self.c, force=True)
        except GatewayError as e:
            return False, "EPS %s: %s" % (e.reason, e.detail)
        except Exception as e:
            return False, "EPS network: %s" % type(e).__name__
        return True, "✓ EPS (%s) টোকেন পাওয়া গেছে / token OK" % _mode(self.c)
