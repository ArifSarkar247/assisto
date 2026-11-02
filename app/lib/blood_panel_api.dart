import 'api.dart';

/// blood (owner 2 Nov) — Blood donor panel. Built only on the generic
/// getJson / postJsonRaw / deleteJson helpers (no api.dart edit). Server:
/// backend/core/blood_views.py (prefix `blood-panel/`; the older personal
/// registry keeps `blood/donors/`). Flag `blood_donors` (OFF). Never gated on
/// the server: reading my profile, switching listing off, leaving, threads.
extension BloodPanelApi on ApiClient {
  Future<Map<String, dynamic>> bpConfig() => getJson('/blood-panel/config');

  Future<Map<String, dynamic>> bpMe() => getJson('/blood-panel/me');

  /// Never throws on a 4xx: the body carries {reason, fields?} + `_status`.
  Future<Map<String, dynamic>> bpSaveMe(Map<String, dynamic> body) =>
      postJsonRaw('/blood-panel/me', body);

  Future<Map<String, dynamic>> bpLeave() => deleteJson('/blood-panel/me');

  Future<Map<String, dynamic>> bpDonated([String? date]) =>
      postJsonRaw('/blood-panel/me/donated', {if (date != null) 'date': date});

  Future<Map<String, dynamic>> bpVerify(String photoB64) =>
      postJsonRaw('/blood-panel/me/verify', {'photo_b64': photoB64});

  Future<Map<String, dynamic>> bpDonors(Map<String, String> q) =>
      getJson(Uri(path: '/blood-panel/donors', queryParameters: q).toString());

  Future<Map<String, dynamic>> bpMessageDonor(int donorId, String text) =>
      postJsonRaw('/blood-panel/donors/$donorId/message', {'text': text});

  Future<Map<String, dynamic>> bpRequests() => getJson('/blood-panel/requests');

  Future<Map<String, dynamic>> bpCreateRequest(Map<String, dynamic> body) =>
      postJsonRaw('/blood-panel/requests', body);

  Future<Map<String, dynamic>> bpRequest(int id) => getJson('/blood-panel/requests/$id');

  /// One action on a request. Literal paths (one per server route) so the
  /// API contract test can resolve every call.
  Future<Map<String, dynamic>> bpAct(int id, String action,
      [Map<String, dynamic> body = const {}]) {
    switch (action) {
      case 'respond':
        return postJsonRaw('/blood-panel/requests/$id/respond', body);
      case 'found':
        return postJsonRaw('/blood-panel/requests/$id/found', body);
      case 'close':
        return postJsonRaw('/blood-panel/requests/$id/close', body);
      case 'report':
        return postJsonRaw('/blood-panel/requests/$id/report', body);
      case 'share': // finish1: this side agrees to the thank-you card
        return postJsonRaw('/blood-panel/requests/$id/share', body);
    }
    throw ArgumentError.value(action, 'action');
  }

  Future<Map<String, dynamic>> bpThreads() => getJson('/blood-panel/threads');

  Future<Map<String, dynamic>> bpThread(int id) => getJson('/blood-panel/threads/$id');

  Future<Map<String, dynamic>> bpSend(int id, String text) =>
      postJsonRaw('/blood-panel/threads/$id', {'text': text});

  Future<Map<String, dynamic>> bpBlock(int id, bool on) =>
      postJsonRaw('/blood-panel/threads/$id/block', {'on': on});

  Future<Map<String, dynamic>> bpCircle(int id, String action) =>
      postJsonRaw('/blood-panel/threads/$id/circle', {'action': action});

  /// finish1: the official list (if the owner imported one) — optional
  /// district / text filter, nearest first for a ~1 km point.
  Future<Map<String, dynamic>> bpBanks([Map<String, String> q = const {}]) => getJson(q.isEmpty
      ? '/blood-panel/banks'
      : Uri(path: '/blood-panel/banks', queryParameters: q).toString());
}

/// Rows of a list field (defensive: anything not a map is skipped).
List<Map<String, dynamic>> bpRows(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! List) return const [];
  return [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)];
}

Map<String, dynamic> bpMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// Round to 2 decimals (~1 km) BEFORE anything leaves the phone.
double bpCoarse(double v) => (v * 100).roundToDouble() / 100;

const kBloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];
