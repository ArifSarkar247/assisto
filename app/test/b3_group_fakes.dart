// b3-group fakes: an SFU room, the group-call server API, a screen-share
// host, a recorder engine and an in-memory recording vault — shared by
// b3_group_test.dart and the gallery (b3_group_shots.dart).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/call_recording.dart';
import 'package:assisto/calls/group_call.dart';

class FakeGroupRoom implements GroupRoom {
  FakeGroupRoom({List<GroupMediaPeer>? peers})
      : _peers = peers ?? [const GroupMediaPeer(id: '1', name: 'Me', isLocal: true)];

  List<GroupMediaPeer> _peers;
  List<String> speakers = [];
  GroupLink _link = GroupLink.idle;
  String reason = '';
  Object? connectError;
  final log = <String>[];
  final _changes = StreamController<void>.broadcast();
  final Map<String, String> sids = {};

  void set({List<GroupMediaPeer>? peers, List<String>? active, GroupLink? link,
      String? why}) {
    if (peers != null) _peers = peers;
    if (active != null) speakers = active;
    if (link != null) _link = link;
    if (why != null) reason = why;
    _changes.add(null);
  }

  @override
  Future<void> connect(String url, String token,
      {required bool camera, required bool mic}) async {
    log.add('connect:$url:$token:camera=$camera:mic=$mic');
    final e = connectError;
    if (e != null) throw e;
    _link = GroupLink.connected;
  }

  @override
  Future<void> disconnect() async {
    log.add('disconnect');
    _link = GroupLink.disconnected;
  }

  @override
  Future<void> setMic(bool on) async => log.add('mic:$on');
  @override
  Future<void> setCamera(bool on) async => log.add('camera:$on');
  @override
  Future<void> flipCamera() async => log.add('flip');
  @override
  Future<void> setScreenShare(bool on) async => log.add('screen:$on');
  @override
  Future<void> setSpeaker(bool on) async => log.add('speaker:$on');
  @override
  GroupLink get link => _link;
  @override
  String get disconnectReason => reason;
  @override
  List<GroupMediaPeer> get peers => _peers;
  @override
  List<String> get activeSpeakers => speakers;
  @override
  String? trackSid(String identity, {required bool video}) =>
      sids['$identity:${video ? 'v' : 'a'}'];
  @override
  Stream<void> get changes => _changes.stream;

  @override
  Widget? videoView(String identity, {bool screen = false}) {
    final p = _peers.where((x) => x.id == identity).firstOrNull;
    if (p == null || !(p.camOn || p.screenOn)) return null;
    return DecoratedBox(
      key: Key('video-$identity${screen ? '-screen' : ''}'),
      decoration: BoxDecoration(
          gradient: LinearGradient(colors: screen
              ? const [Color(0xFF1E3A5F), Color(0xFF3B6EF6)]
              : const [Color(0xFF6B4E3D), Color(0xFF2D3A4A)])),
      child: Center(
          child: Icon(screen ? Icons.desktop_windows_outlined : Icons.face,
              color: Colors.white54, size: 48)),
    );
  }
}

class FakeGroupApi implements GroupCallApi {
  FakeGroupApi({this.host = true, this.kind = 'voice'});
  bool host;
  String kind;
  final log = <String>[];
  Object? startError;
  Object? tokenError;
  Object? muteError;
  Map<String, dynamic> recordAnswer = {};
  List<Map<String, dynamic>> participants = [
    {'user_id': 1, 'name': 'Me', 'role': 'host', 'state': 'joined'},
    {'user_id': 2, 'name': 'Nadia', 'role': 'member', 'state': 'joined'},
    {'user_id': 3, 'name': 'Rafi', 'role': 'member', 'state': 'invited'},
  ];
  String state = 'live';
  Map<String, dynamic>? recording;
  final _ev = StreamController<Map<String, dynamic>>.broadcast();

  void push(Map<String, dynamic> e) => _ev.add({'room': 'gc-1', ...e});

  Map<String, dynamic> body() => {
        'room': 'gc-1',
        'kind': kind,
        'state': state,
        'is_host': host,
        'group_name': 'Family',
        'max_participants': 8,
        'participants': participants,
        'me': {'role': host ? 'host' : 'member', 'state': 'joined'},
        if (recording != null) 'recording': recording,
      };

  Map<String, dynamic> join() => {
        'url': 'wss://sfu.test/livekit',
        'token': 'tok-1',
        'identity': '1',
        'host': host,
        'kind': kind,
      };

  @override
  Future<Map<String, dynamic>> start(
      {int? callId,
      int? groupId,
      List<int> memberIds = const [],
      String kind = 'voice'}) async {
    log.add('start:call=$callId:group=$groupId:members=$memberIds:$kind');
    final e = startError;
    if (e != null) throw e;
    return {...body(), 'join': join()};
  }

  @override
  Future<Map<String, dynamic>> token(String room) async {
    log.add('token:$room');
    final e = tokenError;
    if (e != null) throw e;
    return join();
  }

  @override
  Future<Map<String, dynamic>> event(String room, String event,
      {bool? video}) async {
    log.add(video == null ? 'event:$event' : 'event:$event:video=$video');
    return body();
  }

  @override
  Future<Map<String, dynamic>> status(String room) async {
    log.add('status');
    return body();
  }

  @override
  Future<Map<String, dynamic>> invite(String room, List<int> memberIds) async {
    log.add('invite:$memberIds');
    return body();
  }

  @override
  Future<void> mute(String room, int userId,
      {required String kind, String? trackSid}) async {
    log.add('mute:$userId:$kind:$trackSid');
    final e = muteError;
    if (e != null) throw e;
  }

  @override
  Future<void> remove(String room, int userId) async =>
      log.add('remove:$userId');

  @override
  Future<Map<String, dynamic>> record(String room, String action) async {
    log.add('record:$action');
    return recordAnswer;
  }

  @override
  Stream<Map<String, dynamic>> events(String room) => _ev.stream;
}

class FakeScreenHost implements ScreenShareHost {
  FakeScreenHost({this.ok = true, this.can = true});
  bool ok;
  bool can;
  final log = <String>[];
  @override
  Future<bool> supported() async => can;
  @override
  Future<bool> begin() async {
    log.add('begin');
    return ok;
  }

  @override
  Future<void> end() async => log.add('end');
}

class FakeRecorder implements CallRecorderEngine {
  final log = <String>[];
  @override
  Future<List<String>> start(String dir) async {
    log.add('start');
    return ['$dir/a.m4a'];
  }

  @override
  Future<void> stop() async => log.add('stop');
}

/// No file I/O: remembers what would have been encrypted + saved.
class MemoryVault extends RecordingVault {
  MemoryVault() : super(dir: () async => Directory.systemTemp);
  final saved = <SavedRecording>[];
  List<SavedRecording> items = [];

  @override
  Future<Directory> tmpDir() async => Directory('/tmp/b3-test');

  @override
  Future<SavedRecording?> save({
    required List<String> rawFiles,
    required String title,
    required DateTime startedAt,
    required Duration length,
    required List<String> people,
  }) async {
    final r = SavedRecording(
        id: '${saved.length + 1}',
        title: title,
        at: startedAt,
        seconds: length.inSeconds,
        people: people,
        parts: rawFiles);
    saved.add(r);
    return r;
  }

  @override
  Future<List<SavedRecording>> list() async => items;
}

ApiException apiErr(int? status) => ApiException('x', status);

/// A connected group controller for the gallery / widget tests.
GroupCallController previewGroup({
  bool host = true,
  bool video = false,
  int people = 3,
  bool speakerView = false,
  bool sharing = false,
  String? speaking,
  Map<String, dynamic>? recording,
  bool ringing = true,
  FakeGroupApi? api,
  FakeGroupRoom? room,
  RecordingSession? session,
  List<String> names = const ['Nadia', 'Rafi', 'Mitu', 'Sumon', 'Lima',
    'Tanvir', 'Ruma', 'Jamal'],
}) {
  final a = api ?? FakeGroupApi(host: host, kind: video ? 'video' : 'voice');
  final peers = <GroupMediaPeer>[
    GroupMediaPeer(id: '1', name: 'Me', isLocal: true, camOn: video),
    for (var i = 0; i < people - 1; i++)
      GroupMediaPeer(
          id: '${i + 2}',
          name: names[i % names.length],
          micOn: i != 1,
          camOn: video && i != 2,
          screenOn: false,
          speaking: '${i + 2}' == speaking),
  ];
  a.participants = [
    {'user_id': 1, 'name': 'Me', 'role': host ? 'host' : 'member', 'state': 'joined'},
    for (final p in peers.skip(1))
      {'user_id': int.parse(p.id), 'name': p.name, 'role': 'member', 'state': 'joined'},
    if (ringing)
      {'user_id': 99, 'name': names.last, 'role': 'member', 'state': 'invited'},
  ];
  final r = room ?? FakeGroupRoom(peers: peers);
  if (speaking != null) r.speakers = [speaking];
  final c = GroupCallController(
      api: a, media: r, room: 'gc-1', video: video, selfId: '1');
  c.phase = GroupPhase.connected;
  c.kind = video ? 'video' : 'voice';
  c.isHost = host;
  c.groupName = 'Family';
  c.cameraOn = video;
  c.speakerView = speakerView;
  c.screenSharing = sharing;
  c.screenShareAvailable = true;
  c.connectedAt = DateTime(2026, 10, 23, 10);
  // seats as the server would report them
  c.debugApplyStatus(a.body());
  final s = session ??
      RecordingSession(
          send: (x) async => {}, engine: FakeRecorder(), vault: MemoryVault());
  if (recording != null) s.consent = RecordingConsent.fromJson(recording);
  c.recording = s;
  return c;
}
