import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../services/error_report.dart';

/// md1 — inline voice-note playback. ONE player for the whole app (the next
/// note stops the previous one, like WhatsApp), created LAZILY on the first
/// play tap (never at launch). Every plugin call is crash-guarded.
class VoiceState {
  final String path; // the decrypted file playing ('' = nothing)
  final bool playing;
  final int positionMs;
  final int durationMs;
  const VoiceState({this.path = '', this.playing = false, this.positionMs = 0, this.durationMs = 0});
}

/// Plugin seam (a fake in widget tests).
abstract class VoiceBackend {
  Future<void> play(String path);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration d);
  Future<void> stop();
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<void> get completed;
}

class AudioplayersBackend implements VoiceBackend {
  AudioPlayer? _p;
  AudioPlayer get _player => _p ??= AudioPlayer()..setReleaseMode(ReleaseMode.stop);

  @override
  Future<void> play(String path) => _player.play(DeviceFileSource(path));
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> resume() => _player.resume();
  @override
  Future<void> seek(Duration d) => _player.seek(d);
  @override
  Future<void> stop() => _player.stop();
  @override
  Stream<Duration> get position => _player.onPositionChanged;
  @override
  Stream<Duration> get duration => _player.onDurationChanged;
  @override
  Stream<void> get completed => _player.onPlayerComplete;
}

class VoicePlayer {
  VoicePlayer._();
  static final VoicePlayer instance = VoicePlayer._();

  /// Tests swap this before the first play.
  static VoiceBackend Function() backendFactory = AudioplayersBackend.new;

  VoiceBackend? _b;
  final List<StreamSubscription<Object?>> _subs = [];
  final ValueNotifier<VoiceState> state = ValueNotifier(const VoiceState());

  VoiceBackend _backend() {
    final have = _b;
    if (have != null) return have;
    final b = backendFactory();
    _b = b;
    _subs.add(b.position.listen((p) => _update(positionMs: p.inMilliseconds)));
    _subs.add(b.duration.listen((d) => _update(durationMs: d.inMilliseconds)));
    _subs.add(b.completed.listen((_) =>
        state.value = VoiceState(path: state.value.path, durationMs: state.value.durationMs)));
    return b;
  }

  void _update({int? positionMs, int? durationMs}) {
    final s = state.value;
    state.value = VoiceState(
        path: s.path,
        playing: s.playing,
        positionMs: positionMs ?? s.positionMs,
        durationMs: durationMs ?? s.durationMs);
  }

  /// Play / pause [path]. Returns false when this phone can't play it.
  Future<bool> toggle(String path, {int durationMs = 0}) async {
    try {
      final b = _backend();
      final s = state.value;
      if (s.path == path && s.playing) {
        await b.pause();
        state.value = VoiceState(path: path, positionMs: s.positionMs, durationMs: s.durationMs);
        return true;
      }
      if (s.path == path && s.positionMs > 0) {
        state.value = VoiceState(path: path, playing: true, positionMs: s.positionMs, durationMs: s.durationMs);
        await b.resume();
        return true;
      }
      if (s.path.isNotEmpty) await b.stop();
      state.value = VoiceState(path: path, playing: true, durationMs: durationMs);
      await b.play(path);
      return true;
    } catch (e) {
      reportNonFatal('md1_voice_play', e);
      state.value = const VoiceState();
      return false;
    }
  }

  /// Seek within the note that is (or was last) loaded.
  Future<void> seekFraction(String path, double f, int durationMs) async {
    final s = state.value;
    final dur = s.path == path && s.durationMs > 0 ? s.durationMs : durationMs;
    if (dur <= 0) return;
    final ms = (dur * f.clamp(0.0, 1.0)).round();
    try {
      if (s.path != path) {
        final ok = await toggle(path, durationMs: dur);
        if (!ok) return;
      }
      await _backend().seek(Duration(milliseconds: ms));
      _update(positionMs: ms);
    } catch (e) {
      reportNonFatal('md1_voice_seek', e);
    }
  }

  Future<void> stop() async {
    try {
      await _b?.stop();
    } catch (e) {
      reportNonFatal('md1_voice_stop', e);
    }
    state.value = const VoiceState();
  }
}
