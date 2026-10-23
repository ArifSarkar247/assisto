// b1-calls: voice <-> video switch (request / accept / decline / timeout /
// plan gate / camera failure / renegotiation), mic + camera state badges,
// audio routes, reconnect state machine (restart retries, callee restart
// request, honest give-up), quality mapping, the camera-refused video call
// (reality run 39946885424), the call screen's new controls at 360 px in
// bn/en, and the in-app minimized-call bar.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_mini_bar.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 40);

/// Fake signalling that can refuse a video request (server plan gate).
class GateSignaling extends FakeSignaling {
  bool gate = false;
  @override
  Future<void> signal(int callId, String kind, Map<String, dynamic> data) {
    if (gate && kind == 'video_request') {
      throw const CallUpgradeRequired();
    }
    return super.signal(callId, kind, data);
  }
}

CallController mk(FakeCallMedia m, FakeSignaling s,
        {bool video = false,
        bool outgoing = true,
        Duration upgrade = const Duration(milliseconds: 200),
        Duration reneg = const Duration(milliseconds: 200),
        Duration giveUp = const Duration(milliseconds: 500),
        Duration restartEvery = const Duration(milliseconds: 100)}) =>
    CallController(
      media: m,
      signaling: s,
      sounds: FakeSounds(),
      video: video,
      outgoing: outgoing,
      memberId: 7,
      callId: outgoing ? null : 42,
      reconnectGrace: const Duration(milliseconds: 20),
      reconnectGiveUp: giveUp,
      statusEvery: const Duration(seconds: 30),
      statsEvery: const Duration(seconds: 30),
      upgradeTimeout: upgrade,
      renegTimeout: reneg,
      restartEvery: restartEvery,
    );

Future<CallController> live(FakeCallMedia m, FakeSignaling s,
    {bool video = false, bool outgoing = true, Duration? reneg}) async {
  final c = mk(m, s,
      video: video,
      outgoing: outgoing,
      reneg: reneg ?? const Duration(milliseconds: 200));
  await c.start();
  m.link.add(MediaLinkState.connected);
  await settle();
  expect(c.phase, CallPhase.connected);
  return c;
}

List<String> kinds(FakeSignaling s) => s.signals.map((e) => e.$1).toList();

void main() {
  group('voice -> video (caller asks)', () {
    test('request -> they accept -> camera + renegotiation, audio never dropped',
        () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s);
      expect(c.videoOn, isFalse);
      await c.requestVideo();
      expect(c.upgrade, VideoUpgrade.requesting);
      expect(kinds(s), contains('video_request'));
      s.remoteSignal('video_accept', {});
      await settle();
      expect(m.log, contains('start-video'));
      expect(c.videoOn, isTrue);
      expect(c.cameraOn, isTrue);
      expect(c.speakerOn, isTrue, reason: 'video plays on the speaker');
      expect(kinds(s), contains('reneg_offer'));
      expect(c.upgrade, VideoUpgrade.switching);
      s.remoteSignal('reneg_answer', {'type': 'answer', 'sdp': 'v=0 RV'});
      await settle();
      expect(m.log, contains('set-answer:v=0 RV'));
      expect(c.upgrade, VideoUpgrade.none);
      expect(c.phase, CallPhase.connected);
      expect(m.disposed, isFalse);
      final media = s.signals.lastWhere((e) => e.$1 == 'media').$2;
      expect(media['video'], isTrue);
      // the reneg timer was cancelled: no fallback later
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.videoOn, isTrue);
      c.dispose();
    });

    test('they say "Not now" -> honest notice, still voice', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s);
      await c.requestVideo();
      s.remoteSignal('video_decline', {'reason': 'declined'});
      await settle();
      expect(c.upgrade, VideoUpgrade.none);
      expect(c.notice, CallNotice.videoDeclined);
      expect(c.videoOn, isFalse);
      expect(m.log, isNot(contains('start-video')));
      c.dispose();
    });

    test('no reply -> timeout cancels the request + "no answer"', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s);
      await c.requestVideo();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await settle();
      expect(c.upgrade, VideoUpgrade.none);
      expect(c.notice, CallNotice.videoNoAnswer);
      expect(kinds(s), contains('video_cancel'));
      c.dispose();
    });

    test('server plan gate -> Premium notice, request never pending',
        () async {
      final m = FakeCallMedia(), s = GateSignaling()..gate = true;
      final c = await live(m, s);
      await c.requestVideo();
      expect(c.upgrade, VideoUpgrade.none);
      expect(c.notice, CallNotice.videoPremium);
      expect(c.isLive, isTrue);
      c.dispose();
    });

    test('renegotiation never answered -> back to voice for both', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, reneg: const Duration(milliseconds: 100));
      await c.requestVideo();
      s.remoteSignal('video_accept', {});
      await settle();
      expect(c.videoOn, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await settle();
      expect(c.videoOn, isFalse);
      expect(c.notice, CallNotice.videoFailed);
      expect(m.log, contains('stop-video'));
      expect(kinds(s), contains('video_off'));
      expect(c.isLive, isTrue);
      c.dispose();
    });

    test('both ask at the same moment -> treated as yes from both', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s);
      await c.requestVideo();
      s.remoteSignal('video_request', {});
      await settle();
      expect(c.videoOn, isTrue);
      expect(kinds(s), containsAllInOrder(['video_accept', 'reneg_offer']));
      c.dispose();
    });
  });

  group('voice -> video (the other person asks)', () {
    test('callee: prompt -> Accept -> camera, video_accept, answers reneg',
        () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, outgoing: false);
      s.remoteSignal('video_request', {}, from: 'caller');
      await settle();
      expect(c.upgrade, VideoUpgrade.incoming);
      await c.acceptVideo();
      expect(m.log, contains('start-video'));
      expect(kinds(s), contains('video_accept'));
      expect(kinds(s), isNot(contains('reneg_offer')),
          reason: 'only the caller offers');
      s.remoteSignal('reneg_offer', {'type': 'offer', 'sdp': 'v=0 RO'},
          from: 'caller');
      await settle();
      expect(m.log, contains('accept-offer:v=0 RO'));
      expect(kinds(s), contains('reneg_answer'));
      expect(c.upgrade, VideoUpgrade.none);
      expect(c.videoOn, isTrue);
      c.dispose();
    });

    test('caller accepts the callee\'s request and renegotiates', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s);
      s.remoteSignal('video_request', {});
      await settle();
      expect(c.upgrade, VideoUpgrade.incoming);
      await c.acceptVideo();
      expect(kinds(s), containsAllInOrder(['video_accept', 'reneg_offer']));
      c.dispose();
    });

    test('Not now -> video_decline; unanswered prompt auto-declines',
        () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, outgoing: false);
      s.remoteSignal('video_request', {}, from: 'caller');
      await settle();
      await c.declineVideo();
      expect(s.signals.last.$1, 'video_decline');
      expect(s.signals.last.$2, {'reason': 'declined'});
      s.remoteSignal('video_request', {}, from: 'caller');
      await settle();
      expect(c.upgrade, VideoUpgrade.incoming);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await settle();
      expect(c.upgrade, VideoUpgrade.none);
      expect(s.signals.last.$2, {'reason': 'timeout'});
      c.dispose();
    });

    test('requester cancels -> my prompt goes away', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, outgoing: false);
      s.remoteSignal('video_request', {}, from: 'caller');
      await settle();
      s.remoteSignal('video_cancel', {}, from: 'caller');
      await settle();
      expect(c.upgrade, VideoUpgrade.none);
      c.dispose();
    });

    test('my camera refuses on Accept -> honest decline "camera"', () async {
      final m = FakeCallMedia()
            ..cameraError = MediaOpenException(true, 'camera denied'),
          s = FakeSignaling();
      final c = await live(m, s, outgoing: false);
      s.remoteSignal('video_request', {}, from: 'caller');
      await settle();
      await c.acceptVideo();
      expect(c.videoOn, isFalse);
      expect(c.notice, CallNotice.cameraBlocked);
      expect(s.signals.last.$1, 'video_decline');
      expect(s.signals.last.$2, {'reason': 'camera'});
      c.dispose();
    });
  });

  group('video -> voice', () {
    test('either side, instantly, for both', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, video: true);
      await c.switchToVoice();
      expect(c.videoOn, isFalse);
      expect(m.log, contains('stop-video'));
      expect(kinds(s), contains('video_off'));
      c.dispose();

      final m2 = FakeCallMedia(), s2 = FakeSignaling();
      final c2 = await live(m2, s2, video: true, outgoing: false);
      s2.remoteSignal('video_off', {}, from: 'caller');
      await settle();
      expect(c2.videoOn, isFalse);
      expect(c2.notice, CallNotice.remoteSwitchedToVoice);
      expect(m2.log, contains('stop-video'));
      // and back to video later works again (same flow)
      await c2.requestVideo();
      expect(c2.upgrade, VideoUpgrade.requesting);
      c2.dispose();
    });
  });

  group('mic / camera state', () {
    test('my mute + camera go to the other side; theirs become badges',
        () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, video: true);
      await c.toggleMute();
      await settle();
      expect(s.signals.last.$1, 'media');
      expect(s.signals.last.$2,
          {'camera': true, 'mic': false, 'video': true});
      await c.toggleCamera();
      expect(s.signals.last.$2,
          {'camera': false, 'mic': false, 'video': true});
      s.remoteSignal('media', {'camera': false, 'mic': false, 'video': true});
      await settle();
      expect(c.remoteMicOn, isFalse);
      expect(c.remoteCameraOn, isFalse);
      // an old build sends only {camera}: mic stays "on"
      s.remoteSignal('media', {'camera': true});
      await settle();
      expect(c.remoteMicOn, isTrue);
      expect(c.remoteCameraOn, isTrue);
      c.dispose();
    });

    test('local state survives a reconnect and is re-sent', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s);
      await c.toggleMute();
      await settle();
      s.signals.clear();
      m.link.add(MediaLinkState.failed);
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      expect(c.muted, isTrue);
      expect(c.notice, CallNotice.reconnected);
      expect(s.signals.where((e) => e.$1 == 'media').last.$2['mic'], isFalse);
      c.dispose();
    });
  });

  group('camera refused at start (reality run 39946885424)', () {
    test('video call goes on with the camera OFF instead of failing',
        () async {
      final m = FakeCallMedia()..cameraFailsAtOpen = true, s = FakeSignaling();
      final c = mk(m, s, video: true, outgoing: false);
      s.backlogItems.add({
        'seq': 5,
        'topic': 'call.signal',
        'payload': {
          'call_id': 42,
          'kind': 'offer',
          'data': {'type': 'offer', 'sdp': 'v=0 V'}
        }
      });
      await c.start();
      await settle();
      expect(c.isEnded, isFalse, reason: 'no `fail` any more');
      expect(s.eventLog, isNot(contains('fail')));
      expect(c.cameraOn, isFalse);
      expect(c.notice, CallNotice.cameraBlocked);
      expect(kinds(s), contains('answer'));
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      expect(s.eventLog, contains('connected:relayed=false'));
      // the other side is told the camera is off
      expect(s.signals.where((e) => e.$1 == 'media').last.$2['camera'],
          isFalse);
      // turning the camera on later opens it and asks the caller to re-offer
      await c.toggleCamera();
      expect(m.log, contains('start-video'));
      expect(c.cameraOn, isTrue);
      expect(kinds(s), contains('reneg_request'));
      c.dispose();
    });

    test('caller answers a reneg_request with a fresh offer', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, video: true);
      s.signals.clear();
      s.remoteSignal('reneg_request', {});
      await settle();
      expect(kinds(s), contains('reneg_offer'));
      c.dispose();
    });
  });

  group('reconnect state machine', () {
    test('caller repeats the ICE restart while reconnecting', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s);
      s.signals.clear();
      m.link.add(MediaLinkState.failed);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await settle();
      expect(kinds(s).where((k) => k == 'restart_offer').length,
          greaterThanOrEqualTo(2));
      m.link.add(MediaLinkState.connected);
      await settle();
      final n = kinds(s).where((k) => k == 'restart_offer').length;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(kinds(s).where((k) => k == 'restart_offer').length, n,
          reason: 'retries stop once media is back');
      c.dispose();
    });

    test('callee asks the caller to restart; caller does', () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, outgoing: false);
      m.link.add(MediaLinkState.failed);
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      expect(kinds(s), contains('restart_request'));
      expect(m.log, isNot(contains('offer:restart')),
          reason: 'the callee never offers');
      c.dispose();

      final m2 = FakeCallMedia(), s2 = FakeSignaling();
      final c2 = await live(m2, s2);
      s2.remoteSignal('restart_request', {});
      await settle();
      expect(kinds(s2), contains('restart_offer'));
      c2.dispose();
    });

    test('gives up after the timeout with an honest "connection lost"',
        () async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await live(m, s, outgoing: false);
      m.link.add(MediaLinkState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await settle();
      expect(c.isEnded, isTrue);
      expect(c.endReason, CallEndReason.lost);
      expect(s.eventLog, contains('fail'));
      c.dispose();
    });
  });

  group('audio route + quality', () {
    test('route picker reaches the media layer', () async {
      final m = FakeCallMedia()
            ..routeList = const [
              AudioRoute.earpiece,
              AudioRoute.speaker,
              AudioRoute.bluetooth
            ],
          s = FakeSignaling();
      final c = await live(m, s);
      expect(await c.refreshRoutes(), contains(AudioRoute.bluetooth));
      await c.setRoute(AudioRoute.bluetooth);
      expect(m.log, contains('route:bluetooth'));
      expect(c.route, AudioRoute.bluetooth);
      expect(c.speakerOn, isFalse);
      await c.setRoute(AudioRoute.speaker);
      expect(c.speakerOn, isTrue);
      c.dispose();
    });

    test('ids map both ways', () {
      for (final r in AudioRoute.values) {
        expect(audioRouteFromId(audioRouteId(r)), r);
      }
      expect(audioRouteFromId('usb'), isNull);
    });

    test('Good / Fair / Poor from RTT, loss, jitter and bitrate', () {
      expect(const MediaStats().quality, CallQuality.unknown);
      expect(const MediaStats(rttMs: 80, lossPct: 0.5, jitterMs: 10).quality,
          CallQuality.good);
      expect(const MediaStats(rttMs: 350).quality, CallQuality.fair);
      expect(const MediaStats(lossPct: 3).quality, CallQuality.fair);
      expect(const MediaStats(jitterMs: 60).quality, CallQuality.fair);
      expect(const MediaStats(jitterMs: 150).quality, CallQuality.poor);
      expect(const MediaStats(rttMs: 700).quality, CallQuality.poor);
      expect(const MediaStats(lossPct: 9).quality, CallQuality.poor);
      expect(const MediaStats(availableKbps: 300).quality, CallQuality.good);
      expect(const MediaStats(availableKbps: 300).qualityFor(video: true),
          CallQuality.fair);
      expect(const MediaStats(availableKbps: 100).qualityFor(video: true),
          CallQuality.poor);
      expect(const MediaStats(availableKbps: 20).quality, CallQuality.poor);
    });
  });

  group('call screen (b1 controls)', () {
    Future<void> pump(WidgetTester tester, CallController c,
        {String lang = 'en',
        bool video = false,
        bool resumed = false,
        Size size = const Size(360, 800)}) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: CircleCallScreen(
          key: ObjectKey(c),
          member: const {'id': 7, 'name': 'Nadia'},
          kind: video ? 'video' : 'voice',
          controller: c,
          resumed: resumed,
          surface: video || c.videoOn ? FakeSurface() : null,
        ),
      ));
      await tester.pump();
    }

    for (final lang in ['en', 'bn']) {
      testWidgets('voice: Video button + incoming prompt fit at 360 ($lang)',
          (tester) async {
        final t = lookupAppLocalizations(Locale(lang));
        final c = previewController(
            video: false,
            outgoing: true,
            phase: CallPhase.connected,
            upgrade: VideoUpgrade.incoming,
            remoteMic: false);
        await pump(tester, c, lang: lang);
        expect(find.byKey(const Key('call-to-video')), findsOneWidget);
        expect(find.byKey(const Key('call-video-prompt')), findsOneWidget);
        expect(find.text(t.b1CallVideoAsk('Nadia')), findsOneWidget);
        expect(find.byKey(const Key('call-remote-muted')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('Accept / Not now really reach the call', (tester) async {
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await tester.runAsync(() => live(m, s, outgoing: false));
      s.remoteSignal('video_request', {}, from: 'caller');
      await tester.runAsync(settle);
      await pump(tester, c!);
      expect(find.byKey(const Key('call-video-prompt')), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-video-accept')));
      await tester.runAsync(settle);
      await tester.pump();
      expect(kinds(s), contains('video_accept'));
      expect(c.videoOn, isTrue);
      expect(find.byKey(const Key('call-to-voice')), findsOneWidget);
      expect(find.byKey(const Key('call-camera')), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-to-voice')));
      await tester.runAsync(settle);
      await tester.pump();
      expect(c.videoOn, isFalse);
      expect(find.byKey(const Key('call-to-video')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('no video / minimize buttons before the call connects',
        (tester) async {
      final c = previewController(
          video: false, outgoing: true, phase: CallPhase.ringing);
      await pump(tester, c);
      expect(find.byKey(const Key('call-to-video')), findsNothing);
      expect(find.byKey(const Key('call-minimize')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('video: camera-off placeholder + badges, 5 controls fit (bn)',
        (tester) async {
      final c = previewController(
          video: true,
          outgoing: true,
          phase: CallPhase.connected,
          remoteCamera: false,
          remoteMic: false,
          cameraOn: false);
      await pump(tester, c, lang: 'bn', video: true);
      expect(find.byKey(const Key('call-remote-camera-off')), findsOneWidget);
      expect(find.byKey(const Key('call-remote-muted')), findsOneWidget);
      expect(find.byKey(const Key('call-self-camera-off')), findsOneWidget);
      for (final k in [
        'call-speaker',
        'call-camera',
        'call-flip',
        'call-to-voice',
        'call-mute'
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('poor network shows a short text; notice banner shows',
        (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      final c = previewController(
          video: false,
          outgoing: true,
          phase: CallPhase.connected,
          quality: CallQuality.poor,
          notice: CallNotice.videoDeclined);
      await pump(tester, c);
      expect(find.byKey(const Key('call-quality-poor')), findsOneWidget);
      expect(find.text(t.c2CallQualityPoor), findsWidgets);
      expect(find.byKey(const Key('call-notice')), findsOneWidget);
      expect(find.text(t.b1CallNoticeDeclined('Nadia')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const Key('call-notice')), findsNothing,
          reason: 'notices go away by themselves');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('route picker appears only with a headset', (tester) async {
      final m = FakeCallMedia()
            ..routeList = const [
              AudioRoute.earpiece,
              AudioRoute.speaker,
              AudioRoute.wired
            ],
          s = FakeSignaling();
      final c = await tester.runAsync(() => live(m, s));
      await pump(tester, c!);
      await tester.tap(find.byKey(const Key('call-speaker')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('call-route-wired')), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-route-wired')));
      await tester.pumpAndSettle();
      expect(c.route, AudioRoute.wired);
      expect(m.log, contains('route:wired'));
      // without a headset the button is the plain speaker toggle
      m.routeList = const [AudioRoute.earpiece, AudioRoute.speaker];
      await tester.tap(find.byKey(const Key('call-speaker')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('call-route-speaker')), findsNothing);
      expect(c.speakerOn, isTrue);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('Minimize hands the LIVE call to the mini bar (no hang-up)',
        (tester) async {
      CallRuntime.instance.resetForTest();
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await tester.runAsync(() => live(m, s));
      final nav = GlobalKey<NavigatorState>();
      tester.view.physicalSize = const Size(360, 800) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            CallMiniBarHost(child: child ?? const SizedBox()),
        home: const Scaffold(body: Text('home')),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => CircleCallScreen(
              member: const {'id': 7, 'name': 'Nadia'},
              kind: 'voice',
              controller: c,
              resumed: true)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('call-minimize')), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-minimize')));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(c!.isEnded, isFalse, reason: 'minimizing never hangs up');
      expect(CallRuntime.instance.ongoing.value?.controller, same(c));
      expect(find.byKey(const Key('call-mini-bar')), findsOneWidget);
      // the bar re-opens the same call
      CallScreenReopen.open(nav.currentState!);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('call-hangup')), findsOneWidget);
      expect(CallRuntime.instance.ongoing.value, isNull);
      // red button ends it
      await tester.tap(find.byKey(const Key('call-hangup')));
      await tester.runAsync(settle);
      await tester.pumpAndSettle();
      expect(c.isEnded, isTrue);
      await tester.pumpWidget(const SizedBox());
      CallRuntime.instance.resetForTest();
    });

    testWidgets('mini bar hang-up ends a minimized call', (tester) async {
      CallRuntime.instance.resetForTest();
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = await tester.runAsync(() => live(m, s));
      CallRuntime.instance.minimize(OngoingCall(
          controller: c!, member: const {'name': 'Nadia'}, kind: 'voice'));
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('bn'),
        builder: (context, child) =>
            CallMiniBarHost(child: child ?? const SizedBox()),
        home: const Scaffold(body: Text('home')),
      ));
      expect(find.byKey(const Key('call-mini-bar')), findsOneWidget);
      expect(find.textContaining('Nadia'), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-mini-hangup')));
      await tester.runAsync(settle);
      await tester.pump();
      expect(c.isEnded, isTrue);
      expect(s.eventLog, contains('hangup'));
      expect(find.byKey(const Key('call-mini-bar')), findsNothing);
      await tester.pump(const Duration(seconds: 3)); // controller freed
      await tester.pumpWidget(const SizedBox());
      CallRuntime.instance.resetForTest();
    });
  });
}

/// Test seam: what the mini bar's tap does, without a global navigator.
class CallScreenReopen {
  static void open(NavigatorState nav) {
    final o = CallRuntime.instance.ongoing.value;
    if (o == null) return;
    CircleCallScreen.registerReopen();
    CallRuntime.instance.reopenCall!(nav, o);
  }
}
