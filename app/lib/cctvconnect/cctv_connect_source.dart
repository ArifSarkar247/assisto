import '../api.dart';

/// cctvconnect (CCTV Guard V3 A1 + B): every server call of the brand-cloud
/// and DVR-health screens behind one seam, so widget tests and the
/// screenshot gallery inject a fake. Shapes mirror
/// backend/core/cctv_connect_views.py.
abstract class CctvConnectSource {
  /// {providers: [{id, name, modes, code_label_bn, code_label_en}], links: [...]}
  Future<Map<String, dynamic>> providers(int siteId);

  /// Authorize one device with the label code (used once, never stored).
  Future<Map<String, dynamic>> link(String provider, int siteId, String serial, String code);

  /// One-tap link of the owner's OWN brand account: {url} of our /oauth/go
  /// page, opened in the browser (the vendor's consent page follows).
  Future<Map<String, dynamic>> oauthStart(String provider, int siteId);

  /// {link, devices: [{serial, name, model, online, channels: [{no, name, online, added}]}]}
  Future<Map<String, dynamic>> devices(int linkId);

  /// {added: [...], skipped: [{serial, channel, why}], message}
  Future<Map<String, dynamic>> importChannels(int linkId, List<Map<String, dynamic>> items);

  Future<void> revoke(int linkId);

  /// The daily green-check card: {status, title, lines, recorded_days, target_days, devices}
  Future<Map<String, dynamic>> health(int siteId);

  Future<Map<String, dynamic>> setTargetDays(int siteId, int days);
}

class ApiCctvConnectSource implements CctvConnectSource {
  final ApiClient api;
  ApiCctvConnectSource(this.api);

  @override
  Future<Map<String, dynamic>> providers(int siteId) =>
      api.getJson('/cctv/connect/providers?site=$siteId');

  @override
  Future<Map<String, dynamic>> link(String provider, int siteId, String serial, String code) =>
      api.postJson('/cctv/connect/$provider/link',
          {'site': siteId, 'serial': serial, 'code': code});

  @override
  Future<Map<String, dynamic>> oauthStart(String provider, int siteId) =>
      api.postJson('/cctv/connect/$provider/oauth/start', {'site': siteId});

  @override
  Future<Map<String, dynamic>> devices(int linkId) =>
      api.getJson('/cctv/connect/links/$linkId/devices');

  @override
  Future<Map<String, dynamic>> importChannels(int linkId, List<Map<String, dynamic>> items) =>
      api.postJson('/cctv/connect/links/$linkId/import', {'items': items});

  @override
  Future<void> revoke(int linkId) async {
    await api.deleteJson('/cctv/connect/links/$linkId');
  }

  @override
  Future<Map<String, dynamic>> health(int siteId) => api.getJson('/cctv/health/sites/$siteId');

  @override
  Future<Map<String, dynamic>> setTargetDays(int siteId, int days) =>
      api.postJson('/cctv/health/sites/$siteId', {'target_days': days});
}
