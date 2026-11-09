import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// fcsos — SOS alarms through Do Not Disturb, ONLY with the user's permission
/// (Android "Do Not Disturb access"). Native side: SosDndChannel.kt. After
/// the user grants it, a second SOS notification channel with "override Do
/// Not Disturb" is created and remembered here; the push notifier (any
/// isolate) then draws SOS alarms on it. Without it the normal SOS channel
/// (alarm category + alarm sound) is used — Android lets alarms through
/// priority-only DND by default, but not every phone / mode.
class SosDnd {
  static const _ch = MethodChannel('com.assisto/sos_dnd');
  static const channelId = 'sos_dnd_v1';
  static const _pref = 'fcsos_dnd_channel_v1';

  /// null = unknown (old build / not Android / tests).
  static Future<bool?> granted() async {
    try {
      return await _ch.invokeMethod<bool>('granted');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> openSettings() async {
    try {
      return await _ch.invokeMethod<bool>('openSettings') == true;
    } catch (_) {
      return false;
    }
  }

  /// Creates the bypass channel when DND access is granted; remembers the
  /// result for the background isolate. Returns true when SOS can ring in DND.
  static Future<bool> ensure(String name, String desc) async {
    var ok = false;
    try {
      ok = await _ch.invokeMethod<bool>('ensureChannel', {'name': name, 'desc': desc}) == true;
    } catch (_) {
      ok = false;
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_pref, ok);
    } catch (_) {}
    return ok;
  }

  /// Draw SOS on the bypass channel? (read in any isolate; never throws)
  static Future<bool> channelReady() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_pref) ?? false;
    } catch (_) {
      return false;
    }
  }
}
