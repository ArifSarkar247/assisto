import 'dart:convert';

import '../api.dart';
import '../family_alerts_api.dart';
import '../sosat_api.dart';

/// fcsos — Family Care v3 SOS sender (SCREEN 2) + receiver (SCREEN 3).
/// Backend: core/family_sos_v3.py + core/family_alerts.py. Literal paths (the
/// API contract test resolves every call). Safety: free on every plan.
///   POST /family/sos {lat?, lng?, source, client_id}
///   POST /family/sos/resolve {reason: "mistake"|"safe"}
///   GET  /family/sos/status          -> {state, sent_at, going:[{name,at,me}], audio}
///   GET  /family/sos/ladder          -> receipts (sosat)
///   POST /family/sos/location {lat, lng}
///   POST /family/sos/audio {audio_b64, sec}
///   GET  /family/sos/event/<id>      -> receiver page data
///   GET  /family/sos/event/<id>/audio
///   POST /family/alerts/<id>/responding   (guardian2 "I am going")
///   POST /family/alerts/<id>/seen
///   GET/POST /family/sos/settings {share_info}
abstract class FcSosApi {
  Future<Map<String, dynamic>> send(
      {double? lat, double? lng, required String source, required String clientId});
  Future<Map<String, dynamic>> resolve({required bool mistake});
  Future<Map<String, dynamic>> status();
  Future<Map<String, dynamic>> ladder();
  Future<void> location(double lat, double lng);
  Future<bool> uploadAudio(List<int> bytes, int sec);
  Future<Map<String, dynamic>> event(int deliveryId);
  Future<List<int>> eventAudio(int deliveryId);
  Future<Map<String, dynamic>> going(int deliveryId);
  Future<void> seen(int deliveryId);
  Future<Map<String, dynamic>> settings();
  Future<Map<String, dynamic>> setShareInfo(bool on);
}

class HttpFcSosApi implements FcSosApi {
  HttpFcSosApi(this.c);
  final ApiClient c;

  @override
  Future<Map<String, dynamic>> send(
          {double? lat, double? lng, required String source, required String clientId}) =>
      c.familySos(lat: lat, lng: lng, source: source, clientId: clientId);

  @override
  Future<Map<String, dynamic>> resolve({required bool mistake}) =>
      c.postJson('/family/sos/resolve', {'reason': mistake ? 'mistake' : 'safe'});

  @override
  Future<Map<String, dynamic>> status() => c.getJson('/family/sos/status');

  @override
  Future<Map<String, dynamic>> ladder() => c.sosLadder();

  @override
  Future<void> location(double lat, double lng) async {
    await c.postJsonRaw('/family/sos/location', {'lat': lat, 'lng': lng});
  }

  @override
  Future<bool> uploadAudio(List<int> bytes, int sec) async {
    final r = await c.postJsonRaw(
        '/family/sos/audio', {'audio_b64': base64Encode(bytes), 'sec': sec});
    return r['ok'] == true;
  }

  @override
  Future<Map<String, dynamic>> event(int deliveryId) =>
      c.getJson('/family/sos/event/$deliveryId');

  @override
  Future<List<int>> eventAudio(int deliveryId) =>
      c.getBytes('/family/sos/event/$deliveryId/audio');

  @override
  Future<Map<String, dynamic>> going(int deliveryId) => c.familySosResponding(deliveryId);

  @override
  Future<void> seen(int deliveryId) async {
    await c.familyAlertSeen(deliveryId);
  }

  @override
  Future<Map<String, dynamic>> settings() => c.getJson('/family/sos/settings');

  @override
  Future<Map<String, dynamic>> setShareInfo(bool on) =>
      c.postJson('/family/sos/settings', {'share_info': on});
}
