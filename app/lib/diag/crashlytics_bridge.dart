import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import '../push/firebase_lazy.dart';
import 'crash_reporter.dart';
import 'crash_scrub.dart';

/// sc1 — Firebase Crashlytics behind [CrashSinkBridge].
///
/// * Started ONLY by CrashReporter, after the first frame, never in safe mode.
/// * Collection stays OFF (manifest meta-data
///   firebase_crashlytics_collection_enabled=false) until [setEnabled] true —
///   the user is signed in and past onboarding (privacy policy disclosure).
/// * Only [ScrubbedError]s are recorded — Crashlytics never sees a raw
///   exception message. No logs, no custom keys with user data; the user id is
///   an opaque hash.
/// * Native (JVM) crashes are caught by the Crashlytics SDK itself once
///   Firebase is initialised; a crash BEFORE that (very early launch) is only
///   seen by our StartupGuard breadcrumb → /client/crash-report.
class CrashlyticsBridge implements CrashSinkBridge {
  bool _ready = false;

  @override
  Future<bool> init() async {
    if (_ready) return true;
    try {
      if (!await FirebaseLazy.ensure()) return false;
      // touch the instance once; any failure → stay off
      FirebaseCrashlytics.instance;
      _ready = true;
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  @override
  Future<void> setEnabled(bool on, {String? userHash}) async {
    if (!_ready) return;
    try {
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(on)
          .timeout(const Duration(seconds: 5));
      if (on && userHash != null) {
        await FirebaseCrashlytics.instance
            .setUserIdentifier(userHash)
            .timeout(const Duration(seconds: 5));
      }
      if (!on) {
        // a user who has not (or no longer) agreed: drop anything queued
        await FirebaseCrashlytics.instance
            .deleteUnsentReports()
            .timeout(const Duration(seconds: 5));
      }
    } catch (_) {}
  }

  @override
  Future<void> record(ScrubbedError error, StackTrace? stack,
      {required bool fatal}) async {
    if (!_ready) return;
    try {
      await FirebaseCrashlytics.instance
          .recordError(error, stack, fatal: fatal, printDetails: false)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
