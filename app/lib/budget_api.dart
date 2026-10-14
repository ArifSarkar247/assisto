import 'api.dart';

/// BUDGET module (#50) API surface — advanced per-category budgeting that
/// tracks spent-vs-budget from the user's REAL transactions.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public helpers
/// ([ApiClient.getJson] / [ApiClient.postJson]) so this ships WITHOUT editing
/// the shared api.dart core. The integrator SHOULD later fold these into
/// ApiClient proper — the signatures and paths below are authoritative.
///
/// Every "spent" figure these endpoints return is computed server-side by
/// `core/logic/budget.py` from the SAME transaction rows the money views
/// already pull (read-only reuse) — the app never fabricates spend. Money
/// crosses the wire as plain 2dp strings (integer-poisha on the server); the
/// app formats with `tkFmt` and never does float arithmetic on limits.
extension BudgetApi on ApiClient {
  /// GET /money/budget/month[?month=YYYY-MM] -> the full month view:
  /// { month, lines:[{category,limit,carried_in,effective_limit,spent,
  ///   remaining,pct,bar_pct,state,over_by,rollover}], totals:{...},
  ///   any_over, over_count, insights:[{code,category,pct,over_by}] }.
  ///
  /// `lines[*].spent` is real-transaction spend for that category+month;
  /// `state` ∈ ok|near|over|none drives the progress-bar colour + alert.
  /// Pass [month] as 'YYYY-MM' for history; omit for the current month.
  Future<Map<String, dynamic>> budgetMonth({String? month}) => getJson(
      '/money/budget/month${month == null ? '' : '?month=${Uri.encodeQueryComponent(month)}'}');

  /// GET /money/budget/history?category=<slug>&months=<n> -> one category across
  /// months with rollover carry-in/out:
  /// { category, rollover, months:[{month,...budget_line...}], carry_forward }.
  /// `months` defaults server-side (e.g. last 6). Backs the drill-down screen.
  Future<Map<String, dynamic>> budgetHistory(String category,
          {int months = 6}) =>
      getJson(
          '/money/budget/history?category=${Uri.encodeQueryComponent(category)}&months=$months');

  /// GET /money/budget/plan[?months=<n>&buffer=<pct>] -> next-month suggestions
  /// from real history: { months, buffer_pct, suggestions:[{category,
  /// avg_spent,suggested_limit}] }. The server averages real expense rows and
  /// adds a small buffer — the app only displays / applies the numbers.
  Future<Map<String, dynamic>> budgetPlan({int months = 3, int buffer = 10}) =>
      getJson('/money/budget/plan?months=$months&buffer=$buffer');

  /// GET /money/budget/template?income=<taka> -> 50-30-20 split:
  /// { income, buckets:[{bucket,percent,amount}], savings_amount }.
  /// Buckets sum EXACTLY to income (server absorbs the rounding residue).
  Future<Map<String, dynamic>> budgetTemplate(String income) => getJson(
      '/money/budget/template?income=${Uri.encodeQueryComponent(income)}');

  /// POST /money/budget { category, monthly_limit, rollover } -> created budget.
  /// Manual rail: the user sets a limit; spend is still read from real txns.
  Future<Map<String, dynamic>> budgetCreate({
    required String category,
    required String monthlyLimit,
    bool rollover = false,
  }) =>
      postJson('/money/budget', {
        'category': category,
        'monthly_limit': monthlyLimit,
        'rollover': rollover,
      });

  /// PATCH /money/budget/<id> { monthly_limit?, rollover? } -> updated budget.
  Future<Map<String, dynamic>> budgetUpdate(
    int id, {
    String? monthlyLimit,
    bool? rollover,
  }) =>
      patchJson('/money/budget/$id', {
        if (monthlyLimit != null) 'monthly_limit': monthlyLimit,
        if (rollover != null) 'rollover': rollover,
      });

  /// DELETE is modelled as POST /money/budget/<id>/delete so this extension
  /// needs no new verb on the core client. Returns {} on success.
  Future<Map<String, dynamic>> budgetDelete(int id) =>
      postJson('/money/budget/$id/delete');

  /// POST /money/budget/goal-link { } -> move this month's total underspend
  /// into the active savings goal: { contribution, new_saved, target,
  /// progress_pct, reached }. Over-budget months contribute nothing (server
  /// floors at 0). The app shows the result card; it never computes the move.
  Future<Map<String, dynamic>> budgetGoalLink() =>
      postJson('/money/budget/goal-link');
}
