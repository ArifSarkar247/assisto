# Assisto CCTV — POS webhook (for POS partners)

Version 1 · 9 Nov 2026 · first partner: Asalify POS (the Asalify team builds
their side). Assisto **never calls** a partner server: the POS sends events to
Assisto, Assisto only receives.

## What it is for
A shop owner who uses Assisto CCTV links their POS. Assisto matches the POS's
sales, refunds and cash-drawer events with the shop's camera events and shows
the owner **review-only clips** ("cash drawer opened with no sale", "hand
movement near the cash after a sale"). It never accuses anyone and never
names staff. Send no staff or customer names — they are dropped if sent.

## 1. Getting a key (done by the shop owner, in the Assisto app)
CCTV → shop → **Sales match** → **Link a POS** → choose the POS → the app
shows once:
* `Key ID` — like `ak_123_9f3a1c2b4d` (not secret; names the shop)
* `Secret` — like `ask_...` (secret; shown ONCE; the owner gives it to you)
* Webhook URL — `https://lifeassisto.com/api/v1/shop/pos/webhook`

The owner can rotate the key (the old one keeps working for 24 hours) or
revoke it (stops at once).

## 2. Request
`POST https://lifeassisto.com/api/v1/shop/pos/webhook`

Headers:
| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `X-Assisto-Key-Id` | the Key ID |
| `X-Assisto-Timestamp` | Unix time in seconds (UTC) when you send |
| `X-Assisto-Signature` | `v1=<hex>` where hex = HMAC-SHA256(secret, `"v1:" + timestamp + ":" + raw_body`) |

Sign the **exact bytes** you send as the body. During a key rotation you may
send two signatures separated by a comma: `v1=<old>,v1=<new>`.

Body: one event, or `{"events": [ ... ]}` with up to 100 events (max 64 KB).

```json
{
  "event_id": "INV-2026-000123",
  "type": "sale",
  "amount": "1250.50",
  "currency": "BDT",
  "at": "2026-11-09T15:30:12+06:00",
  "payment_method": "cash",
  "register": "Till 1",
  "sale_ref": "INV-2026-000123",
  "items": 3
}
```

| Field | Required | Notes |
|---|---|---|
| `event_id` | yes | your unique id for THIS event, `[A-Za-z0-9_.:-]`, ≤64. Sending it again = duplicate (ignored) |
| `type` | yes | `sale`, `refund`, `void`, `discount`, `cash_drawer` (drawer opened; `no_sale` also accepted) |
| `amount` | no | Taka, up to 2 decimals, `"0"` for a drawer |
| `currency` | no | only `BDT` |
| `at` | no | ISO 8601 with offset (or Unix seconds). Default: now. Not older than 31 days, not >10 min in the future |
| `payment_method` | no | `cash`, `card`, `bkash`, `nagad`, `rocket`, `upay`, `bank`, `due`, `other` |
| `register` | no | till name, ≤24 letters/digits — **not a person's name** |
| `sale_ref` | no | your receipt / invoice number |
| `items` | no | number of items |

Anything else (cashier name, customer phone …) is dropped and never stored.

## 3. Responses
| Code | Body | Meaning |
|---|---|---|
| 200 | `{"ok": true, "accepted": 1, "duplicates": 0, "errors": []}` | stored (or a duplicate — safe to retry) |
| 207 | some `errors: [{"index": 2, "code": "bad_type"}]` | the good events were stored |
| 401 | `{"error": "bad_key" \| "no_signature" \| "bad_timestamp" \| "stale" \| "bad_signature"}` | fix and resend |
| 400 / 413 / 422 | `bad_json`, `too_big`, all events bad | fix the body |

Replay protection: the timestamp must be within **±5 minutes** of Assisto's
clock and every `event_id` is stored once per shop, so a captured request
can never add a second row. Retry on network errors with the SAME `event_id`
(and a fresh timestamp + signature).

## 4. Signing examples
Python:
```python
import hashlib, hmac, json, time, requests
body = json.dumps({"event_id": "INV-1", "type": "sale", "amount": "120.00"}).encode()
ts = str(int(time.time()))
sig = hmac.new(SECRET.encode(), b"v1:" + ts.encode() + b":" + body, hashlib.sha256).hexdigest()
requests.post(URL, data=body, headers={"Content-Type": "application/json",
    "X-Assisto-Key-Id": KEY_ID, "X-Assisto-Timestamp": ts, "X-Assisto-Signature": "v1=" + sig})
```
PHP (Laravel):
```php
$body = json_encode(['event_id' => 'INV-1', 'type' => 'sale', 'amount' => '120.00']);
$ts = (string) time();
$sig = hash_hmac('sha256', "v1:$ts:$body", $secret);
Http::withHeaders(['X-Assisto-Key-Id' => $keyId, 'X-Assisto-Timestamp' => $ts,
    'X-Assisto-Signature' => "v1=$sig"])->withBody($body, 'application/json')->post($url);
```

## 5. Without a partner integration
* **CSV import** (app → Sales match → Import CSV): columns `time,type,amount,id`
  (Bangla headers `সময়,ধরন,টাকা,রসিদ` work). Re-importing the same file adds nothing.
* Sales and khata entered in Assisto are matched automatically.

## 6. Privacy rules (for partners)
No face recognition, no identity, no staff names. The owner sees review-only
clips; Assisto staff never see video. The shop owner can revoke the key at any time.
