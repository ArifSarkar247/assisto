// cctvarm — every server call of the automatic guard (owner CCTV order
// 3 Nov, W5): family away/home arming with each member's consent, indoor
// privacy, closed-shop guard, the no-movement check and SOS home live.
// Shapes mirror backend/core/cctv_arm_views.py. One seam so widget tests and
// the screenshot gallery inject a fake.
import '../api.dart';

abstract class AutoGuardSource {
  /// GET shop/sites/<id>/arm — owner: config, status, members, cameras, log.
  Future<Map<String, dynamic>> load(int siteId);

  /// POST shop/sites/<id>/arm — a partial change; the server bounds it.
  Future<Map<String, dynamic>> save(int siteId, Map<String, dynamic> body);

  /// GET shop/arm/mine — what places asked ME (consent, Home after yes).
  Future<Map<String, dynamic>> mine();

  /// POST shop/arm/consent — my own yes / no, any time.
  Future<Map<String, dynamic>> consent(int siteId, bool yes);

  /// POST shop/arm/presence — distances only, never coordinates.
  Future<Map<String, dynamic>> presence(List<Map<String, dynamic>> reports);

  /// GET shop/arm/sos-live — home cameras an SOS opened for me.
  Future<Map<String, dynamic>> sosLive();
}

class ApiAutoGuardSource implements AutoGuardSource {
  final ApiClient api;
  ApiAutoGuardSource(this.api);

  @override
  Future<Map<String, dynamic>> load(int siteId) => api.getJson('/shop/sites/$siteId/arm');

  @override
  Future<Map<String, dynamic>> save(int siteId, Map<String, dynamic> body) =>
      api.postJson('/shop/sites/$siteId/arm', body);

  @override
  Future<Map<String, dynamic>> mine() => api.getJson('/shop/arm/mine');

  @override
  Future<Map<String, dynamic>> consent(int siteId, bool yes) =>
      api.postJson('/shop/arm/consent', {'site': siteId, 'consent': yes});

  @override
  Future<Map<String, dynamic>> presence(List<Map<String, dynamic>> reports) =>
      api.postJson('/shop/arm/presence', {'reports': reports});

  @override
  Future<Map<String, dynamic>> sosLive() => api.getJson('/shop/arm/sos-live');
}
