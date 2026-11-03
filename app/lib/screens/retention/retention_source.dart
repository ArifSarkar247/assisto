import '../../api.dart';

/// retention1 — Retention automation: every server call the retention
/// screens make, behind one seam so widget tests / the screenshot gallery
/// inject a fake. Shapes mirror backend/core/views_retention.py.
abstract class RetentionSource {
  Future<Map<String, dynamic>> overview();
  Future<Map<String, dynamic>> saveCaps(Map<String, dynamic> caps);
  Future<Map<String, dynamic>> create(Map<String, dynamic> body);
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> body);
  Future<void> delete(int id);
  Future<Map<String, dynamic>> preview(Map<String, dynamic> draft);
  Future<Map<String, dynamic>> results(int id);
  Future<Map<String, dynamic>> customers(String q, {bool withBirthday = false});
  Future<Map<String, dynamic>> setBirthday(int customerId, String? isoDate);
  Future<Map<String, dynamic>> stockAsks();
  Future<Map<String, dynamic>> addStockAsk(int productId, int customerId);
  Future<void> removeStockAsk(int id);
  Future<Map<String, dynamic>> addOptOut(String phone);
  // bizauto: who stopped this shop's messages (masked) — read-only
  Future<Map<String, dynamic>> optOuts();
  // crmauto: transparent customer score + the owner's activity log
  Future<Map<String, dynamic>> scores({String q = ''});
  Future<Map<String, dynamic>> audit();
  // customer side
  Future<Map<String, dynamic>> inbox();
  Future<Map<String, dynamic>> reply(int id, String text);
  Future<Map<String, dynamic>> stop(int id);
}

class ApiRetentionSource implements RetentionSource {
  final ApiClient api;
  ApiRetentionSource(this.api);

  @override
  Future<Map<String, dynamic>> overview() => api.getJson('/retention');
  @override
  Future<Map<String, dynamic>> saveCaps(Map<String, dynamic> caps) =>
      api.patchJson('/retention/settings', caps);
  @override
  Future<Map<String, dynamic>> create(Map<String, dynamic> body) =>
      api.postJson('/retention/automations', body);
  @override
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> body) =>
      api.patchJson('/retention/automations/$id', body);
  @override
  Future<void> delete(int id) async {
    await api.deleteJson('/retention/automations/$id');
  }

  @override
  Future<Map<String, dynamic>> preview(Map<String, dynamic> draft) =>
      api.postJson('/retention/preview', draft);
  @override
  Future<Map<String, dynamic>> results(int id) => api.getJson('/retention/automations/$id/results');
  @override
  Future<Map<String, dynamic>> customers(String q, {bool withBirthday = false}) =>
      api.getJson('/retention/customers?q=${Uri.encodeQueryComponent(q)}'
          '${withBirthday ? '&with_birthday=1' : ''}');
  @override
  Future<Map<String, dynamic>> setBirthday(int customerId, String? isoDate) =>
      api.postJson('/retention/customers/$customerId/birthday', {'birthday': isoDate});
  @override
  Future<Map<String, dynamic>> stockAsks() => api.getJson('/retention/stock-asks');
  @override
  Future<Map<String, dynamic>> addStockAsk(int productId, int customerId) =>
      api.postJson('/retention/stock-asks', {'product_id': productId, 'customer_id': customerId});
  @override
  Future<void> removeStockAsk(int id) async {
    await api.deleteJson('/retention/stock-asks/$id');
  }

  @override
  Future<Map<String, dynamic>> addOptOut(String phone) =>
      api.postJson('/retention/opt-outs', {'phone': phone});
  @override
  Future<Map<String, dynamic>> optOuts() => api.getJson('/retention/opt-outs');
  @override
  Future<Map<String, dynamic>> scores({String q = ''}) =>
      api.getJson('/retention/scores?q=${Uri.encodeQueryComponent(q)}');
  @override
  Future<Map<String, dynamic>> audit() => api.getJson('/retention/audit');
  @override
  Future<Map<String, dynamic>> inbox() => api.getJson('/retention/inbox');
  @override
  Future<Map<String, dynamic>> reply(int id, String text) =>
      api.postJson('/retention/inbox/$id/reply', {'text': text});
  @override
  Future<Map<String, dynamic>> stop(int id) => api.postJson('/retention/inbox/$id/stop');
}

/// A server error's `detail` (already in the user's language), else null.
String? rtError(Object e) {
  if (e is ApiException && e.message.isNotEmpty && !e.message.startsWith('Error ')) {
    return e.message;
  }
  return null;
}

/// HTTP status of a failed call, if known.
int? rtStatus(Object e) => e is ApiException ? e.status : null;

const _bnZero = 0x09E6;

/// Digits in the UI language (Bangla digits in bn). No Bangla literal here:
/// the language gate keeps Bangla text in the ARB files only.
String rtDigits(String lang, Object v) {
  final s = v.toString();
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? _bnZero + (c - 0x30) : c);
  }
  return b.toString();
}

/// Poisha -> "1,234" taka in the UI language's digits.
String rtTaka(String lang, Object? poisha) {
  final p = (poisha is num) ? poisha.toInt() : 0;
  final taka = p ~/ 100;
  final raw = taka.toString();
  final out = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    if (i > 0 && (raw.length - i) % 3 == 0) out.write(',');
    out.write(raw[i]);
  }
  return rtDigits(lang, out.toString());
}

List<Map<String, dynamic>> rtList(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList() : const [];

Map<String, dynamic> rtMap(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

int rtInt(Object? v, [int fb = 0]) => v is num ? v.toInt() : (int.tryParse('$v') ?? fb);
