// safety-plan — board row 49 PROOF on the emulator (e2e.yml group
// start+safetyplan, settings_e2eproof: push outbox, fake Google Maps,
// /ci-e2e/sj-sim). Three seeded/made-up accounts:
//   A = this phone = the CHILD; B = Reality Karim = guardian 1 (A's Circle,
//   made the verified mother); C = "Reality Guardian Two" = an approved
//   second guardian who is NOT in A's Circle and NOT picked for the trip.
//   spl1: A's trip -> start, late and arrive reach BOTH B and C; A's live
//         screen says both names (C's watching list: backend tests_safetyplan).
//   spl2: A makes the family safety plan ON THE PHONE (meeting place, who to
//         call, 999), shares it with B; B reads it; REAL airplane mode -> the
//         plan still opens on A from the phone's own copy.
//   spl3: map cost — one live trip: the trip itself needs 0 paid calls;
//         "road time" taps stop at the per-journey cap (routes 3); counted.
// Made-up people and places only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/safety_plan/safety_plan_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;
int _n = 0;
const _o = (23.7800, 90.4260);
const _d = (23.9600, 90.4260);
const _pin = '2468';
const _late = {'overdue_alert', 'overdue_ask', 'check_on', 'check_red', 'long_stop'};

List<Map<String, dynamic>> _rows(Map<String, dynamic> r, String key) =>
    ((r[key] ?? const []) as List).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

ApiClient _apiA(RFlow f) => ApiClient.detached(f.app.api.token ?? '')..lang = 'en';

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      return false;
    });

Future<Map<String, dynamic>> _sim(ApiClient api, Map<String, dynamic> body) async {
  final r = await api.postJsonRaw('/ci-e2e/sj-sim', body);
  if (r['ok'] != true) throw TestFailure('sj-sim ${body['op']}: $r');
  return r;
}

Future<double> _now(ApiClient api) async =>
    ((await api.getJson('/ci-e2e/outbox?kind=none'))['now'] as num).toDouble();

Future<List<String>> _pushes(ApiClient api, double since, int uid) async => [
      for (final r in _rows(await api.getJson('/ci-e2e/outbox?since=$since&kind=push&user=$uid'), 'rows'))
        '${(r['data'] as Map?)?['event'] ?? r['push_kind'] ?? ''}'
    ];

class _Setup {
  final int a, b, c, bMemberOfA;
  final String bName, cName;
  _Setup(this.a, this.b, this.c, this.bMemberOfA, this.bName, this.cName);
}

Future<_Setup> _setup(ApiClient api) async {
  final w = await _sim(api, {'op': 'whoami'});
  final peers = _rows(w, 'peers');
  if (peers.isEmpty) throw TestFailure('A has nobody in My Circle: $w');
  final b = peers.first;
  final g = await _sim(api, {'op': 'guardians', 'first': b['user_id']});
  return _Setup((w['me'] as num).toInt(), (b['user_id'] as num).toInt(), (g['second'] as num).toInt(),
      (b['member_id'] as num).toInt(), '${b['name']}', '${g['second_name']}');
}

Future<void> _endActive(ApiClient api) async {
  for (var i = 0; i < 3; i++) {
    final a = await api.getJson('/journey/active');
    if (a['id'] == null) return;
    await api.postJsonRaw('/journey/${a['id']}/arrived', {'pin': _pin});
    final b = await api.getJson('/journey/active');
    if (b['id'] != null) await api.postJsonRaw('/journey/${b['id']}/stop', {'pin': _pin});
  }
}

Future<int> _start(ApiClient api, int watcherMember, {int etaMin = 80}) async {
  await _endActive(api);
  final r = await api.postJson('/journey/start', {
    'destination': {'name': 'Sample Chowrasta', 'lat': _d.$1, 'lng': _d.$2},
    'origin': {'lat': _o.$1, 'lng': _o.$2},
    'eta': DateTime.now().toUtc().add(Duration(minutes: etaMin)).toIso8601String(),
    'watcher_ids': [watcherMember],
    'mode': 'local_bus',
    'vehicle': {'mode': 'local_bus'},
  });
  return ((r['id'] ?? (r['journey'] as Map?)?['id']) as num).toInt();
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

/// Real airplane mode through the CI host (tools/reality/run_flows.sh).
Future<void> _airplane(RFlow f, bool on) async {
  final file = 'splnet_${on ? 'off' : 'on'}_${_tag}_${_n++}';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_NET ${on ? 'off' : 'on'} $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) break;
  }
  await f.eventually(on ? 'backend UNREACHABLE (airplane mode on)' : 'backend reachable again',
      () async => (await _reachable()) != on,
      seconds: on ? 30 : 90);
}

Future<void> _pop(RFlow f, Type screen) async {
  final s = find.byType(screen);
  if (s.evaluate().isEmpty) return;
  await Navigator.of(f.tester.element(s.first)).maybePop();
  await f.pumpFor(const Duration(milliseconds: 1200));
}

void registerSafetyPlanFlows() {
  // --------------------------------------------------------- 1 two guardians
  realityFlow('spl1_two_guardians_journey', 'Safety plan proof (row 49)',
      'Child with two guardians: the trip start, late and arrival reach BOTH (the second one was not even picked); the child sees both names',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final s = await f.net(() => _setup(api));
    late int jid;
    late double since;
    await f.step('A (child) starts a trip and picks ONLY guardian 1 (${s.bName})', () async {
      since = await f.net(() => _now(api));
      jid = await f.net(() => _start(api, s.bMemberOfA));
      await f.eventually('start reached guardian 1 AND guardian 2', () async {
        final b = await _pushes(api, since, s.b), c = await _pushes(api, since, s.c);
        f.note('pushes B=$b C=$c');
        return b.contains('started') && c.contains('started');
      }, seconds: 30);
    });
    await f.step('A\'s live screen says who sees the trip: both guardians', () async {
      await f.pushScreen(JourneyLiveScreen(journeyId: jid), settleSeconds: 4);
      final skip = find.byKey(const ValueKey('j100b_bg_skip'));
      if (await f.appears(skip, seconds: 2)) await f.tap(skip, settleSeconds: 2);
      final notNow = find.text(f.t.notNow);
      if (await f.appears(notNow, seconds: 2)) await f.tap(notNow, settleSeconds: 2);
      final seen = find.byKey(const ValueKey('gsj_seen_by'));
      await f.waitFor(seen, what: '"Seen by" line');
      final txt = (f.tester.widget<Text>(seen).data ?? '');
      f.note('seen-by: $txt');
      if (!txt.contains(s.cName)) throw TestFailure('guardian 2 (${s.cName}) not named: "$txt"');
      await f.shot('seen_by_both');
    });
    await f.step('the trip runs late (stuck 100 min, past the ETA): BOTH guardians alerted', () async {
      since = await f.net(() => _now(api));
      await f.net(() => _sim(api, {
            'op': 'replay',
            'journey': jid,
            'minutes_ago': 110,
            'points': [
              for (var m = 0; m <= 108; m += 4) [m, _o.$1 + 0.0004, _o.$2],
            ],
          }));
      await f.eventually('a late alert reached guardian 1 AND guardian 2', () async {
        final b = await _pushes(api, since, s.b), c = await _pushes(api, since, s.c);
        f.note('late pushes B=$b C=$c');
        return b.any(_late.contains) && c.any(_late.contains);
      }, seconds: 40);
    });
    await f.step('A arrives: BOTH guardians told', () async {
      since = await f.net(() => _now(api));
      await f.net(() => api.postJsonRaw('/journey/$jid/arrived', {'pin': _pin}));
      await f.eventually('arrival reached guardian 1 AND guardian 2', () async {
        final b = await _pushes(api, since, s.b), c = await _pushes(api, since, s.c);
        f.note('arrive pushes B=$b C=$c');
        bool done(List<String> l) => l.any((k) => k.startsWith('arriv') || k == 'stopped');
        return done(b) && done(c);
      }, seconds: 30);
    });
    await _pop(f, JourneyLiveScreen);
    await f.net(() => _endActive(api));
  }, timeout: const Duration(minutes: 6));

  // --------------------------------------------- 2 the plan, shared, offline
  realityFlow('spl2_safety_plan_shared_offline', 'Safety plan proof (row 49)',
      'Family safety plan made on the phone (meeting place, who to call, 999), shared with guardian 1 who reads it; in REAL airplane mode it still opens from the phone',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final s = await f.net(() => _setup(api));
    await f.net(() => api.deleteJson('/safety-plan'));
    await f.step('open Safe Journey -> Family safety plan (empty state)', () async {
      await f.openRoute('journey');
      final btn = find.byKey(const ValueKey('sjl_btn_plan'));
      await f.scrollToBuilt(btn, what: 'Family safety plan button');
      await f.tap(btn, settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('spl_make')), what: 'Make our plan');
      await f.shot('empty');
    });
    await f.step('make it: who to call = guardian 1 (one tap), 999 kept, share with guardian 1', () async {
      await f.tap(find.byKey(const ValueKey('spl_make')), settleSeconds: 3);
      final add = find.byKey(ValueKey('spl_add_call_${s.bMemberOfA}'));
      await f.scrollToBuilt(add, what: 'guardian 1 chip');
      await f.tap(add);
      final share = find.byKey(ValueKey('spl_share_${s.bMemberOfA}'));
      await f.scrollToBuilt(share, what: 'share checkbox');
      await f.tap(share);
      await f.shot('edit');
      final save = find.byKey(const ValueKey('spl_save'));
      await f.scrollToBuilt(save, what: 'Save and share');
      await f.tap(save, settleSeconds: 4);
      await f.waitFor(find.byKey(const ValueKey('spl_mine')), what: 'our plan card');
      await f.shot('saved');
    });
    await f.step('guardian 1 reads the plan (server, their own session)', () async {
      final got = await f.net(() => apiB.getJson('/safety-plan'));
      final shared = _rows(got, 'shared');
      final mine = shared.where((x) => x['owner_id'] == s.a).toList();
      if (mine.isEmpty) throw TestFailure('B does not see A\'s plan: $got');
      final plan = (mine.first['plan'] as Map).cast<String, dynamic>();
      final calls = _rows(plan, 'call_order');
      final nums = _rows(plan, 'numbers').map((n) => n['number']).toList();
      f.note('B sees: call=${calls.map((c) => c['name']).toList()} numbers=$nums');
      if (calls.isEmpty || !nums.contains('999')) throw TestFailure('plan incomplete for B: $plan');
    });
    await f.step('REAL airplane mode: the plan still opens on the phone', () async {
      await _pop(f, SafetyPlanScreen);
      await _airplane(f, true);
      try {
        await f.pushScreen(const SafetyPlanScreen(), settleSeconds: 6);
        await f.waitFor(find.byKey(const ValueKey('spl_offline')), seconds: 25, what: 'offline banner');
        await f.waitFor(find.byKey(const ValueKey('spl_mine')), what: 'plan from the phone copy');
        if (find.byKey(const ValueKey('spl_num_0')).evaluate().isEmpty) {
          throw TestFailure('the emergency numbers are missing offline');
        }
        await f.shot('offline');
      } finally {
        await _airplane(f, false);
      }
      await _pop(f, SafetyPlanScreen);
    });
  }, timeout: const Duration(minutes: 6));

  // -------------------------------------------------------- 3 map cost
  realityFlow('spl3_map_cost_per_journey', 'Safety plan proof (row 49)',
      'Map cost per journey: 20 location fixes + late check + arrival = 0 paid map calls; 6 "road time" taps -> only 3 paid Routes calls (per-journey cap), the rest free fallback; counted on the trip',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final s = await f.net(() => _setup(api));
    late int jid;
    late double since;
    await f.step('a live trip with 20 fixes and the sweeper: zero paid map calls', () async {
      jid = await f.net(() => _start(api, s.bMemberOfA));
      since = await f.net(() => _now(api));
      await f.net(() => _sim(api, {
            'op': 'replay',
            'journey': jid,
            'minutes_ago': 40,
            'points': [
              for (var m = 0; m < 40; m += 2) [m, _o.$1 + m * 0.002, _o.$2],
            ],
          }));
      final calls = _rows(await f.net(() => api.getJson('/ci-e2e/outbox?since=$since&kind=maps')), 'rows');
      f.note('paid map calls during the trip itself: ${calls.length}');
      if (calls.isNotEmpty) throw TestFailure('the live trip made paid map calls: $calls');
    });
    await f.step('6 road-time taps: 3 paid Routes calls, then the free fallback', () async {
      since = await f.net(() => _now(api));
      final states = <String>[];
      for (var k = 0; k < 6; k++) {
        final r = await f.net(() => api.getJson(
            '/maps/eta?olat=${(23.80 + k * 0.01).toStringAsFixed(4)}&olng=90.4260&dlat=23.9600&dlng=90.4260&mode=local_bus'));
        states.add('${r['state']}');
      }
      final routes = _rows(await f.net(() => api.getJson('/ci-e2e/outbox?since=$since&kind=maps')), 'rows')
          .where((r) => '${r['url']}'.contains('computeRoutes'))
          .length;
      final j = await f.net(() => api.getJson('/journey/active'));
      final mc = (j['map_calls'] as Map?) ?? const {};
      f.note('tap states=$states paid Routes=$routes map_calls=$mc');
      if (routes > 3) throw TestFailure('per-journey cap broken: $routes Routes calls');
      if (states.where((x) => x == 'ok' || x == 'cache').length > 3) {
        throw TestFailure('more than 3 paid answers: $states');
      }
      if (((mc['calls'] as Map?)?['routes'] ?? -1) != routes) {
        throw TestFailure('the trip counter (${mc['calls']}) != real calls ($routes)');
      }
    });
    await f.net(() => _endActive(api));
  }, timeout: const Duration(minutes: 5));
}
