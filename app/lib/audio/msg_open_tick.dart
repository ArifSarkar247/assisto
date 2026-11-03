import '../messaging/msg_native.dart';
import '../messaging/msg_prefs.dart';
import 'audio_route_service.dart';

/// circlebub (owner 3 Nov, part C) — the SOFT in-app tick when a message
/// arrives in the chat that is open on screen (instead of the full pop).
///
/// Played natively (messaging/MsgTick.kt, res/raw/assisto_tick.wav) as a
/// notification sound, so Android mutes it on silent / vibrate / DND. It
/// never touches audio routing; it is skipped during a call (the call keeps
/// its earpiece / headset route untouched) and when the user chose "Silent"
/// for message sounds. Call ringtone and SOS sounds are unrelated.
class MsgOpenTick {
  MsgOpenTick._();

  /// Pure gate (tests): play only when not in a call and messages not silent.
  static bool shouldPlay({required bool inCall, required String? soundUri}) =>
      !inCall && soundUri != '';

  static Future<bool> play() async {
    try {
      final inCall = AudioRouteService.instance.inCall;
      final uri = await MsgPrefs.soundUri();
      if (!shouldPlay(inCall: inCall, soundUri: uri)) return false;
      return await MsgNative.playTick();
    } catch (_) {
      return false;
    }
  }
}
