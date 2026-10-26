import '../../api.dart';

/// cctv1 — Home & shop watchman: every server call the watchman screens make,
/// behind one seam so widget tests / the screenshot gallery inject a fake
/// (no shared FakeApi edits). Shapes mirror backend/core/watchman_views.py.
abstract class WatchmanSource {
  Future<Map<String, dynamic>> overview();
  Future<Map<String, dynamic>> setup(String kind, String gateway, String name);
  Future<Map<String, dynamic>> addCamera(int siteId, Map<String, dynamic> body);
  Future<Map<String, dynamic>> queueCheck(int cameraId, Map<String, dynamic> body);
  Future<Map<String, dynamic>> discover(int siteId);
  Future<Map<String, dynamic>> task(int taskId);
  Future<Map<String, dynamic>> zones(int cameraId);
  Future<Map<String, dynamic>> saveZones(int cameraId, Map<String, dynamic> cfg);
  Future<Map<String, dynamic>> preview(int cameraId);
  Future<Map<String, dynamic>> linkImou(int cameraId, String serial, String code);
  Future<Map<String, dynamic>> events(int siteId);
  Future<Map<String, dynamic>> mark(int eventId, String verdict);
  Future<Map<String, dynamic>> viewers(int siteId);
  Future<Map<String, dynamic>> addViewer(int siteId, String phone);
  Future<void> removeViewer(int siteId, int userId);
  Future<Map<String, dynamic>> patchSite(int siteId, Map<String, dynamic> body);
  Future<void> deleteCamera(int cameraId);
}

class ApiWatchmanSource implements WatchmanSource {
  final ApiClient api;
  ApiWatchmanSource(this.api);

  @override
  Future<Map<String, dynamic>> overview() => api.getJson('/shop/watchman');
  @override
  Future<Map<String, dynamic>> setup(String kind, String gateway, String name) =>
      api.postJson('/shop/watchman/setup', {'kind': kind, 'gateway': gateway, 'name': name});
  @override
  Future<Map<String, dynamic>> addCamera(int siteId, Map<String, dynamic> body) =>
      api.postJson('/shop/sites/$siteId/cameras', body);
  @override
  Future<Map<String, dynamic>> queueCheck(int cameraId, Map<String, dynamic> body) =>
      api.postJson('/shop/cameras/$cameraId/check', body);
  @override
  Future<Map<String, dynamic>> discover(int siteId) =>
      api.postJson('/shop/sites/$siteId/discover');
  @override
  Future<Map<String, dynamic>> task(int taskId) =>
      api.getJson('/shop/gateway/tasks/$taskId/status');
  @override
  Future<Map<String, dynamic>> zones(int cameraId) =>
      api.getJson('/shop/cameras/$cameraId/zones');
  @override
  Future<Map<String, dynamic>> saveZones(int cameraId, Map<String, dynamic> cfg) =>
      api.postJson('/shop/cameras/$cameraId/zones', {'zone_config': cfg});
  @override
  Future<Map<String, dynamic>> preview(int cameraId) =>
      api.getJson('/shop/cameras/$cameraId/preview');
  @override
  Future<Map<String, dynamic>> linkImou(int cameraId, String serial, String code) =>
      api.postJson('/shop/cameras/$cameraId/imou',
          {'device_serial': serial, 'safety_code': code});
  @override
  Future<Map<String, dynamic>> events(int siteId) =>
      api.getJson('/shop/events?site=$siteId');
  @override
  Future<Map<String, dynamic>> mark(int eventId, String verdict) =>
      api.postJson('/shop/events/$eventId/mark', {'status': verdict});
  @override
  Future<Map<String, dynamic>> viewers(int siteId) =>
      api.getJson('/shop/sites/$siteId/viewers');
  @override
  Future<Map<String, dynamic>> addViewer(int siteId, String phone) =>
      api.postJson('/shop/sites/$siteId/viewers', {'phone': phone});
  @override
  Future<void> removeViewer(int siteId, int userId) async {
    await api.deleteJson('/shop/sites/$siteId/viewers/$userId');
  }

  @override
  Future<Map<String, dynamic>> patchSite(int siteId, Map<String, dynamic> body) =>
      api.patchJson('/shop/sites/$siteId', body);
  @override
  Future<void> deleteCamera(int cameraId) async {
    await api.deleteJson('/shop/cameras/$cameraId');
  }
}

/// A server error's `detail` (already in the user's language), else null.
String? wmError(Object e) {
  if (e is ApiException && e.message.isNotEmpty && !e.message.startsWith('Error ')) {
    return e.message;
  }
  return null;
}

/// HTTP status of a failed call, if known.
int? wmStatus(Object e) => e is ApiException ? e.status : null;

const _bnZero = 0x09E6;

/// Digits in the UI language (Bangla digits in bn). No Bangla literal here:
/// the language gate keeps Bangla text in the ARB files only.
String wmDigits(String lang, Object v) {
  final s = v.toString();
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? _bnZero + (c - 0x30) : c);
  }
  return b.toString();
}

List<Map<String, dynamic>> wmList(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList() : const [];

Map<String, dynamic> wmMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
