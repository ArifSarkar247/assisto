import 'package:flutter/widgets.dart';

import 'call_controller.dart';

/// callsB: OPTIONAL capabilities of a call's media, kept out of [CallMedia]
/// so existing implementations (fakes, the broken-WebRTC fallback) stay
/// valid. The screens check `media is ScreenShareMedia` / `is MeshHost`.

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

/// Media that can send the phone's screen instead of the camera.
abstract class ScreenShareMedia {
  /// Ask the system consent (MediaProjection dialog), then run
  /// [beforeCapture] (starts the mediaProjection foreground service — it
  /// must run AFTER consent and BEFORE the capture on Android 14+; false =
  /// refuse), then capture and send the screen on every peer connection.
  /// Returns the medias (this one and/or its group links) that had no video
  /// sender yet and need a renegotiation. Throws [ScreenShareDenied] /
  /// [ScreenShareFailed].
  Future<List<Object>> startScreenShare(
      {required Future<bool> Function() beforeCapture});

  /// Back to the camera (or nothing when the camera is off); releases the
  /// capture. Never throws.
  Future<void> stopScreenShare();

  bool get screenSharing;
}

/// A remote video that shows a shared screen uncropped (contain).
abstract class ScreenShareSurface {
  Widget remoteScreenView();
}

/// The remote audio level of one peer connection (0..1, null = unknown) —
/// the "who is speaking" ring.
abstract class AudioLevelMedia {
  Future<double?> remoteAudioLevel();
}

/// callsB group calls: the ONE local mic/camera shared by every pair link
/// (each link = its own peer connection). [WebRtcCallMedia] is the host.
abstract class MeshHost {
  /// A [CallMedia] for one more pair link that sends THIS host's tracks.
  CallMedia createLinkMedia();

  /// Open mic (+ camera) without a 1:1 peer connection (joining a group call
  /// from the chat). Idempotent.
  Future<void> openLocal({required bool video});

  /// 3-4 people: lower the video bitrate / resolution / frame rate on every
  /// link (each phone sends its video 2-3 times on a mesh).
  Future<void> setLowBandwidth(bool on);

  /// My own microphone level (0..1, null = unknown).
  Future<double?> localAudioLevel();

  /// My camera preview (null before the camera opened).
  Widget localPreview({bool mirror = true});

  /// The host's own peer connection is gone (its 1:1 call ended) but group
  /// links still use the local tracks: release everything once they are
  /// closed. [releaseAll] forces it (the group call ended).
  Future<void> releaseAll();
}
