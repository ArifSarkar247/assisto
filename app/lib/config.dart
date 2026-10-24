import 'package:flutter/foundation.dart' show kReleaseMode;

/// All URLs come from ONE place so the backend can move servers with zero
/// change for users (override at build time with --dart-define=API_BASE=...).

class AppConfig {
  static const String _shippedBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'https://api.lifeassisto.com',
  );

  /// Reality-audit CI override (.github/workflows/reality.yml points the debug
  /// integration-test build at a throw-away Django inside the runner:
  /// --dart-define=REALITY_API_BASE=http://10.0.2.2:8700). INERT in release:
  /// kReleaseMode is a compile-time const, so a release build always uses
  /// [_shippedBase] even if the define were passed.
  static const String _realityBase = String.fromEnvironment('REALITY_API_BASE');

  static const String apiBase =
      (!kReleaseMode && _realityBase != '') ? _realityBase : _shippedBase;
  static const String apiPrefix = '/api/v1';
  static const String appVersionLabel = '1.0';

  /// l1-launch: true ONLY in the Google Play build (CI AAB step passes
  /// --dart-define=PLAY_STORE=true). Play forbids self-updating outside the
  /// store, so this build never checks /app/latest, never downloads an APK and
  /// ships without REQUEST_INSTALL_PACKAGES. The website APK keeps its updater.
  static const bool playStore = bool.fromEnvironment('PLAY_STORE');

  /// UTC build timestamp, injected by CI (--dart-define=BUILD_TIME=...). Empty
  /// on local/dev builds. Shown only in Settings → About.
  static const String buildTime = String.fromEnvironment('BUILD_TIME', defaultValue: '');

  /// A path without a leading slash ('messenger/lists') used to produce
  /// '/api/v1messenger/lists' (a guaranteed 404). Normalise it here so every
  /// caller hits the real route.
  static Uri api(String path) => Uri.parse(
      '$apiBase$apiPrefix${path.startsWith('/') ? '' : '/'}$path');

  /// The current DRF auth token, mirrored here by [ApiClient] so image
  /// widgets (which use [NetworkImage], not the REST client) can attach the
  /// `Authorization` header when loading authed media from our own backend
  /// (e.g. the profile avatar served by the auth-checked `/me/avatar` view).
  static String? authToken;

  /// own-device: this install's hashed id (see lib/device_id.dart), sent as
  /// `X-Device-Id` on every API request once loaded; null until then.
  static String? deviceId;

  /// Auth headers for a [NetworkImage] pointing at our own backend, or null
  /// when the URL is foreign (external avatar link) or we have no token.
  static Map<String, String>? authHeadersFor(String url) {
    final t = authToken;
    if (t == null || t.isEmpty) return null;
    if (!url.startsWith(apiBase)) return null;
    return {'Authorization': 'Token $t'};
  }
}
