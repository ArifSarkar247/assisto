// journeymode (owner order 2 Nov 17:40): Train tracker + Destination alarm
// INSIDE Safe Journey. Per mode: the "How are you going?" chips (remembered),
// bus alarm defaults (local 10 m / long-distance 2 km), train link + the
// real station before yours, the alarm auto-ringing when the train LEAVES
// that station (and never at the start for sparse timetables), metro needs
// both stations, the watcher's train card, flags off = journey unchanged,
// and the STANDALONE destination alarm never uploads anything.
// Fake server returns plain maps only.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/screens/train/dest_alarm_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:assisto/train/dest_alarm_sound.dart';
import 'package:assisto/train/journey_transit.dart';
import 'package:assisto/train/train_fgs.dart';
import 'package:assisto/vehicle/veh_map.dart' show VehMapConfig;
import 'package:assisto/widgets/journey_mode_section.dart';

import 'fake_train.dart';

// ------------------------------------------------------------ fakes
class _Sound implements DestAlarmSound {
  int starts = 0, stops = 0;
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async {
    starts++;
    return true;
  }

  @override
  Future<bool> playClip(String path) async => true;
  @override
  Future<bool> vibrateOnce() async => true;
  @override
  Future<bool> speak(String text, String lang) async => true;
  @override
  Future<void> stop() async => stops++;
}

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final gets = <String>[];
  final posts = <(String, Map<String, dynamic>)>[];
  List<Map<String, dynamic>> watching = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path == '/journey/active') return {};
    if (path == '/circle/members') {
      return {
        'results': [
          {'id': 7, 'name': 'Mother', 'phone': '01711000002', 'state': 'accepted'}
        ]
      };
    }
    if (path == '/journey/places') return {'places': const []};
    if (path == '/journey/watching') return {'journeys': watching};
    if (path.startsWith('/journey/geocode')) return {'available': false};
    return fakeTrainGet(path, bn: false, empty: false) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    if (path == '/journey/start') throw ApiException('test: not started', 500);
    return {'ok': true};
  }
}

final _nav = GlobalKey<NavigatorState>();

Widget _app(ApiClient api, {String lang = 'en'}) {
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
  );
}

Future<void> _settle(WidgetTester tester, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _open(WidgetTester tester, ApiClient api, Widget screen, {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(400, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(api, lang: lang));
  unawaited(_nav.currentState!.push(MaterialPageRoute(builder: (_) => screen)));
  await _settle(tester);
}

DestAlarmTexts _tx() => DestAlarmTexts(
    distance: (m) => '${m.round()} m',
    notifTitle: 'n',
    notifText: 'n',
    stop: 's',
    lang: 'en',
    spoken: (s, d) => 'wake $s $d',
    ready: (s, d) => 'ready $s $d');

/// A straight north-south line of [km] kilometres starting at (lat0, lng0).
List<List<double>> _line(double lat0, double lng0, double km) =>
    [for (var k = 0; k <= km; k += 5) [lat0 + k * 1000 / 111320.0, lng0]];

(double, double) _north(double lat, double lng, double m) => (lat + m / 111320.0, lng);

const _lat0 = 23.0, _lng0 = 90.4;

void main() {
  late AppLocalizations en;
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    Settings.resetForTest();
    TrainFgs.disabled = true;
    VehMapConfig.debugSet(const VehMapConfig());
    FeatureFlags.instance.debugOverride = {'train_tracker': true, 'dest_alarm': true};
    JourneyModeController.debugStations = const [];
    JourneyModeController.debugMetro = const [];
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/geolocator'),
        (call) async => call.method == 'checkPermission' ? 2 : null);
  });
  tearDown(() {
    FeatureFlags.instance.debugOverride = null;
    VehMapConfig.debugSet(null);
  });

  // ---------------------------------------------------------- pure
  group('travel mode -> alarm plan', () {
    test('which modes ring, and the bus defaults (local 10 m, long 2 km)', () async {
      expect(kTravelModes,
          ['local_bus', 'long_bus', 'train', 'metro', 'launch', 'car', 'cng']);
      expect(alarmModeFor('local_bus'), TransportMode.cityBus);
      expect(alarmModeFor('long_bus'), TransportMode.longBus);
      expect(alarmModeFor('train'), TransportMode.train);
      expect(alarmModeFor('metro'), TransportMode.metro);
      expect(alarmModeFor('launch'), TransportMode.launch);
      expect(alarmModeFor('car'), isNull);
      expect(alarmModeFor('cng'), isNull);
      expect(alarmOnByDefault('local_bus'), isTrue);
      expect(alarmOnByDefault('long_bus'), isTrue);
      expect(alarmOnByDefault('car'), isFalse);
      expect((await alarmMemoryFor('local_bus')).$1, 10);
      expect((await alarmMemoryFor('long_bus')).$1, 2000);
    });

    test('bus needs a pinned destination; car never rings', () {
      expect(journeyAlarmPlan(travel: 'local_bus', destName: 'X', setM: 10), isNull);
      final p = journeyAlarmPlan(
          travel: 'local_bus', destName: 'Farmgate', destLat: 23.757, destLng: 90.39, setM: 10)!;
      expect((p.mode, p.setM, p.target.name), (TransportMode.cityBus, 10, 'Farmgate'));
      final l = journeyAlarmPlan(
          travel: 'long_bus', destName: 'Cumilla', destLat: 23.46, destLng: 91.18, setM: 2000)!;
      expect((l.mode, l.setM), (TransportMode.longBus, 2000));
      expect(
          journeyAlarmPlan(travel: 'car', destName: 'X', destLat: 23.7, destLng: 90.4, setM: 10),
          isNull);
    });

    test('metro needs both stations', () {
      const metro = [
        MetroStation('Uttara North', 'U', 23.869, 90.367, 2),
        MetroStation('Agargaon', 'A', 23.778, 90.379, 3),
        MetroStation('Motijheel', 'M', 23.728, 90.419, 0),
      ];
      expect(journeyAlarmPlan(travel: 'metro', destName: 'x', setM: 0, metro: metro), isNull);
      final p = journeyAlarmPlan(
          travel: 'metro', destName: 'x', setM: 0, metro: metro, metroFrom: 0, metroTo: 2,
          bn: false)!;
      expect((p.mode, p.target.name, p.metroTo), (TransportMode.metro, 'Motijheel', 2));
      expect(nearestMetro(metro, 23.7285, 90.4185), 2);
      expect(nearestMetro(metro, 22.3, 91.8), isNull); // Chattogram: no metro nearby
    });
  });

  group('train: the real station before yours', () {
    final path = _line(_lat0, _lng0, 60);
    final at = (double km) => _north(_lat0, _lng0, km * 1000);
    DestStation st(String id, double km, {double east = 0}) {
      final p = at(km);
      return DestStation(id, id, id, p.$1, p.$2 + east);
    }

    test('a passed-only station on the line counts; off-line ones do not', () {
      final target = st('T', 50);
      final stations = [st('A', 20), st('B', 42), st('OFF', 46, east: 0.05), target];
      expect(prevStationOnPath(path, stations, target)!.id, 'B');
    });

    test('sparse timetable: a listed stop 300 km back is NOT used (would ring at the start)', () {
      const far = DestStation('CTG', 'Chattogram', 'Chattogram', 22.334, 91.829);
      const kml = DestStation('KML', 'Kamalapur', 'Kamalapur', 23.732, 90.426);
      expect(prevStationOnPath(const [], const [], kml, listedStops: const [far, kml]), isNull);
      const bia = DestStation('BIA', 'Airport', 'Airport', 23.852, 90.408);
      expect(prevStationOnPath(const [], const [], kml, listedStops: const [bia, kml])!.id, 'BIA');
    });

    test('journey train plan carries the station before yours', () {
      final target = st('T', 50);
      final pick = JourneyTrainPick(
          no: '705', nameBn: 'E', date: '2026-11-02', station: target,
          stops: [st('S0', 0), target], path: path);
      final p = journeyAlarmPlan(
          travel: 'train', destName: '', setM: 2000, train: pick,
          stations: [st('B', 42), target], bn: false)!;
      expect(p.mode, TransportMode.train);
      expect(p.prevStation!.name, 'B');
      expect(pick.toLink(), {'no': '705', 'date': '2026-11-02', 'to': 'T'});
    });

    test('alarm auto-rings when the train LEAVES the station before yours', () async {
      final target = at(50), prev = at(42);
      var here = at(30);
      final sound = _Sound();
      final c = DestAlarmController(
          position: () async => DestFix(here.$1, here.$2, accuracy: 10, speedMps: 15),
          battery: () async => 80,
          sound: sound,
          useService: false,
          repeatEvery: const Duration(hours: 1));
      await c.start(
          DestPlan(
              mode: TransportMode.train,
              target: DestTarget('T', target.$1, target.$2),
              setM: 2000,
              prevStation: DestTarget('B', prev.$1, prev.$2)),
          _tx());
      expect(c.value.phase, DestAlarmPhase.watching);
      here = at(42); // standing at the station before
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.watching);
      here = at(43); // left it, 1 km on toward yours
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.ringing);
      expect(sound.starts, 1);
      await c.confirmAwake();
      expect(c.value.phase, DestAlarmPhase.off);
    });

    test('a far previous stop never rings right after leaving it (GPS rule instead)', () async {
      final target = at(300), prev = at(0);
      var here = at(0);
      final c = DestAlarmController(
          position: () async => DestFix(here.$1, here.$2, accuracy: 10),
          battery: () async => 80,
          sound: _Sound(),
          useService: false);
      await c.start(
          DestPlan(
              mode: TransportMode.train,
              target: DestTarget('T', target.$1, target.$2),
              setM: 2000,
              prevStation: DestTarget('O', prev.$1, prev.$2)),
          _tx());
      here = at(2);
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.watching);
      here = at(299);
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.ringing);
      await c.stop();
    });
  });

  // ------------------------------------------------- standalone privacy
  group('standalone destination alarm keeps location on the phone', () {
    test('the alarm code imports no network / server code', () {
      for (final f in [
        'lib/train/dest_alarm_service.dart',
        'lib/train/dest_alarm_math.dart',
        'lib/train/dest_alarm_sound.dart',
        'lib/train/dest_voice_recorder.dart',
        'lib/train/train_fgs.dart',
        'lib/train/journey_transit.dart',
      ]) {
        final src = File(f).readAsStringSync();
        for (final bad in ['api.dart', 'package:http', 'HttpClient', 'train_api.dart', 'postJson',
            'getJson', 'journey_api.dart', 'WebSocket', 'firebase']) {
          expect(src.contains(bad), isFalse, reason: '$f must not use $bad');
        }
      }
    });

    test('a whole alarm run opens no network connection', () async {
      final opened = <String>[];
      await HttpOverrides.runZoned(() async {
        var d = 3000.0;
        final c = DestAlarmController(
            position: () async {
              final p = _north(23.70, 90.40, d);
              return DestFix(p.$1, p.$2, accuracy: 15, speedMps: 10);
            },
            battery: () async => 50,
            sound: _Sound(),
            useService: false);
        await c.start(
            const DestPlan(
                mode: TransportMode.cityBus, target: DestTarget('X', 23.70, 90.40), setM: 10),
            _tx());
        for (d = 2000; d >= 0; d -= 500) {
          await c.tick();
        }
        expect(c.value.phase, DestAlarmPhase.ringing);
        await c.stop();
      }, createHttpClient: (ctx) {
        opened.add('http');
        throw StateError('the destination alarm must not use the network');
      });
      expect(opened, isEmpty);
    });

    testWidgets('the alarm screen sends nothing to the server when you start and ring', (tester) async {
      final api = _Api();
      final old = DestAlarmController.I;
      var d = 900.0;
      DestAlarmController.I = DestAlarmController(
          position: () async {
            final p = _north(23.7570, 90.3900, d);
            return DestFix(p.$1, p.$2, accuracy: 10);
          },
          battery: () async => 60,
          sound: _Sound(),
          useService: false);
      addTearDown(() async {
        await DestAlarmController.I.stop();
        DestAlarmController.I = old;
      });
      DestAlarmScreen.debugStations = const [];
      DestAlarmScreen.debugBusStops = const [DestStation('b1', 'Farmgate', 'F', 23.7570, 90.3900)];
      DestAlarmScreen.debugMetro = const [];
      addTearDown(() {
        DestAlarmScreen.debugStations = null;
        DestAlarmScreen.debugBusStops = null;
        DestAlarmScreen.debugMetro = null;
      });
      await _open(tester, api, const DestAlarmScreen());
      await tester.tap(find.text('Farmgate'));
      await _settle(tester);
      final start = find.text(en.trAlarmStart);
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _settle(tester);
      expect(DestAlarmController.I.on, isTrue);
      d = 0;
      await DestAlarmController.I.tick();
      await _settle(tester);
      expect(DestAlarmController.I.value.phase, DestAlarmPhase.ringing);
      expect(api.posts, isEmpty); // nothing uploaded
      expect(api.gets, isEmpty); // not even a read
      await DestAlarmController.I.stop();
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------- start screen
  group('start screen: How are you going?', () {
    testWidgets('7 chips; local bus turns the alarm on at 10 m; choice remembered', (tester) async {
      await _open(tester, _Api(), const JourneyStartScreen());
      expect(find.text(en.jmHowGoing), findsOneWidget);
      for (final m in kTravelModes) {
        expect(find.byKey(ValueKey('jm_mode_$m')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('jm_alarm')), findsNothing); // nothing picked yet
      await tester.tap(find.byKey(const ValueKey('jm_mode_local_bus')));
      await _settle(tester);
      final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('jm_alarm')));
      expect(sw.value, isTrue);
      expect(find.text(en.jmAlarmBus('10 m')), findsOneWidget);
      expect(find.byKey(const ValueKey('jm_alarm_needs_pin')), findsOneWidget); // honest: no pin yet
      expect(await Settings.getString(kTravelModeKey), 'local_bus');
      // long-distance bus: 2 km
      await tester.tap(find.byKey(const ValueKey('jm_mode_long_bus')));
      await _settle(tester);
      expect(find.text(en.jmAlarmBus('2.0 km')), findsOneWidget);
      // car: no alarm
      await tester.tap(find.byKey(const ValueKey('jm_mode_car')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('jm_alarm')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      // re-open: the last choice is pre-selected
      await _open(tester, _Api(), const JourneyStartScreen());
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('jm_mode_car')));
      expect(chip.selected, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('flags off: chips stay, no train or alarm parts (journey unchanged)', (tester) async {
      FeatureFlags.instance.debugOverride = {'train_tracker': false, 'dest_alarm': false};
      await _open(tester, _Api(), const JourneyStartScreen());
      await tester.tap(find.byKey(const ValueKey('jm_mode_train')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('jm_pick_train')), findsNothing);
      expect(find.byKey(const ValueKey('jm_alarm')), findsNothing);
      expect(find.byKey(const ValueKey('j100_start')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('train: the tracker picker -> station -> destination + link sent at start',
        (tester) async {
      final api = _Api();
      await _open(tester, api, const JourneyStartScreen());
      await tester.tap(find.byKey(const ValueKey('jm_mode_train')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('jm_pick_train')));
      await _settle(tester);
      // the SAME picker as the Train tracker (TrainSearchPanel) lists 701
      await tester.tap(find.textContaining('701'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('jm_station_n3'))); // Dhaka Airport
      await _settle(tester);
      expect(find.byKey(const ValueKey('jm_train_card')), findsOneWidget);
      expect(find.text('Dhaka Airport Railway Station'), findsWidgets); // destination filled
      // alarm on, rings when leaving the stop before (Chattogram is 300 km
      // back: the GPS rule is used and said so)
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('jm_alarm'))).value, isTrue);
      expect(find.text(en.jmAlarmTrainGps('2.0 km')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('j100_w_7')));
      await tester.tap(find.byKey(const ValueKey('j100_w_7')));
      await _settle(tester);
      final start = find.byKey(const ValueKey('j100_start'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _settle(tester);
      final body = api.posts.firstWhere((p) => p.$1 == '/journey/start').$2;
      expect(body['mode'], 'train');
      final v = body['vehicle'] as Map;
      expect((v['train'] as Map)['no'], '701');
      expect((v['train'] as Map)['to'], 'n3');
      expect((body['destination'] as Map)['lat'], closeTo(23.85207, 1e-6));
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------- watcher
  group('watcher view', () {
    Map<String, dynamic> row(Map<String, dynamic>? train) => {
          'id': 3, 'name': 'Rina', 'status': 'active', 'sos': false,
          'destination': 'Dhaka Airport', 'eta': null, 'overdue_state': 'on_time',
          'lat': 23.5, 'lng': 90.9, 'ride': {'mode': 'train'},
          if (train != null) 'train': train, 'url': '',
        };

    testWidgets('sees the train, next station and an ESTIMATED arrival', (tester) async {
      final eta = DateTime(2026, 11, 2, 12, 40);
      final api = _Api()
        ..watching = [
          row({
            'no': '701', 'name_bn': 'S', 'date': '2026-11-02', 'basis': 'own',
            'label': 'estimate', 'lat': 23.5, 'lng': 90.9,
            'next_stop': {'id': 'n3', 'bn': 'B', 'en': 'Dhaka Airport'},
            'to': {'id': 'n3', 'bn': 'B', 'en': 'Dhaka Airport'},
            'to_eta': eta.toUtc().toIso8601String(), 'delay_min': 18, 'passed': false,
          })
        ];
      await _open(tester, api, const JourneyWatchScreen());
      expect(find.byKey(const ValueKey('jm_train_info')), findsOneWidget);
      expect(find.text(en.jmNextStation('Dhaka Airport')), findsOneWidget);
      expect(find.textContaining('(estimate)'), findsWidgets);
      expect(find.text(en.jmTrainLate('18')), findsOneWidget);
      expect(find.text(en.jmBasisOwn), findsOneWidget);
      expect(find.byKey(const ValueKey('jm_open_train')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no train block (flag off on the server) = the old card', (tester) async {
      final api = _Api()..watching = [row(null)];
      await _open(tester, api, const JourneyWatchScreen());
      expect(find.byKey(const ValueKey('jm_train_info')), findsNothing);
      expect(find.text('Rina'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------- live alarm
  testWidgets('journey alarm: ringing shows "I\'m awake"; ending the trip turns it off',
      (tester) async {
    final c = DestAlarmController(
        position: () async => const DestFix(23.70, 90.40, accuracy: 5),
        battery: () async => 60,
        sound: _Sound(),
        useService: false,
        repeatEvery: const Duration(hours: 1));
    final link = JourneyAlarmLink(controller: c);
    await tester.pumpWidget(_app(_Api()));
    unawaited(_nav.currentState!.push(MaterialPageRoute(
        builder: (_) => Scaffold(body: JourneyAlarmStatus(journeyId: 9, link: link)))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('jm_alarm_status')), findsNothing);
    await link.arm(
        9,
        const DestPlan(mode: TransportMode.cityBus, target: DestTarget('X', 23.70, 90.40), setM: 10),
        _tx());
    await _settle(tester);
    expect(c.value.phase, DestAlarmPhase.ringing); // already at the stop
    expect(find.byKey(const ValueKey('jm_awake')), findsOneWidget);
    // another journey id never touches it
    await link.disarm(8);
    expect(c.on, isTrue);
    await tester.tap(find.byKey(const ValueKey('jm_awake')));
    await _settle(tester);
    expect(c.on, isFalse);
    expect(find.byKey(const ValueKey('jm_alarm_status')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
