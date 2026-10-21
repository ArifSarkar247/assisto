import 'package:flutter/material.dart';

/// Placeholder until the CCTV live-view native build: flutter_webrtc is not
/// linked in this build (the real implementation is parked in
/// .phaseB/pending_native/shop_live_rtc.dart and ships with its own launch
/// smoke). [create] always throws, and every caller already catches it and
/// shows the honest "could not connect" message.
class LivePeer {
  LivePeer._();

  static Future<LivePeer> create(
    List<Map<String, dynamic>> ice, {
    required bool sender,
    required void Function(Map<String, dynamic> candidate) onCandidate,
    void Function()? onRemoteVideo,
    void Function(String state)? onState,
  }) =>
      Future.error(UnsupportedError('live view is not in this build'));

  Future<Map<String, dynamic>> createOffer() => throw UnsupportedError('');
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) =>
      throw UnsupportedError('');
  Future<void> setRemote(Map<String, dynamic> sdp) async {}
  Future<void> addCandidate(Map<String, dynamic> c) async {}
  Future<bool> isRelayed() async => false;
  Widget view() => const SizedBox.shrink();
  Future<void> dispose() async {}
}
