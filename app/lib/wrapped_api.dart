import 'api.dart';

/// Monthly Money Wrapped — client surface for the Spotify-Wrapped-style monthly
/// money recap (feature #63, SPEC v2.1 §21). The backend computes everything
/// from the user's REAL transaction rows (read-only) via
/// [money_engine.monthly_wrapped]; it NEVER invents numbers and returns
/// `enough_data: false` for users with too little history so the screen can
/// show an honest "not enough data yet" state.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public
/// [ApiClient.getJson] helper, so this ships WITHOUT editing the shared
/// api.dart. The integrator SHOULD later fold this into ApiClient proper — the
/// path below is authoritative and matches the planned backend route
/// (`money/wrapped`, no trailing slash; see INTEGRATION NOTE in the handoff).
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en` on every
/// request, so category slugs localise server-side; the `personality` slug is
/// localised client-side (see money_wrapped_screen.dart). No extra headers.
extension WrappedApi on ApiClient {
  /// GET /money/wrapped?month=YYYY-MM  (month optional; server defaults to the
  /// most recent complete/current month).
  /// ->
  /// {
  ///   "month": "2026-09",
  ///   "previous_month": "2026-08",
  ///   "enough_data": bool,              // false => show honest empty state
  ///   "txn_count": int,
  ///   "min_txns": int,                  // only when enough_data == false
  ///   "total_earned": "30000.00",       // money as 2dp strings
  ///   "total_spent":  "16000.00",
  ///   "total_saved":  "14000.00",       // net; can be negative (overspend)
  ///   "savings_rate": 47,               // int %, 0 when no income
  ///   "top_category": "food",           // slug or null
  ///   "top_category_amount": "10000.00",
  ///   "biggest_expense": {"category": str, "amount": str, "date": "YYYY-MM-DD"} | null,
  ///   "spend_trend": {
  ///     "previous_spent": str, "delta": str, "pct": int,  // signed
  ///     "up": bool, "has_previous": bool                  // false => no honest %
  ///   },
  ///   "no_spend_days": int,
  ///   "days_in_scope": int,
  ///   "busiest_day": {"date": "YYYY-MM-DD", "amount": str} | null,
  ///   "category_count": int,
  ///   "personality": "super_saver"      // slug; localised client-side
  /// }
  Future<Map<String, dynamic>> moneyWrapped({String? month}) =>
      getJson('/money/wrapped${month != null ? '?month=$month' : ''}');
}
