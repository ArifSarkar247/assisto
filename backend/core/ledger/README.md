# Ledger (Business Accounting) — API contract

Owner: agent **ledger** (core, branch `agent/ledger-acct`). UI: agent **acctui**.
Flag: `accounting_v2` (default OFF). Every endpoint answers
`403 {"error":"feature_off"}` while the flag is off for the caller, and
`403 {"error":"staff_restricted"}` for staff (books are OWNER ONLY).

Code: pure rules `core/logic/ledger.py` · DB layer `core/ledger_service.py` ·
views `core/ledger_views.py` · tests `core/tests_ledger.py` · migration `0130_ledger`.

## Conventions
* Prefix `/api/v1/business/books/`. Token auth. `?business=<id>` (or body
  `business`) picks the shop, like every `business/*` endpoint.
* **Money = integer poisha** (৳1 = 100). Dates = `YYYY-MM-DD` (Asia/Dhaka).
* Names come back already in the request language (`Accept-Language: bn|en`)
  as `name`; memos as `memo`. The app formats digits (Bangla in bn).
* Errors: `{"error": <code>, "detail": <localised text>}` with 400/403/404/409.
* Every report payload carries `book` = `{start_date, lock_date, last_sync_at,
  opening_inventory, warning: {bn,en}|null}`.
* Report GETs **sync first** (at most once per 30 s): new / changed / deleted
  source rows are posted / reversed automatically. Nothing is ever edited or
  deleted in the journal: a change = a reversal entry + a new entry.

## Sources posted automatically (idempotent, one live entry per source)
| source_key | from | posting |
|---|---|---|
| `sale:<id>` | POS `Sale` | Dr cash/bKash/Nagad (total−due), Dr receivable (due), Dr discounts; Cr sales (gross); Dr COGS / Cr inventory (Σ qty×cost). If VAT is on (invoice settings, from `book.vat_since`), the VAT-inclusive part goes to Cr output VAT 2100 |
| `salevoid:<id>` | voided Sale | exact mirror of `sale:<id>` on the void day |
| `khata:<id>` | `KhataEntry` | customer gave = Dr receivable / Cr sales-khata; customer got = Dr cash / Cr receivable; supplier got (purchase on credit) = Dr inventory / Cr payable; supplier gave = Dr payable / Cr cash. Bridge rows `[sale#N]` / `[void-sale#N]` are SKIPPED (no double count) |
| `expense:<id>` | `Expense` | Dr expense account (by category, bn/en keywords) / Cr cash |
| `cash:<id>` | manual cashbox row | Dr/Cr cash vs 2900 suspense (unclassified) |
| `invoice:<id>` | manual invoice (`PaCollectionItem` `biz_invoices`, agent/invoices) | Dr cash (paid) + receivable (due) + discounts; Cr service/sales income, output VAT 2100, SD 2110. Cancelled = reversed. POS-sale invoices are NOT posted again (the sale already is) |
| `opening:inventory` | first sync | reconstructed stock at start: stock×cost now + COGS since − purchases since (frozen) |
| `opening:balances` | `POST opening` | the owner's opening balances (cash, bKash, Nagad, bank, stock, receivables, payables, loans) vs opening-balance equity |
| `manual:<n>` | `POST journal` | owner's own entry (capital, drawings, loan, asset) — never touched by sync |

**Posting hook for other modules** (invoices, purchases…): call
`core.ledger_service.notify_change(business)` after you write a source row.
It is a no-op when the flag is off, never raises, and is idempotent (it only
syncs) — so calling it twice can never double-post.

## Endpoints

### GET `accounts`
`{accounts: [{code, type: asset|liability|equity|income|expense, group, name, contra, balance}], book}`
`balance` = debit − credit (poisha). Chart: BD SME, ~37 accounts (1010 cash,
1020 bKash, 1030 Nagad, 1040 bank, 1100 receivable, 1200 inventory, 1310 input
VAT, 1500 equipment, 2010 payable, 2100 output VAT, 2110 SD, 2300 loans, 2900
suspense, 3010 capital, 3020 drawings, 3030 opening equity, 3100 retained,
4010 POS sales, 4020 khata sales, 4030 service income, 4050 discounts, 4100
other income, 5010 COGS, 60xx expenses).

### GET `journal?from=&to=&page=&source=`
`{entries: [{id, number, date, status: posted|reversed|reversal, source, late,
memo, total, reversal_of, created_at, created_by, lines: [{code, name, debit,
credit, party}]}], page, has_more}` — 50 per page, newest first.

### POST `journal` (owner's manual entry)
Body `{date, memo, lines: [{code, debit, credit, party?}]}` → 201 the entry.
400 `unbalanced` (Σdebit ≠ Σcredit), `bad_account`, `bad_date`; 409 `locked`
when `date` ≤ lock date.
### POST `journal/<id>/reverse` `{reason}` → 201 the reversal entry.
409 `already_reversed`; manual and automatic entries both (automatic ones
re-post on the next sync if their source still exists — use for corrections of
manual entries).

### GET / POST `opening`
GET → `{opening: {date, cash, bkash, nagad, bank, inventory|null, receivables:
[{party, amount}], payables: [{party, amount}], loans}, book}`.
POST same shape (all poisha, ≥ 0) → re-posts `opening:balances` (reversal +
new when changed). `inventory` given = replaces the reconstructed opening stock.

### POST `expense` (the simple screen's "expense" button)
Body `{amount, category, note?, date?}` (poisha, date default today) → 201
`{id, amount, category, note, date, account: {code, name}}`; creates a real
`Expense` row (so the old business reports see it too) and posts it.
400 `amount` (≤ 0) / `bad_date`; 409 `locked`. Sale = existing
`business/sales/checkout`; purchase / due / payment = existing khata endpoints
(`business/khata/parties/<id>/entries`, `/payment`) — all post automatically.

### POST `sync` → `{posted, reversed, unchanged, book}`
### POST `lock` `{lock_date: "YYYY-MM-DD" | null}` → `{book}`
Closes the books up to that day (inclusive). 400 `future_lock` (≥ today),
`bad_date`. Audited (`AuditLog ledger.lock`). Later changes to locked-period
sources post on the first open day (`late: true`).

### GET `trial-balance?as_of=`
`{as_of, rows: [{code, name, type, group, debit, credit}], total_debit, total_credit, balanced, book}`

### GET `profit-loss?from=&to=` (default: this month)
`{from, to, sales: [row], gross_sales, discounts: [row], discounts_total,
net_sales, cogs: [row], cogs_total, gross_profit, gross_margin_pct|null,
operating_expenses: [row], operating_expenses_total, other_income: [row],
other_income_total, net_profit, book}` — `row = {code, name, type, group, amount}`.

### GET `balance-sheet?as_of=`
`{as_of, assets: [row], total_assets, liabilities: [row], total_liabilities,
equity: [row], profit_to_date, total_equity, total_liabilities_equity, balanced,
catalog_stock_value, book}` — `catalog_stock_value` = Σ stock × cost in the
catalog now (compare with inventory 1200: the gap = stock to count/adjust).

### GET `cash-flow?from=&to=` (indirect method, IAS 7)
`{from, to, net_profit, adjustments: [{key, name, amount}], operating,
investing: [row], investing_total, financing: [row], financing_total,
net_change, opening_cash, closing_cash, reconciles, book}` — cash = 1010 +
1020 + 1030 + 1040. `reconciles` = opening + net_change == closing.

### GET `vat?from=&to=` (VAT summary — supports Mushak-9.1, NOT a filing)
`{from, to, output_vat, output_sd, input_vat, net_payable, sales_taxable,
register: [{number, date, buyer, buyer_bin, taxable, sd, vat, total,
source: invoice|sale}], vat_ready, vat_periods: [{from, to|null, vat_bp, sd_bp}], book}`
ledger2 ADDED: `paid` (VAT deposited to NBR — an entry whose only non-money
lines are 2100/2110), `still_due` = net_payable − paid, `taxable_sales`,
`taxable_purchases`, `sale_invoices`, `purchase_bills`, `exempt_sales`,
`purchase_register: [{date, supplier, supplier_bin, bill_no, value, vat, total,
on_credit}]` (Mushak-6.1 data from purchase entries), register rows `exempt`.
FIXED: `output_vat` no longer has VAT paid subtracted (it was netted before).
`business/acct/vat` returns the same numbers (alias). — `register` is the Mushak-6.2
style sales register built from invoices (Mushak-6.3 data). Rates come from the
shop's invoice settings, never hard-coded. Legal basis: VAT & SD Act 2012 and
VAT & SD Rules 2016 (NBR, nbr.gov.bd / vat.gov.bd): Mushak-6.3 tax invoice
(rule 40), 6.1 purchase / 6.2 sales register, 9.1 monthly return.

## ledger2 (phase 2)
- khata entries carry `method` (cash|bkash|nagad|bank, '' = cash for old rows);
  invoices' `payment_method` may be `bank` too.
- per-product VAT: `business/acct/vat-rates` (exempt — VAT Act 2012 First
  Schedule; reduced — rate the owner types from the Third Schedule), dated
  history; only sales on/after `from` change.
- `reclass:<cash_id>` entries (cashbox rows classified out of 2900 Suspense).
- `yearclose:<end>` entries are the owner's (sync never touches them, like
  `manual:`); P&L and cash flow leave them out, balance sheet / TB include them.

## Stability
Field names above are frozen for acctui. New fields may be ADDED; nothing is
renamed or removed without a note here.
