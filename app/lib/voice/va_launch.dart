import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/voice_assistant_screen.dart';
import '../state.dart';
import 'va_native.dart';
import '../ads/app_open_gate.dart' show AppEntry;
import '../feature_flags.dart' show FeatureFlags; // feature-flags
import '../widgets/feature_unavailable.dart'; // feature-flags

/// Opens Assisto Voice when the app was started by the "Digital assistant"
/// gesture (long-press home / assist button) or by the "Hey Assisto" wake
/// word. Called after the first frame and on every resume — never on the
/// cold-start critical path, and every step is guarded.
class VaLaunch {
  VaLaunch._();

  static bool _busy = false;

  /// Bumped to ask an already-open voice screen to listen again.
  static final ValueNotifier<int> relisten = ValueNotifier<int>(0);

  static Future<void> maybeOpen(BuildContext context) async {
    if (_busy) return;
    _busy = true;
    try {
      final app = context.read<AppState>();
      // Cold start: wait (briefly) for the session to load before consuming
      // the flag, so it is not lost behind the loading spinner.
      for (var i = 0; i < 30 && app.loading; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (!app.loggedIn || !app.onboarded || app.locale == null) return;
      if (!await VaNative.consumeAssistLaunch()) return;
      AppEntry.mark('assist'); // p2-money: no app-open ad for this entry
      if (!context.mounted) return;
      // feature-flags: Assisto Voice switched off -> the friendly notice.
      if (!FeatureFlags.instance.isOn('voice_assistant')) {
        FeatureUnavailableScreen.notify(context);
        return;
      }
      if (VoiceAssistantScreen.isOpen) {
        relisten.value++;
        return;
      }
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const VoiceAssistantScreen(),
          fullscreenDialog: true));
    } catch (_) {
      // never break launch / resume
    } finally {
      _busy = false;
    }
  }
}
