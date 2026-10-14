# Subscriptions — ADVANCED upgrade: integration needs

Scope kept to the allowed edit set. This file lists what the backend / API /
model must gain so the new UI persists everything it collects. Nothing below
was applied (models.py / serializers.py / urls.py were out of scope).

## Files changed / created
- **Edited** `app/lib/screens/subscriptions_screen.dart` — full rewrite: smart-view dashboard, pull-to-refresh, bottom-sheet add/edit, mark-paid roll, swipe-to-delete, trial & cancel-candidate banners, income-burden gauge.
- **New** `app/lib/widgets/subs_common.dart` — pure helpers (integer-poisha money, cycle math, next-due roll, bn digits via code points, category/payment catalogs, colour/icon). Mirrors the Python engine.
- **New** `app/lib/widgets/subs_cards.dart` — presentation atoms (spend hero, section header, alert banner, tile, breakdown bar, burden gauge).
- **New** `app/lib/widgets/subs_edit_sheet.dart` — advanced add/edit sheet (all fields).
- **New** `backend/core/logic/subscriptions.py` — pure analytics engine (no Django/DB/net).
- **New** `backend/core/logic/subscriptions_tests_snippets.py` — 20 plain-assert tests, `run_all()` green.
- **New** `.phaseB/up_subs_arb.json` — 58 keys, `{key:[bn,en]}`.

## Current list endpoint (unchanged, what the app reads today)
`GET /api/v1/subscriptions/` → JSON array of flat objects:
```json
[{"id": 1, "name": "Netflix", "amount": "650.00", "cycle": "monthly", "next_due": "2026-02-01"}]
```
`amount` is a DRF `DecimalField` string. `create` (POST) / `update` (PATCH `/{id}/`)
/ `delete` (DELETE `/{id}/`) all exist via `api.dart` (not edited).

## Fields the UI collects but the backend does NOT yet persist
`SubscriptionSerializer.fields` is only `[id, name, amount, cycle, next_due]`,
so the extra keys the sheet sends are silently dropped. To light up the smart
views end-to-end, add to **`core/models.py` `Subscription`** and expose in
**`core/serializers.py` `SubscriptionSerializer.fields`**:

| field | type | notes |
|---|---|---|
| `category` | `CharField(max_length=16, blank=True)` | one of streaming/internet/mobile/utility/fitness/shopping/productivity/other |
| `payment_method` | `CharField(max_length=8, blank=True)` | bkash/nagad/rocket/card/bank/cash |
| `trial_end` | `DateField(null=True, blank=True)` | powers the "trial ending" alert |
| `auto_renew` | `BooleanField(default=True)` | |
| `notes` | `CharField(max_length=300, blank=True)` | |
| `status` | `CharField(max_length=9, default="active")` | active/paused/cancelled — pause/cancel-with-history |
| `last_used` | `DateField(null=True, blank=True)` | powers the cancel-candidate nudge (>= 60 idle days) |
| `interval_days` | `PositiveIntegerField(null=True, blank=True)` | only for `cycle == "custom"` |

Alternative with **no migration**: add a single `details = JSONField(default=dict, blank=True)`
(as the `Document` model already does) and nest the above under it; the UI reads
flat keys today but can be pointed at `details` trivially. JSONField is the
cleaner path given values are a closed set.

### `cycle` length caveat (important)
`Subscription.cycle = CharField(max_length=8)`. The new "quarterly" cycle is
**9 chars and will be truncated/rejected**. The client already sends the wire
value `"quarter"` (7 chars) via `cycleWire()` and treats `quarter`/`quarterly`
as the same cycle, so it fits today. If you prefer the full word, widen to
`max_length=9`. `weekly/monthly/yearly/custom` all fit the current limit.

## Reminders engine reuse
`mark_paid` (py) / `rollNextDue` (dart) advance `next_due` to the first cycle
strictly after today, catching up any missed cycles, with month-end day
clamping. For push reminders before due, feed each live subscription's
`next_due` minus a per-user lead time into the existing
`core/logic/reminders_engine.py` scheduler (anchor = next_due at 09:00, rule =
cycle). No new recurrence code needed — the cycles map 1:1 to its
daily/weekly/monthly freqs; `custom` → `interval` days. Wiring is a view-layer
change (out of scope here).

## Income burden
`subscriptions.income_burden()` / the Dart `SubsBurdenGauge` need a known
monthly income (poisha). `AppState` exposes none today and `state.dart` was out
of scope, so the gauge is wired to `null` (hidden, no divide-by-zero). When the
money module surfaces a monthly income, set
`_knownMonthlyIncomePoisha` in the screen (or read it from `AppState`) and the
gauge lights up automatically. The backend `summarize(subs, monthly_income_poisha=…)`
already returns the `income_burden` block when income is passed.

## Verification
- `python3 backend/core/logic/subscriptions_tests_snippets.py` → `subscriptions: 20 tests passed`.
- Totals / next-due roll hand-verified in tests (monthly/yearly normalisation, 31 Jan → 28 Feb clamp, missed-cycle catch-up, poisha no-float-drift).
- Zero Bangla code points in any `.dart` (taka sign emitted as `৳`; all copy via AppLocalizations). ARB JSON validated: 58 keys, every value a `[bn,en]` pair.
