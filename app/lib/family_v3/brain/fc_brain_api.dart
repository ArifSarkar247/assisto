import '../../api.dart';

/// fcbrain — Family Care v3 BRAIN endpoints (backend core/family_brain.py).
/// An extension on ApiClient (public getJson/postJson only), so api.dart
/// stays untouched.
///   POST /family/brain/ping        heartbeat + events from the open app
///   GET/POST /family/brain/prefs   auto arrive, leave news, night news
///   POST /family/brain/pause       {hours 1|2|8} | {resume:true}
///   GET/POST /family/brain/visibility  who can see me (+ seen)
///   POST /family/brain/leave       {family_id}
///   GET  /family/brain/night-news  tonight's card
///   POST /family/brain/ask         {q, family_id} -> {text, member_user_id, action, source}
///   GET  /family/brain/member/<id> brain + today's timeline + both clocks
///   POST /family/brain/watch       scoped token + fences for the native watch
extension FcBrainApi on ApiClient {
  Future<Map<String, dynamic>> fcbPing(Map<String, dynamic> body) =>
      postJson('/family/brain/ping', body);

  Future<Map<String, dynamic>> fcbPrefs() => getJson('/family/brain/prefs');

  Future<Map<String, dynamic>> fcbSetPrefs(Map<String, dynamic> body) =>
      postJson('/family/brain/prefs', body);

  Future<Map<String, dynamic>> fcbPause(int hours) =>
      postJson('/family/brain/pause', {'hours': hours});

  Future<Map<String, dynamic>> fcbResume() =>
      postJson('/family/brain/pause', {'resume': true});

  Future<Map<String, dynamic>> fcbVisibility() =>
      getJson('/family/brain/visibility');

  Future<Map<String, dynamic>> fcbVisibilitySeen() =>
      postJson('/family/brain/visibility', {'seen': true});

  Future<Map<String, dynamic>> fcbLeave(int familyId) =>
      postJson('/family/brain/leave', {'family_id': familyId});

  Future<Map<String, dynamic>> fcbNightNews() =>
      getJson('/family/brain/night-news');

  Future<Map<String, dynamic>> fcbAsk(String q, {int? familyId}) =>
      postJson('/family/brain/ask', {'q': q, if (familyId != null) 'family_id': familyId});

  Future<Map<String, dynamic>> fcbMember(int userId) =>
      getJson('/family/brain/member/$userId');

  Future<Map<String, dynamic>> fcbWatch() => postJson('/family/brain/watch', {});
}
