// ty1 — My Circle's live loop, end to end on the device side:
//   server queue (GET /rt/events) -> PollRealtimeTransport (CallRuntime)
//   -> RealtimeChannel -> the chat header says "typing…", then clears;
//   server queue call.incoming -> the in-app incoming-call screen (no FCM)
//   -> "ringing" acked to the server (or the caller ends "offline" at 20 s).
//
// Root cause (reality 18_circle_real_call / 19_circle_ticks): this loop is
// started by PushService.start in lib/main.dart's deferred init. Startup SAFE
// MODE skipped it completely, and the reality harness (which pumps AssistoApp
// without main()) never started it. PushService.start(realtimeOnly: true)
// now runs the pure-Dart loop without Firebase; a re-boot with a new
// AppState re-binds instead of watching the old one.
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/receipt_bus.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_service.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake server: one real-time queue (rt/events semantics: events after
/// `after`, `seq` = latest) plus the few endpoints the screens touch.
class _Server extends ApiClient {
  _Server(this.label) {
    token = 'tok-$label';
  }
  final String label;
  final List<Map<String, dynamic>> queue = [];
  final List<String> gets = [];
  final List<(String, Map<String, dynamic>)> posts = [];
  int _seq = 100;

  void publish(String topic, Map<String, dynamic> payload) => queue.add(
      {'seq': ++_seq, 'topic': topic, 'payload': payload, 'ts': DateTime.now().toUtc().toIso8601String()});

  int get rtPolls => gets.where((g) => g.startsWith('/rt/events')).length;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path.startsWith('/rt/events')) {
      final after =
          int.tryParse(Uri.parse('http://x$path').queryParameters['after'] ?? '') ?? 0;
      return {
        'events': [for (final e in queue) if ((e['seq'] as int) > after) e],
        'seq': _seq,
        'more': false,
      };
    }
    if (path.split('?').first == '/circle/4/messages') {
      return {'results': const [], 'has_more': false};
    }
    if (path.startsWith('/circle/rt/state')) return {'chats': const {}};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    return {'ok': true};
  }
}

AppState _signedIn(ApiClient api) => AppState()
  ..api = api
  ..loading = false
  ..user = AppUser(id: 1, name: 'Rahim', autonomyLevel: 2, language: 'en');

Widget _shell(AppState app, {Widget? home}) => ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('bn')],
        home: home ?? const Scaffold(body: Text('home')),
      ),
    );

void _reset() {
  PushService.instance.resetForTest();
  CallRuntime.instance.resetForTest();
  RealtimeChannel.instance.resetForTest();
  ReceiptBus.instance.reset();
}

void main() {
  late AppLocalizations t;
  setUpAll(() async {
    await initializeDateFormatting('en');
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({'push_perm_asked_v1': true});
    _reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.assisto/lockscreen'),
            (c) async => null);
  });
  tearDown(() {
    _reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.assisto/lockscreen'), null);
  });

  Future<void> poll(WidgetTester tester) async {
    // idle interval without FCM is 2.5 s
    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('B types -> A\'s chat header says "typing…", then it clears',
      (tester) async {
    final api = _Server('a');
    final app = _signedIn(api);
    final e2e = SoftwareE2E();
    final me = e2e.generateIdentity();
    final peer = e2e.generateIdentity();
    await tester.pumpWidget(_shell(app,
        home: CircleChatScreen(
            member: {'id': 4, 'name': 'Karim', 'public_key': base64Encode(peer.publicKey)},
            identity: me)));
    await tester.pump(const Duration(milliseconds: 100));

    // safe mode / reality harness start: no Firebase, the loop still runs
    await PushService.instance.start(app, realtimeOnly: true);
    expect(PushService.instance.available.value, isFalse);
    expect(RealtimeChannel.instance.hasTransport, isTrue,
        reason: 'typing/online need the shared loop');
    await poll(tester);
    expect(api.rtPolls, greaterThan(0));
    expect(find.text(t.c3Typing), findsNothing);

    // the server fans B's typing.set out to A with A's chat key
    api.publish('typing.update',
        {'chat': 'member:4', 'activity': 'typing', 'who': '', 'ttl_s': 8});
    await poll(tester);
    expect(find.text(t.c3Typing), findsWidgets,
        reason: 'header line 2 (and the in-thread indicator) say typing…');

    api.publish('typing.update',
        {'chat': 'member:4', 'activity': '', 'who': '', 'ttl_s': 8});
    await poll(tester);
    expect(find.text(t.c3Typing), findsNothing, reason: 'stop clears it');

    // a lost "stop" (phone died) still clears after the TTL
    api.publish('typing.update',
        {'chat': 'member:4', 'activity': 'typing', 'who': '', 'ttl_s': 3});
    await poll(tester);
    expect(find.text(t.c3Typing), findsWidgets);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(t.c3Typing), findsNothing, reason: 'TTL expiry');

    // another chat's typing never shows here
    api.publish('typing.update',
        {'chat': 'member:9', 'activity': 'typing', 'who': '', 'ttl_s': 8});
    await poll(tester);
    expect(find.text(t.c3Typing), findsNothing);

    await tester.pumpWidget(const SizedBox());
    _reset(); // stops the shared poll timer
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('B calls -> A\'s in-app incoming screen (no FCM) + "ringing" ack',
      (tester) async {
    final api = _Server('a');
    final app = _signedIn(api);
    await tester.pumpWidget(_shell(app));
    await PushService.instance.start(app, realtimeOnly: true);
    await poll(tester);
    expect(find.byType(IncomingCallScreen), findsNothing);

    api.publish('call.incoming', {
      'call_id': 77,
      'caller_name': 'Reality Karim',
      'caller_id': 2,
      'video': true,
      'chat_id': 4,
    });
    await poll(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(IncomingCallScreen), findsOneWidget);
    expect(find.text('Reality Karim'), findsWidgets);
    // the caller's 20 s OFFLINE_ACK window is met: the phone said "ringing"
    expect(
        api.posts.any((p) =>
            p.$1 == '/circle/calls/77/event' && p.$2['event'] == 'ringing'),
        isTrue);

    // the same call is never stacked twice
    api.publish('call.incoming', {'call_id': 77, 'caller_name': 'Reality Karim'});
    await poll(tester);
    expect(find.byType(IncomingCallScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    _reset(); // stops the shared poll timer
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('a re-boot with a NEW AppState re-binds the loop to it',
      (tester) async {
    final api1 = _Server('one');
    final app1 = _signedIn(api1);
    await tester.pumpWidget(_shell(app1));
    await PushService.instance.start(app1, realtimeOnly: true);
    await poll(tester);
    final before = api1.rtPolls;
    expect(before, greaterThan(0));

    // "close and reopen": a fresh AppState (same storage, new client)
    final api2 = _Server('two');
    final app2 = _signedIn(api2);
    await tester.pumpWidget(_shell(app2));
    await PushService.instance.start(app2, realtimeOnly: true);
    expect(CallRuntime.instance.boundApp, same(app2));
    await poll(tester);
    await poll(tester);
    expect(api2.rtPolls, greaterThan(0), reason: 'polls the new session');
    expect(api1.rtPolls, before, reason: 'the old session is no longer polled');

    // and the ring follows the new session
    api2.publish('call.incoming', {'call_id': 5, 'caller_name': 'Karim', 'video': false});
    await poll(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(IncomingCallScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    _reset(); // stops the shared poll timer
    await tester.pump(const Duration(seconds: 61));
  });
}
