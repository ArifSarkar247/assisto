# Business v2 — AI Sales Assistant: integration spec

Pure logic lives in `backend/core/logic/business_ai.py` (Django-free) + tests in
`business_ai_tests_snippets.py` (49 asserts, `run_all()`). This doc tells the
Django integrator how to wire it. **Do not duplicate** `business.py` — extend it.

Verify logic: `cd backend && python3 -c "import core.logic.business_ai_tests_snippets as t; t.run_all()"`

---

## (a) Django models to add / extend

Extend the existing `Order` (models.py:712) — do NOT create a parallel one:

- `Order.STATUS`: add `("returned","returned")` (code uses `new→confirmed→packed→shipped→delivered/returned/cancelled`).
- `Order.payment` CharField default `"cod"` — feeds `cod_amount()`.
- `Order.courier_live` BooleanField default False — set from `advance_order()` event (`False` = mock booking, no courier key yet).

New models:

| Model | Key fields | Notes |
|---|---|---|
| `ChatThread` | user FK, customer_phone, channel (`whatsapp_cloud`/`messenger`), `last_inbound_at` (dt), `owner_takeover` bool, `lang` | `last_inbound_at` → epoch for `within_service_window()`. |
| `Message` | thread FK, direction (in/out), text, `is_ai` bool, confidence float, `needs_human` bool, `handoff_reason`, created_at | `is_ai=True` never claims humanity (disclosure helper). |
| `CourierShipment` | order FK, courier (`pathao`/`steadfast`/`redx`), tracking, `live` bool, cod_amount | filled by `book_courier_mock()`. |
| `OwnerPolicy` | user FK (or BusinessProfile FK), delivery_inside, delivery_outside, free_delivery_over, returns, hours, payment_note | maps to `build_context(delivery=…, policies=…)`. |
| `BargainRule` | product FK, min_price (already on Product? add if missing), discount_steps JSON (`[pct|amount,…]`), free_delivery_over, bundle_min_qty | **min_price is the enforced floor**; feeds `negotiate()`. Product currently has NO min_price — ADD `Product.min_price` DecimalField. |
| `OwnerWallet` | user FK, provider (`bkash`/`nagad`), merchant_number, merchant_name | `merchant_qr_descriptor()`. We store a POINTER only — never a balance. |

Pass Django rows into the pure fns as plain dicts (`{"name","price","stock","min_price",…}`), consume the returned dicts. No business logic in views.

---

## (b) Endpoints (under `api/v1/business/…`) → pure fn → gating

Gating legend: **FREE** (bookkeeping/selling), **PAID** (Business AI plan), **🔑** (needs a live provider key; otherwise mock/degraded).

| Method + path | Pure fn | Plan | Key-gated live |
|---|---|---|---|
| POST `/ai/reply` | `draft_reply(text, build_context(...), reply_provider, ai_key, owner_takeover)` | PAID | 🔑 LLM (else deterministic mock) |
| POST `/ai/bargain` | `negotiate(offer, product, rules, lang)` | PAID | no key — **pure code, never AI** |
| POST `/ai/disclose` | `assistant_disclosure(lang)` | PAID | no |
| POST `/orders/{id}/advance` | `advance_order(order, target, courier, courier_keys, lang)` | FREE (status) | 🔑 courier keys for real `shipped` booking |
| GET `/orders/{id}/parcel` | `parcel_status(order, lang)` | FREE | no (reads stored tracking) |
| GET `/ai/morning-summary` | `morning_summary(msgs, orders, needs_you, lang)` | PAID | no |
| POST `/outbound/plan` | `outbound_message_plan(channel, last_inbound_ts, now, template)` | PAID | no (policy only) |
| POST `/webhook/send` (internal) | `assemble_webhook_send(...)` | PAID | 🔑 Meta token to actually POST |
| POST `/webhook/incoming` (Meta callback) | existing `business.py` webhook → `draft_reply` | PAID | 🔑 Meta |
| POST `/ai/voice-entry` | `voice_entry_parse(text, lang)` | PAID | 🔑 transcription (audio→text) |
| POST `/ai/paper-khata` | `paper_khata_parse(mock_rows, lang)` | PAID | 🔑 OCR/vision |
| POST `/ai/match-payment` | `match_payment_to_due(notif, open_dues, lang)` | PAID | no (reuses money_parse) |
| GET `/ai/insights` | `insights(records, lang)` | PAID | no — **rules only** |
| GET `/reports/bank-loan` | `bank_loan_report_data(sales_rows, lang)` | PAID | no — **data only, NO lending/scoring** |
| GET `/payments/qr` | `merchant_qr_descriptor(owner_wallet, lang)` | FREE | no — owner's own merchant |
| POST `/payments/link` | `payment_link_builder(order, partner_key, lang)` | FREE/PAID | 🔑 licensed payment partner |

Hard refusals baked in (return 4xx from the view): `guard_channel()` raises
`PersonalWhatsAppBanned` for personal WhatsApp / WA Business app; `negotiate()`
never returns a price below `min_price`; `advance_order(...,'shipped')` raises
without a valid courier.

---

## (c) Arb — `biz_ai_arb.json` (every user-facing string, bn+en)

Written alongside this doc: `.phaseB/biz_ai_arb.json`. Keys cover assistant
disclosures, defer-to-owner, parcel status (all 7 states), handoff (angry/
refund/big-order/low-confidence), morning summary, payment labels, extras
review prompts. Both `bn` and `en` filled for every key. The pure module
currently inlines these via `pick()`; the arb is the canonical copy for the
Flutter client + any future externalisation.

---

## (d) Where a REAL key/provider is required to go live (all MOCKED now)

1. **LLM** — `draft_reply(reply_provider=<real>, ai_key=<key>)`. No key → deterministic `default_mock_provider`. Provider contract: `prompt dict → {text, confidence}`, MUST NOT invent price/stock.
2. **Meta WhatsApp Business Cloud API** (`graph.facebook.com/.../messages`) + **Messenger Platform** — access token to actually POST (`assemble_webhook_send` returns `needs_key=True`). **Official APIs ONLY — personal WhatsApp / WA Business app automation is refused in code.**
3. **Courier APIs** — Pathao / Steadfast / RedX. `book_courier_mock()` returns a `*-MOCK-*` tracking + `live=False` until `courier_keys[courier]` exists.
4. **Transcription** — audio→text for `voice_entry_parse` (`transcription_mock=True`).
5. **OCR / vision** — paper-khata photo→rows for `paper_khata_parse` (`ocr_mock=True`).
6. **Licensed payment partner** — `payment_link_builder(partner_key=…)`. No key → `MOCK-PAY-LINK://`, `live=False`. **We NEVER hold funds / never a wallet** (`holds_funds=False`, `custodian="licensed_partner"`). Merchant QR points at the owner's OWN bKash/Nagad merchant.

No lending, no credit scoring anywhere (`bank_loan_report_data` is sales history only).
