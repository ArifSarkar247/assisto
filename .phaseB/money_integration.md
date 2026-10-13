# Money module — integrator TODO (agent a8ca5f4e)

Owned files already in tree: app/lib/screens/money_screen.dart (rebuilt), money_common.dart, money_trends_screen.dart, money_networth_screen.dart, money_loan_detail_screen.dart, money_budget_screen.dart, money_import_screen.dart, money_report_screen.dart; backend/core/logic/money_parse.py, money_engine.py, money_tests_snippets.py (23 asserts, pass).

## ARB: apply .phaseB/money_arb.json to both app_*.arb (53 keys). Placeholder @-metadata (type Object): moneyImportSelected{count}, moneyImported{count}, moneyLoanBalanceLabel{amount}, moneyLoanPaidOf{paid,total}, moneyReportFor{month}, moneyVsLastMonth{amount}.

## api.dart add:
- moneyTrends() GET /money/trends
- moneyNetWorth() GET /money/networth
- moneyBudgetDetail(category) GET /money/budget?category=
- moneyReport() GET /money/report
- moneyParse(text) POST /money/parse {text}
- moneyLearnCategory(counterparty,category) POST /money/learn-category
(reuse moneySummary(), getBytes for /money/report.pdf|.xlsx)

## MIGRATION (core):
- NEW CategoryCorrection: user FK CASCADE related_name=category_corrections; key Char(120); category Char(60); updated_at auto_now; unique_together (user,key).
- Budget += rollover Bool default False.
- Loan += repayments JSON default list blank; paid Decimal(14,2) default 0.
- Transaction += ref Char(40) blank; split_with JSON default list blank; split_mode Char(10) blank. (source already supports "notification")
- OPTIONAL RecurringRule {user, account FK, kind, amount, category, freq(daily|weekly|monthly), interval int, day_of_month int null, weekday int null, start date, last_generated date null} — engine generate_recurring ready; UI editor deferred.

## Endpoints (views.py+urls.py), all req_lang + money_engine.category_label(slug,lang):
- GET /money/trends -> month_over_month(txns,6) + category_trends(txns,current)['categories']
- GET /money/networth -> net_worth(accounts,loans) + net_worth_series (per-month)
- GET /money/budget?category -> budget_with_rollover(cat, limit, spend_by_month, ordered_months, rollover)
- GET /money/report -> monthly_report(txns,current,budgets)
- GET /money/report.pdf + .xlsx -> render monthly_report (reuse doctor-pdf export plumbing)
- POST /money/parse {text} -> parse_batch + dedupe(seen refs) -> mark duplicate; Decimals->str
- POST /money/learn-category {counterparty,category} -> learn_correction(..., user)

## fake_api.dart: add overrides moneyTrends/moneyNetWorth/moneyBudgetDetail/moneyReport/moneyParse/moneyLearnCategory (sample data, _bn aware) — see agent report for bodies.

## Self-grade: parser/categoryguesser/split/loans/budgets-rollover/trends = advanced; recurring = good (no UI editor); report = good→advanced (needs export wiring). Pending MONEY REVIEWER.
