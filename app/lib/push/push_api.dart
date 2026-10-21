import '../api.dart';

/// Push-device endpoints (backend/core/views_push.py). Kept as an extension
/// so the shared api.dart stays untouched.
extension PushApi on ApiClient {
  /// POST devices/register {push_token, platform, app_version}.
  Future<Map<String, dynamic>> pushRegister(String token,
          {String appVersion = ''}) =>
      postJson('/devices/register', {
        'push_token': token,
        'platform': 'android',
        'app_version': appVersion,
      });

  /// POST devices/unregister {push_token}.
  Future<Map<String, dynamic>> pushUnregister(String token) =>
      postJson('/devices/unregister', {'push_token': token});

  /// GET push/status -> {available}: does the SERVER have Firebase keys?
  Future<Map<String, dynamic>> pushStatus() => getJson('/push/status');
}
