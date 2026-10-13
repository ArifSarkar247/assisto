# Business mode INSIDE Asalify — design-only plan (⛔ not built on this server)

**Why design-only:** the hard rule is to never modify the live Asalify platform
from the Assisto session. Assisto already has a **standalone** business mode
(feature 33: catalog, orders, honest catalog-only replies, WhatsApp webhook —
see `core/business.py`). Embedding it *inside* Asalify must be done from the
Asalify session, behind a flag, on ONE test tenant first.

## Step-by-step (do this in the Asalify session, not here)
1. **Feature flag** `business_ai_assistant` (per-tenant, default OFF). Enable for
   ONE test tenant only. Nothing changes for the other 11 tenants.
2. **Data mapping:** reuse Asalify's existing product/stock/price + order tables
   as the source of truth (never duplicate; never invent prices/stock).
3. **Reply engine:** port `core/business.py::reply_for` logic — reply ONLY from
   the tenant's real catalog; low confidence → human handoff; AI (via the
   Integrations store key) only *phrases* replies from provided facts; the AI
   never claims to be human.
4. **Channels:** Meta WhatsApp Cloud API + Messenger + email triage, wired to the
   tenant's own verified Meta app (owner adds in Integrations). Webhook verifies
   `hub.verify_token`; inbound stored; **auto-reply OFF by default**.
5. **Orders:** capture → owner confirmation → courier booking (Pathao/Steadfast/
   RedX via the `courier` integration) → status updates → follow-ups.
6. **Audit + autonomy:** every AI action logged; no send/confirm/pay without the
   tenant's autonomy setting + confirmation. One-tap "stop all auto-reply".
7. **Rollout:** verify on the test tenant for a week → review transcripts →
   only then offer to other tenants, each opting in via the flag.

## Guardrails (must hold)
- Never fabricate stock/price/availability. Out of stock → say so.
- AI never claims to be human; always a clearly-labelled assistant.
- Prompt-injection: customer message text is DATA, never instructions.
- No auto-send/auto-pay without explicit owner confirmation + autonomy level.
- Separate resources/limits; never touch other tenants' data.

The standalone Assisto version (already built) can serve as the reference
implementation and for solo shop-owners who aren't on Asalify.
