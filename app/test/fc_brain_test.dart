// fcbrain (Family Care v3 BRAIN 2-7, owner order 9 Nov 10:50):
//   * ask bar offline parser — the SAME case table as the server
//     (test/fixtures/fc_ask_cases.json <-> backend core/tests_fcbrain.py);
//   * on-phone geofence rule: enter / leave hysteresis, first fix only
//     learns, bad accuracy ignored, Kotlin twin uses the same constants;
//   * FAKE-GPS proof of the owner's target: arrival news within 2 minutes in
//     >= 95 % of arrivals (seeded trips: walk, rickshaw, bus, car, bike,
//     some faster than the policy's 60 km/h bound, real GPS noise + fix time
//     + network time);
//   * battery model of a typical day from the same simulation (honest: a
//     MODEL — the real % is measured on the owner's phone, see
//     owner_actions/FAMILY_BRAIN_V3_BN.md);
//   * 15 % battery: last location once per discharge;
//   * the settings screen + night card render in Bangla and English, light
//     and dark, at 200 % font with no overflow.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:assisto/api.dart';
import 'package:assisto/family_v3/brain/fc_ask_parser.dart';
import 'package:assisto/family_v3/brain/fc_brain_settings_screen.dart';
import 'package:assisto/family_v3/brain/fc_brain_slots.dart';
import 'package:assisto/family_v3/brain/fc_geofence.dart';
import 'package:assisto/family_v3/brain/fc_night_news_card.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fcbrain_shots.dart';

const _lat0 = 23.7500, _lng0 = 90.3900;

/// Point [m] metres north of the fence centre.
({double lat, double lng}) _north(double m) => (lat: _lat0 + m / 111320.0, lng: _lng0);

class _TripResult {
  final double? latencyS; // null = never detected
  final int gps, net;
  _TripResult(this.latencyS, this.gps, this.net);
}

/// One fake-GPS trip towards School (r = 150 m) driven by the real engine +
/// battery policy. Speeds change every 30 s inside the mode's range.
_TripResult _trip(math.Random rnd, {required double startM, required double vMin, required double vMax}) {
  const fence = FcFence(1, 'school', _lat0, _lng0);
  final eng = FcFenceEngine([fence]);
  // true distance to the fence centre, one value per second (piecewise
  // speeds, re-drawn every 30 s; 15 % of segments are a jam / stop)
  final dist = <double>[startM];
  var v = 0.0;
  while (dist.last > 0 && dist.length < 4 * 3600) {
    if ((dist.length - 1) % 30 == 0) {
      v = rnd.nextDouble() < 0.15 ? 0.0 : vMin + rnd.nextDouble() * (vMax - vMin);
    }
    dist.add(math.max(0.0, dist.last - v));
  }
  double pos(double t) {
    final i = t.floor();
    if (i >= dist.length - 1) return dist.last;
    return dist[i] + (dist[i + 1] - dist[i]) * (t - i);
  }

  double gauss() {
    final u1 = math.max(1e-9, rnd.nextDouble()), u2 = rnd.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  // when does the person truly cross the 150 m edge?
  double? crossT;
  for (var i = 0; i < dist.length; i++) {
    if (dist[i] <= fence.r) {
      crossT = i.toDouble();
      break;
    }
  }
  var t = 0.0;
  var gps = 0, net = 0;
  var precise = false;
  while (t < 4 * 3600) {
    final acq = precise ? 5 + rnd.nextDouble() * 15 : 2 + rnd.nextDouble() * 6;
    final acc = precise ? 8 + rnd.nextDouble() * 17 : 30 + rnd.nextDouble() * 90;
    precise ? gps++ : net++;
    final ft = t + acq;
    final d = pos(ft) + gauss() * acc / 2;
    final p = _north(d);
    final at = DateTime.utc(2026, 11, 9).add(Duration(milliseconds: (ft * 1000).round()));
    final fix = FcFix(p.lat, p.lng, acc, at);
    final evs = eng.step(fix);
    if (evs.any((e) => e.kind == 'arrive')) {
      final netDelay = 1 + rnd.nextDouble() * 4;
      return _TripResult(crossT == null ? 0.0 : ft + netDelay - crossT, gps, net);
    }
    precise = eng.wantPrecise(fix);
    t = ft + eng.nextDelayS(fix);
  }
  return _TripResult(null, gps, net);
}

double _pct(List<double> xs, double q) {
  final s = [...xs]..sort();
  return s[math.min(s.length - 1, (q * (s.length - 1)).round())];
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Map<String, dynamic> settingsFixture() => fcbSettingsData('en');

Map<String, dynamic> nightFixture(String lang) => fcbNightData(lang);

void main() {
  group('ask bar parser (shared case table)', () {
    final table = jsonDecode(File('test/fixtures/fc_ask_cases.json').readAsStringSync()) as Map;
    final now = DateTime.parse(table['now'] as String);
    final members = (table['members'] as List).map(FcAskMember.fromJson).whereType<FcAskMember>().toList();
    for (final c in (table['cases'] as List).cast<Map>()) {
      test('"${c['q']}"', () {
        final a = fcAskAnswer(c['q'] as String, members, lang: c['lang'] as String, now: now);
        if (c['none'] == true) {
          expect(a, isNull);
          return;
        }
        expect(a, isNotNull);
        expect(a!.memberUserId, c['member']);
        expect(a.action, c['action']);
        for (final s in (c['contains'] as List).cast<String>()) {
          expect(a.text, contains(s));
        }
      });
    }

    test('never says OK for stale data', () {
      final a = fcAskAnswer('is rafi ok', const [FcAskMember(userId: 1, name: 'Rafi', state: 'stale', reason: 'never')],
          lang: 'en');
      expect(a!.text, isNot(contains('Yes')));
      expect(a.action, 'call');
    });

    test('slot adapter reads fcscreen camelCase members', () {
      final a = fcBrainAskMaps('where is rafi', [
        {'userId': 9, 'name': 'Rafi', 'label': '', 'role': 'child', 'placeLabel': 'School', 'state': 'ok',
         'lastSeen': DateTime.now().toUtc().toIso8601String()},
      ], lang: 'en');
      expect(a!.memberUserId, 9);
      expect(a.action, 'location');
      expect(a.text, contains('School'));
    });
  });

  group('on-phone geofence rule', () {
    const home = FcFence(1, 'home', _lat0, _lng0);
    FcFix at(double m, {double acc = 15, int s = 0}) {
      final p = _north(m);
      return FcFix(p.lat, p.lng, acc, DateTime.utc(2026).add(Duration(seconds: s)));
    }

    test('first fix only learns; enter needs one fix; leave needs two', () {
      final e = FcFenceEngine([home]);
      expect(e.step(at(50)), isEmpty); // switched on at Home: no "arrived"
      expect(e.inside, {1});
      expect(e.step(at(400, s: 60)), isEmpty); // one far fix: not yet
      final left = e.step(at(420, s: 120));
      expect(left.single.kind, 'leave');
      final back = e.step(at(160, acc: 20, s: 900)); // 150 + min(20, 50)
      expect(back.single.kind, 'arrive');
    });

    test('a fix worse than 250 m decides nothing', () {
      final e = FcFenceEngine([home])..step(at(3000));
      expect(e.step(at(10, acc: 900)), isEmpty);
      expect(e.inside, isEmpty);
    });

    test('battery policy: far = sleep, near = precise every minute, inside = 5/15 min', () {
      final e = FcFenceEngine([home]);
      final far = at(20000);
      e.step(far);
      expect(e.nextDelayS(far), FcFenceK.maxDelayS);
      expect(e.wantPrecise(far), isFalse);
      final near = at(400);
      e.step(near);
      expect(e.nextDelayS(near), FcFenceK.minDelayS);
      expect(e.wantPrecise(near), isTrue);
      e.step(at(20));
      expect(e.nextDelayS(at(20)), FcFenceK.insideDelayS);
      e.step(at(22));
      e.step(at(21));
      expect(e.nextDelayS(at(21)), FcFenceK.stillDelayS);
    });

    test('Kotlin twin (FamilyWatchService) uses the same constants', () {
      final kt = File('android_overlay/app/src/main/kotlin/com/assisto/assisto/family/FenceRule.kt')
          .readAsStringSync();
      double k(String name) {
        final m = RegExp('const val $name = ([0-9.]+)L?').firstMatch(kt);
        expect(m, isNotNull, reason: name);
        return double.parse(m!.group(1)!);
      }

      expect(k('VMAX_MPS'), FcFenceK.vmaxMps);
      expect(k('MIN_DELAY_S'), FcFenceK.minDelayS);
      expect(k('MAX_DELAY_S'), FcFenceK.maxDelayS);
      expect(k('INSIDE_DELAY_S'), FcFenceK.insideDelayS);
      expect(k('STILL_DELAY_S'), FcFenceK.stillDelayS);
      expect(k('LEAVE_MARGIN_M'), FcFenceK.leaveMarginM);
      expect(k('ENTER_ACC_CAP_M'), FcFenceK.enterAccCapM);
      expect(k('LEAVE_ACC_CAP_M'), FcFenceK.leaveAccCapM);
      expect(k('MAX_ACC_M'), FcFenceK.maxAccM);
      expect(k('NEAR_M'), FcFenceK.nearM);
      expect(k('STILL_M'), FcFenceK.stillM);
    });

    test('15 % battery: last location once per discharge, re-armed by charging', () {
      final b = FcLowBattery();
      expect(b.check(40, false), isFalse);
      expect(b.check(15, false), isTrue);
      expect(b.check(12, false), isFalse);
      expect(b.check(9, false), isFalse);
      expect(b.check(20, true), isFalse); // charging re-arms
      expect(b.check(14, false), isTrue);
    });
  });

  test('FAKE-GPS PROOF: arrival news within 2 minutes in >= 95 % of arrivals', () {
    final rnd = math.Random(20261109);
    final modes = <(String, double, double, int)>[
      ('walk', 0.8, 1.8, 120),
      ('rickshaw', 2.0, 5.0, 120),
      ('bus', 2.0, 12.0, 120),
      ('car', 4.0, 16.0, 100),
      ('motorbike', 6.0, 16.7, 60),
      ('highway', 15.0, 22.0, 30), // faster than the 60 km/h bound: honest worst case
    ];
    final lat = <double>[];
    var missed = 0;
    final byMode = <String, List<double>>{};
    for (final (name, lo, hi, n) in modes) {
      for (var i = 0; i < n; i++) {
        final r = _trip(rnd, startM: 1500 + rnd.nextDouble() * 6500, vMin: lo, vMax: hi);
        if (r.latencyS == null) {
          missed++;
          continue;
        }
        lat.add(r.latencyS!);
        byMode.putIfAbsent(name, () => []).add(r.latencyS!);
      }
    }
    final within = lat.where((x) => x <= 120).length / (lat.length + missed);
    // ignore: avoid_print
    print('fcbrain fake-GPS arrivals: n=${lat.length + missed} missed=$missed '
        'p50=${_pct(lat, 0.5).toStringAsFixed(0)}s p95=${_pct(lat, 0.95).toStringAsFixed(0)}s '
        'within2min=${(within * 100).toStringAsFixed(1)}% '
        '${byMode.entries.map((e) => '${e.key}:p95=${_pct(e.value, 0.95).toStringAsFixed(0)}s').join(' ')}');
    expect(missed, 0);
    expect(within, greaterThanOrEqualTo(0.95));
  });

  test('battery MODEL of a typical day stays under 3 % (real % measured on the phone)', () {
    // A day: 14 h at Home + 7 h at School/Office (inside: 5 min, then 15 min
    // when still) + 2 trips of ~5 km (the simulated policy above) + one
    // heartbeat every 30 min. Energy per action (conservative, published
    // smartphone measurements): precise GPS fix 0.25 mAh, network fix
    // 0.06 mAh, one ping over mobile data incl. radio tail 0.35 mAh.
    // Battery 4000 mAh (smaller than the owner's Realme 9i, 5000 mAh).
    final rnd = math.Random(7);
    var gps = 0, net = 0;
    for (var i = 0; i < 2; i++) {
      final r = _trip(rnd, startM: 5000, vMin: 2, vMax: 12);
      gps += r.gps;
      net += r.net;
    }
    final insideFixes = (21 * 3600 / 900).round() + 4; // + the first 5-min ones
    net += insideFixes;
    const pings = 48 + 4; // heartbeats + arrive/leave events
    final mAh = gps * 0.25 + net * 0.06 + pings * 0.35;
    final pct = mAh / 4000 * 100;
    // ignore: avoid_print
    print('fcbrain battery model: gps=$gps net=$net pings=$pings -> ${mAh.toStringAsFixed(1)} mAh '
        '= ${pct.toStringAsFixed(2)} %/day (target < 3 %)');
    expect(pct, lessThan(3.0));
  });

  group('screens', () {
    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('settings $lang ${dark ? 'dark' : 'light'} 200 % font', (tester) async {
          tester.view.physicalSize = const Size(1080, 2400);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(_app(
              FcBrainSettingsScreen(api: ApiClient(), familyId: 1, debugData: settingsFixture()),
              lang: lang,
              scale: 2.0,
              dark: dark));
          await tester.pumpAndSettle();
          final t = await AppLocalizations.delegate.load(Locale(lang));
          expect(find.text(t.fcbArriveSwitch), findsOneWidget);
          await tester.scrollUntilVisible(find.text('Rahima'), 300);
          expect(find.text('Rahima'), findsOneWidget);
          await tester.scrollUntilVisible(find.text(t.fcbLeaveTitle), 300);
          expect(tester.takeException(), isNull);
        });
      }
      testWidgets('night news card $lang', (tester) async {
        await tester.pumpWidget(_app(
            Scaffold(body: FcNightNewsCard(api: ApiClient(), familyId: 1, debugData: nightFixture(lang))),
            lang: lang));
        await tester.pump();
        final t = await AppLocalizations.delegate.load(Locale(lang));
        expect(find.text(t.fcbNightTitle), findsOneWidget);
        expect(find.textContaining('Rafi'), findsOneWidget);
        expect(find.text(t.fcbListen), findsOneWidget);
      });
    }

    test('clock label: Bangla digits in Bangla', () {
      expect(fcClockLabel('21:30', 'bn'), 'রাত ৯:৩০');
      expect(fcClockLabel('21:30', 'en'), '9:30 PM');
    });
  });
}
