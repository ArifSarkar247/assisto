// train (owner priority C) — Train tracker + destination alarm:
//  1 alarm maths OFFLINE with fixed coordinates: every mode's trigger,
//    never-late rule with accuracy, metro counting without GPS, at-least-
//    one-alert rule, per-mode memory, recorded voice stays local;
//  2 adaptive GPS interval (far = slow, near = fast) + battery bounds;
//  3 the controller rings before the stop and keeps going until "I'm awake";
//  4 sharing stops by itself when the server says arrived; offline keeps
//    the queue;
//  5 estimate is labelled ESTIMATE, SMS compose = "TR 701" to 16318, ৳4;
//  6 chat: nickname only (no profile anywhere), request-only My Circle,
//    emergency words -> 999 / 131 buttons;
//  7 200% text + Bangla + dark: no overflow.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/train/train_chat_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:assisto/train/dest_alarm_sound.dart';
import 'package:assisto/train/train_api.dart';
import 'package:assisto/train/train_share_service.dart';

import 'fake_train.dart';

const kmlLat = 23.7319508, kmlLng = 90.4262749; // Kamalapur (OSM)

(double, double) north(double lat, double lng, double m) => (lat + m / 111320.0, lng);

class _Sound implements DestAlarmSound {
  int stops = 0;
  final List<(bool, bool)> starts = [];
  final List<String> spoken = [], clips = [];
  int buzz = 0;
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async {
    starts.add((sound, vibrate));
    return true;
  }

  @override
  Future<bool> playClip(String path) async {
    clips.add(path);
    return true;
  }

  @override
  Future<bool> vibrateOnce() async {
    buzz++;
    return true;
  }

  @override
  Future<bool> speak(String text, String lang) async {
    spoken.add('$lang:$text');
    return true;
  }

  @override
  Future<void> stop() async => stops++;
}

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.bn = false}) {
    token = 't';
  }
  final bool empty, bn;
  final List<(String, Map<String, dynamic>)> posts = [];
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      fakeTrainGet(path, bn: bn, empty: empty) ?? <String, dynamic>{};
  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    return {'ok': true};
  }
}

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
  t.view.physicalSize = const Size(1080, 5400);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('alarm maths (offline, fixed coordinates)', () {
    test('mode defaults and slider ranges (owner order)', () {
      expect(kModeSpecs[TransportMode.cityBus]!.defaultM, 10);
      expect(kModeSpecs[TransportMode.cityBus]!.minM, 10);
      expect(kModeSpecs[TransportMode.cityBus]!.maxM, 5000);
      expect(kModeSpecs[TransportMode.longBus]!.defaultM, 2000);
      expect(kModeSpecs[TransportMode.longBus]!.minM, 500);
      expect(kModeSpecs[TransportMode.longBus]!.maxM, 20000);
      expect(kModeSpecs[TransportMode.launch]!.defaultM, 2000);
      expect(clampFor(TransportMode.cityBus, 1), 10);
      expect(clampFor(TransportMode.longBus, 99999), 20000);
    });

    test('never-late rule: (distance - accuracy) <= set', () {
      expect(neverLate(400, 0, 500), isTrue);
      expect(neverLate(600, 0, 500), isFalse);
      expect(neverLate(600, 150, 500), isTrue); // poor GPS rings early
      expect(neverLate(40, 25, 10), isFalse);
      expect(neverLate(30, 25, 10), isTrue);
      expect(neverLate(5000, 4600, 500), isTrue);
      // Kamalapur, a fix 400 m north
      final p = north(kmlLat, kmlLng, 400);
      final d = haversineM(p.$1, p.$2, kmlLat, kmlLng);
      expect(d, closeTo(400, 5));
      expect(neverLate(d, 10, 500), isTrue);
      expect(neverLate(d, 10, 300), isFalse);
      expect(neverLate(d, 120, 300), isTrue);
    });

    test('city bus: gentle buzz ~200 m before, then ring', () {
      final w = DistanceWatch(TransportMode.cityBus, 10);
      expect(w.update(900, 5), AlarmEvent.none);
      expect(w.update(205, 5), AlarmEvent.gentle);
      expect(w.update(150, 5), AlarmEvent.none); // once
      expect(w.update(14, 5), AlarmEvent.ring);
      expect(w.update(5, 5), AlarmEvent.none);
    });

    test('long bus / launch: get ready at ~10 km only on trips over 30 km', () {
      for (final m in [TransportMode.longBus, TransportMode.launch]) {
        final w = DistanceWatch(m, 2000);
        expect(w.update(60000, 20), AlarmEvent.none);
        expect(w.update(9900, 20), AlarmEvent.ready);
        expect(w.update(2010, 20), AlarmEvent.ring);
        final short = DistanceWatch(m, 2000);
        expect(short.update(20000, 20), AlarmEvent.none);
        expect(short.update(9000, 20), AlarmEvent.none); // trip < 30 km: no notice
        expect(short.update(1900, 20), AlarmEvent.ring);
      }
    });

    test('train: rings when the train LEAVES the station before yours', () {
      final w = TrainLegWatch(6000, fallbackM: 1000);
      expect(w.update(3000, 9000, 20), AlarmEvent.none); // approaching prev
      expect(w.update(200, 6100, 20), AlarmEvent.none); // at prev (stopped)
      expect(w.seenPrev, isTrue);
      expect(w.update(500, 5600, 20), AlarmEvent.none); // still at the platform end
      expect(w.update(900, 5200, 20), AlarmEvent.ring); // left -> yours is next
      // GPS fallback when the previous station was never seen
      final f = TrainLegWatch(6000, fallbackM: 1000);
      expect(f.update(8000, 1500, 20), AlarmEvent.none);
      expect(f.update(8000, 1100, 200), AlarmEvent.ring); // never-late with accuracy
    });

    test('metro: one station before by counting stations + time (no GPS)', () {
      final st = [
        for (var i = 0; i < 6; i++) MetroStation('S$i', 'স$i', 23.8 + i * 0.01, 90.36, 2.0)
      ];
      final t0 = DateTime(2026, 11, 3, 9);
      // from 0 to 5: ring when leaving station 4 = 4 segments x 2 min
      expect(metroRingAt(st, 0, 5, t0), t0.add(const Duration(minutes: 8)));
      expect(metroStationAt(st, 0, 5, t0, t0.add(const Duration(minutes: 5))), 2);
      // reverse direction 5 -> 1: leave station 2 = 3 segments
      expect(metroRingAt(st, 5, 1, t0), t0.add(const Duration(minutes: 6)));
      // the next station is already yours: ring as you leave
      expect(metroRingAt(st, 2, 3, t0), t0);
    });

    test('at least one alert stays on; defaults voice ON, sound OFF, vibration ON', () {
      const a = AlertPrefs();
      expect([a.voice, a.sound, a.vibrate], [true, false, true]);
      final b = a.toggle(AlertKind.voice, false);
      expect(b.isLastOn(AlertKind.vibrate), isTrue);
      final c = b.toggle(AlertKind.vibrate, false); // refused
      expect(c.vibrate, isTrue);
      expect(c.onCount, 1);
      // a stored all-off value falls back to the defaults
      expect(AlertPrefs.fromJson({'voice': false, 'sound': false, 'vibrate': false}).onCount, 2);
      // the personal clip counts as Voice
      expect(a.withClip('/data/x.m4a').toggle(AlertKind.voice, true).personalClip, '/data/x.m4a');
    });

    test('per-mode memory', () async {
      await DestModeMemory.save(TransportMode.cityBus, 300,
          const AlertPrefs(voice: false, sound: true, vibrate: true));
      await DestModeMemory.save(TransportMode.longBus, 5000, const AlertPrefs());
      final (cm, ca) = await DestModeMemory.load(TransportMode.cityBus);
      final (lm, la) = await DestModeMemory.load(TransportMode.longBus);
      final (tm, ta) = await DestModeMemory.load(TransportMode.train);
      expect([cm, ca.voice, ca.sound], [300, false, true]);
      expect([lm, la.voice, la.sound], [5000, true, false]);
      expect(tm, 2000);
      expect(ta.voice, isTrue);
    });

    test('recorded voice stays on the phone (no upload, no AI)', () {
      final src = File('lib/train/dest_voice_recorder.dart').readAsStringSync();
      expect(src, contains('getApplicationDocumentsDirectory'));
      for (final bad in ['api.dart', 'package:http', 'postJson', 'upload(', 'Uri.parse']) {
        expect(src.contains(bad), isFalse, reason: bad);
      }
      final svc = File('lib/train/dest_alarm_service.dart').readAsStringSync();
      expect(svc.contains('package:http'), isFalse);
      expect(svc.contains('api.dart'), isFalse);
    });

    test('adaptive interval: far slow, near fast, battery bounds', () {
      expect(adaptiveInterval(80000, 500), kMaxInterval);
      expect(adaptiveInterval(700, 500), kMinInterval);
      for (final d in [0.0, 50.0, 600.0, 3000.0, 1e6]) {
        for (final b in [null, 5, 80]) {
          final iv = adaptiveInterval(d, 300, speedMps: 30, batteryPct: b);
          expect(iv >= kMinInterval && iv <= kMaxInterval, isTrue, reason: '$d $b');
        }
      }
      expect(adaptiveInterval(9000, 500, speedMps: 10, batteryPct: 10) >
          adaptiveInterval(9000, 500, speedMps: 10, batteryPct: 90), isTrue);
      expect(adaptiveInterval(700, 500, batteryPct: 5), kMinInterval);
      final n = checksForTrip(100000, 500, 16.7);
      expect(n, lessThan(160));
    });

    test('station + bus stop search on the bundled formats', () {
      final s = parseStations('{"stations":[{"id":"1","en":"Kamalapur Railway Station","bn":"কমলাপুর",'
          '"lat":23.73195,"lng":90.42627},{"id":"2","en":"Chattogram Railway Station","bn":"চট্টগ্রাম",'
          '"lat":22.334,"lng":91.8296}]}');
      expect(searchStations(s, 'কমলা').single.en, startsWith('Kamalapur'));
      expect(searchStations(s, '', lat: 22.3, lng: 91.8).first.id, '2');
      final b = parseStations('{"stops":[{"id":"b1","en":"Farmgate","bn":"","lat":23.75,"lng":90.38}]}');
      expect(b.single.en, 'Farmgate');
      expect(spokenDistanceParts(500), (false, '500'));
      expect(spokenDistanceParts(2000), (true, '2'));
      expect(spokenDistanceParts(2500), (true, '2.5'));
    });
  });

  group('alarm controller', () {
    DestAlarmTexts tx() => DestAlarmTexts(
        notifTitle: 'on',
        notifText: 'near',
        stop: 'Stop',
        lang: 'bn',
        spoken: (s, d) => 'জেগে উঠুন! $s আর $d',
        ready: (s, d) => 'প্রস্তুত হোন $s',
        distance: (m) => '${m.round()} মিটার');

    test('rings before the stop, voice repeats, keeps going until "I am awake"', () async {
      var dist = 3000.0;
      final sound = _Sound();
      final c = DestAlarmController(
          position: () async {
            final p = north(kmlLat, kmlLng, dist);
            return DestFix(p.$1, p.$2, accuracy: 10, speedMps: 15);
          },
          battery: () async => 70,
          sound: sound,
          useService: false,
          repeatEvery: const Duration(milliseconds: 20));
      const tg = DestTarget('কমলাপুর', kmlLat, kmlLng);
      await c.start(const DestPlan(mode: TransportMode.longBus, target: tg, setM: 500), tx());
      expect(c.value.phase, DestAlarmPhase.watching);
      dist = 480;
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.ringing);
      expect(sound.starts.single, (false, true)); // sound OFF, vibration ON by default
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(sound.spoken.length, greaterThan(1)); // keeps saying it
      expect(sound.spoken.first, contains('কমলাপুর'));
      await c.confirmAwake();
      expect(sound.stops, 1);
      expect(c.value.phase, DestAlarmPhase.off);
    });

    test('personal clip is played instead of the Bangla voice', () async {
      final sound = _Sound();
      final c = DestAlarmController(
          position: () async => const DestFix(kmlLat, kmlLng, accuracy: 5),
          battery: () async => null,
          sound: sound,
          useService: false);
      await c.start(
          const DestPlan(
              mode: TransportMode.cityBus,
              target: DestTarget('X', kmlLat, kmlLng),
              setM: 10,
              alerts: AlertPrefs(personalClip: '/local/clip.m4a')),
          tx());
      expect(sound.clips.single, '/local/clip.m4a');
      expect(sound.spoken, isEmpty);
      await c.stop();
    });

    test('metro counts without any GPS', () async {
      final sound = _Sound();
      var now = DateTime(2026, 11, 3, 9);
      final st = [for (var i = 0; i < 4; i++) MetroStation('S$i', 'স$i', 23.8 + i, 90.0, 2.0)];
      final c = DestAlarmController(
          position: () async => null, // no GPS at all
          sound: sound,
          clock: () => now,
          useService: false);
      await c.start(
          DestPlan(
              mode: TransportMode.metro,
              target: const DestTarget('স3', 26.8, 90.0),
              setM: 0,
              metro: st,
              metroFrom: 0,
              metroTo: 3,
              metroLeftAt: now),
          tx());
      expect(c.value.phase, DestAlarmPhase.watching);
      now = now.add(const Duration(minutes: 4)); // left station 2
      await c.tick();
      expect(c.value.phase, DestAlarmPhase.ringing);
      await c.stop();
    });
  });

  group('sharing', () {
    test('stops by itself on arrival; offline keeps the points', () async {
      var offline = true;
      var stopped = 0;
      final sent = <int>[];
      final c = TrainShareController(
          position: () async => TrainFix(23.0, 91.0, 10, DateTime.now()), useService: false);
      await c.start(7, '701', (id, pts) async {
        if (offline) throw Exception('offline');
        sent.add(pts.length);
        return {'accepted': pts.length, 'rejected': 0, 'status': 'arrived'};
      }, stopRemote: (_) async => stopped++, title: '', text: '', stopLabel: '');
      expect(c.value.offline, isTrue);
      expect(c.sharing, isTrue);
      offline = false;
      await c.tick();
      expect(sent.single, 2); // the queued point + the new one
      expect(c.value.status, 'arrived');
      expect(c.sharing, isFalse);
      expect(stopped, 0); // server ended it; no extra call
    });

    test('one tap stop tells the server', () async {
      var stopped = 0;
      final c = TrainShareController(position: () async => null, useService: false);
      await c.start(8, '701', (id, pts) async => {'status': 'active'},
          stopRemote: (_) async => stopped++, title: '', text: '', stopLabel: '');
      await c.stop();
      expect(stopped, 1);
      expect(c.value.status, 'ended');
    });
  });

  group('SMS + emergency words', () {
    test('compose only: TR <no> to 16318; dialer links never auto-dial', () {
      expect(trainSmsUri('701').toString(), 'sms:16318?body=TR%20701');
      expect(trainTelUri('999').scheme, 'tel');
      final bnWords = parseEmergencyWords(File('assets/train/emergency_words.json').readAsStringSync());
      expect(trainIsEmergency('একজন অসুস্থ', bnWords), isTrue);
      expect(trainIsEmergency('একজন অসুস্থ'), isFalse); // Bangla list is data
      expect(trainIsEmergency('একজন অসুস্থ', bnWords), isTrue);
      expect(trainIsEmergency('please HELP'), isTrue);
      expect(trainIsEmergency('ami osustho'), isTrue);
      expect(trainIsEmergency('very helpful'), isFalse);
    });
  });

  group('screens', () {
    testWidgets('estimate is labelled; SMS button shows TR 701 / 16318 / ৳4', (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      final api = _Fake(empty: true);
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), api));
      await t.pumpAndSettle();
      expect(find.text(l.trModeEstimate), findsOneWidget);
      expect(find.text(l.trModeLive), findsNothing);
      expect(find.text(l.trEstimateWhy), findsOneWidget);
      expect(find.text(l.trSmsButton('TR 701', '16318')), findsOneWidget);
      expect(find.text(l.trSmsCost('4')), findsOneWidget);
      expect(find.text(l.trUnchecked), findsOneWidget);
      expect(find.text(l.trImOnTrain), findsOneWidget);
    });

    testWidgets('live shows sharers + delay, never a person', (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), _Fake()));
      await t.pumpAndSettle();
      expect(find.text(l.trModeLive), findsOneWidget);
      expect(find.text(l.trLiveLine('3', l.trLate('18'))), findsOneWidget);
    });

    testWidgets('chat: nickname only, emergency -> 999 / 131, request accept', (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      final api = _Fake();
      await t.pumpWidget(_app(const TrainChatScreen(no: '701', date: '2026-11-03', title: 'Subarna'), api));
      await t.pumpAndSettle();
      expect(find.text('Green'), findsWidgets);
      expect(find.text(l.trCall999), findsOneWidget);
      expect(find.text(l.trCall131), findsOneWidget);
      expect(find.text(l.trRequestFrom('Green')), findsOneWidget);
      await t.tap(find.text(l.trAccept));
      await t.pumpAndSettle();
      expect(api.posts.map((p) => p.$1), contains('/train/chat/request/9/accept'));
      // the message menu offers request / report / block — no "view profile"
      await t.tap(find.text('Train is stopped at Bhairab'));
      await t.pumpAndSettle();
      expect(find.text(l.trAddCircle), findsOneWidget);
      expect(find.text(l.trReport), findsOneWidget);
      expect(find.text(l.trBlock), findsOneWidget);
      expect(find.textContaining('rofile'), findsNothing);
      await t.tap(find.text(l.trAddCircle));
      await t.pumpAndSettle();
      expect(api.posts.map((p) => p.$1), contains('/train/chat/msg/1/circle'));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('chat join: rules + nickname, hotlines visible before joining', (t) async {
      _tall(t);
      final l = await AppLocalizations.delegate.load(const Locale('en'));
      final api = _Fake(empty: true);
      await t.pumpWidget(_app(const TrainChatScreen(no: '701', date: '2026-11-03', title: 'Subarna'), api));
      await t.pumpAndSettle();
      expect(find.text(l.trChatRules), findsOneWidget);
      await t.enterText(find.byType(TextField), 'নীল');
      await t.tap(find.text(l.trChatJoin));
      await t.pumpAndSettle();
      expect(api.posts.single.$1, '/train/701/chat/join');
      expect(api.posts.single.$2['nickname'], 'নীল');
      await t.pumpWidget(const SizedBox());
    });

    for (final dark in [false, true]) {
      testWidgets('Bangla 200% ${dark ? 'dark' : 'light'}: no overflow', (t) async {
        _tall(t);
        await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'),
            _Fake(bn: true), lang: 'bn', dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(_app(const TrainTrackerScreen(), _Fake(bn: true),
            lang: 'bn', dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      });
    }
  });
}
