# Integration — Kid's School Corner (#27) + Fitness Partner (#72)

SPEC v2.1 **§21 ADVANCED**. Two NEW features, fully deterministic, no external
AI key. Nothing in this batch touches `api.dart`, `core/models.py`, `core/urls.py`,
the sidebar source, `app_*.arb`, migrations, or Asalify. Persistence reuses the
existing generic REST-collection pattern (`PaCollectionItem` + `PaItemSerializer`),
so **no migration** is required — the integrator only appends collection paths to
`GENERIC_COLLECTIONS` in `core/views.py`.

---

## 1. New files

### Flutter (screens, self-contained engines — mirror the Python logic)
- `app/lib/screens/kid_school_screen.dart` — Kid's School Corner UI + `_KidMath`
  (deterministic mirror of `kid_school.py`).
- `app/lib/screens/fitness_partner_screen.dart` — Fitness Partner UI + `_FitMath`
  (deterministic mirror of `fitness_partner.py`).

No new widget files were needed; all sub-widgets are private (`_`-prefixed) inside
the two screen files, and all private helpers are `kid`/`fit`-flavoured so nothing
collides with other screens.

### Django (pure logic + self-tests)
- `backend/core/logic/kid_school.py` — notice keyword→type routing, per-notice
  honest status, per-child board, roster rollup, `due_soon` reminder seam,
  validation. No DB, no AI, no clock (today passed in), no money-holding.
- `backend/core/logic/fitness_partner.py` — goal/workout progress, weekly summary,
  streak, pro-rated honest status, AI-coaching seam (`coaching_available` /
  `fallback_tip`, NOT a live model), validation. No DB, no AI, no clock.
- `backend/core/logic/kid_school_tests_snippets.py` — 26 plain-assert tests.
- `backend/core/logic/fitness_partner_tests_snippets.py` — 24 plain-assert tests.

### The ONE `core/tests.py` registration (already applied)
Added right after `SavingsChallengeSnippetTests` / `WellnessTrackerSnippetTests`:

```python
KidSchoolSnippetTests = _make_snippet_case(
    "core.logic.kid_school_tests_snippets", "KidSchoolSnippetTests")
FitnessPartnerSnippetTests = _make_snippet_case(
    "core.logic.fitness_partner_tests_snippets", "FitnessPartnerSnippetTests")
```

`python manage.py test` reports **"Found … test(s)"** with the +50 included
(DB creation is blocked in the sandbox by the hard DB-separation rule, but the
snippet bodies are pure and pass standalone — see §5).

---

## 2. ARB keys (`/home/ubuntu/assisto/.phaseB/up_kidfit_arb.json`)

- **107 NEW keys** total (47 `kid*`, 60 `fit*`), format `key -> [bn, en]`.
- **20 parameterized** keys, enumerated in the `_params` object with their
  placeholder order. Verified: every param key's `{placeholders}` match `_params`
  in BOTH bn and en, and no non-param key carries a placeholder.
- **Reused** (NOT redefined): `loadFailed, retry, cancel, delete, save, saveFailed`.
- Merge procedure (unchanged from prior batches): bn[0]→`app_bn.arb`, en[1]→
  `app_en.arb`, add `@`-metadata for the `_params` keys to `app_en.arb` only, run
  `flutter gen-l10n`. After the merge the 123 analyzer "undefined getter" notices
  (the only analyzer output for these two files) resolve to zero.

### `_params` (placeholder order)
```
kidOverdueBanner[count]  kidOverdueShort[count]  kidOpenShort[count]
kidOverdueDays[days]     kidDueInDays[days]
kidChipFees[count] kidChipExams[count] kidChipPtm[count] kidChipEvents[count]
kidDeleteChildBody[name] kidTypeSuggested[keyword]
fitDaysOfTarget[done,target] fitStepsOfTarget[done,target]
fitWeightOfTarget[current,target] fitTargetLabel[unit]
fitSessions[count] fitDays[count] fitMinutes[minutes] fitCalories[calories]
fitStepsShort[steps]
```

### Zero-Bangla confirmation
`grep -P '[\x{0980}-\x{09FF}]'` over both `.dart` files, excluding `৳`, returns
**0 matches**. The Bangla keyword-router cues in `kid_school_screen.dart` are
written as `\u{...}` escapes (pure ASCII in source) and were verified to decode
to exactly the same keyword lists as `kid_school.py`'s `TYPE_KEYWORDS`. The only
raw non-ASCII bytes in either file are **four `৳` (U+09F3)** currency glyphs,
which are gate-exempt.

---

## 3. EXACT collection paths + row shapes

Append these to `GENERIC_COLLECTIONS` in `backend/core/views.py` (same block that
already lists `savechal/plans`, `student/routine`, …). Each becomes a user-scoped
`PaCollectionViewSet` subclass via the existing `type()` factory — no migration,
rows never leak across collections or users.

```python
# #27 Kid's school corner
"kid/children", "kid/notices",
# #72 Fitness partner
"fitness/goals", "fitness/workouts", "fitness/weighins",
```

Row shapes (what the screens `createItem`/`updateItem` with; stored verbatim in
`PaCollectionItem.data`, round-tripped as `{id, ...data}`):

| Path | Row shape | Notes |
|------|-----------|-------|
| `kid/children`   | `{id, name, klass}` | child-privacy: name + class only. |
| `kid/notices`    | `{id, child, title, body, type, amount, date, done}` | `child` = parent child id; `type ∈ {fee,exam,ptm,event,other}`; `date` 'YYYY-MM-DD'; `amount` only for `fee`; `done` flags paid/handled. |
| `fitness/goals`  | `{id, kind, target, start_weight, start_date}` | `kind ∈ {workout_days,steps,weight}`; `start_weight` only for `weight`; newest row = active goal. |
| `fitness/workouts` | `{id, date, type, minutes, calories, steps}` | `type ∈ {walk,run,cycle,gym,yoga,sport,other}`; `calories`/`steps` optional. |
| `fitness/weighins` | `{id, date, weight}` | optional log driving a weight goal's current value. |

The screens filter by parent-owned linkage client-side:
- a notice belongs to a child via `notice['child'] == child['id']`;
- the active fitness goal is the highest-`id` row in `fitness/goals`.

`klass` (not `class`) is used deliberately — `class` is a Dart/Python reserved
word; the field name is `klass` everywhere.

---

## 4. Tests

| Module | Count | Covers |
|--------|-------|--------|
| `kid_school_tests_snippets.py`       | 26 | keyword routing (en/bn/priority/unknown→other-not-confident), notice status (overdue/due-today/upcoming/no-date/done), `other` is dateless, amount only for fee, child board partition/counts/sort, `due_soon` forward-only window excluding overdue+done, roster rollup + nearest-next, empty/determinism, validation. |
| `fitness_partner_tests_snippets.py`  | 24 | Monday-anchored week bounds + weekday, weekly summary (this-week-only, distinct days, calories only-if-logged), streak (current/stale/yesterday), workout_days on-track/behind/reached, steps today-only, weight loss+gain progress & no-weighin fallback, not-started (future/no-goal), AI-coaching seam honest with/without key, deterministic non-medical tip/note, validation. |
| **Total** | **50** | |

Run standalone (both green):
```
python3 backend/core/logic/kid_school_tests_snippets.py        # kid_school: 26 tests passed
python3 backend/core/logic/fitness_partner_tests_snippets.py   # fitness_partner: 24 tests passed
```

---

## 5. Sidebar entries (integrator wires in the sidebar source)

- **Kid's School Corner (#27)** → **Family & Safety** group (it manages a child's
  life and is parent-owned; Daily Life is an acceptable alternative). Route to
  `KidSchoolScreen()`. Suggested icon `Icons.school_outlined`; label getter
  `kidTitle`.
- **Fitness Partner (#72)** → **Daily Life** group. Route to
  `FitnessPartnerScreen()`. Suggested icon `Icons.favorite_outline`; label getter
  `fitTitle`.

Both screens are self-contained `StatefulWidget`s needing no constructor args and
read `context.read<AppState>().api` exactly like `SavingsChallengeScreen`.

---

## 6. Wiring + seams

- **Persistence**: screens call existing `ApiClient.listItems / createItem /
  updateItem / deleteItem` on the paths above. `api.dart` is untouched.
- **Manual-entry, not AI/scan (#27)**: the parent types a notice and tags its
  type. `_KidMath.suggestType` is a transparent keyword lookup that only
  *pre-selects* the dropdown and shows "suggested from the word …"; once the
  parent touches the dropdown (`_typeTouched`) the suggestion never overrides it.
  An unmatched notice suggests `other` with `confident=false` (no false label).
- **Honest due/overdue (#27)**: computed from `today` passed into the pure
  functions. A dateless notice is `no_date` (never overdue); a `done`/paid notice
  is never overdue; `other` carries no date by type.
- **Reminder seam (#27, documented, NOT wired)**: `kid_school.due_soon` /
  `_KidMath.dueSoon` return the forward-looking set a notification job would act
  on. No notification is scheduled; due dates surface in-screen only — consistent
  with the project's foreground-polling decision (WorkManager removed). The Dart
  `dueSoon` carries `// ignore: unused_element` as a retained seam.
- **Deterministic fitness math (#72)**: Monday-anchored week, pro-rated expected
  value, status thresholds (≥1.1× ahead, ≥0.9× on-track, else behind; ≥target
  reached). Calories are reported only if the user entered them — never estimated.
- **AI-coaching seam (#72, documented, NOT built)**: `coaching_available(has_key)`
  returns `available=True` ONLY when the caller passes a configured key; the
  module never calls a model. With no key the screen shows `fallback_tip(status)`
  — a fixed, non-medical, clearly-not-AI line — and a one-liner (`fitCoachingSeam`)
  stating coaching is optional/key-gated while the full tracker works key-free.
- **Non-medical copy (#72)**: welcome, headline note (`fitNonMedicalNote`), and
  every tip/status avoid medical/extreme claims; the engine's `note` carries the
  "not medical advice" disclaimer in bn/en (asserted by a test).
- **Honest empty/loading/error/welcome states** on both screens; confirm gate on
  destructive delete (child delete also cleans up that child's notices first);
  no clipped text (ellipsis + `maxLines`, Wrap for chips) within 360dp.

### Analyzer status
`flutter analyze` on the two files: the ONLY output is 123 "undefined getter
`kid*`/`fit*`" notices that vanish after the ARB merge + gen-l10n. No other
warnings or errors (the two initial `unused_element` warnings were resolved:
dead `_daysBetween` removed; `dueSoon` kept as an annotated documented seam).
