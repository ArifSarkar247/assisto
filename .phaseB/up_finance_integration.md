# Finance Tools — BASIC → ADVANCED upgrade (integration)

## TL;DR for the integrator
- **No new backend endpoint or API method is required.** All new calculators run
  **client-side and offline** in Dart. The only network call is the pre-existing
  `POST /finance {"tool":"net_worth"}` via the unchanged `api.finance(...)`.
- Merge `up_finance_arb.json` (**108 keys**, camelCase, `{key:[bn,en]}`) into the
  ARB sources and regenerate `AppLocalizations`.
- `backend/core/finance.py` was extended with pure functions (optional server
  parity / future AI-voice flow). `finance_tests_snippets.py` added and passing.

## Files changed / created
| File | Change |
|---|---|
| `app/lib/screens/finance_screen.dart` | **Rewritten** — tool picker (empty state) + 11 calculators |
| `app/lib/widgets/finance_common.dart` | **New** — bn-digit parse (code points), taka fmt, FinanceField/ResultCard/ResultRow/ErrorBanner, input formatter |
| `app/lib/widgets/finance_calc.dart` | **New** — pure client-side math mirroring `finance.py` |
| `backend/core/finance.py` | **Extended** — advanced pure fns (optional) |
| `backend/core/logic/finance_tests_snippets.py` | **New** — 21 asserts, `run_all()` passing |
| `.phaseB/up_finance_arb.json` | **New** — 108 ARB keys |

Not touched (per constraints): `api.dart`, `app_*.arb`, `models.py`, `urls.py`,
`views.py`, sidebar/chatnav, Asalify/crm.

## Localization
Reference pattern matches the rest of the app: `t.<camelCaseKey>`. The integrator
folds `up_finance_arb.json` through the usual `merge_arb.py` path and regenerates.
The screen also **reuses 4 existing keys** that must already exist (they do):
`netWorth`, `assets`, `receivable`, `liabilities`.

**Zero Bangla literals in `.dart`** (confirmed): Bangla digits are accepted on
input via code points `U+09E6..U+09EF`; the taka sign is `String.fromCharCode(0x09F3)`.
No glyph in the Bengali block `U+0980..U+09FF` appears in any of the three Dart files.

## What makes it ADVANCED (vs the old 4-tab basic screen)
Before: 4 fixed tabs (net worth, zakat, EMI, invest), each a flat form that
round-tripped to the server and dumped raw `৳value` rows. No validation, no
schedule, no explanation, no sharing, no empty state.

Now:
- **Tool picker / empty state** grouped by category (Loans, Savings, Planning,
  Religious, Business, Convert) with brand-gradient hero — chat-first, drawer-nav
  friendly (no bottom bar), WCAG-contrast rows, Gap/Radii/Brand tokens throughout.
- **11 calculators**, each with inputs, sensible optional-field defaults, inline
  **validation + error banner**, a result **breakdown**, and a short **bn/en
  explanation of the math** in a note chip:
  1. **EMI/loan** — reducing **and** flat rate, SegmentedButton toggle, full
     **amortization schedule** (scrollable DataTable: month/payment/principal/
     interest/balance), rounding residue absorbed into the final period so the
     balance always clears to 0.
  2. **Rate vs installment compare** — two rates, cheaper option + total savings.
  3. **DPS/savings projection** — annuity-due, monthly compounding (how BD bank
     DPS is quoted), maturity/invested/profit, flagged as an estimate.
  4. **Savings goal** — solves the monthly deposit to hit a target by a deadline
     at a given rate; detects "already reached".
  5. **Zakat** — expanded buckets (cash, bank, gold, silver, investments,
     business goods, money lent, debts) vs a user-entered nisab; 2.5% above nisab.
  6. **50-30-20 budget** — needs/wants/savings; savings is the remainder → no drift.
  7. **Can I afford this?** — free cashflow vs EMI, leftover, **income-burden %**
     with a green/amber "under 30% is comfortable" signal.
  8. **Break-even** — units before profit, revenue at that point, impossible-margin
     guard.
  9. **Simple ROI** — ROI% + profit + annualised %.
  10. **Currency/unit convert** — amount × user-entered rate (never a live rate).
  11. **Net worth** — unchanged backend compute, now with loading + **error/retry**
      state and grouped taka formatting.
- **Share** on every result (share_plus with a Clipboard + snackbar fallback).
- **No float drift**: every money output rounded to paisa (2 dp) at the boundary
  (`round2`), remainder buckets re-sum to the whole, amortization clears to zero.
  Backend side uses `Decimal`. Dart and Python produce identical hand-verified
  numbers (e.g. EMI ৳100000/12%/12mo reducing = 8884.88; flat = 9333.33; DPS
  1000/12%/12mo = 12809.33; zakat 250000 → 6250).
- **Edge cases handled**: 0% rate (straight-line), 1-month term, huge principals
  (10cr/240mo verified), overpayment/down-payment ≥ price, negative margin,
  below-nisab, income ≤ 0.

## Backend (optional, already added — pure, no DB, no AI)
`backend/core/finance.py` gained: `emi_schedule(mode=reducing|flat)`,
`rate_compare`, `dps_projection`, `goal_savings`, `budget_503020`,
`affordability`, `break_even`, `simple_roi`, `convert_amount`, `zakat_full`.
These exist for server/AI-voice parity; **the Flutter screen does not call them**.
If you later want a server tool, wire them into `FinanceView` (not required now).

Tests: `cd backend && python3 -c "import core.logic.finance_tests_snippets as t; t.run_all()"`
→ **`OK — 21 finance tests passed`** (hand-verified EMI/flat/DPS/zakat/ROI/budget/
break-even numbers, plus 0%/1-month/huge/below-nisab edge cases).

## ARB key count
**108** new camelCase keys in `up_finance_arb.json` (all `[bn, en]`, validated).
Old `financeField*` / `financeResult*` snake-derived keys from the previous screen
are now unused by this screen but left in place (other code/merge may reference
them; safe to prune later).
