// Owner idea 1 — guardian-requested journey on the phone (fake server, plain
// maps only): one-tap accept / decline, sharing starts by itself when the
// app is open in an accepted window, one-tap stop, the always-visible
// "<name> is watching" banner on the live trip, the empty state, and the
// ask form (child school mode only for a confirmed child, under-18 confirm).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/guardian_journey_screen.dart';
import 'package:assisto/screens/guardian_request_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final posts = <String, Map<String, dynamic>>{};
  Map<String, dynamic> data = {'incoming': [], 'outgoing': [], 'history': [], 'people': []};
  Map<String, dynamic> active = {};

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/journey/requests') return data;
    if (path == '/journey/active') return active;
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts[path] = body;
    if (path.endsWith('/location')) return {'status': 'active', 'overdue_state': 'on_time'};
    if (path == '/journey/requests') return {'id': 3, 'status': 'pending'};
    return {'id': 1, 'status': 'ok', 'journey_id': null};
  }
}

Map<String, dynamic> _req(String status, {bool inWindow = false, bool standing = false}) => {
      'id': 1, 'role': 'traveller', 'name': 'Baba', 'status': status, 'outcome': '',
      'destination': {'name': 'Chattogram'}, 'note': 'Call me',
      'window_start': DateTime.now().toIso8601String(),
      'window_end': DateTime.now().add(const Duration(hours: 6)).toIso8601String(),
      'standing': standing, 'schedule': const {}, 'in_window': inWindow,
      'journey_id': status == 'active' ? 9 : null, 'log': const [],
    };

final _nav = GlobalKey<NavigatorState>();

Future<void> _open(WidgetTester tester, _Api api, Widget w, {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final s = AppState()
    ..api = api
    ..user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      navigatorKey: _nav,
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: Text('below')),
    ),
  ));
  unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => w)));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

late AppLocalizations en, bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async => call.method == 'checkPermission' ? 2 : null);
  });

  testWidgets('asked of me: one-tap accept, consent note, decline', (tester) async {
    final api = _Api()..data = {..._Api().data, 'incoming': [_req('pending')]};
    await _open(tester, api, const GuardianJourneyScreen());
    expect(find.text(en.gjAsk('Baba')), findsOneWidget);
    expect(find.text(en.gjConsentNote), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gj_accept_1')));
    await _settle(tester);
    expect(api.posts.containsKey('/journey/requests/1/accept'), isTrue);
    expect(find.text(en.gjAccepted), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('app open in an accepted window: sharing starts by itself', (tester) async {
    final api = _Api()..data = {..._Api().data, 'incoming': [_req('accepted', inWindow: true)]};
    await _open(tester, api, const GuardianJourneyScreen());
    expect(api.posts.containsKey('/journey/requests/1/start'), isTrue);
    expect(find.text(en.gjAutoStartNote), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('running: who is watching + one-tap stop (no PIN)', (tester) async {
    final api = _Api()..data = {..._Api().data, 'incoming': [_req('active')]};
    await _open(tester, api, const GuardianJourneyScreen());
    expect(find.text(en.gjWatchingYou('Baba')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gj_stop_1')));
    await _settle(tester);
    expect(api.posts.containsKey('/journey/requests/1/stop'), isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('empty: benefit, how it works, a big ask button', (tester) async {
    await _open(tester, _Api(), const GuardianJourneyScreen());
    expect(find.text(en.gjEmptyTitle), findsOneWidget);
    expect(find.text(en.gjEmptyHow), findsOneWidget);
    expect(find.byKey(const ValueKey('gj_ask')), findsOneWidget);
    expect(find.text(en.gjFreeNote), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ask form: school mode only for a confirmed child, under-18 confirm', (tester) async {
    final api = _Api();
    final people = [
      {'member_id': 4, 'name': 'Rina', 'relation': 'child', 'child': true},
      {'member_id': 5, 'name': 'Karim', 'relation': 'friend', 'child': false},
    ];
    await _open(tester, api, GuardianRequestScreen(people: people));
    await tester.tap(find.byKey(const ValueKey('gj_person_5')));
    await _settle(tester, 3);
    expect(find.byKey(const ValueKey('gj_school')), findsNothing);    // adult: never
    await tester.tap(find.byKey(const ValueKey('gj_person_4')));
    await _settle(tester, 3);
    expect(find.byKey(const ValueKey('gj_school')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('gj_dest')), 'School');
    await tester.tap(find.byKey(const ValueKey('gj_school')));
    await _settle(tester, 3);
    await tester.ensureVisible(find.byKey(const ValueKey('gj_send')));
    await tester.tap(find.byKey(const ValueKey('gj_send')));
    await _settle(tester, 3);
    expect(api.posts.containsKey('/journey/requests'), isFalse);       // minor not confirmed
    expect(find.text(en.gjNeedMinor), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gj_minor')));
    await _settle(tester, 3);
    await tester.ensureVisible(find.byKey(const ValueKey('gj_send')));
    await tester.tap(find.byKey(const ValueKey('gj_send')));
    await _settle(tester, 6);
    final b = api.posts['/journey/requests']!;
    expect((b['standing'], b['minor_declared'], b['member_id']), (true, true, 4));
    expect((b['schedule'] as Map)['days'], isNotEmpty);
  });

  testWidgets('ask form for an adult sends one window', (tester) async {
    final api = _Api();
    await _open(tester, api, const GuardianRequestScreen(people: [
      {'member_id': 5, 'name': 'Karim', 'relation': 'friend', 'child': false},
    ]));
    await tester.tap(find.byKey(const ValueKey('gj_person_5')));
    await tester.enterText(find.byKey(const ValueKey('gj_dest')), 'Chattogram');
    await tester.ensureVisible(find.byKey(const ValueKey('gj_send')));
    await tester.tap(find.byKey(const ValueKey('gj_send')));
    await _settle(tester, 6);
    final b = api.posts['/journey/requests']!;
    expect(b.containsKey('standing'), isFalse);
    expect(DateTime.parse('${b['end']}').isAfter(DateTime.parse('${b['start']}')), isTrue);
  });

  testWidgets('live trip: the banner names who is watching, in Bangla, one-tap stop',
      (tester) async {
    final api = _Api()
      ..active = {
        'id': 9, 'status': 'active', 'destination': {'name': 'Chattogram'},
        'eta': DateTime.now().add(const Duration(hours: 2)).toIso8601String(),
        'pin_required': true, 'extend_left': 6,
        'guardian': {'request_id': 1, 'name': 'Baba', 'standing': false},
      };
    final tr = JourneyTracker(
        useService: false, position: () async => (lat: 23.7, lng: 90.4), battery: () async => 80);
    await _open(tester, api, JourneyLiveScreen(journeyId: 9, tracker: tr), lang: 'bn');
    expect(find.text(bn.gjWatchingYou('Baba')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gj_banner_stop')));
    await _settle(tester);
    expect(api.posts.containsKey('/journey/requests/1/stop'), isTrue);   // no PIN asked
    await tr.stop();
    await tester.pumpWidget(const SizedBox());
  });
}
