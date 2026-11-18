// vehicle-e2e (18 Nov): vehicle tracking end to end on the emulator.
//   A = the vehicle owner (the app on screen). The TRACKER is a simulated
//   SinoTrack ST-906 run from inside the test over real TCP to the runner's
//   tracker server (10.0.2.2:5023, started by reality.yml next to Django;
//   opt-in group: reality.yml only=vehicle). It speaks the real H02 protocol
//   exactly like the device: text "*HQ,<id>,V1,...#" frames for the first fix
//   and the ignition changes, 32-byte BINARY "$" position records while
//   driving, and "*HQ,<id>,V4,<cmd>,DONE,<hhmmss>#" replies to the server's
//   S20 (relay) / S71 (interval) commands.
//
// (a) A pairs the tracker by its device id in the app -> the setup screen
//     shows "First location received" when the first frame lands;
// (b) a made-up Dhaka drive (Dhanmondi 27 -> Panthapath -> Karwan Bazar) in
//     REAL time: the map's live marker and its trail move on screen;
// (c) ignition on / off, (d) overspeed (limit 60), (e) geofence exit (Home):
//     all in the app's notification centre;
// (f) engine cut while MOVING -> refused (with the "cut once it stops" offer);
//     held -> nothing reaches the tracker while it moves -> it stops -> the
//     relay command bytes reach the simulator -> V4 reply -> "confirmed";
//     restore the same way;
// (g) the tracker goes silent -> "Offline · last seen ..." + a "not
//     responding" alert (CI shortens the online window to its 60 s minimum);
// (h) today's trips / distance / top speed on the tracker screen.
// Latency (packet -> server -> app screen) is measured and written to the
// flow note + printed as VEH_E2E_LATENCY {json}.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:assisto/api.dart';
import 'package:assisto/screens/vehicle_tracker_screen.dart';
import 'package:assisto/vehicle/route_canvas.dart';
import 'package:assisto/vehicle/veh_format.dart';
import 'package:assisto/vehicle/veh_map.dart';
import 'package:assisto/vehicle/vehicle_api.dart' show vehNum;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _trackerHost = String.fromEnvironment('REALITY_TRACKER_HOST', defaultValue: '10.0.2.2');
const _trackerPort = int.fromEnvironment('REALITY_TRACKER_PORT', defaultValue: 5023);
const _pin = '2468'; // seed_reality._vehicle (CI throw-away DB only)
const _name = 'Dhaka Car';

// made-up sample places (no real user data)
const _home = (23.75600, 90.37400); // Dhanmondi 27
const _wps = [
  (23.75600, 90.37400), // Dhanmondi 27
  (23.75250, 90.38150), // Panthapath (west)
  (23.75100, 90.39000), // Panthapath (east)
  (23.75050, 90.39350), // Karwan Bazar
];
const _office = (23.75050, 90.39350);
// (from metre, km/h): traffic, a fast empty stretch over the 60 limit, traffic
const _speeds = [(0.0, 30.0), (700.0, 45.0), (950.0, 75.0), (1350.0, 35.0), (1850.0, 22.0)];
const _stepS = 3; // one fix every 3 s while moving (real time)

double _hav(double a1, double o1, double a2, double o2) {
  double r(double d) => d * math.pi / 180;
  final p1 = r(a1), p2 = r(a2);
  final a = math.pow(math.sin((p2 - p1) / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(r(o2 - o1) / 2), 2);
  return 2 * 6371000.0 * math.asin(math.min(1.0, math.sqrt(a)));
}

/// The drive as (lat, lng, speed, course) every [_stepS] seconds, ending at
/// Karwan Bazar (speed 0).
List<(double, double, double, int)> _trip() {
  final legs = <(double, double, double, double, double, double)>[];
  var total = 0.0;
  for (var i = 0; i + 1 < _wps.length; i++) {
    final d = _hav(_wps[i].$1, _wps[i].$2, _wps[i + 1].$1, _wps[i + 1].$2);
    legs.add((total, d, _wps[i].$1, _wps[i].$2, _wps[i + 1].$1, _wps[i + 1].$2));
    total += d;
  }
  (double, double, int) at(double m) {
    for (var i = 0; i < legs.length; i++) {
      final l = legs[i];
      if (m <= l.$1 + l.$2 || i == legs.length - 1) {
        final k = l.$2 == 0 ? 0.0 : ((m - l.$1) / l.$2).clamp(0.0, 1.0);
        final course = (math.atan2(l.$6 - l.$4, l.$5 - l.$3) * 180 / math.pi + 360) % 360;
        return (l.$3 + (l.$5 - l.$3) * k, l.$4 + (l.$6 - l.$4) * k, course.round());
      }
    }
    return (_wps.last.$1, _wps.last.$2, 0);
  }

  double v(double m) {
    var s = _speeds.first.$2;
    for (final p in _speeds) {
      if (m >= p.$1) s = p.$2;
    }
    return s;
  }

  final out = <(double, double, double, int)>[];
  var m = 0.0;
  while (m < total) {
    final p = at(m);
    final s = v(m);
    out.add((p.$1, p.$2, s, p.$3));
    m += s / 3.6 * _stepS;
  }
  out.add((_wps.last.$1, _wps.last.$2, 0.0, 0));
  return out;
}

String _two(int v) => v.toString().padLeft(2, '0');
String _hms(DateTime u) => '${_two(u.hour)}${_two(u.minute)}${_two(u.second)}';
String _dmy(DateTime u) => '${_two(u.day)}${_two(u.month)}${_two(u.year % 100)}';

/// A SinoTrack ST-906 (H02). Records every server command (text + raw hex)
/// and answers like the firmware: "*HQ,<id>,V4,<code>,DONE,<hhmmss>#".
class _St906 {
  _St906(this.id);
  final String id;
  Socket? _s;
  String _buf = '';
  final List<String> cmds = []; // "S20,1,1"
  final List<String> rawHex = []; // the exact bytes the server wrote
  final Map<String, DateTime> cmdAt = {};
  int bytesUp = 0;

  Future<void> connect() async {
    _s = await Socket.connect(_trackerHost, _trackerPort, timeout: const Duration(seconds: 10));
    _s!.listen((data) {
      _buf += latin1.decode(data);
      while (true) {
        final a = _buf.indexOf('*');
        final b = _buf.indexOf('#', a + 1);
        if (a < 0 || b < 0) break;
        final fr = _buf.substring(a, b + 1);
        _buf = _buf.substring(b + 1);
        final p = fr.substring(1, fr.length - 1).split(',');
        if (p.length < 3) continue;
        final code = p[2];
        final c = [code, ...p.skip(4)].join(',');
        cmds.add(c);
        cmdAt.putIfAbsent(c, () => DateTime.now());
        rawHex.add(latin1.encode(fr).map((x) => x.toRadixString(16).padLeft(2, '0')).join());
        _write(latin1.encode('*HQ,$id,V4,$code,DONE,${_hms(DateTime.now().toUtc())}#'));
      }
    }, onError: (_) {}, cancelOnError: true);
  }

  void _write(List<int> b) {
    bytesUp += b.length;
    _s?.add(b);
  }

  static int _status(bool ign) => ign ? 0xFFFFFFFF : 0xFFFFFBFF; // bit 10 = ACC, alarms clear

  static String _dm(double v, int degDigits) {
    final a = v.abs();
    final deg = a.floor();
    final min = (a - deg) * 60.0;
    return '${deg.toString().padLeft(degDigits, '0')}${min.toStringAsFixed(4).padLeft(7, '0')}';
  }

  /// Text V1 position (what the ST-906 sends first and on ACC changes).
  void v1(DateTime at, double lat, double lng, double kmh, bool ign, {int course = 0}) {
    final u = at.toUtc();
    final st = _status(ign).toRadixString(16).toUpperCase().padLeft(8, '0');
    _write(latin1.encode('*HQ,$id,V1,${_hms(u)},A,${_dm(lat, 2)},N,${_dm(lng, 3)},E,'
        '${(kmh / 1.852).toStringAsFixed(2)},$course,${_dmy(u)},$st,470,01,0001,0001#'));
  }

  /// Binary H02 record ('$' + BCD id, time, date, lat, battery, lng+flags,
  /// speed (knots) + course, status) padded to 32 bytes.
  void bin(DateTime at, double lat, double lng, double kmh, bool ign, {int course = 0}) {
    final u = at.toUtc();
    final latD = lat.abs().floor(), lngD = lng.abs().floor();
    final latM = ((lat.abs() - latD) * 60 * 10000).round();
    final lngM = ((lng.abs() - lngD) * 60 * 10000).round();
    final hex = '${id.padLeft(10, '0')}${_hms(u)}${_dmy(u)}'
        '${_two(latD)}${latM.toString().padLeft(6, '0')}06'
        '${lngD.toString().padLeft(3, '0')}${lngM.toString().padLeft(6, '0')}e'
        '${(kmh / 1.852).round().toString().padLeft(3, '0')}${(course % 360).toString().padLeft(3, '0')}'
        '${_status(ign).toRadixString(16).padLeft(8, '0')}';
    final out = <int>[0x24];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    while (out.length < 32) {
      out.add(0);
    }
    _write(out);
  }

  void heartbeat() => _write(latin1.encode('*HQ,$id,HTBT#'));
  bool got(String prefix) => cmds.any((c) => c.startsWith(prefix));

  Future<void> close() async {
    try {
      await _s?.close();
    } catch (_) {}
    _s?.destroy();
    _s = null;
  }
}

DateTime _nowS() {
  final n = DateTime.now().toUtc();
  return DateTime.utc(n.year, n.month, n.day, n.hour, n.minute, n.second);
}

int _p(List<int> xs, double q) {
  if (xs.isEmpty) return -1;
  final s = [...xs]..sort();
  return s[((s.length - 1) * q).round()];
}

void registerVehicleSt906Flows() {
  realityFlow('12v_vehicle_st906', 'Family & safety',
      'Vehicle tracking: pair ST-906 by id -> live Dhaka drive on the map -> ignition / overspeed / geofence alerts -> engine cut refused while moving, held, sent when stopped (relay bytes at the tracker) -> offline last seen -> trips today',
      timeout: const Duration(minutes: 16), (f) async {
    await f.home();
    final api = await f.h.backend();
    final run = DateTime.now().millisecondsSinceEpoch % 100000000;
    final devId = '91${run.toString().padLeft(8, '0')}'; // ST-906 10-digit id (made up)
    final dev = _St906(devId);
    final sentAt = <int, DateTime>{}; // fix second (epoch s) -> when its frame was written
    final uiLat = <int>[], apiLat = <int>[];
    final alertSeen = <String, DateTime>{};
    final alertTrigger = <String, DateTime>{};
    late int tid;
    DateTime last = DateTime.now().toUtc();

    DateTime stamp() {
      var t = _nowS();
      if (!t.isAfter(last)) t = last.add(const Duration(seconds: 1));
      last = t;
      return t;
    }

    void fix(double lat, double lng, double kmh, bool ign, {int course = 0, bool text = false}) {
      final at = stamp();
      sentAt[at.millisecondsSinceEpoch ~/ 1000] = DateTime.now();
      text ? dev.v1(at, lat, lng, kmh, ign, course: course) : dev.bin(at, lat, lng, kmh, ign, course: course);
    }

    Future<Map<String, dynamic>> tracker() async =>
        (await api.getJson('/vehicle/trackers/$tid'));

    // alert titles exactly as the server writes them (core/logic/vehicle_tracking.alert_text)
    final titles = {
      'ignition_on': '$_name started',
      'geofence_exit': '$_name left an area',
      'overspeed': '$_name is going fast',
      'geofence_enter': '$_name entered an area',
      'ignition_off': '$_name switched off',
      'tracker_silent': '$_name: tracker not responding',
    };
    var pollAlerts = true;
    Future<void> alertPoller() async {
      while (pollAlerts) {
        try {
          final r = await api.getJson('/notif/feed');
          final items = (r['items'] as List?) ?? const [];
          final blob = jsonEncode(items);
          titles.forEach((k, v) {
            if (!alertSeen.containsKey(k) && blob.contains(v)) alertSeen[k] = DateTime.now();
          });
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }

    GeoPt? mapLive() {
      final m = find.byType(VehMap);
      if (m.evaluate().isEmpty) return null;
      return f.tester.widget<VehMap>(m.first).live;
    }

    int trailLen() {
      final m = find.byType(VehMap);
      if (m.evaluate().isEmpty) return 0;
      return f.tester.widget<VehMap>(m.first).route.length;
    }

    // The tracker screen's list holds a pannable map: a drag on it pans the
    // map instead of scrolling, so move the list's scroll position directly.
    Future<void> listTo(Finder target, {bool up = false}) async {
      for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
        final sc = find.descendant(
            of: find.byType(VehicleTrackerScreen),
            matching: find.byWidgetPredicate(
                (w) => w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical));
        if (sc.evaluate().isEmpty) break;
        final pos = f.tester.state<ScrollableState>(sc.first).position;
        final to = (pos.pixels + (up ? -300.0 : 300.0)).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
        if (to == pos.pixels) break;
        pos.jumpTo(to);
        await f.tester.pump(const Duration(milliseconds: 300));
      }
      if (target.evaluate().isNotEmpty) {
        await f.tester.ensureVisible(target.first);
        await f.tester.pump(const Duration(milliseconds: 300));
      }
    }

    // ------------------------------------------------------------ (a)
    await f.step('(a) A pairs the ST-906 by its device id in the app', () async {
      await f.openRoute('vehicle_tracking');
      final cta = find.text(f.t.vehPairCta);
      await f.waitFor(cta, what: 'pair button');
      await f.tap(cta.first, settleSeconds: 2);
      final brand = find.byKey(const ValueKey('veh-brand-sinotrack'));
      await f.waitFor(brand, what: 'Sinotrack brand chip');
      await f.tester.ensureVisible(brand);
      await f.tap(brand);
      await f.tester.enterText(find.byKey(const ValueKey('veh-pair-imei')), devId);
      await f.tester.enterText(find.byKey(const ValueKey('veh-pair-name')), _name);
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.shot('vehicle_pair_form');
      final mark = f.httpMark;
      await f.tap(find.byKey(const ValueKey('veh-pair-submit')), settleSeconds: 3);
      f.expectHttp('POST', '/vehicle/trackers', since: mark);
      final r = await f.net(() => api.getJson('/vehicle/trackers'));
      final mine = ((r['trackers'] as List?) ?? const [])
          .cast<Map>()
          .where((t) => '${t['imei_tail']}' == devId.substring(devId.length - 4))
          .toList();
      if (mine.isEmpty) throw TestFailure('tracker not created: $r');
      tid = (mine.first['id'] as num).toInt();
      if ('${mine.first['state']}' != 'pending') throw TestFailure('not waiting: ${mine.first}');
      await f.shot('vehicle_pair_waiting');

      // the device powers on at Home, ignition off: first frame = text V1
      await f.net(() => dev.connect());
      final t0 = DateTime.now();
      fix(_home.$1, _home.$2, 0, false, text: true);
      await f.waitFor(find.text(f.t.v100SetupFirstFix), seconds: 40, what: 'first location on the setup screen');
      final pairMs = DateTime.now().difference(t0).inMilliseconds;
      f.note('pair: first frame -> "First location" on screen ${pairMs}ms');
      await f.shot('vehicle_first_fix');
      final x = await f.net(tracker);
      if (x['state'] != 'paired' || x['live'] == null) throw TestFailure('not paired: $x');
      await f.tap(find.text(f.t.vehDone).last, settleSeconds: 2);
    });

    await f.step('owner settings: limit 60, Home + Office areas, ignition alerts, silent 1 min', () async {
      await f.net(() => api.patchJson('/vehicle/trackers/$tid', {
            'speed_limit_kmh': 60,
            'geofences': [
              {'name': 'Home', 'lat': _home.$1, 'lng': _home.$2, 'radius_m': 150, 'alert': 'both'},
              {'name': 'Office', 'lat': _office.$1, 'lng': _office.$2, 'radius_m': 150, 'alert': 'both'},
            ],
            'alert_prefs': {'ignition_on': true, 'ignition_off': true, 'silent_min': 1},
          }));
      final x = await f.net(tracker);
      final s = (x['settings'] as Map?) ?? const {};
      if (s['speed_limit_kmh'] != 60 || ((s['geofences'] as List?) ?? const []).length != 2) {
        throw TestFailure('settings not saved: $s');
      }
      f.ownerCheck('ST-906: set limit / areas in the Settings screen by hand (CI saves them via the API)');
    });

    // ------------------------------------------------------------ (b)(c)(d)(e)
    await f.step('(b) the live Dhaka drive moves on the map (real time)', () async {
      final card = find.text(_name);
      await f.waitFor(card, seconds: 20, what: 'tracker card');
      await f.tap(card.first, settleSeconds: 3);
      await f.waitFor(find.byType(VehicleTrackerScreen), what: 'tracker screen');
      await f.waitFor(find.byType(VehMap), seconds: 20, what: 'map');
      await f.net(() async => unawaited(alertPoller()));

      final trip = _trip();
      var driving = true;
      final trail0 = trailLen();
      Future<void> drive() async {
        try {
          // key on at Home (text V1), a few seconds standing
          alertTrigger['ignition_on'] = DateTime.now();
          fix(_home.$1, _home.$2, 0, true, text: true);
          await Future<void>.delayed(const Duration(seconds: _stepS));
          var exited = false, entered = false;
          var over = 0;
          for (var i = 0; i < trip.length; i++) {
            final p = trip[i];
            fix(p.$1, p.$2, p.$3, true, course: p.$4);
            if (!exited && _hav(p.$1, p.$2, _home.$1, _home.$2) > 181) {
              exited = true;
              alertTrigger['geofence_exit'] = DateTime.now();
            }
            if (p.$3 > 60 && ++over == 2) alertTrigger['overspeed'] = DateTime.now();
            if (exited && !entered && _hav(p.$1, p.$2, _office.$1, _office.$2) < 119) {
              entered = true;
              alertTrigger['geofence_enter'] = DateTime.now();
            }
            if (i % 4 == 2) {
              // packet -> server (API) latency for this fix
              final want = last;
              final t0 = DateTime.now();
              unawaited(() async {
                while (DateTime.now().difference(t0).inSeconds < 15) {
                  try {
                    final x = await tracker();
                    final at = vehDate(((x['live'] as Map?) ?? const {})['at']);
                    if (at != null && !at.isBefore(want)) {
                      apiLat.add(DateTime.now().difference(t0).inMilliseconds);
                      return;
                    }
                  } catch (_) {}
                  await Future<void>.delayed(const Duration(milliseconds: 250));
                }
              }());
            }
            await Future<void>.delayed(const Duration(seconds: _stepS));
          }
          // parked at the office: engine running, then key off (text V1)
          fix(_office.$1, _office.$2, 0, true, text: true);
          await Future<void>.delayed(const Duration(seconds: _stepS));
          fix(_office.$1, _office.$2, 0, true);
          await Future<void>.delayed(const Duration(seconds: _stepS));
          alertTrigger['ignition_off'] = DateTime.now();
          fix(_office.$1, _office.$2, 0, false, text: true);
          await Future<void>.delayed(const Duration(seconds: _stepS));
          fix(_office.$1, _office.$2, 0, false);
        } catch (_) {
        } finally {
          driving = false;
        }
      }

      await f.net(() async => unawaited(drive()));
      final seen = <int>{};
      var movingShown = false;
      var shots = 0;
      final started = DateTime.now();
      while (driving && DateTime.now().difference(started).inMinutes < 8) {
        await f.tester.pump(const Duration(milliseconds: 250));
        final live = mapLive();
        final at = live?.at;
        if (at != null) {
          final k = at.toUtc().millisecondsSinceEpoch ~/ 1000;
          if (seen.add(k) && sentAt[k] != null) {
            uiLat.add(DateTime.now().difference(sentAt[k]!).inMilliseconds);
          }
        }
        if (!movingShown && find.textContaining(f.t.vehMovingAt('§').split('§').first.trim()).evaluate().isNotEmpty) {
          movingShown = true;
        }
        final el = DateTime.now().difference(started).inSeconds;
        if ((el > 40 && shots == 0) || (el > 110 && shots == 1) || (el > 170 && shots == 2)) {
          shots++;
          await f.shot('vehicle_live_drive_$shots');
        }
      }
      if (driving) throw TestFailure('the drive did not finish in 8 min');
      await f.pumpFor(const Duration(seconds: 3));
      if (seen.length < 8) throw TestFailure('map marker moved only ${seen.length} times');
      if (!movingShown) throw TestFailure('"Moving · N km/h" never shown during the drive');
      // the trail grows while the screen stays open (it was frozen before)
      if (trailLen() <= trail0 + 10) {
        throw TestFailure('map trail did not grow while driving (${trail0} -> ${trailLen()})');
      }
      f.note('drive: marker moved ${seen.length}x on screen; trail ${trail0}->${trailLen()} points');
    });

    await f.step('(c)(d)(e) ignition on/off, overspeed, geofence exit + enter reach A', () async {
      await f.eventually('all drive alerts in the feed', () async {
        return ['ignition_on', 'geofence_exit', 'overspeed', 'geofence_enter', 'ignition_off']
            .every(alertSeen.containsKey);
      }, seconds: 40);
      // ONE overspeed alert for the fast stretch (not one per fix)
      final r = await f.net(() => api.getJson('/notif/feed'));
      final n = RegExp(RegExp.escape(titles['overspeed']!)).allMatches(jsonEncode(r['items'])).length;
      f.note('overspeed rows in feed (NotifEvent + family alert): $n');
    });

    // ------------------------------------------------------------ (f)
    Future<void> openCut(String kind) async {
      final b = find.byKey(ValueKey(kind == 'engine_cut' ? 'veh-cut' : 'veh-restore'));
      await listTo(b);
      await f.tap(b, settleSeconds: 1);
      final dlg = find.byType(AlertDialog);
      await f.waitFor(dlg, what: 'confirm dialog');
      await f.tap(find.descendant(
          of: dlg, matching: find.text(kind == 'engine_cut' ? f.t.vehCutCta : f.t.vehRestoreCta)));
      final pin = find.descendant(of: find.byType(AlertDialog), matching: find.byType(EditableText));
      await f.waitFor(pin, what: 'Security PIN');
      await f.tester.enterText(pin.first, _pin);
      await f.pumpFor(const Duration(milliseconds: 300));
      await f.tap(find.text(f.t.securityContinue), settleSeconds: 2);
    }

    await f.step('(f) engine cut while MOVING: refused, nothing sent', () async {
      var moving = true;
      Future<void> crawl() async {
        var k = 0;
        try {
          while (moving) {
            // drives off again slowly, inside the Office area (no new fence alert)
            fix(_office.$1 + 0.0002 * (k % 3), _office.$2 + 0.0001 * (k % 2), 25, true);
            k++;
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        } catch (_) {}
      }

      await f.net(() async => unawaited(crawl()));
      await f.eventually('server sees it moving', () async {
        final x = await tracker();
        return ((x['live'] as Map?) ?? const {})['moving'] == true;
      }, seconds: 20);
      await f.waitFor(find.textContaining(f.t.vehMovingAt('§').split('§').first.trim()),
          seconds: 30, what: 'Moving on screen');
      await openCut('engine_cut');
      final refused = find.byKey(const ValueKey('veh-refused-moving'));
      await f.waitFor(refused, seconds: 10, what: 'refusal (moving)');
      final txt = f.tester.widget<Text>(refused).data ?? '';
      if (txt != f.t.vehErrMoving && txt != f.t.v100ErrFewFixes) throw TestFailure('refusal text: $txt');
      await f.shot('vehicle_cut_refused_moving');
      await f.tap(find.byKey(const ValueKey('veh-hold-no')), settleSeconds: 2);
      await f.pumpFor(const Duration(seconds: 4));
      if (dev.got('S20')) throw TestFailure('relay command reached a MOVING vehicle: ${dev.cmds}');
      final c = await f.net(() => api.getJson('/vehicle/trackers/$tid/commands'));
      if (((c['commands'] as List?) ?? const []).any((x) => '${(x as Map)['state']}' == 'queued')) {
        throw TestFailure('a cut was queued after "Not now": $c');
      }

      // ---- held: "cut once it stops"
      await openCut('engine_cut');
      await f.waitFor(refused, seconds: 10, what: 'refusal (moving) #2');
      await f.tap(find.byKey(const ValueKey('veh-hold-yes')), settleSeconds: 2);
      final fin = find.byKey(const ValueKey('veh-cut-final'));
      await f.waitFor(fin, seconds: 10, what: 'final confirmation');
      await f.tap(fin, settleSeconds: 2);
      f.expectHttp('POST', '/vehicle/commands/');
      await f.eventually('held cut on the server', () async {
        final c = await api.getJson('/vehicle/trackers/$tid/commands');
        return ((c['commands'] as List?) ?? const [])
            .any((x) => (x as Map)['state'] == 'queued' && x['wait_stop'] == true);
      }, seconds: 15);
      final held = find.textContaining(f.t.vehCmdStHeld('§').split('§').first);
      await listTo(held);
      await f.waitFor(held, seconds: 30, what: '"waiting for the vehicle to stop" row');
      await f.shot('vehicle_cut_held');
      // several server dispatch rounds while it still moves: nothing sent
      await f.pumpFor(const Duration(seconds: 8));
      if (dev.got('S20')) throw TestFailure('held cut sent while MOVING: ${dev.cmds}');

      // ---- it stops: three stopped fixes, then the relay command goes out
      moving = false;
      await f.pumpFor(const Duration(seconds: 2));
      DateTime? stopAt;
      await f.net(() async {
        for (var i = 0; i < 3; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          fix(_office.$1 + 0.0004, _office.$2, 0, true);
        }
        stopAt = DateTime.now();
      });
      await f.eventually('relay command bytes at the tracker', () async => dev.got('S20,'), seconds: 30);
      final s20 = dev.cmds.firstWhere((c) => c.startsWith('S20'));
      if (s20 != 'S20,1,1') throw TestFailure('wrong relay command: $s20');
      final raw = dev.rawHex[dev.cmds.indexOf(s20)];
      final ms = dev.cmdAt[s20]!.difference(stopAt!).inMilliseconds;
      f.note('engine cut: stopped -> S20 at tracker ${ms}ms; bytes ${latin1.decode([
            for (var i = 0; i < raw.length; i += 2) int.parse(raw.substring(i, i + 2), radix: 16)
          ])} (hex $raw)');
      final acked = find.textContaining(f.t.vehCmdStAcked);
      await listTo(acked);
      await f.waitFor(acked, seconds: 45, what: '"confirmed by tracker"');
      await f.waitFor(find.text(f.t.vehRelayCut), seconds: 10, what: 'relay state CUT');
      await f.shot('vehicle_cut_confirmed');
    });

    await f.step('(f) restore: S20,1,0 reaches the tracker, confirmed', () async {
      await openCut('engine_restore');
      await f.eventually('restore bytes at the tracker', () async => dev.got('S20,1,0'), seconds: 30);
      await f.waitFor(find.text(f.t.vehRelayNormal), seconds: 45, what: 'relay state NORMAL');
      if (dev.cmds.any((c) => c.startsWith('S20') && c != 'S20,1,1' && c != 'S20,1,0')) {
        throw TestFailure('unexpected relay command: ${dev.cmds}');
      }
      f.note('server commands seen by the ST-906: ${dev.cmds}');
    });

    // ------------------------------------------------------------ (h)
    await f.step('(h) trips today: trip, distance, top speed on the tracker screen', () async {
      final r = await f.net(() => api.getJson('/vehicle/trackers/$tid/route?hours=24'));
      final trips = (r['trips'] as List?) ?? const [];
      final km = vehNum(r['total_km']) ?? 0;
      final top = vehNum(r['max_speed_kmh']) ?? 0;
      if (trips.isEmpty || km < 1.5 || top < 70) {
        throw TestFailure('trip summary: trips ${trips.length}, km $km, top $top');
      }
      final ctx = f.tester.element(find.byType(VehicleTrackerScreen));
      final topText = f.t.vehKmh(vehNumStr(ctx, top));
      // the screen refreshed its trail when the car stopped; the crawl after
      // it may add ~0.1 km, so accept the API distance +-0.1
      final kmTexts = [for (final d in [-0.1, 0.0, 0.1]) f.t.vehKm(vehNumStr(ctx, km + d, decimals: 1))];
      final title = find.text(f.t.vehTripsToday);
      await listTo(title, up: true);
      await listTo(title);
      await listTo(find.text(topText));
      await f.waitFor(find.text(topText), seconds: 45, what: 'top speed $topText');
      final kmF = find.byWidgetPredicate((w) => w is Text && kmTexts.contains(w.data));
      await f.waitFor(kmF, seconds: 10, what: 'distance one of $kmTexts');
      await f.shot('vehicle_trips_today');
      f.note('trips ${trips.length}, ${km}km, top ${top}km/h');
    });

    // ------------------------------------------------------------ (g)
    await f.step('(g) tracker goes silent -> honest "Offline · last seen"', () async {
      fix(_office.$1 + 0.0004, _office.$2, 0, false, text: true);
      final lastAt = DateTime.now();
      await f.pumpFor(const Duration(seconds: 2));
      await f.net(() => dev.close());
      final off = find.textContaining(f.t.vehOfflineSince('§').split('§').first);
      await listTo(find.byType(VehMap), up: true);
      await listTo(off, up: true);
      await f.waitFor(off, seconds: 150, what: '"Offline · last seen"');
      final x = await f.net(tracker);
      if (x['online'] != false) throw TestFailure('server still says online: $x');
      final seenAt = vehDate(x['last_seen_at']);
      if (seenAt == null || seenAt.difference(lastAt).inSeconds.abs() > 10) {
        throw TestFailure('last seen $seenAt is not the last frame ($lastAt)');
      }
      await f.shot('vehicle_offline_last_seen');
      await f.eventually('"not responding" alert', () async => alertSeen.containsKey('tracker_silent'),
          seconds: 90);
    });

    // ------------------------------------------------------------ alerts on screen
    await f.step('(c)(d)(e)(g) the alerts in the app notification centre', () async {
      pollAlerts = false;
      await f.openRoute('notifications');
      await f.tap(find.textContaining(f.t.notifTabNotifications).first, settleSeconds: 3);
      var n = 0;
      for (final k in ['tracker_silent', 'ignition_off', 'geofence_enter', 'overspeed', 'geofence_exit', 'ignition_on']) {
        final row = find.textContaining(titles[k]!);
        await f.scrollTo(row);
        await f.waitFor(row, seconds: 15, what: 'alert "${titles[k]}"');
        if (n++ % 2 == 0) await f.shot('vehicle_alert_$k');
      }
    });

    await f.step('latency report + cleanup', () async {
      final alertMs = <String, int>{
        for (final k in alertTrigger.keys)
          if (alertSeen[k] != null) k: alertSeen[k]!.difference(alertTrigger[k]!).inMilliseconds,
      };
      final rep = {
        'api_ms': {'n': apiLat.length, 'p50': _p(apiLat, .5), 'p95': _p(apiLat, .95)},
        'screen_ms': {'n': uiLat.length, 'p50': _p(uiLat, .5), 'p95': _p(uiLat, .95), 'max': _p(uiLat, 1)},
        'alert_feed_ms': alertMs,
        'bytes_up': dev.bytesUp,
      };
      // ignore: avoid_print
      print('VEH_E2E_LATENCY ${jsonEncode(rep)}');
      f.note('latency $rep');
      if (uiLat.isEmpty || apiLat.isEmpty) throw TestFailure('no latency samples: $rep');
      try {
        await f.net(() => api.deleteJson('/vehicle/trackers/$tid'));
      } on ApiException catch (_) {}
    });
  });
}
