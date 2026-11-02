// journey100: Safe Journey on two seeded accounts. A starts a journey to a
// made-up place with B as the watcher (through the real start form), the live
// screen opens, the SERVER has it; B's watcher list and the public watcher
// page (/j/<token>/data) show it; A adds time; A taps "I've arrived"; B sees
// "arrived" and the page stops showing any location (privacy).
// The overdue / stop / off-route / signal-lost sweeper is proven by
// backend core/tests_journey100.py (needs real minutes to pass); push
// delivery and the screen-off foreground service need two real phones
// (owner_actions/SAFE_JOURNEY_100_BN.md).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:assisto/screens/journey_live_screen.dart';

import '../support/harness.dart';

const _base = String.fromEnvironment('REALITY_API_BASE');

void registerSafeJourneyFlows() {
  realityFlow('16_safe_journey', 'Family & safety',
      'Safe Journey: start with a watcher -> live -> more time -> arrived (two accounts)', (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    final place = 'Reality Home ${DateTime.now().millisecondsSinceEpoch % 10000}';
    // a journey left over from an earlier run would open instead of the form
    await f.net(() async {
      final a = await api.getJson('/journey/active');
      if (a['id'] != null) await api.postJson('/journey/${a['id']}/arrived');
    });
    await f.step('open Safe Journey -> fill the form -> Start', () async {
      await f.openRoute('journey');
      await f.waitFor(find.byKey(const ValueKey('j100_dest')), what: 'destination field');
      await f.tester.enterText(find.byKey(const ValueKey('j100_dest')), place);
      final b = find.widgetWithText(CheckboxListTile, Seed.nameB);
      if (!await f.appears(b, seconds: 6)) {
        throw TestFailure('watcher ${Seed.nameB} not listed (seed edge A->B missing)');
      }
      await f.tester.ensureVisible(b);
      await f.tap(b);
      await f.shot('form');
      final start = find.byKey(const ValueKey('j100_start'));
      await f.tester.ensureVisible(start);
      await f.tap(start, settleSeconds: 3);
      // our own reason dialog before Android's location prompt: "Not now"
      // (the journey still starts; the live screen then says location is off)
      final notNow = find.text(f.t.notNow);
      if (await f.appears(notNow, seconds: 3)) await f.tap(notNow, settleSeconds: 3);
      await f.waitFor(find.byType(JourneyLiveScreen), seconds: 20, what: 'live journey screen');
      await f.waitFor(find.byKey(const ValueKey('j100_status')), what: 'status card');
      await f.shot('live');
      f.expectHttp('POST', '/journey/start');
    });
    late int jid;
    late String token;
    await f.step('server: A active with B watching; B sees it; public page live', () async {
      await f.eventually('A has the active journey on the server', () async {
        final a = await api.getJson('/journey/active');
        if ((a['destination'] as Map?)?['name'] != place) return false;
        jid = (a['id'] as num).toInt();
        token = Uri.parse('${a['web_link']}').pathSegments.last;
        return true;
      });
      await f.eventually('B lists A\'s journey', () async {
        final r = await apiB.getJson('/journey/watching');
        return (r['journeys'] as List).any((j) => j['id'] == jid);
      });
      if (_base.isNotEmpty) {
        final r = await f.net(() => http.get(Uri.parse('$_base/j/$token/data')));
        final s = (jsonDecode(r.body) as Map)['state'];
        if (!['live', 'waiting', 'stale'].contains(s)) {
          throw TestFailure('watcher page state $s (${r.statusCode})');
        }
        f.note('watcher page state: $s');
      }
    });
    await f.step('More time: +15 min reaches the server', () async {
      final before = await f.net(() => api.getJson('/journey/active'));
      final btn = find.byKey(const ValueKey('j100_extend'));
      await f.tester.ensureVisible(btn);
      await f.tap(btn, settleSeconds: 2);
      await f.tap(find.byKey(const ValueKey('j100_extend_15')), settleSeconds: 3);
      await f.shot('extended');
      f.expectHttp('POST', '/journey/$jid/extend');
      await f.eventually('ETA moved 15 minutes', () async {
        final a = await api.getJson('/journey/active');
        final d = DateTime.parse('${a['eta']}').difference(DateTime.parse('${before['eta']}'));
        return d.inMinutes == 15;
      });
    });
    await f.step('I\'ve arrived -> journey over; B sees "arrived"; no location on the page', () async {
      final btn = find.byKey(const ValueKey('j100_arrived'));
      await f.tester.ensureVisible(btn);
      await f.tap(btn, settleSeconds: 3);
      await f.shot('arrived');
      f.expectHttp('POST', '/journey/$jid/arrived');
      await f.eventually('A has no active journey', () async =>
          (await api.getJson('/journey/active'))['id'] == null);
      await f.eventually('B sees arrived', () async {
        final r = await apiB.getJson('/journey/watching');
        return (r['journeys'] as List).any((j) => j['id'] == jid && j['status'] == 'arrived'
            && j['lat'] == null);
      });
      if (_base.isNotEmpty) {
        final r = await f.net(() => http.get(Uri.parse('$_base/j/$token/data')));
        final m = jsonDecode(r.body) as Map;
        if (m['state'] != 'arrived' || m.containsKey('lat')) {
          throw TestFailure('page after arrival: $m');
        }
      }
    });
  });

  // journey100b: owner idea 1 on the emulator with two real accounts — B asks
  // to follow A's trip, A accepts in the app (inside the window it starts at
  // once), B sees it live, A stops with ONE tap from the live screen, B is
  // told and sees no more location. Push delivery itself needs real phones.
  realityFlow('16b_guardian_journey', 'Family & safety',
      'Guardian-requested trip: B asks -> A accepts -> live for B -> A one-tap stop -> B told',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    final place = 'Reality School ${DateTime.now().millisecondsSinceEpoch % 10000}';
    await f.net(() async {
      final a = await api.getJson('/journey/active');
      if (a['id'] != null) await api.postJson('/journey/${a['id']}/arrived');
      final out = await apiB.getJson('/journey/requests');
      for (final r in (out['outgoing'] as List? ?? const [])) {
        await apiB.postJson('/journey/requests/${r['id']}/cancel');
      }
    });
    late int rid;
    await f.step('B asks to follow A for the next hour (server)', () async {
      final r = await f.net(() async {
        final people = ((await apiB.getJson('/journey/requests'))['people'] as List)
            .cast<Map>();
        final a = people.firstWhere((m) => '${m['name']}'.contains('Rahim'),
            orElse: () => people.isEmpty ? <String, dynamic>{} : people.first);
        final now = DateTime.now().toUtc();
        return apiB.postJson('/journey/requests', {
          'member_id': a['member_id'],
          'destination': {'name': place, 'lat': 23.7465, 'lng': 90.3760},
          'start': now.subtract(const Duration(minutes: 2)).toIso8601String(),
          'end': now.add(const Duration(minutes: 60)).toIso8601String(),
        });
      });
      rid = (r['id'] as num).toInt();
    });
    await f.step('A opens the request and accepts -> live screen', () async {
      await f.openRoute('journey_requests');
      final accept = find.byKey(ValueKey('gj_accept_$rid'));
      await f.waitFor(accept, seconds: 15, what: 'incoming request card');
      await f.shot('request');
      await f.tester.ensureVisible(accept);
      await f.tap(accept, settleSeconds: 3);
      final notNow = find.text(f.t.notNow);
      if (await f.appears(notNow, seconds: 3)) await f.tap(notNow, settleSeconds: 3);
      await f.waitFor(find.byType(JourneyLiveScreen), seconds: 20, what: 'live journey screen');
      await f.shot('live');
      f.expectHttp('POST', '/journey/requests/$rid/accept');
    });
    await f.step('server: request active; B sees it in "outgoing"', () async {
      await f.eventually('B sees the trip running', () async {
        final out = (await apiB.getJson('/journey/requests'))['outgoing'] as List;
        return out.any((r) => r['id'] == rid && r['status'] == 'active');
      });
      await f.eventually('A has the active journey', () async =>
          (await api.getJson('/journey/active'))['id'] != null);
    });
    await f.step('A: one-tap stop from the live screen -> B told, nothing live', () async {
      final stop = find.byKey(const ValueKey('gj_banner_stop'));
      await f.waitFor(stop, what: 'guardian banner stop');
      await f.tester.ensureVisible(stop);
      await f.tap(stop, settleSeconds: 3);
      await f.shot('stopped');
      f.expectHttp('POST', '/journey/requests/$rid/stop');
      await f.eventually('B: request ended by the traveller', () async {
        final h = (await apiB.getJson('/journey/requests'))['history'] as List;
        return h.any((r) => r['id'] == rid && r['outcome'] == 'stopped_by_traveller');
      });
      await f.eventually('A: no active journey', () async =>
          (await api.getJson('/journey/active'))['id'] == null);
    });
  });
}
