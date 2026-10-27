// callsB: screen share state machine, group calls (roster -> pair links,
// tiles 1-4, mute / speaking, add person, join from chat, leave) and the
// 1:1 call unchanged when nobody is added.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart' show ApiClient, ApiException;
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/group/add_person_sheet.dart';
import 'package:assisto/calls/group/group_call.dart';
import 'package:assisto/calls/group/group_chat_call.dart';
import 'package:assisto/calls/group/group_stage.dart';
import 'package:assisto/calls/media_ext.dart';
import 'package:assisto/calls/screen_share.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';
import 'callsb_fakes.dart';

Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

CallController liveCall({
  required FakeCallMedia media,
  required FakeSignaling sig,
  bool video = true,
}) {
  final c = CallController(
    media: media,
    signaling: sig,
    sounds: FakeSounds(),
    video: video,
    outgoing: true,
    memberId: 1,
    callId: 42,
  );
  c.phase = CallPhase.connected;
  c.connectedAt = DateTime(2026, 10, 26);
  return c;
}

Widget wrap(Widget child, {String lang = 'en'}) => MaterialApp(
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

void main() {
  // ------------------------------------------------------- screen share
  group('screen share state machine', () {
    late FakeShareMedia media;
    late FakeSignaling sig;
    late FakeShareService svc;
    late CallController c;
    late ScreenShareController share;

    setUp(() {
      media = FakeShareMedia();
      sig = FakeSignaling();
      svc = FakeShareService();
      c = liveCall(media: media, sig: sig);
      share = ScreenShareController(
        media: media,
        service: svc,
        links: () => [c],
        texts: () => ('Sharing', 'Everyone sees it', 'Stop sharing'),
      );
    });

    test('"Not now" on our consent sheet starts nothing', () async {
      expect(share.supported, isTrue);
      share.request();
      expect(share.state, ScreenShareState.consent);
      share.cancel();
      expect(share.state, ScreenShareState.idle);
      expect(media.log, isNot(contains('share:consent')));
      expect(svc.log, isEmpty);
    });

    test('system consent denied: no foreground service, honest notice',
        () async {
      media.startError = const ScreenShareDenied();
      share.request();
      await share.confirm();
      expect(share.state, ScreenShareState.idle);
      expect(share.notice, ScreenShareNotice.denied);
      expect(media.beforeCaptureCalled, isFalse);
      expect(svc.log, isEmpty, reason: 'service only AFTER consent');
      expect(c.screenSharing, isFalse);
    });

    test('service refused -> failed, nothing captured', () async {
      svc.allow = false;
      share.request();
      await share.confirm();
      expect(share.state, ScreenShareState.idle);
      expect(share.notice, ScreenShareNotice.failed);
      expect(media.sharingNow, isFalse);
    });

    test('capture fails after the service started -> service stopped',
        () async {
      media.startError = const ScreenShareFailed('capture');
      share.request();
      await share.confirm();
      expect(share.notice, ScreenShareNotice.failed);
      expect(svc.log, ['start:Sharing', 'stop']);
    });

    test('sharing: indicator state + the other side is told (screen:true)',
        () async {
      share.request();
      await share.confirm();
      await settle();
      expect(share.state, ScreenShareState.sharing);
      expect(share.sharing, isTrue);
      expect(svc.log.first, 'start:Sharing');
      expect(c.screenSharing, isTrue);
      final media0 = sig.signals.where((s) => s.$1 == 'media').last.$2;
      expect(media0['screen'], isTrue);
      // one-tap Stop
      await share.stop();
      await settle();
      expect(share.state, ScreenShareState.idle);
      expect(media.sharingNow, isFalse);
      expect(svc.log.last, 'stop');
      expect(c.screenSharing, isFalse);
      final media1 = sig.signals.where((s) => s.$1 == 'media').last.$2;
      expect(media1.containsKey('screen'), isFalse);
    });

    test('a track added without a sender renegotiates', () async {
      media.needsReneg = true;
      share.request();
      await share.confirm();
      await settle();
      expect(sig.signals.map((s) => s.$1), contains('reneg_offer'));
    });

    test("the notification's Stop stops sharing", () async {
      share.request();
      await share.confirm();
      svc.tapNotificationStop();
      await settle();
      expect(share.state, ScreenShareState.idle);
      expect(media.log, contains('share:off'));
    });

    test('media without screen capture: no Share button', () {
      final s2 = ScreenShareController(
          media: FakeCallMedia(),
          service: svc,
          links: () => [c],
          texts: () => ('', '', ''));
      expect(s2.supported, isFalse);
      s2.request();
      expect(s2.state, ScreenShareState.idle);
    });
  });

  test('remote screen share is shown (media screen:true)', () async {
    final sig = FakeSignaling();
    final c = CallController(
        media: FakeCallMedia(),
        signaling: sig,
        sounds: FakeSounds(),
        video: true,
        outgoing: true,
        memberId: 1,
        setupRetryDelays: const []);
    await c.start();
    sig.remoteSignal('media', {'camera': true, 'mic': true, 'screen': true});
    await settle();
    expect(c.remoteScreen, isTrue);
    sig.remoteSignal('media', {'camera': true, 'mic': true});
    await settle();
    expect(c.remoteScreen, isFalse);
    await c.hangup();
  });

  // ------------------------------------------------------- pair links
  test('a preplaced pair link offers without placing a call', () async {
    final sig = FakeSignaling()..statusBody = {'phase': 'accepted'};
    final media = FakeCallMedia();
    final c = CallController(
        media: media,
        signaling: sig,
        sounds: const SilentCallSounds(),
        video: false,
        outgoing: true,
        preplaced: true,
        callId: 77,
        setupRetryDelays: const []);
    await c.start();
    expect(sig.eventLog.where((e) => e.startsWith('place')), isEmpty);
    expect(sig.signals.first.$1, 'offer');
    expect(c.phase, CallPhase.accepted);
    expect(media.log, containsAllInOrder(['open:audio', 'peer', 'offer']));
    await c.hangup();
  });

  test('1:1 unchanged: placing still places, no preplaced path', () async {
    final sig = FakeSignaling();
    final c = CallController(
        media: FakeCallMedia(),
        signaling: sig,
        sounds: FakeSounds(),
        video: false,
        outgoing: true,
        memberId: 5,
        setupRetryDelays: const []);
    await c.start();
    expect(sig.eventLog.first, 'place:5:voice');
    expect(c.preplaced, isFalse);
    expect(c.log, isNot(contains(startsWith('preplaced'))));
    expect(c.screenSharing, isFalse);
    await c.hangup();
  });

  // ------------------------------------------------------- group session
  group('group session', () {
    test('roster -> one controller per pair link, never for the 1:1 call',
        () async {
      final api = FakeGroupApi();
      final primary =
          liveCall(media: FakeShareMedia(), sig: FakeSignaling(), video: false);
      final made = <CallController>[];
      final s = fakeSession(api: api, primary: primary, made: made);
      expect(s.isGroupView, isFalse, reason: 'no room yet = plain 1:1');
      api.push(roster(members: [
        member(kMe),
        member(kKarim),
        member(kSalma),
      ], links: [
        link(42, kKarim, via: 'base', state: 'active'),
        link(90, kSalma, role: 'caller', via: 'ring'),
      ]));
      await settle();
      expect(s.isGroupView, isTrue);
      expect(s.roomId, 7);
      expect(made.length, 1);
      expect(made.single.callId, 90);
      expect(made.single.outgoing, isTrue);
      expect(made.single.preplaced, isTrue);
      // a link where I answer
      api.push(roster(members: [
        member(kMe),
        member(kKarim),
        member(kSalma),
        member(kNadia),
      ], links: [
        link(42, kKarim, via: 'base', state: 'active'),
        link(90, kSalma, via: 'ring'),
        link(91, kNadia, role: 'callee'),
      ]));
      await settle();
      expect(made.length, 2);
      expect(made.last.outgoing, isFalse);
      expect(made.last.preplaced, isFalse);
      expect(s.tiles.length, 4);
      expect(s.tiles.first.me, isTrue);
      s.dispose();
    });

    test('a roster for someone else\'s call is ignored', () async {
      final api = FakeGroupApi();
      final primary =
          liveCall(media: FakeShareMedia(), sig: FakeSignaling(), video: false);
      final s = fakeSession(api: api, primary: primary);
      api.push(roster(members: [member(kMe), member(kKarim)], links: [
        link(500, kKarim),
      ]));
      await settle();
      expect(s.roster, isNull);
      s.dispose();
    });

    test('two people = the 1:1 screen; 3+ = the grid; tiles max 4', () {
      final s2 = fakeSession(
          api: FakeGroupApi(),
          primary: liveCall(
              media: FakeShareMedia(), sig: FakeSignaling(), video: false),
          initial: roster(members: [member(kMe), member(kKarim)],
              links: [link(42, kKarim, via: 'base')]));
      expect(s2.isGroupView, isFalse);
      final s3 = previewSession(lang: 'en', people: 3);
      expect(s3.isGroupView, isTrue);
      expect(s3.tiles.length, 3);
      final s4 = previewSession(lang: 'en', people: 4);
      expect(s4.tiles.length, 4);
      expect(s4.seatsLeft, 0);
      for (final s in [s2, s3, s4]) {
        s.dispose();
      }
    });

    test('mute applies to every link and reaches the roster', () async {
      final api = FakeGroupApi();
      final primary =
          liveCall(media: FakeShareMedia(), sig: FakeSignaling(), video: false);
      final made = <CallController>[];
      final s = fakeSession(api: api, primary: primary, made: made, initial:
          roster(members: [member(kMe), member(kKarim), member(kSalma)],
              links: [link(42, kKarim, via: 'base'), link(90, kSalma)]));
      await settle();
      made.single.phase = CallPhase.connected;
      await s.toggleMute();
      expect(s.muted, isTrue);
      expect(primary.muted, isTrue);
      expect(made.single.muted, isTrue);
      expect(api.log, contains('media:{muted: true}'));
      expect(s.tiles.first.muted, isTrue);
      s.dispose();
    });

    test('mute state + who is speaking on the tiles', () {
      final s = previewSession(
          lang: 'en', people: 3, muted: {kSalma}, speaking: {kKarim});
      final byId = {for (final t in s.tiles) t.member.userId: t};
      expect(byId[kSalma]!.muted, isTrue);
      expect(byId[kKarim]!.speaking, isTrue);
      expect(byId[kSalma]!.speaking, isFalse);
      s.setSpeaking({kSalma});
      expect(s.isSpeaking(kSalma), isTrue);
      expect(s.isSpeaking(kKarim), isFalse);
      s.dispose();
    });

    test('a link that joins muted shares the muted mic', () async {
      final api = FakeGroupApi();
      final made = <CallController>[];
      final s = fakeSession(api: api, made: made, initial: roster(
          members: [member(kMe), member(kKarim)],
          links: [link(90, kKarim)]));
      await settle();
      await s.toggleMute();
      api.push(roster(members: [
        member(kMe),
        member(kKarim),
        member(kSalma)
      ], links: [
        link(90, kKarim),
        link(91, kSalma, role: 'callee')
      ]));
      await settle();
      expect(made.last.muted, isTrue);
      expect((made.last.media as FakeCallMedia).log, contains('muted:true'));
      s.dispose();
    });

    test('add person: ok attaches the roster; refusals are honest', () async {
      final api = FakeGroupApi();
      final primary =
          liveCall(media: FakeShareMedia(), sig: FakeSignaling(), video: false);
      final s = fakeSession(api: api, primary: primary, initial: roster(
          members: [member(kMe), member(kKarim)],
          links: [link(42, kKarim, via: 'base')]));
      api.next = roster(
          members: [member(kMe), member(kKarim), member(kSalma, state: 'ringing')],
          links: [link(42, kKarim, via: 'base'), link(90, kSalma)]);
      expect(await s.addPerson(103), AddPersonResult.ok);
      expect(api.log, contains('add:42:103'));
      expect(s.inCallMemberIds, {102, 103});
      api.addError = ApiException('full', 409, null, 'full');
      expect(await s.addPerson(104), AddPersonResult.full);
      api.addError = ApiException('x', 403, null, 'not_contact');
      expect(await s.addPerson(105), AddPersonResult.notContact);
      api.addError = ApiException('x', 429, null, 'rate_limited');
      expect(await s.addPerson(105), AddPersonResult.rateLimited);
      s.dispose();
    });

    test('join from chat: I offer to everyone; leave hangs everything up',
        () async {
      final api = FakeGroupApi()
        ..next = roster(members: [
          member(kMe),
          member(kKarim),
          member(kSalma)
        ], links: [
          link(90, kKarim),
          link(91, kSalma),
        ], groupName: 'Family');
      final made = <CallController>[];
      final s = fakeSession(api: api, made: made);
      expect(await s.join(7), isTrue);
      await settle();
      expect(api.log, contains('join:7'));
      expect(s.isGroupView, isTrue, reason: 'no 1:1 underneath');
      expect(made.map((c) => c.outgoing), [true, true]);
      await s.leave();
      await settle();
      expect(api.log, contains('leave:7'));
      expect(made.every((c) => c.isEnded), isTrue);
      expect(s.alive, isFalse);
      s.dispose();
    });

    test('the room ending ends the group', () async {
      final api = FakeGroupApi();
      final s = fakeSession(api: api, initial: roster(
          members: [member(kMe), member(kKarim), member(kSalma)]));
      expect(s.alive, isTrue);
      api.push(roster(
          members: [member(kMe, state: 'left'), member(kKarim, state: 'left')],
          state: 'ended', myState: 'left'));
      await settle();
      expect(s.alive, isFalse);
      s.dispose();
    });
  });

  // ------------------------------------------------------- widgets
  group('widgets', () {
    testWidgets('tiles 1-4 with mute + speaking indicators', (tester) async {
      for (final n in [1, 2, 3, 4]) {
        final s = previewSession(
            lang: 'en', people: n, muted: {kKarim}, speaking: {kMe});
        await tester.pumpWidget(wrap(Scaffold(
            body: GroupTilesGrid(tiles: s.tiles, video: false))));
        expect(find.byType(GroupTileView), findsNWidgets(n));
        expect(find.byKey(const Key('group-tile-speaking-1')), findsOneWidget);
        if (n >= 2) {
          expect(find.byKey(const Key('group-tile-muted-2')), findsOneWidget);
        }
        s.dispose();
      }
    });

    testWidgets('a tile reads as one sentence for TalkBack', (tester) async {
      final handle = tester.ensureSemantics();
      final s = previewSession(
          lang: 'en', people: 3, muted: {kKarim}, speaking: {kKarim});
      await tester.pumpWidget(
          wrap(Scaffold(body: GroupTilesGrid(tiles: s.tiles, video: false))));
      expect(find.bySemanticsLabel('Karim, muted, speaking'), findsOneWidget);
      handle.dispose();
      s.dispose();
    });

    testWidgets('group view: Add person + Leave + mute', (tester) async {
      final s = previewSession(lang: 'en', people: 3);
      var added = 0;
      var left = 0;
      await tester.pumpWidget(wrap(GroupCallView(
          session: s,
          onAddPerson: () => added++,
          onHangup: () async => left++)));
      expect(find.byKey(const Key('group-call')), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-add-person')));
      expect(added, 1);
      await tester.tap(find.byKey(const Key('group-hangup')));
      await tester.pump();
      expect(left, 1);
      s.dispose();
    });

    testWidgets('the sharing bar has a one-tap Stop', (tester) async {
      var stopped = 0;
      await tester.pumpWidget(wrap(Scaffold(
          body: ScreenShareBar(onStop: () => stopped++))));
      expect(find.text("You're sharing your screen"), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen-share-stop')));
      expect(stopped, 1);
      expect(tester.getSize(find.byKey(const Key('screen-share-stop'))).height,
          greaterThanOrEqualTo(48));
    });

    testWidgets('consent sheet: Not now / Continue', (tester) async {
      bool? got;
      await tester.pumpWidget(wrap(Builder(
          builder: (ctx) => Scaffold(
              body: TextButton(
                  onPressed: () async => got = await showScreenShareConsent(ctx),
                  child: const Text('go'))))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('screen-share-consent')), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen-share-consent-no')));
      await tester.pumpAndSettle();
      expect(got, isFalse);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('screen-share-consent-go')));
      await tester.pumpAndSettle();
      expect(got, isTrue);
    });

    testWidgets('add-person sheet: contacts not in the call, ring, full',
        (tester) async {
      final asked = <int>[];
      var result = AddPersonResult.ok;
      await tester.pumpWidget(wrap(Scaffold(
          body: AddPersonSheet(
        loadContacts: () async => [
          {'id': 102, 'name': 'Karim', 'state': 'accepted'},
          {'id': 103, 'name': 'Salma', 'state': 'accepted'},
          {'id': 104, 'name': 'Nadia', 'state': 'accepted'},
        ],
        onAdd: (id) async {
          asked.add(id);
          return result;
        },
        inCallMemberIds: const {102},
        seatsLeft: 2,
      ))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-person-102')), findsNothing);
      expect(find.byKey(const Key('add-person-103')), findsOneWidget);
      await tester.tap(find.byKey(const Key('add-person-btn-103')));
      await tester.pumpAndSettle();
      expect(asked, [103]);
      expect(find.text('Ringing Salma…'), findsOneWidget);
      result = AddPersonResult.full;
      await tester.tap(find.byKey(const Key('add-person-btn-104')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-person-message')), findsOneWidget);
      expect(find.textContaining('already has 4 people'), findsOneWidget);
    });

    testWidgets('group chat: Join call banner shows while a call runs',
        (tester) async {
      await tester.pumpWidget(wrap(Scaffold(
          body: GroupCallJoinBanner(
              api: ApiClient(),
              groupId: 3,
              initial: {
                'room': roster(
                    members: [member(kKarim), member(kSalma)],
                    myState: '')
              }))));
      expect(find.byKey(const Key('group-join-call')), findsOneWidget);
      await tester.pumpWidget(wrap(Scaffold(
          body: GroupCallJoinBanner(
              key: const ValueKey('b2'),
              api: ApiClient(),
              groupId: 3,
              initial: {
                'room': roster(
                    members: [member(kMe), member(kKarim)], myState: 'joined')
              }))));
      expect(find.byKey(const Key('group-join-call')), findsNothing);
      await tester.pumpWidget(wrap(Scaffold(
          body: GroupCallJoinBanner(
              key: const ValueKey('b3'),
              api: ApiClient(),
              groupId: 3,
              initial: const {'room': null}))));
      expect(find.byKey(const Key('group-join-banner')), findsNothing);
    });

    testWidgets('1:1 call screen unchanged without a group (no grid)',
        (tester) async {
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.connected);
      await tester.pumpWidget(wrap(CircleCallScreen(
          member: const {'id': 1, 'name': 'Karim'},
          kind: 'voice',
          controller: c)));
      await tester.pump();
      expect(find.byKey(const Key('group-call')), findsNothing);
      expect(find.byKey(const Key('call-mute')), findsOneWidget);
      expect(find.byKey(const Key('call-hangup')), findsOneWidget);
      expect(find.byKey(const Key('call-add-person')), findsOneWidget);
      expect(find.byKey(const Key('call-share-screen')), findsNothing,
          reason: 'voice call: no screen share');
    });

    testWidgets('1:1 video call: Share screen + the remote screen badge',
        (tester) async {
      final c = previewController(
          video: true, outgoing: true, phase: CallPhase.connected);
      c.remoteScreen = true;
      final share = ScreenShareController(
          media: FakeShareMedia(),
          service: FakeShareService(),
          links: () => [c],
          texts: () => ('', '', ''));
      await tester.pumpWidget(wrap(CircleCallScreen(
          member: const {'id': 1, 'name': 'Karim'},
          kind: 'video',
          controller: c,
          surface: FakeSurface(),
          previewShare: share)));
      await tester.pump();
      expect(find.byKey(const Key('call-share-screen')), findsOneWidget);
      expect(find.byKey(const Key('call-remote-screen')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      share.dispose();
    });

    testWidgets('a 3-person call shows the grid in the call screen',
        (tester) async {
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.connected);
      final g = previewSession(lang: 'en', people: 3);
      await tester.pumpWidget(wrap(CircleCallScreen(
          member: const {'id': 1, 'name': 'Karim'},
          kind: 'voice',
          controller: c,
          previewGroup: g)));
      await tester.pump();
      expect(find.byKey(const Key('group-call')), findsOneWidget);
      expect(find.byType(GroupTileView), findsNWidgets(3));
      await tester.pumpWidget(const SizedBox());
      g.dispose();
    });
  });

  test('add result mapping', () {
    expect(addResultFrom(ApiException('', 402)), AddPersonResult.upgrade);
    expect(addResultFrom(ApiException('', 409, null, 'already_in')),
        AddPersonResult.alreadyIn);
    expect(addResultFrom(StateError('x')), AddPersonResult.failed);
    expect(kGroupMax, 4);
  });

  test('MeshHost / ScreenShareMedia are optional (1:1 fakes stay valid)', () {
    final m = FakeCallMedia();
    expect(m is ScreenShareMedia, isFalse);
    expect(m is MeshHost, isFalse);
    unawaited(m.dispose());
  });
}
