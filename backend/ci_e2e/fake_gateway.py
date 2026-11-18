"""plans-credits (board row 7): a CI-ONLY fake hosted payment gateway.

Installed by fakes.install() — i.e. ONLY under settings_e2eproof inside
GitHub Actions on the throw-away CI database (ci_e2e.apps refuses anything
else). It replaces nothing in the real code: it is one more
core.payments.gateway.PaymentGateway, so the REAL checkout -> order ->
server-to-server verify -> grant path (core/payments/service.py: amount /
currency / tx checks, idempotency, ledger, plan period, credit lot) runs end
to end. No money moves anywhere: there is no network call at all.

  * create_session  -> https://ci-fake-pay.invalid/pay?tx=<merchant tx>
                       (the app "opens" it; the e2e flow's launcher hook
                       answers it instead of a browser)
  * OFF until a flow asks (POST /api/v1/ci-e2e/pay {op: "on"}), so no other
    e2e flow ever sees a live payment channel; {op: "off"} at the end
  * POST /api/v1/ci-e2e/pay {tx, result: paid|failed|cancelled}
                    -> what the fake gateway will report for that order
  * verify          -> that result, for the order's OWN amount (or a wrong
                       amount when result == "paid_wrong_amount", to prove
                       the server refuses it)
"""
import json
import threading
from decimal import Decimal

from django.conf import settings

from core.payments import gateway as G

from . import fakes

HOST = "https://ci-fake-pay.invalid/"
RESULTS = ("paid", "failed", "cancelled", "paid_wrong_amount")
_LOCK = threading.Lock()


def _path():
    return str(settings.E2E_OUTBOX) + ".pay.json"


def _load():
    try:
        with open(_path(), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def set_on(on):
    set_result("_on", bool(on))


def set_result(tx, result):
    with _LOCK:
        d = _load()
        d[str(tx)] = result
        with open(_path(), "w", encoding="utf-8") as fh:
            json.dump(d, fh)
    fakes.record("pay_result", tx=str(tx), result=result)


class CiFakeGateway(G.PaymentGateway):
    slug = "ci_fake"
    name = "CI fake gateway (no money)"
    integration = ""

    def configured(self):
        return bool(_load().get("_on"))

    def create_session(self, order, customer, urls):
        tx = order.merchant_tx_id
        fakes.record("pay_session", tx=tx, sku=order.sku, amount=str(order.amount_bdt),
                     user_id=order.user_id)
        return {"redirect_url": HOST + "pay?tx=" + tx, "session_id": "ci-" + tx}

    def verify(self, order):
        tx = order.merchant_tx_id
        res = _load().get(tx, "pending")
        amount = order.amount_bdt.quantize(Decimal("0.01"))
        if res == "paid_wrong_amount":
            res, amount = "paid", amount - Decimal("1.00")
        return G.VerifyResult(
            status=res, merchant_tx_id=tx,
            provider_tx_id=("CIFAKE-" + tx) if res == "paid" else "",
            amount=amount, currency="BDT", method="ci_fake", raw={"ci_fake": res})

    def tx_from_return(self, params):
        return str(params.get("tx") or "")

    def tx_from_ipn(self, body, headers):
        raise G.GatewayError("ipn_not_used_in_ci")

    def redirect_allowed(self, url):
        return str(url).startswith(HOST)


def install():
    G.register(CiFakeGateway)
