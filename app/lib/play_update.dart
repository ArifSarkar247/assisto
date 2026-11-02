import 'dart:async';

import 'config.dart';
import 'play_update_impl.dart' deferred as impl;

/// Result of a user-asked Play update check (Settings → About).
enum PlayUpdateCheck { started, upToDate, failed, notPlay }

/// ota1 — Google Play In-App Updates (flexible) for the PLAY build only, so
/// testers are asked to update. The direct APK keeps its own updater.dart.
///
/// framebar (owner rule: NEVER update UI on the home screen): the launch
/// check is SILENT — it only asks Play whether an update exists. Play's own
/// prompt is shown only
///  * when the person opens Settings ([promptIfAvailable], once per app run),
///  * or when they tap "Check for update on Google Play" in About
///    ([checkNow]).
/// Before, Play's dialog popped up by itself ~15 s after launch — almost
/// always over the home screen.
///
/// * The download runs in the background while the app is used.
/// * The install (which restarts the app) is only triggered when the app goes
///   to the background, so nobody is thrown out mid-task.
/// Lazy (deferred library) and crash-guarded: any failure (sideloaded install,
/// no Play account, old Play Store) is ignored and the app keeps working.
class PlayUpdate {
  PlayUpdate._();

  static bool _started = false;
  static bool _downloaded = false;
  static bool _available = false;
  static bool _prompted = false;

  /// Test seam: is this the Play build? (defaults to [AppConfig.playStore]).
  static bool Function() isPlayBuild = () => AppConfig.playStore;

  /// Test seams over the deferred plugin calls.
  static Future<bool> Function() availableFn = _implAvailable;
  static Future<bool> Function() startFn = _implStart;

  static Future<bool> _implAvailable() async {
    await impl.loadLibrary();
    return impl.updateAvailable();
  }

  static Future<bool> _implStart() async {
    await impl.loadLibrary();
    return impl.startFlexibleIfAvailable();
  }

  /// True once the silent launch check found a newer version on Play.
  static bool get available => _available;

  /// Called once after the first frame: a SILENT availability check.
  static Future<void> checkSoon(
      {Duration delay = const Duration(seconds: 15)}) async {
    if (!isPlayBuild() || _started) return;
    _started = true;
    try {
      await Future<void>.delayed(delay);
      _available = await availableFn();
    } catch (_) {
      // not installed from Play / Play unavailable — nothing to do
    }
  }

  /// Settings opened: show Play's prompt if the silent check found an update
  /// (once per app run, so leaving and re-opening Settings never nags).
  static Future<void> promptIfAvailable() async {
    if (!isPlayBuild() || !_available || _prompted) return;
    _prompted = true;
    try {
      _downloaded = await startFn();
      _started = true;
    } catch (_) {}
  }

  /// The person asked (About). Starts Play's flow when an update exists.
  static Future<PlayUpdateCheck> checkNow() async {
    if (!isPlayBuild()) return PlayUpdateCheck.notPlay;
    try {
      _available = await availableFn();
      if (!_available) return PlayUpdateCheck.upToDate;
      _prompted = true;
      _started = true;
      // Play's flow completes only after the download; never hold the
      // About screen's button on it.
      unawaited(startFn().then((v) => _downloaded = v, onError: (_) => false));
      return PlayUpdateCheck.started;
    } catch (_) {
      return PlayUpdateCheck.failed;
    }
  }

  /// Called when the app goes to the background: install a downloaded update.
  static Future<void> onBackground() async {
    if (!isPlayBuild() || !_started) return;
    try {
      if (!_downloaded) {
        await impl.loadLibrary();
        _downloaded = await impl.isDownloaded();
      }
      if (_downloaded) {
        await impl.loadLibrary();
        await impl.complete();
      }
    } catch (_) {}
  }

  static void resetForTest() {
    _started = false;
    _downloaded = false;
    _available = false;
    _prompted = false;
    isPlayBuild = () => AppConfig.playStore;
    availableFn = _implAvailable;
    startFn = _implStart;
  }
}
