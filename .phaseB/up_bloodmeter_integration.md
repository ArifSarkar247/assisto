# Integration note — Section-20 §20: Blood-donor network (#188) + Prepaid-meter tracker (#193)

Two NEW advanced (Section-21 standard) thin modules. NEW files only + ONE
`core/tests.py` registration line. No edits to `api.dart`, `core/models.py`,
`core/urls.py`, sidebar, `app_*.arb`, migrations, Flutter builds, or Asalify.

## New files

Flutter (`app/lib/screens/`):
- `blood_donor_screen.dart` — `BloodDonorScreen`. Registry + Search tabs, register/
  edit donor form, privacy-safe donor cards, eligibility badges. Deterministic
  `_Blood` helper mirrors `blood_donor.py` (90-day eligibility, ABO/Rh-free search,
  opt-in-only contact).
- `prepaid_meter_screen.dart` — `PrepaidMeterScreen`. Meter dashboard (sorted
  low-first), add/edit meter, log recharge, recharge-history sheet, projection
  band with low-balance warning. Deterministic `_Meter` helper mirrors
  `prepaid_meter.py` (integer-poisha closed-interval burn rate + projection).

Django pure logic (`backend/core/logic/`):
- `blood_donor.py` + `blood_donor_tests_snippets.py` (17 tests)
- `prepaid_meter.py` + `prepaid_meter_tests_snippets.py` (16 tests)

All logic is pure: no DB, no AI, no I/O, no money-holding, no external key.

## core/tests.py registration (the ONE wiring line pair)

Added after `ExpenseSplitSnippetTests`:

```python
BloodDonorSnippetTests = _make_snippet_case(
    "core.logic.blood_donor_tests_snippets", "BloodDonorSnippetTests")
PrepaidMeterSnippetTests = _make_snippet_case(
    "core.logic.prepaid_meter_tests_snippets", "PrepaidMeterSnippetTests")
```

`python manage.py test core.tests.BloodDonorSnippetTests core.tests.PrepaidMeterSnippetTests`
reports **Found 33 test(s)** (17 + 16). Standalone (no DB):
`python3 -c "import core.logic.blood_donor_tests_snippets as t; t.run_all()"` →
`blood_donor: 17 tests passed`; prepaid_meter → `prepaid_meter: 16 tests passed`.

## EXACT generic collection paths + row shapes

The integrator must add these names to the `GENERIC_COLLECTIONS` list in
`backend/core/views.py` (the `type()`-generated `PaCollectionViewSet` subclasses
+ the `PaItemSerializer` flatten already back every generic collection — NO model,
NO migration). Each row round-trips as `{id, ...data}` through the one flexible
per-user `PaCollectionItem` store, user-scoped + audit-logged.

Add to `GENERIC_COLLECTIONS`:
```python
    # #188 Blood-donor network
    "blood/donors",
    # #193 Prepaid-meter tracker
    "meter/meters", "meter/recharges",
```

Row shapes (the `data` payload the screens POST/PATCH; `id` is added by the store):

- `blood/donors`  (one row per donor)
  ```jsonc
  {
    "name": "Rahim Uddin",        // required
    "blood_group": "O+",          // required; one of A+ A- B+ B- AB+ AB- O+ O-
    "area": "Mirpur, Dhaka",      // free text, optional
    "phone": "01711111111",       // optional
    "availability": "available",  // available | paused | unavailable
    "last_donation": "2026-01-01",// ISO date, optional (unknown => eligible now)
    "share_contact": false        // PRIVACY opt-in; phone shown only when true
  }
  ```

- `meter/meters`  (one row per prepaid meter)
  ```jsonc
  {
    "name": "Home electricity",   // required
    "kind": "electricity",        // electricity | gas
    "balance": "250.00",          // optional ৳ reading off the meter
    "balance_date": "2026-06-18"  // ISO date the reading was taken
  }
  ```

- `meter/recharges`  (one row per recharge/token; linked by `meter`)
  ```jsonc
  {
    "meter": 42,                  // id of the parent meter row
    "amount": "500.00",           // token amount in ৳ (> 0)
    "date": "2026-06-11"          // ISO date of the recharge
  }
  ```

The screens call `listItems / createItem / updateItem / deleteItem` on exactly
`'blood/donors'`, `'meter/meters'`, `'meter/recharges'` (constants
`_donorsPath`, `_metersPath`, `_rechargesPath`). Deleting a meter also deletes
its recharges (client-side cascade) to keep the collection honest.

## ARB keys

Emitted to `.phaseB/up_bloodmeter_arb.json` as `{"keyName":["<bn>","<en>"]}`.
- **75 new keys** (38 `blood*`, 37 `meter*`), all verified 1:1 against the
  `tr.*` getters used in the two screens (no missing, no extra).
- Shared getters reused from the existing ARB (NOT re-emitted): `cancel`,
  `delete`, `edit`, `save`, `retry`, `loadFailed`, `saveFailed`.
- **9 parameterized keys** in the `_params` object:
  - `bloodNextEligible {date:String}`, `bloodRestingDays {days:int}`,
    `bloodResultCount {count:int}`
  - `meterHistoryTitle {name:String}`, `meterDeleteBody {name:String}`,
    `meterDaysLeft {days:int}`, `meterRatePerDay {rate:String}`,
    `meterRunsOutOn {date:String}`, `meterTotalRecharged {amount:String}`
- Bangla is real & natural; `৳` (U+09F3) is used only as a currency glyph.
  The integrator merges these into `app_en.arb` / `app_bn.arb` and regenerates
  `AppLocalizations` (placeholders already present in both bn & en strings).

## Sidebar entries (integrator wires in app_drawer.dart — not touched here)

- Blood-donor network → **Family & Safety** group. Suggested: icon
  `Icons.bloodtype_outlined`, label `tr.bloodTitle`, route to `BloodDonorScreen`.
- Prepaid-meter tracker → **My Account** group. Suggested: icon
  `Icons.bolt_outlined`, label `tr.meterTitle`, route to `PrepaidMeterScreen`.

## Determinism / honesty / privacy guarantees

- **Eligibility** = `last_donation + 90 days` (`DONATION_INTERVAL_DAYS`, the
  conservative BD/Red-Crescent whole-blood interval). Unknown last-donation =
  treated as eligible but flagged `has_history:false` ("last donation unknown").
- **Privacy**: donor phone is projected into a card ONLY when `share_contact` is
  true; default false. `public_donor_card` / `search_donors` never leak a number
  otherwise; UI shows an honest "contact hidden" state. Verified by
  `test_search_never_leaks_phone_without_opt_in` + `test_contact_hidden_by_default`.
- **Meter estimation**: burn rate = (sum of all recharges before the last) ÷
  (days from first to last recharge), integer poisha/day. Too-thin history
  (<2 dated recharges or zero span) → honest `state:"unknown"`, no fabricated
  runout date. Low when projected `days_left < DEFAULT_LOW_DAYS` (5); empty at 0.
- **No live utility API**: documented, inert seam `live_balance_seam()` returns
  `{"available": false, "reason": "no_live_utility_key"}` with bilingual note —
  the DESCO/NESCO/Titas integration point. The app buys no token, holds no money.
- Dart `_Blood` / `_Meter` helpers mirror the Python verbatim so results match
  online or offline.

## Report

- **Files created**: 6 (2 Flutter screens, 2 Django logic, 2 Django tests) +
  this note + the ARB json. One `core/tests.py` edit (2-line registration).
- **ARB key count**: 75 new keys (9 parameterized, listed under `_params`).
- **Test count**: 33 (blood_donor 17 + prepaid_meter 16), all passing standalone;
  the Django harness discovers all 33 (DB creation is unrelated / sandbox-only).
- **Zero-Bangla confirmation**: scanned both `.dart` files for U+0980–U+09FF
  excluding U+09F3 (৳) → **0 violations** in each file. All user-facing strings
  are `AppLocalizations` getters.
