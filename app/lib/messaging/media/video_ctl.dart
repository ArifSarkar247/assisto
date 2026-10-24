import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'video_player_impl.dart' deferred as vpi;

/// mc-media2 — the in-app video player behind a small interface, so the
/// player screen is tested with a fake and the real plugin (video_player →
/// media3 ExoPlayer) is a DEFERRED library: loaded on the first Play tap of a
/// video, never at app launch.
class VideoCtlState {
  final bool initialized;
  final bool playing;
  final bool buffering;
  final bool muted;
  final Duration position;
  final Duration duration;
  final Size size;
  final String error; // '' = fine
  const VideoCtlState({
    this.initialized = false,
    this.playing = false,
    this.buffering = false,
    this.muted = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.size = Size.zero,
    this.error = '',
  });

  bool get ended => initialized && duration > Duration.zero && position >= duration && !playing;

  double get aspect =>
      size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9;

  VideoCtlState copyWith({
    bool? initialized,
    bool? playing,
    bool? buffering,
    bool? muted,
    Duration? position,
    Duration? duration,
    Size? size,
    String? error,
  }) =>
      VideoCtlState(
        initialized: initialized ?? this.initialized,
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        muted: muted ?? this.muted,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        size: size ?? this.size,
        error: error ?? this.error,
      );
}

abstract class VideoCtl {
  ValueListenable<VideoCtlState> get state;
  Future<void> init();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration d);
  Future<void> setMuted(bool muted);

  /// The picture (a platform texture for the real player).
  Widget view();
  Future<void> dispose();
}

typedef VideoCtlFactory = Future<VideoCtl> Function(File file);

class VideoCtls {
  VideoCtls._();

  /// Tests swap this for a fake.
  static VideoCtlFactory factory = (file) async {
    await vpi.loadLibrary();
    return vpi.RealVideoCtl(file);
  };

  /// Duration + size of a local clip (the sender side), or null. Loads the
  /// player only for this, then releases it; any failure = null.
  static Future<VideoCtlState?> probe(File file,
      {Duration timeout = const Duration(seconds: 6)}) async {
    VideoCtl? c;
    try {
      c = await factory(file);
      await c.init().timeout(timeout);
      final s = c.state.value;
      return s.initialized && s.error.isEmpty ? s : null;
    } catch (_) {
      return null;
    } finally {
      try {
        await c?.dispose();
      } catch (_) {}
    }
  }
}
