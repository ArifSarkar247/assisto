// sjtrain (Safe Journey V2, owner order 9 Nov 11:15) — TRAIN 1-9 + the
// DESTINATION ALARM, app side:
//  * OFFLINE ALARM PROOF: 60 simulated trips (city bus, long bus, train,
//    launch; by distance AND by minutes; GPS noise, sparse fixes, a stop in
//    traffic) with NO network — every one rings BEFORE the stop (100 %);
//  * "N minutes before" rings by the ETA at the phone's own speed and still
//    by distance when the vehicle stands still;
//  * full-screen ring notice shown on ring and removed on "I am awake";
//  * train screen: header + delay chip, "N passengers sharing live",
//    "Now: passing X", metro-style line (passed / next with ETA), seat card,
//    get-off alarm + chat buttons; estimate clearly labelled; Bangla digits;
//    200 % text + dark without overflow;
//  * seat card: facts marked verified / unverified, sun "calculated",
//    one-tap answers posted;
//  * chat: closed bar outside the train's running time.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/train/train_chat_screen.dart';
import 'package:assisto/screens/train/train_line_view.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/dest_alarm_math.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:assisto/train/dest_alarm_sound.dart';
import 'package:assisto/train/train_fgs.dart';

import 'fake_train.dart';

const _lat = 23.7385, _lng = 90.3960;
(double, double) _north(double m) => (_lat + m / 111320.0, _lng);

class _Sound implements DestAlarmSound {
  int starts = 0, stops = 0;
  @override
  Future<bool> start({required bool sound, required bool vibrate}) async {
    starts++;
    return true;
  }

  @override
  Future<bool> speak(String text, String lang) async => true;
  @override
  Future<bool> playClip(String path) async => true;
  @override
  Future<bool> vibrateOnce() async => true;
  @override
  Future<void> stop() async => stops++;
}

class _Notice implements DestRingNotice {
  int shown = 0, cancelled = 0;
  @override
  Future<void> show(DestPlan plan, DestAlarmTexts texts) async => shown++;
  @override
  Future<void> cancel() async => cancelled++;
}

DestAlarmTexts _tx() => DestAlarmTexts(
    distance: (m) => '${m.round()} m',
    notifTitle: 'n',
    notifText: 'n',
    stop: 's',
    lang: 'bn',
    spoken: (s, d) => 'জেগে উঠুন $s',
    ready: (s, d) => 'r');

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.chat});
  final bool empty;
  final Map<String, dynamic>? chat;
  final gets = <String>[];
  final posts = <(String, Map<String, dynamic>)>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path.contains('/chat') && chat != null) return chat!;
    return fakeTrainGet(path, bn: true, empty: empty) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add((path, Map.of(body)));
    if (path.contains('/seat')) return trainSeat701();
    return {'ok': true};
  }
}

Widget _app(Widget child, ApiClient api, {String lang = 'bn', bool dark = false, double scale = 1}) {
  final s = AppState();
  s.api = api;
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      locale: Locale(lang),
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
  t.view.physicalSize = const Size(1080, 9000);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

/// One simulated trip: the vehicle moves toward the stop at [mps] (stops for
/// [stallS] seconds in traffic at [stallAtM]), GPS fixes every [fixS] s with
/// [noiseM] error. Returns the distance (m) left when it rang, or -1 when it
/// passed the stop without ringing. NO network anywhere (the API is absent).
Future<double> _trip(
    {required TransportMode mode,
    required double startM,
    required double mps,
    required int setM,
    int? etaMin,
    int fixS = 20,
    double noiseM = 15,
    double stallAtM = -1,
    int stallS = 0,
    int seed = 1}) async {
  final rng = math.Random(seed);
  var d = startM;
  var clock = DateTime(2026, 11, 9, 8);
  var stallLeft = 0;
  var stallUsed = false;
  final c = DestAlarmController(
      position: () async {
        final e = (rng.nextDouble() * 2 - 1) * noiseM;
        final p = _north(math.max(0, d + e));
        return DestFix(p.$1, p.$2, accuracy: noiseM, speedMps: stallLeft > 0 ? 0 : mps);
      },
      battery: () async => 60,
      sound: _Sound(),
      clock: () => clock,
      useService: false,
      repeatEvery: const Duration(hours: 1));
  await c.start(
      DestPlan(mode: mode, target: const DestTarget('Stop', _lat, _lng), setM: setM, etaMin: etaMin),
      _tx());
  var rangAt = -1.0;
  for (var step = 0; step < 100000; step++) {
    if (c.value.phase == DestAlarmPhase.ringing) {
      rangAt = d;
      break;
    }
    if (d <= 0) break; // passed the stop without ringing
    for (var sec = 0; sec < fixS && d > 0; sec++) {
      if (!stallUsed && stallAtM >= 0 && d <= stallAtM) {
        stallUsed = true;
        stallLeft = stallS; // stuck in traffic
      }
      if (stallLeft > 0) {
        stallLeft--;
        continue;
      }
      d -= mps;
    }
    clock = clock.add(Duration(seconds: fixS));
    await c.tick();
  }
  await c.stop();
  return rangAt;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TrainFgs.disabled = true;
    FeatureFlags.instance.resetForTest();
    DestAlarmController.ringNotice = null;
  });
  tearDown(() {
    FeatureFlags.instance.resetForTest();
    DestAlarmController.ringNotice = null;
    DestAlarmController.arrivedNotifier = null;
  });

  group('OFFLINE destination alarm proof (no network in any trip)', () {
    test('60 trips: bus / long bus / train / launch, by km and by minutes -> 100 % ring before the stop',
        () async {
      final cases = <(TransportMode, double, double, int, int?)>[
        // mode, start m, speed m/s, set m, minutes
        (TransportMode.cityBus, 6000, 6, 300, null),
        (TransportMode.cityBus, 6000, 9, 100, 2),
        (TransportMode.longBus, 60000, 20, 2000, null),
        (TransportMode.longBus, 60000, 22, 1000, 10),
        (TransportMode.train, 40000, 18, 1000, null),
        (TransportMode.train, 40000, 25, 1000, 5),
        (TransportMode.launch, 20000, 5, 1000, null),
        (TransportMode.launch, 20000, 6, 500, 15),
      ];
      var trips = 0, rang = 0;
      final misses = <String>[];
      for (final cse in cases) {
        for (var seed = 1; seed <= 8 && trips < 60; seed++) {
          final stall = seed.isEven; // a stop in traffic near the end
          final left = await _trip(
              mode: cse.$1,
              startM: cse.$2,
              mps: cse.$3,
              setM: clampFor(cse.$1, cse.$4),
              etaMin: cse.$5,
              fixS: [10, 20, 30, 45][seed % 4],
              noiseM: [8.0, 15.0, 30.0][seed % 3],
              stallAtM: stall ? 1500 : -1,
              stallS: stall ? 240 : 0,
              seed: seed);
          trips++;
          if (left > 0) {
            rang++;
          } else {
            misses.add('${cse.$1.name} ${cse.$5 ?? '-'}min seed $seed');
          }
          if (cse.$5 != null && left > 0) {
            // by minutes: rang roughly N minutes out (or earlier), never at the stop
            expect(left, greaterThan(cse.$3 * 30), reason: '${cse.$1} seed $seed');
          }
        }
      }
      // ignore: avoid_print
      print('SJTRAIN PROOF offline destination alarm: $rang / $trips trips rang before the stop');
      expect(trips, 60);
      expect(misses, isEmpty);
      expect(rang, trips);
    });

    test('by minutes: 10 min before at 20 m/s rings ~12 km out; standing still -> distance rule',
        () async {
      final left = await _trip(
          mode: TransportMode.longBus, startM: 60000, mps: 20, setM: 1000, etaMin: 10, fixS: 10, noiseM: 5);
      expect(left, inInclusiveRange(10000, 12500));
      // parked 800 m away: no speed -> the 1 km distance rule still rings
      var d = 800.0;
      final c = DestAlarmController(
          position: () async {
            final p = _north(d);
            return DestFix(p.$1, p.$2, accuracy: 5, speedMps: 0);
          },
          battery: () async => 50,
          sound: _Sound(),
          useService: false,
          repeatEvery: const Duration(hours: 1));
      await c.start(
          const DestPlan(
              mode: TransportMode.longBus, target: DestTarget('X', _lat, _lng), setM: 1000, etaMin: 10),
          _tx());
      expect(c.value.phase, DestAlarmPhase.ringing);
      await c.stop();
    });

    test('full-screen ring notice: shown once on ring, removed on I am awake', () async {
      final n = _Notice();
      DestAlarmController.ringNotice = n;
      final c = DestAlarmController(
          position: () async => const DestFix(_lat, _lng, accuracy: 5),
          battery: () async => null,
          sound: _Sound(),
          useService: false,
          repeatEvery: const Duration(hours: 1),
          snoozeFor: const Duration(milliseconds: 30));
      await c.start(
          const DestPlan(mode: TransportMode.train, target: DestTarget('X', _lat, _lng), setM: 500),
          _tx());
      expect(c.value.phase, DestAlarmPhase.ringing);
      expect(n.shown, 1);
      await c.snooze();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(n.shown, 1, reason: 'a snooze re-ring is not a new full screen');
      await c.confirmAwake();
      expect(n.cancelled, 1);
      expect(c.value.phase, DestAlarmPhase.off);
    });
  });

  group('train screen', () {
    Future<void> pump(WidgetTester t, {bool live = true, String lang = 'bn', bool dark = false,
        double scale = 1}) async {
      _tall(t);
      FeatureFlags.instance.debugOverride = {'dest_alarm': true, 'train_tracker': true};
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), _Fake(empty: !live),
          lang: lang, dark: dark, scale: scale));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
    }

    testWidgets('live: header + delay chip + N sharing + now/next + line + seat card + buttons',
        (t) async {
      await pump(t);
      expect(find.byKey(const ValueKey('sjt_header')), findsOneWidget);
      expect(find.textContaining('১৮ মিনিট দেরি'), findsOneWidget);
      expect(find.text('৩ জন যাত্রী লাইভ শেয়ার করছেন'), findsOneWidget);
      expect(find.byKey(const ValueKey('sjt_now')), findsOneWidget);
      expect(find.textContaining('পরের স্টেশন: কসবা'), findsOneWidget);
      expect(find.byKey(const ValueKey('sjt_line')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjt_seat_card')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjt_getoff')), findsOneWidget);
      expect(find.byKey(const ValueKey('sjt_chat')), findsOneWidget);
      // Bangla digits everywhere on the line
      for (final w in t.widgetList<Text>(find.descendant(
          of: find.byKey(const ValueKey('sjt_line')), matching: find.byType(Text)))) {
        expect(RegExp(r'[0-9]').hasMatch(w.data ?? ''), isFalse, reason: w.data);
      }
      // expand the line: every station
      await t.tap(find.byKey(const ValueKey('sjt_line_toggle')));
      await t.pump();
      expect(find.text('কমলাপুর'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('estimate: clearly labelled, nobody sharing, "Now: passing" from the timetable',
        (t) async {
      await pump(t, live: false);
      expect(find.text('সময়সূচি থেকে আনুমানিক'), findsOneWidget);
      expect(find.textContaining('এখন: কুমিল্লা পার হচ্ছে'), findsWidgets);
      expect(find.textContaining('লাইভ শেয়ার করছেন'), findsNothing);
    });

    testWidgets('English, dark, 200 % text: no overflow', (t) async {
      await pump(t, lang: 'en', dark: true, scale: 2);
      expect(find.text('3 passengers sharing live'), findsOneWidget);
      expect(find.textContaining('18 min late'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('seat card: saved seat -> verified / unverified / calculated; answers posted',
        (t) async {
      SharedPreferences.setMockInitialValues({'sjt_seat_701': '{"coach":"ঝ","seat":"32"}'});
      _tall(t);
      final api = _Fake();
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), api));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('কোচ ঝ · সিট ৩২'), findsOneWidget);
      expect(find.textContaining('যাচাই করা · ৩ জন যাত্রী একমত'), findsOneWidget);
      expect(find.textContaining('যাচাই হয়নি'), findsWidgets);
      expect(find.textContaining('রেললাইন ও সময়সূচি থেকে হিসাব করা'), findsWidgets);
      await t.ensureVisible(find.byKey(const ValueKey('sjt_seat_ask')));
      await t.tap(find.byKey(const ValueKey('sjt_seat_ask')));
      await t.pumpAndSettle();
      await t.tap(find.text('পেছনের দিকে মুখ করা').last);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('sjt_ask_send')));
      await t.pumpAndSettle();
      final post = api.posts.lastWhere((p) => p.$1.contains('/seat'));
      expect(post.$2['facing'], 'backward');
      expect(post.$2['coach'], 'ঝ');
      expect(post.$2.containsKey('place'), isFalse, reason: 'skipped questions are not sent');
    });

    testWidgets('seat card empty state: benefit + big button + how-to', (t) async {
      await pump(t);
      await t.ensureVisible(find.byKey(const ValueKey('sjt_seat_add')));
      expect(find.byKey(const ValueKey('sjt_seat_add')), findsOneWidget);
      expect(find.textContaining('টিকিট দেখে কোচ ও সিট নম্বর লিখুন'), findsOneWidget);
    });
  });

  group('station line widget', () {
    testWidgets('train between stations: passed grey, "Train has left X"', (t) async {
      _tall(t);
      final line = trainLine701(DateTime.now(), live: true);
      await t.pumpWidget(_app(Scaffold(body: SingleChildScrollView(child: TrainLineView(line: line))),
          _Fake(), lang: 'en'));
      await t.pump();
      expect(find.text('Train has left Cumilla'), findsOneWidget);
      final s = trainLineStatus(lookupAppLocalizations(const Locale('en')), line, false);
      expect(s, startsWith('Next: Kasba'));
    });
  });

  group('train chat', () {
    testWidgets('closed outside the running time: no input, says when it opens', (t) async {
      _tall(t);
      final room = trainChatRoom()
        ..['chat'] = {
          'open': false,
          'opens_at': DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String(),
          'closes_at': DateTime.now().add(const Duration(hours: 9)).toUtc().toIso8601String(),
        };
      await t.pumpWidget(_app(
          const TrainChatScreen(no: '701', date: '2026-11-03', title: 'সুবর্ণ এক্সপ্রেস'),
          _Fake(chat: room)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('sjt_chat_closed')), findsOneWidget);
      expect(find.textContaining('চ্যাট খুলবে'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });
}
