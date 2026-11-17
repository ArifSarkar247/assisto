// train-e2e — the Train Tracker V2 END TO END on the emulator (board row 41,
// the owner's flagship). Runs ONLY in .github/workflows/train-e2e.yml
// (REALITY_ONLY=start,trainproof) against the throw-away Django
// (settings_e2eproof + a real Redis) AFTER the API proof
// (tools/e2e/train_e2e_driver.py: latency, payload, trust numbers).
//
// The real app UI, the real server, Rangpur Express 771 on its real OSM line.
// backend/ci_e2e/train_sim.py moves the TRAIN modules' clock so 771 runs
// "now" whatever the hour, and generates rider points; every point, check-in
// and text still goes through the real /train endpoints from this phone.
//
//   tp1  771 / 772 in the list (number, English name, Bangla digits), times
//   tp2  3 riders (mock=false) -> "Live", "3 passengers sharing live", speed,
//        "3 riders live", the next station + ETA; the timeline between the
//        right stations; an off-the-line rider and a mock rider rejected
//        (trust drops) and still "3"
//   tp3  riders stop -> "N min ago" -> "Predicted — not live" (learned
//        delay) -> "Timetable"
//   tp4  a pasted 16318 reply (2 people) -> the train moves to that station
//   tp5  station check-in: 1st "counts when one more agrees", 2nd agrees ->
//        accepted, a phone 55 km away -> not counted
//   tp6  no network (real airplane mode) -> the list from the phone's pack ->
//        the train page labelled "Offline: mobile tower + timetable" /
//        "Offline: timetable estimate"
// Every step: screenshots in English AND Bangla. All riders/texts are
// made-up sample data. The `train_tracker` switch stays OFF (A is a preview
// tester only).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/train/train_line_view.dart';
import 'package:assisto/screens/train/train_paste_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';

import '../support/harness.dart';

const _no = '771';
const _riderPhones = ['01999000101', '01999000102', '01999000103'];
const _riderPassword = 'ci-train-rider-sample'; // made-up CI-only accounts (seed_train_e2e)
final _bn = lookupAppLocalizations(const Locale('bn'));
final _tag = (DateTime.now().millisecondsSinceEpoch % 100000).toString();

String _date = '';
Map<String, dynamic> _g = const {};
final List<String> _tokens = [];

// ---------------------------------------------------------------- helpers
ApiClient _api(RFlow f) {
  final c = ApiClient.detached(f.app.api.token ?? '');
  c.lang = 'en';
  return c;
}

Future<Map<String, dynamic>> _sim(RFlow f, Map<String, dynamic> body) =>
    f.net(() => _api(f).postJson('/ci-e2e/train-sim', body));

final Map<int, ApiClient> _riders = {};

/// A made-up rider's own session — signed in as its OWN device id (a
/// sign-in from the app's device id would replace the app's session).
Future<ApiClient> _rider(RFlow f, int i) async {
  final have = _riders[i];
  if (have != null) return have;
  final appDevice = AppConfig.deviceId;
  AppConfig.deviceId = 'train-e2e-rider-$i';
  final String tok;
  try {
    tok = await f.net(() async =>
        (await ApiClient().login(identifier: _riderPhones[i], password: _riderPassword)).token);
  } finally {
    AppConfig.deviceId = appDevice;
  }
  final c = ApiClient.detached(tok);
  c.lang = 'en';
  return _riders[i] = c;
}

Finder _k(String k) => find.byKey(ValueKey(k));

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      return false;
    });

String _bnD(String s) =>
    s.replaceAllMapped(RegExp(r'\d'), (m) => '০১২৩৪৫৬৭৮৯'[int.parse(m[0]!)]);

AppLocalizations _t(RFlow f, bool bn) => bn ? _bn : f.t;

String _d(bool bn, String s) => bn ? _bnD(s) : s;

Map<String, dynamic> _m(Object? v) => Map<String, dynamic>.from((v ?? const {}) as Map);

Future<void> _lang(RFlow f, String code) async {
  await f.app.setLocale(Locale(code));
  await f.pumpFor(const Duration(seconds: 2));
}

/// Both languages of the current screen: en shot, bn shot, back to en.
Future<void> _shots(RFlow f, String name, {Future<void> Function(bool bn)? check}) async {
  if (check != null) await check(false);
  await f.shot('${name}_en');
  await _lang(f, 'bn');
  try {
    if (check != null) await check(true);
    await f.shot('${name}_bn');
  } finally {
    await _lang(f, 'en');
  }
}

Finder _chip(String label) => find.descendant(of: _k('tr2_fresh'), matching: find.text(label));

Future<void> _openList(RFlow f) async {
  if (find.byType(TrainTrackerScreen).evaluate().isNotEmpty &&
      find.byType(TrainLiveScreen).evaluate().isEmpty) {
    return;
  }
  try {
    await f.openFromDrawer(f.t.sjlNameTrain);
    await f.waitFor(find.byType(TrainTrackerScreen), seconds: 8, what: 'train list (drawer)');
  } catch (e) {
    f.note('drawer path: $e — pushed the list');
    await f.backToHome();
    await f.pushScreen(const TrainTrackerScreen());
  }
  await f.waitFor(find.byType(TrainTrackerScreen), what: 'train list');
}

Future<void> _search(RFlow f, String q) async {
  final field = find.descendant(of: find.byType(TrainSearchPanel), matching: find.byType(TextField));
  await f.waitFor(field, what: 'train search box');
  await f.tester.enterText(field.first, q);
  await f.pumpFor(const Duration(seconds: 3));
}

/// The 771 row -> the train page for [_date] (the day chip the user taps).
Future<void> _openLive(RFlow f) async {
  final live = find.byType(TrainLiveScreen);
  if (live.evaluate().isNotEmpty) {
    await f.back();
    await f.pumpFor(const Duration(seconds: 1));
  }
  await _openList(f);
  await _search(f, _no);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime.parse(_date).difference(today).inDays;
  final chip = day < 0 ? f.t.trYesterday : (day > 0 ? f.t.trTomorrow : f.t.trToday);
  await f.tap(find.text(chip).first, settleSeconds: 2);
  final row = find.textContaining('$_no · ');
  await f.waitFor(row, seconds: 20, what: 'the 771 row');
  await f.tap(row.first, settleSeconds: 3);
  if (!await f.appears(live, seconds: 10)) {
    f.note('row tap did not open the train page (ad gate?) — pushed it');
    await f.pushScreen(TrainLiveScreen(no: _no, date: _date));
  }
  await f.waitFor(_k('tr2_fresh'), seconds: 30, what: 'the freshness chip');
}

Future<void> _waitChip(RFlow f, String label, {double seconds = 40}) async {
  if (await f.appears(_chip(label), seconds: 8)) return;
  await _openLive(f); // a fresh load instead of waiting for the 30 s poll
  await f.waitFor(_chip(label), seconds: seconds, what: 'chip "$label"');
}

Future<bool> _reachable() async {
  final u = Uri.parse(AppConfig.apiBase);
  try {
    final s = await Socket.connect(u.host, u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80),
        timeout: const Duration(seconds: 2));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Ask the CI host to switch airplane mode (adb, tools/reality/run_flows.sh).
Future<void> _airplane(RFlow f, bool on) async {
  final file = 'net_${on ? 'off' : 'on'}_tp_$_tag';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_NET ${on ? 'off' : 'on'} $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) break;
  }
  await f.eventually(on ? 'backend unreachable (airplane on)' : 'backend reachable again',
      () async => (await _reachable()) != on,
      seconds: on ? 30 : 90);
}

// ---------------------------------------------------------------- flows
void registerTrainProofFlows() {
  realityFlow('tp1_data_771_772', 'Train Tracker', 'Rangpur Express 771/772 in the list: number, English name, Bangla digits, official times (bn + en)',
      (f) async {
    await f.step('the list from the drawer, search 771', () async {
      await _openList(f);
      await _search(f, _no);
      await f.waitFor(find.text('$_no · Rangpur Express'), seconds: 20, what: '771 · Rangpur Express');
      await f.waitFor(_sees(f.t.trDepArr('09:10', '19:00')), what: '771 times 09:10 -> 19:00');
      await f.shot('search_771_en');
    });
    await f.step('search by the English name: both directions', () async {
      await _search(f, 'Rangpur Express');
      await f.waitFor(find.text('772 · Rangpur Express'), seconds: 20, what: '772 row');
      await f.waitFor(_sees(f.t.trDepArr('20:00', '06:00')), what: '772 times 20:00 -> 06:00');
      await f.shot('search_name_en');
    });
    await f.step('Bangla: search ৭৭১', () async {
      await _lang(f, 'bn');
      try {
        await _search(f, '৭৭১');
        await f.waitFor(find.text('৭৭১ · রংপুর এক্সপ্রেস'), seconds: 20, what: '৭৭১ · রংপুর এক্সপ্রেস');
        await f.shot('search_771_bn');
      } finally {
        await _lang(f, 'en');
      }
    });
  }, timeout: const Duration(minutes: 5));

  realityFlow('tp2_live_three_riders', 'Train Tracker', '3 riders on the real line -> Live, 3 sharing, speed, next station ETA, timeline between the right stations; off-line + mock riders rejected, trust drops (bn + en)',
      (f) async {
    await f.step('fake clock: 771 between Natore and Santahar now', () async {
      final c = await _sim(f, {
        'op': 'clock',
        'no': _no,
        'minutes_after_dep': 300,
        'device_today': trainIsoDate(DateTime.now()),
      });
      _date = '${c['date']}';
      f.note('service date $_date, train clock ${c['now']}');
    });
    await f.step('3 riders ping through /train/ping (mock=false)', () async {
      _g = await _sim(f, {'op': 'riders', 'no': _no, 'date': _date, 'minutes': 6, 'delay_min': 10});
      final riders = (_g['riders'] as List).cast<List>();
      _tokens.clear();
      for (var k = 0; k < riders.length; k++) {
        final api = await _rider(f, k);
        final tr = await f.net(() => api.postJson('/train/$_no/trip', {'date': _date}));
        _tokens.add('${tr['token']}');
        final r = await f.net(() => api.postJson('/train/ping', {'token': _tokens[k], 'points': riders[k]}));
        expect((r['accepted'] as num).toInt(), greaterThanOrEqualTo(riders[k].length - 1),
            reason: 'rider $k: $r');
      }
    });
    final e = _m(_g['expect']);
    await f.step('the timeline: between the right stations (server line)', () async {
      final v = await f.net(() => _api(f).getJson('/train/$_no/live?date=$_date'));
      final line = _m(v['line']);
      final st = (line['stations'] as List).cast<Map>();
      final here = '${st[(line['now_index'] as num).toInt()]['id']}';
      final next = '${st[(line['next_index'] as num).toInt()]['id']}';
      expect(here, _m(e['prev'])['id'], reason: 'last station passed');
      expect(next, _m(e['next'])['id'], reason: 'next station');
      expect(v['sharers'], 3);
    });
    await f.step('the train page: Live, 3 sharing, speed, next station + ETA', () async {
      await _openLive(f);
      await _shots(f, 'live', check: (bn) async {
        final t = _t(f, bn);
        await f.waitFor(_chip(t.tr2FreshLive), seconds: 30, what: 'chip Live');
        await f.waitFor(find.text(_d(bn, t.sjtSharingMany('3'))), what: '3 passengers sharing live');
        await f.scrollTo(_k('tr2_next'));
        await f.waitFor(_k('tr2_next'), what: 'next station badge');
        await f.waitFor(_sees(_d(bn, t.tr2RidersLive('3'))), what: '3 riders live on the train');
        final unit = t.tr2Speed('#').split('#').last.trim(); // "km/h" | Bangla unit
        await f.waitFor(
            find.descendant(of: _k('tr2_train_facts'), matching: _sees(unit)), what: 'speed ($unit)');
        final next = _m(e['next']);
        await f.waitFor(_sees('${bn ? next['bn'] : next['en']}'), what: 'the next station by name');
      });
    });
    await f.step('outliers: off the line + mock location rejected, trust drops, still 3', () async {
      final o = _m(_g['outlier']);
      final api = _api(f);
      for (final kind in ['off_line', 'mock']) {
        final tr = await f.net(() => api.postJson('/train/$_no/trip', {'date': _date}));
        final r = await f.net(() => api.postJson('/train/ping', {'token': tr['token'], 'points': o[kind]}));
        expect(r['accepted'], 0, reason: '$kind: $r');
        expect(_m(r['reasons'])[kind], isNotNull, reason: '$kind: $r');
      }
      final st = await _sim(f, {'op': 'state', 'no': _no, 'date': _date});
      final trust = [for (final t in st['trips'] as List) (t['trust'] as num).toDouble()];
      expect(trust.length, 5);
      expect(trust[3], lessThan(0.6), reason: 'off-line rider trust $trust');
      expect(trust[4], lessThan(trust[3]), reason: 'mock rider trust $trust');
      expect(st['in_redis'], isTrue);
      f.note('trust after outliers: $trust');
      await _openLive(f);
      await f.waitFor(find.text(f.t.sjtSharingMany('3')), what: 'still 3 passengers');
      await f.shot('outliers_still_3_en');
    });
  }, timeout: const Duration(minutes: 8));

  realityFlow('tp3_freshness_ladder', 'Train Tracker', 'Riders stop -> "N min ago" -> "Predicted — not live" (learned delay) -> "Timetable" (bn + en)',
      (f) async {
    if (_date.isEmpty) f.skip('tp2 did not set the train clock');
    await f.step('riders stop, 4 minutes pass -> "N min ago"', () async {
      for (var k = 0; k < _tokens.length; k++) {
        final api = await _rider(f, k);
        await f.net(() => api.postJson('/train/trip/stop', {'token': _tokens[k]}));
      }
      await _sim(f, {'op': 'advance', 'no': _no, 'date': _date, 'minutes': 4});
      await _openLive(f);
      await _shots(f, 'stale', check: (bn) async {
        final t = _t(f, bn);
        final any = find.descendant(
            of: _k('tr2_fresh'),
            matching: find.byWidgetPredicate((w) =>
                w is Text &&
                [for (var n = 1; n <= 30; n++) '$n'].any((n) => (w.data ?? '') == _d(bn, t.tr2FreshAgo(n)))));
        await f.waitFor(any, seconds: 30, what: '"N min ago"');
      });
    });
    await f.step('16 minutes: the live state expired -> learned delay "Predicted"', () async {
      await _sim(f, {'op': 'learn', 'no': _no, 'date': _date, 'weeks': 4, 'delay_min': 16});
      final a = await _sim(f, {'op': 'advance', 'no': _no, 'date': _date, 'minutes': 12});
      expect(a['mode'], 'predicted', reason: '$a');
      await _waitChip(f, f.t.tr2FreshPredicted);
      await _shots(f, 'predicted', check: (bn) async {
        await f.waitFor(_chip(_t(f, bn).tr2FreshPredicted), what: 'chip Predicted');
      });
    });
    await f.step('nothing learned -> "Timetable", estimated', () async {
      await _sim(f, {'op': 'forget', 'no': _no});
      await _waitChip(f, f.t.tr2FreshTimetable);
      await _shots(f, 'timetable', check: (bn) async {
        await f.waitFor(_chip(_t(f, bn).tr2FreshTimetable), what: 'chip Timetable');
        await f.waitFor(find.text(_t(f, bn).sjtEstimated), what: 'estimated from the timetable');
      });
    });
  }, timeout: const Duration(minutes: 7));

  realityFlow('tp4_paste_16318', 'Train Tracker', 'A pasted 16318 reply (2 people agree) moves the train to that station (bn + en)',
      (f) async {
    if (_date.isEmpty) f.skip('tp2 did not set the train clock');
    late Map<String, dynamic> x;
    await f.step('someone else already shared the same reply', () async {
      x = await _sim(f, {'op': 'text16318', 'no': _no, 'date': _date, 'delay_min': 12});
      final b = await _rider(f, 2);
      final r = await f.net(() => b.postJson('/train/text', {'text': x['text'], 'source': 'paste'}));
      expect(r['status'], 'pending', reason: '$r');
    });
    await f.step('paste it in the app: preview, send -> "updated for everyone"', () async {
      await _openLive(f);
      await f.scrollTo(_k('tr2_paste_open'));
      await f.tap(_k('tr2_paste_open'), settleSeconds: 2);
      await f.waitFor(find.byType(TrainPasteScreen), what: 'paste screen');
      await f.tester.enterText(find.descendant(of: _k('tr2_paste_box'), matching: find.byType(EditableText)).first,
          '${x['text']}');
      await f.pumpFor(const Duration(seconds: 2));
      await f.waitFor(_k('tr2_paste_preview'), what: 'what the app understood');
      await f.waitFor(_sees('${_m(x['station'])['en']}'), what: 'the station in the preview');
      await f.shot('paste_preview_en');
      await _lang(f, 'bn');
      try {
        await f.shot('paste_preview_bn');
        await f.tap(_k('tr2_paste_send'), settleSeconds: 3);
        await f.waitFor(find.descendant(of: _k('tr2_paste_result'), matching: find.text(_bn.tr2TextApplied)),
            seconds: 20, what: 'applied (bn)');
        await f.shot('paste_applied_bn');
      } finally {
        await _lang(f, 'en');
      }
    });
    await f.step('the train page follows the report', () async {
      final n = await f.net(() => _api(f).getJson('/train/$_no/now?date=$_date'));
      expect(n['mode'], 'reported', reason: '$n');
      expect((n['ch'] as num).toDouble(), greaterThanOrEqualTo((_m(x['station'])['ch'] as num) - 200));
      await _openLive(f);
      await _shots(f, 'reported');
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('tp5_station_checkin', 'Train Tracker', 'Station check-in: 1 report waits, 2 agreeing are accepted, a phone 55 km away is not counted (bn + en)',
      (f) async {
    if (_date.isEmpty) f.skip('tp2 did not set the train clock');
    late Map<String, dynamic> next;
    await f.step('tap the next station on the timeline -> sheet (bn + en)', () async {
      final v = await f.net(() => _api(f).getJson('/train/$_no/live?date=$_date'));
      final line = _m(v['line']);
      next = _m((line['stations'] as List)[(line['next_index'] as num).toInt()]);
      await _openLive(f);
      final name = find.descendant(of: find.byType(TrainLineView), matching: find.text('${next['en']}'));
      await f.scrollTo(name);
      await f.tap(name.first, settleSeconds: 2);
      await f.waitFor(_k('tr2_station_sheet'), what: 'station sheet');
      await f.shot('checkin_sheet_en');
    });
    await f.step('"reached here" -> waits for one more person', () async {
      await f.tap(_k('tr2_ci_reached'), settleSeconds: 2);
      await f.waitFor(find.text(f.t.tr2CheckinPending), seconds: 15, what: 'pending snackbar');
      await f.shot('checkin_pending_en');
    });
    await f.step('a second person agrees -> accepted; 55 km away -> not counted', () async {
      final r1 = await _rider(f, 0);
      final a = await f.net(() => r1.postJson('/train/$_no/checkin',
          {'date': _date, 'station_id': next['id'], 'kind': 'reached'}));
      expect(a['status'], 'accepted', reason: '$a');
      final r2 = await _rider(f, 1);
      final lat = (next['lat'] as num).toDouble() + 0.5, lng = (next['lng'] as num).toDouble();
      final far = await f.net(() => r2.postJson('/train/$_no/checkin',
          {'date': _date, 'station_id': next['id'], 'kind': 'reached', 'lat': lat, 'lng': lng, 'acc': 15}));
      expect(far['status'], 'rejected', reason: '$far');
      expect(far['reason'], 'far_from_station');
      final n = await f.net(() => _api(f).getJson('/train/$_no/now?date=$_date'));
      expect(_m(n['checkins'])['${next['id']}'], 2, reason: '$n');
    });
    await f.step('the station sheet in Bangla', () async {
      await _openLive(f);
      await _lang(f, 'bn');
      try {
        final name =
            find.descendant(of: find.byType(TrainLineView), matching: find.text('${next['bn']}'));
        await f.scrollTo(name);
        await f.tap(name.first, settleSeconds: 2);
        await f.waitFor(_k('tr2_station_sheet'), what: 'station sheet (bn)');
        await f.waitFor(find.text(_bn.tr2CheckinReached), what: 'Bangla "reached here"');
        await f.shot('checkin_sheet_bn');
        await f.tester.tapAt(const Offset(20, 60));
        await f.pumpFor(const Duration(seconds: 1));
      } finally {
        await _lang(f, 'en');
      }
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('tp6_offline_pack', 'Train Tracker', 'No network (real airplane mode): the list from the phone pack -> the train page labelled tower / timetable estimate (bn + en)',
      (f) async {
    if (_date.isEmpty) f.skip('tp2 did not set the train clock');
    await f.step('download every timetable to the phone', () async {
      if (find.byType(TrainLiveScreen).evaluate().isNotEmpty) await f.back();
      await _openList(f);
      await _search(f, _no);
      await f.scrollTo(_k('tr2_offline_card'));
      if (_k('tr2_offline_ready').evaluate().isEmpty) {
        await f.tap(_k('tr2_offline_get'), settleSeconds: 3);
      }
      await f.waitFor(_k('tr2_offline_ready'), seconds: 40, what: 'offline pack saved');
      await f.shot('offline_ready_en');
    });
    try {
      await f.step('airplane mode: the list still finds 771 (from the pack)', () async {
        await _airplane(f, true);
        await _search(f, '');
        await _search(f, _no);
        await f.waitFor(_k('tr2_list_offline'), seconds: 20, what: 'offline strip on the list');
        await f.waitFor(find.textContaining('$_no · '), what: '771 row offline');
        await _shots(f, 'offline_list');
      });
      await f.step('the train page: offline estimate, labelled', () async {
        final row = find.textContaining('$_no · ');
        await f.tap(row.first, settleSeconds: 3);
        if (!await f.appears(find.byType(TrainLiveScreen), seconds: 10)) {
          await f.pushScreen(TrainLiveScreen(no: _no, date: _date));
        }
        await f.waitFor(_k('tr2_offline_body'), seconds: 40, what: 'offline train page');
        await _shots(f, 'offline_page', check: (bn) async {
          final t = _t(f, bn);
          final label = find.descendant(
              of: _k('tr2_fresh'),
              matching: find.byWidgetPredicate(
                  (w) => w is Text && (w.data == t.tr2FreshOfflineTt || w.data == t.tr2FreshTower)));
          await f.waitFor(label, what: 'offline label (tower / timetable)');
        });
      });
    } finally {
      await _airplane(f, false);
    }
  }, timeout: const Duration(minutes: 7));
}
