# Integration — #173 Daily Challenges/Quiz + #18 Saved/Bookmarks (§21 advanced)

Two NEW features, built to the Section-21 standard. All new files; one
`core/tests.py` registration block. No edits to api.dart, core/models.py,
core/urls.py, sidebar, app_*.arb, or migrations. No external key. Original
Assisto identity. Points hold no money (documented seam only).

Report headline: **4 new .dart files · 2 new backend logic + 2 new test
snippets · 167 new ARB keys (5 parameterized) · 46 new tests (24 + 22) ·
ZERO Bangla in .dart (U+0980–U+09FF absent in all 4 files, verified)** — full
backend suite 1436 tests green.

---

## New files

Flutter (`app/lib/`):
- `screens/daily_challenges_screen.dart` — #173 UI: deterministic daily
  challenge card (quiz MC / task), stats strip (streak · points · done),
  answer-with-explain, completed history, welcome/loading/error/none states.
- `widgets/chal_bank.dart` — the 21-item bank STRUCTURE + the deterministic
  engine (date→index rotation, scoring, streak, longest-streak, summary),
  VERBATIM mirror of the backend. Bank TEXT resolves through
  `AppLocalizations` getters keyed by item id → ZERO Bangla literals here.
- `screens/saved_items_screen.dart` — #18 UI: add/edit (bottom sheet), search
  bar, tag-filter chips (All + per-tag counts), cards per kind, confirm-delete.
- `widgets/saved_logic.dart` — pure search / tag+kind filter / recent-sort /
  tag counts / honest-state pipeline, VERBATIM mirror of the backend.

Backend (`backend/core/logic/`):
- `daily_challenges.py` — pure deterministic engine + the bilingual BANK (21
  items ≥ the required ~20; finance/health/safety/general, hand-checked facts).
- `daily_challenges_tests_snippets.py` — 24 plain-assert tests.
- `saved_items.py` — pure saved/bookmark helpers + cross-app `make_item` seam.
- `saved_items_tests_snippets.py` — 22 plain-assert tests.

`.phaseB/up_chalsaved_arb.json` — 167 new ARB keys + `_params`.

---

## Tests (one registration block already added to core/tests.py)

Added after `FitnessPartnerSnippetTests`:

```python
DailyChallengesSnippetTests = _make_snippet_case(
    "core.logic.daily_challenges_tests_snippets", "DailyChallengesSnippetTests")
SavedItemsSnippetTests = _make_snippet_case(
    "core.logic.saved_items_tests_snippets", "SavedItemsSnippetTests")
```

Run: `.venv/bin/python backend/manage.py test core --settings=assisto_backend.settings_test`
→ 1436 OK (46 new: DailyChallenges 24, SavedItems 22). Each snippet file also
runs standalone (`python3 <file>`), no Django.

What the tests lock down:
- Daily: bank ≥20, unique ids, all 4 categories, valid shapes, correct
  answer-index points to the true fact (spot-checked: Dhaka / 100° / 7
  continents / never-share-OTP / 3–6 months); date→index wraps & advances by
  exactly 1/day & is identical across languages; bad date → honest `ok:false`;
  scoring (correct/try/task/skip/unknown); streak (today or yesterday anchor,
  gap breaks it, old run → 0, skipped rows ignored); longest-streak; summary
  totals + accuracy (null when no quizzes, not 0%); points→Premium-days seam
  reports days only (never grants).
- Saved: tag/kind normalisation; validate codes; make_item trims/caps/rejects;
  search AND-of-terms over title+note+tag+ref, case-insensitive, order-stable,
  blank→all; tag & kind filters; untagged only matches blank tag; tag counts
  (freq desc then A→Z, untagged excluded); recent-sort (blank-created last);
  `apply` state machine — empty ≠ no_results ≠ browse-all.

---

## EXACT collection paths + row shapes

Both reuse the existing `PaCollectionItem` flexible per-user JSON store via the
generic collection machinery — **no new model, no migration**. The integrator
adds two names to `GENERIC_COLLECTIONS` in `backend/core/views.py` (precedent:
`savechal/plans`, `staff/people`, etc.):

```python
GENERIC_COLLECTIONS = [
    ...
    # #173 Daily challenges / quiz — user PROGRESS only (bank is in-code)
    "challenges/progress",
    # #18 Saved / bookmarks — universal "save this" store
    "saved/items",
]
```

`GENERIC_COLLECTION_VIEWSETS` auto-builds a user-scoped, audit-logged ViewSet
per name; routing is already generic (same as every other collection). No
`core/urls.py` edit beyond whatever auto-registers GENERIC_COLLECTIONS (the
existing precedent rows prove this is migration-free and URL-config-free).

### `challenges/progress` — row shape
One row per completed daily challenge:
```
{ id, date, item_id, kind, answer, correct, points }
  date     'YYYY-MM-DD'  the day the challenge belonged to
  item_id  stable bank id (e.g. 'fin_emergency_fund')  — NOT the bank content
  kind     'quiz' | 'task'
  answer   chosen option index (quiz) | 1 (task done) | null (skipped)
  correct  bool            (task => true once done)
  points   int             points earned for this row
```
Screen calls: `listItems('challenges/progress')`,
`createItem('challenges/progress', row)` on completion. The BANK itself is
deterministic in-code (`daily_challenges.py` / `chal_bank.dart`) and is NEVER
stored — only the user's progress is.

### `saved/items` — row shape
```
{ id, title, note, tag, kind, ref, created }
  title    required, trimmed, ≤120 chars
  note     optional longer text / the saved content, ≤4000
  tag      optional single tag, normalised (lower-case, no leading '#', ≤40)
  kind     'note' | 'answer' | 'doc' | 'link'  (default 'note')
  ref      optional reference (url for link, doc id/name for doc)
  created  'YYYY-MM-DD'  (set by the screen; sort key only)
```
Screen calls: `listItems/createItem/updateItem/deleteItem('saved/items', …)`.

---

## ARB keys + `_params`

`up_chalsaved_arb.json` holds **167 NEW keys** as `{"key":["<bn>","<en>"]}`
plus a `_params` object. Do NOT edit `app_en.arb`/`app_bn.arb` — the integrator
merges this file with the existing merge script (`merge_arb.py`). Zero collision
with existing keys (verified). The 7 shared getters the screens reuse
(`cancel, close, delete, loadFailed, retry, save, saveFailed`) already exist and
are intentionally NOT re-emitted.

Key families:
- Challenge UI: `chalTitle, chalLoadError, chalWelcomeTitle/Body, chalNoneTitle/
  Body, chalStreak, chalPoints, chalDone, chalKindQuiz/Task, chalCatFinance/
  Health/Safety/General, chalSubmitAnswer, chalMarkDone, chalTaskHint/Completed,
  chalWhy, chalHistory, chalHistoryEmptyTitle/Body, chalPointsNote` + 5 toasts.
- Challenge BANK text (127 keys): `chalBank<ItemId>Q` (question),
  `chalBank<ItemId>X` (explanation), `chalBank<ItemId>O0..O3` (quiz options) for
  each of the 21 items. These carry the bilingual, fact-checked content.
- Saved UI: `savedTitle, savedLoadError, savedAdd, savedEdit, savedWelcome
  Title/Body, savedSearchHint, savedAllTag, savedNoResultsTitle/Body,
  savedClearFilters, savedKind*, savedTitle/Note/Tag/Link/DocLabel+Hint,
  savedSaved, savedDeleted, savedDeleteTitle/Body`.

`_params` (parameterized keys → placeholder list):
```json
"_params": {
  "chalCorrectToast": ["points"],
  "chalWrongToast":   ["points"],
  "chalTaskDone":     ["points"],
  "savedAllTag":      ["count"],
  "savedDeleteBody":  ["title"]
}
```
Placeholders in both bn and en verified to match `_params` exactly.

---

## Wiring (screens → drawer + chat nav)

The sidebar/app_drawer and ChatNav were NOT edited (off-limits). The integrator
adds ONE `SidebarItem` per feature to `app/lib/widgets/sidebar_sections.dart`
(same shape as every other item). Suggested placements:

- **Daily challenge → Daily Life** section (`SidebarSection('daily_life', …)`,
  line ~237) as a top engagement item:
  ```dart
  SidebarItem(Icons.emoji_events_outlined, (t) => t.chalTitle,
      (_) => const DailyChallengesScreen(),
      synonyms: ['daily', 'challenge', 'quiz', 'streak', 'points']),
  ```
- **Saved / bookmarks → Reminders & Memory** section
  (`SidebarSection('reminders_memory', …)`, line ~115) next to Memory:
  ```dart
  SidebarItem(Icons.bookmarks_outlined, (t) => t.savedTitle,
      (_) => const SavedItemsScreen(),
      synonyms: ['saved', 'bookmark', 'save this', 'favorite', 'keep']),
  ```
Add the two imports at the top of `sidebar_sections.dart`:
```dart
import '../screens/daily_challenges_screen.dart';
import '../screens/saved_items_screen.dart';
```
(Each sidebar item is also chat-openable via the existing ChatNav/screen_synonyms
map if the integrator adds the two routes there — optional, same pattern.)

---

## The POINTS seam (never holds money)

Daily-challenge points use the SAME "points" unit the referral engine mints
(`backend/core/logic/referral.py`). Division of responsibility:

- `daily_challenges.summarise(rows, today)['total_points']` **COUNTS** points
  from the user's completed progress rows. It never grants a plan, never mutates
  a balance, never holds money. The Dart `ChalBank.summarise` mirrors it for the
  on-screen total.
- `daily_challenges.premium_days_from_points(points)` is the DOCUMENTED, UNWIRED
  conversion: it reports how many Premium days `points` *would* buy using
  `referral.POINTS_PER_PREMIUM_DAY` (default 25 pts/day, OWNER REVIEW), imported
  lazily so the module stays standalone-testable. It returns an int only.
- REDEMPTION (actually extending `user.plan_until`) stays the integrator's job
  via the existing plan mechanism (plans.py) and the referral ledger — exactly
  as referral.py already documents. To make challenge points spendable, the
  integrator routes `total_points` into the same wallet/ledger the referral
  accept flow feeds, and applies Premium days through plans.py. Nothing here
  grants, charges, or stores money.

Point policy constants (mirrored in both engines, OWNER REVIEW): correct quiz
`POINTS_CORRECT=10`, wrong-but-tried `POINTS_TRY=2`, task done `POINTS_TASK=5`.

---

## Cross-app "save this" seam (#18)

Any screen can offer a Save action without a new endpoint:
1. Build a validated, normalised row:
   - Dart: `SavedLogic.makeItem(title, note:…, tag:…, kind:'answer', ref:…, created:…)`
   - Python (server-side helpers/tests): `saved_items.make_item(title, …)`
2. POST it to the one generic collection:
   `apiClient.createItem('saved/items', row)`.

Examples: chat screen saves an AI answer with `kind:'answer'`, the answer text
as `note`; the Vault/document screen saves `kind:'doc'` + the doc id/name in
`ref`; a link preview saves `kind:'link'` + the url in `ref` (validated:
`ref_required_for_link`). `make_item` raises on invalid input so a bad save
never silently stores junk. That's the entire seam — row shape + createItem.

---

## Honest states & §21 polish checklist

- Welcome (first-use) distinct from loaded: challenge shows a welcome banner
  until the first completion; Saved shows a full welcome StateMessage with a
  primary Save action when nothing is saved.
- Saved **no-results** (has items, filter/search matched none) is a DISTINCT
  honest state from empty, with a "Clear filters" action.
- Challenge: deterministic daily rotation; quiz explanation revealed ONLY after
  answering (no spoiler); wrong answers still earn a small consolation and show
  the correct option; task = self-reported engagement, never graded.
- Loading (skeleton) + error (retry) on both screens.
- bn/en throughout; no clipped text at 360dp (ellipsis + maxLines on every
  dynamic label; options wrap); WCAG-aware brand colours from theme.dart.
- No money held anywhere; facts accurate + neutral (general, non-prescriptive).
