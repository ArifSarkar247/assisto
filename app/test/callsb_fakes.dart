// callsB fakes: group-call API, screen-share media + native service, roster
// builders and frozen preview sessions for tests and the gallery.
import 'dart:async';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/group/group_call.dart';
import 'package:assisto/calls/media_ext.dart';
import 'package:assisto/calls/screen_share.dart';

import 'c2_calls_fakes.dart';

/// FakeCallMedia that can share the screen.
class FakeShareMedia extends FakeCallMedia
    implements ScreenShareMedia, AudioLevelMedia {
  /// What the system consent dialog / capture does.
  Object? startError;
  bool needsReneg = false;
  bool sharingNow = false;
  bool beforeCaptureCalled = false;
  double? level;

  @override
  bool get screenSharing => sharingNow;

  @override
  Future<List<Object>> startScreenShare(
      {required Future<bool> Function() beforeCapture}) async {
    log.add('share:consent');
    final e = startError;
    if (e is ScreenShareDenied) throw e; // refused BEFORE the service
    beforeCaptureCalled = true;
    if (!await beforeCapture()) throw const ScreenShareFailed('service');
    if (e != null) throw e;
    sharingNow = true;
    log.add('share:on');
    return needsReneg ? [this] : const [];
  }

  @override
  Future<void> stopScreenShare() async {
    sharingNow = false;
    log.add('share:off');
  }

  @override
  Future<double?> remoteAudioLevel() async => level;
}

class FakeShareService implements ScreenShareService {
  bool allow = true;
  final log = <String>[];
  final _stops = StreamController<void>.broadcast();

  void tapNotificationStop() => _stops.add(null);

  @override
  Stream<void> get stopRequests => _stops.stream;

  @override
  Future<bool> start(
      {required String title,
      required String body,
      required String stop}) async {
    log.add('start:$title');
    return allow;
  }

  @override
  Future<void> stop() async => log.add('stop');
}

class FakeGroupApi implements GroupCallApi {
  final log = <String>[];
  final _ev = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic> next = {};
  Object? addError;

  void push(Map<String, dynamic> roster) => _ev.add(roster);

  @override
  Future<Map<String, dynamic>> addPerson(int callId, int memberId) async {
    log.add('add:$callId:$memberId');
    final e = addError;
    if (e != null) throw e;
    return next;
  }

  @override
  Future<Map<String, dynamic>?> roomOfCall(int callId) async {
    log.add('room-of:$callId');
    return null;
  }

  @override
  Future<Map<String, dynamic>> room(int roomId) async {
    log.add('room:$roomId');
    return next;
  }

  @override
  Future<Map<String, dynamic>> join(int roomId) async {
    log.add('join:$roomId');
    return next;
  }

  @override
  Future<Map<String, dynamic>> leave(int roomId) async {
    log.add('leave:$roomId');
    return next;
  }

  @override
  Future<void> media(int roomId, Map<String, dynamic> data) async =>
      log.add('media:$data');

  @override
  Stream<Map<String, dynamic>> rosterEvents() => _ev.stream;
}

/// Fixture people (never the owner's name).
const kMe = 1, kKarim = 2, kSalma = 3, kNadia = 4;

String fixtureName(int id, String lang) => switch (id) {
      kMe => lang == 'bn' ? 'রহিম' : 'Rahim',
      kKarim => lang == 'bn' ? 'করিম' : 'Karim',
      kSalma => lang == 'bn' ? 'সালমা' : 'Salma',
      _ => lang == 'bn' ? 'নাদিয়া' : 'Nadia',
    };

Map<String, dynamic> member(int id,
        {String state = 'joined',
        bool muted = false,
        bool camera = true,
        bool screen = false,
        String lang = 'en'}) =>
    {
      'user_id': id,
      'name': fixtureName(id, lang),
      'state': state,
      'me': id == kMe,
      'muted': muted,
      'camera': camera,
      'screen': screen,
      'member_id': id == kMe ? null : 100 + id,
    };

Map<String, dynamic> link(int callId, int peer, {String role = 'caller',
        String via = 'mesh', String state = 'connecting'}) =>
    {
      'call_id': callId,
      'via': via,
      'peer_user_id': peer,
      'role': role,
      'state': state,
    };

Map<String, dynamic> roster({
  required List<Map<String, dynamic>> members,
  List<Map<String, dynamic>> links = const [],
  String kind = 'voice',
  String state = 'live',
  String myState = 'joined',
  int roomId = 7,
  String groupName = '',
}) {
  final active =
      members.where((m) => m['state'] == 'ringing' || m['state'] == 'joined');
  return {
    'room_id': roomId,
    'kind': kind,
    'state': state,
    'group_name': groupName,
    'max': 4,
    'active': active.length,
    'joined': members.where((m) => m['state'] == 'joined').length,
    'my_state': myState,
    'can_add': state == 'live' && active.length < 4,
    'low_bandwidth': active.length >= 3,
    'members': members,
    'links': links,
  };
}

/// A session over fakes: every link gets a FakeSignaling-driven controller.
GroupCallSession fakeSession({
  required FakeGroupApi api,
  CallController? primary,
  Map<String, dynamic>? initial,
  List<CallController>? made,
  MeshHost? host,
}) =>
    GroupCallSession(
      api: api,
      primary: primary,
      host: host,
      roster: initial == null ? null : GroupRoster.fromJson(initial),
      levelsEvery: const Duration(hours: 1),
      pollEvery: const Duration(hours: 1),
      newLinkMedia: () => FakeShareMedia(),
      makeLink: (l, media, video) {
        final c = CallController(
          media: media,
          signaling: FakeSignaling(
              acceptBody: {'phase': 'accepted', 'call_id': l.callId}),
          sounds: const SilentCallSounds(),
          video: video,
          outgoing: l.offerer,
          preplaced: l.offerer,
          callId: l.callId,
          setupRetryDelays: const [],
        );
        made?.add(c);
        return c;
      },
    );

/// A frozen session for the gallery: links already "connected".
GroupCallSession previewSession({
  required String lang,
  required int people,
  String kind = 'voice',
  Set<int> muted = const {},
  Set<int> speaking = const {},
  Set<int> ringing = const {},
  Set<int> screen = const {},
  String groupName = '',
}) {
  final ids = [kMe, kKarim, kSalma, kNadia].take(people).toList();
  final r = roster(
    kind: kind,
    groupName: groupName,
    members: [
      for (final id in ids)
        member(id,
            lang: lang,
            muted: muted.contains(id),
            screen: screen.contains(id),
            state: ringing.contains(id) ? 'ringing' : 'joined'),
    ],
  );
  final s = GroupCallSession(
    api: FakeGroupApi(),
    roster: GroupRoster.fromJson(r),
    levelsEvery: const Duration(hours: 1),
    pollEvery: const Duration(hours: 1),
    newLinkMedia: () => FakeCallMedia(),
    makeLink: (l, m, v) => throw StateError('preview'),
    timers: false,
  );
  s.assumeConnected = true;
  s.muted = muted.contains(kMe);
  s.cameraOn = kind == 'video';
  s.setSpeaking(speaking);
  return s;
}
