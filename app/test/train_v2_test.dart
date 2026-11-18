// train-app (Train Tracker V2, owner order 17 Nov) — the APP lane:
//  B  rider share: 30 s points, mock flag, auto-stop at the last station,
//     battery saver, saved queue that survives a restart, the one-time
//     "Are you on this train?" (on the line + train speed only);
//  C  serving cell sent only with the rider's extra yes;
//  D  offline pack: timetables + tower map, position from tower / timetable,
//     the offline screen clearly labelled; outbox syncs when online;
//  E  station check-in (reached / left) from the timeline;
//  F  "Share a train update": ANY pasted / shared text (16318 reply, group
//     post), on-phone preview, sent or queued offline — no SMS reading;
//  I  destination alarm: asked ONCE, shares only on yes;
//  J  timeline V2 (passed green + delay, train speed + riders, next yellow),
//     freshness live / N min ago / predicted / timetable, Bangla digits,
//     200 % text + dark without overflow.
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
import 'package:assisto/screens/train/train_line_view.dart';
import 'package:assisto/screens/train/train_paste_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/screens/train/train_v2_widgets.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/train/train_fgs.dart';
import 'package:assisto/train/train_offline.dart';
import 'package:assisto/train/train_api.dart';
import 'package:assisto/train/train_onboard.dart';
import 'package:assisto/train/train_share_service.dart';
import 'package:assisto/train/train_sms_parse.dart';
import 'package:assisto/train/train_v2_native.dart';

import 'fake_train.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.offline = false});
  final bool empty;
  bool offline;
  final posts = <(String, Map<String, dynamic>)>[];
  final gets = <String>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (offline) throw const SocketException('offline');
    gets.add(path);
    return fakeTrainGet(path, bn: true, empty: empty) ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    if (offline) throw const SocketException('offline');
    posts.add((path, Map.of(body)));
    return fakeTrainPost(path, body) ?? {'ok': true};
  }
}

class _Native extends TrainNative {
  _Native({this.cell, this.low = false});
  final TrainCell? cell;
  final bool low;
  int cellReads = 0;
  @override
  Future<TrainCell?> servingCell() async {
    cellReads++;
    return cell;
  }

  @override
  Future<TrainPower> power() async => TrainPower(low ? 12 : 80, false);
}

const _cumillaCell = TrainCell(mcc: '470', mnc: '01', tac: 1234, cid: 56789, rat: 'lte');

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

const _stations = [
  TrainSmsStation('o5', 'কুমিল্লা', 'Cumilla'),
  TrainSmsStation('o9', 'ভৈরব বাজার', 'Bhairab Bazar'),
  TrainSmsStation('n3', 'ঢাকা বিমানবন্দর', 'Dhaka Airport'),
  TrainSmsStation('n2', 'কমলাপুর', 'Kamalapur'),
];

TrainOfflinePack _pack() => TrainOfflinePack.fromJson(trainOfflinePackJson(), savedAt: DateTime.now());

// a Wednesday (the fake pack has no off days)
DateTime _at(int h, int m) => DateTime(2026, 11, 18, h, m);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TrainFgs.disabled = true;
    TrainNative.disabledForTests = true;
    TrainNative.I = _Native();
    TrainShareController.I = TrainShareController(useService: false, persist: false);
    TrainOutbox.I = TrainOutbox();
    TrainOfflineStore.I = TrainOfflineStore(dir: Directory.systemTemp.createTempSync('tr2'));
    FeatureFlags.instance.debugOverride = {'dest_alarm': true, 'train_tracker': true};
  });
  tearDown(() async {
    await TrainShareController.I.stop(remote: false);
    FeatureFlags.instance.debugOverride = null;
  });

  // ------------------------------------------------------------ F parser
  group('F: shared text -> train position (no SMS reading)', () {
    final now = _at(10, 40);
    test('16318 English reply: train, station, left, time, late h:mm', () {
      final r = parseTrain16318(
          'Train No.701 SUBARNA EXPRESS Departed from CUMILLA at 10:25 AM. Late: 0:18',
          stations: _stations, now: now)!;
      expect(r.no, '701');
      expect(r.stationId, 'o5');
      expect(r.kind, 'left');
      expect(r.at, _at(10, 25));
      expect(r.lateMin, 18);
    });

    test('Bangla post with Bangla digits: reached, 12 h pm, "১৫ মিনিট দেরি"', () {
      final r = parseTrain16318('ট্রেন ৭০১ ভৈরব বাজার পৌঁছেছে ১০:৩০ এ, ১৫ মিনিট দেরি',
          stations: _stations, now: now)!;
      expect(r.no, '701');
      expect(r.stationId, 'o9');
      expect(r.kind, 'reached');
      expect(r.at, _at(10, 30));
      expect(r.lateMin, 15);
    });

    test('group post in Banglish with "(701)" and on time', () {
      final r = parseTrain16318('Subarna (701) just arrived Dhaka Airport, on time. 11:05 pm', // a late night post
          stations: _stations, now: _at(23, 20))!;
      expect(r.no, '701');
      expect(r.stationId, 'n3');
      expect(r.kind, 'reached');
      expect(r.at, _at(23, 5));
      expect(r.lateMin, 0);
    });

    test('a time 2 h+ "in the future" is yesterday; no number -> expected train', () {
      final r = parseTrain16318('Left Kamalapur 23:50', stations: _stations, expectNo: '701', now: _at(0, 20))!;
      expect(r.no, '701');
      expect(r.at, DateTime(2026, 11, 17, 23, 50));
    });

    test('nothing to place -> null', () {
      expect(parseTrain16318('hello, how are you', stations: _stations, now: now), isNull);
      expect(parseTrain16318('', stations: _stations), isNull);
    });
  });

  // ------------------------------------------------------------ D offline
  group('D: offline pack + position', () {
    test('timetable parse handles past-midnight times', () {
      final t = parseOffTrain({
        'no': '9',
        'stops': [
          {'id': 'a', 'km': 0, 'dep': '23:30'},
          {'id': 'b', 'km': 50, 'arr': '00:20', 'dep': '00:25'},
          {'id': 'c', 'km': 90, 'arr': '01:10'},
        ]
      })!;
      expect([for (final s in t.stops) s.arrMin], [0, 50, 100]);
      expect(t.depMin, 23 * 60 + 30);
      // half way between b and c at 00:47:30
      final p = timetablePosition(t, DateTime(2026, 11, 19, 0, 47, 30));
      expect(p.state, 'running');
      expect(p.km, closeTo(70, 0.1));
    });

    test('timetable estimate: dwell at a stop, between stops, before, after, off day', () {
      final tr = _pack().trains['701']!;
      expect(timetablePosition(tr, _at(9, 16)).km, 154.1); // standing at Cumilla
      final mid = timetablePosition(tr, _at(8, 50)); // Feni -> Cumilla
      expect(mid.km, greaterThan(90));
      expect(mid.km, lessThan(154.1));
      expect(timetablePosition(tr, _at(6, 0)).state, 'not_started');
      expect(timetablePosition(tr, _at(13, 0)).state, 'arrived');
      // compact bundle: off-day bitmask, bit0 = Monday -> bit 2 = Wednesday
      final j = trainOfflinePackJson();
      ((j['tr'] as List)[0] as List)[5] = 4;
      final off = TrainOfflinePack.fromJson(j).trains['701']!;
      expect(off.offDays, {3});
      expect(timetablePosition(off, _at(9, 0)).state, 'off_day'); // Wednesday off
    });

    test('compact bundle: suspended train labelled, km from coordinates when missing', () {
      final p = _pack();
      expect(p.version, 'a1b2c3d4e5f6');
      final m = p.trains['3109']!;
      expect(m.suspended, isTrue);
      expect(timetablePosition(m, _at(12, 0)).state, 'suspended');
      expect(m.stops.last.km, greaterThan(100)); // Dhaka -> Benapole, straight line
      expect(p.trains['701']!.suspended, isFalse);
      expect(p.trains['701']!.stops[2].lat, closeTo(23.4607, 1e-6));
    });

    test('tower position: the learned point projected on this train\'s route; "01" == "1"', () {
      final p = _pack(), tr = p.trains['701']!;
      expect(towerPosition(p, tr, _cumillaCell, _at(9, 0))!.km, closeTo(160.0, 0.5));
      final st = towerPosition(p, tr, const TrainCell(mcc: '470', mnc: '3', tac: 77, cid: 4242), _at(9, 0))!;
      expect(st.km, closeTo(234.3, 0.5));
      expect(st.source, 'tower');
      expect(towerPosition(p, tr, const TrainCell(mcc: '470', mnc: '1', tac: 1, cid: 2), _at(9, 0)), isNull);
      expect(towerPosition(p, tr, null, _at(9, 0)), isNull);
    });

    test('offline line has the server shape + its source', () {
      final p = _pack(), tr = p.trains['701']!;
      final line = trainOfflineLine(tr, towerPosition(p, tr, _cumillaCell, _at(9, 30))!);
      expect(line['source'], 'tower');
      expect((line['stations'] as List).length, 6);
      expect(line['now_index'], 2); // past Cumilla
      expect(line['next_index'], 3); // Bhairab next
      expect(line['passing'], isNull); // 6 km after Cumilla
    });

    test('store: download -> saved file -> loads again; size + stale', () async {
      final dir = Directory.systemTemp.createTempSync('tr2s');
      final s = TrainOfflineStore(dir: dir);
      expect(await s.load(), isNull);
      expect(await s.download((have) async => trainOfflinePackJson()), isTrue);
      expect(s.pack!.trains.keys, containsAll(['701', '3109']));
      expect(s.pack!.sizeBytes, greaterThan(500));
      expect(s.pack!.stale, isFalse);
      final again = TrainOfflineStore(dir: dir);
      expect((await again.load())!.towers.length, 2);
      // no internet: keeps what it has
      expect(await again.download((have) async => throw const SocketException('x')), isFalse);
      expect(again.pack, isNotNull);
      expect(trainSizeLabel(431000), '421 KB');
      expect(trainSizeLabel(1300000), '1.2 MB');
    });

    test('downloads the ENGINE pack (/train/offline/pack, tw filled), not the raw bundle', () async {
      final api = _Fake();
      final s = TrainOfflineStore(dir: Directory.systemTemp.createTempSync('tr2e'));
      expect(await s.download(api.trainOfflinePack), isTrue);
      expect(api.gets.single, '/train/offline/pack');
      // engine tower_map() rows: [mcc, mnc, tac, cid, segment, metres, samples, lat*1e5, lng*1e5]
      expect(s.pack!.towers.keys, containsAll(['470-1-1234-56789', '470-3-77-4242']));
      expect(s.pack!.towers['470-1-1234-56789']!.single.lat, closeTo(23.50426, 1e-6));
      // up to date -> the server answers {version, same: true}; the phone keeps its pack
      expect(await s.download((have) async {
        expect(have, 'a1b2c3d4e5f6');
        return {'version': have, 'same': true};
      }), isTrue);
      expect(s.pack!.towers.length, 2);
    });

    test('engine tower point on a curved line (km off the stop-to-stop chord) is still placed', () {
      final j = trainOfflinePackJson();
      // half way Cumilla -> Bhairab, ~5 km east of the straight chord
      (j['tw'] as List).add([470, 7, 900, 123456, 31, 2200, 9, 2375660, 9112765]);
      final p = TrainOfflinePack.fromJson(j), tr = p.trains['701']!;
      final pos = towerPosition(
          p, tr, const TrainCell(mcc: '470', mnc: '07', tac: 900, cid: 123456), _at(10, 0))!;
      expect(pos.source, 'tower');
      expect(pos.km, inInclusiveRange(175.0, 215.0));
      // the raw bundle has an empty tw: no tower, the timetable is used
      final raw = trainOfflinePackJson()..['tw'] = [];
      final p2 = TrainOfflinePack.fromJson(raw);
      expect(towerPosition(p2, p2.trains['701']!, _cumillaCell, _at(10, 0)), isNull);
      // 8-field rows (no learned point) are ignored, never misplaced
      final short = trainOfflinePackJson()..['tw'] = [[470, 1, 1234, 56789, 12, 640, 14, 2350426]];
      expect(TrainOfflinePack.fromJson(short).towers, isEmpty);
    });

    test('outbox: offline keeps reports, sends them when online, drops refused ones', () async {
      final api = _Fake(offline: true);
      final box = TrainOutbox();
      final at = DateTime.now().toUtc().toIso8601String();
      await box.add(TrainOutItem('checkin', '701', {'station_id': 'o5', 'kind': 'left', 'at': at}));
      await box.add(TrainOutItem('text', '701', {'text': 'TR 701 left Cumilla', 'at': at}));
      expect(await box.flush(api), 0);
      expect(box.value, 2);
      api.offline = false;
      expect(await box.flush(api), 2);
      expect(box.value, 0);
      expect(api.posts.map((p) => p.$1), ['/train/701/checkin', '/train/text']);
    });
  });

  // ------------------------------------------------------------ B / C share
  group('B + C: rider share', () {
    TrainFix fix(double lat, double lng, {bool mock = false}) =>
        TrainFix(lat, lng, 8, DateTime.now(), speedKmh: 60, mock: mock);

    test('30 s, mock flag sent, cell only with the extra yes', () async {
      expect(TrainShareController.every, const Duration(seconds: 30));
      expect(TrainShareController.maxQueue, 240);
      final nat = _Native(cell: _cumillaCell);
      final sent = <Map<String, dynamic>>[];
      final c = TrainShareController(
          position: () async => fix(23.4, 91.1, mock: true), useService: false, native: nat, persist: false);
      await c.start(1, '701', (id, pts) async {
        sent.addAll(pts);
        return {'accepted': 0, 'rejected': 1, 'status': 'active'};
      }, stopRemote: (_) async {}, title: '', text: '', stopLabel: '');
      expect(sent.single['mock'], isTrue);
      expect(sent.single.containsKey('cell'), isFalse);
      expect(nat.cellReads, 0); // never read without the opt-in
      await c.stop(remote: false);
      sent.clear();
      await c.start(2, '701', (id, pts) async {
        sent.addAll(pts);
        return {'status': 'active'};
      }, stopRemote: (_) async {}, title: '', text: '', stopLabel: '', cell: true);
      expect(sent.single['cell'], {'mcc': '470', 'mnc': '01', 'tac': 1234, 'cid': 56789, 'rat': 'lte'});
      await c.stop(remote: false);
    });

    test('auto-stop within 800 m of the last station (tells the server)', () async {
      var stopped = 0;
      final c = TrainShareController(
          position: () async => fix(23.7330, 90.4265), useService: false, persist: false);
      await c.start(3, '701', (id, pts) async => {'accepted': 1, 'status': 'active'},
          stopRemote: (_) async => stopped++,
          title: '',
          text: '',
          stopLabel: '',
          lastStop: (23.73195, 90.42627));
      expect(c.value.status, 'arrived');
      expect(c.sharing, isFalse);
      expect(stopped, 1);
    });

    test('offline points are saved, marked queued, and sent after a restart', () async {
      var online = false;
      final sent = <Map<String, dynamic>>[];
      Future<Map<String, dynamic>> send(int id, List<Map<String, dynamic>> pts) async {
        if (!online) throw const SocketException('x');
        sent.addAll(pts);
        return {'status': 'active'};
      }

      final c = TrainShareController(position: () async => fix(23.4, 91.1), useService: false);
      await c.start(4, '701', send, stopRemote: (_) async {}, title: '', text: '', stopLabel: '');
      await c.tick();
      expect(c.value.offline, isTrue);
      expect(c.value.queued, 2);
      // the app is closed while offline
      await c.stop(remote: false);
      final fresh = TrainShareController(useService: false);
      online = true;
      expect(await fresh.flushSaved(send), 2);
      expect(sent.every((p) => p['queued'] == true), isTrue);
      expect(await fresh.flushSaved(send), 0); // sent once only
    });

    test('battery under 20 % and not charging -> 60 s saver', () async {
      final c = TrainShareController(
          position: () async => null, useService: true, native: _Native(low: true), persist: false);
      await c.start(5, '701', (id, pts) async => {'status': 'active'},
          stopRemote: (_) async {}, title: '', text: '', stopLabel: '');
      expect(c.value.saver, isTrue);
      expect(TrainShareController.everySaver, const Duration(seconds: 60));
      await c.stop(remote: false);
    });

    test('"Are you on this train?": on the line at train speed only, once', () async {
      final path = [
        [23.40, 91.10],
        [23.50, 91.10],
      ];
      final t0 = DateTime.now();
      TrainFix at(double lat, int s, {double lng = 91.10, bool mock = false}) =>
          TrainFix(lat, lng, 8, t0.add(Duration(seconds: s)), mock: mock);
      // 500 m in 30 s = 60 km/h on the line
      expect(trainLooksOnboard(at(23.42, 0), at(23.4245, 30), path), isTrue);
      expect(trainLooksOnboard(at(23.42, 0, lng: 91.12), at(23.4245, 30, lng: 91.12), path), isFalse); // 2 km off
      expect(trainLooksOnboard(at(23.42, 0), at(23.4201, 30), path), isFalse); // walking
      expect(trainLooksOnboard(at(23.42, 0), at(23.4245, 30, mock: true), path), isFalse);
      expect(trainDistToPathM(23.45, 91.10, path), lessThan(1));

      final fixes = [at(23.42, 0), at(23.4245, 30), at(23.429, 60)];
      var i = 0, asked = 0;
      final w = TrainOnboardWatch(
          no: '701', date: '2026-11-18', path: path, fix: () async => fixes[i++ % 3], onAsk: () async => asked++);
      await w.start();
      await w.check();
      await w.check();
      expect(asked, 1);
      w.stop();
      expect(await trainOnboardAsked('701', '2026-11-18'), isTrue);
      final again = TrainOnboardWatch(
          no: '701', date: '2026-11-18', path: path, fix: () async => fixes[1], onAsk: () async => asked++);
      await again.start(); // already asked today: never again
      again.stop();
      expect(asked, 1);
    });
  });

  // ------------------------------------------------------------ J screen
  group('J: timeline V2 + freshness', () {
    testWidgets('passed green with delay, train speed + riders, next yellow; Bangla digits', (t) async {
      _tall(t);
      final line = trainLine701(DateTime.now(), live: true);
      await t.pumpWidget(_app(
          Scaffold(body: SingleChildScrollView(child: TrainLineView(line: line, speedKmh: 62, riders: 3))),
          _Fake()));
      await t.pump();
      expect(find.byKey(const ValueKey('tr2_next')), findsOneWidget);
      expect(find.text('৬২ কিমি/ঘণ্টা · ৩ জন লাইভ'), findsOneWidget);
      expect(find.textContaining('+১৬ মি.'), findsOneWidget); // Cumilla, confirmed late
      for (final w in t.widgetList<Text>(find.byType(Text))) {
        expect(RegExp(r'[0-9]').hasMatch(w.data ?? ''), isFalse, reason: w.data);
      }
    });

    test('freshness: live / N min ago / predicted / timetable', () {
      expect(trainFreshOf({'live': {'age_s': 30}}).kind, 'live');
      final ago = trainFreshOf({'live': {'age_s': 400}});
      expect((ago.kind, ago.ageMin), ('stale', 7));
      expect(trainFreshOf({'freshness': {'state': 'predicted'}}).kind, 'predicted');
      expect(trainFreshOf({'mode': 'estimate'}).kind, 'timetable');
      expect(trainFreshOf({'freshness': {'state': 'estimate'}}).kind, 'timetable');
      final l = lookupAppLocalizations(const Locale('en'));
      final labels = [
        for (final k in ['live', 'stale', 'predicted', 'timetable', 'offline_tower', 'offline_timetable'])
          trainFreshLabel(l, TrainFresh(k, 5))
      ];
      expect(labels.toSet().length, 6);
      for (final s in labels) {
        expect(s.contains('100'), isFalse); // never "100 % accurate"
      }
    });

    testWidgets('live screen: freshness chip, rider why, paste button; station -> check-in posted',
        (t) async {
      _tall(t);
      final api = _Fake();
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), api));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tr2_fresh')), findsOneWidget);
      expect(find.text('লাইভ'), findsOneWidget);
      expect(find.byKey(const ValueKey('tr2_paste_open')), findsOneWidget);
      await t.ensureVisible(find.text('কসবা').first);
      await t.tap(find.text('কসবা').first);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tr2_station_sheet')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tr2_ci_reached')));
      await t.pumpAndSettle();
      final p = api.posts.singleWhere((p) => p.$1 == '/train/701/checkin');
      expect(p.$2['station_id'], 'o6');
      expect(p.$2['kind'], 'reached');
      expect(find.text('ধন্যবাদ — গণনা হয়েছে'), findsOneWidget);
    });

    testWidgets('rider toggle: consent with benefits + tower opt-in -> sharing with cell', (t) async {
      _tall(t);
      final api = _Fake();
      TrainShareController.I =
          TrainShareController(position: () async => null, useService: false, persist: false);
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), api, lang: 'en'));
      await t.pumpAndSettle();
      final l = lookupAppLocalizations(const Locale('en'));
      await t.ensureVisible(find.text(l.trImOnTrain));
      await t.tap(find.text(l.trImOnTrain));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tr2_benefits')), findsOneWidget);
      expect(find.text(l.tr2BenefitPoints), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tr2_cell_optin')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('tr2_share_go')));
      await t.pumpAndSettle();
      expect(api.posts.any((p) => p.$1 == '/train/701/share'), isTrue);
      expect(TrainShareController.I.sharing, isTrue);
      expect(TrainShareController.I.cellOptIn, isTrue);
      expect(find.text(l.tr2AutoStop), findsOneWidget);
      await TrainShareController.I.stop(remote: false);
    });

    testWidgets('offline screen: tower + timetable label, never "live"', (t) async {
      _tall(t);
      TrainNative.I = _Native(cell: _cumillaCell);
      TrainOfflineStore.I.debugSet(_pack());
      await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), _Fake(offline: true)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tr2_offline_body')), findsOneWidget);
      expect(find.text('অফলাইন: মোবাইল টাওয়ার + সময়সূচি'), findsOneWidget);
      expect(find.text('লাইভ'), findsNothing);
    });

    for (final dark in [false, true]) {
      testWidgets('200 % text, ${dark ? 'dark' : 'light'}: screens without overflow', (t) async {
        _tall(t);
        await t.pumpWidget(_app(const TrainLiveScreen(no: '701', date: '2026-11-03'), _Fake(),
            dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(_app(const TrainPasteScreen(no: '701', date: '2026-11-03', stations: _stations),
            _Fake(), lang: 'en', dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(_app(const TrainTrackerScreen(), _Fake(), dark: dark, scale: 2));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      });
    }
  });

  // ------------------------------------------------------------ F screen
  group('F: share a train update', () {
    testWidgets('paste -> preview -> sent; offline -> saved for later', (t) async {
      _tall(t);
      final api = _Fake();
      await t.pumpWidget(
          _app(const TrainPasteScreen(no: '701', date: '2026-11-18', stations: _stations), api, lang: 'en'));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('tr2_paste_box')),
          'TR 701: Subarna Express left Cumilla at 10:25. Late 18 min');
      await t.pump();
      expect(find.byKey(const ValueKey('tr2_paste_preview')), findsOneWidget);
      expect(find.text('Train 701'), findsOneWidget);
      expect(find.text('left Cumilla'), findsOneWidget);
      expect(find.text('18 min late'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tr2_paste_send')));
      await t.pumpAndSettle();
      final p = api.posts.single;
      expect(p.$1, '/train/text');
      expect(p.$2['source'], 'paste');
      expect(p.$2['no'], '701');
      expect(find.text('Thank you — the train is updated for everyone'), findsOneWidget);
      api.offline = true;
      await t.tap(find.byKey(const ValueKey('tr2_paste_send')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tr2_paste_result')), findsOneWidget);
      expect(TrainOutbox.I.value, 1);
    });

    test('no READ_SMS anywhere; the share target is text only and off by default', () {
      final yml = File('../.github/workflows/android.yml').readAsStringSync();
      expect(yml.contains('android.permission.READ_SMS'), isFalse);
      final i = yml.indexOf('train.TrainShareActivity');
      expect(i, greaterThan(0));
      final block = yml.substring(i, yml.indexOf('</activity>', i));
      expect(block, contains('android:enabled="false"'));
      expect(block, contains('text/plain'));
      final kt = File('android_overlay/app/src/main/kotlin/com/assisto/assisto/train/TrainV2Channel.kt')
          .readAsStringSync();
      expect(kt.contains('READ_PHONE_STATE"'), isFalse);
      expect(kt.contains('Telephony.Sms'), isFalse);
    });
  });

  // ------------------------------------------------------------ I alarm
  group('I: destination alarm asks once', () {
    testWidgets('yes shares; the question is remembered for this train + day', (t) async {
      _tall(t);
      var answer = false;
      await t.pumpWidget(_app(
          Builder(
              builder: (ctx) => Scaffold(
                    body: Center(
                      child: TextButton(
                          onPressed: () async => answer = await showTrainAlarmShareAsk(ctx),
                          child: const Text('go')),
                    ),
                  )),
          _Fake()));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('tr2_alarm_ask')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tr2_alarm_yes')));
      await t.pumpAndSettle();
      expect(answer, isTrue);
      expect(await trainAlarmShareAsked('701', '2026-11-18'), isFalse);
      await trainAlarmShareMarkAsked('701', '2026-11-18');
      expect(await trainAlarmShareAsked('701', '2026-11-18'), isTrue);
    });
  });
}
