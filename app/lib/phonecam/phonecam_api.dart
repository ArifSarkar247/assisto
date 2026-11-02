import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../config.dart';
import '../shop_api.dart' show DeviceReply;

/// cctvphone — server calls for "an old phone as an Assisto camera".
/// Viewer side (normal login): the pairing code/QR + the owner's switches.
extension PhoneCamApi on ApiClient {
  /// {code, link, valid_s, included, used, extra_needs_credits,
  ///  extra_camera_credits, cameras: [...]} for one of the owner's places.
  Future<Map<String, dynamic>> phoneCamPair(int siteId) =>
      getJson('/shop/phonecam/pair?site=$siteId');

  /// {viewers_live: bool} and/or {name}.
  Future<Map<String, dynamic>> phoneCamSettings(int cameraId, Map<String, dynamic> body) =>
      patchJson('/shop/phonecam/$cameraId', body);
}

/// Camera-phone side: claim a code WITHOUT a login (the old phone may have
/// no Assisto account). Never throws — status 0 = offline.
class PhoneCamClaim {
  static Future<DeviceReply> claim(String code,
      {String name = '', String model = '', http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c
          .post(AppConfig.api('/shop/phonecam/claim'),
              headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: jsonEncode({
                'code': code,
                if (name.isNotEmpty) 'name': name,
                if (model.isNotEmpty) 'model': model,
                'platform': 'android',
              }))
          .timeout(const Duration(seconds: 20));
      Map<String, dynamic> b = {};
      try {
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) b = d;
      } catch (_) {}
      return DeviceReply(r.statusCode, b);
    } catch (_) {
      return const DeviceReply(0, {});
    }
  }
}
