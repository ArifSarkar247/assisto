"""pay1 — payments: Google Play Billing + a hosted payment gateway (EPS),
one entitlement service, owner switches, per-channel P&L.

  catalog.py      SKUs and server-authoritative prices per channel
  entitlement.py  THE entitlement service (plan + plan_until + credits)
  gateway.py      provider-agnostic PaymentGateway interface + registry
  eps.py          EPS (Easy Payment System) implementation
  play.py         Google Play Developer API + RTDN (Pub/Sub push) handling
  service.py      orchestration used by the API views, website and sweep
"""
