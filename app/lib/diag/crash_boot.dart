import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import '../state.dart';
import 'crash_reporter.dart';
import 'crash_scrub.dart';
import 'crashlytics_bridge.dart';

/// sc1 — glue between AppState and [CrashReporter]. Called ONCE from main.dart
/// a few seconds after the first frame, guarded. Consent = signed in AND past
/// onboarding. Crashlytics only outside StartupGuard safe mode.
class CrashBoot {
  CrashBoot._();
  static bool _started = false;

  static Future<void> start(AppState app, {required bool safeMode}) async {
    if (_started) return;
    _started = true;
    var version = '', build = '';
    try {
      final info = await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 3));
      version = info.version;
      build = info.buildNumber;
    } catch (_) {}
    final r = CrashReporter.instance;
    await r.start(
      post: (body) async {
        await app.api.postJson('/client/crash-report', body);
      },
      consented: () => app.loggedIn && app.onboarded && !app.loading,
      userHash: () {
        final id = app.user?.id;
        return id == null ? '' : CrashScrub.userHash(id);
      },
      bridge: safeMode ? null : CrashlyticsBridge(),
      version: version,
      build: build,
    );
    app.addListener(() => unawaited(r.onConsentChanged()));
  }
}
