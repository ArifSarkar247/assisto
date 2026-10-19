# Assisto — Business Model + Profit Guard: Implementation Plan

Status: PLAN ONLY (no code / no ARB changes in this pass).
Author: mapping of EXISTING P3 monetization → concrete DELTA design.
Scope: extend what already ships; never duplicate it.

Legend: **[REUSE]** = already exists, extend it · **[NEW]** = net-new · **[CHANGE]** = edit existing.

---

## STEP 1 — WHAT ALREADY EXISTS (verified map)

### 1.1 Plans / entitlements (the pricing source of truth today)
- **`core/plans.py`** — `PLANS` dict is the hard-coded catalog (Python literal, NOT admin-editable):
  - Keys: `free` (৳0, 15 credits, ads=True), `premium` (৳**149**/mo, unlimited_ai, ads=False), `family` (৳**299**/mo, family=5), `probashi` ($4.99/mo), `business` (৳**1999**/mo), `annual` (৳1199/yr), `founder` (lifetime, is_founder).
  - Each plan: `price, cur, period, credits, unlimited_ai, ads, family`, + bilingual `name/desc/benefits`.
  - `TOPUP_PACKS = [{p20: ৳20→20cr}, {p30: ৳30→35cr}]`, `TRIAL_DAYS=7`, `REWARDED_DAILY_CAP=5`.
  - Functions: `trial_active`, `plan_active`, `effective_plan` (founder→trial(=premium)→paid→free), `entitlements(user,lang)`, `plans_public(lang)` (hides founder), `start_trial`, `_grant`, `grant_monthly_if_due` (once/calendar-month), `has_ai_quota`, `consume_credit` (one credit, no-op for unlimited), `reward_ad` (+1/day up to cap, uses `localdate()`).
  - NOTE: prices here mismatch the new spec (Premium 149 vs 199; Family 299 to be REMOVED; Business 1999 vs 999). All of these are **the delta**.

- **`User`** model (`core/models.py` ~L46–66): `plan` (CharField default "free"), `plan_until`, `trial_until`, `is_founder`, `ai_credits` (IntegerField — the running balance), `referral_code`, `referred_by`, `elderly_mode`.

- **`Subscription`** (`core/models.py` L476) = the user's *own bill-tracker* feature (Netflix/utility reminders). **UNRELATED to Assisto's own billing.** Do not overload it.

### 1.2 Credits
- Balance lives on `User.ai_credits` (int). Audit trail: **`CreditLedger`** (`core/models.py` L714): `user, delta (+/-), reason ∈ {grant,consume,rewarded,topup,trial,adjust}, note, created_at`.
- Spend path: `plans.consume_credit(user)` decrements by 1 and writes a `consume` ledger row. Called **inside `core/ai.py::generate()`** after a successful AI call (L184–186).
- Grant paths: `_grant` (monthly/trial/rewarded/topup), `grant_monthly_if_due`, `reward_ad`.
- **Gaps vs new spec:** (a) only a FLAT 1-credit cost — no per-action / per-model-tier cost table; (b) **not atomic** (`consume_credit` is read-modify-write on `User.ai_credits`, no row lock / `F()` / `select_for_update` → double-spend race under concurrency); (c) `has_ai_quota` only checks `>0`, so a 1-credit user could start a 5-credit action; (d) topup packs defined but **no purchase/credit endpoint wires them**.

### 1.3 Endpoints (billing/credits/plans)
- `GET /me/plan` → `views.PlanView` → `plans.entitlements()`.
- `POST /credits/rewarded` → `views.RewardedAdView` → gates on `integrations.is_enabled("admob")`, then `plans.reward_ad()`. (**App-open / interstitial crediting does NOT exist.**)
- `POST /waitlist` → `views.WaitlistView` (AllowAny) → `WaitlistEntry` (contact unique, approved bool).
- `GET` plans list → `views.py` L993 returns `plans.plans_public(lang)` (public paywall data).
- `GET /me/plan` is the only entitlement read; **no `/billing/charge`, no `/credits/topup`, no `/plan/subscribe` (billing "not wired yet" per plans_screen.dart docstring).**
- Referral money: `ReferralGrant` ledger + `core/logic/referral.py` (pure) with dup-person / dup-device clawback + redeem (points→Premium days). App: `referralRedeem()`.

### 1.4 AI budget / kill-switch (the "per-user limit + daily budget kill-switch")
- **`core/ai.py`** is the single AI gateway. `generate(task, data, tier, feature, user, ...)`:
  1. `_providers()` — ordered list anthropic→gemini→openai (store key wins over env).
  2. **Global daily budget kill-switch:** `_today_spend()` = `Sum(AIUsage.cost_usd)` over trailing 24h; if `>= settings.AI_DAILY_BUDGET_USD` → raise `AIUnavailable("budget")`.
  3. **Per-user daily limit:** `_user_over_limit(user)` = count of `AIUsage` rows in 24h `>= settings.AI_USER_DAILY_LIMIT` → `AIUnavailable("user_limit")`.
  4. **Plan credits:** `plans.has_ai_quota(user)` else `AIUnavailable("credits")`.
  5. Model routing: `TIER_MODEL = {cheap: haiku-4-5, medium: sonnet-4-6, strong: opus-4-8}`; `PRICES` USD/1M tokens per model (incl. gemini-flash, gpt-4o-mini).
  6. On success logs **`AIUsage`** (`core/models.py` L564: `user, feature, model, input_tokens, output_tokens, cost_usd, created_at`, indexed on created_at) then `consume_credit`.
- Settings (`assisto_backend/settings.py` L41–45): `AI_API_KEY`, `AI_ENABLED`, `AI_PROVIDER`, `AI_DAILY_BUDGET_USD=5` (env), `AI_USER_DAILY_LIMIT=40` (env). **Env-only — NOT owner-editable at runtime.**
- `ai.status()` / `ai.available()` expose spend vs budget.
- **This is the ONLY cost meter today.** SMS/IVR/video/storage have NO spend ledger. There is NO trailing-7d revenue number and NO model-downgrade-under-pressure hook (tier is picked by the caller, never auto-lowered).

### 1.5 Owner-editable config today (two existing patterns to REUSE)
- **Integrations store** — `core/integrations.py`: `REGISTRY` (dict of slug→meta incl. `anthropic, gemini, openai, firebase, google_places, admob, play_billing, bkash, …`), persisted in **`Integration`** model as an **encrypted blob** (`enc_blob`), accessed via `get(slug)`, `is_enabled(slug)` (status=="working"), `save(slug,data)`, `test(slug)`. `admob` fields: `app_id, banner_unit, rewarded_unit` (no app-open/interstitial units yet).
- **Admin flags store** — `core/logic/admin_flags.py` (PURE: catalog + validate + confirm-gate + audit) backed by **`AdminFlagState`** (`core/models.py` L2392, single row key='global', `state` JSON `{flag_id:bool}` + append-only `audit`). Catalog is **bool switches only** (ai_drafting, sms_fanout, push_fanout, cloud_photo_enhance, maps_geocoding, family_sharing, new_signups, …). Views: `AdminFlagsView` / `AdminFlagsFlipView` (`core/views_build61.py`, **superuser-gated** `_FlagsBase.is_owner`). App mirror: `app/lib/screens/admin/cost_flags_screen.dart`.
  - KEY CONSTRAINT (admin_flags.py docstring): "NEVER HOLDS MONEY / NEVER SERVER-SIDE PRICING" — this engine is bool capability switches, it must NOT compute prices. **So numeric pricing needs a NEW config store, not AdminFlagState.**

### 1.6 Owner analytics / P&L (partial, exists)
- `core/analytics.py` — PURE aggregation. Already has **`revenue_by_plan(events, price_map)`** (counts paid users × owner-set price; returns null revenue if any plan unpriced — "never invent revenue"), popularity ranking, dashboard builder. Endpoints: `GET /analytics/dashboard` (`views_module5.AnalyticsDashboardView`), `GET /analytics/ingest`.
- App: `app/lib/screens/owner_analytics_screen.dart` (owner dashboard UI already exists).
- **Gap:** no variable-COST side (AI/SMS/etc.), no daily P&L, no break-even, no margin-per-feature.

### 1.7 Storage (no quota today)
- Media is stored via Django `FileField/ImageField`: avatars, `vault/`, `catalog/`, `khata_bills/`, `theft/`, support screenshots; `EncryptedBackup.size_bytes` is the ONLY per-object byte count. **No per-user usage total, no quota, no meter, no upload gate.**

### 1.8 App monetization UI that exists
- `app/lib/screens/plans_screen.dart` — paywall: current entitlement + `plansPublic()` list + compare table (`widgets/plans_compare_table.dart`) + referral earn block (`widgets/plans_referral_section.dart`) + FAQ. Upgrade button is a clean "available when ___" (billing not wired).
- `app/lib/api.dart`: `plan()` → `/me/plan`, `rewardedAd()` → `/credits/rewarded`, `plansPublic()`, `referralRedeem()`, `referralBalance/History()`.
- `app/lib/screens/referral_screen.dart`, `owner_analytics_screen.dart`, `admin/cost_flags_screen.dart`, `admin/server_address_screen.dart`.
- `subscriptions_screen.dart` = the bill-tracker feature (NOT our billing).
- **No dedicated credit-balance widget, no top-up-pack purchase UI, no rewarded-ad wallet UI, no storage meter.**

---

## STEP 2 — DELTA DESIGN

### 0. One shared config store (foundation for everything numeric)
- **[NEW] `PricingConfig`** model — single-row (`key='global'`), owner-editable, server-authoritative. Mirrors the `AdminFlagState` single-row pattern but holds NUMBERS (admin_flags is barred from pricing by its own contract).
  - Fields: `key` (unique, default "global"), `data` (JSONField), `audit` (JSONField append-only), `updated_at`.
  - `data` shape (defaults seeded from a pure `core/logic/pricing.py` DEFAULTS, same discipline as admin_flags DEFAULTS):
    ```
    {
      "plans": { "free": {...}, "premium": {price_bdt, annual_bdt, included_credits, ...},
                 "business": {...} },      # family REMOVED
      "topup_packs": [{id, price_bdt, credits}, ...],
      "action_costs": { "<action_id>": {provider_cost_usd, margin, credits} , ... },
      "ad_rewards": { rewarded_credits, rewarded_daily_cap, appopen_min_gap_sec, appopen_daily_cap, interstitial_daily_cap },
      "storage_quota_bytes": { free, premium, business },
      "profit_guard": { spend_cap_pct_of_rev7d (=0.60), approach_pct (=0.80) },
      "margin_target": 0.40,
      "usd_bdt": <rate>   # for provider_cost→credits math
    }
    ```
- **[NEW] pure engine `core/logic/pricing.py`** (no Django/DB/clock, like admin_flags.py): `DEFAULTS`, `normalize(data)`, `credits_for(action, qty, cfg)`, `recompute_action_credits(cfg)` (auto re-price, §8), `validate_edit(path,value)`, `make_audit_entry(...)`. Dart mirror optional (UX preview only; server re-validates).
- **[NEW] accessor module `core/billing.py`**: `cfg()` (load+normalize PricingConfig row), `get_plan(user)`, `charge(user, action, qty=1)`, `credit(user, source, amount, note)`, plus the Profit Guard + storage helpers below. This is the ONE import costly endpoints use.
- **Admin-editability:** `GET/POST /admin/pricing` (superuser-gated, reuse `_FlagsBase.is_owner`), each edit writes an audit row. App: **[NEW]** `admin/pricing_screen.dart` (sibling of cost_flags_screen.dart).
- **Enforcement:** server is authority; `plans.PLANS` becomes a *fallback default only* — `entitlements()`/`plans_public()` read `PricingConfig` first.
- Tests: config loads defaults when row missing; owner edit persists + audits; non-owner 403; unpriced-plan safety.

---

### 1. PLANS — Free / Premium ৳199 / Business ৳999 (remove Family)
- **[CHANGE] `core/plans.py`**: drop `family` (and fold its features into `premium`); set Premium=199, Business=999; keep `annual` + `founder` + `probashi` (owner call — keep for now, re-price via config). Make `PLANS` the DEFAULT; real values come from `PricingConfig.data["plans"]`.
- **[CHANGE] `effective_plan` / `entitlements` / `plans_public`**: read prices + included credits + ads + quotas from `billing.cfg()`; still localise via i18n. Family→Premium feature flags (caregiver dashboard, 5 members) merge under `premium` entitlement.
- **Annual discount:** `plans.annual_bdt` in config (admin-editable); compare table computes savings from real numbers (app already does this from plansPublic).
- **Migration / existing Family users:** data migration — any `User.plan=="family"` (and `annual`/`family` rows) → set `plan="premium"`, preserve `plan_until`; keep `max_family` entitlement in premium so their 5-member circles don't break. Grandfather note in audit.
- **Server enforcement point:** `effective_plan()` (single chokepoint already consulted by `ai.generate`, watchers, etc.).
- **Admin-editable:** all plan prices + included credits via `/admin/pricing`.
- Tests: Family user migrates to Premium with members intact; prices served come from config not literal; removing Family from catalog hides it in `plans_public`; annual savings math.

---

### 2. CREDITS — monthly included + packs + per-action cost + atomic debit
- **[CHANGE] packs:** config `topup_packs` = `[৳20, ৳50, ৳100, ৳200]` (credits per pack admin-set). **[NEW] `POST /credits/topup`** (verifies a `play_billing`/`bkash` purchase token when wired; until then owner-only/manual grant path) → `billing.credit(user,"topup",n)` → `CreditLedger reason=topup`.
- **[NEW] per-action cost table** in config `action_costs`, keyed by action id, each = `provider_cost_usd × (1+margin) → credits` (margin default ≥0.40). Action ids (seed): `ai_msg_cheap, ai_msg_medium, ai_msg_strong, scan_ocr, photo_enhance, video_min, remote_support_min, ivr_min, sms, voice_clone, ai_sales_convo, storage_extra_gb`.
- **[NEW] atomic charge API** in `core/billing.py`:
  ```
  charge(user, action, qty=1) -> {"ok": bool, "reason": str, "charged": int, "balance": int}
  ```
  Logic: unlimited plan → ok, 0 charged. Else `need = pricing.credits_for(action,qty,cfg)`; inside `transaction.atomic()` + `select_for_update()` on the User row (fixes current race): if `ai_credits < need` → `{ok:False, reason:"insufficient", need}`; else `F('ai_credits') - need`, write one `CreditLedger consume` row with `note=action`. **Never negative; one row = no double-spend.**
- **[CHANGE] `core/ai.py::generate`**: replace the flat `has_ai_quota`/`consume_credit` with a **pre-charge** of the tier's action id (`ai_msg_<tier>`) BEFORE the provider call reserving credits, refund (credit back) if every provider fails (the existing `queued` path). This also fixes gap 1.2(c) (won't start a 5-credit action with 1 credit).
- **WHERE each costly endpoint calls `charge`** (enforcement points):
  | action | endpoint / module |
  |---|---|
  | ai_msg_* | `core/ai.py::generate` (covers all AI features) |
  | scan_ocr | doc scanner view (`core/logic/doc_scanner.py` caller) |
  | photo_enhance | `core/photo.py` enhance view (cloud ops only) |
  | video_min / remote_support_min | RTC/circle_calls views (`core/logic/rtc.py`, `circle_calls`) |
  | ivr_min / sms | SMS/IVR senders (currently gated by `sms_fanout` flag + `SMS_ENABLED`) |
  | voice_clone | voice feature view |
  | ai_sales_convo | `core/business_ai.py` / `business_views.py` CRM AI |
  | storage_extra_gb | upload endpoints (see §5) |
- **[REUSE]** `CreditLedger` (add no fields), `User.ai_credits`, `/me/plan` surfaces balance; **[NEW]** `GET /credits/history` (paged ledger) + app credit-balance widget + top-up sheet on `plans_screen.dart`.
- Tests: charge debits exactly `credits_for`; insufficient blocks + leaves balance unchanged; concurrent double-charge → only one succeeds (select_for_update); failed-provider refund; unlimited plan charges 0; pack grants correct credits + audit.

---

### 3. AD-FUNDED WALLET (free users)
- **[NEW] `AdWallet`** model: `user (OneToOne), balance_credits (int, >=0), updated_at`. Plus **[REUSE/EXTEND] `CreditLedger`** — add reasons `ad_appopen`, `ad_interstitial` (rewarded already exists) so the audit trail is unified; OR keep a small **[NEW] `AdEvent`** ledger (`user, kind ∈ {rewarded,appopen,interstitial}, credited, created_at`) for fraud/cap checks. (Recommend `AdEvent` for clean server-side cap math; `AdWallet.balance` is the spendable value.)
- **Crediting events (AdMob key-gated via `integrations.is_enabled("admob")`):**
  - rewarded → `+ad_rewards.rewarded_credits` (reuse `reward_ad`, now writes AdWallet + AdEvent).
  - app-open → **server-checked ≤1 per 3h** (`appopen_min_gap_sec` config) + daily cap: `POST /ads/appopen`.
  - interstitial → daily cap: `POST /ads/interstitial`.
  - All use `timezone.localdate()` (Asia/Dhaka) like existing `reward_ad` to avoid the UTC midnight bug.
- **Enforcement:** for a FREE user, `billing.charge()` first spends `AdWallet.balance`, then `ai_credits`. If both 0 → `{ok:False, reason:"watch_an_ad"}` → app shows "watch an ad to continue". **No ads watched → no costly action.** AdMob not configured → free users fall back to the 15 monthly included credits only.
- **NEVER gate (hard allow-list, bypass charge entirely):** SOS, Safe-Journey, anti-theft/lost-phone, health/medicine reminders, elderly mode, payment, login/auth. These call their logic directly, never `charge`. Add a `SAFETY_EXEMPT` set in `billing.py` asserted by a test.
- **[NEW] endpoints:** `POST /ads/appopen`, `POST /ads/interstitial`, `GET /ads/wallet`. App: **[NEW]** rewarded/app-open widget + wallet chip; **[CHANGE]** `admob` REGISTRY fields add `appopen_unit, interstitial_unit`.
- Tests: rewarded/appopen/interstitial credit the wallet; app-open 2nd call within 3h rejected (server clock); daily caps enforced; free user with empty wallet blocked on costly action but SOS/health/login/payment still work; AdMob off → no crediting, falls back to monthly credits.

---

### 4. PROFIT GUARD (global daily)
- **[NEW] `DailyLedger`** model: `date (unique), revenue_ads, revenue_subs, revenue_packs, revenue_commissions, cost_ai, cost_sms, cost_ivr, cost_video, cost_storage, updated_at` (all Decimal/float, in a single currency — store BDT, convert AI USD via `cfg.usd_bdt`). One row/day; upserted by `billing.record_cost(kind,amt)` / `record_revenue(source,amt)` called from the charge/credit/ad/payment paths.
- **[NEW] pure `core/logic/profit_guard.py`**: `trailing_7d_revenue(rows)`, `today_variable_cost(row)`, `state(rev7d, cost_today, cfg) -> {"ok"|"approaching"|"over", ratio}` where `over` when `cost_today > 0.60 × (rev7d/7 proxy or rev7d window)`, `approaching` at `>= approach_pct`.
- **[NEW] `billing.guard(action, user)`** consulted BEFORE any costly action (inside `charge`, after safety-exempt check):
  - `approaching` → **model-downgrade hook**: `ai.generate` consults `billing.effective_tier(requested_tier)` which caps `strong→medium→cheap` when guard is "approaching". (This is the missing auto-downgrade; implemented as a tier ceiling, not a caller change.)
  - `over` → block FREE-tier costly actions until next local day (`AIUnavailable("budget")`-style) + **instant owner alert** (reuse push/`firebase` + an `OwnerAlert` row / existing owner-notify path).
  - **Reserved safety budget:** SOS/family-alert SMS + safety notifications are in `SAFETY_EXEMPT` → guard NEVER blocks them (same allow-list as §3).
- **[CHANGE] `settings.AI_DAILY_BUDGET_USD`** stays as an absolute hard ceiling (belt-and-suspenders) but the PRIMARY guard becomes the revenue-relative one from config (`profit_guard.spend_cap_pct_of_rev7d`), so it scales with the business.
- **Admin-editable:** `spend_cap_pct_of_rev7d`, `approach_pct` in `/admin/pricing`. **Owner dashboard** reads `DailyLedger` (§7).
- Tests: cost under 60% → ok; at 80% → approaching + strong downgrades to medium; over 60% → free costly action blocked + owner alert fired + paid users still allowed; SOS/safety SMS never blocked even when over; downgrade never touches safety.

---

### 5. STORAGE — per-plan quota, WhatsApp model, meter
- **[NEW] `StorageUsage`** model: `user (OneToOne), bytes_used (BigInteger), updated_at`. Incremented on every upload, decremented on delete/expiry.
- **WhatsApp model:** server keeps encrypted media only until delivered + N days (config `media_retention_days`); phone keeps the copy. A periodic purge (reuse the `management/commands/purge_deletions.py` pattern) frees `bytes_used` when server media expires. Backups count toward quota (`EncryptedBackup.size_bytes` already tracked).
- **Quota per plan** in config `storage_quota_bytes`. `billing.storage_ok(user, incoming_bytes) -> bool`.
- **Enforcement points (upload endpoints):** avatar, vault (`Document.file`), catalog photo, khata bill photo, circle/circle_media uploads, `EncryptedBackup`. Each calls `billing.storage_ok` BEFORE saving; on fail → block NEW photos/videos/files/backups with a clean "storage full — upgrade or free space" state. **Text, calls, and ALL safety features keep working** (they don't upload bulk media / are safety-exempt).
- **Meter:** add `storage` block to `/me/plan` entitlements (`used, quota, pct`); **[NEW]** always-visible storage meter widget (app) + `GET /me/storage`.
- Tests: upload increments usage; over-quota upload blocked; delete/expiry decrements; text+call+SOS unaffected when full; backup counts; retention purge frees bytes.

---

### 6. ABUSE
- **[REUSE]** per-user daily AI limit (`AI_USER_DAILY_LIMIT`) + global kill-switch (`ai.available`) + referral dup-person/dup-device clawback (`core/logic/referral.py`, `ReferralGrant.device_id`).
- **[NEW]** rate limits on new costly endpoints (`/credits/topup`, `/ads/*`): per-user + per-device throttles (DRF throttle classes or a simple `AdEvent`-count check). Multi-account/device: reuse `device_id` on `AdEvent`/`ReferralGrant` — a device that already earned today can't farm ads across accounts.
- **[NEW]** rewarded-ad fraud: server-side gap/cap (already in §3), plus reject credits if `admob` not enabled; clamp wallet to config max.
- **[REUSE]** global kill-switch: `AdminFlagState` bool flags (`sms_fanout`, `cloud_photo_enhance`, …) already let the owner cut any cost capability instantly; add `ads_rewarded` / `topups_enabled` bool flags to the CATALOG.
- Tests (required): **a FREE user with 0 credits + empty ad wallet gets 402/blocked on every paid endpoint** (ai, scan, enhance, video, sms, voice_clone, sales_convo); duplicate-device ad farming rejected; topup rate-limit; kill-switch off → endpoint returns clean unavailable.

---

### 7. OWNER DASHBOARD — daily P&L
- **[REUSE] `core/analytics.py`** `revenue_by_plan` + dashboard builder; **[REUSE]** `owner_analytics_screen.dart` + `/analytics/dashboard`.
- **[NEW] pure `pnl` section** in analytics (or `core/logic/profit_guard.py`): from `DailyLedger` rows → `{date, revenue{ads,subs,packs,commissions,total}, variable{ai,sms,ivr,video,storage,total}, fixed (config), margin, break_even_revenue}`; margin per feature from `AIUsage.feature` sums; margin per plan from `revenue_by_plan`.
- **[NEW] `GET /admin/pnl?days=30`** (superuser-gated) → daily P&L series + break-even line + current profit-guard state + last cost kill-switch alerts (from `DailyLedger` + guard state + `AdminFlagState.audit`).
- **App:** **[CHANGE/EXTEND]** `owner_analytics_screen.dart` — add P&L tab (revenue vs variable vs fixed, break-even line, margin per feature/plan, guard-state banner + alert list).
- Tests: P&L totals = sum of ledger; margin computed; break-even correct; unpriced → null (never invent); non-owner 403.

---

### 8. AUTO RE-PRICING
- When owner edits `action_costs.<id>.provider_cost_usd` (or `usd_bdt`) via `/admin/pricing`, `pricing.recompute_action_credits(cfg)` recomputes `credits = round_up(provider_cost_usd × (1+margin) / usd_bdt_per_credit_unit)` to keep `margin_target`.
- Two modes (config `auto_reprice`): **auto** = recompute + persist + audit; **alert** = compute the suggested new credit cost, DON'T apply, fire an owner alert/approval row (reuse owner-alert path) with current vs suggested. Default = **alert** (owner approves price changes).
- Tests: provider_cost up → auto mode updates credits keeping ≥40% margin; alert mode leaves prices + fires approval; margin never drops below target after recompute.

---

## REUSE vs NEW — summary
- **REUSE (extend):** `plans.py` (effective_plan/entitlements/plans_public, reward_ad), `CreditLedger`, `User.ai_credits/plan`, `AIUsage` + `ai.generate` gateway, `integrations` store (admob/bkash/play_billing), `admin_flags`/`AdminFlagState` (bool kill-switches), `analytics.revenue_by_plan` + owner dashboard, `referral.py` fraud engine, purge-command pattern, `/me/plan`, `/credits/rewarded`, `plans_screen.dart`, `owner_analytics_screen.dart`, `cost_flags_screen.dart`.
- **NEW:** `PricingConfig` model + `core/logic/pricing.py` + `core/billing.py` (charge/credit/guard/storage), `AdWallet` (+`AdEvent`), `DailyLedger`, `StorageUsage`, `core/logic/profit_guard.py`, endpoints `/admin/pricing`, `/credits/topup`, `/credits/history`, `/ads/appopen`, `/ads/interstitial`, `/ads/wallet`, `/me/storage`, `/admin/pnl`; app `admin/pricing_screen.dart`, credit/wallet/storage widgets, P&L tab.
- **CHANGE:** `plans.PLANS` (prices, drop Family), `ai.generate` (pre-charge + tier ceiling), `admob` REGISTRY fields, `CreditLedger.REASONS`, migration for Family users.

---

## SMALLEST FIRST SHIPPABLE SLICE — "Build 1 of ~6"
**Config + atomic per-action charge + Family→Premium, server-enforced, no UI gamble.**
1. `PricingConfig` model + migration + `core/logic/pricing.py` DEFAULTS/normalize (seed Premium=199, Business=999, Family removed, action_costs, margin 0.40).
2. `core/billing.py` `cfg()` + **atomic `charge()`** (`select_for_update`, never-negative, single ledger row) + `SAFETY_EXEMPT` allow-list.
3. Wire `ai.generate` to `billing.charge("ai_msg_<tier>")` (fixes double-spend + under-funded-start bug) with failed-provider refund.
4. `effective_plan/entitlements/plans_public` read `PricingConfig`; **data migration Family→Premium** (members preserved).
5. `GET/POST /admin/pricing` (superuser) + audit.
Ships real revenue safety (correct prices, no double-spend, Family migrated) with ZERO new app screens required — `plans_screen` already renders `plansPublic()`. Builds 2–6: ad wallet, Profit Guard + DailyLedger, storage quota, owner P&L tab, auto-repricing.

---

## RISKS / FLAGS
1. **Migration risk — existing Family users.** A data migration MUST move `plan="family"` → `premium` while preserving `plan_until` and the 5-member circle entitlement, or paying users lose access. Grandfather in audit. (Also `annual`/`probashi` keep working.)
2. **Atomic-debit bug exists TODAY.** Current `consume_credit` is a non-atomic read-modify-write → double-spend under concurrency; Build 1 fixes it. Treat as a real bug, not just a feature.
3. **Migrations needed:** `PricingConfig`, `AdWallet`(+`AdEvent`), `DailyLedger`, `StorageUsage`, `CreditLedger.REASONS` enum widen. All additive/nullable — no destructive schema change; run on the Assisto-owned DB only (never touch Asalify).
4. **Pricing authority split:** admin_flags.py is contractually barred from pricing ("NEVER SERVER-SIDE PRICING") — numeric config MUST live in the new `PricingConfig`, not AdminFlagState; keep bool kill-switches in AdminFlagState. Don't cross the streams.
5. **Billing rails not wired:** `play_billing`/`bkash` integrations are defined but untested; `/credits/topup` + subscribe need a verified purchase token before real money moves — ship behind `integrations.is_enabled` and the owner kill-switch, manual-grant fallback until then.
6. **Safety allow-list is load-bearing:** one shared `SAFETY_EXEMPT` set must gate BOTH the ad wallet (§3) and Profit Guard (§4); a missing entry could block an SOS. Needs an explicit test per safety feature.
7. **Spend meters are incomplete:** today only AI has a cost ledger (`AIUsage`). SMS/IVR/video/storage costs are currently un-metered, so Profit Guard's "variable spend" is AI-only until §4's `DailyLedger.record_cost` is wired into those senders.
