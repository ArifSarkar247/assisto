import 'api.dart';

/// Assisto P15 — "About the Assisto name" (name / trademark research note).
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public
/// `getJson` helper, so this module ships WITHOUT editing the shared api.dart.
/// The integrator SHOULD later fold this into ApiClient proper — the path
/// below is authoritative and matches the backend route style (NO trailing
/// slash, see `backend/core/urls.py` -> `path("name/about", ...)`).
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en`, so the
/// backend returns bn/en-aware text (meaning / notes / checklist / status /
/// disclaimer) for the selected locale.
extension NameAboutApi on ApiClient {
  /// GET /name/about
  /// ->
  /// {
  ///   "name": "Assisto",
  ///   "meaning": String,
  ///   "classes": [{"class": int, "note": String}, ...],
  ///   "checklist": [String, ...],
  ///   "status": String,
  ///   "disclaimer": String   // informational only, NOT legal clearance
  /// }
  ///
  /// This surface reports what the owner must still check — it NEVER claims the
  /// name is cleared. The returned `disclaimer` is advisory; the UI also shows
  /// its own bilingual legal-clearance warning regardless of the payload.
  Future<Map<String, dynamic>> nameAbout() => getJson('/name/about');
}
