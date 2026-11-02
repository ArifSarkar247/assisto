import 'api.dart';

/// acctui — the accounting UI's own endpoints (backend/core/ledger_entry_views.py,
/// prefix `business/acct/`, flag `accounting_v2`, owner only). Built only on
/// the generic getJson / postJsonRaw helpers (no api.dart edit). The reports
/// the core already serves (P&L, balance sheet, trial balance) come from
/// books_api.dart. Money is integer poisha.
extension AcctApi on ApiClient {
  static String _p(String path, int? businessId,
      [Map<String, String> extra = const {}]) {
    final q = <String, String>{
      if (businessId != null && businessId > 0) 'business': '$businessId',
      ...extra,
    };
    return q.isEmpty ? path : Uri(path: path, queryParameters: q).toString();
  }

  Map<String, dynamic> _b(int? businessId, Map<String, dynamic> body) => {
        if (businessId != null && businessId > 0) 'business': businessId,
        ...body,
      };

  Future<Map<String, dynamic>> acctEntries(int? businessId, {int? before}) =>
      getJson(_p('/business/acct/entries', businessId,
          {if (before != null) 'before': '$before'}));

  /// Never throws on a 4xx: the body carries `_status` (a network failure
  /// still throws — the caller queues the entry offline).
  Future<Map<String, dynamic>> acctCreateEntry(
          int? businessId, Map<String, dynamic> entry) =>
      postJsonRaw('/business/acct/entries', _b(businessId, entry));

  Future<Map<String, dynamic>> acctVoidEntry(
          int? businessId, String clientId, String reason) =>
      postJsonRaw('/business/acct/entries/$clientId/void',
          _b(businessId, {'reason': reason}));

  /// The opening wizard's hints: khata dues (already in the books), the
  /// books' start / lock day, the reconstructed opening stock, shop name.
  Future<Map<String, dynamic>> acctHints(int? businessId) =>
      getJson(_p('/business/acct/hints', businessId));

  /// The CORE's opening balances (backend/core/ledger/README.md):
  /// {opening: {date, cash, bkash, nagad, bank, inventory|null,
  /// receivables: [{party, amount}], payables: [...], loans} | null, book}.
  Future<Map<String, dynamic>> booksOpening(int? businessId) =>
      getJson(_p('/business/books/opening', businessId));

  Future<Map<String, dynamic>> booksSetOpening(
          int? businessId, Map<String, dynamic> opening) =>
      postJsonRaw('/business/books/opening', _b(businessId, opening));

  /// The CORE's cash flow (indirect, IAS 7; `reconciles`).
  Future<Map<String, dynamic>> booksCashFlow(int? businessId,
          {required String from, required String to}) =>
      getJson(_p('/business/books/cash-flow', businessId, {'from': from, 'to': to}));

  /// The CORE's VAT summary + Mushak-6.2-style sales register.
  Future<Map<String, dynamic>> booksVat(int? businessId,
          {required String from, required String to}) =>
      getJson(_p('/business/books/vat', businessId, {'from': from, 'to': to}));

  /// acctui VAT detail: VAT paid to NBR kept apart, invoice / bill counts.
  Future<Map<String, dynamic>> acctVat(int? businessId,
          {required String from, required String to}) =>
      getJson(_p('/business/acct/vat', businessId, {'from': from, 'to': to}));

  Future<Map<String, dynamic>> acctAudit(int? businessId, {int page = 1}) =>
      getJson(_p('/business/acct/audit', businessId, {'page': '$page'}));

  Future<Map<String, dynamic>> acctLock(
          int? businessId, String? lockDate, {String reason = ''}) =>
      postJsonRaw('/business/acct/lock',
          _b(businessId, {'lock_date': lockDate, 'reason': reason}));

  Future<Map<String, dynamic>> acctExportLog(int? businessId, String what) =>
      postJsonRaw('/business/acct/export-log', _b(businessId, {'what': what}));

  /// Trial balance / balance sheet as of a day (the core endpoints take
  /// `as_of`; books_api.dart only asks for today).
  Future<Map<String, dynamic>> acctTrialBalanceAsOf(int? businessId, String asOf) =>
      getJson(_p('/business/books/trial-balance', businessId, {'as_of': asOf}));

  Future<Map<String, dynamic>> acctBalanceSheetAsOf(int? businessId, String asOf) =>
      getJson(_p('/business/books/balance-sheet', businessId, {'as_of': asOf}));

  /// The core journal (50 entries a page, newest first) for the export.
  Future<Map<String, dynamic>> acctJournal(int? businessId,
          {required String from, required String to, int page = 1}) =>
      getJson(_p('/business/books/journal', businessId,
          {'from': from, 'to': to, 'page': '$page'}));

  // ------------------------------------------------------------ ledger2
  /// Manual cashbox rows + what each really was (reclass out of Suspense):
  /// {rows: [{id, date, kind in|out, amount, note, code, name}],
  /// unclassified, unclassified_amount, choices: {in: [...], out: [...]}}.
  Future<Map<String, dynamic>> acctCashbox(int? businessId) =>
      getJson(_p('/business/acct/cashbox', businessId));

  /// code '' clears the choice. Never throws on 4xx (`_status`).
  Future<Map<String, dynamic>> acctClassifyCash(int? businessId, int cashId, String code) =>
      postJsonRaw('/business/acct/cashbox/$cashId/classify', _b(businessId, {'code': code}));

  /// {shop_vat_bp, shop_sd_bp, vat_seller, custom, products: [{product_id,
  /// name, category, mode standard|exempt|reduced, vat_bp, note, since}]}.
  Future<Map<String, dynamic>> acctVatRates(int? businessId, {String q = ''}) =>
      getJson(_p('/business/acct/vat-rates', businessId, {if (q.isNotEmpty) 'q': q}));

  Future<Map<String, dynamic>> acctSetVatRate(int? businessId, Map<String, dynamic> body) =>
      postJsonRaw('/business/acct/vat-rates', _b(businessId, body));

  /// {closes: [{end, number, status, total}], suggestions: [{end, kind}], book}.
  Future<Map<String, dynamic>> acctYearCloses(int? businessId) =>
      getJson(_p('/business/acct/year-close', businessId));

  Future<Map<String, dynamic>> acctCloseYear(int? businessId, String end) =>
      postJsonRaw('/business/acct/year-close', _b(businessId, {'end': end}));

  Future<Map<String, dynamic>> acctReopenYear(int? businessId, String end, String reason) =>
      postJsonRaw('/business/acct/year-reopen', _b(businessId, {'end': end, 'reason': reason}));

  /// Sales sold with cost price 0 (profit overstated): {sales, lines,
  /// revenue, products: [{product_id, name, lines, qty, revenue, current_cost}]}.
  Future<Map<String, dynamic>> acctCostGaps(int? businessId,
          {String? from, String? to}) =>
      getJson(_p('/business/acct/cost-gaps', businessId,
          {if (from != null) 'from': from, if (to != null) 'to': to}));

  /// {product_id, cost?} — cost in poisha (optional: the catalog's is used).
  Future<Map<String, dynamic>> acctApplyCost(int? businessId, int productId, {int? cost}) =>
      postJsonRaw('/business/acct/cost-gaps/apply',
          _b(businessId, {'product_id': productId, if (cost != null) 'cost': cost}));
}
