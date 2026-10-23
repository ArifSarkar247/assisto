import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../api.dart';
import 'call_log.dart';
import 'call_recording.dart';

/// b3-group — group voice/video calls (3+ people) on our self-hosted LiveKit
/// SFU. 1:1 calls stay peer-to-peer ([CallController]).
///
/// Pure Dart: the SFU media ([GroupRoom], LiveKit in the app — a DEFERRED
/// library, nothing loads at launch) and the server ([GroupCallApi]) are
/// injected, so the whole state machine is unit-tested with fakes.
///
///   joining -> connected (<-> reconnecting) -> ended(reason)
/// "connected" is entered ONLY when the SFU really connected. Every failure
/// says what it is ("Group calls are not available right now", "This call is
/// full", "You were removed", ...) — no fake path.
enum GroupPhase { joining, connected, reconnecting, ended }

enum GroupEndReason {
  none,
  left, // I left (can rejoin while the room lives)
  ended, // the call is over for everyone
  removed, // the host removed me
  full, // max people reached
  unavailable, // LiveKit not reachable / not configured
  upgrade, // group video needs Premium (server gate)
  network, // our server unreachable
  mediaDenied, // mic permission refused
  failed, // anything else
}

enum GroupNotice {
  none,
  mutedByHost,
  hostActionFailed,
  inviteSent,
  inviteFailed,
  screenShareFailed,
  screenSharePremium,
  reconnected,
}

/// SFU link state as the media layer reports it.
enum GroupLink { idle, connecting, connected, reconnecting, disconnected }

/// One participant as the SFU sees them (LiveKit identity = our user id).
@immutable
class GroupMediaPeer {
  const GroupMediaPeer({
    required this.id,
    this.name = '',
    this.isLocal = false,
    this.micOn = true,
    this.camOn = false,
    this.screenOn = false,
    this.speaking = false,
  });
  final String id;
  final String name;
  final bool isLocal;
  final bool micOn;
  final bool camOn;
  final bool screenOn;
  final bool speaking;
}

/// The SFU media side (LiveKit in the app, a fake in tests / the gallery).
abstract class GroupRoom {
  /// Connect + publish the mic (and the camera when [camera]). Throws
  /// [GroupRoomException].
  Future<void> connect(String url, String token,
      {required bool camera, required bool mic});
  Future<void> disconnect();
  Future<void> setMic(bool on);
  Future<void> setCamera(bool on);
  Future<void> flipCamera();

  /// Publish / unpublish the screen. The caller already got the user's
  /// MediaProjection consent and the foreground service (Android 14 rule).
  Future<void> setScreenShare(bool on);
  Future<void> setSpeaker(bool on);

  GroupLink get link;

  /// Why the SFU dropped us ('removed' | 'room_deleted' | 'duplicate' | ''),
  /// valid when [link] is disconnected.
  String get disconnectReason;
  List<GroupMediaPeer> get peers;

  /// Loudest first (LiveKit activeSpeakersChanged).
  List<String> get activeSpeakers;

  /// The published track sid of [identity] (host "mute" needs it).
  String? trackSid(String identity, {required bool video});

  /// Fires whenever peers / speakers / link change.
  Stream<void> get changes;

  /// The video of [identity] (camera, or the screen when [screen]); null
  /// when there is none.
  Widget? videoView(String identity, {bool screen = false});
}

class GroupRoomException implements Exception {
  GroupRoomException(this.kind, [this.detail = '']);

  /// 'denied' (mic permission) | 'unreachable' | 'failed'
  final String kind;
  final String detail;
  @override
  String toString() => 'GroupRoomException($kind, $detail)';
}

/// The server side (ApiGroupCalls in the app).
abstract class GroupCallApi {
  Future<Map<String, dynamic>> start(
      {int? callId, int? groupId, List<int> memberIds, String kind});
  Future<Map<String, dynamic>> token(String room);
  Future<Map<String, dynamic>> event(String room, String event, {bool? video});
  Future<Map<String, dynamic>> status(String room);
  Future<Map<String, dynamic>> invite(String room, List<int> memberIds);
  Future<void> mute(String room, int userId,
      {required String kind, String? trackSid});
  Future<void> remove(String room, int userId);
  Future<Map<String, dynamic>> record(String room, String action);

  /// call.group events for [room] (state / record / muted / removed / ended).
  Stream<Map<String, dynamic>> events(String room);
}

/// Hooks around a screen share (consent dialog + foreground service). The
/// app wires flutter_webrtc's MediaProjection consent + CallKeepAlive.
abstract class ScreenShareHost {
  /// Can this phone share at all (hidden otherwise).
  Future<bool> supported();

  /// Ask the user (system MediaProjection dialog) and start the foreground
  /// service of type mediaProjection. false = declined / impossible.
  Future<bool> begin();
  Future<void> end();
}

/// One tile of the grid: server seat + SFU media merged.
@immutable
class GroupTile {
  const GroupTile({
    required this.id,
    required this.name,
    this.photo = '',
    this.isLocal = false,
    this.isHost = false,
    this.inRoom = false,
    this.state = '',
    this.micOn = true,
    this.camOn = false,
    this.screenOn = false,
    this.speaking = false,
  });
  final String id;
  final String name;
  final String photo;
  final bool isLocal;
  final bool isHost;

  /// connected to the SFU right now
  final bool inRoom;

  /// server seat: invited | joined | left | declined | removed
  final String state;
  final bool micOn;
  final bool camOn;
  final bool screenOn;
  final bool speaking;
  bool get ringing => !inRoom && state == 'invited';
}

class GroupCallController extends ChangeNotifier {
  GroupCallController({
    required this.api,
    required this.media,
    this.room,
    this.callId,
    this.groupId,
    this.memberIds = const [],
    this.video = false,
    this.screenHost,
    this.recording,
    this.selfId,
    this.statusEvery = const Duration(seconds: 8),
    this.reconnectGiveUp = const Duration(seconds: 30),
  }) : cameraOn = video;

  final GroupCallApi api;
  final GroupRoom media;

  /// Join this room (incoming ring / group banner). null = [start] creates it
  /// from [callId] (add people to a 1:1) or [groupId] (group chat).
  String? room;
  final int? callId;
  final int? groupId;
  final List<int> memberIds;

  /// Start with the camera on (video room).
  final bool video;
  final ScreenShareHost? screenHost;

  /// B5 consent recording (created by the screen; may be null in tests).
  RecordingSession? recording;

  /// My user id (LiveKit identity); learnt from the token when null.
  String? selfId;
  final Duration statusEvery;
  final Duration reconnectGiveUp;

  GroupPhase phase = GroupPhase.joining;
  GroupEndReason endReason = GroupEndReason.none;
  GroupNotice notice = GroupNotice.none;
  int noticeSeq = 0;

  String kind = 'voice';
  bool isHost = false;
  String groupName = '';
  int maxParticipants = 8;
  bool roomLive = true;
  bool micOn = true;
  bool cameraOn;
  bool speakerOn = true;
  bool screenSharing = false;
  bool screenShareAvailable = false;

  /// "Speaker view" (one big active speaker) instead of the grid.
  bool speakerView = false;
  Map<String, dynamic>? upgradePrompt;
  DateTime? connectedAt;
  final List<String> log = [];

  /// server seats by user id (name, photo, role, state)
  final Map<String, Map<String, dynamic>> _seats = {};
  StreamSubscription<void>? _mediaSub;
  StreamSubscription<Map<String, dynamic>>? _evSub;
  Timer? _statusTimer;
  Timer? _giveUp;
  bool _disposed = false;
  bool _started = false;
  String _lastSpeaker = '';

  bool get isEnded => phase == GroupPhase.ended;
  bool get isLive =>
      phase == GroupPhase.connected || phase == GroupPhase.reconnecting;
  bool get isVideoRoom => kind == 'video';

  /// I left / dropped, but the room still lives: "Rejoin".
  bool get canRejoin =>
      isEnded &&
      roomLive &&
      room != null &&
      (endReason == GroupEndReason.left ||
          endReason == GroupEndReason.failed ||
          endReason == GroupEndReason.unavailable ||
          endReason == GroupEndReason.network);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _notice(GroupNotice n) {
    notice = n;
    noticeSeq++;
    _notify();
  }

  // ------------------------------------------------------------- start
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    Map<String, dynamic> join;
    try {
      if (room == null) {
        final body = await api.start(
            callId: callId,
            groupId: groupId,
            memberIds: memberIds,
            kind: video ? 'video' : 'voice');
        _applyStatus(body);
        join = (body['join'] as Map).cast<String, dynamic>();
      } else {
        _applyStatus(await api.status(room!));
        join = await api.token(room!);
      }
    } catch (e) {
      log.add('start-failed:$e');
      return _finish(_reasonFor(e));
    }
    await _connect(join);
  }

  GroupEndReason _reasonFor(Object e) {
    if (e is ApiException) {
      switch (e.status) {
        case 503:
          return GroupEndReason.unavailable;
        case 402:
          return GroupEndReason.upgrade;
        case 409:
          return GroupEndReason.full;
        case 410:
          return GroupEndReason.ended;
        case 403:
          return GroupEndReason.removed;
        case 404:
          return GroupEndReason.ended;
        case null:
          return GroupEndReason.network;
      }
      return GroupEndReason.failed;
    }
    return GroupEndReason.network;
  }

  Future<void> _connect(Map<String, dynamic> join) async {
    if (_disposed) return;
    selfId ??= '${join['identity'] ?? ''}';
    isHost = join['host'] == true || isHost;
    phase = GroupPhase.joining;
    _notify();
    _mediaSub ??= media.changes.listen((_) => _onMedia());
    _evSub ??= api.events(room!).listen(_onEvent, onError: (_) {});
    try {
      await media.connect('${join['url']}', '${join['token']}',
          camera: isVideoRoom && cameraOn, mic: micOn);
    } on GroupRoomException catch (e) {
      log.add('connect-failed:${e.kind}');
      return _finish(e.kind == 'denied'
          ? GroupEndReason.mediaDenied
          : GroupEndReason.unavailable);
    } catch (e) {
      log.add('connect-failed:$e');
      return _finish(GroupEndReason.unavailable);
    }
    if (_disposed || isEnded) return;
    phase = GroupPhase.connected;
    connectedAt ??= DateTime.now();
    log.add('phase:connected');
    try {
      _applyStatus(await api.event(room!, 'joined',
          video: isVideoRoom && cameraOn));
    } catch (e) {
      callLog('group#joined', e);
    }
    if (statusEvery > Duration.zero) {
      _statusTimer ??=
          Timer.periodic(statusEvery, (_) => unawaited(_poll()));
    }
    unawaited(_checkScreenShare());
    _notify();
  }

  Future<void> _checkScreenShare() async {
    try {
      screenShareAvailable = await screenHost?.supported() ?? false;
    } catch (_) {
      screenShareAvailable = false;
    }
    _notify();
  }

  Future<void> _poll() async {
    final r = room;
    if (r == null || isEnded) return;
    try {
      _applyStatus(await api.status(r));
    } catch (e) {
      callLog('group#poll', e);
    }
  }

  @visibleForTesting
  void debugApplyStatus(Map<String, dynamic> s) => _applyStatus(s);

  void _applyStatus(Map<String, dynamic> s) {
    room = '${s['room'] ?? room ?? ''}';
    kind = '${s['kind'] ?? kind}';
    isHost = s['is_host'] == true || isHost;
    groupName = '${s['group_name'] ?? groupName}';
    maxParticipants = (s['max_participants'] as num?)?.toInt() ?? maxParticipants;
    roomLive = '${s['state'] ?? 'live'}' == 'live';
    for (final p in (s['participants'] as List? ?? const [])) {
      if (p is! Map) continue;
      final m = p.cast<String, dynamic>();
      _seats['${m['user_id']}'] = m;
    }
    final rec = s['recording'];
    if (rec is Map) {
      unawaited(recording?.apply(rec.cast<String, dynamic>()));
    }
    final me = s['me'];
    if (me is Map && me['state'] == 'removed' && !isEnded) {
      unawaited(_finish(GroupEndReason.removed));
      return;
    }
    if (!roomLive && !isEnded && phase != GroupPhase.joining) {
      unawaited(_finish(GroupEndReason.ended));
      return;
    }
    _notify();
  }

  void _onEvent(Map<String, dynamic> e) {
    final k = '${e['kind'] ?? ''}';
    log.add('event:$k');
    switch (k) {
      case 'state':
        unawaited(_poll());
        break;
      case 'record':
        final v = e['recording'];
        if (v is Map) unawaited(recording?.apply(v.cast<String, dynamic>()));
        break;
      case 'muted':
        if (e['media'] == 'video') {
          cameraOn = false;
        } else {
          micOn = false;
        }
        _notice(GroupNotice.mutedByHost);
        break;
      case 'removed':
        unawaited(_finish(GroupEndReason.removed));
        break;
      case 'ended':
        roomLive = false;
        unawaited(_finish(GroupEndReason.ended));
        break;
    }
  }

  void _onMedia() {
    if (_disposed || isEnded) return;
    final l = media.link;
    if (l == GroupLink.reconnecting && phase == GroupPhase.connected) {
      phase = GroupPhase.reconnecting;
      _giveUp ??= Timer(reconnectGiveUp, () {
        if (phase == GroupPhase.reconnecting) {
          unawaited(_finish(GroupEndReason.failed));
        }
      });
    } else if (l == GroupLink.connected && phase == GroupPhase.reconnecting) {
      phase = GroupPhase.connected;
      _giveUp?.cancel();
      _giveUp = null;
      _notice(GroupNotice.reconnected);
    } else if (l == GroupLink.disconnected && isLive) {
      final why = media.disconnectReason;
      unawaited(_finish(why == 'removed'
          ? GroupEndReason.removed
          : why == 'room_deleted'
              ? GroupEndReason.ended
              : GroupEndReason.failed));
      return;
    }
    // my own mic/cam as the SFU reports them (host mute lands here too)
    for (final p in media.peers) {
      if (p.isLocal) {
        micOn = p.micOn;
        if (!screenSharing) cameraOn = p.camOn;
      }
    }
    final s = media.activeSpeakers;
    if (s.isNotEmpty) _lastSpeaker = s.first;
    _notify();
  }

  // ------------------------------------------------------------- view
  /// Everyone in the call (me first), SFU state merged with server seats.
  /// Invited people who have not joined yet show as "Ringing…" tiles.
  List<GroupTile> get tiles {
    final out = <GroupTile>[];
    final seen = <String>{};
    final speakers = media.activeSpeakers.toSet();
    final mp = [...media.peers]..sort((a, b) => a.isLocal
        ? -1
        : b.isLocal
            ? 1
            : 0);
    for (final p in mp) {
      final seat = _seats[p.id] ?? const {};
      seen.add(p.id);
      out.add(GroupTile(
        id: p.id,
        name: p.name.isNotEmpty ? p.name : '${seat['name'] ?? ''}',
        photo: '${seat['photo'] ?? ''}',
        isLocal: p.isLocal,
        isHost: seat['role'] == 'host',
        inRoom: true,
        state: 'joined',
        micOn: p.micOn,
        camOn: p.camOn,
        screenOn: p.screenOn,
        speaking: p.speaking || speakers.contains(p.id),
      ));
    }
    for (final e in _seats.entries) {
      if (seen.contains(e.key) || e.key == selfId) continue;
      final st = '${e.value['state'] ?? ''}';
      if (st != 'invited') continue; // left / declined / removed: no tile
      out.add(GroupTile(
          id: e.key,
          name: '${e.value['name'] ?? ''}',
          photo: '${e.value['photo'] ?? ''}',
          isHost: e.value['role'] == 'host',
          state: st,
          micOn: false));
    }
    return out;
  }

  /// The person to show big in speaker view: the loudest remote speaker, a
  /// screen share first, else the last one who spoke, else the first remote.
  String? get activeSpeakerId {
    final remote = media.peers.where((p) => !p.isLocal).toList();
    for (final p in remote) {
      if (p.screenOn) return p.id;
    }
    for (final id in media.activeSpeakers) {
      if (remote.any((p) => p.id == id)) return id;
    }
    if (remote.any((p) => p.id == _lastSpeaker)) return _lastSpeaker;
    return remote.isEmpty ? null : remote.first.id;
  }

  /// How many in the SFU right now (me included).
  int get presentCount => media.peers.length;

  /// Grid shape: 1-2 people one column, 3-4 = 2x2, 5-9 = 3x3, more pages.
  static int columnsFor(int n) => n <= 2 ? 1 : (n <= 4 ? 2 : 3);
  static int perPage(int n) => n <= 4 ? 4 : 9;

  // ------------------------------------------------------------- controls
  Future<void> toggleMic() async {
    micOn = !micOn;
    _notify();
    try {
      await media.setMic(micOn);
    } catch (e) {
      callLog('group#mic', e);
    }
  }

  Future<void> toggleCamera() async {
    if (!isVideoRoom) return;
    cameraOn = !cameraOn;
    _notify();
    try {
      await media.setCamera(cameraOn);
      await api.event(room!, 'media', video: cameraOn || screenSharing);
    } catch (e) {
      callLog('group#cam', e);
    }
  }

  Future<void> flipCamera() async {
    try {
      await media.flipCamera();
    } catch (e) {
      callLog('group#flip', e);
    }
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    _notify();
    try {
      await media.setSpeaker(speakerOn);
    } catch (e) {
      callLog('group#speaker', e);
    }
  }

  void toggleLayout() {
    speakerView = !speakerView;
    _notify();
  }

  /// B4: share my screen (consent dialog + foreground service first).
  Future<void> toggleScreenShare() async {
    if (!isLive) return;
    if (screenSharing) {
      screenSharing = false;
      _notify();
      try {
        await media.setScreenShare(false);
        await api.event(room!, 'media', video: cameraOn);
      } catch (e) {
        callLog('group#screen-off', e);
      }
      await screenHost?.end();
      return;
    }
    final host = screenHost;
    if (host == null || !screenShareAvailable) return;
    final ok = await host.begin();
    if (!ok) {
      log.add('screen:declined');
      return;
    }
    try {
      await media.setScreenShare(true);
      screenSharing = true;
      log.add('screen:on');
      unawaited(api.event(room!, 'media', video: true).catchError(
          (Object e) => <String, dynamic>{}));
    } catch (e) {
      log.add('screen:failed:$e');
      await host.end();
      _notice('$e'.contains('canPublish') || '$e'.contains('permission')
          ? GroupNotice.screenSharePremium
          : GroupNotice.screenShareFailed);
    }
    _notify();
  }

  /// Host: mute someone's mic (or camera). They unmute themselves.
  Future<void> hostMute(GroupTile t, {bool video = false}) async {
    if (!isHost || t.isLocal) return;
    try {
      await api.mute(room!, int.parse(t.id),
          kind: video ? 'video' : 'audio',
          trackSid: media.trackSid(t.id, video: video));
      log.add('host:mute:${t.id}');
    } catch (e) {
      callLog('group#mute', e);
      _notice(GroupNotice.hostActionFailed);
    }
  }

  Future<void> hostRemove(GroupTile t) async {
    if (!isHost || t.isLocal) return;
    try {
      await api.remove(room!, int.parse(t.id));
      log.add('host:remove:${t.id}');
      _seats[t.id] = {...?_seats[t.id], 'state': 'removed'};
      _notify();
    } catch (e) {
      callLog('group#remove', e);
      _notice(GroupNotice.hostActionFailed);
    }
  }

  Future<bool> invite(List<int> memberIds) async {
    if (memberIds.isEmpty || room == null) return false;
    try {
      _applyStatus(await api.invite(room!, memberIds));
      _notice(GroupNotice.inviteSent);
      return true;
    } catch (e) {
      callLog('group#invite', e);
      _notice(GroupNotice.inviteFailed);
      return false;
    }
  }

  // ------------------------------------------------------------- leave
  Future<void> leave() async {
    if (isEnded) return;
    final r = room;
    if (r != null) {
      unawaited(api.event(r, 'left').then<void>((_) {}, onError: (Object e) {
        callLog('group#left', e);
      }));
    }
    await _finish(GroupEndReason.left);
  }

  /// Back into the same room while it lives (fresh token).
  Future<void> rejoin() async {
    if (!canRejoin || _disposed) return;
    phase = GroupPhase.joining;
    endReason = GroupEndReason.none;
    log.add('rejoin');
    _notify();
    Map<String, dynamic> join;
    try {
      join = await api.token(room!);
    } catch (e) {
      return _finish(_reasonFor(e));
    }
    await _connect(join);
  }

  Future<void> _finish(GroupEndReason reason) async {
    if (isEnded && endReason != GroupEndReason.none) return;
    endReason = reason;
    phase = GroupPhase.ended;
    log.add('ended:${reason.name}');
    _statusTimer?.cancel();
    _statusTimer = null;
    _giveUp?.cancel();
    _giveUp = null;
    if (reason == GroupEndReason.ended || reason == GroupEndReason.removed) {
      roomLive = reason != GroupEndReason.ended && roomLive;
    }
    try {
      await recording?.close();
    } catch (_) {}
    if (screenSharing) {
      screenSharing = false;
      try {
        await screenHost?.end();
      } catch (_) {}
    }
    try {
      await media.disconnect();
    } catch (e) {
      callLog('group#disconnect', e);
    }
    _notify();
  }

  @override
  void dispose() {
    if (!isEnded) unawaited(leave());
    _disposed = true;
    _statusTimer?.cancel();
    _giveUp?.cancel();
    _mediaSub?.cancel();
    _evSub?.cancel();
    super.dispose();
  }
}
