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
}
