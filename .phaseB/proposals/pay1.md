# pay1 — Payments (Google Play Billing + EPS gateway), integration notes

Owner order: `.phaseB/PAYMENTS_ORDER.md` + amendment (22 Oct): the gateway is
**EPS** (eps.com.bd), not SSLCommerz. Branch `agent/pay1` (based on `launch`).

## What changed, by file

Backend (new)
- `core/payments/` — `catalog.py` (SKUs, server prices per channel, fees),
  `entitlement.py` (THE entitlement service), `gateway.py` (provider-agnostic
  `PaymentGateway` interface + registry), `eps.py` (EPS implementation),
  `play.py` (Play Developer API + RTDN), `service.py` (checkout / complete /
  IPN / return / refund / sweep / channel P&L).
- `core/logic/payments_cfg.py` — pure defaults/normalize of the
  `PricingConfig.payments` block (switches, fees, channel prices, reminder
  days, Play product ids). Hooked into `pricing.DEFAULTS()/normalize()`.
- `core/views_pay1.py` + `core/urls.py` block `# ---- pay1 ----`.
- `core/management/commands/payments_sweep.py`.
- `web/views_pay1.py` (+ `templates/web/premium.html`, `pay_return.html`),
  `web/urls.py` block `# ---- pay1 ----` (`/premium`, `/pay/return`).
- `web/owner/views_pay1.py` + `templates/owner/payments.html`, nav link,
  `owner/urls.py` line, `owner/i18n.py` appended `EN.update/BN.update` block;
  `templates/owner/pnl.html` gets a "net revenue per channel" table.
- `core/models.py` appended block `# ---- pay1 ----` (PaymentOrder, PlayPurchase,
  PlanPeriod, PaymentAccount, PaymentEvent, WebhookReceipt, PaymentReminder,
  WebCheckoutSession) + `core/migrations/0062_pay1.py` (depends on
  `0057_f1_founders` — **integrator re-chains** to the latest in main).
- Small edits: `core/integrations.py` (play_billing fields + new `eps` entry +
  `test_eps`, `test_play_billing`), `core/billing.py` (`eps` provider;
  legacy `/credits/topup` answers `use_checkout` when a channel is set up;
  `pnl_dashboard.payments_by_channel`), `core/views_build61.py`
  (`pricing_apply` merges the `payments` block; `use_checkout` is a 200).

App
- `lib/payments/payments_api.dart` (our endpoints only), `checkout_sheet.dart`
  (the ONE sheet), `store_billing.dart` (seam + lazy loader),
  `play_billing_impl.dart` (in_app_purchase; DEFERRED import).
- `lib/screens/plans_screen.dart` — "Choose" opens the sheet (sku from the
  card shown), prepaid renew banner / "managed by Google Play" note.
- `lib/screens/credits_screen.dart` — packs open the sheet.
- Tests: `test/pay1_checkout_test.dart`, `test/pay1_fakes.dart`,
  `test/pay1_shots.dart` (+2 lines in `screenshots_test.dart`).
- Strings: `.phaseB/up_pay_arb.json` (30 keys, en + bn). `app/lib/l10n` untouched.

## pubspec (applied on this branch, marked `---- pay1 ----`)
```diff
   flutter_webrtc: ^1.6.2
+  # ---- pay1 ---- Google Play Billing (BSD-3-Clause, flutter/packages).
+  in_app_purchase: 3.3.1
+  in_app_purchase_android: 0.5.3
+  # ---- /pay1 ----
```
- `in_app_purchase` 3.3.1 (published 2026-09-18) + `in_app_purchase_android`
  0.5.3 (published 2026-08-28; 0.5.5 was only 3 days old so not taken), both
  licence **BSD-3-Clause** (flutter/packages); needs Flutter >= 3.44 (we are on
  3.47.7). Transitive: `in_app_purchase_platform_interface`,
  `in_app_purchase_storekit` (iOS, unused). Play Billing Library 8.0.0 (com.android.billingclient:billing). pubspec.lock is committed.
- Why exact: owner rule (no surprise upgrades in a payment path).
- Lazy: the plugin's Android side only registers a method channel at engine
  start; no BillingClient is created until `buy()` is called. On the Dart side
  only `play_billing_impl.dart` imports it, as a `deferred` library loaded on
  the first "Google Play" tap when `AppConfig.playStore` is true. The website
  APK never loads it (`StoreBilling.forThisBuild()` returns null).
- No startup ContentProvider is added by in_app_purchase_android (checked in
  its AndroidManifest; it only adds the BILLING permission via the billing
  client AAR).

## android.yml (applied, marked `---- pay1 ----`)
1. New step before "Build release APK": adds
   `<uses-permission android:name="com.android.vending.BILLING" tools:node="remove"/>`
   so the **website APK has no Play Billing permission at all**.
2. In the AAB step: removes that line again (Play build keeps BILLING) and
   fails the job if `com.android.vending.BILLING` is missing from the bundle.
No other native/manifest/Gradle change. Smoke stays API-33-only.

## Live install steps (integrator)
1. Merge, re-chain `0062_pay1.py`, `migrate`.
2. Cron (hourly), e.g. `/etc/cron.d/assisto-payments`:
   `7 * * * * ubuntu cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py payments_sweep >> /var/log/assisto/payments_sweep.log 2>&1`
3. Settings (optional, defaults shown): `WEB_PUBLIC_SITE=https://lifeassisto.com`,
   `PUBLIC_API_BASE=https://api.lifeassisto.com`, `PLAY_PACKAGE_NAME=com.assisto.assisto`.
4. Reverse proxy: `/pay/return` and `/premium` on lifeassisto.com and
   `/api/v1/payments/*` on api.lifeassisto.com must reach Django (they already
   do if the whole host is proxied). The RTDN/IPN views read the raw body; no
   body-size change needed.
5. Apply `.phaseB/up_pay_arb.json` with `arb_apply.py`, then gen-l10n.
6. Owner: `owner_actions/PAYMENTS_SETUP.md` (Bangla) — EPS + Play Console + keys.

## Entitlement rules (documented for the owner in PAYMENTS_SETUP.md)
- One account: `User.plan/plan_until` is written ONLY by
  `core/payments/entitlement.recompute()` for payments; periods live in
  `PlanPeriod` (unique `(source, ref)`), credits in CreditPurchase/CreditLedger.
- Highest tier covered now wins. Non-payment time (Founding Member, referral,
  owner edits) is the account "base" (PaymentAccount) and is never wiped.
- Gateway (prepaid): same plan stacks; upgrade converts unused lower-tier
  gateway time at the monthly price ratio into extra days; downgrade queues.
- Play: Google's dates are mirrored; ACTIVE/CANCELED/IN_GRACE_PERIOD =
  entitled until expiryTime; ON_HOLD/PAUSED/EXPIRED/PENDING = not entitled;
  REVOKED / voided = revoked (+ revenue reversed); `linkedPurchaseToken`
  marks the old token replaced (upgrade/downgrade/resubscribe).
- No double charge: Play sub of same/higher tier blocks a gateway sub;
  a prepaid gateway period of same/higher tier blocks a Play sub (precheck);
  gateway tx ids and Play purchase-token hashes are unique.

## Security
- Amounts only from the server price table; a callback/IPN can never change
  them. Every gateway payment is verified server-to-server
  (`CheckMerchantTransactionStatus`) and must match tx id, amount, currency.
- EPS IPN: AES-256-CBC envelope required once an IPN key is set; timestamp
  replay window 30 min; (tx, EPS tx) receipt de-dupe; IPN is a trigger only.
- RTDN: Pub/Sub OIDC JWT verified (RS256 against Google's JWKS, iss, aud,
  email, exp) and/or shared `?token=`; fail-closed when neither is set;
  messageId de-dupe; the body is never trusted for state (re-fetch from Google).
- Play tokens bound to the first account (unique hash) + obfuscatedAccountId
  `u<pk>-<HMAC>` check; packs consumed by the server, granted once.
- Website session: random token, hash stored, HttpOnly + Secure + SameSite=Lax,
  30 min; OTP via core.otp (rate limits, lockout, anti-enumeration).
- Redirects only to `https://*.eps.com.bd`.
- Audit: PaymentEvent (append-only) + the user's AuditLog for every
  entitlement change; owner actions also in OwnerAudit.

## EPS contract — sources and what was verified
See the module docstring of `core/payments/eps.py`: official samples at
github.com/EPS-PG (EPS_PHP "Official PHP SDK", EPS_Laravel, EPS_Woocommerce)
and https://eps.com.bd/ipn. Response shapes were confirmed against the public
EPS sandbox (GetToken / InitializeEPS / CheckMerchantTransactionStatus, and
the "Invalid hash provided." error) with the demo merchant EPS publishes in
its own PHP sample; the tests use a faithful mock of those shapes. Two
assumptions are marked (IPN AES key derivation; the full list of status
words) and listed for the owner to confirm with EPS.
