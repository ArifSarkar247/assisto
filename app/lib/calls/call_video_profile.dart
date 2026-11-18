import '../perf/low_ram.dart';
import 'call_net_policy.dart' show VideoCapture, videoCaptureFor;

/// calls-quality (lead 18 Nov): the camera size for a video call, decided
/// when the camera opens — 1280x720 on a capable phone with a good uplink,
/// 640x480 on a low-RAM phone (≤ 3 GB), an unknown phone, or after the last
/// call measured a weak uplink. The LIVE step-down after that is the
/// encoder's job (CallNetPolicy's resolution ladder + WebRTC's own
/// BALANCED degradation), so the camera never has to reopen mid-call.
class CallVideoProfile {
  CallVideoProfile._();

  /// Total RAM (MB) and Android's low-RAM flag (LowRamTuning reads them once
  /// at app start). Tests replace these.
  static int Function() ramMb = () => LowRamTuning.ramMb;
  static bool Function() lowRam = () => LowRamTuning.lowRam;

  /// The uplink the LAST video call measured (smoothed available send
  /// bitrate, kbit/s) — null until a call has run in this app session, and
  /// forgotten after [uplinkMemory] (the phone may be on another network).
  static double? get lastUplinkKbps {
    final at = _uplinkAt;
    if (at == null || now().difference(at) > uplinkMemory) return null;
    return _uplink;
  }

  static set lastUplinkKbps(double? v) {
    _uplink = v;
    _uplinkAt = v == null ? null : now();
  }

  static double? _uplink;
  static DateTime? _uplinkAt;
  static const uplinkMemory = Duration(minutes: 30);
  static DateTime Function() now = DateTime.now;

  /// Test override (integration tests only); null = decide from the phone.
  static VideoCapture? forced;

  static VideoCapture get capture =>
      forced ??
      videoCaptureFor(
          ramMb: ramMb(), lowRam: lowRam(), lastUplinkKbps: lastUplinkKbps);

  /// getUserMedia numbers for [c] (PLAIN numbers — see webrtc_media.dart).
  static Map<String, dynamic> constraintsFor(VideoCapture c) =>
      c == VideoCapture.hd720
          ? const {'width': 1280, 'height': 720, 'frameRate': 24}
          : const {'width': 640, 'height': 480, 'frameRate': 24};
}
