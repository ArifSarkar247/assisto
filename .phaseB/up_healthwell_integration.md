# Integration — #69 Health timeline + #71 Water/sleep/diet tracker (SPEC v2.1 §10, ADVANCED)

Two NEW Health features, built to the Section-21 advanced bar (honest states,
confirm gate, bn/en, premium polish, no clipped text @360dp). NEW files only +
one `core/tests.py` registration block. No edits to `api.dart`, `core/models.py`,
`core/urls.py`, the sidebar, `app_*.arb`, migrations, or Flutter builds. No
external key. Food-photo OCR is a documented, key-gated seam — NOT built.

## New files

| File | Purpose |
|---|---|
| `backend/core/logic/health_timeline.py` | Pure deterministic timeline logic: normalise, newest-first ordering (date → created_at → id desc; undated last), filter (category set + free-text), group-by-month, group-by-category, category counts, summary (days-since-last from a passed-in `today`), validate, bilingual `disclaimer()`. No DB / AI / clock. |
| `backend/core/logic/health_timeline_tests_snippets.py` | 16 plain-assert tests (hand-verified, deterministic). `run_all()`. |
| `backend/core/logic/wellness_tracker.py` | Pure deterministic wellness logic: fold-by-day (water/sleep summed, latest diet note wins; undated skipped), clamped ring + raw ratio, `today_view`, 7-day `trend` (averages over logged days only + goal-met day counts), goal-met `streaks` (current + best), validate, bilingual `disclaimer()`. Time always passed in. No DB / AI / clock. |
| `backend/core/logic/wellness_tracker_tests_snippets.py` | 17 plain-assert tests. `run_all()`. |
| `app/lib/screens/health_timeline_screen.dart` | Advanced timeline UI. Welcome/loading/error/empty-filter states; search + category filter chips (with counts); month-grouped OR category-grouped (toggle); add/edit/delete bottom-sheet with confirm-delete dialog; disclaimer card everywhere. `_HealthView` mirrors the Python ordering/filter/grouping VERBATIM. ZERO Bangla literals. |
| `app/lib/screens/wellness_tracker_screen.dart` | Advanced tracker UI. Welcome/loading/error states + honest empty-day; today progress rings (water/sleep, clamped) with "over goal" via raw ratio; current+best streaks; 7-day trend bar charts (per-metric, logged vs gap shading, goal-day legend); diet card; log-today bottom-sheet (steppers + per-log goal override + free-text diet + documented photo-OCR seam note). `_Well` mirrors the Python math VERBATIM. ZERO Bangla literals. |

No new widget files were needed (helpers are private `_`-prefixed classes inside
each screen, e.g. `_EventCard`, `_FilterBar`, `_Ring`, `_TrendBars`).

## ARB keys — `.phaseB/up_healthwell_arb.json`

64 NEW keys (format `{"keyName":["<bn>","<en>"]}`), bn real + natural. 8 are
parameterized (declared in the `_params` object). Reused existing common keys
(NOT re-emitted): `cancel`, `delete`, `loadFailed`, `retry`, `save`,
`saveFailed`.

Prefixes: `htl*` (health timeline, 32 keys) and `well*` (wellness, 32 keys).

Parameterized keys (`_params`):

| key | params |
|---|---|
| `wellGlasses` | `count:int` |
| `wellGlassesOf` | `value:int, goal:int` |
| `wellHours` | `hours:String` |
| `wellHoursOf` | `value:String, goal:String` |
| `wellDaysCount` | `count:int` |
| `wellBestStreak` | `best:int` |
| `wellGoalDays` | `count:int, total:int` |
| `wellTrendAverages` | `water:String, sleep:String` |

Integrator: merge both arrays into `app_en.arb` / `app_bn.arb` (en = index [1],
bn = index [0]) with the usual `.phaseB` merge helper, add `@key` metadata with
`placeholders` for the 8 parameterized keys, then `flutter gen-l10n`. Month
names and weekday letters come from Flutter's `MaterialLocalizations`
(`formatMonthYear`, `formatShortDate`, `narrowWeekdays`) — no extra date keys.

## EXACT collection paths + row shapes

Add to `GENERIC_COLLECTIONS` in `core/views.py` (same `PaCollectionItem`
flexible per-user JSON store as the Section-20 modules — **no migration**):

```python
# #69 Health timeline + #71 Water/sleep/diet tracker (§10)
"health/timeline",
"wellness/logs",
```

The `GENERIC_COLLECTION_VIEWSETS` comprehension already builds a user-scoped,
audit-logged ViewSet per entry (`kind` = name with `/`→`_`). The screens call
the existing `ApiClient.listItems/createItem/updateItem/deleteItem` — no
`api.dart` change.

### `health/timeline` row (one event)
```json
{
  "id": 123,
  "category": "visit|test|prescription|vaccination|symptom|hospitalization|other",
  "title": "Blood sugar test",
  "date": "2026-03-05",          // YYYY-MM-DD; may be omitted (undated, shown honestly)
  "notes": "Fasting 6.1 mmol/L",  // optional
  "doctor": "Dr. Rahman",         // optional
  "place": "Popular Diagnostic",  // optional
  "created_at": "2026-03-05T09:12:00Z"  // server-set; used only as a sort tie-break
}
```
Unknown/blank `category` is coerced to `other` (never dropped). Delete is a
real `deleteItem` after a confirm dialog.

### `wellness/logs` row (one day)
```json
{
  "id": 456,
  "date": "2026-03-10",     // YYYY-MM-DD; REQUIRED (undated rows are ignored)
  "water": 6,               // glasses, int ≥ 0
  "sleep": 7.5,             // hours, number ≥ 0 (0.5 steps in UI)
  "diet": "fish & rice",    // free text (optional)
  "water_goal": 8,          // optional per-log override (default 8)
  "sleep_goal": 8.0         // optional per-log override (default 8.0)
}
```
The UI keeps **one log per day**: on "Log today" it edits today's existing row
if present (else creates). The backend fold still sums duplicates
deterministically if any ever exist.

## Tests

- `HealthTimelineSnippetTests` (16) and `WellnessTrackerSnippetTests` (17)
  registered in `core/tests.py` via `_make_snippet_case` (one block appended
  after `SavingsChallengeSnippetTests`, the `SocialComposeSnippetTests`
  precedent).
- Both pass standalone and under the Django harness (`django.setup()` +
  `run_all()`): **33/33**. (Full `manage.py test` can't create the test DB in
  the build sandbox by design — Asalify DB separation — but the classes import
  and the pure logic runs green.)

## Sidebar entries (integrator)

Both go under **Daily Life**, near the existing health items (Medicine DB,
Health tips, Birthdays). Suggested labels use the new ARB titles:

- Health timeline → route to `HealthTimelineScreen` (icon `Icons.timeline`),
  label `htlTitle`.
- Water, sleep & diet → route to `WellnessTrackerScreen`
  (icon `Icons.favorite_outline`), label `wellTitle`.

Add the two routes to the drawer/ChatNav route table alongside the other §10
Health screens, and `import` the two new screen files. (No sidebar file is
edited here — these are the integrator's one-line additions, per the
constraints.)

## Wiring checklist (integrator)

1. Merge `up_healthwell_arb.json` into `app_en.arb` / `app_bn.arb` (+ `@`
   placeholders for the 8 `_params` keys) → `flutter gen-l10n`.
2. Add `"health/timeline"` and `"wellness/logs"` to `GENERIC_COLLECTIONS` in
   `core/views.py` (no migration).
3. Add drawer/ChatNav entries + imports for the two screens (Daily Life group).
4. `flutter analyze` (expect 0) + lang gate (expect CLEAN — zero Bangla in the
   two .dart files, verified) + backend tests.
5. `fake_api` stubs for `health/timeline` + `wellness/logs` if the gallery/
   golden harness needs them (empty list → welcome state renders).

## Health-copy safety

Neither feature diagnoses, scores severity, or gives treatment/medical advice.
A gentle "not medical advice — consult a doctor" note is shown on the timeline
(every grouped view + the add/edit form) and on the tracker (main view). No drug
data is invented; any medicine reference remains the DGDA-sourced medicine
module's responsibility. Goals in the tracker are the USER'S own (gentle
8-glass / 8-hour defaults are lay guidance, labelled as defaults, not a
prescription). Food-photo OCR is a documented key-gated seam, intentionally not
built — the UI states it plainly (`wellPhotoSeam`).
```
