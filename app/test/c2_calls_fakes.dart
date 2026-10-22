// c2-calls fakes: a fake peer (media), fake signalling and fake sounds for
// CallController tests + the call-screen gallery states.
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_video.dart';

class FakeCallMedia implements CallMedia {
  FakeCallMedia({this.openError});
  MediaOpenException? openError;
  final log = <String>[];
  final cands = StreamController<Map<String, dynamic>>.broadcast();
  final link = StreamController<MediaLinkState>.broadcast();
  MediaStats nextStats = const MediaStats(rttMs: 80, lossPct: 0.5);
  bool disposed = false;
  List<Map<String, dynamic>>? ice;

  @override
  Future<void> open({required bool video}) async {
    log.add('open:${video ? 'video' : 'audio'}');
    final e = openError;
    if (e != null) throw e;
  }

  @override
  Future<void> createPeer(List<Map<String, dynamic>> iceServers) async {
    ice = iceServers;
    log.add('peer');
  }

  @override
  Future<Map<String, dynamic>> createOffer({bool iceRestart = false}) async {
    log.add(iceRestart ? 'offer:restart' : 'offer');
    return {'type': 'offer', 'sdp': iceRestart ? 'v=0 restart' : 'v=0 offer'};
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(Map<String, dynamic> offer) async {
    log.add('accept-offer:${offer['sdp']}');
    return {'type': 'answer', 'sdp': 'v=0 answer'};
  }

  @override
  Future<void> setAnswer(Map<String, dynamic> answer) async =>
      log.add('set-answer:${answer['sdp']}');

  @override
  Future<void> addCandidate(Map<String, dynamic> c) async =>
      log.add('cand:${c['candidate']}');

  @override
  Stream<Map<String, dynamic>> get localCandidates => cands.stream;
  @override
  Stream<MediaLinkState> get linkState => link.stream;

  @override
  Future<void> setMuted(bool muted) async => log.add('muted:$muted');
  @override
  Future<void> setCameraEnabled(bool on) async => log.add('camera:$on');
  @override
  Future<void> switchCamera() async => log.add('switch');
  @override
  Future<void> setSpeaker(bool on) async => log.add('speaker:$on');
  @override
  Future<MediaStats> stats() async => nextStats;
  @override
  Future<void> dispose() async {
    disposed = true;
    log.add('dispose');
  }
}

class FakeSignaling implements CallSignaling {
  FakeSignaling({
    Map<String, dynamic>? placeBody,
    Map<String, dynamic>? acceptBody,
    this.rtc = const {
      'configured': true,
      'throttled': false,
      'ice_servers': [
        {
          'urls': ['stun:turn.example:3478']
        },
        {
          'urls': ['turn:turn.example:3478?transport=udp'],
          'username': 'u',
          'credential': 'c'
        }
      ]
    },
  })  : placeBody = placeBody ??
            {
              'allowed': true,
              'call_id': 42,
              'phase': 'calling',
              'end_reason': ''
            },
        acceptBody = acceptBody ?? {'phase': 'accepted', 'call_id': 42};

  Map<String, dynamic> placeBody;
  Map<String, dynamic> acceptBody;
  Map<String, dynamic>? rtc;
  Map<String, dynamic> statusBody = {'phase': 'calling'};
  final eventLog = <String>[];
  final signals = <(String, Map<String, dynamic>)>[];
  final backlogItems = <Map<String, dynamic>>[];
  final _ev = StreamController<Map<String, dynamic>>.broadcast();
  int fast = 0;
  int _seq = 100;

  /// Push a server event into the controller.
  void state(String phase, {String endReason = '', String side = 'caller'}) =>
      _ev.add({
        'seq': ++_seq,
        'topic': 'call.state',
        'payload': {
          'call_id': 42,
          'phase': phase,
          'end_reason': endReason,
          'side': side
        }
      });

  void remoteSignal(String kind, Map<String, dynamic> data,
          {String from = 'callee'}) =>
      _ev.add({
        'seq': ++_seq,
        'topic': 'call.signal',
        'payload': {'call_id': 42, 'kind': kind, 'from': from, 'data': data}
      });

  final placeKeys = <String?>[];

  @override
  Future<Map<String, dynamic>> place(int memberId, String kind,
      {String? clientCallId}) async {
    eventLog.add('place:$memberId:$kind');
    placeKeys.add(clientCallId);
    return placeBody;
  }

  @override
  Future<Map<String, dynamic>> accept(int callId) async {
    eventLog.add('accept:$callId');
    return acceptBody;
  }

  @override
  Future<Map<String, dynamic>> event(int callId, String event,
      {bool? relayed}) async {
    eventLog.add(relayed == null ? event : '$event:relayed=$relayed');
    return {'phase': 'ended'};
  }

  @override
  Future<void> signal(
          int callId, String kind, Map<String, dynamic> data) async =>
      signals.add((kind, data));

  @override
  Future<Map<String, dynamic>> status(int callId) async => statusBody;

  @override
  Future<Map<String, dynamic>?> rtcConfig() async => rtc;

  @override
  Stream<Map<String, dynamic>> events(int callId) => _ev.stream;

  @override
  Future<List<Map<String, dynamic>>> backlog(int callId) async => backlogItems;

  @override
  void setFast(bool on) => fast += on ? 1 : -1;
}

class FakeSounds implements CallSounds {
  final log = <String>[];
  @override
  Future<void> startRingback() async => log.add('ringback');
  @override
  Future<void> stopRingback() async => log.add('stop-ringback');
  @override
  Future<void> playBusy() async => log.add('busy');
  @override
  Future<void> playDeclined() async => log.add('declined');
  @override
  Future<void> playEnded() async => log.add('ended');
  @override
  Future<void> stopAll() async => log.add('stop-all');
  @override
  Future<void> setProximity(bool on) async => log.add('proximity:$on');
}

/// Gallery video surface: coloured panels instead of camera frames.
class FakeSurface implements CallVideoSurface {
  FakeSurface({bool remote = true}) : hasRemoteVideo = ValueNotifier(remote);
  @override
  final ValueNotifier<bool> hasRemoteVideo;
  @override
  Widget localView({bool mirror = true}) => const DecoratedBox(
      decoration: BoxDecoration(
          gradient:
              LinearGradient(colors: [Color(0xFF3A4F7A), Color(0xFF6C8CC7)])),
      child:
          Center(child: Icon(Icons.person, color: Colors.white70, size: 48)));
  @override
  Widget remoteView() => const DecoratedBox(
      decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF6B4E3D), Color(0xFF2D3A4A)])),
      child:
          Center(child: Icon(Icons.face_3, color: Colors.white54, size: 160)));
}

/// A controller frozen in [phase] (gallery).
CallController previewController({
  required bool video,
  required bool outgoing,
  required CallPhase phase,
  CallEndReason reason = CallEndReason.none,
  bool turn = true,
  CallQuality quality = CallQuality.good,
  bool muted = false,
  bool speaker = false,
  bool remoteCamera = true,
}) {
  final c = CallController(
    media: FakeCallMedia(),
    signaling: FakeSignaling(),
    sounds: FakeSounds(),
    video: video,
    outgoing: outgoing,
    memberId: 1,
    callId: 42,
    now: () => DateTime(2026, 10, 22, 10, 4, 7),
  );
  c.phase = phase;
  c.endReason = reason;
  c.turnAvailable = turn;
  c.quality = quality;
  c.muted = muted;
  c.speakerOn = speaker || video;
  c.remoteCameraOn = remoteCamera;
  if (phase == CallPhase.connected || phase == CallPhase.reconnecting) {
    c.connectedAt = DateTime(2026, 10, 22, 10, 0, 0);
  }
  return c;
}
