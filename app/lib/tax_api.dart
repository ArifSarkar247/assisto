import 'api.dart';

/// Assisto #60 — Tax & Zakat (SPEC v2.1 §21 ADVANCED).
///
/// Implemented as an EXTENSION on [ApiClient] so this module ships WITHOUT
/// editing the shared api.dart. It reuses the EXISTING `/finance` tool endpoint
/// (ApiClient.finance), which already routes a `tool` string to a pure
/// server-side calculator in `backend/core/finance.py`.
///
/// IMPORTANT — the MoneyTax screen computes 100% CLIENT-SIDE and offline via
/// `widgets/tax_calc.dart` (mirroring `backend/core/logic/tax_zakat.py`), so the
/// estimator works with NO network and NO AI key. These server calls are an
/// OPTIONAL parity path for a future AI/voice flow. They are LIVE only once the
/// integrator wires the new `estimate_income_tax` / `zakat_full` / `zakat_nisab`
/// tools into `FinanceView.post` (core/views.py) — the backend logic already
/// exists in `core/logic/tax_zakat.py`; FinanceView just needs three extra
/// `if tool == ...` branches delegating to it. Until then the screen uses the
/// local calc and never calls these.
///
/// Rates/thresholds are PUBLISHED NBR figures (source-noted in tax_zakat); the
/// server returns identical integer-poisha numbers to the client math. Bullion
/// prices and amounts are user inputs — never guessed.
extension TaxZakatApi on ApiClient {
  /// POST /finance {tool:"tax_estimate", ...} — income-tax estimate.
  /// Returns gross_tax, rebate, tax_after_rebate, minimum_tax, net_tax,
  /// payable/refund, bands[], source, estimate:true. NOT tax advice.
  Future<Map<String, dynamic>> taxEstimate({
    required num taxableIncome,
    String year = '2025-2026',
    String category = 'general',
    num eligibleInvestment = 0,
    num tdsPaid = 0,
    String location = 'dhaka_ctg',
    bool extraDisabledDependent = false,
  }) =>
      finance('tax_estimate', {
        'taxable_income': taxableIncome,
        'year': year,
        'category': category,
        'eligible_investment': eligibleInvestment,
        'tds_paid': tdsPaid,
        'location': location,
        'extra_disabled_dependent': extraDisabledDependent,
      });

  /// POST /finance {tool:"zakat_nisab", ...} — nisab from USER-entered per-gram
  /// gold/silver prices (never guessed). Returns gold_nisab, silver_nisab,
  /// lower_nisab and the fixed gram weights.
  Future<Map<String, dynamic>> zakatNisab({
    num goldPricePerGram = 0,
    num silverPricePerGram = 0,
  }) =>
      finance('zakat_nisab', {
        'gold_price_per_gram': goldPricePerGram,
        'silver_price_per_gram': silverPricePerGram,
      });

  /// POST /finance {tool:"zakat_full", ...} — 2.5% of net zakatable wealth,
  /// only at/above nisab. All asset values + nisab are user inputs.
  Future<Map<String, dynamic>> zakatFull({
    num cash = 0,
    num bank = 0,
    num goldValue = 0,
    num silverValue = 0,
    num investments = 0,
    num businessGoods = 0,
    num moneyLent = 0,
    num debts = 0,
    num nisab = 0,
  }) =>
      finance('zakat_full', {
        'cash': cash,
        'bank': bank,
        'gold_value': goldValue,
        'silver_value': silverValue,
        'investments': investments,
        'business_goods': businessGoods,
        'money_lent': moneyLent,
        'debts': debts,
        'nisab': nisab,
      });
}
