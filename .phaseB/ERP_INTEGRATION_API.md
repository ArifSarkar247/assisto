# ERP integration API (design only — not built)

How an Asalify or AXON ERP shop could plug its catalog and orders into the
Assisto Business AI Agent, so the AI answers from the ERP's live prices/stock
and orders taken in Messenger/Instagram/WhatsApp land in the ERP.

Status: **document only**. Nothing below exists in code yet. The agent today
reads `core.Product` / `ProductVariant` and writes `core.Order`; the ERP
bridge would fill and read those same tables, so the reply engine, number
post-check, approvals and courier flow stay unchanged.

## 1. Auth

* One **integration key per business**, created by the seller in Assisto
  (Agent setup → "Connect your ERP"), shown once, stored hashed (like the
  existing OTP/owner tokens). Scopes: `catalog:write`, `orders:read`,
  `orders:write`, `webhooks`.
* Requests: `Authorization: Bearer <key>` over HTTPS only; rate limit
  60 req/min per key; every call audit-logged (business, scope, ip).
* Webhooks **from Assisto to the ERP** are signed exactly like Meta's:
  `X-Assisto-Signature-256: sha256=<HMAC-SHA256(body, webhook_secret)>`, plus
  `X-Assisto-Event-Id` for idempotency. The ERP must answer 2xx within 10 s;
  we retry with backoff (1 m, 5 m, 30 m, 2 h, 6 h) then mark the endpoint
  failing and notify the seller.

## 2. Catalog sync (ERP → Assisto)

`PUT /api/v1/bizagent/erp/catalog` — full or partial upsert, max 500 items/call.

```json
{"items": [
  {"sku": "PJ-001", "name": "Cotton Panjabi", "price": "1200.00",
   "min_price": "1000.00", "stock": 18, "low_stock_at": 3,
   "description": "100% cotton", "category": "Panjabi",
   "variants": [{"vkey": "M/white", "size": "M", "colour": "white",
                 "price": "1200.00", "stock": 6}]}
 ],
 "mode": "partial"}
```

* Key = `sku` (maps to `Product.sku`, unique per business). `mode: full`
  hides (stock 0) products missing from the payload.
* Prices/stock remain the **only** source of truth for the AI; the post-check
  compares replies against exactly these numbers.
* `PATCH /api/v1/bizagent/erp/stock` `{ "sku": "PJ-001", "stock": 17 }` for
  fast stock-only pushes (e.g. after a shop-floor sale in the ERP).
* `cost_price` is optional and never shown to the AI or to staff.

## 3. Orders (Assisto → ERP)

Webhook `order.created` when a customer confirms in chat (same moment the
Assisto `Order` row is created and stock is reserved):

```json
{"event": "order.created", "event_id": "ord-123-created",
 "order": {"id": 123, "channel": "messenger", "status": "confirmed",
           "payment": "cod", "total": "2520.00", "delivery_charge": "120.00",
           "area": "outside",
           "customer": {"name": "…", "phone": "01XXXXXXXXX", "address": "…"},
           "items": [{"sku": "PJ-001", "variant": "M/white", "qty": 2,
                      "unit_price": "1200.00"}]}}
```

Further events: `order.status_changed` (packed / shipped / delivered /
returned / cancelled, with `courier`, `tracking`), `order.cancelled`.

ERP → Assisto:

* `POST /api/v1/bizagent/erp/orders/<id>/status {"status": "packed"}` — same
  state machine as the app (`business_ai.can_transition`).
* `POST /api/v1/bizagent/erp/orders/<id>/shipment {"courier": "pathao",
  "tracking": "…"}` when the ERP books the courier itself; Assisto then only
  tracks and messages the customer.
* `GET /api/v1/bizagent/erp/orders?since=<iso>` — pull, for ERPs that cannot
  receive webhooks.

## 4. Stock reservation rule

Assisto reserves stock when the chat order is confirmed. If the ERP is the
master, it must accept the `order.created` webhook and push the new stock
back (§2). On a conflict (ERP stock already 0) the ERP answers
`409 {"reason": "out_of_stock"}`; Assisto then cancels the order, restores
stock and sends the customer an honest apology through the approval queue.

## 5. What Asalify / AXON need to build

* A settings field for the Assisto key + webhook secret, the catalog push job
  (on product save + nightly full sync), and the order webhook receiver.
* Mapping of their product ids ↔ `sku`.

## 6. Open questions for the owner

* One ERP per business, or several shops under one key?
* Does the ERP or Assisto own courier booking for ERP shops?
* Pricing: is ERP sync part of Seller Pro, or a separate add-on?
