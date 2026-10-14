# Integration note — Student Corner (#192) + Wedding & Events (#189), SPEC v2.1 §20

Two NEW thin modules built to the §21 ADVANCED standard (loading / error /
welcome-first-use states, confirm-gated deletes, bilingual bn/en, honest states,
no clipped text at 360 dp, premium polish). Deterministic pure logic; no AI key;
holds no money. NEW files only + ONE `core/tests.py` registration block. No edits
to `api.dart`, `core/models.py`, `core/urls.py`, sidebar, `app_*.arb`, or any
migration.

---

## New files

Flutter (app/lib):
- `screens/student_corner_screen.dart` — StudentCornerScreen (4 tabs: Routine,
  Tracker, CGPA, Goals).
- `screens/wedding_events_screen.dart` — WeddingEventsScreen (4 tabs: Overview
  w/ countdown + stat cards, Guests, Budget, Tasks).
- `widgets/student_gpa_engine.dart` — pure StudentEngine (CGPA, tracker, routine,
  goals). Mirrors the Python module verbatim; no widgets, no Bangla, no I/O.
- `widgets/wedding_engine.dart` — pure WeddingEngine (poisha math, guest tally,
  budget, tasks, countdown). Mirrors the Python module verbatim.

Backend (backend/core/logic):
- `student_corner.py` — pure deterministic logic.
- `student_corner_tests_snippets.py` — 23 plain-assert self-tests.
- `wedding_events.py` — pure deterministic logic.
- `wedding_events_tests_snippets.py` — 19 plain-assert self-tests.

ARB:
- `.phaseB/up_studwed_arb.json` — 154 NEW keys (`key -> [bn, en]`) + `_params`.

---

## Tests (core/tests.py) — ONE registration block added

Appended right after `LandlordTenantSnippetTests` (the existing `_make_snippet_case`
precedent, exactly like `SocialComposeSnippetTests`):

```python
StudentCornerSnippetTests = _make_snippet_case(
    "core.logic.student_corner_tests_snippets", "StudentCornerSnippetTests")
WeddingEventsSnippetTests = _make_snippet_case(
    "core.logic.wedding_events_tests_snippets", "WeddingEventsSnippetTests")
```

- Verified: both classes register in Django's harness; `django.setup()` +
  `run_all()` → **student 23 / wedding 19 = 42 tests pass**.
- Dart↔Python parity spot-checked live: CGPA 3.5625 (quality 28.5, 8 graded cr),
  over-budget ৳50,000.00, countdown 24 days, fmt ৳12,34,56,789.00, toPoisha
  "1200.50"→120050 — all identical to the Python asserts.
- (Full `manage.py test` needs DB-create perms absent in this sandbox; the suites
  run green standalone and under `django.setup()`.)

---

## GPA scale used (documented + echoed)

**UGC Uniform Grading System — Bangladeshi university 4.00 scale.** Constant
`GPA_SCALE` in `student_corner.py` and `StudentEngine.scaleRows` in
`student_gpa_engine.dart` (single source each side):

| Marks (%) | Letter | Point |
|-----------|--------|-------|
| 80–100 | A+ | 4.00 |
| 75–79 | A | 3.75 |
| 70–74 | A- | 3.50 |
| 65–69 | B+ | 3.25 |
| 60–64 | B | 3.00 |
| 55–59 | B- | 2.75 |
| 50–54 | C+ | 2.50 |
| 45–49 | C | 2.25 |
| 40–44 | D | 2.00 |
| 0–39 | F | 0.00 |

`CGPA = Σ(grade point × credit) ÷ Σ graded credits`. An **F counts** in the
credit denominator (0.00 points) — honest, matches real BD transcripts. A course
with no resolvable grade is kept, marked `graded=false`, and **excluded** from
both numerator and denominator (never invented). The scale table is SHOWN in the
CGPA tab (ExpansionTile) and the per-course `point × credit = contribution` and
the final `quality ÷ credits = cgpa` are rendered transparently.

---

## EXACT collection paths + row shapes (generic REST pattern)

Screens call the existing `ApiClient.listItems/createItem/updateItem/deleteItem`
(NO `api.dart` edit). Each path is one flexible per-user JSON collection; every
row round-trips as `{id, ...data}` via the `PaCollectionItem` flatten serializer
(same precedent as the task-manager / mess / split / samity / rent collections).

**Integrator action:** add these 8 names to `GENERIC_COLLECTIONS` in
`backend/core/views.py` (the `type()`-built `GENERIC_COLLECTION_VIEWSETS`
registry handles routing; NO migration — reuses `PaCollectionItem`):

```python
# #192 Student corner
"student/routine", "student/assignments", "student/courses", "student/goals",
# #189 Wedding & events
"wedding/event", "wedding/guests", "wedding/budget", "wedding/tasks",
```

Row shapes (data stored under the collection; `id` added by the store):

| Path | Row shape |
|------|-----------|
| `student/routine` | `{id, day:"sat".."fri", subject, room, start:"HH:MM", end:"HH:MM"}` |
| `student/assignments` | `{id, title, kind:"assignment"\|"exam", due_date:"YYYY-MM-DD"\|null, done:bool}` |
| `student/courses` | `{id, title, credit:number, letter:"A+".."F"\|null}` (marks also accepted by the engine) |
| `student/goals` | `{id, title, done:bool}` |
| `wedding/event` | `{id, title, event_date:"YYYY-MM-DD"\|null}` (single row; screen uses `.first`) |
| `wedding/guests` | `{id, name, rsvp:"yes"\|"no"\|"maybe"\|"invited", plus_ones:int}` |
| `wedding/budget` | `{id, category:key-or-freetext, estimated:int poisha, actual:int poisha}` |
| `wedding/tasks` | `{id, title, vendor, due_date:"YYYY-MM-DD"\|null, done:bool}` |

Notes:
- **Money is stored as INTEGER POISHA** in `wedding/budget` (the editor converts
  the taka field via `WeddingEngine.toPoisha` on save and back to taka for
  editing). `toPoisha(int)` is idempotent, so round-trips are exact.
- `due_date`/`event_date` are plain ISO `YYYY-MM-DD` strings; overdue/countdown
  are computed on-device from `DateTime.now()` (backend takes `now` explicitly
  for reproducible tests).

---

## ARB keys + _params

- **154 NEW keys**, format `key -> [bn, en]` (bn index 0, en index 1).
- **19 parameterized keys** in `_params` (add @-metadata to `app_en.arb` only,
  per project convention / merge_arb PARAMS):
  - Student: `studentOverdueBanner(count)`, `studentOverdueDays(days)`,
    `studentDueInDays(days)`, `studentCourseMath(letter,point,credit,contribution)`,
    `studentCourseNoGrade(credit)`, `studentCreditsSummary(credits,band)`,
    `studentFormulaBody(quality,credits,cgpa)`, `studentGoalProgress(done,total)`.
  - Wedding: `weddingExpectedGuests(count)`, `weddingOverdueTasks(count)`,
    `weddingOverdueBanner(count)`, `weddingOverdueDays(days)`,
    `weddingDueInDays(days)`, `weddingDaysToGo(days)`, `weddingDaysAgo(days)`,
    `weddingOverBy(amount)`, `weddingRemainingAmt(amount)`,
    `weddingEstVsAct(estimated,actual)`, `weddingPlusOnes(count)`.
- **Reused existing keys (NOT redefined):** `loadFailed`, `retry`, `cancel`,
  `delete`, `save`, `saveFailed`.
- **Merge:** add bn values → `app_bn.arb`, en values → `app_en.arb`, add
  @-metadata for the `_params` keys to `app_en.arb`, run l10n codegen. Every
  `tr.*` getter referenced by the two screens is one of these 154 keys or one of
  the 6 reused keys (verified programmatically, zero unknown getters).

---

## Zero-Bangla confirmation

Scanned all four new `.dart` files for U+0980–U+09FF: **0 violations**. The only
Bengali-block codepoint present is **৳ (U+09F3)**, the gate-exempt currency glyph,
and it appears only inside `WeddingEngine.fmtPoisha` (4×) and two doc-comment
mentions — never as a user-facing literal. All user-facing copy is an
`AppLocalizations` getter. `dart analyze` on the two engine files: **No issues
found**. (The screens' `tr.*` getters resolve only after the ARB merge above, by
design — `app_*.arb` is intentionally untouched.)

---

## Sidebar entries (for the integrator — sidebar NOT edited here)

Per `.phaseB/SIDEBAR_LAYOUT.md` grouping, add both under **Daily Life**:
- **Student corner** → route to `StudentCornerScreen` (icon: `school_outlined`).
- **Wedding & events** → route to `WeddingEventsScreen` (icon:
  `celebration_outlined`).

Each opens from chat like the other Daily-Life modules. Synonyms for search
(bn/en): student corner / রুটিন / সিজিপিএ / অ্যাসাইনমেন্ট / results; wedding /
বিয়ে / অনুষ্ঠান / গায়ে হলুদ / guest list / budget.

---

## Wiring summary

1. `GENERIC_COLLECTIONS` += the 8 paths above (views.py) — no migration.
2. `core/tests.py` registration block (already added).
3. Merge `up_studwed_arb.json` into `app_en.arb` / `app_bn.arb` + @-metadata, run
   l10n codegen.
4. Add two Daily-Life sidebar entries + routes to the two screens.
No other files change.
