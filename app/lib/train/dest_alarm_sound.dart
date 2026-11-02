import 'package:flutter/services.dart';

import '../audio/audio_route_service.dart';

/// train: the destination alarm's sound — ONE small, documented siren-style
/// exception (like SOS): a looping alarm tone + the stop name spoken on
/// STREAM_ALARM, so it is loud even on silent and also heard in connected
/// earphones. Native side: android_overlay/.../train/TrainAlarmChannel.kt
/// (allowed by test/audio_route_guard_test.dart). Routing goes through
/// [AudioRouteService] (a lease that clears a stale call/mic session first,
/// so the alarm never plays on the earpiece).
abstract class DestAlarmSound {
  Future<bool> start();
  Future<bool> speak(String text, String lang);
  Future<void> stop();
}

class NativeDestAlarmSound implements DestAlarmSound {
  static const MethodChannel _ch = MethodChannel('com.assisto/train_alarm');
  AudioRouteLease? _lease;

  @override
  Future<bool> start() async {
    try {
      _lease ??= await AudioRouteService.instance.acquire(AudioUse.destAlarm);
    } catch (_) {
      // best-effort: the alarm still plays on STREAM_ALARM
    }
    try {
      return await _ch.invokeMethod<bool>('start', {'volumeMax': true}) ?? false;
    } catch (_) {
      return false; // older build / no tone: the vibration + notification remain
    }
  }

  @override
  Future<bool> speak(String text, String lang) async {
    try {
      return await _ch.invokeMethod<bool>('speak', {'text': text, 'lang': lang}) ?? false;
    } catch (_) {
      return false; // no TTS engine: the tone keeps playing
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _ch.invokeMethod<bool>('stop');
    } catch (_) {
      // best-effort: nothing playing
    }
    final l = _lease;
    _lease = null;
    try {
      await l?.release();
    } catch (_) {
      // best-effort: lease already gone
    }
  }
}
