# Integration note — Domestic staff/driver (#186) + Savings challenge (#171)

Two NEW advanced features (Section-21 standard). All NEW files + ONE line added
to `core/tests.py`. No edits to `api.dart`, `core/models.py`, `core/urls.py`,
sidebar, `app_*.arb`, migrations, or Flutter build config.

## New files

| File | What |
|------|------|
| `backend/core/logic/domestic_staff.py` | Pure deterministic staff/salary/advance/dues math. Integer poisha; holds no money; all time from a passed-in `now`. |
| `backend/core/logic/domestic_staff_tests_snippets.py` | 20 plain-assert tests (`run_all()`). |
| `backend/core/logic/savings_challenge.py` | Pure deterministic challenge schedule + progress/streak/status/projection. Integer poisha; holds no money; time passed in. |
| `backend/core/logic/savings_challenge_tests_snippets.py` | 21 plain-assert tests (`run_all()`). |
| `app/lib/screens/domestic_staff_screen.dart` | Advanced staff UI. Contains `_StaffMath`, a VERBATIM Dart mirror of `domestic_staff.py`. |
| `app/lib/screens/savings_challenge_screen.dart` | Advanced savings UI. Contains `_SaveMath`, a VERBATIM Dart mirror of `savings_challenge.py`. |
| `.phaseB/up_staffsave_arb.json` | 102 NEW ARB keys as `{"key":["<bn>","<en>"]}`, 9 parameterized under `_params`. |

No new widget files were needed (both screens are self-contained; shared bits
reuse `widgets/skeleton.dart` `SkeletonList` + `StateMessage`).

## core/tests.py registration (the one line pair)

Added after `FarmerModeSnippetTests`:

```python
DomesticStaffSnippetTests = _make_snippet_case(
    "core.logic.domestic_staff_tests_snippets", "DomesticStaffSnippetTests")
SavingsChallengeSnippetTests = _make_snippet_case(
    "core.logic.savings_challenge_tests_snippets", "SavingsChallengeSnippetTests")
```

Verified green via the real harness:
`.venv/bin/python manage.py test core.tests.DomesticStaffSnippetTests core.tests.SavingsChallengeSnippetTests --settings=assisto_backend.settings_test`
→ **Ran 41 tests … OK** (20 staff + 21 savings).

## EXACT collection paths + row shapes

All four are generic per-user JSON collections. The integrator adds the four
names to the `GENERIC_COLLECTIONS` list in `core/views.py` (the `type()` loop
below it auto-builds a `PaCollectionViewSet` subclass per name — user-scoped,
audit-logged, no migration, backed by `PaCollectionItem`). The screens call the
existing `ApiClient.listItems/createItem/updateItem/deleteItem` on these paths;
each row round-trips as `{id, ...data}`.

```python
GENERIC_COLLECTIONS = [
    ...,
    # #186 Domestic staff / driver
    "staff/people", "staff/payments",
    # #171 Savings challenge
    "savechal/plans", "savechal/deposits",
]
```

### `staff/people`  (one row per household worker)
```
{ id, name: str, role: str, salary: str|num (taka-ish, monthly),
  join_date: "YYYY-MM" }
```
`role` ∈ `maid | driver | cook | guard | gardener | nanny | tutor | other`.

### `staff/payments`  (one row per salary/advance/repay entry)
```
{ id, person: <staff/people id>, month: "YYYY-MM",
  kind: "salary" | "advance" | "repay",
  amount: str|num (taka-ish),
  present_days?: str|int, month_days?: str|int }   # attendance on salary rows
```
Pro-rate rule: a full month (present unset or present ≥ month_days) always pays
the full salary EXACTLY; a partial month floors. A bad/negative attendance entry
never deducts. `net_dues = unpaid_wages − advance_balance` (advance − repay).

### `savechal/plans`  (one row per challenge)
```
{ id, name: str, kind: "week52"|"fixed"|"roundup",
  base: str|num (taka-ish),            # week1/base amount, or daily target (roundup)
  period?: "daily"|"weekly"|"monthly", # fixed only
  periods?: str|int,                   # fixed only (how many)
  start_date: "YYYY-MM-DD" }
```

### `savechal/deposits`  (one row per deposit logged)
```
{ id, plan: <savechal/plans id>, date: "YYYY-MM-DD", amount: str|num (taka-ish) }
```

## ARB keys + `_params`

102 NEW keys in `.phaseB/up_staffsave_arb.json`, format
`{"keyName":["<bangla>","<english>"]}`. The 9 parameterized keys are declared in
the `_params` object (placeholder order matters):

| key | params |
|-----|--------|
| `staffAdvanceHeld` | `amount` |
| `staffDaysPresent` | `present`, `month` (both int) |
| `staffDeleteBody` | `name` |
| `savechalDeleteBody` | `name` |
| `savechalGoalPreview` | `goal` |
| `savechalOfGoal` | `goal` |
| `savechalPeriods` | `n` (int) |
| `savechalProjectedShort` | `amount` |
| `savechalStreakShort` | `n` (int) |

Reused existing shared keys (NOT in the sidecar): `save`, `cancel`, `delete`,
`retry`, `edit`, `loadFailed`, `saveFailed`. The ৳ (U+09F3) currency glyph is
emitted by the math layer (`fmtPoisha`) and is gate-exempt.

Integrator merges each `"key":["bn","en"]` into `app_bn.arb` (slot 0) and
`app_en.arb` (slot 1); for `_params` entries add the matching
`@key` placeholders block in `app_en.arb` (all `String` except the int ones
noted above). Flutter gen-l10n then produces `t.key(...)`.

## Sidebar entries (for the integrator)

- **Domestic staff & driver** (`DomesticStaffScreen`) → under **My Account**
  (household-management). Icon suggestion `Icons.diversity_3_outlined`. (Could
  alternatively sit under **Family**; My Account is the better home since it is
  the owner's private payroll.)
- **Savings challenge** (`SavingsChallengeScreen`) → under **My Account**
  (alongside Money/savings). Icon suggestion `Icons.savings_outlined`.

Both screens are drawer-pushed routes (no bottom bar), matching the chat-first
nav standard.

## Wiring summary

1. Add the four collection names to `GENERIC_COLLECTIONS` (above). No migration.
2. Merge the 102 ARB keys + 9 `_params` into `app_bn.arb`/`app_en.arb`; run
   gen-l10n.
3. Add the two drawer entries routing to `DomesticStaffScreen` /
   `SavingsChallengeScreen`.
4. `core/tests.py` already has the registration line (committed with this work).

## Honesty / safety invariants

- Deterministic: Dart `_StaffMath` / `_SaveMath` are line-by-line mirrors of the
  Python engines; the live screen math is identical to the backend and offline.
- Holds no money: every summary ends with a visible "the app holds no money"
  note (bilingual); staff copy is dignity-first (leads with wages OWED to the
  worker, never framed as an expense to minimise).
- Honest states on both screens: welcome (first-use) · loading (skeleton) ·
  error (retry) · empty sub-states (no months / no deposits) · savings
  `not_started`. Status compares deposits to what the plan EXPECTED by today —
  never to the grand total — so an early saver is never told they're "behind by
  98%". Projection is capped at the goal, never inflated.
- ZERO Bangla literals in either `.dart` (verified U+0980–U+09FF absent except
  the gate-exempt ৳).
```
