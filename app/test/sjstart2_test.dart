// sjstart2 (owner Safe Journey V2, 9 Nov): start screen leftovers —
// "Who watches" chips (more than one, family first, remembered), optional
// number-plate photo sent to the watchers, and the usual-trip suggestion
// "Going to Office? Tell family?" learned on the phone.
import 'dart:async';
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/services/journey_habits.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/journey_plate_photo.dart';
import 'package:assisto/widgets/journey_watcher_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Hit {
  final String method, path;
  final Map<String, dynamic> body;
  _Hit(this.method, this.path, this.body);
}

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final hits = <_Hit>[];
  bool startOk = false;
  Map<String, dynamic> active = {};
  Map<String, dynamic> circle = {
    'results': [
      {'id': 7, 'name': 'Ammu', 'phone': '01711000002', 'state': 'accepted', 'relation': 'mother'},
      {'id': 8, 'name': 'Rafi (office)', 'phone': '01711000003', 'state': 'accepted', 'relation': 'colleague'},
      {'id': 9, 'name': 'Abbu', 'phone': '01711000004', 'state': 'accepted', 'relation': 'father'},
    ]
  };

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    hits.add(_Hit('GET', path, const {}));
    if (path == '/journey/active') return active;
    if (path == '/circle/members') return circle;
    if (path == '/journey/places') return {'places': const []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    hits.add(_Hit('POST', path, body));
    if (path == '/journey/parse-link') {
      return {'ok': true, 'lat': 23.7806, 'lng': 90.407, 'name': 'Gulshan 1'};
    }
    if (path == '/journey/start') {
      if (!startOk) throw ApiException('test: not started', 500);
      return {'id': 5};
    }
    // keeps the start screen here (no live screen in this test)
    if (path.endsWith('/vehicle-photo')) return Completer<Map<String, dynamic>>().future;
    return {'ok': true};
  }

  List<_Hit> posts(String suffix) =>
      hits.where((h) => h.method == 'POST' && h.path.endsWith(suffix)).toList();
}

final _nav = GlobalKey<NavigatorState>();

Widget _app(_Api api, {String lang = 'en', bool dark = false}) {
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
      home: const Scaffold(body: Text('below')),
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

Future<void> _pinViaLink(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('j2_paste_link')));
  await tester.tap(find.byKey(const ValueKey('j2_paste_link')));
  await _settle(tester, 6);
  await tester.enterText(find.byKey(const ValueKey('j2_link_field')), 'https://maps.app.goo.gl/x');
  await tester.tap(find.byKey(const ValueKey('j2_link_use')));
  await _settle(tester, 8);
}

Future<void> _tapStartAndTime(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('j100_start'), skipOffstage: false));
  await _settle(tester, 3);
  await tester.tap(find.byKey(const ValueKey('j100_start')));
  await _settle(tester);
  await _popTimePicker(tester);
}

/// The one start POST, or a failure that says what the screen showed.
_Hit _started(WidgetTester tester, _Api api) {
  final p = api.posts('/journey/start');
  if (p.length == 1) return p.single;
  final shown = [
    for (final e in find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)).evaluate())
      (e.widget as Text).data ?? '',
  ];
  fail('no /journey/start POST; snackbars=$shown; '
      'timePicker=${find.byType(TimePickerDialog).evaluate().length}; '
      'sheets=${find.byType(BottomSheet).evaluate().length}; '
      'hits=${[for (final h in api.hits) '${h.method} ${h.path}']}');
}

Future<void> _popTimePicker(WidgetTester tester) async {
  final tp = find.byType(TimePickerDialog);
  if (tp.evaluate().isNotEmpty) {
    Navigator.of(tester.element(tp))
        .pop(TimeOfDay.fromDateTime(DateTime.now().add(const Duration(minutes: 40))));
    await _settle(tester);
  }
}

// Home (Badda-like sample) -> Office (Gulshan-like sample); made-up points.
const _hLat = 23.7800, _hLng = 90.4260, _oLat = 23.7925, _oLng = 90.4078;

JourneyHabitTrip _trip(DateTime at, {double fLat = _hLat, double dLat = _oLat}) =>
    JourneyHabitTrip(
        fLat: fLat, fLng: _hLng, dLat: dLat, dLng: _oLng, name: 'Office', kind: 'office',
        mode: 'cng', at: at);

void main() {
  late AppLocalizations en, bn;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('usual trips (learned on the phone)', () {
    // Sun 1 Nov 2026 .. Thu: BD working days
    final mon = DateTime(2026, 11, 9, 8, 40); // a Monday
    final past = [
      _trip(DateTime(2026, 11, 1, 8, 30)),
      _trip(DateTime(2026, 11, 2, 8, 35)),
      _trip(DateTime(2026, 11, 3, 8, 20)),
    ];

    test('three weekday trips at 08:30 -> suggested at 08:40 on a weekday', () {
      final u = sj2UsualTrips(past, mon);
      expect(u, hasLength(1));
      expect(u.single.name, 'Office');
      expect(u.single.times, 3);
      expect(u.single.usualMin, 8 * 60 + 30);
      expect(u.single.mode, 'cng');
    });

    test('not at another time, not on the Friday weekend, not from one day only', () {
      expect(sj2UsualTrips(past, DateTime(2026, 11, 9, 13, 0)), isEmpty);
      expect(sj2UsualTrips(past, DateTime(2026, 11, 13, 8, 40)), isEmpty); // Friday
      expect(sj2UsualTrips([past.first, _trip(DateTime(2026, 11, 1, 8, 45))], mon), isEmpty);
      // older than six weeks is forgotten
      expect(sj2UsualTrips(past, DateTime(2027, 1, 4, 8, 40)), isEmpty);
    });

    test('a trip to somewhere else is its own pattern', () {
      final mixed = [...past, _trip(DateTime(2026, 11, 4, 8, 30), dLat: 23.70)];
      final u = sj2UsualTrips(mixed, mon);
      expect(u.first.times, 3);
      expect(u.where((s) => s.times == 1), isEmpty); // one day: not usual
    });

    test('just left: out of the 250 m ring, not at the destination', () {
      final s = sj2UsualTrips(past, mon).single;
      expect(sj2JustLeft(s, _hLat, _hLng, mon), isFalse); // still home
      expect(sj2JustLeft(s, _hLat + 0.006, _hLng, mon), isTrue); // ~670 m away
      expect(sj2JustLeft(s, _oLat, _oLng, mon), isFalse); // already at office
      // 6 km away and never seen at home lately: not "just left"
      expect(sj2JustLeft(s, _hLat - 0.055, _hLng, mon), isFalse);
      expect(
          sj2JustLeft(s, _hLat - 0.055, _hLng, mon,
              seenAtOrigin: mon.subtract(const Duration(minutes: 20))),
          isTrue);
    });

    test('suggestion payload round-trips through the notification', () {
      final s = sj2UsualTrips(past, mon).single;
      final back = JourneyHabits.parse('${JourneyHabits.payloadPrefix}${jsonEncode(s.toJson())}');
      expect(back!.name, 'Office');
      expect(back.kind, 'office');
      expect(back.usualMin, 8 * 60 + 30);
      expect(JourneyHabits.parse('remalarm:x'), isNull);
    });

    test('record keeps the trips on the phone; forget clears them', () async {
      await JourneyHabits.record(_trip(DateTime(2026, 11, 1, 8, 30)));
      await JourneyHabits.record(_trip(DateTime(2026, 11, 2, 8, 30)));
      expect(await JourneyHabits.trips(), hasLength(2));
      await JourneyHabits.forget();
      expect(await JourneyHabits.trips(), isEmpty);
    });

    test('tick: off -> nothing; on + just left home -> one suggestion a day', () async {
      final app = AppState()
        ..api = _Api()
        ..user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
            autonomyLevel: 2, language: 'en');
      for (final t in past) {
        await JourneyHabits.record(t);
      }
      var fix = (lat: _hLat, lng: _hLng);
      JourneyHabits.debugFix = () async => fix;
      addTearDown(() => JourneyHabits.debugFix = null);
      await JourneyHabits.setEnabled(false);
      expect(await JourneyHabits.tick(app, now: mon), isNull);
      await JourneyHabits.setEnabled(true);
      expect(await JourneyHabits.tick(app, now: mon), isNull); // still at home
      fix = (lat: _hLat + 0.006, lng: _hLng);
      final s = await JourneyHabits.tick(app, now: mon.add(const Duration(minutes: 3)));
      expect(s?.name, 'Office');
      // once a day only
      expect(await JourneyHabits.tick(app, now: mon.add(const Duration(minutes: 6))), isNull);
    });

    test('tick: a journey already running -> no suggestion', () async {
      final api = _Api()..active = {'id': 3};
      final app = AppState()
        ..api = api
        ..user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
            autonomyLevel: 2, language: 'en');
      for (final t in past) {
        await JourneyHabits.record(t);
      }
      JourneyHabits.debugFix = () async => (lat: _hLat + 0.006, lng: _hLng);
      addTearDown(() => JourneyHabits.debugFix = null);
      expect(await JourneyHabits.tick(app, now: mon), isNull);
    });
  });

  group('plate photo', () {
    test('offered for road rides, not for train / metro / launch / walk', () {
      for (final m in [null, 'cng', 'car', 'bike', 'local_bus', 'long_bus']) {
        expect(sj2PlatePhotoFits(m, null), isTrue, reason: '$m');
      }
      for (final m in ['train', 'metro', 'launch', 'walk']) {
        expect(sj2PlatePhotoFits(m, null), isFalse, reason: '$m');
      }
      expect(sj2PlatePhotoFits('walk', 'pathao'), isTrue);
    });
  });

  testWidgets('watcher chips: more than one, family first, remembered next time', (tester) async {
    final api = _Api();
    await _open(tester, api, const JourneyStartScreen());
    // family section before the others
    final fam = tester.getTopLeft(find.byKey(const Key('cfa-section-family'), skipOffstage: false));
    final oth = tester.getTopLeft(find.byKey(const Key('cfa-section-others'), skipOffstage: false));
    expect(fam.dy, lessThan(oth.dy));
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text(en.sj2WatchNone, skipOffstage: false), findsOneWidget);
    for (final id in [7, 9]) {
      await tester.ensureVisible(find.byKey(ValueKey('j100_w_$id')));
      await tester.tap(find.byKey(ValueKey('j100_w_$id')));
      await _settle(tester, 3);
    }
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('j100_w_7'))).selected, isTrue);
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('j100_w_9'))).selected, isTrue);
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('j100_w_8'))).selected, isFalse);
    expect(find.text(en.sj2WatchCount('2')), findsOneWidget);
    await _pinViaLink(tester);
    await _tapStartAndTime(tester);
    expect((_started(tester, api).body['watcher_ids'] as List).toSet(), {7, 9});
    // the start failed here, but the next start screen picks them again
    // only after a successful start — see the next test
  });

  testWidgets('a successful start remembers watchers and sends the plate photo', (tester) async {
    final api = _Api()..startOk = true;
    final img = base64Decode( // a real 1x1 PNG
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');
    await _open(tester, api, JourneyStartScreen(platePicker: (_) async => img));
    await tester.ensureVisible(find.byKey(const ValueKey('j100_w_8')));
    await tester.tap(find.byKey(const ValueKey('j100_w_8')));
    await _settle(tester, 3);
    expect(find.byKey(const ValueKey('sj2_plate_tile'), skipOffstage: false), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('sj2_plate_pick')));
    await tester.tap(find.byKey(const ValueKey('sj2_plate_pick')));
    await _settle(tester, 6);
    await tester.tap(find.byKey(const ValueKey('sj2_plate_camera')));
    await _settle(tester, 6);
    expect(find.text(en.sj2PlateAdded), findsOneWidget);
    expect(find.byKey(const ValueKey('sj2_plate_remove')), findsOneWidget);
    await _pinViaLink(tester);
    await _tapStartAndTime(tester);
    _started(tester, api);
    final up = api.posts('/journey/5/vehicle-photo');
    expect(up, hasLength(1));
    expect(up.single.body['image_b64'], isNotEmpty);
    expect(await JourneyWatcherMemory.load(), {8});
  });

  testWidgets('remembered watchers come back preselected (removed member dropped)',
      (tester) async {
    SharedPreferences.setMockInitialValues({JourneyWatcherMemory.key: '7,42'});
    final api = _Api();
    await _open(tester, api, const JourneyStartScreen());
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('j100_w_7'), skipOffstage: false)).selected,
        isTrue);
    expect(find.text(en.sj2WatchCount('1'), skipOffstage: false), findsOneWidget);
  });

  testWidgets('train hides the plate photo', (tester) async {
    SharedPreferences.setMockInitialValues({'journey_travel_mode': 'train'});
    await _open(tester, _Api(), const JourneyStartScreen());
    expect(find.byKey(const ValueKey('sj2_plate_tile'), skipOffstage: false), findsNothing);
  });

  testWidgets('suggestion "Start" fills Office in and starts with the remembered watchers',
      (tester) async {
    SharedPreferences.setMockInitialValues({JourneyWatcherMemory.key: '7,9'});
    final api = _Api();
    const s = JourneySuggestion(
        oLat: _hLat, oLng: _hLng, dLat: _oLat, dLng: _oLng, name: 'Office', kind: 'office',
        mode: 'cng', usualMin: 510, times: 3);
    await _open(tester, api, const JourneyStartScreen(suggest: s, autoStart: true));
    await _settle(tester, 90); // the road-time wait (no Routes in the fake)
    await _popTimePicker(tester);
    final b = _started(tester, api).body;
    expect(b['destination']['name'], 'Office');
    expect(b['destination']['lat'], _oLat);
    expect(b['destination']['kind'], 'office');
    expect((b['watcher_ids'] as List).toSet(), {7, 9});
    expect(find.byKey(const ValueKey('sj2_suggest_banner'), skipOffstage: false), findsOneWidget);
  });

  testWidgets('Bangla dark: chips + plate tile in Bangla, Bangla digits', (tester) async {
    SharedPreferences.setMockInitialValues({JourneyWatcherMemory.key: '7,9'});
    await _open(tester, _Api(), const JourneyStartScreen(), lang: 'bn', dark: true);
    expect(find.text(bn.sj2WatchCount('২'), skipOffstage: false), findsOneWidget);
    expect(find.text(bn.sj2PlateTitle, skipOffstage: false), findsOneWidget);
    expect(find.text(en.sj2PlateTitle, skipOffstage: false), findsNothing);
    final chip = tester.getSize(find.byKey(const ValueKey('j100_w_7'), skipOffstage: false));
    expect(chip.height, greaterThanOrEqualTo(48));
  });

  testWidgets('chips widget alone toggles', (tester) async {
    var sel = <int>{};
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
            body: StatefulBuilder(
                builder: (c, set) => JourneyWatcherChips(
                    rows: const [
                      {'id': 1, 'name': 'Ammu', 'relation': 'mother'},
                      {'id': 2, 'name': 'Bondhu'},
                    ],
                    selected: sel,
                    onChanged: (v) => set(() => sel = v))))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('j100_w_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('j100_w_2')));
    await tester.pumpAndSettle();
    expect(sel, {1, 2});
    await tester.tap(find.byKey(const ValueKey('j100_w_1')));
    await tester.pumpAndSettle();
    expect(sel, {2});
  });
}
