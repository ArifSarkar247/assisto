import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../push/push_service.dart' show appNavigatorKey;
import '../state.dart';
import 'call_native.dart';

/// play-fsi — Android 14+ does not pre-grant "full screen notifications" to
/// Assisto, so an incoming My Circle call would only show as a heads-up
/// notification (it still rings: max priority, call category, ringtone,
/// Accept/Decline). This asks the user ONCE, with a clear reason, to allow the
/// full-screen call screen; "Allow" opens Settings -> Full screen notifications.
/// Shown when My Circle opens, or after the first incoming call (never over a
/// ringing call). Android 13 and older, or already allowed: never shown.
class FullScreenCallPrompt {
  FullScreenCallPrompt._();

  static const String kShown = 'fsi_prompt_shown_v1';

  /// Tests: pretend the OS answer.
  static bool? debugCanOverride;

  static Future<bool> _needed() async {
    final can = debugCanOverride ?? await CallNative.canFullScreen();
    if (can) return false;
    return !(await Settings.getBool(kShown, false));
  }

  /// From a screen that is on top (My Circle).
  static Future<void> maybeShow(BuildContext context) async {
    try {
      if (!await _needed() || !context.mounted) return;
      await Settings.setBool(kShown, true);
      if (!context.mounted) return;
      await _dialog(context);
    } catch (_) {}
  }

  /// After an incoming call screen closed: use the app navigator.
  static Future<void> maybeShowAfterCall() async {
    try {
      if (!await _needed()) return;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await Settings.setBool(kShown, true);
      if (!ctx.mounted) return;
      await _dialog(ctx);
    } catch (_) {}
  }

  /// CI proof on an Android 14 emulator (smoke build only, via the
  /// `ao_open=__fsi__` probe): logs what the OS answers and, when full-screen
  /// is denied, shows the prompt so the job can screenshot it.
  static Future<void> debugProbe() async {
    final can = await CallNative.canFullScreen();
    debugPrint('FSI_PROBE can=$can');
    final ctx = appNavigatorKey.currentContext;
    if (!can && ctx != null && ctx.mounted) await _dialog(ctx);
  }

  static Future<void> _dialog(BuildContext context) {
    final t = AppLocalizations.of(context);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        key: const Key('fsi-prompt'),
        icon: const Icon(Icons.ring_volume_rounded),
        title: Text(t.fsiTitle),
        content: Text(t.fsiBody),
        actions: [
          TextButton(
            key: const Key('fsi-later'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.fsiLater),
          ),
          FilledButton(
            key: const Key('fsi-allow'),
            onPressed: () {
              Navigator.of(ctx).pop();
              CallNative.openFullScreenSettings();
            },
            child: Text(t.fsiAllow),
          ),
        ],
      ),
    );
  }
}
