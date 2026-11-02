// sjalarm (owner Safe Journey order 3 Nov): Card 2 Destination Alarm + Card 3
// Train Tracker additions — controller (speed rule, snooze, battery-saving far
// GPS, family arrival notice), screens (presets, custom, honest GPS note,
// owner-only recorder entry, "Alarm here" from the train's stop list with the
// station filled, 999/131 on the train page), trip recorder (on the phone,
// JSON + GPX, mark stop), Bangla 200% dark.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/train/dest_alarm_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/screens/train/trip_recorder_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/dest_alarm_decide.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:assisto/train/dest_alarm_sound.dart';
import 'package:assisto/train/train_fgs.dart';
import 'package:assisto/train/trip_recorder.dart';
import 'package:assisto/train/trip_trace.dart';

import 'fake_train.dart';

const _lat = 23.7385, _lng = 90.3960;
(double, double) _north(double m) => (_lat + m / 111320.0, _lng);

class _Sound implements DestAlarmSound {
  int starts = 0, stops = 0;
  final spoken = <String>[];
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async {
    starts++;
    return true;
  }

  @override
  Future<bool> speak(String text, String lang) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<bool> playClip(String path) async => true;
  @override
  Future<bool> vibrateOnce() async => true;
  @override
  Future<void> stop() async => stops++;
}

class _Fake extends ApiClient {
  _Fake() {
    token = 't';
  }
  final gets = <String>[];
  final posts = <(String, Map<String, dynamic>)>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    return fakeTrainGet(path, bn: false, empty: true) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    return {'ok': true};
  }
}

DestAlarmTexts _tx() => DestAlarmTexts(
    distance: (m) => '${m.round()} m',
    notifTitle: 'n',
    notifText: 'n',
    stop: 's',
    lang: 'bn',
    spoken: (s, d) => 'জেগে উঠুন $s',
    ready: (s, d) => 'r');

Widget _app(Widget child, ApiClient api, {String lang = 'en', bool dark = false, double scale = 1}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: scale == 1
          ? null
          : (ctx, w) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    ),
  );
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 6400);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TrainFgs.disabled = true;
    FeatureFlags.instance.resetForTest();
  });
  tearDown(() {
    FeatureFlags.instance.resetForTest();
    DestAlarmController.arrivedNotifier = null;
  });

  group('controller: REAL LIFE speed rule + snooze + family notice', () {
    test('a fast bus rings ~45 s early with a 10 m setting (reason: speed)', () async {
      var d = 3000.0;
      final sound = _Sound();
      final c = DestAlarmController(
          position: () async {
            final p = _north(d);
            return DestFix(p.$1, p.$2, accuracy: 10, speedMps: 11);
          },
          battery: () async => 70,
          sound: sound,
          useService: false,
          repeatEvery: const Duration(hours: 1));
      await c.start(
          const DestPlan(mode: TransportMode.cityBus, target: DestTarget('Shahbag', _lat, _lng), setM: 10),
          _tx());
      d = 800;
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.watching);
      expect(c.value.speedMps, closeTo(11, 0.5));
      d = 480; // 470 m nearest / 11 m/s = 43 s
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.ringing);
      expect(c.value.reason, RingReason.eta);
      expect(sound.spoken.single, contains('Shahbag'));
      await c.stop();
    });

    test('snooze: quiet, then rings again; "I am awake" ends it', () async {
      final sound = _Sound();
      final c = DestAlarmController(
          position: () async => const DestFix(_lat, _lng, accuracy: 5),
          battery: () async => null,
          sound: sound,
          useService: false,
          repeatEvery: const Duration(hours: 1),
          snoozeFor: const Duration(milliseconds: 40));
      await c.start(
          const DestPlan(mode: TransportMode.cityBus, target: DestTarget('X', _lat, _lng), setM: 10),
          _tx());
      expect(c.value.phase, DestAlarmPhase.ringing);
      expect(sound.starts, 1);
      await c.snooze();
      expect(c.value.snoozedUntil, isNotNull);
      expect(sound.stops, 1);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(c.value.snoozedUntil, isNull);
      expect(sound.starts, 2); // rang again
      await c.confirmAwake();
      expect(c.value.phase, DestAlarmPhase.off);
    });

    test('family "arrived" only after I am awake, only to the picked people', () async {
      final calls = <List<int>>[];
      DestAlarmController.arrivedNotifier = (p) async {
        calls.add(p.notifyCircleIds);
        return true;
      };
      final c = DestAlarmController(
          position: () async => const DestFix(_lat, _lng, accuracy: 5),
          battery: () async => null,
          sound: _Sound(),
          useService: false,
          repeatEvery: const Duration(hours: 1));
      await c.start(
          const DestPlan(
              mode: TransportMode.cityBus,
              target: DestTarget('X', _lat, _lng),
              setM: 10,
              notifyCircleIds: [7, 9]),
          _tx());
      expect(calls, isEmpty); // ringing is not "arrived" yet
      await c.confirmAwake();
      expect(calls.single, [7, 9]);
      expect(c.value.arrivedSent, isTrue);
      // stopped before it rang: nobody is told
      await c.start(
          DestPlan(mode: TransportMode.cityBus, target: DestTarget('X', _north(5000).$1, _lng), setM: 10,
              notifyCircleIds: const [7]),
          _tx());
      await c.confirmAwake();
      expect(calls.length, 1);
    });

    test('offline family notice: the alarm already worked, the failure is shown', () async {
      DestAlarmController.arrivedNotifier = (p) async => throw const SocketException('offline');
      final c = DestAlarmController(
          position: () async => const DestFix(_lat, _lng, accuracy: 5),
          battery: () async => null,
          sound: _Sound(),
          useService: false,
          repeatEvery: const Duration(hours: 1));
      await c.start(
          const DestPlan(
              mode: TransportMode.cityBus, target: DestTarget('X', _lat, _lng), setM: 10, notifyCircleIds: [1]),
          _tx());
      await c.confirmAwake();
      expect(c.value.arrivedSent, isFalse);
    });

    test('battery: far away uses the low-power GPS, near switches to high accuracy', () async {
      var d = 30000.0;
      var low = 0, high = 0;
      Future<DestFix?> fix() async {
        final p = _north(d);
        return DestFix(p.$1, p.$2, accuracy: 15, speedMps: 20);
      }

      final c = DestAlarmController(
          position: () async {
            high++;
            return fix();
          },
          lowPowerPosition: () async {
            low++;
            return fix();
          },
          battery: () async => 50,
          sound: _Sound(),
          useService: false);
      await c.start(
          const DestPlan(mode: TransportMode.longBus, target: DestTarget('X', _lat, _lng), setM: 2000),
          _tx());
      expect(high, 1); // the first fix is always precise
      await c.tick();
      expect(low, 1); // far: battery saving
      d = 4000; // the coarse fix says "near" -> a precise fix decides
      await c.tick();
      expect(low, 2);
      expect(high, 2);
      d = 1500;
      await c.tick(); // still near: precise only
      expect(low, 2);
      expect(c.value.phase, DestAlarmPhase.ringing);
      await c.stop();
    });
  });

  group('screens', () {
    testWidgets('presets 10 m (default) / 100 / 300 / 500 m / 1 km + Custom; GPS note; no recorder for users',
        (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      DestAlarmScreen.debugStations = const [];
      DestAlarmScreen.debugBusStops = const [DestStation('b1', 'Farmgate', 'ফার্মগেট', 23.757, 90.39)];
      DestAlarmScreen.debugMetro = const [];
      addTearDown(() {
        DestAlarmScreen.debugStations = null;
        DestAlarmScreen.debugBusStops = null;
        DestAlarmScreen.debugMetro = null;
      });
      final api = _Fake();
      await t.pumpWidget(_app(const DestAlarmScreen(), api));
      await t.pumpAndSettle();
      expect(find.text(l.sjaPresetDefault(l.trMetres('10'))), findsOneWidget);
      for (final m in ['100', '300', '500']) {
        expect(find.text(l.trMetres(m)), findsOneWidget, reason: m);
      }
      expect(find.text(l.trKm('1.0')), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      await t.tap(find.text(l.sjaCustom));
      await t.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text(l.sjaGpsNote), findsOneWidget);
      expect(find.text(l.sjaNotifyFamily), findsOneWidget);
      expect(find.byTooltip(l.sjaRecorderTitle), findsNothing); // owner-only
      expect(api.gets, isEmpty); // the alarm screen reads nothing from the server
    });

    testWidgets('owner preview of trip_recorder shows the recorder entry', (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      FeatureFlags.instance.applyForTest({
        'features': {'trip_recorder': true, 'dest_alarm': true},
        'preview': ['trip_recorder', 'dest_alarm'],
      });
      DestAlarmScreen.debugStations = const [];
      DestAlarmScreen.debugBusStops = const [];
      DestAlarmScreen.debugMetro = const [];
      addTearDown(() {
        DestAlarmScreen.debugStations = null;
        DestAlarmScreen.debugBusStops = null;
        DestAlarmScreen.debugMetro = null;
      });
      await t.pumpWidget(_app(const DestAlarmScreen(), _Fake()));
      await t.pumpAndSettle();
      expect(find.byTooltip(l.sjaRecorderTitle), findsOneWidget);
      expect(tripRecorderVisible(), isTrue);
      // switched ON for everybody by mistake is still not shown to users
      FeatureFlags.instance.applyForTest({'features': {'trip_recorder': true}, 'preview': []});
      expect(tripRecorderVisible(), isFalse);
    });

    testWidgets('train page: "Alarm here" opens the alarm with that station filled; 999 / 131 shown',
        (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      FeatureFlags.instance.debugOverride = {'dest_alarm': true, 'train_tracker': true};
      DestAlarmScreen.debugStations = const [];
      DestAlarmScreen.debugBusStops = const [];
      DestAlarmScreen.debugMetro = const [];
      addTearDown(() {
        DestAlarmScreen.debugStations = null;
        DestAlarmScreen.debugBusStops = null;
        DestAlarmScreen.debugMetro = null;
      });
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), _Fake()));
      await t.pumpAndSettle();
      expect(find.text(l.trCall999), findsWidgets);
      expect(find.text(l.trCall131), findsWidgets);
      expect(find.text(l.trUnchecked), findsWidgets); // schedule not verified
      final here = find.text(l.sjaAlarmHere);
      expect(here, findsNWidgets(3));
      await t.ensureVisible(here.at(1));
      await t.tap(here.at(1)); // Dhaka Airport
      await t.pumpAndSettle();
      expect(find.byType(DestAlarmScreen), findsOneWidget);
      expect(find.widgetWithText(Card, 'Dhaka Airport Railway Station'), findsOneWidget);
      final start = find.text(l.trAlarmStart);
      await t.ensureVisible(start);
      final btn = t.widget<ButtonStyleButton>(find
          .ancestor(of: start, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton))
          .first);
      expect(btn.onPressed, isNotNull); // station already picked: ready to start
    });

    for (final dark in [false, true]) {
      testWidgets('Bangla 200% ${dark ? 'dark' : 'light'}: alarm + recorder, no overflow', (t) async {
        _tall(t);
        DestAlarmScreen.debugStations = const [];
        DestAlarmScreen.debugBusStops = const [DestStation('b1', 'Farmgate', 'ফার্মগেট', 23.757, 90.39)];
        DestAlarmScreen.debugMetro = const [];
        addTearDown(() {
          DestAlarmScreen.debugStations = null;
          DestAlarmScreen.debugBusStops = null;
          DestAlarmScreen.debugMetro = null;
        });
        await t.pumpWidget(_app(const DestAlarmScreen(), _Fake(), lang: 'bn', dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        final dir = await Directory.systemTemp.createTemp('trip');
        addTearDown(() => dir.delete(recursive: true));
        final oldRec = TripRecorder.I;
        TripRecorder.I = TripRecorder(stream: () => const Stream.empty(), dir: () async => dir, useService: false);
        addTearDown(() => TripRecorder.I = oldRec);
        await t.pumpWidget(_app(const TripRecorderScreen(), _Fake(), lang: 'bn', dark: dark, scale: 2));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }
  });

  group('trip recorder (owner-only, on the phone)', () {
    test('records, marks the stop, saves JSON + GPX, replays, deletes', () async {
      final dir = await Directory.systemTemp.createTemp('trip');
      addTearDown(() => dir.delete(recursive: true));
      final ctl = StreamController<TracePoint>();
      final r = TripRecorder(stream: () => ctl.stream, dir: () async => dir, useService: false);
      await r.start('cityBus');
      final t0 = DateTime.utc(2026, 11, 3, 8);
      for (var i = 0; i < 120; i++) {
        final p = _north(1200 - 10.0 * i);
        ctl.add(TracePoint(t0.add(Duration(seconds: i)), p.$1, p.$2, 8, speed: 10));
      }
      await Future<void>.delayed(Duration.zero);
      expect(r.value.points, 120);
      expect(r.markStop(), isTrue);
      final f = await r.stop();
      expect(f, isNotNull);
      final tr = TripTrace.decode(await f!.readAsString())!;
      expect(tr.synthetic, isFalse);
      expect(tr.points.length, 120);
      expect(tr.points.first.speed, 10);
      expect(tr.stopLat, isNotNull);
      expect(File(f.path.replaceAll('.json', '.gpx')).existsSync(), isTrue);
      expect(await r.saved(), hasLength(1));
      // the recorder's own file runs through the CI replay as-is
      final rp = replayTrace(tr);
      expect(rp.ringAt, isNotNull);
      expect(rp.leadS, greaterThan(15));
      await r.delete(f);
      expect(await r.saved(), isEmpty);
      await ctl.close();
    });

    test('pure decision code imports no network', () {
      for (final f in ['lib/train/dest_alarm_decide.dart', 'lib/train/trip_trace.dart']) {
        final src = File(f).readAsStringSync();
        for (final bad in ['api.dart', 'package:http', 'HttpClient', 'postJson', 'getJson']) {
          expect(src.contains(bad), isFalse, reason: '$f uses $bad');
        }
      }
    });
  });
}
