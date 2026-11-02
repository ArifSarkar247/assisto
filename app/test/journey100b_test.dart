// journey100b — Safe Journey tracker gaps closed before the owner's two-phone
// test: battery-aware cadence, whole backlog sent when the network returns,
// fix source ('app' / 'bg') for honest "no location" alerts, and a replayed
// Dhaka trip with a dead zone where no fix is lost.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/state.dart';

JourneyFix _f(double lat, double lng, DateTime at) => JourneyFix(lat, lng, at, 80);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
  });

  group('battery-aware cadence', () {
    final t0 = DateTime(2026, 11, 2, 20, 0);

    test('moving: a fix on every wake-up', () {
      final recent = [
        _f(23.750, 90.390, t0),
        _f(23.752, 90.391, t0.add(const Duration(seconds: 30))),
        _f(23.754, 90.392, t0.add(const Duration(seconds: 60))),
      ];
      expect(
          journeyShouldFix(
              now: t0.add(const Duration(seconds: 90)), recent: recent, battery: 80),
          isTrue);
    });

    test('standing still: at most every 90 s (page still says live)', () {
      final recent = [
        _f(23.75000, 90.39000, t0),
        _f(23.75005, 90.39003, t0.add(const Duration(seconds: 30))),
        _f(23.75002, 90.39001, t0.add(const Duration(seconds: 60))),
      ];
      expect(journeyShouldFix(now: t0.add(const Duration(seconds: 90)), recent: recent),
          isFalse);
      expect(journeyShouldFix(now: t0.add(const Duration(seconds: 150)), recent: recent),
          isTrue);
      expect(kStillFixEvery.inSeconds, lessThan(120)); // FRESH_FIX_S on the server
    });

    test('low battery: at most every 60 s, normal battery every 30 s', () {
      final recent = [_f(23.75, 90.39, t0)];
      final at31 = t0.add(const Duration(seconds: 31));
      expect(journeyShouldFix(now: at31, recent: recent, battery: 12), isFalse);
      expect(journeyShouldFix(now: at31, recent: recent, battery: 40), isTrue);
      expect(journeyShouldFix(now: t0.add(const Duration(seconds: 61)), recent: recent, battery: 12),
          isTrue);
      expect(journeyShouldFix(now: at31, recent: const []), isTrue);
    });
  });

  test('fix source rides along and survives the disk queue', () {
    final q = JourneyFixQueue()
      ..add(JourneyFix(23.7, 90.4, DateTime.utc(2026, 11, 2), null, 'bg'))
      ..add(JourneyFix(23.8, 90.4, DateTime.utc(2026, 11, 2, 0, 1), 50));
    final back = JourneyFixQueue.decode(q.encode());
    expect(back.items.map((f) => f.src).toList(), ['bg', 'app']);
    expect(back.items.first.toJson()['src'], 'bg');
    expect(back.items.first.toJson().containsKey('battery'), isFalse);
  });

  test('replayed Dhaka trip with a 4-minute dead zone: no fix lost, backlog sent at once',
      () async {
    // Mirpur 10 -> Farmgate, a fix every 30 s; ticks 6..13 have no network
    final trace = List.generate(20, (i) => (lat: 23.807 - i * 0.002, lng: 90.368 + i * 0.0008));
    var i = 0;
    var now = DateTime(2026, 11, 2, 18, 0);
    var online = true;
    final batches = <List<Map<String, dynamic>>>[];
    final tr = JourneyTracker(
        useService: false,
        clock: () => now,
        position: () async => trace[i],
        battery: () async => 70);
    await tr.start(7, (id, pts) async {
      if (!online) throw ApiException('offline');
      batches.add(pts);
      return {'status': 'active', 'overdue_state': 'on_time'};
    });
    for (i = 1; i < trace.length; i++) {
      online = !(i >= 6 && i <= 13);
      now = now.add(const Duration(seconds: 30));
      await tr.tick();
      if (i == 10) {
        expect(tr.value.net, JourneyNet.offline);
        expect(tr.value.queued, 5); // honest count on screen
      }
    }
    expect(tr.value.queued, 0);
    final sent = [for (final b in batches) ...b];
    expect(sent.length, trace.length); // every fix arrived exactly once
    final ats = sent.map((p) => p['at'] as String).toList();
    expect(ats, [...ats]..sort()); // in time order
    // the backlog went in ONE tick when the network came back
    final back = batches.firstWhere((b) => b.length > 1);
    expect(back.length, 9);
    expect(sent.every((p) => p['src'] == 'app'), isTrue);
    await tr.stop();
  });

  test('a long outage (> 100 fixes) is sent in up to 3 batches in one tick', () async {
    var now = DateTime(2026, 11, 2, 18, 0);
    var online = false;
    var lat = 23.70;
    final batches = <int>[];
    final tr = JourneyTracker(
        useService: false,
        clock: () => now,
        position: () async => (lat: lat += 0.001, lng: 90.40),
        battery: () async => 70);
    await tr.start(7, (id, pts) async {
      if (!online) throw ApiException('offline');
      batches.add(pts.length);
      return {'status': 'active'};
    });
    for (var k = 0; k < 249; k++) {
      now = now.add(const Duration(seconds: 30));
      await tr.tick();
    }
    expect(tr.value.queued, 250);
    online = true;
    now = now.add(const Duration(seconds: 30));
    await tr.tick();
    expect(batches, [100, 100, 51]);
    expect(tr.value.queued, 0);
    await tr.stop();
  });
}
