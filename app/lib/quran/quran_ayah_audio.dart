// quranview: per-ayah recitation (Quran Foundation audio URL) with a repeat
// count. Streams only — the file is never saved on the phone (QF terms: no
// copy kept past 7 days outside Content Sync). Never quranicaudio.com /
// EveryAyah. Playback goes through the app-wide AudioRouteService.
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import '../audio/audio_route_service.dart';

/// Minimal player seam (tests use a fake).
abstract class QvPlayer {
  Future<void> playUrl(String url);
  Future<void> stop();
  Stream<void> get completed;
  Future<void> dispose();
}

class _RealPlayer implements QvPlayer {
  AudioPlayer? _p;
  AudioPlayer get _player =>
      _p ??= AudioPlayer()..setReleaseMode(ReleaseMode.stop);
  @override
  Future<void> playUrl(String url) => _player.play(UrlSource(url));
  @override
  Future<void> stop() async => _p?.stop();
  @override
  Stream<void> get completed => _player.onPlayerComplete;
  @override
  Future<void> dispose() async => _p?.dispose();
}

bool qvBannedAudio(String url) {
  final u = url.toLowerCase();
  return u.contains('quranicaudio.com') || u.contains('everyayah.com');
}

/// Plays one ayah [repeat] times. [onState] gets (playingIndex 1..n, or 0
/// when stopped) and an error flag.
class QuranAyahAudio {
  final QvPlayer _p;
  final void Function(int index, bool failed) onState;
  StreamSubscription<void>? _sub;
  int _left = 0;
  int _total = 0;
  String? _url;

  QuranAyahAudio({required this.onState, QvPlayer? player})
      : _p = player ?? _RealPlayer();

  bool get playing => _left > 0;

  Future<void> play(String url, int repeat) async {
    await stop();
    if (url.isEmpty || qvBannedAudio(url)) {
      onState(0, true);
      return;
    }
    _url = url;
    _total = repeat.clamp(1, 99);
    _left = _total;
    _sub = _p.completed.listen((_) => _next());
    await _start();
  }

  Future<void> _start() async {
    try {
      await AudioRouteService.instance.preparePlayback(AudioUse.media);
      onState(_total - _left + 1, false);
      await _p.playUrl(_url!);
    } catch (_) {
      await stop();
      onState(0, true);
    }
  }

  void _next() {
    if (_left <= 0) return;
    _left--;
    if (_left > 0) {
      _start();
    } else {
      _sub?.cancel();
      _sub = null;
      onState(0, false);
    }
  }

  Future<void> stop() async {
    final was = _left > 0;
    _left = 0;
    await _sub?.cancel();
    _sub = null;
    try {
      await _p.stop();
    } catch (_) {}
    if (was) onState(0, false);
  }

  Future<void> dispose() async {
    _left = 0;
    await _sub?.cancel();
    try {
      await _p.dispose();
    } catch (_) {}
  }
}
