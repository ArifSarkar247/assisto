import 'dart:async';

import 'package:assisto/calls/call_controller.dart'
    show MediaLinkState, MediaOpenException;
import 'package:assisto/calls/group_call_controller.dart';

/// group-calls test fakes: a tiny in-memory "server" (rooms, legs, the
/// rt/events queue per person) that follows the same rules as
/// core/views_group_calls.py, and a fake WebRTC side per phone that reports
/// a leg connected only when BOTH phones applied an offer and its answer.

class FakeClock {
  DateTime t = DateTime(2026, 11, 17, 12);
  DateTime now() => t;
  void tick([Duration d = const Duration(seconds: 1)]) => t = t.add(d);
}

class Hub {
  Hub({this.kind = 'voice'});
  String kind;
  int seq = 100;
  int _leg = 500;
  bool live = true;
  final clock = FakeClock();
  final Map<int, String> state = {};
  final Map<int, int> ringBy = {};
  final Map<int, (int, int)> legs = {};
  final Set<int> ended = {};
  final Map<int, List<Map<String, dynamic>>> sent = {};
  final Map<int, StreamController<Map<String, dynamic>>> streams = {};
  final Map<int, FakeGroupMedia> medias = {};
  final Map<int, bool> muted = {};
  final Map<int, bool> camera = {};
  final List<String> serverEvents = [];
  final Set<int> blocked = {};
  String? joinError;

  StreamController<Map<String, dynamic>> streamOf(int uid) =>
      streams[uid] ??= StreamController<Map<String, dynamic>>.broadcast();

  void emit(int uid, String topic, Map<String, dynamic> payload) {
    final e = {'seq': ++seq, 'topic': topic, 'payload': payload};
    (sent[uid] ??= []).add(e);
    streams[uid]?.add(e);
  }

  bool _liveLeg(int id) => legs.containsKey(id) && !ended.contains(id);

  int get seated =>
      state.values.where((s) => s == 'joined' || s == 'ringing').length;

  Map<String, dynamic> snap(int uid) => {
        'room_id': 1,
        'kind': kind,
        'live': live,
        'state': live ? 'live' : 'ended',
        'max': 8,
        'seats_taken': seated,
        'free': 8 - seated,
        'video_kbps': seated >= 5 ? 80 : 150,
        'data_mb_per_min': 1.4,
        'full_message': 'FULL',
        'seq': seq,
        'members': [
          for (final e in state.entries)
            {
              'user_id': e.key,
              'name': 'P${e.key}',
              'state': e.value,
              'is_me': e.key == uid,
              'muted': muted[e.key] ?? false,
              'camera': camera[e.key] ?? false,
            }
        ],
        'legs': [
          for (final e in legs.entries)
            if (_liveLeg(e.key) && (e.value.$1 == uid || e.value.$2 == uid))
              {
                'call_id': e.key,
                'peer_id': e.value.$1 == uid ? e.value.$2 : e.value.$1,
                'offerer': e.value.$1 == uid,
                'state': 'connecting',
              }
        ],
      };

  void changed() {
    for (final u in state.keys) {
      if (state[u] == 'joined' || state[u] == 'ringing') {
        emit(u, 'group.state', {'room_id': 1});
      }
    }
  }

  /// The host starts: rings [others].
  Map<String, dynamic> hostStart(int host, List<int> others) {
    state[host] = 'joined';
    for (final o in others) {
      state[o] = 'ringing';
      ringBy[o] = host;
    }
    return snap(host);
  }

  Map<String, dynamic> join(int uid) {
    if (joinError != null) throw GroupCallError(joinError!);
    final seq0 = seq;
    final inviter = ringBy.remove(uid);
    if (state[uid] != 'joined' && seated >= 8) {
      throw const GroupCallError('full');
    }
    state[uid] = 'joined';
    if (inviter != null && state[inviter] == 'joined') {
      final id = ++_leg;
      legs[id] = (inviter, uid); // the accepted ring: the inviter offers
      emit(inviter, 'call.state',
          {'call_id': id, 'phase': 'accepted', 'room_id': 1});
    }
    for (final other in state.keys.toList()) {
      if (other == uid || state[other] != 'joined') continue;
      final has = legs.entries.any((e) =>
          _liveLeg(e.key) &&
          ((e.value.$1 == uid && e.value.$2 == other) ||
              (e.value.$1 == other && e.value.$2 == uid)));
      if (has) continue;
      final id = ++_leg;
      legs[id] = (uid, other);
      emit(other, 'group.leg', {'room_id': 1, 'call_id': id, 'peer_id': uid});
    }
    changed();
    return {...snap(uid), 'seq': seq0};
  }

  void leave(int uid) {
    state[uid] = 'left';
    for (final e in legs.entries) {
      if (!_liveLeg(e.key)) continue;
      if (e.value.$1 != uid && e.value.$2 != uid) continue;
      ended.add(e.key);
      final other = e.value.$1 == uid ? e.value.$2 : e.value.$1;
      emit(other, 'call.state', {'call_id': e.key, 'phase': 'ended'});
    }
    final joined = state.values.where((s) => s == 'joined').length;
    final ringing = state.values.where((s) => s == 'ringing').length;
    if (joined <= 1 && ringing == 0 || joined == 0) {
      live = false;
      for (final u in state.keys) {
        if (state[u] == 'joined') state[u] = 'left';
        emit(u, 'group.state', {'room_id': 1, 'ended': true});
      }
      return;
    }
    changed();
  }

  void signal(int from, int leg, String kind, Map<String, dynamic> data) {
    final p = legs[leg];
    if (p == null || ended.contains(leg)) return;
    final to = p.$1 == from ? p.$2 : p.$1;
    emit(to, 'call.signal', {'call_id': leg, 'kind': kind, 'data': data});
  }

  /// A leg is up when both phones hold a peer with local + remote SDP.
  void checkUp(int leg) {
    final p = legs[leg];
    if (p == null) return;
    final a = medias[p.$1]?.peers[leg], b = medias[p.$2]?.peers[leg];
    if (a == null || b == null) return;
    if (a.local && a.remote && b.local && b.remote && !(a.up && b.up)) {
      a.up = true;
      b.up = true;
      medias[p.$1]!.link(leg, MediaLinkState.connected);
      medias[p.$2]!.link(leg, MediaLinkState.connected);
    }
  }
}

class FakePeer {
  bool local = false;
  bool remote = false;
  bool up = false;
  String? lastRemoteSdp;
}

class FakeGroupMedia implements GroupMedia {
  FakeGroupMedia(this.hub, this.uid, {this.denyMic = false}) {
    hub.medias[uid] = this;
  }
  final Hub hub;
  final int uid;
  final bool denyMic;
  final Map<int, FakePeer> peers = {};
  final _cands = StreamController<LegCandidate>.broadcast();
  final _links = StreamController<LegLink>.broadcast();
  final Map<int, double> levels = {}; // peer user id -> loudness
  int _n = 0;
  bool opened = false;
  bool disposed = false;
  bool mutedNow = false;

  void link(int leg, MediaLinkState s) => _links.add(LegLink(leg, s));

  @override
  bool cameraUnavailable = false;

  @override
  Future<void> open({required bool video}) async {
    if (denyMic) throw MediaOpenException(true, 'denied');
    opened = true;
  }

  @override
  Future<void> addPeer(int legId, List<Map<String, dynamic>> iceServers,
      {required bool video}) async {
    peers[legId] = FakePeer();
  }

  @override
  Future<Map<String, dynamic>> createOffer(int legId) async {
    peers[legId]!.local = true;
    return {'type': 'offer', 'sdp': 'o-$uid-$legId-${++_n}'};
  }

  @override
  Future<Map<String, dynamic>> acceptOffer(
      int legId, Map<String, dynamic> offer) async {
    final p = peers[legId]!;
    p.remote = true;
    p.local = true;
    p.lastRemoteSdp = '${offer['sdp']}';
    _cands.add(LegCandidate(legId, {'candidate': 'c-$uid'}));
    scheduleMicrotask(() => hub.checkUp(legId));
    return {'type': 'answer', 'sdp': 'a-$uid-$legId-${++_n}'};
  }

  @override
  Future<void> setAnswer(int legId, Map<String, dynamic> answer) async {
    final p = peers[legId]!;
    p.remote = true;
    p.lastRemoteSdp = '${answer['sdp']}';
    scheduleMicrotask(() => hub.checkUp(legId));
  }

  @override
  Future<void> addCandidate(int legId, Map<String, dynamic> c) async {}

  @override
  Future<void> closePeer(int legId) async {
    peers.remove(legId);
  }

  @override
  Stream<LegCandidate> get localCandidates => _cands.stream;

  @override
  Stream<LegLink> get linkStates => _links.stream;

  /// Inbound media keeps flowing on a leg that is up: ~50 audio packets a
  /// second (Opus 20 ms), video frames when the other person's camera is on.
  @override
  Future<LegStats> stats(int legId) async {
    final p = peers[legId];
    final pair = hub.legs[legId];
    if (p == null || !p.up || pair == null) return const LegStats();
    final other = pair.$1 == uid ? pair.$2 : pair.$1;
    final s = hub.clock.now().millisecondsSinceEpoch ~/ 1000 % 100000;
    final otherMuted = hub.medias[other]?.mutedNow ?? false;
    return LegStats(
      audioPacketsIn: s * 50,
      audioBytesIn: s * 4000,
      videoFramesDecoded:
          (hub.camera[other] ?? false) ? s * 15 : 0,
      audioLevel: otherMuted ? 0 : (levels[other] ?? 0),
      bytesSent: s * 5000,
      bytesReceived: s * 5000,
    );
  }

  @override
  Future<void> setMuted(bool muted) async => mutedNow = muted;
  @override
  Future<void> setCameraEnabled(bool on) async {}
  @override
  Future<void> switchCamera() async {}
  @override
  Future<void> setSpeaker(bool on) async {}
  @override
  Future<void> setVideoKbps(int kbps) async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    peers.clear();
  }
}

class FakeGroupSignaling implements GroupSignaling {
  FakeGroupSignaling(this.hub, this.uid);
  final Hub hub;
  final int uid;
  final List<String> events_ = [];

  @override
  Future<Map<String, dynamic>> snapshot(int roomId) async => hub.snap(uid);

  @override
  Future<Map<String, dynamic>> join(int roomId, {int? callId}) async =>
      hub.join(uid);

  @override
  Future<void> leave(int roomId) async => hub.leave(uid);

  @override
  Future<Map<String, dynamic>> invite(int roomId, List<int> userIds) async {
    final results = <Map<String, dynamic>>[];
    for (final u in userIds) {
      if (hub.blocked.contains(u)) {
        results.add({'user_id': u, 'ok': false, 'code': 'unavailable'});
      } else if (hub.seated >= 8) {
        results.add({'user_id': u, 'ok': false, 'code': 'full'});
      } else {
        hub.state[u] = 'ringing';
        hub.ringBy[u] = uid;
        results.add({'user_id': u, 'ok': true});
      }
    }
    hub.changed();
    return {...hub.snap(uid), 'results': results};
  }

  @override
  Future<void> media(int roomId, {bool? muted, bool? camera}) async {
    if (muted != null) hub.muted[uid] = muted;
    if (camera != null) hub.camera[uid] = camera;
  }

  @override
  Future<void> signal(int legId, String kind, Map<String, dynamic> data) async =>
      hub.signal(uid, legId, kind, data);

  @override
  Future<void> event(int legId, String event, {bool? relayed}) async {
    events_.add('$legId:$event');
    hub.serverEvents.add('$uid:$legId:$event');
    if (event == 'fail') {
      hub.ended.add(legId);
      final p = hub.legs[legId]!;
      final other = p.$1 == uid ? p.$2 : p.$1;
      hub.emit(other, 'call.state', {'call_id': legId, 'phase': 'ended'});
    }
  }

  @override
  Stream<Map<String, dynamic>> get events => hub.streamOf(uid).stream;

  @override
  Future<List<Map<String, dynamic>>> backlog(int legId) async => [
        for (final e in hub.sent[uid] ?? const <Map<String, dynamic>>[])
          if (e['topic'] == 'call.signal' &&
              (e['payload'] as Map)['call_id'] == legId)
            e
      ];

  @override
  void setFast(bool on) {}
}

/// Let every queued event / microtask / short timer run.
Future<void> settle([int rounds = 30]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

GroupCallController phoneFor(Hub hub, int uid,
    {int? answer,
    int? adopt,
    int since = 0,
    bool video = false,
    bool denyMic = false,
    bool mobile = false}) {
  return GroupCallController(
    media: FakeGroupMedia(hub, uid, denyMic: denyMic),
    signaling: FakeGroupSignaling(hub, uid),
    roomId: 1,
    myId: uid,
    video: video,
    answerCallId: answer,
    adoptCallId: adopt,
    sinceSeq: since,
    onMobileData: mobile,
    now: hub.clock.now,
    pollEvery: const Duration(hours: 1),
    statsEvery: const Duration(hours: 1),
    offerWait: const Duration(milliseconds: 20),
    repairAfter: const Duration(hours: 1),
  );
}
