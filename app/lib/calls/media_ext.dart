import 'package:flutter/widgets.dart';

/// circle-screenshare: OPTIONAL capabilities of a call's media, kept out of
/// [CallMedia] so every existing implementation (fakes, the broken-WebRTC
/// fallback) stays valid. The call screen checks `media is ScreenShareMedia`.

/// The user refused the system screen-capture dialog.
class ScreenShareDenied implements Exception {
  const ScreenShareDenied();
  @override
  String toString() => 'ScreenShareDenied';
}

/// Screen sharing could not start (service refused, capture failed).
class ScreenShareFailed implements Exception {
  const ScreenShareFailed(this.why);
  final String why;
  @override
  String toString() => 'ScreenShareFailed($why)';
}

/// Media that can send the phone's screen in place of the camera.
abstract class ScreenShareMedia {
  /// 1. the SYSTEM consent (MediaProjection dialog — every time: Android 14
  ///    tokens are single-use), 2. [beforeCapture] (starts the
  ///    mediaProjection foreground service: Android 14+ requires it AFTER
  ///    consent and BEFORE the projection is created; false = refuse),
  /// 3. capture and put the screen on the video sender (replaceTrack — no
  ///    renegotiation) or, with no video sender yet, add it.
  /// Returns true when a sender was ADDED and the call must renegotiate.
  /// Throws [ScreenShareDenied] / [ScreenShareFailed].
  Future<bool> startScreenShare(
      {required Future<bool> Function() beforeCapture});

  /// Back to the camera (nothing when the camera is off); releases the
  /// capture. Never throws.
  Future<void> stopScreenShare();

  bool get screenSharing;
}

/// The other person's video drawn UNCROPPED (contain) — a shared screen
/// must show every edge (text, buttons), never cover-cropped.
abstract class ScreenShareSurface {
  Widget remoteScreenView();
}

/// Screen-share encoding caps (pure; unit-tested). A phone screen is ~1080 x
/// 2400: half resolution keeps text readable, a screen changes slowly so
/// 10 fps is enough, and the TURN relay / mobile data stay cheap. Low-data
/// calls go to a third of the resolution, 5 fps, 450 kbit/s.
class ScreenShareCaps {
  const ScreenShareCaps(this.maxBitrate, this.maxFramerate, this.scaleDown);
  final int maxBitrate;
  final int maxFramerate;
  final double scaleDown;

  static const normal = ScreenShareCaps(1000000, 10, 2.0);
  static const low = ScreenShareCaps(450000, 5, 3.0);

  /// The screen caps, never above what the call's network plan allows for
  /// video (a weak network keeps its lower numbers). [lowData] = the user's
  /// (or the other phone's) low-data mode.
  static ScreenShareCaps forPlan(
      {required bool lowData, int? planMaxBps, int? planMaxFps, double? planScale}) {
    final b = lowData ? low : normal;
    return ScreenShareCaps(
      planMaxBps != null && planMaxBps > 0 && planMaxBps < b.maxBitrate
          ? planMaxBps
          : b.maxBitrate,
      planMaxFps != null && planMaxFps > 0 && planMaxFps < b.maxFramerate
          ? planMaxFps
          : b.maxFramerate,
      planScale != null && planScale > b.scaleDown ? planScale : b.scaleDown,
    );
  }
}
