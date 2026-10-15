import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Launch-safety breadcrumb + crash log (hotfix after the build-99 ANR).
///
/// How it works:
///  * [markLaunchStart] (first thing in main) reads whether the PREVIOUS launch
///    ever reached the home screen. If it did NOT, this launch enters SAFE MODE.
///  * [isSafeMode] tells the deferred init whether to skip native/optional init.
///  * [markReachedHome] (called once the home screen renders) clears the flag,
///    so a healthy launch resets everything.
///  * [recordError] appends an uncaught error to a local file; [takeError]
///    reads+clears it so the next GOOD launch can upload it to the backend.
///
/// Everything is wrapped in try/catch and never throws — the guard can never be
/// the thing that breaks startup.
class StartupGuard {
  StartupGuard._();

  static const _kInProgress = 'startup_in_progress_v1';
  static const _kBadCount = 'startup_bad_count_v1';
  static const _errFile = 'startup_error.log';

  static bool _prevBad = false;
  static Future<void>? _started;

  /// Call synchronously at the very top of main(). Kicks off the (async) read of
  /// the previous launch's state and marks THIS launch in-progress.
  static void markLaunchStart() {
    _started = _begin();
  }

  static Future<void> _begin() async {
    try {
      final p = await SharedPreferences.getInstance();
      // If the previous launch set in-progress and never cleared it, it crashed
      // or ANR'd before reaching home -> this launch is SAFE MODE.
      _prevBad = p.getBool(_kInProgress) ?? false;
      if (_prevBad) {
        await p.setInt(_kBadCount, (p.getInt(_kBadCount) ?? 0) + 1);
      }
      await p.setBool(_kInProgress, true);
    } catch (_) {
      _prevBad = false; // never let the guard itself cause trouble
    }
  }

  /// True iff the previous launch didn't reach home — skip native/optional init.
  static Future<bool> isSafeMode() async {
    try {
      await _started;
    } catch (_) {}
    return _prevBad;
  }

  /// Consecutive bad launches (0 when healthy). Shown as context if needed.
  static Future<int> badCount() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getInt(_kBadCount) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Call once the home screen has actually rendered — clears the bad-launch
  /// flag so the next launch is normal.
  static Future<void> markReachedHome() async {
    try {
      await _started;
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kInProgress, false);
      await p.setInt(_kBadCount, 0);
    } catch (_) {}
  }

  /// Append an uncaught error to the local log (for upload on the next good run).
  static Future<void> recordError(String message) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_errFile');
      final stamp = DateTime.now().toIso8601String();
      await f.writeAsString('[$stamp] $message\n\n',
          mode: FileMode.append, flush: true);
    } catch (e) {
      if (kDebugMode) debugPrint('StartupGuard.recordError failed: $e');
    }
  }

  /// Read + clear the stored error log (so the next good launch can upload it).
  static Future<String?> takeError() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$_errFile');
      if (!await f.exists()) return null;
      final s = await f.readAsString();
      if (s.trim().isEmpty) return null;
      await f.delete();
      return s;
    } catch (_) {
      return null;
    }
  }
}
