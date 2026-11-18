// gap-nearby: Nearby + City Service proof on the emulator, its own reality
// group `nearbycity` (seed_reality loads the made-up nearby + city samples
// on the CI backend; never live data).
//
// 40_nearby_refresh — the emulator's REAL GPS is moved to the sample
//   Farmgate point (`adb emu geo fix`), Nearby opens from its route, the list
//   loads from the CI backend, pull-to-refresh really asks the server again
//   (NearbyScreen.areaRequests before/after in the result note), then REAL
//   airplane mode: reopen -> the saved list with its date; pull -> honest
//   "couldn't update".
// 41_city_map_fare_alarm — the real MapLibre map renders (style + tiles from
//   our own map server, screenshot), the metro fare between two stations
//   equals the official chart in the repo (backend/core/citytransit/fares.py
//   METRO_CHART: Uttara North <-> Agargaon = Tk 60, Uttara North <->
//   Motijheel = Tk 100), and the get-off alarm armed OFFLINE fires on a
//   mocked GPS route (far -> midway -> near the stop).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/config.dart';
import 'package:assisto/screens/city/city_map_screen.dart';
import 'package:assisto/screens/city/city_metro_screen.dart';
import 'package:assisto/screens/city/city_service_screen.dart';
import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/train/dest_alarm_service.dart';
import 'package:assisto/widgets/nearby_category_bar.dart';

import '../support/harness.dart';

const _farmgate = (lat: 23.7577, lon: 90.3897);
const _motijheel = (name: 'Motijheel', address: '', lat: 23.7330, lng: 90.4177);
var _n = 0;

Future<void> _ack(RFlow f, String line, String file, {double seconds = 20}) async {
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('$line $file');
  final end = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) return;
  }
  f.note('no ack for $file');
}

/// Move the emulator's real GPS (the host runs `adb emu geo fix`).
Future<void> _geo(RFlow f, double lat, double lon) async {
  await _ack(f, 'REALITY_GEO ${lat.toStringAsFixed(6)} ${lon.toStringAsFixed(6)}', 'geo_nc_${_n++}');
  await f.pumpFor(const Duration(seconds: 2)); // let the fix reach the location service
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

/// REAL airplane mode through the CI host (as offline_first_flow).
Future<void> _airplane(RFlow f, bool on) async {
  await _ack(f, 'REALITY_NET ${on ? 'off' : 'on'}', 'net_nc_${on ? 'off' : 'on'}_${_n++}', seconds: 40);
  await f.eventually(on ? 'backend UNREACHABLE (airplane mode)' : 'backend reachable again',
      () async => (await _reachable()) != on,
      seconds: on ? 30 : 90);
}

Future<void> _pull(RFlow f) async {
  // back to the top first (the numbers card is the first item), then pull
  final list = find.descendant(
      of: find.byKey(const ValueKey('nearby_refresh')).last, matching: find.byType(Scrollable)).first;
  await f.tester.dragUntilVisible(
      find.byKey(const ValueKey('nearby_emergency_numbers')), list, const Offset(0, 300), maxIteration: 15);
  await f.pumpFor(const Duration(milliseconds: 800));
  await f.tester.fling(find.byKey(const ValueKey('nearby_emergency_numbers')).last, const Offset(0, 600), 1500);
  await f.pumpFor(const Duration(seconds: 1));
}

/// Metres north of a point (for the mocked route).
(double, double) _north((double, double) p, double m) => (p.$1 + m / 111195.0, p.$2);

void registerNearbyCityFlows() {
  realityFlow('40_nearby_refresh', 'Safety',
      'Nearby: opens on real GPS, list loads, pull-to-refresh refetches (request count), offline = saved list + date',
      (f) async {
    await f.home();
    await f.step('real GPS at the sample point, open Nearby from its route', () async {
      await _geo(f, _farmgate.lat, _farmgate.lon);
      NearbyScreen.areaRequests = 0;
      await f.openRoute('nearby', settleSeconds: 4);
      await f.waitFor(find.byType(NearbyScreen), what: 'Nearby');
      await f.waitFor(find.byKey(const ValueKey('nearby_emergency_numbers')), what: 'official numbers');
      await f.shot('nearby_open');
    });
    await f.step('the list loads from the server (nearest first, unnamed place titled, sourced number)', () async {
      await f.waitFor(find.text('Sample Hospital One'), seconds: 30, what: 'sample hospitals');
      await f.shot('nearby_list');
      final list = find.descendant(
          of: find.byKey(const ValueKey('nearby_refresh')).last, matching: find.byType(Scrollable)).first;
      final unnamed = find.text(f.t.nearbyUnnamedPlace(f.t.nearbyCatHospital));
      await f.tester.dragUntilVisible(unnamed, list, const Offset(0, -300), maxIteration: 15);
      await f.pumpFor(const Duration(milliseconds: 600));
      await f.shot('nearby_unnamed_titled');
      // the category bar scrolls sideways: bring "Police" into view
      final bar = find.descendant(of: find.byType(NearbyCategoryBar), matching: find.byType(Scrollable)).first;
      final police = find.text(f.t.nearbyCatPolice);
      await f.tester.dragUntilVisible(police, bar, const Offset(-250, 0), maxIteration: 10);
      await f.tap(police.last, settleSeconds: 2);
      await f.waitFor(find.text('Sample Police Station'), what: 'police list');
      await f.waitFor(find.text(f.t.nearbyPhoneSrcOsm), what: 'number source under Call');
      await f.shot('nearby_police_sourced');
      await f.tester.dragUntilVisible(find.text(f.t.nearbyCatHospital), bar, const Offset(250, 0), maxIteration: 10);
      await f.tap(find.text(f.t.nearbyCatHospital).last, settleSeconds: 2);
      await f.waitFor(find.text('Sample Hospital One'), what: 'hospitals again');
    });
    await f.step('pull-to-refresh really asks the server again', () async {
      final before = NearbyScreen.areaRequests;
      await _pull(f);
      await f.waitFor(find.byKey(const ValueKey('nearby_refreshed')), seconds: 20, what: '"updated" message');
      final after = NearbyScreen.areaRequests;
      f.note('area requests before pull=$before after pull=$after');
      expect(after, before + 1);
      await f.shot('nearby_refreshed');
    });
    await f.step('airplane mode: reopen -> saved list with its date; pull -> honest failure', () async {
      await _airplane(f, true);
      try {
        await f.back();
        await f.openRoute('nearby', settleSeconds: 4);
        await f.waitFor(find.byKey(const ValueKey('nearby_offline_note')), seconds: 30, what: 'offline note');
        final note = f.tester.widget<Text>(find.byKey(const ValueKey('nearby_offline_note')).last).data ?? '';
        f.note('offline note: "$note"');
        expect(note.isNotEmpty && note != f.t.nearbyOfflineNote, isTrue, reason: note); // has the date
        expect(find.text('Sample Hospital One'), findsWidgets);
        await f.shot('nearby_offline_dated');
        final before = NearbyScreen.areaRequests;
        await _pull(f);
        await f.waitFor(find.byKey(const ValueKey('nearby_refresh_failed')), seconds: 30, what: 'honest failure');
        f.note('offline pull: requests $before -> ${NearbyScreen.areaRequests}');
        await f.shot('nearby_offline_pull');
      } finally {
        await _airplane(f, false);
      }
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('41_city_map_fare_alarm', 'Daily life',
      'City: real map renders, metro fare for 2 stations = official chart, offline stop alarm fires on mocked GPS',
      (f) async {
    await f.home();
    await f.step('the real map (MapLibre + our own tiles) renders', () async {
      await f.pushScreen(const CityMapScreen(here: _farmgate), settleSeconds: 4);
      await f.waitFor(find.byKey(const ValueKey('city_map_gl_ready')), seconds: 60, what: 'map style + tiles loaded');
      await f.pumpFor(const Duration(seconds: 6)); // tiles paint
      await f.shot('city_map_gl');
      await f.back();
    });
    await f.step('metro: fare between two stations = the official chart', () async {
      await f.pushScreen(const CityMetroScreen(), settleSeconds: 4);
      final list = find.descendant(
          of: find.byKey(const ValueKey('city_metro_list')).last, matching: find.byType(Scrollable)).first;
      final card = find.byKey(const ValueKey('city_metro_pair'));
      await f.tester.dragUntilVisible(card, list, const Offset(0, -250), maxIteration: 20);
      await f.pumpFor(const Duration(milliseconds: 600));
      // default pair: first -> last station (Uttara North -> Motijheel)
      await f.waitFor(find.byKey(const ValueKey('city_metro_pair_tk_100')), what: 'UTN -> MOT = Tk 100 (chart)');
      await f.tap(find.byKey(const ValueKey('city_metro_pair_to')).last, settleSeconds: 2);
      await f.tap(find.byWidgetPredicate((w) => w is Text && (w.data == 'Agargaon' || w.data == 'আগারগাঁও')).last, settleSeconds: 2);
      await f.waitFor(find.byKey(const ValueKey('city_metro_pair_tk_60')), what: 'UTN -> AGA = Tk 60 (chart)');
      f.note('UTN-MOT Tk 100, UTN-AGA Tk 60 (fares.py METRO_CHART)');
      await f.shot('city_metro_pair_fare');
      await f.back();
    });
    await f.step('offline get-off alarm fires on a mocked GPS route', () async {
      await _geo(f, _farmgate.lat, _farmgate.lon);
      await f.pushScreen(const CityServiceScreen(debugHere: _farmgate, debugTo: _motijheel, debugSimple: false),
          settleSeconds: 4);
      await f.waitFor(find.byKey(const ValueKey('city_option')), seconds: 25, what: 'route option');
      await _airplane(f, true);
      try {
        await f.tap(find.byKey(const ValueKey('city_start_sj')).first, settleSeconds: 3);
        await f.waitFor(find.byKey(const ValueKey('city_sj_go')), what: 'start sheet');
        await f.tap(find.byKey(const ValueKey('city_sj_go')).last, settleSeconds: 4);
        await f.eventually('alarm armed offline',
            () async => DestAlarmController.I.value.phase != DestAlarmPhase.off, seconds: 20);
        final tgt = DestAlarmController.I.value.plan!.target;
        f.note('alarm stop "${tgt.name}" at ${tgt.lat.toStringAsFixed(4)},${tgt.lng.toStringAsFixed(4)}');
        await f.shot('city_alarm_armed_offline');
        // mocked route: 2.5 km away -> 1 km -> 150 m from the stop
        for (final m in [2500.0, 1000.0, 150.0]) {
          final p = _north((tgt.lat, tgt.lng), m);
          await _geo(f, p.$1, p.$2);
          // the foreground service ticks on its own schedule; tick now so
          // the proof does not wait minutes between far fixes
          await f.net(() => DestAlarmController.I.tick());
          await f.pumpFor(const Duration(seconds: 1));
          final v = DestAlarmController.I.value;
          f.note('at ${m.round()} m: phase=${v.phase.name} gps=${v.distanceM?.round()} m');
          if (m > 400) expect(v.phase, isNot(DestAlarmPhase.ringing));
        }
        await f.eventually('the alarm rings near the stop',
            () async => DestAlarmController.I.value.phase == DestAlarmPhase.ringing, seconds: 30);
        await f.shot('city_alarm_ringing');
      } finally {
        await f.net(() => DestAlarmController.I.stop());
        await _airplane(f, false);
      }
    });
  }, timeout: const Duration(minutes: 7));
}
