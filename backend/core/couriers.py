"""
P1 Business AI Agent — courier merchant API clients: Pathao, Steadfast, RedX.

Official merchant endpoints (base URLs are overridable per account, because
couriers move hosts; confirm them against the courier's merchant docs when the
account is opened — see owner_actions/BUSINESS_AGENT_SETUP.md):

  Pathao   (OAuth password grant)   sandbox https://courier-api-sandbox.pathao.com
                                    live    https://api-hermes.pathao.com
           POST /aladdin/api/v1/issue-token
           POST /aladdin/api/v1/orders                 (create)
           POST /aladdin/api/v1/merchant/price-plan    (price calc)
           GET  /aladdin/api/v1/orders/{consignment_id}/info  (tracking)
  Steadfast (Api-Key + Secret-Key)  https://portal.packzy.com/api/v1
           POST /create_order
           GET  /status_by_cid/{consignment_id}
           GET  /status_by_invoice/{invoice}
  RedX     (API-ACCESS-TOKEN: Bearer)  sandbox https://sandbox.redx.com.bd/v1.0.0-beta
                                       live    https://openapi.redx.com.bd/v1.0.0-beta
           POST /parcel
           GET  /parcel/info/{tracking_id}
           GET  /parcel/track/{tracking_id}

Every call goes through `transport(method, url, headers, body)` so tests use
recorded fake responses. Results are honest dicts:
  {"ok", "consignment_id", "tracking", "status", "fee", "error"}
No key → {"ok": False, "error": "no_key"} — never a fake booking.
"""
import json
import urllib.error
import urllib.request

from .logic import business_ai as bai

TIMEOUT_S = 20

PATHAO_SANDBOX = "https://courier-api-sandbox.pathao.com"
PATHAO_LIVE = "https://api-hermes.pathao.com"
STEADFAST_LIVE = "https://portal.packzy.com/api/v1"
REDX_SANDBOX = "https://sandbox.redx.com.bd/v1.0.0-beta"
REDX_LIVE = "https://openapi.redx.com.bd/v1.0.0-beta"

# key fields per courier (stored encrypted per seller, or owner-level)
FIELDS = {
    "pathao": ("client_id", "client_secret", "username", "password", "store_id",
               "sandbox", "base_url"),
    "steadfast": ("api_key", "secret_key", "base_url"),
    "redx": ("access_token", "pickup_store_id", "sandbox", "base_url"),
}
REQUIRED = {
    "pathao": ("client_id", "client_secret", "username", "password", "store_id"),
    "steadfast": ("api_key", "secret_key"),
    "redx": ("access_token",),
}


def http_transport(method, url, headers, body):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
            raw = r.read().decode() or "{}"
            try:
                return r.status, json.loads(raw)
            except ValueError:
                return r.status, {"raw": raw[:300]}
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}
    except Exception as e:  # noqa: BLE001
        return 0, {"message": type(e).__name__}


_transport = http_transport


def set_transport(fn):
    global _transport
    prev = _transport
    _transport = fn or http_transport
    return prev


def has_keys(courier, keys):
    keys = keys or {}
    return courier in REQUIRED and all(keys.get(k) for k in REQUIRED[courier])


def _truthy(v):
    return str(v).lower() in ("1", "true", "yes", "on")


def _res(ok, **kw):
    out = {"ok": ok, "consignment_id": "", "tracking": "", "status": "", "fee": None,
           "error": ""}
    out.update(kw)
    return out


def _err_text(js, status):
    if isinstance(js, dict):
        for k in ("message", "error", "errors"):
            v = js.get(k)
            if v:
                return (json.dumps(v, ensure_ascii=False) if not isinstance(v, str) else v)[:200]
    return "HTTP %s" % status


# ----------------------------------------------------------------- Pathao
def _pathao_base(keys):
    return (keys.get("base_url") or (PATHAO_SANDBOX if _truthy(keys.get("sandbox"))
                                     else PATHAO_LIVE)).rstrip("/")


def pathao_token(keys):
    st, js = _transport("POST", _pathao_base(keys) + "/aladdin/api/v1/issue-token",
                        {"Content-Type": "application/json", "Accept": "application/json"},
                        {"client_id": keys.get("client_id"),
                         "client_secret": keys.get("client_secret"),
                         "username": keys.get("username"), "password": keys.get("password"),
                         "grant_type": "password"})
    if st == 200 and js.get("access_token"):
        return js["access_token"], ""
    return "", _err_text(js, st)


def _pathao_headers(tok):
    return {"Content-Type": "application/json", "Accept": "application/json",
            "Authorization": "Bearer " + tok}


def pathao_create(keys, order):
    tok, err = pathao_token(keys)
    if not tok:
        return _res(False, error="auth: " + err)
    body = {"store_id": int(keys.get("store_id") or 0),
            "merchant_order_id": str(order["id"]),
            "recipient_name": order["name"][:100],
            "recipient_phone": order["phone"],
            "recipient_address": order["address"][:220],
            "delivery_type": 48, "item_type": 2,
            "item_quantity": int(order.get("qty") or 1),
            "item_weight": float(order.get("weight_kg") or 0.5),
            "amount_to_collect": int(round(float(order.get("cod") or 0))),
            "item_description": (order.get("description") or "")[:200],
            "special_instruction": (order.get("note") or "")[:200]}
    for k in ("recipient_city", "recipient_zone", "recipient_area"):
        if order.get(k):
            body[k] = int(order[k])
    st, js = _transport("POST", _pathao_base(keys) + "/aladdin/api/v1/orders",
                        _pathao_headers(tok), body)
    d = (js or {}).get("data") or {}
    if st in (200, 201) and d.get("consignment_id"):
        return _res(True, consignment_id=str(d["consignment_id"]),
                    tracking=str(d["consignment_id"]),
                    status=str(d.get("order_status") or "Pending"),
                    fee=d.get("delivery_fee"))
    return _res(False, error=_err_text(js, st))


def pathao_price(keys, order):
    tok, err = pathao_token(keys)
    if not tok:
        return _res(False, error="auth: " + err)
    body = {"store_id": int(keys.get("store_id") or 0), "item_type": 2, "delivery_type": 48,
            "item_weight": float(order.get("weight_kg") or 0.5),
            "recipient_city": int(order.get("recipient_city") or 0),
            "recipient_zone": int(order.get("recipient_zone") or 0)}
    st, js = _transport("POST", _pathao_base(keys) + "/aladdin/api/v1/merchant/price-plan",
                        _pathao_headers(tok), body)
    d = (js or {}).get("data") or {}
    if st == 200 and ("final_price" in d or "price" in d):
        return _res(True, fee=d.get("final_price", d.get("price")))
    return _res(False, error=_err_text(js, st))


def pathao_status(keys, consignment_id):
    tok, err = pathao_token(keys)
    if not tok:
        return _res(False, error="auth: " + err)
    st, js = _transport("GET", _pathao_base(keys) + "/aladdin/api/v1/orders/%s/info"
                        % consignment_id, _pathao_headers(tok), None)
    d = (js or {}).get("data") or {}
    if st == 200 and d:
        return _res(True, consignment_id=str(consignment_id), tracking=str(consignment_id),
                    status=str(d.get("order_status") or d.get("order_status_slug") or ""))
    return _res(False, error=_err_text(js, st))


# ----------------------------------------------------------------- Steadfast
def _sf_base(keys):
    return (keys.get("base_url") or STEADFAST_LIVE).rstrip("/")


def _sf_headers(keys):
    return {"Api-Key": keys.get("api_key", ""), "Secret-Key": keys.get("secret_key", ""),
            "Content-Type": "application/json"}


def steadfast_create(keys, order):
    body = {"invoice": "A%s" % order["id"], "recipient_name": order["name"][:100],
            "recipient_phone": order["phone"], "recipient_address": order["address"][:250],
            "cod_amount": float(order.get("cod") or 0),
            "note": (order.get("note") or "")[:200]}
    st, js = _transport("POST", _sf_base(keys) + "/create_order", _sf_headers(keys), body)
    c = (js or {}).get("consignment") or {}
    if st == 200 and int((js or {}).get("status") or 200) == 200 and c.get("consignment_id"):
        return _res(True, consignment_id=str(c["consignment_id"]),
                    tracking=str(c.get("tracking_code") or c["consignment_id"]),
                    status=str(c.get("status") or "in_review"))
    return _res(False, error=_err_text(js, st))


def steadfast_status(keys, consignment_id=None, invoice=None):
    path = ("/status_by_cid/%s" % consignment_id) if consignment_id \
        else ("/status_by_invoice/%s" % invoice)
    st, js = _transport("GET", _sf_base(keys) + path, _sf_headers(keys), None)
    if st == 200 and (js or {}).get("delivery_status"):
        return _res(True, consignment_id=str(consignment_id or ""),
                    status=str(js["delivery_status"]))
    return _res(False, error=_err_text(js, st))


# ----------------------------------------------------------------- RedX
def _rx_base(keys):
    return (keys.get("base_url") or (REDX_SANDBOX if _truthy(keys.get("sandbox"))
                                     else REDX_LIVE)).rstrip("/")


def _rx_headers(keys):
    return {"API-ACCESS-TOKEN": "Bearer " + keys.get("access_token", ""),
            "Content-Type": "application/json"}


def redx_create(keys, order):
    body = {"customer_name": order["name"][:100], "customer_phone": order["phone"],
            "delivery_area": order.get("area_name") or order.get("area") or "",
            "delivery_area_id": int(order.get("delivery_area_id") or 0),
            "customer_address": order["address"][:250],
            "merchant_invoice_id": "A%s" % order["id"],
            "cash_collection_amount": str(int(round(float(order.get("cod") or 0)))),
            "parcel_weight": int(float(order.get("weight_kg") or 0.5) * 1000),
            "instruction": (order.get("note") or "")[:200],
            "value": str(int(round(float(order.get("value") or order.get("cod") or 0))))}
    if keys.get("pickup_store_id"):
        body["pickup_store_id"] = int(keys["pickup_store_id"])
    st, js = _transport("POST", _rx_base(keys) + "/parcel", _rx_headers(keys), body)
    tid = (js or {}).get("tracking_id")
    if st in (200, 201) and tid:
        return _res(True, consignment_id=str(tid), tracking=str(tid), status="pickup-pending")
    return _res(False, error=_err_text(js, st))


def redx_status(keys, tracking_id):
    st, js = _transport("GET", _rx_base(keys) + "/parcel/info/%s" % tracking_id,
                        _rx_headers(keys), None)
    p = (js or {}).get("parcel") or {}
    if st == 200 and p:
        return _res(True, consignment_id=str(tracking_id), tracking=str(tracking_id),
                    status=str(p.get("status") or ""))
    return _res(False, error=_err_text(js, st))


# ----------------------------------------------------------------- dispatch
def create(courier, keys, order):
    if courier not in bai.COURIERS:
        return _res(False, error="unknown_courier")
    if not has_keys(courier, keys):
        return _res(False, error="no_key")
    fn = {"pathao": pathao_create, "steadfast": steadfast_create, "redx": redx_create}[courier]
    return fn(keys, order)


def status(courier, keys, consignment_id):
    if not has_keys(courier, keys):
        return _res(False, error="no_key")
    if courier == "pathao":
        return pathao_status(keys, consignment_id)
    if courier == "steadfast":
        return steadfast_status(keys, consignment_id=consignment_id)
    if courier == "redx":
        return redx_status(keys, consignment_id)
    return _res(False, error="unknown_courier")


_DELIVERED = ("delivered", "delivered_approval_pending", "partial_delivered", "partial_delivered_approval_pending")
_RETURNED = ("returned", "return", "cancelled", "cancelled_approval_pending", "pickup_cancelled",
             "returned-to-merchant", "return-in-transit")


def map_status(raw):
    """Courier status text → our order status (business_ai state machine):
    'delivered' | 'returned' | 'shipped' (anything in transit)."""
    s = (raw or "").strip().lower().replace(" ", "_")
    if s in _DELIVERED or s.startswith("delivered"):
        return bai.STATUS_DELIVERED
    if s in _RETURNED or "return" in s or "cancel" in s:
        return bai.STATUS_RETURNED
    return bai.STATUS_SHIPPED
