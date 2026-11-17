// gap-safejourney (feature gap lane, 17 Nov): what a real user noticed on
// Safe Journey —
//  * "Going to Office?" now also on the start screen itself (the
//    notification only fired while Assisto was open AND after leaving);
//  * the watcher's card shows the number-plate / ride photo (was web only);
//  * the traveller sees who is watching ("Seen by: …");
//  * one "km left" number on the live screen, not two different ones.
// Made-up people and places only.
import 'dart:async';
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_live_screen.dart' show sjWatcherNames;
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/screens/safe_journey/sj_during_panel.dart';
import 'package:assisto/services/journey_habits.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/journey_watcher_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final posts = <String, Map<String, dynamic>>{};
  List<Map<String, dynamic>> watching = [];
  Map<String, dynamic> during = {};

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/journey/active') return {};
    if (path == '/journey/places') return {'places': []};
    if (path == '/circle/members') {
      return {
        'results': [
          {'id': 7, 'name': 'Ammu', 'phone': '01711000002', 'state': 'accepted', 'relation': 'mother'},
        ]
      };
    }
    if (path == '/journey/watching') return {'journeys': watching};
    if (path == '/journey/watch-board') return {'count': 0, 'active': [], 'finished': []};
    if (path.contains('/during')) return during;
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts[path] = body;
    if (path == '/journey/start') return Completer<Map<String, dynamic>>().future;
    return {'ok': true};
  }
}

final _nav = GlobalKey<NavigatorState>();

Widget _app(_Api api, {String lang = 'en', bool dark = false, Widget? home}) {
  final s = AppState()
    ..api = api
    ..user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
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
      home: home ?? const Scaffold(body: Text('below')),
    ),
  );
}

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _open(WidgetTester tester, _Api api, Widget screen,
    {String lang = 'en', bool dark = false}) async {
  await tester.binding.setSurfaceSize(const Size(400, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(api, lang: lang, dark: dark));
  unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => screen)));
  await _settle(tester);
}

// Home (Badda-like sample) -> Office (Gulshan-like sample); made-up points.
const _hLat = 23.7800, _hLng = 90.4260, _oLat = 23.7925, _oLng = 90.4078;

/// Two past trips at this time of day, same weekday 1 and 2 weeks ago.
String _pastTrips() {
  final now = DateTime.now();
  return jsonEncode([
    for (final w in [7, 14])
      JourneyHabitTrip(
              fLat: _hLat, fLng: _hLng, dLat: _oLat, dLng: _oLng, name: 'Office',
              kind: 'office', mode: 'cng', at: now.subtract(Duration(days: w)))
          .toJson()
  ]);
}

const _sug = JourneySuggestion(
    oLat: _hLat, oLng: _hLng, dLat: _oLat, dLng: _oLng, name: 'Office', usualMin: 510, times: 2);

void main() {
  late AppLocalizations en, bn;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async => call.method == 'checkPermission' ? 2 : null);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'), null));

  group('start-screen suggestion (pure)', () {
    test('position unknown -> offered', () {
      expect(sjgScreenSuggestion([_sug], null)?.name, 'Office');
    });
    test('at home (start point) -> offered', () {
      expect(sjgScreenSuggestion([_sug], (lat: _hLat, lng: _hLng)), isNotNull);
    });
    test('already at the office -> not offered', () {
      expect(sjgScreenSuggestion([_sug], (lat: _oLat, lng: _oLng)), isNull);
    });
    test('far from the usual start (another city) -> not offered', () {
      expect(sjgScreenSuggestion([_sug], (lat: 24.0, lng: 90.4)), isNull);
    });
    test('nothing learned -> nothing', () {
      expect(sjgScreenSuggestion(const [], null), isNull);
    });
  });

  testWidgets('opening Safe Journey at the usual time offers "Going to Office?"; one tap fills it',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {JourneyHabits.kTripsKey: _pastTrips(), JourneyWatcherMemory.key: '7'});
    final api = _Api();
    await _open(tester, api, const JourneyStartScreen());
    expect(find.byKey(const ValueKey('gsj_usual_card')), findsOneWidget);
    expect(find.text(en.sj2SuggestTitle('Office')), findsOneWidget);
    final go = tester.getSize(find.byKey(const ValueKey('gsj_usual_go')));
    expect(go.height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const ValueKey('gsj_usual_go')));
    await _settle(tester, 90); // the road-time wait (no Routes in the fake)
    final tp = find.byType(TimePickerDialog);
    if (tp.evaluate().isNotEmpty) {
      Navigator.of(tester.element(tp))
          .pop(TimeOfDay.fromDateTime(DateTime.now().add(const Duration(minutes: 40))));
      await _settle(tester);
    }
    // one tap = the journey starts to Office with the remembered watcher
    final b = api.posts['/journey/start'];
    expect(b, isNotNull);
    expect(b!['destination']['name'], 'Office');
    expect(b['destination']['lat'], _oLat);
    expect(b['watcher_ids'], [7]);
    expect(find.byKey(const ValueKey('gsj_usual_card'), skipOffstage: false), findsNothing);
  });

  testWidgets('the card can be closed and is not shown without a habit', (tester) async {
    SharedPreferences.setMockInitialValues({JourneyHabits.kTripsKey: _pastTrips()});
    await _open(tester, _Api(), const JourneyStartScreen());
    await tester.tap(find.byKey(const ValueKey('gsj_usual_close')));
    await _settle(tester, 3);
    expect(find.byKey(const ValueKey('gsj_usual_card')), findsNothing);

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const SizedBox());
    await _open(tester, _Api(), const JourneyStartScreen());
    expect(find.byKey(const ValueKey('gsj_usual_card')), findsNothing);
  });

  testWidgets('suggestions switched off -> no card', (tester) async {
    SharedPreferences.setMockInitialValues(
        {JourneyHabits.kTripsKey: _pastTrips(), JourneyHabits.kOnKey: false});
    await _open(tester, _Api(), const JourneyStartScreen());
    expect(find.byKey(const ValueKey('gsj_usual_card')), findsNothing);
  });

  testWidgets('Bangla dark: the card is in Bangla', (tester) async {
    SharedPreferences.setMockInitialValues({JourneyHabits.kTripsKey: _pastTrips()});
    await _open(tester, _Api(), const JourneyStartScreen(), lang: 'bn', dark: true);
    expect(find.text(bn.sj2SuggestTitle('Office')), findsOneWidget);
    expect(find.text(bn.sj2SuggestGo), findsOneWidget);
    expect(find.text(en.sj2SuggestGo), findsNothing);
  });

  testWidgets('watcher card shows the ride photo while live; tap enlarges', (tester) async {
    final api = _Api()
      ..watching = [
        {
          'id': 11, 'name': 'Rina', 'status': 'active', 'sos': false,
          'destination': 'Office', 'ride': {'plate': 'DHA-GA-11', 'mode': 'cng'},
          'ride_photo': '/api/v1/m/journey/j11.jpg?e=1&s=x',
        },
        {
          'id': 12, 'name': 'Abbu', 'status': 'arrived', 'sos': false,
          'destination': 'Home', 'ride_photo': '/api/v1/m/journey/j12.jpg?e=1&s=x',
        },
      ];
    await _open(tester, api, const JourneyWatchScreen());
    expect(find.byKey(const ValueKey('gsj_ride_photo')), findsOneWidget); // live only
    await tester.tap(find.byKey(const ValueKey('gsj_ride_photo')));
    await _settle(tester, 4);
    expect(find.byKey(const ValueKey('gsj_ride_photo_big')), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the 30 s refresh
  });

  test('ride photo url: signed path -> full url; empty -> none', () {
    expect(sjRidePhotoUrl(null), isNull);
    expect(sjRidePhotoUrl(''), isNull);
    expect(sjRidePhotoUrl('/api/v1/m/a.jpg?e=1&s=x'), endsWith('/api/v1/m/a.jpg?e=1&s=x'));
    expect(sjRidePhotoUrl('/api/v1/m/a.jpg')!.startsWith('http'), isTrue);
  });

  test('watcher names for the traveller ("Seen by")', () {
    expect(sjWatcherNames({}), isNull);
    expect(sjWatcherNames({'watcher_names': []}), isNull);
    expect(sjWatcherNames({'watcher_names': ['Ammu', ' ', 'Abbu']}), 'Ammu, Abbu');
    expect(en.cgaSeenBy('Ammu, Abbu'), 'Seen by: Ammu, Abbu');
  });

  testWidgets('during panel: km line can be left to the screen above (one number)',
      (tester) async {
    final api = _Api()..during = {'state': 'moving', 'distance_m': 12400};
    await tester.pumpWidget(_app(api,
        home: Scaffold(
            body: ListView(children: [
          SjDuringPanel(
              journeyId: 5, poll: false, showDistance: false, onArrived: (_) {}, onDanger: () {}),
        ]))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('sjd_state_dist')), findsNothing);
    await tester.pumpWidget(_app(api,
        home: Scaffold(
            body: ListView(children: [
          SjDuringPanel(journeyId: 5, poll: false, onArrived: (_) {}, onDanger: () {}),
        ]))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('sjd_state_dist')), findsOneWidget);
  });
}
