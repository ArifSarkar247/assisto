// callpip (owner phone test 2 Nov 19:45): "during a My Circle VIDEO call,
// Back / Home / opening Facebook makes the video disappear instead of
// minimizing". Kotlin is compiled only by the daily APK build, so every
// decision is Dart (lib/calls/call_pip.dart) and tested here, plus the
// native contract (source guards) and the runtime wiring through a mocked
// com.assisto/calls channel.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_mini_bar.dart';
import 'package:assisto/calls/call_native.dart';
import 'package:assisto/calls/call_pip.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/calls/call_video.dart';
import 'package:assisto/l10n/app_localizations.dart';

import 'c2_calls_fakes.dart';

/// every com.assisto/calls call: (method, args)
final List<(String, Object?)> native = [];

void _mock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.assisto/calls'),
          (c) async {
    native.add((c.method, c.arguments));
    if (c.method == 'setAutoPip' || c.method == 'leaveApp') return true;
    return null;
  });
}

/// native -> Dart (a PiP button, the notification's Return)
Future<void> _fromNative(String method, Object? args) async {
  const codec = StandardMethodCodec();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('com.assisto/calls',
          codec.encodeMethodCall(MethodCall(method, args)), (_) {});
}

List<Map> _pipCalls() => [
      for (final c in native)
        if (c.$1 == 'setAutoPip') c.$2 as Map
    ];

CallController _live({bool video = true, bool cameraOn = true}) =>
    previewController(
        video: video,
        outgoing: true,
        phase: CallPhase.connected,
        cameraOn: cameraOn);

FakeCallMedia _media(CallController c) => c.media as FakeCallMedia;
FakeSignaling _sig(CallController c) => c.signaling as FakeSignaling;

Map<String, dynamic> _lastMediaSignal(CallController c) =>
    _sig(c).signals.lastWhere((s) => s.$1 == 'media').$2;

/// A surface that also knows the remote video size (like WebRtcCallMedia).
class _SizedSurface extends FakeSurface implements VideoSizeSource {
  final ValueNotifier<int> _tick = ValueNotifier(0);
  int? w;
  int? h;
  @override
  int? get remoteVideoWidth => w;
  @override
  int? get remoteVideoHeight => h;
  @override
  Listenable get remoteSizeChanges => _tick;
  void resize(int ww, int hh) {
    w = ww;
    h = hh;
    _tick.value++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    native.clear();
    _mock();
    CallRuntime.instance.resetForTest();
    CallNative.inPip.value = false;
    CallNative.listen();
  });

  tearDown(() {
    CallRuntime.instance.resetForTest();
    CallNative.inPip.value = false;
  });

  group('decisions (call_pip.dart)', () {
    test('auto PiP only for a LIVE video call', () {
      expect(wantAutoPip(videoOn: true, live: true, ended: false), isTrue);
      expect(wantAutoPip(videoOn: false, live: true, ended: false), isFalse,
          reason: 'voice: notification, no PiP');
      expect(wantAutoPip(videoOn: true, live: false, ended: false), isFalse,
          reason: 'still ringing / connecting');
      expect(wantAutoPip(videoOn: true, live: true, ended: true), isFalse);
    });

    test('PiP shape follows the remote video, always inside Android limits',
        () {
      expect(pipAspectFor(null, null), PipAspect.fallback);
      expect(pipAspectFor(0, 480), PipAspect.fallback);
      expect(pipAspectFor(480, 640), const PipAspect(75, 100)); // portrait
      expect(pipAspectFor(640, 480), const PipAspect(100, 75)); // landscape
      expect(pipAspectFor(720, 720), const PipAspect(100, 100));
      for (final s in [
        (1, 1000),
        (1000, 1),
        (100, 239),
        (239, 100),
        (1080, 2400),
        (2400, 1080),
      ]) {
        final a = pipAspectFor(s.$1, s.$2);
        expect(a.ratio, inInclusiveRange(1 / 2.39, 2.39), reason: '$s -> $a');
        expect(a.w, inInclusiveRange(1, 100));
        expect(a.h, inInclusiveRange(1, 100));
      }
    });

    test('PiP buttons: mute, camera (video only), end — at most 3', () {
      expect(pipActions(muted: false, videoOn: true, cameraOn: true), const [
        PipAction(PipActionId.mute),
        PipAction(PipActionId.camera, on: true),
        PipAction(PipActionId.end),
      ]);
      expect(pipActions(muted: true, videoOn: false, cameraOn: false), const [
        PipAction(PipActionId.mute, on: true),
        PipAction(PipActionId.end),
      ]);
      for (final m in [true, false]) {
        for (final v in [true, false]) {
          expect(pipActions(muted: m, videoOn: v, cameraOn: v).length,
              lessThanOrEqualTo(3));
        }
      }
    });

    test('PiP state: off for voice / ended; a button change is a new state',
        () {
      final off = pipStateFor(
          videoOn: false, live: true, ended: false, muted: false, cameraOn: false);
      expect(off.signature, PipState.off.signature);
      final a = pipStateFor(
          videoOn: true, live: true, ended: false, muted: false, cameraOn: true);
      final b = pipStateFor(
          videoOn: true, live: true, ended: false, muted: true, cameraOn: true);
      expect(a.auto, isTrue);
      expect(a.signature == b.signature, isFalse);
      expect(
          pipStateFor(
                  videoOn: true,
                  live: true,
                  ended: false,
                  muted: false,
                  cameraOn: true,
                  remoteW: 640,
                  remoteH: 480)
              .aspect,
          const PipAspect(100, 75));
    });

    test('camera pauses only when Assisto is NOT visible (PiP keeps it live)',
        () {
      bool pause(AppLifecycleState s,
              {bool pip = false,
              bool video = true,
              bool cam = true,
              bool live = true}) =>
          shouldPauseCameraBg(
              state: s, inPip: pip, videoOn: video, cameraOn: cam, live: live);
      expect(pause(AppLifecycleState.paused), isTrue);
      expect(pause(AppLifecycleState.hidden), isTrue);
      expect(pause(AppLifecycleState.inactive), isFalse,
          reason: 'PiP / notification shade: still visible');
      expect(pause(AppLifecycleState.paused, pip: true), isFalse);
      expect(pause(AppLifecycleState.paused, video: false), isFalse);
      expect(pause(AppLifecycleState.paused, cam: false), isFalse,
          reason: 'the user turned it off: nothing to pause');
      expect(pause(AppLifecycleState.paused, live: false), isFalse);
      expect(pause(AppLifecycleState.resumed), isFalse);

      expect(
          shouldResumeCameraBg(
              state: AppLifecycleState.resumed, inPip: false, pausedBg: true),
          isTrue);
      expect(
          shouldResumeCameraBg(
              state: AppLifecycleState.paused, inPip: false, pausedBg: true),
          isFalse);
      expect(
          shouldResumeCameraBg(
              state: AppLifecycleState.resumed, inPip: false, pausedBg: false),
          isFalse);
    });

    test('Back on the last screen: PiP (video) / background (voice), never '
        'close during a call', () {
      expect(rootBackAction(callActive: false, videoLive: false),
          RootBackAction.none);
      expect(rootBackAction(callActive: true, videoLive: true),
          RootBackAction.pip);
      expect(rootBackAction(callActive: true, videoLive: false),
          RootBackAction.background);
    });

    test('in-app: green bar always, video tile only for video, PiP = video '
        'only', () {
      expect(
          miniCallView(hasCall: false, ended: false, inPip: false, videoOn: true),
          const MiniCallView());
      expect(
          miniCallView(hasCall: true, ended: true, inPip: false, videoOn: true),
          const MiniCallView());
      expect(
          miniCallView(hasCall: true, ended: false, inPip: false, videoOn: false),
          const MiniCallView(bar: true));
      expect(
          miniCallView(hasCall: true, ended: false, inPip: false, videoOn: true),
          const MiniCallView(bar: true, tile: true));
      expect(
          miniCallView(hasCall: true, ended: false, inPip: true, videoOn: true),
          const MiniCallView(pip: true));
    });

    test('self inset never shows a black / frozen box', () {
      expect(
          showSelfInset(
              videoOn: true,
              cameraOn: true,
              pausedBg: false,
              cameraUnavailable: false),
          isTrue);
      expect(
          showSelfInset(
              videoOn: true,
              cameraOn: true,
              pausedBg: true,
              cameraUnavailable: false),
          isFalse);
      expect(
          showSelfInset(
              videoOn: true,
              cameraOn: true,
              pausedBg: false,
              cameraUnavailable: true),
          isFalse);
      expect(
          showSelfInset(
              videoOn: true,
              cameraOn: false,
              pausedBg: false,
              cameraUnavailable: false),
          isFalse);
    });
  });

  group('camera in the background (controller state machine)', () {
    test('pause: other phone told first (avatar), camera released; resume: '
        're-opened by itself', () async {
      final c = _live();
      await c.setBackgroundCameraPause(true);
      expect(c.cameraPausedBg, isTrue);
      expect(c.cameraOn, isTrue, reason: "the user's choice is kept");
      expect(_media(c).log, contains('stop-video'));
      final sent = _lastMediaSignal(c);
      expect(sent['camera'], isFalse);
      expect(sent['away'], isTrue);

      await c.setBackgroundCameraPause(false);
      expect(c.cameraPausedBg, isFalse);
      expect(_media(c).log.last, 'start-video');
      final back = _lastMediaSignal(c);
      expect(back['camera'], isTrue);
      expect(back['away'], isFalse);
    });

    test('back camera stays the back camera after the resume', () async {
      final c = _live();
      c.frontCamera = false;
      await c.setBackgroundCameraPause(true);
      await c.setBackgroundCameraPause(false);
      expect(_media(c).log.sublist(_media(c).log.length - 2),
          ['start-video', 'switch']);
      expect(c.frontCamera, isFalse);
    });

    test('camera cannot come back: honest "camera off", never a frozen frame',
        () async {
      final c = _live();
      await c.setBackgroundCameraPause(true);
      _media(c).cameraError = MediaOpenException(false, 'busy');
      await c.setBackgroundCameraPause(false);
      expect(c.cameraOn, isFalse);
      expect(c.notice, CallNotice.cameraBlocked);
      expect(_lastMediaSignal(c)['camera'], isFalse);
    });

    test('nothing to pause: voice call, camera already off, ended', () async {
      final voice = _live(video: false);
      await voice.setBackgroundCameraPause(true);
      expect(voice.cameraPausedBg, isFalse);
      final off = _live(cameraOn: false);
      await off.setBackgroundCameraPause(true);
      expect(off.cameraPausedBg, isFalse);
      expect(_media(off).log, isNot(contains('stop-video')));
      final ended = _live()..phase = CallPhase.ended;
      await ended.setBackgroundCameraPause(true);
      expect(ended.cameraPausedBg, isFalse);
    });

    test('switched to voice while away: no camera re-opened', () async {
      final c = _live();
      await c.setBackgroundCameraPause(true);
      c.videoOn = false;
      await c.setBackgroundCameraPause(false);
      expect(_media(c).log, isNot(contains('start-video')));
    });
  });

  group('runtime wiring (mocked native)', () {
    test('the call screen\'s live video call arms auto-PiP with its buttons; '
        'the same state is sent once', () async {
      final c = _live();
      final s = _SizedSurface();
      CallRuntime.instance.bindScreenCall(c, s);
      CallRuntime.instance.bindScreenCall(c, s);
      await Future<void>.delayed(Duration.zero);
      final calls = _pipCalls();
      expect(calls, hasLength(1));
      expect(calls.single['on'], isTrue);
      expect(calls.single['w'], 9);
      expect(calls.single['h'], 16);
      expect([for (final a in calls.single['actions'] as List) a['id']],
          ['mute', 'camera', 'end']);
      // the remote video's size arrives -> the window takes its shape
      s.resize(640, 480);
      await Future<void>.delayed(Duration.zero);
      expect(_pipCalls().last['w'], 100);
      expect(_pipCalls().last['h'], 75);
      // mute -> the PiP button flips to "Unmute"
      c.muted = true;
      CallRuntime.instance.bindScreenCall(c, s);
      await Future<void>.delayed(Duration.zero);
      expect((_pipCalls().last['actions'] as List).first['on'], isTrue);
      // the screen lets go -> auto-PiP off
      CallRuntime.instance.unbindScreenCall(c);
      await Future<void>.delayed(Duration.zero);
      expect(_pipCalls().last['on'], isFalse);
    });

    test('voice call: no PiP (notification keeps it running)', () async {
      CallRuntime.instance.bindScreenCall(_live(video: false), null);
      await Future<void>.delayed(Duration.zero);
      expect(_pipCalls().every((m) => m['on'] == false), isTrue);
    });

    test('REGRESSION: back from the mini bar, auto-PiP stays ON (it was '
        'switched off while "PiP supported?" was still unknown)', () async {
      final c = _live();
      CallRuntime.instance.bindScreenCall(c, FakeSurface());
      // minimize (Back) -> mini bar keeps it
      CallRuntime.instance.unbindScreenCall(c);
      CallRuntime.instance.minimize(OngoingCall(
          controller: c,
          surface: FakeSurface(),
          member: const {'id': 1, 'name': 'Nadia'},
          kind: 'video'));
      await Future<void>.delayed(Duration.zero);
      expect(_pipCalls().last['on'], isTrue);
      // tap the bar -> the screen takes it back -> still ON
      CallRuntime.instance.takeOngoing();
      CallRuntime.instance.bindScreenCall(c, FakeSurface());
      await Future<void>.delayed(Duration.zero);
      expect(_pipCalls().last['on'], isTrue);
    });

    test('PiP buttons reach the live call: mute, camera, end', () async {
      final c = _live();
      CallRuntime.instance.bindScreenCall(c, FakeSurface());
      await _fromNative('pipAction', 'mute');
      await Future<void>.delayed(Duration.zero);
      expect(c.muted, isTrue);
      await _fromNative('pipAction', 'camera');
      await Future<void>.delayed(Duration.zero);
      expect(c.cameraOn, isFalse);
      await _fromNative('pipAction', 'end');
      await Future<void>.delayed(Duration.zero);
      expect(c.isEnded, isTrue);
      expect(_sig(c).eventLog.join(' '), contains('hangup'));
    });

    test('a minimized call gets the PiP buttons too', () async {
      final c = _live();
      CallRuntime.instance.minimize(OngoingCall(
          controller: c,
          surface: FakeSurface(),
          member: const {'id': 1, 'name': 'Nadia'},
          kind: 'video'));
      await _fromNative('pipAction', 'mute');
      await Future<void>.delayed(Duration.zero);
      expect(c.muted, isTrue);
    });

    test('call ends while the PiP window shows -> the window closes '
        '(Assisto to the background)', () async {
      final c = _live();
      CallRuntime.instance.bindScreenCall(c, FakeSurface());
      CallNative.inPip.value = true;
      c.phase = CallPhase.ended;
      CallRuntime.instance.syncPip();
      await Future<void>.delayed(Duration.zero);
      expect(native.where((n) => n.$1 == 'leaveApp'), isNotEmpty);
      expect((native.lastWhere((n) => n.$1 == 'leaveApp').$2 as Map)['pip'],
          isFalse);
    });
  });

  group('lifecycle + Back (widget binding)', () {
    testWidgets('Home WITHOUT PiP: camera paused -> back: camera on again',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final c = _live();
      CallRuntime.instance.bindScreenCall(c, FakeSurface());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(c.cameraPausedBg, isTrue);
      expect(_lastMediaSignal(c)['away'], isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(c.cameraPausedBg, isFalse);
      expect(_media(c).log.last, 'start-video');
    });

    testWidgets('Home WITH PiP: camera stays live; PiP closed (X) -> paused; '
        'opened again -> live', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final c = _live();
      CallRuntime.instance.bindScreenCall(c, FakeSurface());
      CallNative.inPip.value = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(c.cameraPausedBg, isFalse, reason: 'PiP is visible');
      // PiP X: the activity stops while Android still says "in PiP" ...
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(c.cameraPausedBg, isFalse);
      // ... then PiP mode ends (no lifecycle event follows)
      CallNative.inPip.value = false;
      await tester.pump();
      expect(c.cameraPausedBg, isTrue);
      expect(c.isEnded, isFalse, reason: 'close PiP never ends the call');
      // "Return to call" from the notification
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(c.cameraPausedBg, isFalse);
      await tester.pump(const Duration(milliseconds: 400)); // PiP-exit timer
    });

    testWidgets('Back on the LAST screen during a video call -> PiP, never '
        'closes Assisto', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallRuntime.instance.attachNavigator(nav);
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav, home: const Scaffold(body: Text('home'))));
      final c = _live();
      CallRuntime.instance.minimize(OngoingCall(
          controller: c,
          surface: FakeSurface(),
          member: const {'id': 1, 'name': 'Nadia'},
          kind: 'video'));
      await tester.pump();
      final handled = await tester.binding.handlePopRoute();
      expect(handled, isTrue);
      final leave = native.lastWhere((n) => n.$1 == 'leaveApp');
      expect((leave.$2 as Map)['pip'], isTrue);
      expect(c.isEnded, isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('voice call: Back on the last screen -> background (call '
        'keeps running)', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallRuntime.instance.attachNavigator(nav);
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav, home: const Scaffold(body: Text('home'))));
      final c = _live(video: false);
      CallRuntime.instance.minimize(OngoingCall(
          controller: c,
          member: const {'id': 1, 'name': 'Nadia'},
          kind: 'voice'));
      await tester.pump();
      expect(await tester.binding.handlePopRoute(), isTrue);
      expect((native.lastWhere((n) => n.$1 == 'leaveApp').$2 as Map)['pip'],
          isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a screen that can go back still goes back; no call = normal '
        'Back', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallRuntime.instance.attachNavigator(nav);
      await tester.pumpWidget(MaterialApp(
          navigatorKey: nav, home: const Scaffold(body: Text('home'))));
      final c = _live();
      CallRuntime.instance.bindScreenCall(c, FakeSurface());
      nav.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => const Text('chat')));
      await tester.pumpAndSettle();
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(native.where((n) => n.$1 == 'leaveApp'), isEmpty);
      // no call: our runtime never swallows Back
      CallRuntime.instance.unbindScreenCall(c);
      expect(await CallRuntime.instance.didPopRoute(), isFalse);
    });
  });

  group('PiP layout', () {
    Widget host(Widget child, {String lang = 'en'}) => MaterialApp(
          locale: Locale(lang),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Center(child: SizedBox(width: 180, height: 320, child: child)),
        );

    testWidgets('their video large + my camera small; paused camera -> no '
        'inset; their camera off -> avatar', (tester) async {
      final c = _live();
      await tester.pumpWidget(host(CallPipLayout(
          controller: c, surface: FakeSurface(), name: 'Nadia')));
      expect(find.byIcon(Icons.face_3_rounded), findsOneWidget,
          reason: 'remote video');
      expect(find.byKey(const Key('call-pip-self')), findsOneWidget);
      expect(tester.takeException(), isNull);

      c.cameraPausedBg = true;
      c.remoteCameraOn = false;
      await tester.pumpWidget(host(CallPipLayout(
          key: const Key('again'),
          controller: c,
          surface: FakeSurface(),
          name: 'Nadia')));
      expect(find.byKey(const Key('call-pip-self')), findsNothing);
      expect(find.byIcon(Icons.face_3_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tiny PiP window (Bangla, 200 % text): nothing overflows',
        (tester) async {
      final c = _live()..remoteMicOn = false;
      await tester.pumpWidget(host(
          Builder(
              builder: (ctx) => MediaQuery(
                    data: MediaQuery.of(ctx)
                        .copyWith(textScaler: const TextScaler.linear(2)),
                    child: SizedBox(
                        width: 96,
                        height: 170,
                        child: CallPipLayout(
                            controller: c,
                            surface: FakeSurface(),
                            name: 'নাদিয়া')),
                  )),
          lang: 'bn'));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    });
  });

  group('native + build contract (Kotlin is compiled only by the APK build)',
      () {
    String read(String p) => File(p).readAsStringSync();
    const kt =
        'android_overlay/app/src/main/kotlin/com/assisto/assisto/calls/CallPip.kt';

    test('CallPip.kt: leaving never finishes the activity; guarded; immutable '
        'intents; not-exported receiver', () {
      final s = read(kt);
      final leave =
          s.substring(s.indexOf('fun leaveApp'), s.indexOf('fun decorateOngoing'));
      expect(leave.contains('finish()'), isFalse);
      expect(leave, contains('moveTaskToBack(true)'));
      expect(s, contains('setAutoEnterEnabled'));
      expect(s, contains('setAspectRatio'));
      expect(s, contains('setActions'));
      expect(s, contains('RECEIVER_NOT_EXPORTED'));
      expect('PendingIntent.get'.allMatches(s).length,
          'FLAG_IMMUTABLE'.allMatches(s).length,
          reason: 'every PendingIntent immutable');
      expect(s, isNot(contains('SYSTEM_ALERT_WINDOW')));
      // every PiP button id Dart sends has a native icon
      for (final id in PipActionId.values) {
        expect(s, contains('"${id.name}"'), reason: id.name);
      }
    });

    test('PiP icons exist and survive resource shrinking', () {
      final keep = read('android_overlay/app/src/main/res/raw/assisto_keep.xml');
      for (final n in [
        'ic_pip_mic',
        'ic_pip_mic_off',
        'ic_pip_videocam',
        'ic_pip_videocam_off',
        'ic_pip_call_end'
      ]) {
        expect(File('android_overlay/app/src/main/res/drawable/$n.xml')
            .existsSync(), isTrue, reason: n);
        expect(keep, contains('@drawable/$n'));
      }
    });

    test('MainActivity forwards Home (26-30), PiP changes and "Return to call"',
        () {
      final s = read(
          'android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt');
      expect(s, contains('CallsChannel.onUserLeaveHint()'));
      expect(s, contains('CallsChannel.onPipChanged('));
      expect(s, contains('CallsChannel.onIntent(intent)'));
      final ch = read(
          'android_overlay/app/src/main/kotlin/com/assisto/assisto/calls/CallsChannel.kt');
      for (final m in ['"setAutoPip"', '"leaveApp"', '"decorateOngoing"', '"pipAction"', '"callReturn"']) {
        expect(ch, contains(m));
      }
    });

    test('manifest: PiP on MainActivity, size changes handled, no overlay '
        'permission, no new FGS type', () {
      final y = read('../.github/workflows/android.yml');
      expect(y, contains('android:supportsPictureInPicture="true"'));
      expect(y, contains('callpip: MainActivity configChanges'));
      expect(y, contains("'smallestScreenSize', 'screenLayout'"));
      // the Play guard still refuses these
      expect(y, contains('SYSTEM_ALERT_WINDOW BIND_ACCESSIBILITY_SERVICE FOREGROUND_SERVICE_CAMERA'));
      expect(y.contains('FOREGROUND_SERVICE_PHONE_CALL'), isFalse,
          reason: 'phoneCall FGS type needs a Play declaration (owner)');
    });

    test('a downloaded Play update never restarts Assisto during a call', () {
      final pu = read('lib/play_update.dart');
      final body = pu.substring(pu.indexOf('static Future<void> onBackground'));
      expect(body.indexOf('holdInstall()'), greaterThan(0));
      expect(body.indexOf('holdInstall()'), lessThan(body.indexOf('complete()')));
      expect(read('lib/main.dart'),
          contains('PlayUpdate.holdInstall = () => CallRuntime.instance.callActive'));
    });
  });
}
