// cctvevidence (W7) — the server calls of the camera's "Recording & evidence"
// screen: SD-card health, the per-camera video add-on, today's clips, the
// shop address printed in the evidence pack. One seam so widget tests and the
// screenshot gallery inject a fake. Shapes mirror backend/core/cctv_evidence.py.
import '../api.dart';

abstract class CctvEvidenceSource {
  /// GET shop/cameras/<id>/recording[?refresh=1]
  Future<Map<String, dynamic>> recording(int cameraId, {bool refresh = false});

  /// POST shop/cameras/<id>/video-addon {tier} — one month, paid with credits.
  Future<Map<String, dynamic>> buyAddon(int cameraId, String tier);

  /// PUT shop/sites/<id>/address {address}
  Future<Map<String, dynamic>> saveAddress(int siteId, String address);
}

class ApiCctvEvidenceSource implements CctvEvidenceSource {
  final ApiClient api;
  ApiCctvEvidenceSource(this.api);

  @override
  Future<Map<String, dynamic>> recording(int cameraId, {bool refresh = false}) =>
      api.getJson('/shop/cameras/$cameraId/recording${refresh ? '?refresh=1' : ''}');

  @override
  Future<Map<String, dynamic>> buyAddon(int cameraId, String tier) =>
      api.postJson('/shop/cameras/$cameraId/video-addon', {'tier': tier});

  @override
  Future<Map<String, dynamic>> saveAddress(int siteId, String address) =>
      api.postJson('/shop/sites/$siteId/address', {'address': address});
}
