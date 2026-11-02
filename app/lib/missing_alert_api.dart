import 'api.dart';

/// missing (owner 2 Nov) — Missing person alert ("nikhonj shotorkota").
/// Built only on the generic getJson / postJson / postJsonRaw helpers (no
/// api.dart edit). Server: backend/core/missing_views.py. Behind the server
/// flag `missing_alert` (OFF). Never flag-gated on the server: "I am safe",
/// turning nearby alerts OFF, and the alerts about me.
extension MissingAlertApi on ApiClient {
  Future<Map<String, dynamic>> maConfig() => getJson('/missing-alerts/config');

  Future<Map<String, dynamic>> maList() => getJson('/missing-alerts');

  Future<Map<String, dynamic>> maDetail(int id) => getJson('/missing-alerts/$id');

  /// Never throws on a 4xx: the body carries {reason, fields?} + `_status`.
  Future<Map<String, dynamic>> maCreate(Map<String, dynamic> body) =>
      postJsonRaw('/missing-alerts', body);

  /// One action on an alert. Literal paths (one per server route) so the
  /// API contract test can resolve every call.
  Future<Map<String, dynamic>> maAct(int id, String action,
      [Map<String, dynamic> body = const {}]) {
    switch (action) {
      case 'found':
        return postJsonRaw('/missing-alerts/$id/found', body);
      case 'close':
        return postJsonRaw('/missing-alerts/$id/close', body);
      case 'renew':
        return postJsonRaw('/missing-alerts/$id/renew', body);
      case 'gd':
        return postJsonRaw('/missing-alerts/$id/gd', body);
      case 'cosign':
        return postJsonRaw('/missing-alerts/$id/cosign', body);
      case 'safe':
        return postJsonRaw('/missing-alerts/$id/safe', body);
      case 'report':
        return postJsonRaw('/missing-alerts/$id/report', body);
    }
    throw ArgumentError.value(action, 'action');
  }

  Future<Map<String, dynamic>> maTips(int id) => getJson('/missing-alerts/$id/tips');

  Future<Map<String, dynamic>> maSendTip(int id, Map<String, dynamic> body) =>
      postJsonRaw('/missing-alerts/$id/tips', body);

  Future<Map<String, dynamic>> maThread(int threadId) =>
      getJson('/missing-alerts/tips/$threadId');

  Future<Map<String, dynamic>> maReply(int threadId, String text) =>
      postJsonRaw('/missing-alerts/tips/$threadId', {'text': text});

  Future<Map<String, dynamic>> maPref() => getJson('/missing-alerts/nearby');

  Future<Map<String, dynamic>> maSetPref(Map<String, dynamic> body) =>
      postJsonRaw('/missing-alerts/nearby', body);

  Future<Map<String, dynamic>> maWhereIAm(double lat, double lng) =>
      postJsonRaw('/missing-alerts/where-i-am', {'lat': lat, 'lng': lng});
}

/// Rows of a list field (defensive: anything not a map is skipped).
List<Map<String, dynamic>> maRows(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! List) return const [];
  return [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)];
}

/// Bangla digits -> ASCII (code points, so no Bangla text in Dart).
String maAsciiDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x09E6 && r <= 0x09EF) {
      b.writeCharCode(0x30 + r - 0x09E6);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

/// Mirror of missing_rules.clean_gd_number (format only; the server's
/// prefix rules also accept "GD No." / the Bangla prefix): the diary number,
/// optionally "/year" or "/month". Null when the format is wrong.
String? maCleanGd(String raw) {
  var s = maAsciiDigits(raw).trim();
  final first = s.indexOf(RegExp(r'\d'));
  if (first < 0) return null;
  s = s.substring(first).replaceAll(RegExp(r'\s+'), '');
  if (!RegExp(r'^\d{1,6}(/\d{1,4}){0,2}$').hasMatch(s)) return null;
  if (int.parse(s.split('/').first) == 0) return null;
  return s;
}

/// Round to 2 decimals (~1 km) BEFORE anything leaves the phone.
double maCoarse(double v) => (v * 100).roundToDouble() / 100;
