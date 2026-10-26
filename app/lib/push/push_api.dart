import '../api.dart';

/// Push-device endpoints (backend/core/views_push.py). Kept as an extension
/// so the shared api.dart stays untouched.
extension PushApi on ApiClient {
  /// POST devices/register {push_token, platform, app_version} + (ring-
  /// everywhere) the phone's brand / model / Android SDK for the Owner Admin
  /// call-delivery table (no PII). The answer's `missed_pending` counts
  /// never-delivered missed calls waiting for [missedPending].
  /// calls95: [replaceToken] = the token this install registered before
  /// (FCM rotated it); the server drops that row.
  Future<Map<String, dynamic>> pushRegister(String token,
          {String appVersion = '',
          Map<String, Object?>? device,
          String? replaceToken}) =>
      postJson('/devices/register', {
        'push_token': token,
        'platform': 'android',
        'app_version': appVersion,
        if (replaceToken != null && replaceToken.isNotEmpty)
          'replace_token': replaceToken,
        if (device != null) ...{
          'brand': '${device['brand'] ?? ''}',
          'model': '${device['model'] ?? ''}',
          'sdk_int': device['sdk_int'] is int ? device['sdk_int'] : 0,
        },
      });

  /// ring-everywhere: GET circle/calls/missed_pending -> {items: [...]} —
  /// calls this phone never got (killed / force-stopped / offline), each
  /// returned ONCE as a ready missed_call push payload.
  Future<Map<String, dynamic>> missedPending() =>
      getJson('/circle/calls/missed_pending');

  /// POST devices/unregister {push_token}.
  Future<Map<String, dynamic>> pushUnregister(String token) =>
      postJson('/devices/unregister', {'push_token': token});

  /// GET push/status -> {available}: does the SERVER have Firebase keys?
  Future<Map<String, dynamic>> pushStatus() => getJson('/push/status');
}
