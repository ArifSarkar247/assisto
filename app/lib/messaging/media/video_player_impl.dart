import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'video_ctl.dart';

/// mc-media2 — the REAL player (video_player 2.14.1 → media3 ExoPlayer on
/// Android). Imported ONLY as a deferred library from video_ctl.dart. Every
/// call is guarded: a codec the phone can't play becomes an honest error
/// state ("Open with another app"), never a crash.
class RealVideoCtl implements VideoCtl {
  RealVideoCtl(File file) : _c = VideoPlayerController.file(file);

  final VideoPlayerController _c;
  final ValueNotifier<VideoCtlState> _state = ValueNotifier(const VideoCtlState());
  bool _disposed = false;

  @override
  ValueListenable<VideoCtlState> get state => _state;

  void _sync() {
    if (_disposed) return;
    final v = _c.value;
    _state.value = VideoCtlState(
      initialized: v.isInitialized,
      playing: v.isPlaying,
      buffering: v.isBuffering,
      muted: v.volume == 0,
      position: v.position,
      duration: v.duration,
      size: v.size,
      error: v.hasError ? (v.errorDescription ?? 'error') : '',
    );
  }

  @override
  Future<void> init() async {
    try {
      await _c.initialize();
      _c.addListener(_sync);
      _sync();
    } catch (e) {
      _state.value = _state.value.copyWith(error: '$e');
    }
  }

  @override
  Future<void> play() async {
    try {
      final v = _c.value;
      if (v.isInitialized && v.duration > Duration.zero && v.position >= v.duration) {
        await _c.seekTo(Duration.zero);
      }
      await _c.play();
    } catch (e) {
      _state.value = _state.value.copyWith(error: '$e');
    }
  }

  @override
  Future<void> pause() async {
    try {
      await _c.pause();
    } catch (_) {}
  }

  @override
  Future<void> seekTo(Duration d) async {
    try {
      await _c.seekTo(d);
    } catch (_) {}
  }

  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _c.setVolume(muted ? 0 : 1);
      _sync();
    } catch (_) {}
  }

  @override
  Widget view() => VideoPlayer(_c);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _c.removeListener(_sync);
      await _c.dispose();
    } catch (_) {}
  }
}
