import 'api.dart';

/// Owner Analytics — client surface for the privacy-friendly product analytics
/// dashboard (launch gap P15). Backend computes everything on OUR OWN server
/// (no third-party trackers / SDKs): D1/D7/D30 cohort retention, invite funnel,
/// free -> paid conversion funnel and feature usage, all from PII-free
/// aggregate rows.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public
/// [ApiClient.getJson] helper, so this ships WITHOUT editing the shared
/// api.dart. The integrator SHOULD later fold this into ApiClient proper — the
/// path below is authoritative and matches backend/core/urls.py
/// (`analytics/dashboard`, no trailing slash).
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en` on every
/// request (set from the selected locale), so no extra header plumbing is
/// needed here.
///
/// OWNER-ONLY: the endpoint returns HTTP 403 `{"detail": "owner only"}` for
/// non-staff users. [getJson] surfaces that as an [ApiException] with
/// `status == 403`; the screen catches it and shows an owner-only state rather
/// than a generic error.
extension OwnerAnalyticsApi on ApiClient {
  /// GET /analytics/dashboard
  /// ->
  /// {
  ///   "retention": {
  ///     "d1":  {"eligible": int, "returned": int, "pct": double},
  ///     "d7":  {...},
  ///     "d30": {...},
  ///     "new_users": int
  ///   },
  ///   "invites": {"sent": int, "accepted": int, "accept_rate_pct": double},
  ///   "paid_funnel": {
  ///     "viewed": int, "started": int, "completed": int,
  ///     "view_to_start_pct": double, "start_to_paid_pct": double,
  ///     "view_to_paid_pct": double
  ///   },
  ///   "top_features": [{"feature": str, "users": int}, ...],
  ///   "total_events": int
  /// }
  ///
  /// OWNER-ONLY — 403 for non-staff (see extension docstring).
  Future<Map<String, dynamic>> ownerAnalyticsDashboard() =>
      getJson('/analytics/dashboard');
}
