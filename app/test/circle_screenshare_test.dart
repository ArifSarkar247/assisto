// circle-screenshare: screen sharing in a My Circle video call — the state
// machine (our sheet -> Android's consent -> the mediaProjection service ->
// the screen on the video sender), every stop path (our red bar, the
// notification, Android ending it, the call ending, back to voice), the
// camera coming back, renegotiation when the phone had no video sender
// (gatefix: a caller without a camera), the receiver's uncropped view, the
// data caps, the honest "not in this version" line, the call screen in
// bn/en at 360 px and 200 % text, and source guards for the Android 14 order.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_video.dart';
import 'package:assisto/calls/media_ext.dart';
import 'package:assisto/calls/screen_share.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 40);

/// A call media that can share the screen (records the Android order).
class ShareMedia extends FakeCallMedia implements ScreenShareMedia {
  bool deny = false;
  bool failCapture = false;

  /// true = no video sender yet (the camera never opened): the screen is
  /// ADDED and the call must renegotiate.
  bool noSender = false;
  @override
  bool screenSharing = false;

  @override
  Future<bool> startScreenShare(
      {required Future<bool> Function() beforeCapture}) async {
    log.add('ss:consent');
    if (deny) throw const ScreenShareDenied();
    if (!await beforeCapture()) throw const ScreenShareFailed('service');
    log.add('ss:capture');
    if (failCapture) throw const ScreenShareFailed('capture');
    screenSharing = true;
    log.add(noSender ? 'ss:add-track' : 'ss:replace-track');
    return noSender;
  }

  @override
  Future<void> stopScreenShare() async {
    screenSharing = false;
    log.add('ss:stop');
  }
}

class FakeShareService implements ScreenShareService {
  bool startOk = true;
  bool isAvailable = true;
  final log = <String>[];
  final stops = StreamController<String>.broadcast();

  @override
  Future<bool> start(
      {required String title, required String body, required String stop}) async {
    log.add('start:$title|$stop');
    return startOk;
  }

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<bool> available() async => isAvailable;

  @override
  Stream<String> get stopRequests => stops.stream;
}

class ShareSurface extends FakeSurface implements ScreenShareSurface {
  @override
  Widget remoteScreenView() =>
      const ColoredBox(key: Key('test-remote-screen'), color: Colors.blueGrey);
}

CallController mk(FakeCallMedia m, FakeSignaling s,
        {bool video = true, bool outgoing = true}) =>
    CallController(
      media: m,
      signaling: s,
      sounds: FakeSounds(),
      video: video,
      outgoing: outgoing,
      memberId: 7,
      callId: outgoing ? null : 42,
      reconnectGrace: const Duration(milliseconds: 20),
      statusEvery: const Duration(seconds: 30),
      statsEvery: const Duration(seconds: 30),
      renegTimeout: const Duration(milliseconds: 300),
    );

Future<CallController> live(FakeCallMedia m, FakeSignaling s,
    {bool video = true, bool outgoing = true}) async {
  final c = mk(m, s, video: video, outgoing: outgoing);
  await c.start();
  m.link.add(MediaLinkState.connected);
  await settle();
  expect(c.phase, CallPhase.connected);
  return c;
}

Map<String, dynamic> lastMedia(FakeSignaling s) =>
    s.signals.lastWhere((e) => e.$1 == 'media').$2;

Future<(ScreenShareController, FakeShareService)> sharing(
    CallController c) async {
  final svc = FakeShareService();
  ScreenShareController.serviceOverride = svc;
  final ss = ScreenShareController.of(c)!;
  await ss.request();
  expect(ss.state, ScreenShareState.consent);
  await ss.confirm();
  await settle();
  return (ss, svc);
}

void main() {
  tearDown(() => ScreenShareController.serviceOverride = null);

  group('start', () {
    test(
        'our sheet -> Android consent -> service AFTER consent -> capture -> '
        'replaceTrack; the other phone is told', () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      final (ss, svc) = await sharing(c);
      expect(ss.state, ScreenShareState.sharing);
      final i = m.log.indexOf('ss:consent');
      expect(i, greaterThanOrEqualTo(0));
      expect(svc.log.first, startsWith('start:'),
          reason: 'the service starts inside beforeCapture');
      expect(m.log.indexOf('ss:capture'), greaterThan(i));
      expect(m.log, contains('ss:replace-track'));
      expect(c.screenSharing, isTrue);
      expect(lastMedia(s)['screen'], isTrue);
      expect(lastMedia(s)['camera'], isTrue,
          reason: 'old builds show the video, not the avatar');
      expect(s.signals.map((e) => e.$1), isNot(contains('reneg_offer')),
          reason: 'a video sender existed: no renegotiation');
      c.dispose();
    });

    test(
        'gatefix case: no video sender (camera never opened) -> the screen is '
        'ADDED and the caller re-offers', () async {
      final m = ShareMedia()
        ..cameraFailsAtOpen = true
        ..noSender = true;
      final s = FakeSignaling();
      final c = await live(m, s);
      expect(m.cameraUnavailable, isTrue);
      final offersBefore = m.log.where((l) => l == 'offer').length;
      await sharing(c);
      expect(m.log, contains('ss:add-track'));
      expect(m.log.where((l) => l == 'offer').length, offersBefore + 1);
      expect(s.signals.map((e) => e.$1), contains('reneg_offer'));
      s.remoteSignal('reneg_answer', {'type': 'answer', 'sdp': 'v=0 SS'});
      await settle();
      expect(m.log, contains('set-answer:v=0 SS'));
      expect(c.phase, CallPhase.connected);
      c.dispose();
    });

    test('the CALLEE without a sender asks the caller to re-offer', () async {
      final m = ShareMedia()..noSender = true;
      final s = FakeSignaling();
      final c = mk(m, s, outgoing: false);
      c.phase = CallPhase.connected;
      c.callId = 42;
      final svc = FakeShareService();
      ScreenShareController.serviceOverride = svc;
      final ss = ScreenShareController.of(c)!;
      await ss.request();
      await ss.confirm();
      await settle();
      expect(s.signals.map((e) => e.$1), contains('reneg_request'));
      expect(s.signals.map((e) => e.$1), isNot(contains('reneg_offer')));
      c.dispose();
    });

    test('Android dialog refused -> no service, honest notice, call goes on',
        () async {
      final m = ShareMedia()..deny = true;
      final s = FakeSignaling();
      final c = await live(m, s);
      final svc = FakeShareService();
      ScreenShareController.serviceOverride = svc;
      final ss = ScreenShareController.of(c)!;
      await ss.request();
      await ss.confirm();
      expect(ss.state, ScreenShareState.idle);
      expect(ss.notice, ScreenShareNotice.denied);
      expect(svc.log, isEmpty, reason: 'never a service without consent');
      expect(c.screenSharing, isFalse);
      expect(c.phase, CallPhase.connected);
      c.dispose();
    });

    test('capture fails AFTER the service started -> service stopped, notice',
        () async {
      final m = ShareMedia()..failCapture = true;
      final s = FakeSignaling();
      final c = await live(m, s);
      final svc = FakeShareService();
      ScreenShareController.serviceOverride = svc;
      final ss = ScreenShareController.of(c)!;
      await ss.request();
      await ss.confirm();
      expect(ss.notice, ScreenShareNotice.failed);
      expect(svc.log.last, 'stop', reason: 'never a service left running');
      expect(ss.state, ScreenShareState.idle);
      c.dispose();
    });

    test('service refused (no consent on Android 14) -> failed, no capture',
        () async {
      final m = ShareMedia();
      final s = FakeSignaling();
      final c = await live(m, s);
      final svc = FakeShareService()..startOk = false;
      ScreenShareController.serviceOverride = svc;
      final ss = ScreenShareController.of(c)!;
      await ss.request();
      await ss.confirm();
      expect(m.log, isNot(contains('ss:capture')));
      expect(ss.notice, ScreenShareNotice.failed);
      c.dispose();
    });

    test('"Not now" on our sheet -> nothing asked from Android', () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      ScreenShareController.serviceOverride = FakeShareService();
      final ss = ScreenShareController.of(c)!;
      await ss.request();
      ss.cancel();
      expect(ss.state, ScreenShareState.idle);
      expect(m.log, isNot(contains('ss:consent')));
      c.dispose();
    });

    test('a build without the service: honest line, never the consent sheet',
        () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      ScreenShareController.serviceOverride = FakeShareService()
        ..isAvailable = false;
      final ss = ScreenShareController.of(c)!;
      await ss.request();
      expect(ss.state, ScreenShareState.idle);
      expect(ss.notice, ScreenShareNotice.notInThisVersion);
      c.dispose();
    });

    test('only in a live VIDEO call; media without sharing -> no controller',
        () async {
      final s = FakeSignaling();
      final voice = await live(ShareMedia(), s, video: false);
      ScreenShareController.serviceOverride = FakeShareService();
      final ss = ScreenShareController.of(voice)!;
      expect(ss.available, isFalse);
      await ss.request();
      expect(ss.state, ScreenShareState.idle);
      voice.dispose();
      final plain = await live(FakeCallMedia(), FakeSignaling());
      expect(ScreenShareController.of(plain), isNull);
      plain.dispose();
    });

    test('one controller per call (survives the screen: minimize / PiP)',
        () async {
      final c = await live(ShareMedia(), FakeSignaling());
      ScreenShareController.serviceOverride = FakeShareService();
      expect(ScreenShareController.of(c), same(ScreenShareController.of(c)));
      c.dispose();
    });
  });

  group('stop', () {
    test('our red bar: screen off, service off, FRESH camera back, told',
        () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      final (ss, svc) = await sharing(c);
      m.log.clear();
      await ss.stop();
      await settle();
      expect(m.log.first, 'ss:stop');
      expect(m.log, contains('start-video'),
          reason: 'the camera Android may have taken in the background');
      expect(svc.log.last, 'stop');
      expect(c.screenSharing, isFalse);
      expect(lastMedia(s).containsKey('screen'), isFalse);
      expect(lastMedia(s)['camera'], isTrue);
      expect(ss.notice, ScreenShareNotice.none);
      c.dispose();
    });

    test('camera was OFF before sharing -> stays off after', () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      await c.toggleCamera();
      expect(c.cameraOn, isFalse);
      final (ss, _) = await sharing(c);
      expect(lastMedia(s)['camera'], isTrue, reason: 'the screen is video');
      m.log.clear();
      await ss.stop();
      await settle();
      expect(m.log, isNot(contains('start-video')));
      expect(lastMedia(s)['camera'], isFalse);
      c.dispose();
    });

    test("the notification's Stop sharing", () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      final (ss, svc) = await sharing(c);
      svc.stops.add('user');
      await settle();
      expect(ss.state, ScreenShareState.idle);
      expect(m.log, contains('ss:stop'));
      expect(ss.notice, ScreenShareNotice.none);
      c.dispose();
    });

    test('Android ended it (status-bar chip / lock) -> honest notice',
        () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      final (ss, svc) = await sharing(c);
      svc.stops.add('system');
      await settle();
      expect(ss.state, ScreenShareState.idle);
      expect(ss.notice, ScreenShareNotice.stoppedBySystem);
      expect(c.screenSharing, isFalse);
      c.dispose();
    });

    test('the call ends while sharing -> capture + service stopped', () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      final (ss, svc) = await sharing(c);
      await c.hangup();
      await settle();
      expect(m.log, contains('ss:stop'));
      expect(svc.log.last, 'stop');
      expect(ss.state, ScreenShareState.idle);
      c.dispose();
    });

    test('switching to voice while sharing stops the share', () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      final (ss, svc) = await sharing(c);
      await c.switchToVoice();
      await settle();
      expect(ss.state, ScreenShareState.idle);
      expect(svc.log.last, 'stop');
      c.dispose();
    });

    test('leaving Assisto while sharing never pauses the "camera"', () async {
      final m = ShareMedia(), s = FakeSignaling();
      final c = await live(m, s);
      await sharing(c);
      m.log.clear();
      await c.setBackgroundCameraPause(true);
      expect(c.cameraPausedBg, isFalse);
      expect(m.log, isNot(contains('stop-video')));
      expect(lastMedia(s)['camera'], isTrue);
      c.dispose();
    });
  });

  group('receiver', () {
    test("their 'screen' flag -> remoteScreen; old builds never set it",
        () async {
      final s = FakeSignaling();
      final c = await live(ShareMedia(), s);
      s.remoteSignal('media', {'camera': true, 'video': true, 'screen': true});
      await settle();
      expect(c.remoteScreen, isTrue);
      s.remoteSignal('media', {'camera': true, 'video': true});
      await settle();
      expect(c.remoteScreen, isFalse);
      c.dispose();
    });
  });

  group('data caps', () {
    test('normal: half resolution, 10 fps, 1 Mbit/s', () {
      final c = ScreenShareCaps.forPlan(lowData: false);
      expect((c.maxBitrate, c.maxFramerate, c.scaleDown), (1000000, 10, 2.0));
    });
    test('low data: a third, 5 fps, 450 kbit/s', () {
      final c = ScreenShareCaps.forPlan(lowData: true);
      expect((c.maxBitrate, c.maxFramerate, c.scaleDown), (450000, 5, 3.0));
    });
    test('never above a weaker network plan', () {
      final c = ScreenShareCaps.forPlan(
          lowData: false, planMaxBps: 300000, planMaxFps: 8, planScale: 2.5);
      expect((c.maxBitrate, c.maxFramerate, c.scaleDown), (300000, 8, 2.5));
    });
  });

  group('source guards (Android order, uncropped view, manifest)', () {
    final media = File('lib/calls/webrtc_media.dart').readAsStringSync();
    final block = media.substring(media.indexOf('circle-screenshare (1:1)'));

    test('consent -> service -> getDisplayMedia, in that order', () {
      final a = block.indexOf('Helper.requestCapturePermission()');
      final b = block.indexOf('await beforeCapture()');
      final c = block.indexOf('getDisplayMedia(');
      expect(a, greaterThan(0));
      expect(b, greaterThan(a));
      expect(c, greaterThan(b));
    });

    test('replaceTrack when a sender exists; the receiver view is contain', () {
      expect(block, contains('await sender.replaceTrack(track)'));
      expect(block, contains('RTCVideoViewObjectFitContain'));
      expect(block, contains('MAINTAIN_RESOLUTION'));
      // the camera paths never blank / replace a shared screen
      expect(media, contains('if (_screenTrack == null) await _videoSender?.replaceTrack(null)'));
      expect(media, contains('if (_screenTrack != null && sender != null)'));
    });

    test('the mediaProjection service: APK yes, Play only once declared', () {
      final ci = File('../.github/workflows/android.yml').readAsStringSync();
      expect(ci, contains('android:foregroundServiceType="mediaProjection"'));
      expect(ci, contains('FOREGROUND_SERVICE_MEDIA_PROJECTION'));
      expect(ci, contains("PLAY_SCREEN_SHARE: 'false'"));
      expect(ci, contains('Play manifest: ScreenShareService + FOREGROUND_SERVICE_MEDIA_PROJECTION removed'));
      final svc = File(
              'android_overlay/app/src/main/kotlin/com/assisto/assisto/calls/ScreenShareService.kt')
          .readAsStringSync();
      expect(svc, contains('FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION'));
      expect(svc, contains('ctx.startService(i)'),
          reason: 'a refused startForeground never becomes a crash');
      expect(svc, contains('START_NOT_STICKY'));
      expect(svc, contains('WebRTC_ScreenCapture'),
          reason: 'Android ending the projection is noticed');
    });

    test('the emulator proof is wired (host taps Android consent)', () {
      final sh = File('../tools/reality/run_flows.sh').readAsStringSync();
      expect(sh, contains('REALITY_PROJECTION'));
      expect(sh, contains('appops set \$PKG PROJECT_MEDIA allow'));
      final all = File('integration_test/reality_all_test.dart').readAsStringSync();
      expect(all, contains('registerCircleScreenShareFlows()'));
      final flow = File('integration_test/flows/circle_screenshare_flow.dart')
          .readAsStringSync();
      expect(flow, contains('videoFramesDecoded'));
      expect(flow, contains('videoFramesEncoded'));
    });
  });

  group('call screen', () {
    Future<void> pump(WidgetTester tester, CallController c,
        {String lang = 'en', double text = 1.0, CallVideoSurface? surface}) async {
      tester.view.physicalSize = const Size(360, 800) * 3;
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
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(text)),
            child: child!),
        home: CircleCallScreen(
          key: ObjectKey(c),
          member: const {'id': 7, 'name': 'Nadia'},
          kind: 'video',
          controller: c,
          resumed: true,
          surface: surface ?? ShareSurface(),
        ),
      ));
      await tester.pump();
    }

    CallController liveVideo(ShareMedia m) {
      final c = mk(m, FakeSignaling());
      c.phase = CallPhase.connected;
      c.callId = 42;
      c.connectedAt = DateTime.now();
      return c;
    }

    for (final lang in ['en', 'bn']) {
      testWidgets('share -> our sheet -> sharing bar -> Stop ($lang)',
          (tester) async {
        final svc = FakeShareService();
        ScreenShareController.serviceOverride = svc;
        final m = ShareMedia();
        final c = liveVideo(m);
        await pump(tester, c, lang: lang);
        final t = await AppLocalizations.delegate.load(Locale(lang));
        expect(find.byKey(const Key('cssh-share')), findsOneWidget);
        expect(find.text(t.csshShare), findsOneWidget);
        await tester.tap(find.byKey(const Key('cssh-share')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cssh-consent')), findsOneWidget);
        expect(find.text(t.csshConsentTitle('Nadia')), findsOneWidget);
        await tester.tap(find.byKey(const Key('cssh-consent-go')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cssh-sharing-bar')), findsOneWidget);
        expect(find.text(t.csshSharingBar), findsOneWidget);
        expect(tester.getSize(find.byKey(const Key('cssh-stop'))).height,
            greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(const Key('cssh-stop')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cssh-sharing-bar')), findsNothing);
        expect(find.byKey(const Key('cssh-share')), findsOneWidget);
        expect(svc.log.last, 'stop');
        expect(tester.takeException(), isNull);
        c.dispose();
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('their shared screen is drawn whole with a chip', (tester) async {
      ScreenShareController.serviceOverride = FakeShareService();
      final c = liveVideo(ShareMedia());
      c.remoteScreen = true;
      await pump(tester, c);
      expect(find.byKey(const Key('test-remote-screen')), findsOneWidget);
      expect(find.byKey(const Key('cssh-remote-chip')), findsOneWidget);
      expect(find.text('Nadia is sharing their screen'), findsOneWidget);
      c.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a camera (no screen flag) keeps the normal view',
        (tester) async {
      ScreenShareController.serviceOverride = FakeShareService();
      final c = liveVideo(ShareMedia());
      await pump(tester, c);
      expect(find.byKey(const Key('test-remote-screen')), findsNothing);
      expect(find.byKey(const Key('cssh-remote-chip')), findsNothing);
      c.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('refused / not in this version -> honest line', (tester) async {
      ScreenShareController.serviceOverride = FakeShareService()
        ..isAvailable = false;
      final c = liveVideo(ShareMedia());
      await pump(tester, c);
      await tester.tap(find.byKey(const Key('cssh-share')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cssh-consent')), findsNothing);
      expect(find.byKey(const Key('cssh-notice')), findsOneWidget);
      c.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('200 % text, bn: share row + sharing bar never overflow',
        (tester) async {
      ScreenShareController.serviceOverride = FakeShareService();
      final m = ShareMedia();
      final c = liveVideo(m);
      await pump(tester, c, lang: 'bn', text: 2.0);
      expect(tester.takeException(), isNull);
      final ss = ScreenShareController.of(c)!;
      await ss.request();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cssh-consent-go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cssh-sharing-bar')), findsOneWidget);
      expect(tester.takeException(), isNull);
      c.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a voice call shows no share button', (tester) async {
      ScreenShareController.serviceOverride = FakeShareService();
      final c = mk(ShareMedia(), FakeSignaling(), video: false);
      c.phase = CallPhase.connected;
      c.callId = 42;
      c.connectedAt = DateTime.now();
      await pump(tester, c);
      expect(find.byKey(const Key('cssh-share')), findsNothing);
      c.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
