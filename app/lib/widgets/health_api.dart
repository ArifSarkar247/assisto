import '../api.dart';

/// Phase-B Health-additions API surface: Health tips, Medicine DB, Birthdays.
///
/// Implemented as an EXTENSION on ApiClient built ONLY on its public methods
/// (getJson / postJson) so this module ships without editing the shared
/// api.dart. The integrator SHOULD later fold these into ApiClient proper — the
/// signatures and paths below are authoritative (see the module report).
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en`, so the
/// backend logic (health_tips / medicine_db / birthdays) returns bn/en text.
extension HealthApi on ApiClient {
  // ---- health tips library ----

  /// GET /health/tips[?topic=&q=] -> {topics[], tips[], disclaimer, sources[]}.
  /// Integrator returns core.logic.health_tips.library(lang, topic, query).
  Future<Map<String, dynamic>> healthTips({String? topic, String? query}) {
    final qp = <String>[];
    if (topic != null && topic.isNotEmpty) qp.add('topic=$topic');
    if (query != null && query.trim().isNotEmpty) {
      qp.add('q=${Uri.encodeQueryComponent(query.trim())}');
    }
    final suffix = qp.isEmpty ? '' : '?${qp.join('&')}';
    return getJson('/health/tips$suffix');
  }

  /// POST /health/tips/emergency {text} -> {emergency, matched[], action}.
  /// NOT a diagnosis — only decides whether to surface "call 999 / see a
  /// doctor". Integrator returns core.logic.health_tips.emergency_check(text,lang).
  Future<Map<String, dynamic>> healthEmergencyCheck(String text) =>
      postJson('/health/tips/emergency', {'text': text});

  // ---- medicine database (drug lookup) ----

  /// GET /medicine-db/search?q= -> {results[], meta{source,is_sample,...}}.
  /// Integrator returns {results: medicine_db.search(q,lang), meta: medicine_db.meta(lang)}.
  Future<Map<String, dynamic>> medicineDbSearch(String query) =>
      getJson('/medicine-db/search?q=${Uri.encodeQueryComponent(query.trim())}');

  /// GET /medicine-db/lookup?brand= -> a single localised record WITH
  /// alternatives + switch_warning (or {available:false,...} needs-data state).
  Future<Map<String, dynamic>> medicineDbLookup(String brand) =>
      getJson('/medicine-db/lookup?brand=${Uri.encodeQueryComponent(brand.trim())}');

  // ---- birthdays / memorable days ----

  /// GET /birthdays -> {upcoming[], kinds[]} (upcoming within N days).
  Future<Map<String, dynamic>> birthdaysList() => getJson('/birthdays');

  /// POST /birthdays {name, date, kind, lead_days} -> created occasion.
  Future<Map<String, dynamic>> birthdayCreate(Map<String, dynamic> body) =>
      postJson('/birthdays', body);

  /// DELETE is wired by the integrator as POST /birthdays/{id}/delete (kept to
  /// public postJson). Returns {ok:true}.
  Future<Map<String, dynamic>> birthdayDelete(int id) =>
      postJson('/birthdays/$id/delete', const {});

  /// POST /birthdays/drafts {name, kind, age?} -> {drafts[], card{title,body}}.
  /// Wish/greeting DRAFTS only — NEVER auto-sent. Integrator returns
  /// {drafts: birthdays.wish_drafts(...), card: birthdays.greeting_card(...)}.
  Future<Map<String, dynamic>> birthdayDrafts(Map<String, dynamic> body) =>
      postJson('/birthdays/drafts', body);
}
