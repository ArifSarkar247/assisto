// train (owner priority C) — Train tracker + destination alarm:
//  1 alarm radius maths OFFLINE with fixed coordinates (Kamalapur station);
//  2 adaptive GPS interval (far = slow, near = fast) + battery bounds;
//  3 the alarm controller rings inside the zone and Stop silences it;
//  4 sharing stops by itself when the server says arrived; offline keeps
//    the queue;
//  5 estimate is labelled ESTIMATE, SMS compose = "TR 701" to 16318, ৳4;
//  6 chat: nickname only (no profile anywhere), request-only My Circle,
//    emergency words -> 999 / 131 buttons;
//  7 200% text + Bangla + dark: no overflow.
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
  int starts = 0, stops = 0;
  final List<String> spoken = [];
  @override
  Future<bool> start() async {
    starts++;
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
    test('radius zones around Kamalapur', () {
      final p = north(kmlLat, kmlLng, 400);
      final d = haversineM(p.$1, p.$2, kmlLat, kmlLng);
      expect(d, closeTo(400, 5));
      expect(insideZone(d, 1000), isTrue);
      expect(insideZone(d, 500), isTrue);
      expect(insideZone(d, 300), isFalse);
      expect(insideZone(d, 100), isFalse);
      // a fix too inaccurate to trust never fires
      expect(insideZone(d, 500, accuracyM: 900), isFalse);
      expect(clampRadius(10), kCustomMin);
      expect(clampRadius(99999), kCustomMax);
      expect(kRadiusPresets, [1000, 500, 300, 100]);
    });

    test('adaptive interval: far slow, near fast, always within bounds', () {
      expect(adaptiveInterval(80000, 500), kMaxInterval);
      expect(adaptiveInterval(900, 500), kMinInterval);
      final mid = adaptiveInterval(5000, 500, speedMps: 20);
      expect(mid.inSeconds, inInclusiveRange(kMinInterval.inSeconds, kMaxInterval.inSeconds));
      expect(mid < adaptiveInterval(20000, 500, speedMps: 20), isTrue);
      for (final d in [0.0, 50.0, 600.0, 3000.0, 1e6]) {
        for (final b in [null, 5, 80]) {
          final iv = adaptiveInterval(d, 300, speedMps: 30, batteryPct: b);
          expect(iv >= kMinInterval && iv <= kMaxInterval, isTrue, reason: '$d $b');
        }
      }
    });

    test('battery: low battery stretches far checks but never the near zone', () {
      expect(adaptiveInterval(9000, 500, speedMps: 10, batteryPct: 10) >
          adaptiveInterval(9000, 500, speedMps: 10, batteryPct: 90), isTrue);
      expect(adaptiveInterval(800, 500, batteryPct: 5), kMinInterval);
      // 100 km at 60 km/h: a bounded number of GPS checks (fixed 5 s would be 1200)
      final n = checksForTrip(100000, 500, 16.7);
      expect(n, lessThan(160));
      expect(checksForTrip(100000, 500, 16.7, batteryPct: 10), lessThanOrEqualTo(n));
    });

    test('station search works on the bundled-format file', () {
      final s = parseStations('{"stations":[{"id":"1","en":"Kamalapur Railway Station","bn":"কমলাপুর",'
          '"lat":23.73195,"lng":90.42627},{"id":"2","en":"Chattogram Railway Station","bn":"চট্টগ্রাম",'
          '"lat":22.334,"lng":91.8296}]}');
      expect(searchStations(s, 'কমলা').single.en, startsWith('Kamalapur'));
      expect(searchStations(s, 'chatto').single.bn, 'চট্টগ্রাম');
      expect(searchStations(s, '', lat: 22.3, lng: 91.8).first.id, '2');
    });
  });

  group('alarm controller', () {
    test('rings inside the zone, speaks the stop name, Stop silences', () async {
      var dist = 3000.0;
      final sound = _Sound();
      final c = DestAlarmController(
          position: () async {
            final p = north(kmlLat, kmlLng, dist);
            return DestFix(p.$1, p.$2, accuracy: 10, speedMps: 15);
          },
          battery: () async => 70,
          sound: sound,
          useService: false);
      const tx = DestAlarmTexts(
          notifTitle: 'on', notifText: 'near', stop: 'Stop', spoken: 'জেগে উঠুন! কমলাপুর', lang: 'bn');
      await c.start(const DestTarget('কমলাপুর', kmlLat, kmlLng), 500, tx);
      expect(c.value.phase, DestAlarmPhase.watching);
      expect(sound.starts, 0);
      dist = 300;
      await c.stop();
      await c.start(const DestTarget('কমলাপুর', kmlLat, kmlLng), 500, tx);
      expect(c.value.phase, DestAlarmPhase.ringing);
      expect(sound.starts, 1);
      expect(sound.spoken.single, contains('কমলাপুর'));
      await c.stop();
      expect(sound.stops, 1);
      expect(c.value.phase, DestAlarmPhase.off);
    });

    test('location off is said honestly and nothing rings', () async {
      final sound = _Sound();
      final c = DestAlarmController(
          position: () async => null, battery: () async => null, sound: sound, useService: false);
      await c.start(const DestTarget('X', kmlLat, kmlLng), 1000,
          const DestAlarmTexts(notifTitle: '', notifText: '', stop: '', spoken: '', lang: 'en'));
      expect(c.value.locationOff, isTrue);
      expect(sound.starts, 0);
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
      expect(trainIsEmergency('একজন অসুস্থ'), isTrue);
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
