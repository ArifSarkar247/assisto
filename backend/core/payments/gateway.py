"""Provider-agnostic hosted payment gateway interface.

The app and the website only ever talk to OUR endpoints
(/api/v1/payments/checkout, /payments/orders/<id>, /pay/return). Which
gateway sits behind them is decided here, so another gateway (SSLCommerz,
bKash PGW, ...) can be added later as one more PaymentGateway subclass with
no app change.

A gateway MUST:
  * create a hosted-checkout session for an order whose amount the SERVER set
  * verify a payment SERVER-TO-SERVER (never trust a redirect or an IPN body)
    and return a VerifyResult the service checks against the order
  * tell which of our orders a browser return / IPN refers to
"""
from dataclasses import dataclass, field
from decimal import Decimal


class GatewayError(Exception):
    def __init__(self, reason, detail=""):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


@dataclass
class VerifyResult:
    status: str                 # paid | failed | cancelled | pending | unknown
    merchant_tx_id: str = ""
    provider_tx_id: str = ""
    amount: Decimal = Decimal("0")
    currency: str = "BDT"
    method: str = ""
    raw: dict = field(default_factory=dict)


class PaymentGateway:
    slug = ""
    name = ""
    integration = ""          # core.integrations slug that holds the keys

    def configured(self):
        raise NotImplementedError

    def create_session(self, order, customer, urls):
        """-> {"redirect_url": str, "session_id": str}. Raises GatewayError."""
        raise NotImplementedError

    def verify(self, order):
        """-> VerifyResult from the gateway's own status API. Raises GatewayError."""
        raise NotImplementedError

    def tx_from_return(self, params):
        """Our merchant_tx_id from browser-return query params ('' if none).
        Only used to FIND the order; the payment itself is verified."""
        raise NotImplementedError

    def tx_from_ipn(self, body, headers):
        """Our merchant_tx_id from an IPN/webhook, or raise GatewayError when
        the notification fails the gateway's own authenticity check."""
        raise NotImplementedError

    def redirect_allowed(self, url):
        """Only redirect the browser to the gateway's own hosts."""
        raise NotImplementedError


_REGISTRY = {}


def register(cls):
    _REGISTRY[cls.slug] = cls
    return cls


def get(slug=None):
    """The gateway by slug, or the first configured one. None when none is."""
    from . import eps  # noqa: F401  (registers itself)
    if slug:
        cls = _REGISTRY.get(slug)
        return cls() if cls else None
    for cls in _REGISTRY.values():
        g = cls()
        if g.configured():
            return g
    return None


def default_slug():
    from . import eps  # noqa: F401
    return next(iter(_REGISTRY), "")
