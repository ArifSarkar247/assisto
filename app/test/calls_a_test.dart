// calls-a (owner 27 Oct): answer from outside the app + use Assisto during a
// call.
//
// Item 1 — every Accept path's routing decision:
//   cold accept (notification Accept, app closed), cold open (full-screen
//   intent / tap, incl. the lock screen), warm accept / open (app in the
//   background: native onNewIntent + the notification plugin's copy),
//   foreground (in-app ringing screen), Accept while the ringing screen is
//   up, duplicates, the resume "still ringing" check, no "Call ended" frame,
//   instant (transition-less) call routes, signed-out cold accept.
// Item 2 — the return-to-call bar on arbitrary routes, the floating video
//   window (drag / clamp / tap -> full call), system PiP view, navigation
//   keeps the controller alive, ads blocked during a full-screen call.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_launch.dart';
import 'package:assisto/calls/call_mini_bar.dart';
import 'package:assisto/calls/call_native.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/push/push_service.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/state.dart';

import 'c2_calls_fakes.dart';

const _data = {
  'kind': 'call',
  'call_id': '501',
  'chat_id': '7',
  'caller_name': 'Nadia Rahman',
  'caller_photo': 'https://api.lifeassisto.com/media/u/7/p.jpg?v=2&s=a b',
  'video': 'false',
  'lang': 'en',
  'ack_sig': 'x/y+z==',
};

PushPayload _p([Map<String, String> extra = const {}]) =>
    PushPayload({..._data, ...extra});

/// The route string exactly as CallLaunch.kt (java.net.URLEncoder) builds it.
String _nativeRoute(String action, Map<String, String> data) {
  String enc(String s) => Uri.encodeQueryComponent(s);
  final json = PushPayload(data).encode();
  return '/assisto_call?a=$action&id=${enc(data['call_id']!)}&p=${enc(json)}';
}

class _App extends StatelessWidget {
  const _App(
      {required this.nav,
      required this.app,
      this.initialRoute,
      this.locale = const Locale('en')});
  final GlobalKey<NavigatorState> nav;
  final AppState app;
  final String? initialRoute;
  final Locale locale;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          navigatorKey: nav,
          locale: locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          initialRoute: initialRoute,
          onGenerateRoute: CallLaunchRouter.instance.onGenerateRoute,
          builder: (context, child) =>
              CallMiniBarHost(child: child ?? const SizedBox()),
          home: const _Home(),
        ),
      );
}

int homeBuilds = 0;

class _Home extends StatelessWidget {
  const _Home();
  @override
  Widget build(BuildContext context) {
    homeBuilds++;
    return Scaffold(
      appBar: AppBar(title: const Text('HOME')),
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const _Chat(name: 'Rahim'))),
          child: const Text('open chat'),
        ),
      ),
    );
  }
}

/// A stand-in My Circle chat: type and "send" while a call runs.
class _Chat extends StatefulWidget {
  const _Chat({required this.name});
  final String name;
  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  final ctl = TextEditingController();
  final sent = <String>[];
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('chat ${widget.name}')),
        body: Column(children: [
          Expanded(child: ListView(children: [for (final m in sent) Text(m)])),
          Row(children: [
            Expanded(child: TextField(key: const Key('chat-input'), controller: ctl)),
            IconButton(
                key: const Key('chat-send'),
                tooltip: 'send',
                onPressed: () => setState(() {
                      sent.add(ctl.text);
                      ctl.clear();
                    }),
                icon: const Icon(Icons.send_rounded)),
          ]),
        ]),
      );
}

AppState _signedOut() => AppState()..loading = false;

/// Still starting (token not read yet): a call screen waits for the session.
AppState _starting() => AppState();

/// End of a test with a waiting call screen: the start finishes signed out,
/// the screen closes itself, every timer drains.
Future<void> _finish(WidgetTester tester, AppState app) async {
  app.loading = false;
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

/// Every call on com.assisto/calls (method + call_id) and what ringActive
/// answers.
final List<String> nativeCalls = [];
bool? nativeRingActive = true;

void _mockChannels(List<String> lockCalls) {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('com.assisto/lockscreen'),
      (c) async {
    lockCalls.add(c.method);
    return null;
  });
  m.setMockMethodCallHandler(const MethodChannel('com.assisto/calls'),
      (c) async {
    final a = c.arguments;
    nativeCalls.add('${c.method}:${a is Map ? (a['call_id'] ?? '') : ''}');
    if (c.method == 'ringActive') return nativeRingActive;
    return null;
  });
}

void main() {
  late List<String> lockCalls;

  setUp(() {
    lockCalls = [];
    nativeCalls.clear();
    nativeRingActive = true;
    debugRingActive = null;
    SharedPreferences.setMockInitialValues({});
    _mockChannels(lockCalls);
    CallLaunchRouter.instance.resetForTest();
    CallRuntime.instance.resetForTest();
    CallNative.inPip.value = false;
    homeBuilds = 0;
  });

  tearDown(() {
    CallLaunchRouter.instance.resetForTest();
    CallRuntime.instance.resetForTest();
    CallNative.inPip.value = false;
  });

  group('launch route (CallLaunch.kt <-> Dart)', () {
    test('round-trips every payload character (urls, +, spaces, Bangla)', () {
      final d = {..._data, 'caller_name': 'নাদিয়া রহমান'};
      final l = CallLaunch.parseRoute(_nativeRoute('accept', d))!;
      expect(l.accept, isTrue);
      expect(l.callId, '501');
      expect(l.payload.callerName, 'নাদিয়া রহমান');
      expect(l.payload.callerPhoto, _data['caller_photo']);
      expect(l.payload.data['ack_sig'], 'x/y+z==');
      expect(CallLaunch.routeFor('open', d), _nativeRoute('open', d));
    });

    test('exactly one "/" segment: the Navigator builds [home, call] only', () {
      final r = _nativeRoute('accept', _data);
      expect(r.split('/').length, 2);
    });

    test('anything else is not a call launch', () {
      expect(CallLaunch.parseRoute('/'), isNull);
      expect(CallLaunch.parseRoute('/photo/app?t=1'), isNull);
      expect(CallLaunch.parseRoute('/assisto_callx?a=accept&p=%7B%7D'), isNull);
      expect(CallLaunch.parseRoute('/assisto_call?a=accept&p=not-json'), isNull);
      expect(
          CallLaunch.parseRoute(_nativeRoute('accept', {..._data, 'kind': 'sos'})),
          isNull);
      expect(
          CallLaunch.parseRoute(_nativeRoute('accept', {..._data, 'call_id': ''})),
          isNull);
      // an unknown action never answers: it only shows the ringing screen
      expect(CallLaunch.parseRoute(_nativeRoute('weird', _data))!.accept, isFalse);
    });

    test('one screen per call: Accept after "open" wins, never twice', () {
      final r = CallLaunchRouter.instance;
      expect(r.claim('9', 'open'), isTrue);
      expect(r.claim('9', 'open'), isFalse);
      expect(r.claim('9', 'accept'), isTrue);
      expect(r.claim('9', 'accept'), isFalse);
      expect(r.claim('9', 'open'), isFalse);
      expect(r.answered('9'), isTrue);
      expect(r.claim('', 'accept'), isFalse);
    });

    test('ads: a FULL-screen call (not only a minimized one) blocks them', () {
      expect(CallRuntime.instance.callActive, isFalse);
      CallRuntime.instance.activeCallId = 501;
      expect(CallRuntime.instance.callActive, isTrue);
    });
  });

  group('Item 1: Accept opens the call screen directly', () {
    testWidgets('COLD Accept (app closed / lock screen): the FIRST frame is '
        'the call screen, the home is never painted', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final app = AppState(); // still loading, like a real cold start
      await tester.pumpWidget(_App(
          nav: nav, app: app, initialRoute: _nativeRoute('accept', _data)));
      // first frame
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(find.text('Nadia Rahman'), findsOneWidget);
      expect(find.text('HOME'), findsNothing, reason: 'home offstage');
      expect(find.byType(IncomingCallScreen), findsNothing);
      final route = CallLaunchRouter.instance.coldRoute!;
      expect(route.isCurrent, isTrue);
      expect(route.settings.name, CallLaunchRouter.acceptRouteName);
      expect((route as PageRoute).transitionDuration, Duration.zero);
      expect(CallLaunchRouter.instance.decisions.last,
          contains('entry=coldAccept action=accept id=501 result=first=call'));
      // this phone is in call 501 from the first frame on
      expect(CallRuntime.instance.activeCallId, 501);
      expect(nav.currentState!.canPop(), isTrue, reason: 'home is underneath');

      // the notification plugin's launch copy + the resume "still ringing"
      // check arrive seconds later: NO second call / ringing screen
      expect(
          CallLaunchRouter.instance.openWarm(
              CallLaunch(action: 'accept', payload: _p()),
              nav: nav.currentState),
          isTrue);
      CallRuntime.instance.attachNavigator(nav);
      CallRuntime.instance.onIncoming({'call_id': '501', 'caller_name': 'Nadia'});
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(find.byType(IncomingCallScreen), findsNothing,
          reason: 'the stacked ringing screen was the "Call ended" frame');
      expect(CallLaunchRouter.instance.decisions.last, contains('duplicate'));

      // AppState finishes loading signed out -> nothing to answer with: the
      // call screen closes itself (login / home shows)
      app.loading = false;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byType(CircleCallScreen), findsNothing);
      expect(find.text('HOME'), findsOneWidget);
      expect(lockCalls, contains('release'));
    });

    testWidgets('COLD full-screen intent / tap (lock screen): first frame is '
        'the ringing screen; Accept swaps to the call screen instantly',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final app = _starting();
      await tester.pumpWidget(_App(
          nav: nav, app: app, initialRoute: _nativeRoute('open', _data)));
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      expect(CallLaunchRouter.instance.decisions.last,
          contains('entry=coldOpen action=open id=501 result=first=ringing'));
      await tester.tap(find.byKey(const Key('incoming-accept')));
      await tester.pump(); // ONE frame: no transition
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(find.byType(IncomingCallScreen), findsNothing);
      expect(CallLaunchRouter.instance.answered('501'), isTrue);
      expect(CallLaunchRouter.instance.decisions.last, contains('inAppAccept'));
      // accepted: the lock screen is NOT handed back by the ringing screen
      // (the call screen owns it now)
      expect(lockCalls, isEmpty);
      await _finish(tester, app);
    });

    testWidgets('WARM Accept (app in background): straight to the call screen '
        'in one frame, the notification copy is a no-op', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallLaunchRouter.instance.attach(nav);
      final app = _starting();
      await tester.pumpWidget(_App(nav: nav, app: app));
      expect(find.text('HOME'), findsOneWidget);
      // MainActivity.onNewIntent -> "callLaunch"
      CallLaunchRouter.instance.onNative({
        'action': 'accept',
        'call_id': '501',
        'payload': _p().encode(),
      });
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      expect(CallLaunchRouter.instance.decisions.last,
          contains('entry=warmAccept action=accept id=501 result=top=call'));
      // flutter_local_notifications' onDidReceiveNotificationResponse copy
      CallLaunchRouter.instance.onNative({
        'action': 'accept',
        'call_id': '501',
        'payload': _p().encode(),
      });
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(CallLaunchRouter.instance.decisions.last, contains('duplicate'));
      await _finish(tester, app);
    });

    testWidgets('lock screen: full-screen ringing screen up, then Accept from '
        'the notification -> that screen answers (one screen, no "Call ended")',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallLaunchRouter.instance.attach(nav);
      final app = _starting();
      await tester.pumpWidget(_App(nav: nav, app: app));
      CallLaunchRouter.instance
          .openWarm(CallLaunch(action: 'open', payload: _p()));
      await tester.pump();
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      CallLaunchRouter.instance
          .openWarm(CallLaunch(action: 'accept', payload: _p()));
      await tester.pump();
      expect(find.byType(IncomingCallScreen), findsNothing);
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(CallLaunchRouter.instance.decisions.join('\n'),
          contains('entry=warmAccept action=accept id=501 result=ringing_screen_accept'));
      // the caller's "answered elsewhere" cancel arrives late: no ended frame
      CallRuntime.instance.onPushCancel(_p());
      await tester.pump(const Duration(milliseconds: 300));
      final t = lookupAppLocalizations(const Locale('en'));
      expect(find.text(t.pushCallEnded), findsNothing);
      await _finish(tester, app);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('FOREGROUND: in-app ring -> Accept -> call; a later tap on '
        'the notification Accept is ignored', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallLaunchRouter.instance.attach(nav);
      CallRuntime.instance.attachNavigator(nav);
      final app = _starting();
      await tester.pumpWidget(_App(nav: nav, app: app));
      CallRuntime.instance.onIncoming(
          {'call_id': '501', 'caller_name': 'Nadia Rahman', 'chat_id': '7'});
      await tester.pump();
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      // the real-time queue + a resume check list it again: no second ring
      CallRuntime.instance.onIncoming({'call_id': '501'});
      await tester.pump();
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('incoming-accept')));
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsOneWidget);
      CallLaunchRouter.instance
          .openWarm(CallLaunch(action: 'accept', payload: _p()));
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(CallLaunchRouter.instance.decisions.last, contains('duplicate'));
      await _finish(tester, app);
    });

    testWidgets('no navigator yet -> not swallowed (the old path still runs)',
        (tester) async {
      expect(
          CallLaunchRouter.instance
              .openWarm(CallLaunch(action: 'accept', payload: _p())),
          isFalse);
      expect(CallLaunchRouter.instance.handled('501'), isFalse);
    });
  });

  group('CI fix 1: opening the ringing screen keeps the phone ringing', () {
    Future<void> openFromNotification(WidgetTester tester, AppState app,
        GlobalKey<NavigatorState> nav) async {
      CallLaunchRouter.instance.attach(nav);
      await tester.pumpWidget(_App(nav: nav, app: app));
      // full-screen intent / tap while the app runs (lock screen, warm)
      CallLaunchRouter.instance
          .openWarm(CallLaunch(action: 'open', payload: _p()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // let every platform-channel round trip finish (a cancel would land)
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(find.byType(IncomingCallScreen), findsOneWidget);
    }

    testWidgets('native ring still posted -> it is KEPT (never cancelled on '
        '"open"), no second in-app ringtone', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final app = _starting();
      await openFromNotification(tester, app, nav);
      expect(nativeCalls, contains('ringActive:501'));
      expect(nativeCalls.where((c) => c.startsWith('cancelRing')), isEmpty,
          reason: 'before the fix the open path cancelled the ring');
      expect(nativeCalls.where((c) => c.startsWith('startRingtone')), isEmpty);
      final st = tester.state(find.byType(IncomingCallScreen));
      expect((st as dynamic).ringingInApp, isFalse);
      // Accept: NOW the ring stops
      await tester.tap(find.byKey(const Key('incoming-accept')));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(nativeCalls, contains('cancelRing:501'));
      await _finish(tester, app);
    });

    testWidgets('native ring gone (OEM dropped it) -> rings IN-APP, never a '
        'silent ringing screen; Decline stops everything', (tester) async {
      nativeRingActive = false;
      final nav = GlobalKey<NavigatorState>();
      final app = _starting();
      await openFromNotification(tester, app, nav);
      await tester.pump(const Duration(milliseconds: 50));
      expect(nativeCalls.any((c) => c.startsWith('startRingtone')), isTrue);
      final st = tester.state(find.byType(IncomingCallScreen));
      expect((st as dynamic).ringingInApp, isTrue);
      await tester.tap(find.byKey(const Key('incoming-decline')));
      await tester.pumpAndSettle();
      expect(nativeCalls, contains('stopRingtone:'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(nativeCalls, contains('cancelRing:501'));
      expect(find.byType(IncomingCallScreen), findsNothing);
      await _finish(tester, app);
    });

    testWidgets('caller hangs up / rings out while the screen is up -> the '
        'native ring is stopped too', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final app = _starting();
      await openFromNotification(tester, app, nav);
      CallRuntime.instance.onPushCancel(_p());
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(nativeCalls, contains('cancelRing:501'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(IncomingCallScreen), findsNothing);
      await _finish(tester, app);
    });

    testWidgets('notification TAP response (flutter_local_notifications) '
        'never cancels the ring; its Accept does', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallLaunchRouter.instance.attach(nav);
      final app = _starting();
      await tester.pumpWidget(_App(nav: nav, app: app));
      PushService.instance.resetForTest();
      PushService.instance.localResponseForTest(NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotification,
          payload: _p().encode()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(find.byType(IncomingCallScreen), findsOneWidget);
      expect(nativeCalls.where((c) => c.startsWith('cancelRing')), isEmpty);
      PushService.instance.localResponseForTest(NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: 'accept',
          payload: _p().encode()));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(nativeCalls, contains('cancelRing:501'));
      expect(find.byType(CircleCallScreen), findsOneWidget);
      PushService.instance.resetForTest();
      await _finish(tester, app);
    });

    test('native contract: only ACCEPT answers Telecom / cancels the ring', () {
      final a = File('android_overlay/app/src/main/kotlin/com/assisto/assisto/'
              'MainActivity.kt')
          .readAsStringSync();
      final i = a.indexOf('TelecomBridge.answered(callId)');
      expect(i, greaterThan(0));
      final guard = a.substring(a.lastIndexOf('if (isCall', i), i);
      expect(guard, contains('IncomingCall.ACTION_ACCEPT'),
          reason: 'a tap / full-screen "open" must keep the native ring');
      expect(guard, contains('FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY'));
    });
  });

  group('CI fix 2: warm Accept re-uses the running activity (API 30)', () {
    test('CallEntryActivity sets its own flags (no copied EXCLUDE_FROM_RECENTS) '
        'with CLEAR_TOP + SINGLE_TOP so MainActivity gets onNewIntent', () {
      final k = File('android_overlay/app/src/main/kotlin/com/assisto/assisto/'
              'calls/CallEntryActivity.kt')
          .readAsStringSync();
      final m = RegExp(r'fwd\.flags\s*=\s*([^\n]+\n[^\n]+)').firstMatch(k);
      expect(m, isNotNull, reason: 'flags must be SET, not added to a copy');
      final f = m!.group(1)!;
      expect(f, contains('FLAG_ACTIVITY_NEW_TASK'));
      expect(f, contains('FLAG_ACTIVITY_CLEAR_TOP'));
      expect(f, contains('FLAG_ACTIVITY_SINGLE_TOP'));
      expect(k, isNot(contains('.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)')));
    });

    testWidgets('a warm Accept that arrives on the running engine opens the '
        'call screen (native "callLaunch" handler, Dart side)', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallLaunchRouter.instance.attach(nav);
      CallNative.onCallLaunch = CallLaunchRouter.instance.onNative;
      CallNative.listen();
      final app = _starting();
      await tester.pumpWidget(_App(nav: nav, app: app));
      // exactly what CallsChannel.sendCallLaunch posts to Dart
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              'com.assisto/calls',
              const StandardMethodCodec().encodeMethodCall(MethodCall(
                  'callLaunch', {
                'action': 'accept',
                'call_id': '501',
                'payload': _p().encode(),
              })),
              (_) {});
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsOneWidget);
      expect(CallLaunchRouter.instance.decisions.last,
          contains('entry=warmAccept action=accept id=501 result=top=call'));
      await _finish(tester, app);
    });
  });

  group('Item 2: use Assisto during a call', () {
    OngoingCall minimized({bool video = true}) {
      final c = previewController(
          video: video, outgoing: false, phase: CallPhase.connected);
      final o = OngoingCall(
          controller: c,
          surface: video ? FakeSurface() : null,
          member: const {'id': 7, 'name': 'Nadia'},
          kind: video ? 'video' : 'voice');
      CallRuntime.instance.minimize(o);
      return o;
    }

    testWidgets('green bar + floating video on EVERY route; reply in a chat '
        'while the video call runs; the controller never dies', (tester) async {
      tester.view.physicalSize = const Size(360, 800) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      CallRuntime.instance.attachNavigator(nav);
      await tester.pumpWidget(_App(nav: nav, app: _signedOut()));
      final o = minimized();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('call-mini-bar')), findsOneWidget);
      expect(find.byKey(const Key('call-float')), findsOneWidget);
      // the bar never hides the status bar area of the screen below: the
      // route's own padding top is consumed by the bar
      final barBox = tester.getRect(find.byKey(const Key('call-mini-bar')));
      expect(barBox.top, 0);
      expect(barBox.height, greaterThanOrEqualTo(48));
      final appBar = tester.getRect(find.byType(AppBar));
      expect(appBar.top, greaterThanOrEqualTo(barBox.bottom - 0.5));

      // open a chat and reply while the call continues
      await tester.tap(find.text('open chat'));
      await tester.pumpAndSettle();
      expect(find.text('chat Rahim'), findsOneWidget);
      expect(find.byKey(const Key('call-mini-bar')), findsOneWidget);
      expect(find.byKey(const Key('call-float')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('chat-input')), 'on a call, 2 min');
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump();
      expect(find.text('on a call, 2 min'), findsOneWidget);
      expect(o.controller.isEnded, isFalse);
      expect(CallRuntime.instance.ongoing.value, same(o));

      // tap the floating window -> the full call, SAME controller
      await tester.tap(find.byKey(const Key('call-float')));
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsOneWidget);
      final screen =
          tester.widget<CircleCallScreen>(find.byType(CircleCallScreen));
      expect(screen.controller, same(o.controller));
      expect(screen.resumed, isTrue);
      await tester.pump();
      expect(find.byKey(const Key('call-mini-bar')), findsNothing);
      expect(find.byKey(const Key('call-float')), findsNothing);
      // minimize again -> back on the chat, bar + float back, still live
      await tester.tap(find.byKey(const Key('call-minimize')));
      await tester.pumpAndSettle();
      expect(find.text('chat Rahim'), findsOneWidget);
      expect(find.text('on a call, 2 min'), findsOneWidget,
          reason: 'the chat kept its state under the call');
      expect(find.byKey(const Key('call-float')), findsOneWidget);
      expect(o.controller.isEnded, isFalse);
      // hang up from the bar: everything goes
      await tester.tap(find.byKey(const Key('call-mini-hangup')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('call-mini-bar')), findsNothing);
      expect(find.byKey(const Key('call-float')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('floating window: drag moves it, it settles at a side and '
        'never leaves the screen; TalkBack names it', (tester) async {
      tester.view.physicalSize = const Size(360, 800) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_App(nav: nav, app: _signedOut(),
          locale: const Locale('bn')));
      minimized();
      await tester.pump();
      await tester.pump();
      final f = find.byKey(const Key('call-float'));
      final r0 = tester.getRect(f);
      expect(r0.right, lessThanOrEqualTo(360));
      expect(r0.width, greaterThanOrEqualTo(48));
      // drag to the left half -> settles on the LEFT side
      await tester.drag(f, const Offset(-220, 300));
      await tester.pumpAndSettle();
      final r1 = tester.getRect(f);
      expect(r1.left, lessThan(40));
      expect(r1.top, greaterThan(r0.top + 200));
      // fling far off-screen -> clamped inside
      await tester.drag(f, const Offset(900, 2000));
      await tester.pumpAndSettle();
      final r2 = tester.getRect(f);
      expect(r2.right, lessThanOrEqualTo(360));
      expect(r2.bottom, lessThanOrEqualTo(800));
      final t = lookupAppLocalizations(const Locale('bn'));
      expect(find.bySemanticsLabel(t.callsAFloatLabel('Nadia')), findsOneWidget);
    });

    testWidgets('voice call: bar only (no floating window)', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_App(nav: nav, app: _signedOut()));
      minimized(video: false);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('call-mini-bar')), findsOneWidget);
      expect(find.byKey(const Key('call-float')), findsNothing);
    });

    testWidgets('left the app during a minimized video call: system PiP shows '
        'only the video; the app underneath keeps its state', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallRuntime.instance.attachNavigator(nav);
      // In the app the call screen registers this before any minimize; here
      // the call is minimized directly, so register it (test-order safe).
      CircleCallScreen.registerReopen();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(_App(nav: nav, app: _signedOut()));
      final o = minimized();
      await tester.pump();
      await tester.tap(find.text('open chat'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('chat-input')), 'draft');
      CallNative.inPip.value = true;
      await tester.pump();
      expect(find.byKey(const Key('call-pip-view')), findsOneWidget);
      expect(find.byKey(const Key('call-mini-bar')), findsNothing);
      expect(find.text('chat Rahim'), findsNothing, reason: 'offstage in PiP');
      CallNative.inPip.value = false;
      await tester.pump();
      expect(find.byKey(const Key('call-pip-view')), findsNothing);
      expect(find.text('draft'), findsOneWidget, reason: 'state kept');
      // PiP window tapped back to full size (app resumed) -> the full call
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final screen =
          tester.widget<CircleCallScreen>(find.byType(CircleCallScreen));
      expect(screen.controller, same(o.controller));
    });

    testWidgets('an ENDED minimized call is never re-opened (no stale "Call '
        'ended" screen)', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      CallRuntime.instance.attachNavigator(nav);
      await tester.pumpWidget(_App(nav: nav, app: _signedOut()));
      final o = minimized();
      await tester.pump();
      o.controller.phase = CallPhase.ended;
      CallRuntime.instance.restoreOngoing();
      await tester.pump();
      expect(find.byType(CircleCallScreen), findsNothing);
      expect(CallRuntime.instance.ongoing.value, isNull);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
