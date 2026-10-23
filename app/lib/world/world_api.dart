import 'dart:convert';

import '../api.dart';
import '../state.dart';

/// p4-world: the Unseen World backend seam. Screens take a [WorldApi] so the
/// gallery and widget tests inject a fake (no network). Every call returns the
/// decoded JSON body with `_status` (HTTP status) merged in; network failures
/// throw and the screens show an honest error/offline state.
abstract class WorldApi {
  Future<Map<String, dynamic>> config();
  Future<Map<String, dynamic>> today();
  Future<Map<String, dynamic>> savePrefs(Map<String, dynamic> body);
  Future<Map<String, dynamic>> ask(String question, String lang);
  Future<Map<String, dynamic>> jobs();
  Future<Map<String, dynamic>> hub(String id);
  Future<Map<String, dynamic>> hubAi(String id, String question, String lang);
  Future<Map<String, dynamic>> mcq(String topic);
  Future<Map<String, dynamic>> mcqSubmit(
      String topic, List<Map<String, dynamic>> answers, String lang);
}

class ApiWorldApi implements WorldApi {
  ApiWorldApi(this.api);
  final ApiClient api;

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      return {...await api.getJson(path), '_status': 200};
    } on ApiException catch (e) {
      return {'_status': e.status ?? 500, 'ok': false};
    }
  }

  @override
  Future<Map<String, dynamic>> config() => _get('/world/config');
  @override
  Future<Map<String, dynamic>> today() => _get('/world/today');
  @override
  Future<Map<String, dynamic>> savePrefs(Map<String, dynamic> body) =>
      api.postJsonRaw('/world/prefs', body);
  @override
  Future<Map<String, dynamic>> ask(String question, String lang) =>
      api.postJsonRaw('/world/ask', {'question': question, 'lang': lang});
  @override
  Future<Map<String, dynamic>> jobs() => _get('/world/jobs');
  @override
  Future<Map<String, dynamic>> hub(String id) => _get('/world/hub/$id');
  @override
  Future<Map<String, dynamic>> hubAi(String id, String question, String lang) =>
      api.postJsonRaw('/world/hub/$id/ai', {'question': question, 'lang': lang});
  @override
  Future<Map<String, dynamic>> mcq(String topic) =>
      _get('/world/mcq?topic=${Uri.encodeQueryComponent(topic)}');
  @override
  Future<Map<String, dynamic>> mcqSubmit(
          String topic, List<Map<String, dynamic>> answers, String lang) =>
      api.postJsonRaw(
          '/world/mcq', {'topic': topic, 'answers': answers, 'lang': lang});
}

/// Tiny write-through cache so hubs and Today open offline with the last copy
/// (labelled as such by the screens). Never fabricates: null when never saved.
class WorldCache {
  WorldCache._();
  static String _k(String id, String lang) => 'world_cache_v1_${id}_$lang';

  static Future<void> save(String id, String lang, Map<String, dynamic> j) async {
    try {
      final copy = Map<String, dynamic>.from(j)..remove('_status');
      await Settings.setString(_k(id, lang), jsonEncode(copy));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> read(String id, String lang) async {
    try {
      final raw = await Settings.getString(_k(id, lang));
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }
}

int worldStatus(Map<String, dynamic> j) =>
    j['_status'] is num ? (j['_status'] as num).toInt() : 200;

List<Map<String, dynamic>> worldList(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

Map<String, dynamic> worldMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};
