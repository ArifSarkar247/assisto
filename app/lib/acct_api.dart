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

  Future<Map<String, dynamic>> acctOpening(int? businessId) =>
      getJson(_p('/business/acct/opening', businessId));

  Future<Map<String, dynamic>> acctSetOpening(
          int? businessId, Map<String, dynamic> values) =>
      postJsonRaw('/business/acct/opening', _b(businessId, values));

  Future<Map<String, dynamic>> acctCashFlow(int? businessId,
          {required String from, required String to}) =>
      getJson(_p('/business/acct/cash-flow', businessId, {'from': from, 'to': to}));

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
}
