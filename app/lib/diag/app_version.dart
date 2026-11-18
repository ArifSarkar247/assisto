import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';

/// min-build: the full app version ("1.0.N+10N", the same string the push
/// registration sends) for the X-App-Version header on EVERY request, so the
/// server can hold back a feature this build cannot open
/// (core/views_features.py MIN_BUILD). Resolved once after the first frame;
/// until then (and if the plugin fails) the header stays the short label.
class AppVersion {
  static Future<void>? _once;

  static Future<void> resolve() => _once ??= _read();

  static Future<void> _read() async {
    try {
      final info = await PackageInfo.fromPlatform().timeout(const Duration(seconds: 3));
      if (info.version.isNotEmpty) {
        AppConfig.appBuildVersion =
            info.buildNumber.isEmpty ? info.version : '${info.version}+${info.buildNumber}';
      }
    } catch (_) {}
  }
}
