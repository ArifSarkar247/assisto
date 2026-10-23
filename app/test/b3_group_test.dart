// b3-group: group calls (LiveKit SFU) — controller state machine with a fake
// room + fake server, grid / active speaker, host menu (mute / remove), leave
// + rejoin, honest errors; add-person flow from a 1:1 call; screen share
// (B4) banner + 1:1 renegotiation + plan gate; consented recording (B5): all
// accept starts, one decline blocks, a new joiner pauses.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_group_calls.dart';
import 'package:assisto/calls/call_banners.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_recording.dart';
import 'package:assisto/calls/circle_pick_sheet.dart';
import 'package:assisto/calls/group_call.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/group_call_screen.dart';

import 'b3_group_fakes.dart';
import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 40);

Widget app(Widget child, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

GroupCallController mkGroup(FakeGroupApi a, FakeGroupRoom r,
        {String? room, int? callId, int? groupId, bool video = false,
        ScreenShareHost? host}) =>
    GroupCallController(
      api: a,
      media: r,
      room: room,
      callId: callId,
      groupId: groupId,
      memberIds: callId != null ? const [5, 6] : const [],
      video: video,
      screenHost: host,
      statusEvery: const Duration(seconds: 30),
      reconnectGiveUp: const Duration(milliseconds: 200),
    );

/// 1:1 media that can share the screen.
class ShareMedia extends FakeCallMedia implements ScreenShareMedia {
  bool addsSender = true;
  @override
  Future<bool> startScreen() async {
    log.add('screen:start');
    return addsSender;
  }

  @override
  Future<void> stopScreen({required bool camera}) async =>
      log.add('screen:stop:camera=$camera');
}

class GateSig extends FakeSignaling {
  bool gate = false;
  @override
  Future<void> signal(int callId, String kind, Map<String, dynamic> data) {
    if (gate && kind == 'screen_start') throw const CallUpgradeRequired();
    return super.signal(callId, kind, data);
  }
}

Future<CallController> live1(FakeCallMedia m, FakeSignaling s) async {
  final c = CallController(
    media: m,
    signaling: s,
    sounds: FakeSounds(),
    video: false,
    outgoing: true,
    memberId: 7,
    statusEvery: const Duration(seconds: 30),
    statsEvery: const Duration(seconds: 30),
  );
  await c.start();
  m.link.add(MediaLinkState.connected);
  await settle();
  expect(c.phase, CallPhase.connected);
  return c;
}

void main() {
  group('group controller', () {
    test('add people to a 1:1: server room, SFU connect, joined', () async {
      final a = FakeGroupApi(), r = FakeGroupRoom();
      final c = mkGroup(a, r, callId: 42);
      await c.start();
      await settle();
      expect(a.log.first, 'start:call=42:group=null:members=[5, 6]:voice');
      expect(r.log.first, 'connect:wss://sfu.test/livekit:tok-1:camera=false:mic=true');
      expect(c.phase, GroupPhase.connected);
      expect(c.room, 'gc-1');
      expect(c.isHost, isTrue);
      expect(a.log, contains('event:joined:video=false'));
      c.dispose();
    });

    test('join an existing room: status + token', () async {
      final a = FakeGroupApi(host: false), r = FakeGroupRoom();
      final c = mkGroup(a, r, room: 'gc-1');
      await c.start();
      await settle();
      expect(a.log.take(2), ['status', 'token:gc-1']);
      expect(c.isLive, isTrue);
      expect(c.isHost, isFalse);
      c.dispose();
    });

    test('honest errors', () async {
      for (final (code, want) in [
        (503, GroupEndReason.unavailable),
        (402, GroupEndReason.upgrade),
        (409, GroupEndReason.full),
        (410, GroupEndReason.ended),
        (403, GroupEndReason.removed),
        (null, GroupEndReason.network),
      ]) {
        final a = FakeGroupApi()..startError = apiErr(code);
        final c = mkGroup(a, FakeGroupRoom(), groupId: 9);
        await c.start();
        expect(c.endReason, want, reason: '$code');
        c.dispose();
      }
      // the SFU itself unreachable / mic refused
      final r = FakeGroupRoom()
        ..connectError = GroupRoomException('unreachable');
      var c = mkGroup(FakeGroupApi(), r, room: 'gc-1');
      await c.start();
      expect(c.endReason, GroupEndReason.unavailable);
      expect(c.canRejoin, isTrue);
      c.dispose();
      r.connectError = GroupRoomException('denied');
      c = mkGroup(FakeGroupApi(), r, room: 'gc-1');
      await c.start();
      expect(c.endReason, GroupEndReason.mediaDenied);
      c.dispose();
    });

    test('tiles: me first, remote peers, invited ring, active speaker', () async {
      final a = FakeGroupApi();
      final r = FakeGroupRoom(peers: const [
        GroupMediaPeer(id: '1', name: 'Me', isLocal: true),
        GroupMediaPeer(id: '2', name: 'Nadia'),
        GroupMediaPeer(id: '4', name: 'Mitu', micOn: false),
      ]);
      final c = mkGroup(a, r, room: 'gc-1');
      await c.start();
      await settle();
      final t = c.tiles;
      expect(t.map((e) => e.id), ['1', '2', '4', '3']);
      expect(t.first.isLocal, isTrue);
      expect(t.firstWhere((e) => e.id == '4').micOn, isFalse);
      expect(t.last.ringing, isTrue); // Rafi was invited, not in the SFU yet
      expect(c.activeSpeakerId, '2');
      r.set(active: ['4']);
      await settle();
      expect(c.activeSpeakerId, '4');
      r.set(active: []);
      await settle();
      expect(c.activeSpeakerId, '4'); // the last one who spoke stays big
      r.set(peers: [
        ...r.peers,
        const GroupMediaPeer(id: '5', name: 'Sumon', screenOn: true)
      ]);
      await settle();
      expect(c.activeSpeakerId, '5'); // a screen share wins
      expect(c.tiles.firstWhere((e) => e.id == '5').screenOn, isTrue);
      c.dispose();
    });

    test('grid shape', () {
      expect([for (final n in [1, 2, 3, 4, 5, 9]) GroupCallController.columnsFor(n)],
          [1, 1, 2, 2, 3, 3]);
      expect(GroupCallController.perPage(4), 4);
      expect(GroupCallController.perPage(8), 9);
    });

    test('host mutes / removes; a member cannot', () async {
      final a = FakeGroupApi();
      final r = FakeGroupRoom(peers: const [
        GroupMediaPeer(id: '1', name: 'Me', isLocal: true),
        GroupMediaPeer(id: '2', name: 'Nadia'),
      ])
        ..sids['2:a'] = 'TR_mic2';
      final c = mkGroup(a, r, room: 'gc-1');
      await c.start();
      await settle();
      final nadia = c.tiles.firstWhere((t) => t.id == '2');
      await c.hostMute(nadia);
      expect(a.log, contains('mute:2:audio:TR_mic2'));
      await c.hostRemove(nadia);
      expect(a.log, contains('remove:2'));
      // a member: nothing goes to the server
      final b = FakeGroupApi(host: false);
      final m = mkGroup(b, r, room: 'gc-1');
      await m.start();
      await settle();
      await m.hostMute(nadia);
      await m.hostRemove(nadia);
      expect(b.log.where((l) => l.startsWith('mute') || l.startsWith('remove')),
          isEmpty);
      // the server refused / LiveKit down -> honest notice
      a.muteError = apiErr(502);
      await c.hostMute(nadia);
      expect(c.notice, GroupNotice.hostActionFailed);
      c.dispose();
      m.dispose();
    });

    test('server events: muted by host, removed, ended', () async {
      final a = FakeGroupApi(host: false), r = FakeGroupRoom();
      final c = mkGroup(a, r, room: 'gc-1');
      await c.start();
      await settle();
      a.push({'kind': 'muted', 'media': 'audio'});
      await settle();
      expect(c.micOn, isFalse);
      expect(c.notice, GroupNotice.mutedByHost);
      a.push({'kind': 'removed'});
      await settle();
      expect(c.endReason, GroupEndReason.removed);
      expect(c.canRejoin, isFalse);
      expect(r.log, contains('disconnect'));
      c.dispose();
      final c2 = mkGroup(FakeGroupApi(), FakeGroupRoom(), room: 'gc-1');
      await c2.start();
      await settle();
      (c2.api as FakeGroupApi).push({'kind': 'ended'});
      await settle();
      expect(c2.endReason, GroupEndReason.ended);
      expect(c2.canRejoin, isFalse);
      c2.dispose();
    });

    test('leave, then rejoin while the room lives', () async {
      final a = FakeGroupApi(), r = FakeGroupRoom();
      final c = mkGroup(a, r, room: 'gc-1');
      await c.start();
      await settle();
      await c.leave();
      await settle();
      expect(c.endReason, GroupEndReason.left);
      expect(a.log, contains('event:left'));
      expect(c.canRejoin, isTrue);
      a.log.clear();
      await c.rejoin();
      await settle();
      expect(a.log.first, 'token:gc-1');
      expect(c.phase, GroupPhase.connected);
      c.dispose();
    });

    test('SFU reconnect, give up, kicked by the SFU', () async {
      final a = FakeGroupApi(), r = FakeGroupRoom();
      final c = mkGroup(a, r, room: 'gc-1');
      await c.start();
      await settle();
      r.set(link: GroupLink.reconnecting);
      await settle();
      expect(c.phase, GroupPhase.reconnecting);
      r.set(link: GroupLink.connected);
      await settle();
      expect(c.phase, GroupPhase.connected);
      expect(c.notice, GroupNotice.reconnected);
      r.set(link: GroupLink.disconnected, why: 'removed');
      await settle();
      expect(c.endReason, GroupEndReason.removed);
      c.dispose();
    });

    test('screen share: consent declined = nothing; accepted = published', () async {
      final a = FakeGroupApi(), r = FakeGroupRoom();
      final h = FakeScreenHost(ok: false);
      final c = mkGroup(a, r, room: 'gc-1', host: h);
      await c.start();
      await settle();
      expect(c.screenShareAvailable, isTrue);
      await c.toggleScreenShare();
      expect(c.screenSharing, isFalse);
      expect(r.log, isNot(contains('screen:true')));
      h.ok = true;
      await c.toggleScreenShare();
      await settle();
      expect(c.screenSharing, isTrue);
      expect(r.log, contains('screen:true'));
      expect(a.log, contains('event:media:video=true'));
      await c.toggleScreenShare();
      expect(c.screenSharing, isFalse);
      expect(h.log, ['begin', 'begin', 'end']);
      c.dispose();
    });

    test('hidden where it cannot work', () async {
      final c = mkGroup(FakeGroupApi(), FakeGroupRoom(), room: 'gc-1',
          host: FakeScreenHost(can: false));
      await c.start();
      await settle();
      expect(c.screenShareAvailable, isFalse);
      await c.toggleScreenShare();
      expect(c.screenSharing, isFalse);
      c.dispose();
    });
  });

  group('recording consent (B5)', () {
    Map<String, dynamic> v(String status,
            {bool must = false, bool rec = false, int? declined}) =>
        {'id': 1, 'status': status, 'requester': 1, 'accepted': [1],
          'i_must_answer': must, 'i_record': rec, 'declined_by': declined};

    test('all accept -> the requester records; others never do', () async {
      final eng = FakeRecorder(), vault = MemoryVault();
      final s = RecordingSession(
          send: (a) async => {'recording': v('pending')},
          engine: eng,
          vault: vault);
      await s.request();
      expect(s.consent.status, RecordStatus.pending);
      expect(eng.log, isEmpty); // asking is not recording
      await s.apply(v('recording', rec: true));
      expect(eng.log, ['start']);
      expect(s.consent.recordingNow, isTrue);
      // somebody else's phone: the banner, never the engine
      final other = FakeRecorder();
      final o = RecordingSession(send: (a) async => {}, engine: other, vault: vault);
      await o.apply(v('recording'));
      expect(o.consent.recordingNow, isTrue);
      expect(other.log, isEmpty);
      await s.apply(v('stopped'));
      expect(eng.log, ['start', 'stop']);
      expect(vault.saved, hasLength(1));
      expect(s.notice, RecordNotice.saved);
    });

    test('one decline blocks: nothing is recorded', () async {
      final eng = FakeRecorder();
      final s = RecordingSession(
          send: (a) async => {}, engine: eng, vault: MemoryVault());
      await s.apply(v('pending'));
      await s.apply(v('declined', declined: 3));
      expect(eng.log, isEmpty);
      expect(s.notice, RecordNotice.declined);
      expect(s.consent.open, isFalse);
    });

    test('a new joiner pauses it until they accept', () async {
      final eng = FakeRecorder(), vault = MemoryVault();
      final s = RecordingSession(send: (a) async => {}, engine: eng, vault: vault);
      await s.apply(v('recording', rec: true));
      await s.apply(v('paused'));
      expect(eng.log, ['start', 'stop']);
      expect(vault.saved, hasLength(1)); // the agreed part is kept
      expect(s.notice, RecordNotice.paused); // the pause is what people see
      await s.apply(v('recording', rec: true));
      expect(eng.log, ['start', 'stop', 'start']);
    });

    test('the person asked answers through the server', () async {
      final sent = <String>[];
      final s = RecordingSession(
          send: (a) async {
            sent.add(a);
            return {'recording': v('recording')};
          },
          engine: null);
      await s.apply(v('pending', must: true));
      expect(s.consent.iMustAnswer, isTrue);
      await s.accept();
      expect(sent, ['accept']);
      expect(s.consent.recordingNow, isTrue);
      expect(s.canRequest, isFalse); // no recorder here: can't ask itself
    });

    test('group: server record events reach the session', () async {
      final a = FakeGroupApi(), r = FakeGroupRoom();
      final c = mkGroup(a, r, room: 'gc-1');
      final eng = FakeRecorder();
      c.recording =
          RecordingSession(send: (x) async => {}, engine: eng, vault: MemoryVault());
      await c.start();
      await settle();
      a.push({'kind': 'record', 'recording': v('recording', rec: true)});
      await settle();
      expect(eng.log, ['start']);
      a.push({'kind': 'record', 'recording': v('paused')}); // a newcomer
      await settle();
      expect(eng.log, ['start', 'stop']);
      await c.leave();
      c.dispose();
    });

    testWidgets('consent card: Allow / Don\'t allow', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(app(Scaffold(
        backgroundColor: Colors.black,
        body: RecordingConsentCard(
            requesterName: 'Nadia',
            onAllow: () => calls.add('allow'),
            onDecline: () => calls.add('decline')),
      )));
      expect(find.text('Nadia wants to record this call'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recording-allow')));
      await tester.tap(find.byKey(const Key('recording-decline')));
      expect(calls, ['allow', 'decline']);
    });

    testWidgets('red Recording banner + dot for everyone', (tester) async {
      await tester.pumpWidget(app(Scaffold(
        body: RecordingBanner(
            consent: RecordingConsent.fromJson(v('recording')),
            requesterName: 'Nadia'),
      )));
      expect(find.byKey(const Key('recording-dot')), findsOneWidget);
      expect(find.textContaining('Nadia is recording'), findsOneWidget);
    });
  });

  group('1:1 call (B3 move, B4 share, B5 state)', () {
    test('sfu_move: the other phone added people', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live1(m, s);
      s.remoteSignal('sfu_move', {'room': 'ac-9', 'kind': 'video'});
      await settle();
      expect(c.sfuMoveRoom, 'ac-9');
      expect(c.sfuMoveKind, 'video');
      c.dispose();
    });

    test('record_state reaches the attached session', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live1(m, s);
      final eng = FakeRecorder();
      c.recording =
          RecordingSession(send: (a) async => {}, engine: eng, vault: MemoryVault());
      s.remoteSignal('record_state', {
        'id': 1, 'status': 'recording', 'requester': 1, 'accepted': [1, 2],
        'i_must_answer': false, 'i_record': true
      });
      await settle();
      expect(eng.log, ['start']);
      await c.hangup();
      expect(eng.log, ['start', 'stop']); // ending the call finishes the file
      c.dispose();
    });

    test('screen share in a voice call: gate, consent, renegotiate, media', () async {
      final m = ShareMedia(), s = GateSig();
      final c = await live1(m, s);
      final h = FakeScreenHost();
      c.screenHost = h;
      c.screenShareAvailable = true;
      s.gate = true;
      await c.toggleScreenShare();
      expect(c.notice, CallNotice.videoPremium);
      expect(h.log, isEmpty); // never asked for consent when refused
      s.gate = false;
      await c.toggleScreenShare();
      await settle();
      expect(c.screenSharing, isTrue);
      expect(m.log, contains('screen:start'));
      final k = s.signals.map((e) => e.$1).toList();
      expect(k, containsAllInOrder(['screen_start', 'reneg_offer', 'media']));
      expect(s.signals.lastWhere((e) => e.$1 == 'media').$2['screen'], isTrue);
      await c.toggleScreenShare();
      expect(c.screenSharing, isFalse);
      expect(m.log, contains('screen:stop:camera=false'));
      expect(h.log, ['begin', 'end']);
      c.dispose();
    });

    test('the other person sharing shows up', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live1(m, s);
      s.remoteSignal('media', {'camera': false, 'mic': true, 'screen': true});
      await settle();
      expect(c.remoteScreen, isTrue);
      c.dispose();
    });
  });

  group('screens', () {
    setUp(() => GroupCallConfig.setForTest(true));
    tearDown(() {
      GroupCallConfig.reset();
      CircleCallScreen.debugPickPeople = null;
      CircleCallScreen.debugOpenGroup = null;
    });

    testWidgets('add person from a live 1:1: pick -> group room with handover',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.connected);
      c.recording = RecordingSession(send: (a) async => {}, engine: FakeRecorder());
      int? gotCall;
      List<int>? gotIds;
      CallController? gotHandover;
      CircleCallScreen.debugPickPeople = (_) async => [5, 6];
      CircleCallScreen.debugOpenGroup =
          ({callId, required memberIds, room, required handover}) {
        gotCall = callId;
        gotIds = memberIds;
        gotHandover = handover;
      };
      await tester.pumpWidget(app(CircleCallScreen(
          member: const {'id': 7, 'name': 'Nadia'},
          kind: 'voice',
          controller: c)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('call-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('call-add-people')), findsOneWidget);
      expect(find.byKey(const Key('call-record')), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-add-people')));
      await tester.pumpAndSettle();
      expect(gotCall, 42);
      expect(gotIds, [5, 6]);
      expect(identical(gotHandover, c), isTrue);
    });

    testWidgets('"More" and "Add people" are hidden when group calls are not installed',
        (tester) async {
      GroupCallConfig.reset(); // not available
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.connected);
      await tester.pumpWidget(app(CircleCallScreen(
          member: const {'id': 7, 'name': 'Nadia'},
          kind: 'voice',
          controller: c)));
      await tester.pump();
      expect(find.byKey(const Key('call-more')), findsNothing);
    });

    testWidgets('picker: choose people, max respected', (tester) async {
      List<int>? got;
      await tester.pumpWidget(app(Builder(
          builder: (ctx) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      got = await pickCirclePeople(ctx,
                          api: ApiClient(),
                          exclude: {7},
                          max: 1,
                          load: () async => [
                                {'id': 7, 'name': 'Nadia'},
                                {'id': 5, 'name': 'Rafi'},
                                {'id': 6, 'name': 'Mitu'},
                              ]);
                    },
                    child: const Text('open'),
                  ),
                ),
              ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Nadia'), findsNothing); // already in the call
      await tester.tap(find.byKey(const Key('pick-5')));
      await tester.pump();
      // max 1: Mitu can't be ticked now
      final mitu = tester.widget<CheckboxListTile>(find.byKey(const Key('pick-6')));
      expect(mitu.onChanged, isNull);
      await tester.tap(find.byKey(const Key('pick-add')));
      await tester.pumpAndSettle();
      expect(got, [5]);
    });

    testWidgets('group screen: grid, active speaker ring, host menu mute',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final a = FakeGroupApi();
      final c = previewGroup(api: a, people: 4, speaking: '2');
      await tester.pumpWidget(app(GroupCallScreen(controller: c)));
      await tester.pump();
      expect(find.byKey(const Key('group-grid')), findsOneWidget);
      for (final id in ['1', '2', '3', '4', '99']) {
        expect(find.byKey(Key('group-tile-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const Key('group-mic-off-3')), findsOneWidget);
      expect(find.byKey(const Key('group-ringing-99')), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-tile-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('host-mute')));
      await tester.pumpAndSettle();
      expect(a.log, contains('mute:2:audio:null'));
      // speaker view
      await tester.tap(find.byKey(const Key('group-layout')));
      await tester.pump();
      expect(find.byKey(const Key('group-speaker-view')), findsOneWidget);
    });

    testWidgets('group screen: member has no host menu; remove asks first',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final m = previewGroup(host: false);
      await tester.pumpWidget(app(GroupCallScreen(controller: m)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('group-tile-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('host-mute')), findsNothing);
      final a = FakeGroupApi();
      final h = previewGroup(api: a);
      await tester.pumpWidget(app(GroupCallScreen(key: UniqueKey(), controller: h)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('group-tile-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('host-remove')));
      await tester.pumpAndSettle();
      expect(a.log.where((l) => l.startsWith('remove')), isEmpty);
      await tester.tap(find.byKey(const Key('host-remove-confirm')));
      await tester.pumpAndSettle();
      expect(a.log, contains('remove:2'));
    });

    testWidgets('screen share banner + Stop', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final c = previewGroup(sharing: true);
      await tester.pumpWidget(app(GroupCallScreen(controller: c)));
      await tester.pump();
      expect(find.byKey(const Key('screen-share-banner')), findsOneWidget);
      expect(find.text('You are sharing your screen'), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen-share-stop')));
      await tester.pump();
      expect(c.screenSharing, isFalse);
      expect((c.media as FakeGroupRoom).log, contains('screen:false'));
    });

    testWidgets('consent prompt in the group screen sends accept',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final sent = <String>[];
      final s = RecordingSession(
          send: (a) async {
            sent.add(a);
            return {};
          },
          engine: null);
      final c = previewGroup(session: s, recording: {
        'id': 1, 'status': 'pending', 'requester': 2, 'accepted': [2],
        'i_must_answer': true, 'i_record': false
      });
      await tester.pumpWidget(app(GroupCallScreen(controller: c)));
      await tester.pump();
      expect(find.byKey(const Key('recording-consent')), findsOneWidget);
      expect(find.text('Nadia wants to record this call'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recording-allow')));
      await tester.pump();
      expect(sent, ['accept']);
    });

    testWidgets('ended: honest reason + rejoin while the room lives',
        (tester) async {
      final c = previewGroup();
      c.phase = GroupPhase.ended;
      c.endReason = GroupEndReason.unavailable;
      await tester.pumpWidget(app(GroupCallScreen(controller: c)));
      await tester.pump();
      expect(find.text('Group calls are not available right now. Please try again later.'),
          findsOneWidget);
      expect(find.byKey(const Key('group-rejoin')), findsOneWidget);
      c.endReason = GroupEndReason.removed;
      c.roomLive = true;
      await tester.pumpWidget(app(GroupCallScreen(key: UniqueKey(), controller: c)));
      await tester.pump();
      expect(find.byKey(const Key('group-rejoin')), findsNothing);
    });
  });
}
