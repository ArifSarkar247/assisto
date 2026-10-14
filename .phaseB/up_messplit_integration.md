# Integration note — Mess & bachelor accounting (#182) + Expense splitting (#183)

SPEC v2.1 §20, built to the §21 "advanced" standard. NEW work only. No edits to
api.dart, core/models.py, core/urls.py, sidebar, app_*.arb, or migrations beyond
the one-line tests registration + the two OwnedViewSet registrations the
integrator adds (described below). Zero Bangla literals in .dart (U+0980–U+09FF),
verified; only the gate-exempt ৳ (U+09F3) appears.

## New files

Flutter (new screens):
- `app/lib/screens/mess_accounting_screen.dart` — #182. 3 tabs (Members /
  Entries / Summary). Honest states: loading · error · welcome (no members).
  All meal-rate / dues math done in-screen by `_MessMath` (a verbatim mirror of
  the backend) so the summary is deterministic and identical offline.
- `app/lib/screens/expense_split_screen.dart` — #183. 3 tabs (People / Expenses
  / Settle up). Honest states: loading · error · welcome (no people) +
  empty-expenses state. All split / net / settle-up math in-screen by
  `_SplitMath` (verbatim mirror of the backend).

Backend (pure deterministic logic, no DB / AI / I/O / money-holding):
- `backend/core/logic/mess_accounting.py`
- `backend/core/logic/expense_split.py`
- `backend/core/logic/mess_accounting_tests_snippets.py` (14 tests)
- `backend/core/logic/expense_split_tests_snippets.py` (14 tests)

ARB keys: `.phaseB/up_messplit_arb.json` (this folder).

## core/tests.py registration (already added — the ONE edit)

Two `_make_snippet_case` lines after `AppUpdateSnippetTests`:
```python
MessAccountingSnippetTests = _make_snippet_case(
    "core.logic.mess_accounting_tests_snippets", "MessAccountingSnippetTests")
ExpenseSplitSnippetTests = _make_snippet_case(
    "core.logic.expense_split_tests_snippets", "ExpenseSplitSnippetTests")
```
Result: **28 new tests**, full suite **1122 passing** (`manage.py test core
--settings=assisto_backend.settings_test`).

## ARB keys — count & params

- **94 new keys** (47 `mess*`, 47 `split*`), bn+en balanced, in
  `up_messplit_arb.json` as `{"key":["<bn>","<en>"]}` (index 0 → app_bn.arb,
  index 1 → app_en.arb).
- **8 parameterized** keys, listed in the file's `_params` object. When merging,
  add the ICU `{placeholder}` form + `@key` metadata to both .arb:
  - `messMealsCount(count)`, `messMealsFor(name)`, `messDeleteMemberBody(name)`
  - `splitPaidBySplit(name, mode)`, `splitDeletePersonBody(name)`,
    `splitPaysText(from, to)`, `splitPaidShare(paid, share)`,
    `splitExactTotal(total)`
- **Reused existing getters (do NOT re-add):** `cancel, save, delete, edit,
  loadFailed, saveFailed, retry` — all confirmed present in app_en.arb.
- The ৳ sign is emitted by `_MessMath.fmtPoisha` / `_SplitMath.fmtPoisha`
  (Dart) and `fmt_poisha` (Python) — a currency glyph, gate-exempt, not copy.
- Parity verified: all 94 used getters exist in the ARB; 0 missing, 0 extra;
  every parameterized getter's arity matches `_params`.

## Generic REST collections — exact paths + row shapes

Both screens call the EXISTING `ApiClient` generic helpers only
(`listItems/createItem/updateItem/deleteItem`) — **no api.dart edit**. The
integrator registers matching per-collection `OwnedViewSet`s backed by a
flexible per-user JSON model, exactly like `PaCollectionItem` /
`PaCollectionViewSet` (the proven precedent: `pa/visitors`, `pa/followups`).
Each row round-trips as `{id, ...data}` via the flatten serializer
(`PaItemSerializer`): read flattens `data` + `id`; write folds every field
except `id` into `data`.

### Mess (#182) — 5 collections
| path (router prefix) | row `data` shape | notes |
|---|---|---|
| `mess/members`  | `{name}` | one row per member |
| `mess/meals`    | `{member, meals}` | member = a `mess/members` id; meals is a number, 0.5 steps allowed. One row per member (screen updates in place). |
| `mess/bazar`    | `{amount, title?}` | market buys; amount is taka-ish string. Feeds the meal rate. |
| `mess/deposits` | `{member, amount}` | deposits to the mess fund. |
| `mess/charges`  | `{member, amount, title?}` | `member` is a member id for a per-member charge, or the string `"common"` (also accepts `null`/`""`/`"all"`) for a shared charge split equally. |

### Split (#183) — 2 collections
| path | row `data` shape | notes |
|---|---|---|
| `split/people`   | `{name}` | one row per person |
| `split/expenses` | `{title?, payer, mode, amount?, participants?, parts?}` | `payer` = a `split/people` id. `mode` ∈ `equal`/`shares`/`exact`. `equal`: `amount` + `participants` (list of ids). `shares`: `amount` + `parts=[{member,weight}]`. `exact`: `parts=[{member,amount}]` (no top-level amount). |

### Suggested backend wiring (integrator — mirrors PaCollectionViewSet)

Reuse the `PaCollectionItem` model (its `collection` CharField is 24 chars — the
longest path above, `mess/deposits`, is 13 — fits) OR add a sibling
`MessSplitCollectionItem` model with the same `(user, collection, data)` shape
if collection-namespace isolation from PA is preferred. Then one viewset per
path with a fixed `collection`, e.g.:
```python
class _MessViewSet(PaCollectionViewSet):      # same model/serializer/scoping
    pass
class MessMembersViewSet(_MessViewSet): collection = "mess/members"; kind = "mess_members"
class MessMealsViewSet(_MessViewSet):   collection = "mess/meals";   kind = "mess_meals"
class MessBazarViewSet(_MessViewSet):   collection = "mess/bazar";   kind = "mess_bazar"
class MessDepositsViewSet(_MessViewSet):collection = "mess/deposits";kind = "mess_deposits"
class MessChargesViewSet(_MessViewSet): collection = "mess/charges"; kind = "mess_charges"
class SplitPeopleViewSet(_MessViewSet):  collection = "split/people";  kind = "split_people"
class SplitExpensesViewSet(_MessViewSet):collection = "split/expenses";kind = "split_expenses"
```
URLs (router.register — the slash paths work as-is; `_withSlash` in api.dart
already splits before any query string):
```python
router.register("mess/members", views.MessMembersViewSet, basename="mess-members")
router.register("mess/meals", views.MessMealsViewSet, basename="mess-meals")
router.register("mess/bazar", views.MessBazarViewSet, basename="mess-bazar")
router.register("mess/deposits", views.MessDepositsViewSet, basename="mess-deposits")
router.register("mess/charges", views.MessChargesViewSet, basename="mess-charges")
router.register("split/people", views.SplitPeopleViewSet, basename="split-people")
router.register("split/expenses", views.SplitExpensesViewSet, basename="split-expenses")
```
No new migration is needed if `PaCollectionItem` is reused (same table). If a
separate model is added, that is the only migration (DB backup first per the
disk/worktree protocol).

The backend logic modules (`mess_accounting.py`, `expense_split.py`) are OPTIONAL
on the request path — the screens compute everything client-side from the raw
rows. The modules exist as the authoritative, tested reference and can back an
agent/endpoint later (e.g. a server-rendered monthly summary) with zero new math.

## Backend logic — what's deterministic & honest

- **All money is INTEGER POISHA** (1 tk = 100 poisha); the only non-integer is
  the meal rate, kept as an exact fraction and rounded for display only.
- **mess_accounting.py**: `total_meals`, `total_bazar`, `meal_rate_poisha`
  (0.0 — not infinite — when no meals), `meal_cost_shares` (largest-remainder
  distribution → member costs sum EXACTLY to the bazar total, no drift),
  `deposits_by_member`, `charges_by_member`, `split_common_charges` (equal,
  exact), `monthly_summary` (reconciles to zero, returns a bilingual `note`),
  `validate_member`.
- **expense_split.py**: `split_equal` / `split_shares` (largest-remainder) /
  `split_exact`, `normalise_expense`, `expense_debts`, `net_balances` (sum to
  EXACTLY 0), `simplify_debts` (greedy minimal transfers, ≤ n-1), `group_summary`
  (paid/share/net per person + settlement list with bilingual text + `note`),
  `validate_expense`.
- No DB, no AI, no I/O, **holds no money** — compute + display only; settle-up
  is a suggestion the users act on themselves.
- Cross-language parity verified: the Dart `_MessMath`/`_SplitMath` mirrors
  produce identical distributions (e.g. ৳100 over meals 7/11/13 →
  `{2258, 3548, 4194}` in both; equal ৳10/3 → `{334,333,333}` both, sum 1000).

## Sidebar / ChatNav entries (My Account section)

Per `SIDEBAR_LAYOUT.md`, add two items under **My Account / আমার হিসাব**:
- Mess & bachelor accounting → `MessAccountingScreen()`
  (icon `Icons.groups_2_outlined`; title key `messTitle`).
- Split expenses → `ExpenseSplitScreen()`
  (icon `Icons.call_split` or `Icons.group_add_outlined`; title key `splitTitle`).

ChatNav routes + open-from-chat synonyms (integrator adds to the route table and
`screen_synonyms.py`): mess manager / মেস হিসাব / meal rate / মিল রেট /
মেস ম্যানেজার  →  mess; split / ভাগাভাগি / খরচ ভাগ / splitwise / settle up /
কে কাকে কত দেবে  →  split.

## Checklist for the integrator
1. Merge `up_messplit_arb.json` into app_bn.arb (index 0) + app_en.arb (index 1);
   add ICU `{param}` + `@key` metadata for the 8 `_params` keys. Run
   `flutter gen-l10n`.
2. Register the 7 OwnedViewSets + 7 router lines (above). Reuse PaCollectionItem
   (no migration) or add a sibling model (one migration, DB backup first).
3. Add the 2 sidebar items + ChatNav routes + synonyms.
4. `flutter analyze` (expect 0 errors) · `app/tool/lang_gate.py` (expect CLEAN) ·
   backend tests (1122 pass).
