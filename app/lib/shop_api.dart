import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'config.dart';

/// CCTV Part 4 round 2 (a2-cctv) — owner-side calls (normal login) for camera
/// settings, the end-of-day cash check and live-view signaling. Kept in its own
/// extension so the shared api.dart stays merge-friendly.
extension ShopOpsApi on ApiClient {
  /// The camera row WITH its token + webhook paths (owner only).
  Future<Map<String, dynamic>> shopCamera(int id) => getJson('/shop/cameras/$id');

  Future<Map<String, dynamic>> shopPatchCamera(
          int id, Map<String, dynamic> body) =>
      patchJson('/shop/cameras/$id', body);

  /// DELETE has no shared helper without a trailing slash; the shop views are
  /// registered without one.
  Future<void> shopDeleteCamera(int id) async {
    final r = await http.delete(AppConfig.api('/shop/cameras/$id'), headers: {
      if (token != null) 'Authorization': 'Token $token',
      'Accept-Language': lang ?? 'bn',
    });
    if (r.statusCode < 200 || r.statusCode >= 300) {
      String msg = 'Error ${r.statusCode}';
      try {
        final b = jsonDecode(r.body);
        if (b is Map && b['detail'] != null) msg = b['detail'].toString();
      } catch (_) {}
      throw ApiException(msg, r.statusCode);
    }
  }

  Future<Map<String, dynamic>> shopEodList(int siteId) =>
      getJson('/shop/sites/$siteId/eod');

  /// [countedPoisha]/[openingPoisha] are POISHA (taka x 100).
  Future<Map<String, dynamic>> shopEodSubmit(int siteId,
          {required int countedPoisha, int openingPoisha = 0, String note = ''}) =>
      postJson('/shop/sites/$siteId/eod', {
        'counted_cash': countedPoisha,
        'opening_float': openingPoisha,
        if (note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> shopLiveStart(int cameraId) =>
      postJson('/shop/live/start', {'camera': cameraId});

  Future<Map<String, dynamic>> shopLiveSignal(
          int sessionId, String kind, Object? payload) =>
      postJson('/shop/live/$sessionId/signal', {'kind': kind, 'payload': payload});

  Future<Map<String, dynamic>> shopLivePoll(int sessionId, int after) =>
      getJson('/shop/live/$sessionId/signal?after=$after');

  Future<Map<String, dynamic>> shopLiveEnd(int sessionId,
          {required bool relayed, required int seconds}) =>
      postJson('/shop/live/$sessionId/end',
          {'relayed': relayed, 'seconds': seconds});

  Future<Map<String, dynamic>> shopVoidSale(int saleId, String reason) =>
      postJson('/business/sales/$saleId/void', {'reason': reason});
}

/// Result of a device call: HTTP status + parsed JSON (never throws on 4xx).
class DeviceReply {
  final int status;
  final Map<String, dynamic> body;
  const DeviceReply(this.status, this.body);
  bool get ok => status >= 200 && status < 300;
  bool get unauthorized => status == 401;
}

/// The SHOP BOX DEVICE client (an old phone acting as the shop camera). It has
/// NO user login: every call carries the site/camera token in the
/// `X-Shop-Token` header (never in the URL, so it stays out of access logs).
/// Outbound HTTPS only; nothing listens on the phone.
class ShopDeviceClient {
  final String token;
  final int? cameraId; // set when paired with a SITE token + chosen camera
  final http.Client _c;
  ShopDeviceClient(this.token, {this.cameraId, http.Client? client})
      : _c = client ?? http.Client();

  Map<String, String> get _h => {
        'X-Shop-Token': token,
        if (cameraId != null) 'X-Shop-Camera': '$cameraId',
        'Accept': 'application/json',
      };

  Future<DeviceReply> _wrap(Future<http.Response> f) async {
    try {
      final r = await f.timeout(const Duration(seconds: 20));
      Map<String, dynamic> b = {};
      try {
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) b = d;
      } catch (_) {}
      return DeviceReply(r.statusCode, b);
    } catch (_) {
      return const DeviceReply(0, {}); // offline / timeout
    }
  }

  Future<DeviceReply> _post(String path, Map<String, dynamic> body) => _wrap(_c.post(
      AppConfig.api(path),
      headers: {..._h, 'Content-Type': 'application/json'},
      body: jsonEncode(body)));

  Future<DeviceReply> _get(String path) => _wrap(_c.get(AppConfig.api(path), headers: _h));

  Future<DeviceReply> pairCheck() => _post('/shop/pair/check', const {});

  Future<DeviceReply> heartbeat({List<String> caps = const ['live'], String version = ''}) =>
      _post('/shop/heartbeat', {
        if (cameraId != null) 'camera_ids': [cameraId],
        'caps': caps,
        'platform': 'android',
        'version': version,
      });

  Future<DeviceReply> config() => _get('/shop/config');

  Future<DeviceReply> pending() => _get('/shop/live/pending');

  Future<DeviceReply> signal(int sessionId, String kind, Object? payload) =>
      _post('/shop/live/$sessionId/signal', {'kind': kind, 'payload': payload});

  Future<DeviceReply> poll(int sessionId, int after) =>
      _get('/shop/live/$sessionId/signal?after=$after');

  Future<DeviceReply> end(int sessionId, {required bool relayed, required int seconds}) =>
      _post('/shop/live/$sessionId/end', {'relayed': relayed, 'seconds': seconds});

  /// POST shop/ingest — signals + at most ONE small snapshot (multipart).
  Future<DeviceReply> ingest(String type, Map<String, dynamic> signals,
      {Uint8List? snapshot}) async {
    if (snapshot == null) {
      return _post('/shop/ingest', {
        'type': type,
        'signals': signals,
        if (cameraId != null) 'camera_id': cameraId,
        'at': DateTime.now().millisecondsSinceEpoch / 1000.0,
      });
    }
    final req = http.MultipartRequest('POST', AppConfig.api('/shop/ingest'))
      ..headers.addAll(_h)
      ..fields['type'] = type
      ..fields['signals'] = jsonEncode(signals)
      ..fields['at'] = '${DateTime.now().millisecondsSinceEpoch / 1000.0}';
    if (cameraId != null) req.fields['camera_id'] = '$cameraId';
    req.files.add(http.MultipartFile.fromBytes('snapshot', snapshot,
        filename: 'snapshot.jpg'));
    return _wrap(_c.send(req).then(http.Response.fromStream));
  }
}
