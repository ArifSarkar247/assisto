import 'package:flutter/services.dart';

/// Showing Assisto over the lock screen is allowed ONLY for the one launch a
/// ringing call or an SOS alert makes (MainActivity decides that from the
/// notification payload; nothing in the manifest makes the app visible on a
/// locked phone). When the call/SOS screen closes we hand the lock screen
/// back, so nobody can wake a locked phone and read chats or the vault.
/// MainActivity also releases it whenever the app leaves the screen.
class LockScreenGuard {
  static const _ch = MethodChannel('com.assisto/lockscreen');

  static Future<void> release() async {
    try {
      await _ch.invokeMethod<void>('release');
    } catch (_) {
      // no native side (tests / older build): nothing was granted
    }
  }
}
