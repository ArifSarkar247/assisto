// gatefix (release gate run 44115922433): flutter_webrtc on Android drops a
// top-level offerToReceiveVideo, so a VIDEO call whose caller had no camera
// track offered no video m-line and the callee's camera never arrived. The
// rule: a video-call offer always carries a video m-line (receive-only when
// there is no local camera); a voice-call offer carries none.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/webrtc_media.dart';

void main() {
  test('video call with no local camera: offer gets a receive-only video m-line', () {
    expect(offerNeedsRecvOnlyVideo(videoCall: true, hasLocalVideo: false, alreadyAdded: false), isTrue);
  });

  test('video call with a camera: its own video track already makes the m-line', () {
    expect(offerNeedsRecvOnlyVideo(videoCall: true, hasLocalVideo: true, alreadyAdded: false), isFalse);
  });

  test('voice call: no video m-line in the offer', () {
    expect(offerNeedsRecvOnlyVideo(videoCall: false, hasLocalVideo: false, alreadyAdded: false), isFalse);
  });

  test('never added twice (ICE restart / renegotiation offers)', () {
    expect(offerNeedsRecvOnlyVideo(videoCall: true, hasLocalVideo: false, alreadyAdded: true), isFalse);
  });

  // calls-camfast: the camera-less m-line is SEND-capable (sendrecv, no
  // track) so a camera turned on later is a replaceTrack, not a renegotiation.
  test('createOffer applies the rule with a SendRecv VIDEO transceiver (no track) before createOffer', () {
    final src = File('lib/calls/webrtc_media.dart').readAsStringSync();
    final body = src.substring(src.indexOf('Future<Map<String, dynamic>> createOffer('));
    final rule = body.indexOf('offerNeedsRecvOnlyVideo(');
    final add = body.indexOf('RTCRtpMediaType.RTCRtpMediaTypeVideo');
    final recv = body.indexOf('TransceiverDirection.SendRecv');
    final offer = body.indexOf('_peer.createOffer(');
    expect(rule, greaterThan(-1));
    expect(add, greaterThan(rule));
    expect(recv, greaterThan(rule));
    expect(offer, greaterThan(add));
  });

  test('calls-camfast: a camera-less callee keeps a send-capable video m-line before createAnswer', () {
    final src = File('lib/calls/webrtc_media.dart').readAsStringSync();
    final body = src.substring(src.indexOf('Future<Map<String, dynamic>> acceptOffer('));
    final keep = body.indexOf('_keepVideoSendSlot()');
    final ans = body.indexOf('createAnswer(');
    expect(keep, greaterThan(-1));
    expect(ans, greaterThan(keep));
    final slot = src.substring(src.indexOf('Future<void> _keepVideoSendSlot()'));
    expect(slot.indexOf('TransceiverDirection.SendRecv'), greaterThan(-1));
    expect(slot.indexOf('setStreams('), greaterThan(-1));
  });
}
