# Integration — #190 Qurbani & #191 Probashi corner

Both screens are self-contained, use the generic REST-collection helpers on
`ApiClient` (`listItems` / `createItem` / `updateItem` / `deleteItem`), and need
no `api.dart`, `core/models.py`, `core/urls.py`, or migration changes beyond the
existing flexible per-user JSON collection backing (PaCollectionItem precedent).
All ARB keys are in `.phaseB/up_qurprob_arb.json` (merge into `app_*.arb` with
the project's merge script; `_params` lists the placeholder names per key).

## Screens

- `app/lib/screens/qurbani_screen.dart` — `QurbaniScreen` (already built).
- `app/lib/screens/probashi_screen.dart` — `ProbashiScreen` (built this pass).

Both are `const`-constructible (`const QurbaniScreen()`, `const ProbashiScreen()`)
and read `context.read<AppState>().api`.

## Generic collection paths + row shapes

### Qurbani — `qurbani/plans`
One row per sacrificial-animal plan.

```
{ id, animal, total_shares, cost, meat_kg,
  dist_family, dist_relatives, dist_poor, done }
```
- `animal`  : one of `cow | buffalo | camel | goat | sheep` (max shares 7/7/7/1/1).
- `total_shares` : int 1..max(animal).
- `cost`    : amount string in BDT (stored verbatim; parsed to integer poisha).
- `meat_kg` : total meat weight in kg (string/number; may be 0 / unset).
- `dist_family | dist_relatives | dist_poor` : integer ratio weights (default 1/1/1)
  for the largest-remainder meat split.
- `done`    : JSON list of completed checklist step keys, subset of
  `animal_chosen, shares_filled, cost_collected, butcher_booked, storage_ready,
  distribution`.

### Qurbani — `qurbani/participants`
One row per shareholder; `plan` foreign-keys the plan row id.

```
{ id, plan, name, shares }
```
- `plan`   : id of the owning `qurbani/plans` row.
- `name`   : free text.
- `shares` : int >= 1; sum of a plan's participant shares must be <= total_shares
  (the screen enforces free-shares on add/edit).

Cost-per-participant is computed client-side (largest-remainder of the taken
portion of `cost`) and is NOT stored.

### Probashi — `probashi/remittances`
One row per money-sent event (a record book — the app sends/holds NO money).

```
{ id, amount, rate, date, currency?, note? }
```
- `amount`   : foreign-currency amount sent (string; parsed to integer minor units).
- `rate`     : BDT per foreign unit (string/number; parsed to float >= 0).
- `date`     : `YYYY-MM-DD`.
- `currency?`: optional ISO-ish label the UI may show (not required by the math).
- `note?`    : optional free text.

BDT received per row = `amount_minor × rate`, rounded once to poisha; totals and
the effective (BDT-weighted) average rate are computed client-side in `_PMath`,
mirroring `backend/core/logic/probashi.py` verbatim.

### Probashi — `probashi/docs`
One row per important document with an optional expiry.

```
{ id, kind, label?, number?, expiry? }
```
- `kind`   : one of `passport | visa | ticket | nid | work_permit | insurance | other`.
- `label?` : optional display name; when blank the UI shows the kind's localised label.
- `number?`: optional document number.
- `expiry?`: `YYYY-MM-DD` or empty. Status (`expired | expiring | valid | no_date`)
  and days-left are computed client-side from `DateTime.now()`; the 90-day warn
  window mirrors `DEFAULT_WARN_DAYS`. Automatic reminders are a documented seam
  only — nothing is scheduled or sent.

## Sidebar entries (both → Daily Life)

Add both to the **Daily Life** section of the sidebar (do not edit the sidebar
in this pass — this records the intended wiring):

| Label key        | Screen          | Route target        | Icon (suggested)              |
|------------------|-----------------|---------------------|-------------------------------|
| `qurbaniTitle`   | `QurbaniScreen` | push `QurbaniScreen`| `Icons.volunteer_activism_outlined` |
| `probashiTitle`  | `ProbashiScreen`| push `ProbashiScreen`| `Icons.public`               |

Both live under the existing **Daily Life** group alongside Ramadan / birthdays /
dictionary etc. No bottom-bar entry (drawer-nav only, per design standards).

## Backend

- `backend/core/logic/qurbani.py` + `qurbani_tests_snippets.py` — registered in
  `core/tests.py` (pure, deterministic; no DB/AI/IO).
- `backend/core/logic/probashi.py` + `probashi_tests_snippets.py` — registered in
  `core/tests.py`.
- Persistence rides the existing generic per-user JSON collection endpoint that
  `listItems/createItem/updateItem/deleteItem` already target by path; no new
  model/route/migration is required.

## On-device math mirrors (offline-identical)

- `_QMath` in `qurbani_screen.dart` mirrors `qurbani.py` (integer poisha, integer
  grams, largest-remainder split).
- `_PMath` in `probashi_screen.dart` mirrors `probashi.py` (integer minor units /
  poisha, round-once BDT received, deterministic timezone pair from a single
  passed-in UTC instant, document expiry/status from today, 90-day warn window).

## i18n / design compliance

- ZERO Bangla literals in either `.dart` (verified: 0 Bangla codepoints in
  U+0980–U+09FF except `৳` U+09F3, which is a gate-exempt currency glyph).
- Every visible string is an `AppLocalizations` getter (`tr.qurbani*` / `tr.probashi*`
  plus shared `cancel/save/delete/edit/retry/loadFailed/saveFailed/saved`).
- All §21 states present on both screens: welcome (first use), loading
  (`SkeletonList`), error + retry (`StateMessage` + retry button), empty
  (per-tab `StateMessage`).
- Delete actions are confirm-gated (`_confirm` AlertDialog) on both screens.
- Layouts use `Flexible`/`Expanded` + wrapping so copy does not clip at 360dp.
```
