import 'api.dart';

/// WebRTC ICE config for Connected-Circle calls (Step 6 M3). Fetches the
/// self-hosted STUN/TURN servers + time-limited credentials from the backend
/// (`GET /rtc/turn`), which also decides — server-side — whether a call may
/// start right now:
///   * configured == false  -> the TURN server isn't set up / reachable yet
///                             (ports not open) -> show "call server not
///                             reachable" and don't attempt the call.
///   * throttled  == true   -> the shared box is under load; back off BEFORE
///                             starting a call so Asalify is never slowed
///                             -> show "call server busy, try again".
///   * otherwise            -> [iceServers] is ready to feed to RTCPeerConnection.
extension RtcApi on ApiClient {
  Future<RtcConfig> rtcTurn() async {
    try {
      final j = await getJson('/rtc/turn');
      return RtcConfig.fromJson(j);
    } on ApiException {
      // Auth/other server error — treat as not reachable (honest fallback).
      return const RtcConfig(configured: false, throttled: false);
    } catch (_) {
      return const RtcConfig(configured: false, throttled: false);
    }
  }
}

/// The ICE/throttle decision from the server.
class RtcConfig {
  final bool configured;
  final bool throttled;
  final String reason;
  final List<Map<String, dynamic>> iceServers;
  final int ttl;

  const RtcConfig({
    required this.configured,
    required this.throttled,
    this.reason = '',
    this.iceServers = const [],
    this.ttl = 0,
  });

  /// True iff a call may start right now and we have ICE servers to use.
  bool get callable => configured && !throttled && iceServers.isNotEmpty;

  factory RtcConfig.fromJson(Map<String, dynamic> j) => RtcConfig(
        configured: j['configured'] == true,
        throttled: j['throttled'] == true,
        reason: (j['reason'] ?? '').toString(),
        iceServers: ((j['ice_servers'] ?? const []) as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(),
        ttl: (j['ttl'] is num) ? (j['ttl'] as num).toInt() : 0,
      );
}
