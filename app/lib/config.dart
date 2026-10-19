/// All URLs come from ONE place so the backend can move servers with zero
/// change for users (override at build time with --dart-define=API_BASE=...).
class AppConfig {
  static const String apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'https://assisto.asalify.com',
  );
  static const String apiPrefix = '/api/v1';
  static const String appVersionLabel = '1.0';

  /// UTC build timestamp, injected by CI (--dart-define=BUILD_TIME=...). Empty
  /// on local/dev builds. Shown only in Settings → About.
  static const String buildTime = String.fromEnvironment('BUILD_TIME', defaultValue: '');

  static Uri api(String path) => Uri.parse('$apiBase$apiPrefix$path');

  /// The current DRF auth token, mirrored here by [ApiClient] so image
  /// widgets (which use [NetworkImage], not the REST client) can attach the
  /// `Authorization` header when loading authed media from our own backend
  /// (e.g. the profile avatar served by the auth-checked `/me/avatar` view).
  static String? authToken;

  /// Auth headers for a [NetworkImage] pointing at our own backend, or null
  /// when the URL is foreign (external avatar link) or we have no token.
  static Map<String, String>? authHeadersFor(String url) {
    final t = authToken;
    if (t == null || t.isEmpty) return null;
    if (!url.startsWith(apiBase)) return null;
    return {'Authorization': 'Token $t'};
  }
}
