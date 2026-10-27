import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api.dart' show ApiException;
import '../call_controller.dart';
import '../call_log.dart';
import '../media_ext.dart';

/// callsB: GROUP calls on the current mesh — up to [kGroupMax] people, every
/// pair with its own peer connection (= its own [CallController], so each
/// pair gets the proven 1:1 machinery: connect timeout, reconnect, ICE
/// restart, relay report). The server keeps the roster (who is ringing /
/// joined / left) and creates the pair links; this session follows the
/// roster, runs one controller per link and merges them into tiles.
///
/// 1:1 calls are untouched: a session exists only once someone was added
/// (or a group call was started / joined from a chat).
const int kGroupMax = 4;

class GroupMember {
  GroupMember({
    required this.userId,
    required this.name,
    this.photo = '',
    this.photoV = '',
    required this.state,
    this.me = false,
    this.muted = false,
    this.camera = true,
    this.screen = false,
    this.memberId,
  });

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        userId: (j['user_id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        photo: '${j['photo_url'] ?? ''}',
        photoV: '${j['photo_v'] ?? ''}',
        state: '${j['state'] ?? ''}',
        me: j['me'] == true,
        muted: j['muted'] == true,
        camera: j['camera'] != false,
        screen: j['screen'] == true,
        memberId: (j['member_id'] as num?)?.toInt(),
      );

  final int userId;
  final String name, photo, photoV, state;
  final bool me, muted, camera, screen;

  /// MY My Circle id for this person (null = not my contact).
  final int? memberId;

  bool get active => state == 'ringing' || state == 'joined';
}

class GroupLink {
  GroupLink(
      {required this.callId,
      required this.via,
      required this.peerUserId,
      required this.role,
      required this.state});

  factory GroupLink.fromJson(Map<String, dynamic> j) => GroupLink(
        callId: (j['call_id'] as num?)?.toInt() ?? 0,
        via: '${j['via'] ?? ''}',
        peerUserId: (j['peer_user_id'] as num?)?.toInt() ?? 0,
        role: '${j['role'] ?? ''}',
        state: '${j['state'] ?? ''}',
      );

  final int callId, peerUserId;
  final String via, role, state;
  bool get offerer => role == 'caller';
}

class GroupRoster {
  GroupRoster({
    required this.roomId,
    required this.kind,
    required this.state,
    this.groupId,
    this.groupName = '',
    this.max = kGroupMax,
    required this.active,
    required this.joined,
    required this.myState,
    required this.canAdd,
    required this.lowBandwidth,
    required this.members,
    required this.links,
  });

  factory GroupRoster.fromJson(Map<String, dynamic> j) => GroupRoster(
        roomId: (j['room_id'] as num?)?.toInt() ?? 0,
        kind: '${j['kind'] ?? 'voice'}',
        state: '${j['state'] ?? 'live'}',
        groupId: (j['group_id'] as num?)?.toInt(),
        groupName: '${j['group_name'] ?? ''}',
        max: (j['max'] as num?)?.toInt() ?? kGroupMax,
        active: (j['active'] as num?)?.toInt() ?? 0,
        joined: (j['joined'] as num?)?.toInt() ?? 0,
        myState: '${j['my_state'] ?? ''}',
        canAdd: j['can_add'] == true,
        lowBandwidth: j['low_bandwidth'] == true,
        members: ((j['members'] ?? const []) as List)
            .whereType<Map>()
            .map((m) => GroupMember.fromJson(m.cast<String, dynamic>()))
            .toList(),
        links: ((j['links'] ?? const []) as List)
            .whereType<Map>()
            .map((m) => GroupLink.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  final int roomId;
  final String kind, state;
  final int? groupId;
  final String groupName;
  final int max, active, joined;
  final String myState;
  final bool canAdd, lowBandwidth;
  final List<GroupMember> members;
  final List<GroupLink> links;

  bool get live => state == 'live';
  bool get video => kind == 'video';
}

/// Server calls for a group call (ApiGroupCallApi in the app, a fake in
/// tests).
abstract class GroupCallApi {
  /// POST circle/calls/<callId>/add {member_id} -> roster (+ invited).
  Future<Map<String, dynamic>> addPerson(int callId, int memberId);

  /// GET circle/calls/<callId>/room -> roster, or null (a plain 1:1 call).
  Future<Map<String, dynamic>?> roomOfCall(int callId);
  Future<Map<String, dynamic>> room(int roomId);
  Future<Map<String, dynamic>> join(int roomId);
  Future<Map<String, dynamic>> leave(int roomId);
  Future<void> media(int roomId, Map<String, dynamic> data);

  /// `call.roster` payloads from the real-time queue (every room I am in).
  Stream<Map<String, dynamic>> rosterEvents();
}

/// Why "Add person" did not ring anyone (the sheet shows it honestly).
enum AddPersonResult {
  ok,
  full,
  notContact,
  alreadyIn,
  rateLimited,
  blocked,
  upgrade,
  ended,
  failed,
}

AddPersonResult addResultFrom(Object e) {
  if (e is ApiException) {
    switch (e.reason) {
      case 'full':
        return AddPersonResult.full;
      case 'not_contact':
        return AddPersonResult.notContact;
      case 'already_in':
        return AddPersonResult.alreadyIn;
      case 'rate_limited':
        return AddPersonResult.rateLimited;
      case 'blocked':
        return AddPersonResult.blocked;
      case 'upgrade_required':
        return AddPersonResult.upgrade;
      case 'ended':
      case 'not_in_call':
        return AddPersonResult.ended;
    }
    if (e.status == 429) return AddPersonResult.rateLimited;
    if (e.status == 402) return AddPersonResult.upgrade;
  }
  return AddPersonResult.failed;
}

/// One tile of the grid (me or another participant).
class GroupTile {
  GroupTile({
    required this.member,
    required this.status,
    this.controller,
    this.muted = false,
    this.cameraOn = false,
    this.screen = false,
    this.speaking = false,
  });
  final GroupMember member;

  /// me | ringing | connecting | connected | reconnecting
  final String status;

  /// The pair link to this person (null for me / not linked yet).
  final CallController? controller;
  final bool muted, cameraOn, screen, speaking;
  bool get me => member.me;
}

/// What the add-person sheet needs from a call (a [GroupCallSession], or
/// the 1:1 call screen before a group exists).
abstract class GroupCallSessionLike {
  Future<AddPersonResult> addPerson(int memberId);
  Set<int> get inCallMemberIds;
  int get seatsLeft;
}

typedef LinkControllerFactory = CallController Function(
    GroupLink link, CallMedia media, bool video);

class GroupCallSession extends ChangeNotifier implements GroupCallSessionLike {
  GroupCallSession({
    required this.api,
    required this.newLinkMedia,
    required this.makeLink,
    this.primary,
    this.host,
    GroupRoster? roster,
    this.levelsEvery = const Duration(milliseconds: 700),
    this.pollEvery = const Duration(seconds: 6),
    this.speakingLevel = 0.02,
    bool timers = true,
  }) : _roster = roster {
    _sub = api.rosterEvents().listen(_onRosterEvent, onError: (Object e) {
      callLog('group_call#1', e);
    });
    if (timers) {
      // gallery previews pass timers: false (frozen, nothing polls)
      _levels = Timer.periodic(levelsEvery, (_) => unawaited(_pollLevels()));
      _poll = Timer.periodic(pollEvery, (_) => unawaited(refresh()));
    }
    primary?.addListener(_onAnyChange);
    final r = _roster;
    if (r != null) _apply(r);
  }

  final GroupCallApi api;

  /// A [CallMedia] for one more pair link (sharing the host's mic/camera).
  final CallMedia Function() newLinkMedia;
  final LinkControllerFactory makeLink;

  /// The 1:1 call this group grew out of (null = joined from a chat).
  final CallController? primary;

  /// The shared local media (levels, low-bandwidth mode), when real.
  final MeshHost? host;
  final Duration levelsEvery, pollEvery;
  final double speakingLevel;

  GroupRoster? _roster;
  GroupRoster? get roster => _roster;
  final Map<int, CallController> _links = {};
  final Map<int, double> _level = {};
  final Set<int> _speaking = {};
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _levels, _poll;
  bool _disposed = false;
  bool _left = false;
  bool? _lowSent;
  final List<String> log = [];

  bool muted = false;
  bool cameraOn = true;
  bool screenSharing = false;

  /// Gallery: joined people without a live link show as connected.
  @visibleForTesting
  bool assumeConnected = false;

  /// Pair-link controllers (not the primary), by call id.
  Map<int, CallController> get links => Map.unmodifiable(_links);

  /// Every controller of this call: the primary first, then the links.
  List<CallController> get controllers => [
        if (primary != null) primary!,
        ..._links.values,
      ];

  int? get roomId => _roster?.roomId;
  bool get video => _roster?.video ?? (primary?.videoOn ?? false);

  /// The roster says I'm in the call and it is live.
  bool get alive {
    final r = _roster;
    if (r == null) return primary != null && !primary!.isEnded;
    return r.live && r.myState == 'joined' && !_left;
  }

  /// Show the group grid: 3+ people (ringing or joined), or a call joined
  /// from a chat (no 1:1 underneath).
  bool get isGroupView {
    final r = _roster;
    if (r == null) return false;
    return r.active >= 3 || primary == null;
  }

  bool get canAdd => (_roster?.canAdd ?? false) && alive;

  @override
  Set<int> get inCallMemberIds => {
        for (final m in _roster?.members ?? const <GroupMember>[])
          if (m.active && m.memberId != null) m.memberId!
      };

  @override
  int get seatsLeft {
    final r = _roster;
    if (r == null) return kGroupMax - 2;
    return (r.max - r.active).clamp(0, kGroupMax);
  }

  /// A live link to add people through (the server needs a call I'm in).
  int? get anyLiveCallId {
    final p = primary;
    if (p != null && p.isLive && p.callId != null) return p.callId;
    for (final c in _links.values) {
      if (c.isLive && c.callId != null) return c.callId;
    }
    return null;
  }

  void _onAnyChange() {
    if (!_disposed) notifyListeners();
  }

  void _onRosterEvent(Map<String, dynamic> p) {
    final id = (p['room_id'] as num?)?.toInt();
    final mine = roomId;
    if (mine != null && id != mine) return;
    if (mine == null) {
      // not in a room yet: adopt one that contains my 1:1 call
      final pid = primary?.callId;
      final links = (p['links'] as List?) ?? const [];
      final ours = pid != null &&
          links.whereType<Map>().any((l) => (l['call_id'] as num?) == pid);
      if (!ours) return;
    }
    attach(GroupRoster.fromJson(p));
  }

  /// A fresh roster (event, poll, add / join answer).
  void attach(GroupRoster r) {
    if (_disposed) return;
    _roster = r;
    _apply(r);
    notifyListeners();
  }

  void attachJson(Map<String, dynamic> j) => attach(GroupRoster.fromJson(j));

  void _apply(GroupRoster r) {
    log.add('roster:${r.state}:${r.active}');
    final low = r.lowBandwidth;
    if (_lowSent != low && host != null) {
      _lowSent = low;
      unawaited(host!.setLowBandwidth(low).catchError((Object e) {
        callLog('group_call#2', e);
      }));
    }
    if (!r.live || r.myState != 'joined' || _left) return;
    final primaryId = primary?.callId;
    for (final l in r.links) {
      if (l.callId == primaryId || _links.containsKey(l.callId)) continue;
      if (l.state == 'ended') continue;
      _startLink(l, r.video);
    }
  }

  void _startLink(GroupLink l, bool video) {
    final media = newLinkMedia();
    final c = makeLink(l, media, video);
    // the shared mic / camera state, so the other side's tile is right
    c.muted = muted;
    if (video) c.cameraOn = cameraOn;
    c.screenSharing = screenSharing;
    if (muted) {
      unawaited(media.setMuted(true).catchError((Object e) {
        callLog('group_call#3', e);
      }));
    }
    _links[l.callId] = c;
    log.add('link:${l.callId}:${l.offerer ? 'offer' : 'answer'}');
    c.addListener(_onAnyChange);
    unawaited(c.start().catchError((Object e) {
      callLog('group_call#4', e);
    }));
  }

  /// Poll the roster (a lost event never leaves the grid stale).
  Future<void> refresh() async {
    final id = roomId;
    try {
      if (id != null) {
        attachJson(await api.room(id));
      } else {
        final pid = primary?.callId;
        if (pid == null) return;
        final j = await api.roomOfCall(pid);
        if (j != null) attachJson(j);
      }
    } catch (e) {
      callLog('group_call#5', e);
    }
  }

  // ------------------------------------------------------------- tiles
  int? _peerOf(CallController c) {
    final r = _roster;
    if (r == null) return null;
    for (final l in r.links) {
      if (l.callId == c.callId) return l.peerUserId;
    }
    return null;
  }

  CallController? controllerFor(int userId) {
    for (final c in controllers) {
      if (!c.isEnded && _peerOf(c) == userId) return c;
    }
    return null;
  }

  bool isSpeaking(int userId) => _speaking.contains(userId);

  /// Me first, then everyone ringing / joined (max [kGroupMax]).
  List<GroupTile> get tiles {
    final r = _roster;
    if (r == null) return const [];
    final out = <GroupTile>[];
    for (final m in r.members) {
      if (m.me) {
        out.insert(
            0,
            GroupTile(
                member: m,
                status: 'me',
                muted: muted,
                cameraOn: video && cameraOn,
                screen: screenSharing,
                speaking: _speaking.contains(m.userId)));
        continue;
      }
      if (!m.active) continue;
      final c = controllerFor(m.userId);
      String status;
      if (m.state == 'ringing') {
        status = 'ringing';
      } else if (c == null) {
        status = assumeConnected ? 'connected' : 'connecting';
      } else if (c.phase == CallPhase.connected) {
        status = 'connected';
      } else if (c.phase == CallPhase.reconnecting) {
        status = 'reconnecting';
      } else {
        status = 'connecting';
      }
      final live = c != null && c.isLive;
      out.add(GroupTile(
        member: m,
        status: status,
        controller: c,
        muted: m.muted || (live && !c.remoteMicOn),
        cameraOn: video && live && c.remoteCameraOn && m.camera,
        screen: m.screen || (live && c.remoteScreen),
        speaking: _speaking.contains(m.userId),
      ));
    }
    return out.take(kGroupMax).toList();
  }

  Future<void> _pollLevels() async {
    if (_disposed || !alive) return;
    final next = <int>{};
    for (final c in controllers) {
      if (!c.isLive) continue;
      final Object m = c.media;
      final uid = _peerOf(c);
      if (uid == null || m is! AudioLevelMedia) continue;
      try {
        final lv = await m.remoteAudioLevel();
        if (lv != null) {
          _level[uid] = lv;
          if (lv >= speakingLevel && c.remoteMicOn) next.add(uid);
        }
      } catch (e) {
        callLog('group_call#6', e);
      }
    }
    final h = host;
    final me = _roster?.members.where((m) => m.me).firstOrNull;
    if (h != null && me != null && !muted) {
      try {
        final lv = await h.localAudioLevel();
        if (lv != null && lv >= speakingLevel) next.add(me.userId);
      } catch (e) {
        callLog('group_call#7', e);
      }
    }
    setSpeaking(next);
  }

  /// Who is speaking right now (from audio levels; tests call it directly).
  void setSpeaking(Set<int> ids) {
    if (setEquals(ids, _speaking) || _disposed) return;
    _speaking
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  // ------------------------------------------------------------- controls
  Future<void> toggleMute() async {
    muted = !muted;
    notifyListeners();
    var applied = false;
    for (final c in controllers) {
      if (c.isEnded) continue;
      if (c.muted != muted) {
        await c.toggleMute();
        applied = true;
      }
    }
    if (!applied) {
      // no link yet (still ringing everyone): mute the shared mic itself
      for (final c in _links.values) {
        await c.media.setMuted(muted).catchError((Object e) {
          callLog('group_call#8', e);
        });
      }
    }
    unawaited(_sendMedia({'muted': muted}));
  }

  Future<void> toggleCamera() async {
    if (!video) return;
    cameraOn = !cameraOn;
    notifyListeners();
    for (final c in controllers) {
      if (!c.isEnded && c.cameraOn != cameraOn) await c.toggleCamera();
    }
    unawaited(_sendMedia({'camera': cameraOn}));
  }

  Future<void> switchCamera() async {
    final c = controllers.where((c) => !c.isEnded).firstOrNull;
    if (c != null) await c.switchCamera();
  }

  /// My screen share started / stopped (the media already swapped tracks).
  void setScreenSharing(bool on) {
    if (screenSharing == on) return;
    screenSharing = on;
    notifyListeners();
    unawaited(_sendMedia({'screen': on}));
  }

  Future<void> _sendMedia(Map<String, dynamic> data) async {
    final id = roomId;
    if (id == null) return;
    try {
      await api.media(id, data);
    } catch (e) {
      callLog('group_call#9', e);
    }
  }

  /// "Add person": ring one of my accepted My Circle contacts into the call.
  @override
  Future<AddPersonResult> addPerson(int memberId) async {
    final cid = anyLiveCallId;
    if (cid == null) return AddPersonResult.ended;
    try {
      final j = await api.addPerson(cid, memberId);
      attachJson(j);
      return AddPersonResult.ok;
    } catch (e) {
      callLog('group_call#10', e);
      return addResultFrom(e);
    }
  }

  /// Join from a chat: the server links me to everyone (I offer).
  Future<bool> join(int roomId) async {
    try {
      attachJson(await api.join(roomId));
      return alive;
    } catch (e) {
      callLog('group_call#11', e);
      return false;
    }
  }

  /// Leave: hang up every pair link (the primary too) and tell the server.
  Future<void> leave() async {
    if (_left) return;
    _left = true;
    log.add('leave');
    final id = roomId;
    final all = controllers;
    for (final c in all) {
      if (!c.isEnded) unawaited(c.hangup());
    }
    if (id != null) {
      try {
        await api.leave(id);
      } catch (e) {
        callLog('group_call#12', e);
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _levels?.cancel();
    _poll?.cancel();
    primary?.removeListener(_onAnyChange);
    for (final c in _links.values) {
      c.removeListener(_onAnyChange);
      c.dispose(); // hangs a live link up
    }
    _links.clear();
    super.dispose();
  }
}

/// callsB: the live group calls by any of their call ids, so a call screen
/// re-opened from the mini bar finds its group again.
class GroupCalls {
  GroupCalls._();
  static final GroupCalls instance = GroupCalls._();
  final Map<int, GroupCallSession> _byCall = {};

  void register(int callId, GroupCallSession s) => _byCall[callId] = s;
  GroupCallSession? forCall(int? callId) =>
      callId == null ? null : _byCall[callId];
  void unregister(GroupCallSession s) =>
      _byCall.removeWhere((_, v) => identical(v, s));
}

/// callsB: pair links of a group call make no sounds of their own (the
/// call screen's 1:1 controller / the group screen owns ringback & tones).
class SilentCallSounds implements CallSounds {
  const SilentCallSounds();
  @override
  Future<void> startRingback() async {}
  @override
  Future<void> stopRingback() async {}
  @override
  Future<void> playBusy() async {}
  @override
  Future<void> playDeclined() async {}
  @override
  Future<void> playEnded() async {}
  @override
  Future<void> stopAll() async {}
  @override
  Future<void> setProximity(bool on) async {}
}
