import 'api.dart';

/// ledger (owner Part 1 f) — Business Accounting books. Built only on the
/// generic getJson / postJsonRaw helpers (no api.dart edit). Server:
/// backend/core/ledger_views.py, prefix `business/books/`, flag
/// `accounting_v2` (OFF), owner only. Money is integer poisha.
extension BooksApi on ApiClient {
  static String _p(String path, int? businessId, [Map<String, String> extra = const {}]) {
    final q = <String, String>{
      if (businessId != null && businessId > 0) 'business': '$businessId',
      ...extra,
    };
    return q.isEmpty ? path : Uri(path: path, queryParameters: q).toString();
  }

  Future<Map<String, dynamic>> booksProfitLoss(int? businessId,
          {required String from, required String to}) =>
      getJson(_p('/business/books/profit-loss', businessId, {'from': from, 'to': to}));

  Future<Map<String, dynamic>> booksBalanceSheet(int? businessId) =>
      getJson(_p('/business/books/balance-sheet', businessId));

  Future<Map<String, dynamic>> booksTrialBalance(int? businessId) =>
      getJson(_p('/business/books/trial-balance', businessId));

  /// Never throws on a 4xx: the body carries `_status`.
  Future<Map<String, dynamic>> booksSync(int? businessId) => postJsonRaw(
      '/business/books/sync',
      {if (businessId != null && businessId > 0) 'business': businessId});
}
