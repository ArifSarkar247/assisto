import '../api.dart';

/// fcelder — Silent Watch + Elder setup endpoints
/// (backend/core/views_silent_watch.py) on the generic getJson / postJson
/// helpers. An interface so widget tests and the screenshot gallery use a
/// fake server.
abstract class SilentWatchApi {
  Future<Map<String, dynamic>> status();
  Future<Map<String, dynamic>> setConfig(Map<String, dynamic> body);
  Future<String?> newToken();
  Future<void> ok();
  Future<Map<String, dynamic>> ack(int alertId);
  Future<Map<String, dynamic>> test(int elderId);
  Future<Map<String, dynamic>> startSetup(Map<String, dynamic> body);
  Future<Map<String, dynamic>> previewSetup(String code);
  Future<Map<String, dynamic>> acceptSetup(String code);

  /// Family members the child can pick (one tap; Care Call's people list =
  /// accepted My Circle family).
  Future<List<Map<String, dynamic>>> people();
}

class HttpSilentWatchApi implements SilentWatchApi {
  HttpSilentWatchApi(this.c);
  final ApiClient c;

  @override
  Future<Map<String, dynamic>> status() => c.getJson('/family/silent-watch');

  @override
  Future<Map<String, dynamic>> setConfig(Map<String, dynamic> body) =>
      c.postJson('/family/silent-watch', body);

  @override
  Future<String?> newToken() async {
    final r = await c.postJson('/family/silent-watch/token');
    final t = r['token'];
    return t is String && t.isNotEmpty ? t : null;
  }

  @override
  Future<void> ok() async {
    await c.postJson('/family/silent-watch/ok');
  }

  @override
  Future<Map<String, dynamic>> ack(int alertId) =>
      c.postJson('/family/silent-watch/alerts/$alertId/ack');

  @override
  Future<Map<String, dynamic>> test(int elderId) =>
      c.postJson('/family/silent-watch/test', {'elder_user_id': elderId});

  @override
  Future<Map<String, dynamic>> startSetup(Map<String, dynamic> body) =>
      c.postJson('/family/elder-setup', body);

  @override
  Future<Map<String, dynamic>> previewSetup(String code) =>
      c.getJson('/family/elder-setup/${Uri.encodeComponent(code)}');

  @override
  Future<Map<String, dynamic>> acceptSetup(String code) =>
      c.postJson('/family/elder-setup/${Uri.encodeComponent(code)}/accept', {'yes': true});

  @override
  Future<List<Map<String, dynamic>>> people() async {
    final r = await c.getJson('/carecall/people');
    return [
      for (final x in (r['results'] as List? ?? const []))
        Map<String, dynamic>.from(x as Map)
    ];
  }
}
