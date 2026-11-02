// journey100b — Safe Journey tracker gaps closed before the owner's two-phone
// test: battery-aware cadence, whole backlog sent when the network returns,
// fix source ('app' / 'bg') for honest "no location" alerts, and a replayed
// Dhaka trip with a dead zone where no fix is lost.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/services/oem_guide.dart';
import 'package:assisto/widgets/notif_models.dart';
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

  test('a hanging send (poor network) gives up, keeps the fix, next tick still runs',
      () async {
    var now = DateTime(2026, 11, 2, 18, 0);
    var hang = true;
    var lat = 23.70;
    final sent = <int>[];
    final tr = JourneyTracker(
        useService: false,
        clock: () => now,
        sendTimeout: const Duration(milliseconds: 50),
        position: () async => (lat: lat += 0.001, lng: 90.40),
        battery: () async => 70);
    await tr.start(7, (id, pts) {
      if (hang) return Completer<Map<String, dynamic>>().future; // never answers
      sent.add(pts.length);
      return Future.value(<String, dynamic>{'status': 'active'});
    });
    expect(tr.value.net, JourneyNet.offline);
    now = now.add(const Duration(seconds: 30));
    await tr.tick(); // not blocked by the hung request
    expect(tr.value.queued, 2);
    hang = false;
    now = now.add(const Duration(seconds: 30));
    await tr.tick();
    expect(sent, [3]);
    expect(tr.value.net, JourneyNet.ok);
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

  group('owner real trip 2 Nov', () {
    OemInfo oem(String maker, {bool? opt, bool? restricted}) => OemInfo.fromMap({
          'manufacturer': maker, 'brand': maker, 'model': 'x', 'sdkInt': 33,
          'release': '13', 'rom': '', 'batteryOptIgnored': opt, 'bgRestricted': restricted,
        });

    test('pre-start battery-saver check: which phones get the 2-step sheet', () {
      expect(journeyNeedsBgSetup(null, guidedBefore: false), isFalse); // unknown: never block
      expect(journeyNeedsBgSetup(oem('realme', opt: true), guidedBefore: false), isTrue);
      expect(journeyNeedsBgSetup(oem('realme', opt: true), guidedBefore: true), isFalse);
      expect(journeyNeedsBgSetup(oem('Xiaomi', opt: false), guidedBefore: true), isTrue);
      expect(journeyNeedsBgSetup(oem('samsung', opt: true, restricted: true), guidedBefore: true),
          isTrue);
      expect(journeyNeedsBgSetup(oem('Google', opt: true), guidedBefore: false), isFalse);
    });

    test('Safe Journey push buttons: Open map + Live view, real URLs only', () {
      final d = {'kind': 'family_alert', 'journey_id': '9', 'lat': '23.88', 'lng': '90.4',
                 'url': 'https://lifeassisto.com/j/abc'};
      expect(PushNotifier.journeyActions(d),
          [PushNotifier.actionJourneyMap, PushNotifier.actionJourneyLive]);
      expect(PushNotifier.journeyActionUri(d, PushNotifier.actionJourneyMap).toString(),
          'https://maps.google.com/?q=23.880000,90.400000');
      expect(PushNotifier.journeyActionUri(d, PushNotifier.actionJourneyLive).toString(),
          'https://lifeassisto.com/j/abc');
      expect(PushNotifier.journeyActions({...d, 'lat': '', 'url': ''}), isEmpty);
      expect(PushNotifier.journeyActions({...d, 'kind': 'message'}), isEmpty);
      expect(PushNotifier.journeyActionUri(d, null), isNull);
      final acts = PushNotifier.detailsFor(PushPayload({...d, 'title': 'x', 'body': 'y',
              'lang': 'bn'}))
          .android!
          .actions!;
      expect(acts.map((a) => a.id).toList(), ['j_map', 'j_live']);
      expect(acts.map((a) => a.title).toList(), ['ম্যাপে দেখুন', 'লাইভ দেখুন']);
    });

    test('admin (server) alerts are flagged for their own tab', () {
      expect(NotifEvent.fromJson({'id': 1, 'type': 'admin'}).admin, isTrue);
      expect(NotifEvent.fromJson({'id': 2, 'type': 'safe_journey'}).admin, isFalse);
      final back = NotifEvent.fromJson(NotifEvent.fromJson({'id': 1, 'type': 'admin'}).toJson());
      expect(back.admin, isTrue);
    });
  });
}
