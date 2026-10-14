# Family Accounting — BASIC→ADVANCED integration note (#61, SPEC v2.1 §21)

Shared family money: who-paid-what, split expenses among family/circle members,
a family budget pool with contributions, settle-up ("Dad owes Mom ৳500"), shared
bills (rent/utilities/groceries), per-member view, monthly family summary,
shared-only privacy. **Integer poisha end to end — no float drift.**

## Files (what this build added / touched)

| File | Role |
|---|---|
| `backend/core/logic/famacct_engine.py` | **NEW.** Pure, integer-poisha math: `to_poisha`/`fmt_poisha`, `split_equal`/`split_shares`/`split_exact`, `shared_expense`, `net_balances`/`settle_up`/`settle_message`, `pool_status`, `member_view`/`monthly_summary`, `visible_to_member`/`filter_shared` (privacy). No Django, no AI key. |
| `backend/core/logic/famacct_tests_snippets.py` | **NEW.** 15 plain-assert tests (fold into `core/tests.py` as `FamAcctSnippetTests`). `run_all()` → `famacct: 15 tests passed`. |
| `app/lib/famacct_api.dart` | **NEW extension** on `ApiClient` (built only on getJson/postJson — api.dart untouched) + `FamAcctLocal` (on-device poisha mirror). |
| `app/lib/widgets/famacct_strings.dart` | **NEW.** Bilingual `_faStrings` table (Bangla as `\u` escapes), `faStr`/`faStrS`. Mirrors `up_famacct_arb.json`. |
| `app/lib/widgets/famacct_section.dart` | **NEW.** The whole section as ONE self-contained widget (4 sub-tabs: Expenses / Settle up / Pool / Per member). |
| `app/lib/widgets/famacct_sheets.dart` | **NEW.** Add-expense dialog, amount sheet, member picker. |
| `app/lib/screens/family_screen.dart` | **EDIT (isolated, 4 lines):** 2 imports; tab length 6→7; one `Tab`; one `TabBarView` child `FamAcctSection(members: members)`. Nothing else in the screen changed — D6 can extend it without collision. |

ARB: do **not** edit `app_*.arb` in this build — merge `up_famacct_arb.json`
(48 keys) at the next sync, then `flutter gen-l10n`.

## Reuse (no new stores)

- **Family / Connected-Circle contacts are READ, not redefined.** The section
  receives the SAME `members` list `FamilyScreen` already loads via
  `api.listItems('family')`; participants are `'self'` + those member ids. No
  new contact model, no duplicate picker. The backend engine takes member ids
  as opaque keys, so the circle graph (`core/logic/circle.py`) is the source of
  truth for who exists.
- **Money logic style reused:** the engine mirrors `money_engine.py`'s pure,
  dict-in/dict-out, deterministic design (and its split-residue discipline),
  but switches the unit to **integer poisha** instead of `Decimal` taka so a
  family ledger can never drift by a paisa.

## No float / no drift (the hard invariant)

- Every amount in and out of `famacct_engine` and `FamAcctLocal` is an **int of
  poisha** (1 taka = 100 poisha). User input is parsed from the decimal STRING
  (`to_poisha` / `takaToPoisha`), half-up on the paisa — binary-float noise
  never enters. Tested: `to_poisha("0.10")+to_poisha("0.20")==to_poisha("0.30")`.
- **Equal split** hands the remainder poisha one-each to the first members;
  **shares split** uses the largest-remainder method. Both sum EXACTLY to the
  input (tested). **Net balances sum to 0**; **settle-up** reconciles exactly
  and uses ≤ n−1 transfers (greedy largest-first).

## Split + settle-up (the advanced core)

- `shared_expense(payer, total, members, mode)` → `{shares, debts}`; debts
  exclude the payer (you don't owe yourself).
- `settle_up(expenses)` collapses many expenses into minimal "X pays Y ৳Z"
  transfers; `settle_message` renders the bilingual "Dad owes Mom ৳500" line.
- The Dart section carries the SAME settle-up greedy algorithm so the offline
  compute path produces identical transfers.

## Privacy — members see SHARED only

`visible_to_member` / `filter_shared`: a member sees an expense only if it is a
shared family item **and** they participate (payer or in the split). Private
items (`shared=False`) are visible to their owner alone. The summary/expenses
endpoints MUST filter through this server-side before serializing (the Dart
layer assumes it already has).

## Honest states (§21 #4)

loading (skeleton) · per-sub-tab empty (with CTA) · error → on-device compute
fallback with a visible **offline banner** · settle-up empty shows "All settled
up" (success tint), NOT a fake ৳0 · per-member net shows "Settled" when 0 rather
than a misleading number · AI-captured chip on auto entries.

## Endpoints the integrator must build (none exist yet)

All under `/api/v1/family/accounting/` (see `famacct_api.dart` docstrings for
exact shapes). Money fields are integer poisha.

| Method · Path | Returns |
|---|---|
| GET `summary?month=` | `{total_poisha, by_category, members:[{member,name,paid_poisha,share_poisha,net_poisha}], settlements:[{from,to,amount_poisha,message{bn,en}}], pool{…}}` (shared-only) |
| GET `expenses?month=` | `{expenses:[{id,payer,payer_name,total_poisha,category,mode,note,date,shares:[{member,name,share_poisha}],ai_captured}]}` |
| POST `expenses` | create; body `{payer,total_poisha,category,note,mode,members|parts,shared}` → the computed expense |
| POST `expenses/delete` | `{id}` → `{ok}` |
| GET `pool?month=` / POST `pool` `{target_poisha}` | the pool block |
| POST `pool/contribute` `{member,amount_poisha}` | updated pool |
| POST `settle` `{from,to,amount_poisha}` | record a transfer as paid → `{ok}` |

Suggested storage: a `FamilyExpense` (+ `FamilyExpenseShare`) and `FamilyPool`
(+ `FamilyPoolContribution`) model keyed to the owner's circle; the view layer
feeds rows to `famacct_engine` and returns what it computes. Wire the add-expense
action into reminders + watch feed + chat ("split 900 taka dinner 3 ways") and
the audit log (§21 #6, #9) when the endpoints land.

## §21 ten-point coverage

1. **Parity+** — split + minimal settle-up (Splitwise-class) folded into the
   family hub, bilingual, poisha-exact.
2. **Full flow** — create / delete expense, set pool target / contribute,
   mark-settled, per-member + monthly views (edit/search/export are the next
   pass; endpoints emitted).
3. **Both rails** — manual add dialog now; `ai_captured` marker wired for the
   auto rail (chat "split …" → endpoint).
4. **States** — loading / empty / error / offline all designed (above).
5. **bn/en, light/dark, sizes** — all copy via `faStr`; scrollable tabs,
   Theme colors, no hard-coded light assumptions.
6. **Reminders/watch/chat/voice** — hooks noted; needs the endpoints.
7. **Tests** — 15 server snippet tests pass now; app widget/scenario tests to
   follow with the live endpoints.
8. **Share/result card** — settle-up line ("Dad owes Mom ৳500") is the result
   card seed.
9. **Privacy+audit** — shared-only gate enforced in the engine; audit on write
   when endpoints land.
10. **Independent reviewer** — pending (owner gate).

## Tests

```
cd backend && python3 -c "import core.logic.famacct_tests_snippets as t; t.run_all()"
# -> famacct: 15 tests passed
```
