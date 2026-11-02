// cctvescalate — the server calls for CCTV escalation plus (owner CCTV order
// 3 Nov, C3-C6): light / recorded warning on the camera, the owner's
// warning clip, the per-camera capability table. A separate seam (not in
// CctvxSource) so fakes stay small. Shapes mirror
// backend/core/cctv_escalate_views.py.
import 'dart:convert';
import 'dart:typed_data';

import '../api.dart';
import 'cctvx_source.dart';

abstract class EscalateSource {
  /// POST shop/events/<id>/deter {feature: light|voice, confirm: true}
  Future<Map<String, dynamic>> deter(int eventId, String feature,
      {int? cameraId, int? seconds});

  /// GET shop/sites/<id>/warn-clip
  Future<Map<String, dynamic>> warnClip(int siteId);

  /// PUT shop/sites/<id>/warn-clip {wav_b64}
  Future<Map<String, dynamic>> saveWarnClip(int siteId, Uint8List wav);

  /// DELETE shop/sites/<id>/warn-clip
  Future<Map<String, dynamic>> deleteWarnClip(int siteId);

  /// GET shop/cameras/<id>/deter[?refresh=1]
  Future<Map<String, dynamic>> cameraTable(int cameraId, {bool refresh = false});
}

class ApiEscalateSource implements EscalateSource {
  final ApiClient api;
  ApiEscalateSource(this.api);

  @override
  Future<Map<String, dynamic>> deter(int eventId, String feature,
          {int? cameraId, int? seconds}) =>
      api.postJson('/shop/events/$eventId/deter', {
        'feature': feature,
        'confirm': true,
        if (cameraId != null) 'camera_id': cameraId,
        if (seconds != null) 'seconds': seconds,
      });

  @override
  Future<Map<String, dynamic>> warnClip(int siteId) =>
      api.getJson('/shop/sites/$siteId/warn-clip');

  @override
  Future<Map<String, dynamic>> saveWarnClip(int siteId, Uint8List wav) =>
      api.postJson('/shop/sites/$siteId/warn-clip', {'wav_b64': base64Encode(wav)});

  @override
  Future<Map<String, dynamic>> deleteWarnClip(int siteId) =>
      api.deleteJson('/shop/sites/$siteId/warn-clip');

  @override
  Future<Map<String, dynamic>> cameraTable(int cameraId, {bool refresh = false}) =>
      api.getJson('/shop/cameras/$cameraId/deter${refresh ? '?refresh=1' : ''}');
}

/// The escalate seam for a CctvxSource (the real one wraps the same
/// ApiClient; fakes get null -> those rows are hidden, never dead).
EscalateSource? escalateFor(CctvxSource source) =>
    source is ApiCctvxSource ? ApiEscalateSource(source.api) : null;
