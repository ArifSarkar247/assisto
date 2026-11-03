import '../../api.dart';

/// mktengine — Marketing Engine v1: every server call behind one seam so the
/// widget tests / screenshot gallery inject a fake. Shapes mirror
/// backend/core/views_mktengine.py.
abstract class MktSource {
  Future<Map<String, dynamic>> overview();
  Future<Map<String, dynamic>> saveAnswers(Map<String, dynamic> answers, {bool partial = false});
  Future<Map<String, dynamic>> generate();
  Future<Map<String, dynamic>> editItem(String id, Map<String, dynamic> body);
  Future<Map<String, dynamic>> polish(String id);
  Future<Map<String, dynamic>> activate(String id);
  Future<Map<String, dynamic>> publish(String id);
}

class ApiMktSource implements MktSource {
  final ApiClient api;
  ApiMktSource(this.api);

  @override
  Future<Map<String, dynamic>> overview() => api.getJson('/mkt');
  @override
  Future<Map<String, dynamic>> saveAnswers(Map<String, dynamic> answers, {bool partial = false}) =>
      api.postJson('/mkt/profile', {'answers': answers, 'partial': partial});
  @override
  Future<Map<String, dynamic>> generate() => api.postJson('/mkt/generate');
  @override
  Future<Map<String, dynamic>> editItem(String id, Map<String, dynamic> body) =>
      api.patchJson('/mkt/items/$id', body);
  @override
  Future<Map<String, dynamic>> polish(String id) => api.postJson('/mkt/items/$id/polish');
  @override
  Future<Map<String, dynamic>> activate(String id) => api.postJson('/mkt/items/$id/activate');
  @override
  Future<Map<String, dynamic>> publish(String id) => api.postJson('/mkt/items/$id/publish');
}

/// A server error's `detail` (already in the user's language), else null.
String? mktError(Object e) {
  if (e is ApiException && e.message.isNotEmpty && !e.message.startsWith('Error ')) {
    return e.message;
  }
  return null;
}

/// HTTP status of a failed call, if known.
int? mktStatus(Object e) => e is ApiException ? e.status : null;

List<Map<String, dynamic>> mktList(Object? v) =>
    v is List ? [for (final x in v) if (x is Map) Map<String, dynamic>.from(x)] : const [];

Map<String, dynamic> mktMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
