import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Widget;

import 'call_controller.dart' show MediaLinkState, MediaOpenException;
import 'call_log.dart';

/// group-calls (owner order 17 Nov): a My Circle group call on this phone.
///
/// MESH: the server (core/views_group_calls.py) makes every PAIR of people in
/// the call one normal 1:1 call record — a "leg". This phone keeps one peer
/// connection per leg, all sending the SAME microphone (and camera) stream.
/// The leg's record CALLER sends the offer; the other side answers. Offers
/// carry a generation number `g` (answers and ICE echo it), so a re-offer
/// after a network change / a handed-over 1:1 call can never mix with an old
/// one. Pure Dart: no plugin here ([GroupMedia] is the WebRTC side,
/// [GroupSignaling] the server side), so all of it is unit tested.

/// What one leg measured (inbound = what I RECEIVE from that person).
class LegStats {
  const LegStats({
    this.audioPacketsIn,
    this.audioBytesIn,
    this.videoFramesDecoded,
    this.audioLevel,
    this.bytesSent,
    this.bytesReceived,
  });
  final int? audioPacketsIn;
  final int? audioBytesIn;
  final int? videoFramesDecoded;

  /// 0..1 loudness of that person right now (inbound-rtp audioLevel).
  final double? audioLevel;
  final int? bytesSent;
  final int? bytesReceived;
}

class LegCandidate {
  const LegCandidate(this.legId, this.candidate);
  final int legId;
  final Map<String, dynamic> candidate;
}

class LegLink {
  const LegLink(this.legId, this.state);
  final int legId;
  final MediaLinkState state;
}

/// The WebRTC side: ONE local stream, one peer connection per leg.
abstract class GroupMedia {
  /// getUserMedia (mic, + camera for a video call). Throws
  /// [MediaOpenException].
  Future<void> open({required bool video});

  /// true when the camera could not start but the mic works.
  bool get cameraUnavailable;
  Future<void> addPeer(int legId, List<Map<String, dynamic>> iceServers,
      {required bool video});
  Future<Map<String, dynamic>> createOffer(int legId);
  Future<Map<String, dynamic>> acceptOffer(
      int legId, Map<String, dynamic> offer);
  Future<void> setAnswer(int legId, Map<String, dynamic> answer);
  Future<void> addCandidate(int legId, Map<String, dynamic> c);
  Future<void> closePeer(int legId);
  Stream<LegCandidate> get localCandidates;
  Stream<LegLink> get linkStates;
  Future<LegStats> stats(int legId);
  Future<void> setMuted(bool muted);
  Future<void> setCameraEnabled(bool on);
  Future<void> switchCamera();
  Future<void> setSpeaker(bool on);

  /// Video send cap per leg (kbit/s) — low data on mobile / many people.
  Future<void> setVideoKbps(int kbps);

  /// gatefix-style evidence for one leg (SDP, transceivers, rtp counters):
  /// printed by the e2e proof when a pair fails. {} when not available.
  Future<Map<String, dynamic>> debugEvidence(int legId);
  Future<void> dispose();
}

/// Optional: video views (the WebRTC implementation has them).
abstract class GroupVideoSurface {
  /// Fires when a remote video starts / stops (repaint the grid).
  Listenable get videoChanged;
  Widget localView();
  Widget? remoteView(int legId);
  bool hasRemoteVideo(int legId);
}

/// The server side (REST + the shared rt/events queue).
abstract class GroupSignaling {
  Future<Map<String, dynamic>> snapshot(int roomId);
  Future<Map<String, dynamic>> join(int roomId, {int? callId});
  Future<void> leave(int roomId);
  Future<Map<String, dynamic>> invite(int roomId, List<int> userIds);
  Future<void> media(int roomId, {bool? muted, bool? camera});
  Future<void> signal(int legId, String kind, Map<String, dynamic> data);
  Future<void> event(int legId, String event, {bool? relayed});

  /// Every real-time event for me: {seq, topic, payload}.
  Stream<Map<String, dynamic>> get events;

  /// Retained call.signal events of one leg (an offer sent before this
  /// phone listened).
  Future<List<Map<String, dynamic>>> backlog(int legId);
  void setFast(bool on);
}

/// A refusal from the server: [code] full | unavailable | not_found |
/// call_ended | upgrade_required | no_people | network; [message] is the
/// server's own words in the user's language (may be empty).
class GroupCallError implements Exception {
  const GroupCallError(this.code, [this.message = '', this.status]);
  final String code;
  final String message;
  final int? status;
  @override
  String toString() => 'GroupCallError($code${status == null ? '' : ' $status'})';
}

enum GroupCallPhase { joining, live, ended }

enum GroupEndReason {
  none,
  left, // I tapped hang up
  ended, // everyone else left
  full, // 8 people already
  unavailable, // not allowed (block / not a member)
  mediaDenied,
  mediaError,
  network,
}

/// One person's tile.
class GroupTile {
  GroupTile({
    required this.userId,
    required this.name,
    this.photoUrl = '',
    this.photoV = '',
    this.state = 'joined',
    this.muted = false,
    this.camera = false,
    this.isMe = false,
    this.host = false,
  });
  final int userId;
  String name;
  String photoUrl;
  String photoV;

  /// ringing | joined | left | declined | missed
  String state;
  bool muted;
  bool camera;
  final bool isMe;
  bool host;
  bool speaking = false;

  /// my leg with this person (null for me / not connected yet)
  int? legId;
  bool connected = false;

  bool get inCall => state == 'joined';
  bool get ringing => state == 'ringing';
}

class _Leg {
  _Leg(this.callId, this.peerId, this.offerer, this.adopted);
  final int callId;
  final int peerId;
  final bool offerer;

  /// a 1:1 call handed over to this group engine (its old offer is stale)
  final bool adopted;
  int gen = 0;
  bool peerReady = false;
  bool remoteSet = false;
  bool connected = false;
  bool reportedConnected = false;
  bool closed = false;
  int restarts = 0;
  Timer? offerWait;
  final List<Map<String, dynamic>> pending = [];
  final List<(DateTime, LegStats)> samples = [];
}

/// Strict media proof (the same bar as the 1:1 release gate): inbound
/// audio packets AND bytes keep growing across at least [window], and when
/// video is expected at least one frame was decoded.
@visibleForTesting
bool mediaFlowProven(List<(DateTime, LegStats)> samples,
    {bool expectVideo = false,
    Duration window = const Duration(seconds: 6)}) {
  if (samples.length < 2) return false;
  final last = samples.last;
  final lp = last.$2.audioPacketsIn, lb = last.$2.audioBytesIn;
  if (lp == null || lb == null) return false;
  // the newest sample at least [window] older than the last one
  (DateTime, LegStats)? base;
  for (final s in samples) {
    if (last.$1.difference(s.$1) >= window) base = s;
  }
  if (base == null) return false;
  final bp = base.$2.audioPacketsIn, bb = base.$2.audioBytesIn;
  if (bp == null || bb == null || lp <= bp || lb <= bb) return false;
  // packets grew at EVERY step (never stalled for a whole stats period)
  int? prev;
  for (final s in samples) {
    if (s.$1.isBefore(base.$1)) continue;
    final p = s.$2.audioPacketsIn;
    if (p == null) return false;
    if (prev != null && p <= prev) return false;
    prev = p;
  }
  // video: frames decoded AND still growing (gatefix 25f02670 bar)
  if (expectVideo) {
    final lf = last.$2.videoFramesDecoded ?? 0;
    final bf = base.$2.videoFramesDecoded ?? 0;
    if (lf <= 0 || lf <= bf) return false;
  }
  return true;
}

/// The grid shape for [n] tiles: (columns, rows). 1 -> 1x1, 2 -> 1x2,
/// 3-4 -> 2x2, 5-6 -> 2x3, 7-8 -> 2x4.
(int, int) gridShape(int n) {
  if (n <= 1) return (1, 1);
  if (n == 2) return (1, 2);
  const cols = 2;
  return (cols, (n + cols - 1) ~/ cols);
}

class GroupCallController extends ChangeNotifier {
  GroupCallController({
    required this.media,
    required this.signaling,
    required this.roomId,
    required this.myId,
    this.video = false,
    this.answerCallId,
    this.adoptCallId,
    this.sinceSeq = 0,
    this.onMobileData = false,
    this.networkEvents,
    DateTime Function()? now,
    this.pollEvery = const Duration(seconds: 3),
    this.statsEvery = const Duration(seconds: 1),
    this.offerWait = const Duration(seconds: 4),
    this.repairAfter = const Duration(seconds: 10),
    this.maxRestarts = 3,
  }) : now = now ?? DateTime.now;

  final GroupMedia media;
  final GroupSignaling signaling;
  final int roomId;
  /// My user id (learned from the snapshot's `is_me` when 0).
  int myId;
  bool video;

  /// The group ring I answer (accepted by join).
  final int? answerCallId;

  /// A live 1:1 call handed over to this engine (Add person / upgrade).
  final int? adoptCallId;

  /// Events at or below this seq were before this engine (stale).
  int sinceSeq;
  /// Low-data mode: on mobile data (or the "Low-data calls" setting) video
  /// is capped at 150 kbps per person and 5+ people start camera-off.
  bool onMobileData;

  /// 'wifi' | 'cellular' | 'other' | 'lost' (CallNative.networkChanges).
  final Stream<String>? networkEvents;
  StreamSubscription<String>? _netSub;
  final DateTime Function() now;
  final Duration pollEvery;
  final Duration statsEvery;
  final Duration offerWait;
  final Duration repairAfter;
  final int maxRestarts;

  GroupCallPhase phase = GroupCallPhase.joining;
  GroupEndReason endReason = GroupEndReason.none;
  String kind = 'voice';
  String groupName = '';
  int maxPeople = 8;
  int free = 7;
  String fullMessage = '';
  int videoKbps = 150;
  double dataMbPerMin = 0;
  bool muted = false;
  bool cameraOn = false;
  bool speakerOn = false;
  DateTime? connectedAt;
  final List<String> log = [];

  final Map<int, GroupTile> _tiles = {};
  final Map<int, _Leg> _legs = {};
  final Set<int> _seen = {};
  final Map<int, DateTime> _missingSince = {};
  List<Map<String, dynamic>> _ice = const [];
  StreamSubscription<Map<String, dynamic>>? _evSub;
  StreamSubscription<LegCandidate>? _candSub;
  StreamSubscription<LegLink>? _linkSub;
  Timer? _poll;
  Timer? _statsTimer;
  Future<void> _chain = Future<void>.value();
  bool _refreshing = false;
  bool _refreshAgain = false;
  DateTime? _lastRepair;
  bool _disposed = false;

  bool get isEnded => phase == GroupCallPhase.ended;
  bool get isLive => phase == GroupCallPhase.live;
  bool get isVideo => kind == 'video';

  /// Tiles: the other people first (joined, then ringing), me last.
  List<GroupTile> get tiles {
    final others = _tiles.values
        .where((t) => !t.isMe && (t.inCall || t.ringing))
        .toList()
      ..sort((a, b) {
        if (a.inCall != b.inCall) return a.inCall ? -1 : 1;
        return a.userId.compareTo(b.userId);
      });
    final me = _tiles[myId];
    return [...others, if (me != null) me];
  }

  /// People really in the call (me included).
  int get inCallCount => _tiles.values.where((t) => t.inCall).length;
  int get ringingCount => _tiles.values.where((t) => t.ringing).length;
  Set<int> get seatedUserIds => {
        for (final t in _tiles.values)
          if (t.inCall || t.ringing) t.userId
      };

  int? get activeSpeakerId {
    for (final t in _tiles.values) {
      if (t.speaking) return t.userId;
    }
    return null;
  }

  /// Leg ids (tests / the e2e proof).
  List<int> get legIds => _legs.keys.toList()..sort();
  int? legPeer(int legId) => _legs[legId]?.peerId;
  bool legConnected(int legId) => _legs[legId]?.connected ?? false;

  /// Strict proof per leg: media flows FROM that person to me.
  Map<int, bool> get mediaProof => {
        for (final l in _legs.values)
          l.peerId: mediaFlowProven(l.samples,
              expectVideo: isVideo && (_tiles[l.peerId]?.camera ?? false))
      };

  /// Evidence for every leg (e2e logs; never sent anywhere).
  Future<Map<int, Map<String, dynamic>>> evidence() async => {
        for (final id in legIds) id: await media.debugEvidence(id)
      };

  /// Bytes this call used on this phone (all legs).
  int get dataBytes {
    var n = 0;
    for (final l in _legs.values) {
      if (l.samples.isEmpty) continue;
      final s = l.samples.last.$2;
      n += (s.bytesSent ?? 0) + (s.bytesReceived ?? 0);
    }
    return n;
  }

  // ------------------------------------------------------------- lifecycle
  /// [initial]: the snapshot the start / invite call returned (else join).
  Future<void> start({Map<String, dynamic>? initial}) async {
    log.add('start room=$roomId');
    signaling.setFast(true);
    _evSub = signaling.events.listen((e) {
      _chain = _chain.then((_) => _onEvent(e)).catchError((Object err) {
        callLog('group_call#1', err);
      });
    });
    var snap = initial;
    final firstKind = '${initial?['kind'] ?? (video ? 'video' : 'voice')}';
    kind = firstKind;
    video = firstKind == 'video';
    try {
      await media.open(video: video);
    } on MediaOpenException catch (e) {
      await _end(e.denied ? GroupEndReason.mediaDenied : GroupEndReason.mediaError,
          tellServer: true);
      return;
    } catch (e) {
      callLog('group_call#2', e);
      await _end(GroupEndReason.mediaError, tellServer: true);
      return;
    }
    if (_disposed || isEnded) return;
    cameraOn = video && !media.cameraUnavailable;
    speakerOn = video;
    _netSub = networkEvents?.listen(_onNetwork, onError: (_) {});
    _candSub = media.localCandidates.listen(_onLocalCandidate);
    _linkSub = media.linkStates.listen(_onLink);
    try {
      if (snap == null || adoptCallId != null || answerCallId != null) {
        snap = await signaling.join(roomId, callId: answerCallId);
      }
    } catch (e) {
      callLog('group_call#3', e);
      final code = _codeOf(e);
      await _end(
          code == 'full'
              ? GroupEndReason.full
              : code == 'unavailable' || code == 'not_found'
                  ? GroupEndReason.unavailable
                  : code == 'call_ended'
                      ? GroupEndReason.ended
                      : GroupEndReason.network,
          tellServer: false);
      return;
    }
    final seq = (snap['seq'] as num?)?.toInt();
    if (seq != null && seq > sinceSeq) sinceSeq = seq;
    // low data: 5+ people on mobile data start with the camera off
    final people = ((snap['seats_taken'] as num?)?.toInt() ?? 2);
    if (cameraOn && onMobileData && people >= 5) {
      cameraOn = false;
      await media.setCameraEnabled(false);
      unawaited(signaling.media(roomId, camera: false).catchError((_) {}));
    } else if (video) {
      unawaited(signaling.media(roomId, camera: cameraOn).catchError((_) {}));
    }
    phase = GroupCallPhase.live;
    await _apply(snap);
    _poll = Timer.periodic(pollEvery, (_) => unawaited(refresh()));
    _statsTimer = Timer.periodic(statsEvery, (_) => unawaited(_sampleStats()));
    _notify();
  }

  static String _codeOf(Object e) => e is GroupCallError ? e.code : '';

  /// Gallery / widget previews: show [snap] as a live call (no media, no
  /// server, no timers).
  @visibleForTesting
  void preview(Map<String, dynamic> snap) {
    phase = GroupCallPhase.live;
    kind = '${snap['kind'] ?? kind}';
    cameraOn = kind == 'video';
    unawaited(_apply(snap));
  }

  /// Re-read the room (poll, group.state, an unknown leg's event).
  Future<void> refresh() async {
    if (isEnded || _disposed) return;
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      final s = await signaling.snapshot(roomId);
      await _apply(s);
    } catch (e) {
      callLog('group_call#4', e);
      if (_codeOf(e) == 'not_found') {
        await _end(GroupEndReason.ended, tellServer: false);
      }
    } finally {
      _refreshing = false;
    }
    if (_refreshAgain && !isEnded) {
      _refreshAgain = false;
      await refresh();
    }
  }

  Future<void> _apply(Map<String, dynamic> s) async {
    if (isEnded) return;
    if (s['ice'] is Map && (s['ice'] as Map)['iceServers'] is List) {
      _ice = ((s['ice'] as Map)['iceServers'] as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    }
    kind = '${s['kind'] ?? kind}';
    groupName = '${s['group_name'] ?? groupName}';
    maxPeople = (s['max'] as num?)?.toInt() ?? maxPeople;
    free = (s['free'] as num?)?.toInt() ?? free;
    fullMessage = '${s['full_message'] ?? fullMessage}';
    final vk = (s['video_kbps'] as num?)?.toInt();
    if (vk != null && vk != videoKbps) {
      videoKbps = vk;
      if (isVideo) {
        unawaited(media
            .setVideoKbps(onMobileData ? (vk < 150 ? vk : 150) : vk)
            .catchError((_) {}));
      }
    }
    dataMbPerMin = (s['data_mb_per_min'] as num?)?.toDouble() ?? dataMbPerMin;
    if (s['live'] == false || s['state'] == 'ended') {
      await _end(GroupEndReason.ended, tellServer: false);
      return;
    }
    // tiles
    final seen = <int>{};
    for (final m in (s['members'] as List? ?? const []).whereType<Map>()) {
      final id = (m['user_id'] as num?)?.toInt();
      if (id == null) continue;
      if (m['is_me'] == true) myId = id;
      seen.add(id);
      final t = _tiles[id] ??= GroupTile(
          userId: id, name: '${m['name'] ?? ''}', isMe: id == myId);
      t
        ..name = '${m['name'] ?? t.name}'
        ..photoUrl = '${m['photo_url'] ?? ''}'
        ..photoV = '${m['photo_v'] ?? ''}'
        ..state = '${m['state'] ?? t.state}'
        ..muted = m['muted'] == true
        ..camera = m['camera'] == true
        ..host = m['host'] == true;
    }
    _tiles.removeWhere((id, _) => !seen.contains(id));
    final me = _tiles[myId];
    if (me != null && me.state != 'joined' && phase == GroupCallPhase.live) {
      await _end(GroupEndReason.left, tellServer: false);
      return;
    }
    // legs
    final live = <int>{};
    for (final l in (s['legs'] as List? ?? const []).whereType<Map>()) {
      final id = (l['call_id'] as num?)?.toInt();
      final peer = (l['peer_id'] as num?)?.toInt();
      if (id == null || peer == null) continue;
      live.add(id);
      if (!_legs.containsKey(id)) {
        // a newer leg with the same person replaces an old one
        for (final old in _legs.values.where((x) => x.peerId == peer).toList()) {
          await _closeLeg(old.callId);
        }
        await _openLeg(id, peer, l['offerer'] == true);
      }
    }
    for (final id in _legs.keys.toList()) {
      if (!live.contains(id)) await _closeLeg(id);
    }
    for (final t in _tiles.values) {
      final leg = _legs.values.where((l) => l.peerId == t.userId);
      t.legId = leg.isEmpty ? null : leg.first.callId;
      t.connected = leg.isNotEmpty && leg.first.connected;
    }
    _checkMissing();
    _notify();
  }

  /// A person in the call I have no leg with for [repairAfter] -> ask the
  /// server to (re)open my legs (idempotent).
  void _checkMissing() {
    if (!isLive) return;
    final t = now();
    var need = false;
    for (final tile in _tiles.values) {
      if (tile.isMe || !tile.inCall) {
        _missingSince.remove(tile.userId);
        continue;
      }
      if (tile.legId != null) {
        _missingSince.remove(tile.userId);
        continue;
      }
      final since = _missingSince[tile.userId] ??= t;
      if (t.difference(since) >= repairAfter) need = true;
    }
    final last = _lastRepair;
    if (need && (last == null || t.difference(last) >= repairAfter)) {
      _lastRepair = t;
      log.add('repair');
      unawaited(signaling.join(roomId).then(_apply).catchError((Object e) {
        callLog('group_call#5', e);
      }));
    }
  }

  // ------------------------------------------------------------------ legs
  Future<void> _openLeg(int id, int peer, bool offerer) async {
    final leg = _Leg(id, peer, offerer, id == adoptCallId);
    _legs[id] = leg;
    log.add('leg+$id peer=$peer ${offerer ? 'offer' : 'answer'}');
    try {
      await media.addPeer(id, _ice, video: isVideo);
      leg.peerReady = true;
    } catch (e) {
      callLog('group_call#6', e);
      return;
    }
    if (leg.closed) return;
    // an offer / ICE sent before this phone listened
    try {
      for (final e in await signaling.backlog(id)) {
        await _onEvent(e);
      }
    } catch (e) {
      callLog('group_call#7', e);
    }
    if (leg.closed) return;
    if (offerer) {
      if (leg.gen == 0) await _sendOffer(leg);
    } else if (!leg.remoteSet) {
      // the offerer sends its offer when it sees the leg; if none comes
      // (it went to a handed-over 1:1 screen, or was lost) ask for one.
      // A handed-over leg asks sooner: its old offer is gone for sure.
      leg.offerWait = Timer(
          leg.adopted ? const Duration(milliseconds: 1500) : offerWait, () {
        if (!leg.remoteSet && !leg.closed) _askOffer(leg);
      });
    }
  }

  void _askOffer(_Leg leg) {
    log.add('ask-offer ${leg.callId}');
    unawaited(signaling
        .signal(leg.callId, 'restart_request', {'g': leg.gen})
        .catchError((_) {}));
  }

  Future<void> _sendOffer(_Leg leg) async {
    if (leg.closed || isEnded) return;
    if (leg.gen > 0) {
      // a fresh peer for every re-offer: no half-renegotiated state
      await _rebuildPeer(leg);
    }
    leg.gen++;
    leg.remoteSet = false;
    leg.pending.clear();
    try {
      final offer = await media.createOffer(leg.callId);
      await signaling.signal(leg.callId, 'offer', {...offer, 'g': leg.gen});
      log.add('offer ${leg.callId} g=${leg.gen}');
    } catch (e) {
      callLog('group_call#8', e);
    }
  }

  Future<void> _rebuildPeer(_Leg leg) async {
    leg.peerReady = false;
    leg.connected = false;
    try {
      await media.closePeer(leg.callId);
      await media.addPeer(leg.callId, _ice, video: isVideo);
      leg.peerReady = true;
    } catch (e) {
      callLog('group_call#9', e);
    }
  }

  Future<void> _closeLeg(int id) async {
    final leg = _legs.remove(id);
    if (leg == null) return;
    leg.closed = true;
    leg.offerWait?.cancel();
    log.add('leg-$id');
    try {
      await media.closePeer(id);
    } catch (e) {
      callLog('group_call#10', e);
    }
    final t = _tiles[leg.peerId];
    if (t != null) {
      t.legId = null;
      t.connected = false;
      t.speaking = false;
    }
  }

  // ---------------------------------------------------------------- events
  Future<void> _onEvent(Map<String, dynamic> e) async {
    if (isEnded || _disposed) return;
    final seq = (e['seq'] as num?)?.toInt();
    if (seq != null) {
      if (seq <= sinceSeq) return;
      if (!_seen.add(seq)) return;
    }
    final topic = '${e['topic'] ?? ''}';
    final p = (e['payload'] is Map)
        ? (e['payload'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    if (topic.startsWith('group.')) {
      if ((p['room_id'] as num?)?.toInt() != roomId) return;
      if (p['ended'] == true) {
        await _end(GroupEndReason.ended, tellServer: false);
        return;
      }
      unawaited(refresh());
      return;
    }
    if (topic != 'call.signal' && topic != 'call.state') return;
    final id = (p['call_id'] as num?)?.toInt();
    if (id == null) return;
    final leg = _legs[id];
    if (topic == 'call.state') {
      if (leg != null && p['phase'] == 'ended') {
        await _closeLeg(id);
        _notify();
      }
      // a ring I placed was answered / declined, or a leg I don't know
      if (p['room_id'] != null || leg != null) unawaited(refresh());
      return;
    }
    if (leg == null) {
      // a signal for a leg this phone has not opened yet: the snapshot
      // brings the leg, its backlog replays this signal
      if (seq != null) _seen.remove(seq);
      unawaited(refresh());
      return;
    }
    if (!leg.peerReady) {
      if (seq != null) _seen.remove(seq);
      return; // _openLeg replays the backlog once the peer exists
    }
    final kind = '${p['kind'] ?? ''}';
    final data = (p['data'] is Map)
        ? (p['data'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    await _onSignal(leg, kind, data);
  }

  Future<void> _onSignal(
      _Leg leg, String kind, Map<String, dynamic> data) async {
    final g = (data['g'] as num?)?.toInt() ?? 0;
    switch (kind) {
      case 'offer':
      case 'restart_offer':
        if (leg.offerer) return; // roles come from the server: never glare
        if (g != 0 && g < leg.gen) return; // an older offer
        leg.offerWait?.cancel();
        if (leg.remoteSet) await _rebuildPeer(leg);
        leg.gen = g;
        try {
          final ans = await media.acceptOffer(leg.callId, _sdp(data));
          leg.remoteSet = true;
          await signaling.signal(leg.callId, 'answer', {...ans, 'g': g});
          log.add('answer ${leg.callId} g=$g');
          await _flush(leg);
        } catch (e) {
          callLog('group_call#11', e);
        }
        return;
      case 'answer':
      case 'restart_answer':
        if (!leg.offerer || g != leg.gen || leg.remoteSet) return;
        try {
          await media.setAnswer(leg.callId, _sdp(data));
          leg.remoteSet = true;
          await _flush(leg);
        } catch (e) {
          callLog('group_call#12', e);
        }
        return;
      case 'ice':
        if (g != 0 && g < leg.gen) return; // an older peer's candidate
        if (!leg.remoteSet || (g != 0 && g > leg.gen)) {
          leg.pending.add(data);
          return;
        }
        try {
          await media.addCandidate(leg.callId, data);
        } catch (e) {
          callLog('group_call#13', e);
        }
        return;
      case 'restart_request':
        if (leg.offerer) await _sendOffer(leg);
        return;
      default:
        return;
    }
  }

  static Map<String, dynamic> _sdp(Map<String, dynamic> d) =>
      {'type': d['type'], 'sdp': d['sdp']};

  Future<void> _flush(_Leg leg) async {
    final keep = <Map<String, dynamic>>[];
    for (final c in List.of(leg.pending)) {
      final g = (c['g'] as num?)?.toInt() ?? 0;
      if (g != 0 && g < leg.gen) continue;
      if (g != 0 && g > leg.gen) {
        keep.add(c);
        continue;
      }
      try {
        await media.addCandidate(leg.callId, c);
      } catch (e) {
        callLog('group_call#14', e);
      }
    }
    leg.pending
      ..clear()
      ..addAll(keep);
  }

  void _onLocalCandidate(LegCandidate c) {
    final leg = _legs[c.legId];
    if (leg == null || isEnded) return;
    unawaited(signaling
        .signal(c.legId, 'ice', {...c.candidate, 'g': leg.gen})
        .catchError((_) {}));
  }

  void _onLink(LegLink l) {
    final leg = _legs[l.legId];
    if (leg == null || isEnded) return;
    log.add('link ${l.legId} ${l.state.name}');
    switch (l.state) {
      case MediaLinkState.connected:
        leg.connected = true;
        leg.restarts = 0;
        connectedAt ??= now();
        if (!leg.reportedConnected) {
          leg.reportedConnected = true;
          unawaited(signaling.event(leg.callId, 'connected').then((_) {},
              onError: (Object e) => callLog('group_call#15', e)));
        }
        break;
      case MediaLinkState.failed:
        leg.connected = false;
        if (leg.restarts >= maxRestarts) {
          // give this pair up; the server ends the leg and the repair path
          // opens a fresh one if both are still in the call
          unawaited(signaling.event(leg.callId, 'fail').then((_) {},
              onError: (Object _) {}));
          break;
        }
        leg.restarts++;
        if (leg.offerer) {
          unawaited(_sendOffer(leg));
        } else {
          _askOffer(leg);
        }
        break;
      case MediaLinkState.disconnected:
        leg.connected = false;
        break;
      default:
        break;
    }
    final t = _tiles[leg.peerId];
    if (t != null) t.connected = leg.connected;
    _notify();
  }

  void _onNetwork(String kind) {
    final mobile = kind == 'cellular';
    if (kind == 'lost' || mobile == onMobileData) return;
    onMobileData = mobile;
    log.add('net $kind');
    if (isVideo) {
      unawaited(media
          .setVideoKbps(mobile && videoKbps > 150 ? 150 : videoKbps)
          .catchError((_) {}));
    }
    _notify();
  }

  // ----------------------------------------------------------------- stats
  /// Tests / the e2e proof: take one stats sample of every leg now.
  @visibleForTesting
  Future<void> sampleStatsNow() => _sampleStats();

  Future<void> _sampleStats() async {
    if (!isLive) return;
    final at = now();
    int? loudest;
    var loudLevel = 0.04; // below this nobody is "speaking"
    for (final leg in _legs.values.toList()) {
      if (!leg.connected) continue;
      try {
        final s = await media.stats(leg.callId);
        leg.samples.add((at, s));
        if (leg.samples.length > 30) leg.samples.removeAt(0);
        final lv = s.audioLevel ?? 0;
        final tile = _tiles[leg.peerId];
        if (lv > loudLevel && tile != null && !tile.muted) {
          loudLevel = lv;
          loudest = leg.peerId;
        }
      } catch (e) {
        callLog('group_call#16', e);
      }
    }
    var changed = false;
    for (final t in _tiles.values) {
      final sp = t.userId == loudest;
      if (t.speaking != sp) {
        t.speaking = sp;
        changed = true;
      }
    }
    if (changed) _notify();
  }

  // -------------------------------------------------------------- controls
  Future<void> toggleMute() async {
    muted = !muted;
    await media.setMuted(muted);
    _tiles[myId]?.muted = muted;
    unawaited(signaling.media(roomId, muted: muted).catchError((_) {}));
    _notify();
  }

  Future<void> toggleCamera() async {
    if (!isVideo || media.cameraUnavailable) return;
    cameraOn = !cameraOn;
    await media.setCameraEnabled(cameraOn);
    _tiles[myId]?.camera = cameraOn;
    unawaited(signaling.media(roomId, camera: cameraOn).catchError((_) {}));
    _notify();
  }

  Future<void> switchCamera() => media.switchCamera();

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await media.setSpeaker(speakerOn);
    _notify();
  }

  /// Ring more people. Returns the server's per-person results
  /// ({user_id, ok, code}); the room is refreshed from the reply.
  Future<List<Map<String, dynamic>>> invite(List<int> userIds) async {
    final body = await signaling.invite(roomId, userIds);
    await _apply(body);
    return ((body['results'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  /// The red button: leave; the others go on.
  Future<void> leave() => _end(GroupEndReason.left, tellServer: true);

  Future<void> _end(GroupEndReason reason, {required bool tellServer}) async {
    if (isEnded) return;
    phase = GroupCallPhase.ended;
    endReason = reason;
    log.add('end ${reason.name}');
    _poll?.cancel();
    _statsTimer?.cancel();
    await _evSub?.cancel();
    _evSub = null;
    await _netSub?.cancel();
    _netSub = null;
    signaling.setFast(false);
    final told = tellServer
        ? signaling.leave(roomId).catchError((Object e) {
            callLog('group_call#17', e);
          })
        : Future<void>.value();
    for (final id in _legs.keys.toList()) {
      await _closeLeg(id);
    }
    await _candSub?.cancel();
    await _linkSub?.cancel();
    try {
      await media.dispose();
    } catch (e) {
      callLog('group_call#18', e);
    }
    _notify();
    await told;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (!isEnded) unawaited(leave());
    _disposed = true;
    _poll?.cancel();
    _statsTimer?.cancel();
    super.dispose();
  }
}
