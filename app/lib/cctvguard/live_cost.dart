import 'dart:async';

/// cctvguard (owner CCTV order G) — pure, testable cost-guard logic for live
/// view. No Flutter / WebRTC imports, so the unit tests run without a phone.
///
/// * [LivePath]: which way the video goes — the SAME Wi-Fi (host↔host), a
///   direct internet path (srflx, P2P) or our TURN relay (the only one that
///   costs us and counts against the monthly relay allowance).
/// * [RelayCandidateHold]: "prefer P2P + LAN" — our relay candidates are held
///   back for a moment; if a direct / same-Wi-Fi path connects first they are
///   never offered, so the relay is used only when nothing else works.
/// * [VendorIdle]: the 5-minute "no touch" stop for Imou / EZVIZ live.
enum LivePath { lan, direct, relay, unknown }

class LiveCost {
  LiveCost._();

  static final RegExp _typRelay = RegExp(r'(^|\s)typ\s+relay(\s|$)');

  /// True for an ICE candidate line of type relay (TURN).
  static bool isRelayCandidate(Object? candidate) =>
      candidate is String && _typRelay.hasMatch(candidate);

  /// The path of the selected candidate pair from the two candidate types.
  static LivePath pathOf(String? localType, String? remoteType) {
    if (localType == null && remoteType == null) return LivePath.unknown;
    if (localType == 'relay' || remoteType == 'relay') return LivePath.relay;
    if (localType == 'host' && remoteType == 'host') return LivePath.lan;
    return LivePath.direct;
  }

  static LivePath parse(Object? s) => switch (s) {
        'lan' => LivePath.lan,
        'direct' => LivePath.direct,
        'relay' => LivePath.relay,
        _ => LivePath.unknown,
      };

  /// Seconds between usage reports to the server while a live view runs.
  static const int reportEverySeconds = 60;

  /// Megabytes with one decimal (server meter uses 1 MB = 1,000,000 bytes).
  static String mb(num bytes) => (bytes / 1000000).toStringAsFixed(1);
}

/// Holds relay candidates for [hold]; if [connected] comes first they are
/// dropped (a direct / same-Wi-Fi path won). Host / srflx candidates go out
/// at once. Never blocks a connection: after [hold] the relay ones are sent.
class RelayCandidateHold {
  final Duration hold;
  final void Function(Map<String, dynamic> candidate) send;
  final List<Map<String, dynamic>> _held = [];
  bool _connected = false;
  bool _released = false;
  Timer? _timer;

  RelayCandidateHold({required this.send, this.hold = const Duration(milliseconds: 1500)});

  int get heldCount => _held.length;
  bool get released => _released;

  void offer(Map<String, dynamic> c) {
    final relay = LiveCost.isRelayCandidate(c['candidate']);
    if (!relay || _released || hold == Duration.zero) {
      send(c);
      return;
    }
    if (_connected) return; // a direct / same-Wi-Fi path already won
    _held.add(c);
    _timer ??= Timer(hold, release);
  }

  /// The peer connection reached "connected" — a non-relay path won if the
  /// relay candidates were never released.
  void connected() {
    _connected = true;
    _timer?.cancel();
    _held.clear();
  }

  void release() {
    if (_connected || _released) return;
    _released = true;
    final out = List<Map<String, dynamic>>.of(_held);
    _held.clear();
    for (final c in out) {
      send(c);
    }
  }

  void dispose() {
    _timer?.cancel();
    _held.clear();
  }
}

/// The idle stop of a vendor (Imou / EZVIZ) live view: [left] counts down
/// every second and a touch resets it; touches are sent to the server at
/// most every [sendEvery].
class VendorIdle {
  final int idleSeconds;
  final Duration sendEvery;
  int left;
  DateTime? _lastSent;

  VendorIdle({this.idleSeconds = 300, this.sendEvery = const Duration(seconds: 15)})
      : left = idleSeconds;

  /// One second passed; true when the view must stop now.
  bool tick() {
    if (left > 0) left -= 1;
    return left <= 0;
  }

  /// A touch: resets the countdown; true when the server should be told.
  bool touch(DateTime now) {
    left = idleSeconds;
    if (_lastSent != null && now.difference(_lastSent!) < sendEvery) return false;
    _lastSent = now;
    return true;
  }
}
