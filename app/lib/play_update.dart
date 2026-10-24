import 'config.dart';
import 'play_update_impl.dart' deferred as impl;

/// ota1 — Google Play In-App Updates (flexible) for the PLAY build only, so
/// testers are asked to update. The direct APK keeps its own updater.dart.
///
/// * Play draws the prompt itself; the user can say no ("not now").
/// * The download runs in the background while the app is used.
/// * The install (which restarts the app) is only triggered when the app goes
///   to the background, so nobody is thrown out mid-task.
/// Lazy (deferred library, ~15 s after the first frame) and crash-guarded:
/// any failure (sideloaded install, no Play account, old Play Store) is
/// ignored and the app keeps working.
class PlayUpdate {
  PlayUpdate._();

  static bool _started = false;
  static bool _downloaded = false;

  /// Called once after the first frame.
  static Future<void> checkSoon(
      {Duration delay = const Duration(seconds: 15)}) async {
    if (!AppConfig.playStore || _started) return;
    _started = true;
    try {
      await Future<void>.delayed(delay);
      await impl.loadLibrary();
      _downloaded = await impl.startFlexibleIfAvailable();
    } catch (_) {
      // not installed from Play / Play unavailable — nothing to do
    }
  }

  /// Called when the app goes to the background: install a downloaded update.
  static Future<void> onBackground() async {
    if (!AppConfig.playStore || !_started) return;
    try {
      if (!_downloaded) _downloaded = await impl.isDownloaded();
      if (_downloaded) await impl.complete();
    } catch (_) {}
  }
}
