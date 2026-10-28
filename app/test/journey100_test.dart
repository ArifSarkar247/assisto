// journey100: Safe Journey on the phone (fake server, no plugins):
// start -> live -> arrive, the offline store-and-forward queue, the user-tapped
// SMS fallback composer, the duress PIN (looks exactly like a normal stop),
// a wrong PIN keeps the journey, "Are you OK?" -> I'm OK, the fake call, and
// the watcher list's honest states.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_fake_call_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

class _Hit {
  final String method, path;
  final Map<String, dynamic> body;
  _Hit(this.method, this.path, this.body);
}

class _JApi extends ApiClient {
  _JApi() {
    token = 'test-token';
  }
  final hits = <_Hit>[];
  Map<String, dynamic> active = {
    'id': 5,
    'status': 'active',
    'destination': {'name': 'Home'},
    'eta': DateTime.now().add(const Duration(minutes: 30)).toIso8601String(),
    'pin_required': false,
    'extend_left': 6,
  };
  Map<String, dynamic> Function(Map<String, dynamic> body)? onLocation;
  Object? stopError;
  List<Map<String, dynamic>> watching = [];
  bool watchFails = false;
  Map<String, dynamic> circle = {'results': []};

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    hits.add(_Hit('GET', path, const {}));
    if (path == '/journey/active') return active;
    if (path == '/circle/members') return circle;
    if (path == '/journey/watching') {
      if (watchFails) throw ApiException('down', 500);
      return {'journeys': watching};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    hits.add(_Hit('POST', path, body));
    if (path.endsWith('/location')) {
      return onLocation?.call(body) ?? {'status': 'active', 'overdue_state': 'on_time'};
    }
    // the start form test only checks what is SENT; failing here keeps the
    // real live screen (tracker, plugins) out of the widget test
    if (path == '/journey/start') throw ApiException('test: not started', 500);
    if (path.endsWith('/stop') && stopError != null) throw stopError!;
    if (path.endsWith('/stop')) return {'ok': true, 'outcome': 'cancel', 'status': 'stopped'};
    return {'ok': true};
  }

  List<_Hit> posts(String suffix) =>
      hits.where((h) => h.method == 'POST' && h.path.endsWith(suffix)).toList();
}

final _nav = GlobalKey<NavigatorState>();

Widget _app(_JApi api, {String lang = 'en', bool dark = false}) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      navigatorKey: _nav,
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: Text('below')),
    ),
  );
}

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

JourneyTracker _tracker({bool locationOn = true, int? battery = 80}) => JourneyTracker(
    useService: false,
    position: () async => locationOn ? (lat: 23.76, lng: 90.39) : null,
    battery: () async => battery);

Future<void> _openLive(WidgetTester tester, _JApi api, JourneyTracker tr,
    {String lang = 'en'}) async {
  await tester.pumpWidget(_app(api, lang: lang));
  unawaited(_nav.currentState!.push(MaterialPageRoute(
      builder: (_) => JourneyLiveScreen(journeyId: 5, tracker: tr))));
  await _settle(tester);
}

late AppLocalizations en;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
  });

  group('offline queue', () {
    test('caps, acks and survives a round trip', () {
      final q = JourneyFixQueue();
      for (var i = 0; i < kMaxQueue + 5; i++) {
        q.add(JourneyFix(23.0 + i / 1000, 90, DateTime.utc(2026, 1, 1, 0, 0, i % 60), 50));
      }
      expect(q.items.length, kMaxQueue);
      expect(q.items.first.lat, closeTo(23.005, 1e-9)); // oldest dropped
      final back = JourneyFixQueue.decode(q.encode());
      expect(back.items.length, kMaxQueue);
      expect(back.items.first.battery, 50);
      back.ack(10);
      expect(back.items.length, kMaxQueue - 10);
      expect(JourneyFixQueue.decode('not json').items, isEmpty);
    });

    test('tracker keeps fixes while offline and sends them as one batch later', () async {
      var online = false;
      final sent = <List<Map<String, dynamic>>>[];
      var now = DateTime(2026, 10, 27, 20, 0);
      final tr = JourneyTracker(
          useService: false,
          clock: () => now,
          position: () async => (lat: 23.76, lng: 90.39),
          battery: () async => 12);
      await tr.start(9, (id, pts) async {
        if (!online) throw ApiException('offline');
        sent.add(pts);
        return {'status': 'active', 'overdue_state': 'on_time'};
      });
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 31));
        await tr.tick();
      }
      expect(tr.value.net, JourneyNet.offline);
      expect(tr.value.queued, greaterThanOrEqualTo(3));
      expect(sent, isEmpty);
      online = true;
      now = now.add(const Duration(seconds: 31));
      await tr.tick();
      expect(tr.value.net, JourneyNet.ok);
      expect(tr.value.queued, 0);
      expect(sent.single.length, greaterThanOrEqualTo(4)); // all queued + new
      expect(sent.single.first['battery'], 12); // low battery rides along
      expect(tr.value.lastSentAt, isNotNull);
      await tr.stop();
    });

    test('server says arrived -> tracker stops itself', () async {
      final tr = _tracker();
      await tr.start(9, (id, pts) async => {'status': 'arrived'});
      await tr.tick();
      expect(tr.running, isFalse);
      expect(tr.value.status, 'arrived');
    });

    test('location off is honest, nothing is invented', () async {
      final tr = _tracker(locationOn: false);
      var calls = 0;
      await tr.start(9, (id, pts) async {
        calls++;
        return {'status': 'active'};
      });
      await tr.tick();
      expect(tr.value.locationOff, isTrue);
      expect(calls, 0);
      await tr.stop();
    });
  });

  test('SMS fallback composer: user-tapped sms: link, no SEND_SMS', () {
    final u = journeySmsUri(['+880 1711-000002', '01711000003', 'x'],
        'Help me: https://maps.google.com/?q=23.7,90.4 (at 9:05 PM)');
    expect(u.scheme, 'sms');
    final s = u.toString();
    expect(s, startsWith('sms:+8801711000002,01711000003?body='));
    expect(s, isNot(contains('+(at'))); // spaces are %20, never '+'
    expect(Uri.decodeComponent(s.split('body=')[1]),
        'Help me: https://maps.google.com/?q=23.7,90.4 (at 9:05 PM)');
    expect(journeyMapsLink(23.7, 90.4), 'https://maps.google.com/?q=23.700000,90.400000');
  });

  testWidgets('start -> live -> I have arrived', (tester) async {
    final api = _JApi();
    final tr = _tracker();
    await _openLive(tester, api, tr);
    expect(find.text(en.j100Sharing), findsOneWidget);
    expect(find.text(en.journeyToward('Home')), findsOneWidget);
    expect(api.posts('/journey/5/location').single.body['points'], isA<List>());
    await tester.ensureVisible(find.byKey(const ValueKey('j100_arrived')));
    await tester.tap(find.byKey(const ValueKey('j100_arrived')));
    await _settle(tester);
    expect(api.posts('/journey/5/arrived'), hasLength(1));
    expect(find.byType(JourneyLiveScreen), findsNothing);
    expect(tr.running, isFalse);
  });

  testWidgets('offline: N saved + the SMS button', (tester) async {
    final api = _JApi()..onLocation = (_) => throw ApiException('offline');
    final tr = _tracker();
    await _openLive(tester, api, tr);
    expect(find.text(en.j100OfflineTitle), findsOneWidget);
    expect(find.text(en.j100OfflineBody(1)), findsOneWidget);
    expect(find.byKey(const ValueKey('j100_sms')), findsOneWidget);
    await tr.stop();
  });

  testWidgets('late: Are you OK? -> I am OK reaches the server', (tester) async {
    final api = _JApi()
      ..onLocation = (_) => {'status': 'active', 'overdue_state': 'ask'};
    final tr = _tracker();
    await _openLive(tester, api, tr);
    expect(find.text(en.journeyAreYouOkTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('j100_im_ok')));
    await _settle(tester);
    expect(api.posts('/journey/5/respond'), hasLength(1));
    await tr.stop();
  });

  testWidgets('duress PIN stop looks exactly like a normal stop', (tester) async {
    for (final pin in ['1234', '9876']) {
      final api = _JApi()..active = {..._JApi().active, 'pin_required': true};
      final tr = _tracker();
      await _openLive(tester, api, tr);
      await tester.ensureVisible(find.byKey(const ValueKey('j100_stop')));
      await tester.tap(find.byKey(const ValueKey('j100_stop')));
      await _settle(tester);
      expect(find.text(en.sosPinTitle), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, pin);
      await tester.tap(find.byKey(const ValueKey('j100_pin_ok')));
      await _settle(tester);
      expect(api.posts('/journey/5/stop').single.body['pin'], pin);
      // same screen result for both: closed, no message that could give it away
      expect(find.byType(JourneyLiveScreen), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tr.running, isFalse);
    }
  });

  testWidgets('wrong PIN keeps the journey running', (tester) async {
    final api = _JApi()
      ..active = {..._JApi().active, 'pin_required': true}
      ..stopError = ApiException('wrong', 400);
    final tr = _tracker();
    await _openLive(tester, api, tr);
    await tester.ensureVisible(find.byKey(const ValueKey('j100_stop')));
    await tester.tap(find.byKey(const ValueKey('j100_stop')));
    await _settle(tester);
    await tester.enterText(find.byType(TextField).last, '0000');
    await tester.tap(find.byKey(const ValueKey('j100_pin_ok')));
    await _settle(tester);
    expect(find.text(en.sosPinWrong), findsOneWidget);
    expect(find.byType(JourneyLiveScreen), findsOneWidget);
    expect(tr.running, isTrue);
    await tr.stop();
  });

  testWidgets('more time: sheet -> server', (tester) async {
    final api = _JApi();
    final tr = _tracker();
    await _openLive(tester, api, tr);
    await tester.ensureVisible(find.byKey(const ValueKey('j100_extend')));
    await tester.tap(find.byKey(const ValueKey('j100_extend')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('j100_extend_15')));
    await _settle(tester);
    expect(api.posts('/journey/5/extend').single.body['minutes'], 15);
    expect(find.text(en.j100Extended), findsOneWidget);
    await tr.stop();
  });

  testWidgets('fake call rings, answers, counts, ends', (tester) async {
    await tester.pumpWidget(_app(_JApi()));
    unawaited(_nav.currentState!.push(MaterialPageRoute(
        builder: (_) => const JourneyFakeCallScreen(caller: 'Mom', delaySeconds: 2))));
    await _settle(tester, 5);
    expect(find.text(en.fakeCallArmed(2)), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester, 3);
    expect(find.text('Mom'), findsOneWidget);
    expect(find.text(en.fakeCallIncoming), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('j100_fake_answer')));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('00:03'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('j100_fake_end')));
    await _settle(tester);
    expect(find.byType(JourneyFakeCallScreen), findsNothing);
  });

  testWidgets('watcher list: live, lost, SOS, empty and error states', (tester) async {
    final api = _JApi()
      ..watching = [
        {'id': 1, 'name': 'Rina', 'status': 'active', 'sos': false, 'destination': 'Home',
         'lat': 23.7, 'lng': 90.4, 'fix_age_s': 30, 'battery': 40, 'url': 'https://x/j/1'},
        {'id': 2, 'name': 'Tuli', 'status': 'active', 'sos': false, 'destination': '',
         'lat': 23.7, 'lng': 90.4, 'fix_age_s': 1800, 'url': 'https://x/j/2'},
        {'id': 3, 'name': 'Mita', 'status': 'stopped', 'sos': true, 'destination': '',
         'lat': 23.7, 'lng': 90.4, 'fix_age_s': 60, 'url': 'https://x/j/3'},
      ];
    await tester.pumpWidget(_app(api));
    unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => const JourneyWatchScreen())));
    await _settle(tester);
    expect(find.text(en.j100StLive), findsOneWidget);
    expect(find.text(en.j100StLost(30)), findsOneWidget);
    expect(find.text(en.j100StSos), findsOneWidget);
    expect(find.text(en.j100Battery(40)), findsOneWidget);
    api.watching = [];
    await tester.pumpWidget(_app(api));
    unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => const JourneyWatchScreen())));
    await _settle(tester);
    expect(find.text(en.j100WatchEmpty), findsOneWidget);
    api.watchFails = true;
    await tester.pumpWidget(_app(api));
    unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => const JourneyWatchScreen())));
    await _settle(tester);
    expect(find.text(en.j100WatchError), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // drop the 30 s refresh timer
  });

  test('watcher rows: real /circle/members shape, accepted only', () {
    final rows = journeyWatcherRows({
      'results': [
        {'id': 7, 'name': 'Karim', 'state': 'accepted'},
        {'id': 8, 'name': 'Pending Pal', 'state': 'pending'},
        {'id': 9, 'name': 'Old Shape'},
      ]
    });
    expect(rows.map((m) => m['id']), [7, 9]);
    expect(journeyWatcherRows({}), isEmpty);
    expect(journeyWatcherRows(null), isEmpty);
    expect(journeyWatcherRows([{'id': 1, 'status': 'accepted'}]).single['id'], 1);
  });

  testWidgets('start form lists accepted circle members as watchers', (tester) async {
    final api = _JApi()
      ..active = {}
      ..circle = {
        'results': [
          {'id': 7, 'name': 'Reality Karim', 'phone': '01711000002', 'state': 'accepted'},
          {'id': 8, 'name': 'Pending Pal', 'state': 'pending'},
        ]
      };
    await tester.pumpWidget(_app(api));
    unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => const JourneyStartScreen())));
    await _settle(tester);
    final karim = find.widgetWithText(CheckboxListTile, 'Reality Karim');
    expect(karim, findsOneWidget);
    expect(find.text('Pending Pal'), findsNothing);
    expect(find.byKey(const ValueKey('truth_journey_add_watcher')), findsNothing);
    await tester.ensureVisible(karim);
    await tester.tap(karim);
    await _settle(tester, 3);
    expect(tester.widget<CheckboxListTile>(karim).value, isTrue);
    // sjfix: the ETA goes out as an absolute UTC instant. A naive local
    // time was read by the server as Asia/Dhaka, so any phone on another
    // timezone started its journey already overdue.
    await tester.enterText(find.byKey(const ValueKey('j100_dest')), 'Home');
    await tester.ensureVisible(find.byKey(const ValueKey('j100_start')));
    await tester.tap(find.byKey(const ValueKey('j100_start')));
    await _settle(tester);
    final eta = '${api.posts('/journey/start').single.body['eta']}';
    expect(eta, endsWith('Z'));
    final at = DateTime.parse(eta);
    expect(at.isAfter(DateTime.now().toUtc()), isTrue);
    expect(at.difference(DateTime.now().toUtc()).inHours, lessThan(25));
    expect(api.posts('/journey/start').single.body['watcher_ids'], [7]);
  });

  testWidgets('start form with an empty circle shows the add-family step', (tester) async {
    final api = _JApi()..active = {};
    await tester.pumpWidget(_app(api));
    unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => const JourneyStartScreen())));
    await _settle(tester);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.byKey(const ValueKey('truth_journey_add_watcher')), findsOneWidget);
  });

  testWidgets('live screen in Bangla + dark mode: Bangla only, 48dp targets', (tester) async {
    final api = _JApi();
    final tr = _tracker();
    await tester.pumpWidget(_app(api, lang: 'bn', dark: true));
    unawaited(_nav.currentState!.push(MaterialPageRoute(
        builder: (_) => JourneyLiveScreen(journeyId: 5, tracker: tr))));
    await _settle(tester);
    final bn = await AppLocalizations.delegate.load(const Locale('bn'));
    expect(find.text(bn.j100Sharing), findsOneWidget);
    expect(find.text(en.j100Sharing), findsNothing);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await tr.stop();
  });
}
