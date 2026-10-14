# BUDGET module (#50 → advanced) — integrator TODO

Raises Appendix-A #50 ("Budget & next-month plan") from **good → advanced** (SPEC v2.1 §21, all 10). Builds a dedicated Budget module on top of the existing Money data — **reads real transactions read-only**, never fabricates spend.

Owned files (new / rebuilt this task, no shared files edited):
- `app/lib/screens/money_budget_screen.dart` — **rebuilt** as the advanced module (3 tabs: This month / History / Plan) AND still serves the single-category drill-down `MoneyBudgetScreen(category:)` that `money_screen.dart` opens (constructor kept backward-compatible: `category` is now optional).
- `app/lib/widgets/budget_card.dart` — `BudgetCard` (progress bar + state colour + over-budget alert), `BudgetTotalHeader`, `budgetStateColor/Label`.
- `app/lib/widgets/budget_insights.dart` — `BudgetInsights` (ranked plain-language insights), `BudgetGoalLinkCard`.
- `app/lib/widgets/budget_sheets.dart` — `showBudgetSheet` (add/edit), `showTemplateSheet` (50-30-20).
- `app/lib/budget_api.dart` — `BudgetApi` extension on `ApiClient` (public `getJson/postJson/patchJson` only — fold into api.dart later).
- `backend/core/logic/budget.py` — pure engine (integer-poisha, no float drift).
- `backend/core/logic/budget_tests_snippets.py` — 16 asserts, `run_all()` passes:
  `python3 -c "import core.logic.budget_tests_snippets as b; b.run_all()"` → `OK — 16 budget tests passed`.

## ARB: apply `.phaseB/up_budget_arb.json` to both `app_*.arb` (58 keys), then regenerate `app_localizations`.
Placeholder @-metadata (type Object), declare in THIS order (the .dart calls are positional):
- `budgetSpentOf{spent, limit}`
- `budgetInsightOver{category, pct}` · `budgetInsightNear{category, pct}`
- `budgetOverBy{amount}` · `budgetUnbudgetedHint{amount}` · `budgetGoalLinkBody{amount}`
- `budgetPctOfLimit{pct}` · `budgetMonthLabel{month}`

## budget.py engine (pure, no Django import; integer POISHA → no float drift):
- `to_poisha/from_poisha/taka_str` — the integer-money boundary (1 Tk = 100 poisha; floats rounded at 2dp first so 19.99→1999, never 1998).
- `spent_by_category(txns, month)` — **real expense rows only** (income/transfer/other-month excluded) → {cat: poisha}.
- `budget_line(category, limit, spent, warn_pct=80, carried_in=0)` — effective limit vs spend; `state` ∈ ok|near|over|none; `pct` unclamped, `bar_pct` clamped 0..100; `over_by`.
- `month_budget(budgets, txns, month)` — all lines + totals + `unbudgeted_spent` (honest) + `any_over/over_count`; lines sorted over→near→ok→none.
- `rollover_series(category, limit, spend_by_month, months, rollover)` — carry-in/out; overspend never makes negative carry.
- `template_50_30_20(income)` — needs/wants/savings; last bucket absorbs residue (sums exact).
- `insights(month_result, max=3)` — ranked {code: over|near|on_track, category, pct, over_by}; `on_track` only when nothing over/near.
- `goal_contribution(month_result, goal)` — this-month total underspend → savings goal; over-budget month contributes 0.
- `next_month_plan(txns, months, buffer_pct=10)` — avg real spend + buffer per category.

## MIGRATION (core): no new model needed — reuse existing `Budget` (category, monthly_limit, rollover already present per money_integration.md) and `Goal` (target_amount, saved_amount). No migrations authored here (per task).

## api.dart add (or keep the extension): all `req_lang`, feed the SAME txn queryset the money views pull, Decimals→str:
- GET `/money/budget/month[?month=YYYY-MM]` → `budget.month_budget(user_budgets, user_txns, month or current)` + `insights(result)` merged in as `result["insights"]`.
- GET `/money/budget/history?category=&months=6` → `budget.rollover_series(cat, limit, spend_by_month_from_txns, ordered_months, rollover)`. (Supersedes the old `/money/budget?category=` which `moneyBudgetDetail` used; drill-down now calls `budgetHistory`.)
- GET `/money/budget/plan?months=3&buffer=10` → `budget.next_month_plan(txns, recent_months, buffer)`.
- GET `/money/budget/template?income=` → `budget.template_50_30_20(income)`.
- POST `/money/budget {category, monthly_limit, rollover}` → create Budget (manual rail).
- PATCH `/money/budget/<id> {monthly_limit?, rollover?}` → update.
- POST `/money/budget/<id>/delete` → delete (modelled as POST so the extension needs no new verb).
- POST `/money/budget/goal-link` → `budget.goal_contribution(month_budget(...), active_goal)`, then persist `saved_amount += contribution`; return the result card payload.

## §21 (all 10):
1. Best-in-class: per-category limits + rollover + 50-30-20 + next-month plan + goal link — matches/beats Wallet/Money-Manager.
2. Full flow: create/edit/delete budget; view this-month/history; apply template; use suggestion.
3. Both rails: **manual** (set a limit) + **auto** (spend read from real/AI-captured txns; `budgetAiMarker` on tracking-only cards).
4. Empty/loading/offline/tracking-only states all designed (skeletons, offline card, honest "no limit" state).
5. Strict bn/en (zero Bangla in .dart; all text via ARB), light/dark (ColorScheme), small/large (ellipsis + Wrap + scroll).
6. Wire: surface over-budget as a watch-feed/reminder alert + answerable in chat ("am I over on food?") — engine ready; integrator wires to watch/reminders like money.
7. Server tests: `budget_tests_snippets.py` (16, incl. real-txn + no-drift + over-alert + rollover scenarios).
8. Result card: `BudgetGoalLinkCard` + `BudgetTotalHeader` share-ready; template preview card.
9. Privacy/audit: limits are user data (synced repo); create/update/delete should write the money audit log like other Money writes.
10. Reviewer: pending BUDGET REVIEWER.

## Self-grade: engine (rollup/rollover/template/insights/plan/goal) + screen = advanced. Confirmed: spent-vs-budget from real transactions · integer poisha, no float drift · over-budget alerts (state=over, over_by, red bar). PENDING BUDGET REVIEWER.
