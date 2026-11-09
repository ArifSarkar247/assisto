import '../api.dart';

/// carecall — the Care Call endpoints (backend/core/views_carecall.py), on
/// the generic getJson / postJson helpers (no api.dart edit). An interface so
/// widget tests and the screenshot gallery use a fake server.
abstract class CareCallApi {
  Future<Map<String, dynamic>> mine();
  Future<List<Map<String, dynamic>>> people();
  Future<Map<String, dynamic>> create(Map<String, dynamic> body);
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> body);
  Future<void> delete(int id);
  Future<Map<String, dynamic>> consent(int setterId, bool accept);
  Future<void> quiet(String start, String end);
  Future<Map<String, dynamic>> acks(List<Map<String, dynamic>> acks);
  Future<List<int>> voice(int id);
}

class HttpCareCallApi implements CareCallApi {
  HttpCareCallApi(this.c);
  final ApiClient c;

  @override
  Future<Map<String, dynamic>> mine() => c.getJson('/carecall');

  @override
  Future<List<Map<String, dynamic>>> people() async {
    final r = await c.getJson('/carecall/people');
    return [for (final x in (r['results'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
  }

  @override
  Future<Map<String, dynamic>> create(Map<String, dynamic> body) => c.postJson('/carecall', body);

  @override
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> body) =>
      c.postJson('/carecall/$id', body);

  @override
  Future<void> delete(int id) async {
    await c.postJson('/carecall/$id/delete');
  }

  @override
  Future<Map<String, dynamic>> consent(int setterId, bool accept) =>
      c.postJson('/carecall/consent', {'setter_id': setterId, 'accept': accept});

  @override
  Future<void> quiet(String start, String end) async {
    await c.postJson('/carecall/quiet', {'start': start, 'end': end});
  }

  @override
  Future<Map<String, dynamic>> acks(List<Map<String, dynamic>> acks) =>
      c.postJson('/carecall/acks', {'acks': acks});

  @override
  Future<List<int>> voice(int id) => c.getBytes('/carecall/$id/voice');
}
