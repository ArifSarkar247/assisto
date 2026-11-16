// sjproof — Safe Journey V2 PROOF (owner order 9 Nov 11:15, §PROOF): every
// listed scenario on the emulator with FAKE GPS on the two seeded test
// accounts (A = this phone, B = Reality Karim). Run by e2e.yml with
// group=start+sjproof (settings_e2eproof: fake Google Maps, push outbox,
// CI-only /ci-e2e/sj-sim clock).
//
// Fake GPS, two ways:
//   * the emulator's REAL GPS: `REALITY_GEO lat lng` -> the host runs
//     `adb emu geo fix` (tools/reality/run_flows.sh) — the phone's tracker and
//     the destination alarm read it like a real phone (also in airplane mode);
//   * the minutes of a trip: /ci-e2e/sj-sim `replay` moves the CALLER's own
//     journey back in time and feeds its fixes minute by minute through the
//     same server code as POST /journey/<id>/location + the sweeper (a real
//     trip needs real minutes: 2-min dwell, 5-min private ask, 30-min stop).
// The app then shows what the server decided. Made-up places and people only.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_watch_screen.dart';
import 'package:assisto/screens/safe_journey/sj_child_school_screen.dart';
import 'package:assisto/screens/safe_journey/sj_private_ask_screen.dart';
import 'package:assisto/screens/train/dest_alarm_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/services/journey_tracker.dart';
import 'package:assisto/train/dest_alarm_service.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;
int _geoN = 0;

// a made-up ~20 km trip due north (a "Badda -> Gazipur" style ride)
const _o = (23.7800, 90.4260);
const _d = (23.9600, 90.4260);
const _pin = '2468', _dangerPin = '1357';
const _watcherKinds = {
  'check_on', 'check_red', 'overdue_alert', 'long_stop', 'off_route', 'signal_lost',
  'fast_pin', 'arrival_unusual', 'danger_pin', 'duress',
};

(double, double) _north((double, double) p, double m) => (p.$1 + m / 111320.0, p.$2);
(double, double) _east((double, double) p, double m) =>
    (p.$1, p.$2 + m / (111320.0 * math.cos(p.$1 * math.pi / 180)));

List<Map<String, dynamic>> _rows(Map<String, dynamic> r, String key) =>
    ((r[key] ?? const []) as List).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      return false;
    });

/// The app's own session as a plain client (never a second sign-in).
ApiClient _apiA(RFlow f) => ApiClient.detached(f.app.api.token ?? '')..lang = 'en';

Future<Map<String, dynamic>> _sim(ApiClient api, Map<String, dynamic> body) async {
  Map<String, dynamic>? r;
  Object? err;
  try {
    r = await api.postJsonRaw('/ci-e2e/sj-sim', body);
  } catch (e) {
    err = e; // e.g. 409 no_train_running_now
  }
  if (r == null || r['ok'] != true) throw TestFailure('sj-sim ${body['op']}: ${r ?? err}');
  return r;
}

Future<double> _now(ApiClient api) async =>
    ((await api.getJson('/ci-e2e/outbox?kind=none'))['now'] as num).toDouble();

/// Push events the fakes "sent" to [uid] since [since] (data.event list).
Future<List<String>> _pushes(ApiClient api, double since, int uid) async =>
    [
      for (final r in _rows(await api.getJson('/ci-e2e/outbox?since=$since&kind=push&user=$uid'), 'rows'))
        '${(r['data'] as Map?)?['event'] ?? r['push_kind'] ?? ''}'
    ];

class _People {
  final int a, b, bMemberOfA, aMemberOfB;
  final String nameA;
  _People(this.a, this.b, this.bMemberOfA, this.aMemberOfB, this.nameA);
}

Future<_People> _people(ApiClient api, ApiClient apiB) async {
  final wa = await _sim(api, {'op': 'whoami'});
  final wb = await _sim(apiB, {'op': 'whoami'});
  Map<String, dynamic> peer(Map<String, dynamic> w, int uid) =>
      _rows(w, 'peers').firstWhere((p) => p['user_id'] == uid,
          orElse: () => throw TestFailure('A and B are not in each other\'s My Circle: $w'));
  final a = (wa['me'] as num).toInt(), b = (wb['me'] as num).toInt();
  return _People(a, b, (peer(wa, b)['member_id'] as num).toInt(),
      (peer(wb, a)['member_id'] as num).toInt(), '${wa['name']}');
}

/// End whatever journey [api]'s user has running (a leftover from a re-run).
Future<void> _endActive(ApiClient api) async {
  for (var i = 0; i < 3; i++) {
    final a = await api.getJson('/journey/active');
    if (a['id'] == null) return;
    await api.postJsonRaw('/journey/${a['id']}/arrived', {'pin': _pin});
    final b = await api.getJson('/journey/active');
    if (b['id'] != null) await api.postJsonRaw('/journey/${b['id']}/stop', {'pin': _pin});
  }
}

Future<int> _start(ApiClient api, int watcherMember,
    {(double, double) dest = _d, String name = 'Sample Chowrasta', int etaMin = 80,
    String mode = 'local_bus', String kind = ''}) async {
  await _endActive(api);
  final r = await api.postJson('/journey/start', {
    'destination': {'name': name, 'lat': dest.$1, 'lng': dest.$2, if (kind.isNotEmpty) 'kind': kind},
    'origin': {'lat': _o.$1, 'lng': _o.$2},
    'eta': DateTime.now().toUtc().add(Duration(minutes: etaMin)).toIso8601String(),
    'watcher_ids': [watcherMember],
    'mode': mode,
    'vehicle': {'mode': mode},
  });
  return ((r['id'] ?? (r['journey'] as Map?)?['id']) as num).toInt();
}

Future<Map<String, dynamic>> _replay(ApiClient api, int jid, int minutesAgo,
    List<(num, (double, double)?)> pts) =>
    _sim(api, {
      'op': 'replay',
      'journey': jid,
      'minutes_ago': minutesAgo,
      'points': [
        for (final (m, p) in pts) [m, p?.$1, p?.$2]
      ],
    });

/// Ask the CI host to move the emulator's GPS and wait for its ack.
Future<void> _geo(RFlow f, (double, double) p) async {
  final file = 'geo_${_tag}_${_geoN++}';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_GEO ${p.$1.toStringAsFixed(6)} ${p.$2.toStringAsFixed(6)} $file');
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) return;
  }
  f.note('no ack for $file (GPS may lag)');
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

/// Real airplane mode through the CI host (as offline_first_flow).
Future<void> _airplane(RFlow f, bool on) async {
  final file = 'sjnet_${on ? 'off' : 'on'}_${_tag}_${_geoN++}';
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

Future<void> _openLive(RFlow f, int jid) async {
  await f.pushScreen(JourneyLiveScreen(journeyId: jid), settleSeconds: 4);
  // the battery-saver sheet / our location reason may come first on a fresh phone
  final skip = find.byKey(const ValueKey('j100b_bg_skip'));
  if (await f.appears(skip, seconds: 2)) await f.tap(skip, settleSeconds: 2);
  // location is granted by the CI host; our own reason dialog = "Not now"
  final notNow = find.text(f.t.notNow);
  if (await f.appears(notNow, seconds: 2)) await f.tap(notNow, settleSeconds: 2);
  // the private ask may already cover it (then the live screen is offstage)
  await f.waitFor(
      find.byWidgetPredicate((w) => w is JourneyLiveScreen || w is SjPrivateAskScreen,
          skipOffstage: false),
      what: 'live journey screen');
}

/// Night (22:00-06:00 Dhaka): the trip checks in privately by itself (owner
/// V2) — a night check-in is the traveller's own private ask, never an alert.
bool _night() {
  final h = DateTime.now().toUtc().add(const Duration(hours: 6)).hour;
  return h >= 22 || h < 6;
}

void registerSjProofFlows() {
  // ------------------------------------------------------------ 1 place search
  realityFlow('sjp01_place_search_budget', 'Safe Journey V2 proof',
      'Place search with the Google budget ON and OFF: Gai / গাইবান্ধা / Badda / Shahjalal airport from our own list, Google only under 5 good matches, never a limit message',
      (f) async {
    await f.home();
    final api = _apiA(f);
    Future<void> openForm() async {
      await f.openRoute('journey');
      final trip = find.byKey(const ValueKey('sjl_btn_trip'));
      if (await f.appears(trip, seconds: 8)) {
        await f.tester.ensureVisible(trip);
        await f.tap(trip, settleSeconds: 3);
      }
      await f.waitFor(find.byKey(const ValueKey('j100_dest')), what: 'destination field');
    }

    Future<void> expectRow(String typed, String shows) async {
      final field = find.byKey(const ValueKey('j100_dest'));
      await f.tester.tap(field);
      await f.tester.enterText(field, typed);
      final row = find.ancestor(of: find.textContaining(shows), matching: find.byType(ListTile));
      await f.waitFor(row, seconds: 12, what: '"$shows" suggested for "$typed"');
      if (find.text(f.t.mapscSearchCapped).evaluate().isNotEmpty ||
          find.text(f.t.mapscSearchOff).evaluate().isNotEmpty) {
        throw TestFailure('a limit / off message was shown for "$typed"');
      }
    }

    Future<int> googleCalls(double since) async => _rows(
            await api.getJson('/ci-e2e/outbox?since=$since&kind=maps'), 'rows')
        .where((r) => '${r['url']}'.contains('autocomplete'))
        .length;

    try {
      for (final on in [true, false]) {
        final label = on ? 'budget ON' : 'budget OFF (used up)';
        await f.step('$label: Gai / গাইবান্ধা / Badda / Shahjalal airport from our own list', () async {
          await f.net(() => _sim(api, {'op': 'maps', 'global_day': on ? null : 0}));
          await openForm();
          final since = await f.net(() => _now(api));
          await expectRow('Gai', 'Gaibandha');
          await f.shot('${on ? 'on' : 'off'}_gai');
          await expectRow('গাইবান্ধা', 'Gaibandha');
          await f.shot('${on ? 'on' : 'off'}_gaibandha_bn');
          await expectRow('Badda', 'Badda');
          await expectRow('Shahjalal airport', 'Shahjalal');
          await f.shot('${on ? 'on' : 'off'}_airport');
          final g = await f.net(() => googleCalls(since));
          f.note('$label: Google autocomplete calls for the 4 BD names = $g');
        });
        await f.step('$label: a rare name -> Google ${on ? 'adds' : 'silently skipped'}', () async {
          final since = await f.net(() => _now(api));
          final field = find.byKey(const ValueKey('j100_dest'));
          await f.tester.tap(field);
          await f.tester.enterText(field, 'Chandra Bus');
          await f.pumpFor(const Duration(seconds: 4));
          if (find.text(f.t.mapscSearchCapped).evaluate().isNotEmpty ||
              find.text(f.t.mapscSearchOff).evaluate().isNotEmpty) {
            throw TestFailure('a limit / off message was shown ($label)');
          }
          final g = await f.net(() => googleCalls(since));
          if (on) {
            await f.waitFor(
                find.ancestor(of: find.textContaining('Chandra Bus Stand'), matching: find.byType(ListTile)),
                seconds: 12, what: 'Google row (fewer than 5 good matches, budget on)');
            if (g < 1) throw TestFailure('budget on, few matches: Google was not asked');
          } else if (g != 0) {
            throw TestFailure('budget used up: $g paid Google calls');
          }
          await f.shot('${on ? 'on' : 'off'}_rare');
          FocusManager.instance.primaryFocus?.unfocus();
          await f.backToHome();
        });
      }
    } finally {
      await f.net(() => _sim(api, {'op': 'maps', 'global_day': null}));
    }
  }, timeout: const Duration(minutes: 6));

  // ------------------------------------------------------------ 2 normal trip
  realityFlow('sjp02_normal_trip', 'Safe Journey V2 proof',
      'Normal trip (B travels, A watches): moving the whole way -> Arrived only after 2 minutes inside the radius; zero alerts to the family',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final p = await f.net(() => _people(api, apiB));
    late int jid;
    late double since;
    await f.step('B starts a 20 km trip with A watching; 70 minutes of fake GPS', () async {
      since = await f.net(() => _now(api));
      jid = await f.net(() => _start(apiB, p.aMemberOfB, etaMin: 80));
      final r = await f.net(() => _replay(apiB, jid, 70, [
            for (var m = 0; m <= 70; m++) (m, _north(_o, math.min(20000 - 40.0, m * 300.0)))
          ]));
      if (r['status'] != 'arrived') throw TestFailure('never arrived: $r');
      final bad = (r['events'] as List).where((e) => _watcherKinds.contains(e)).toList();
      if (bad.isNotEmpty) throw TestFailure('watcher alerts on a normal trip: $bad');
      f.note('server: arrived, events ${r['events']}');
    });
    await f.step('A (watcher): Finished list shows B arrived, no badge; no alert push', () async {
      await f.pushScreen(const JourneyWatchScreen());
      await f.waitFor(find.byKey(ValueKey('sjd_card_$jid')), seconds: 20, what: 'B\'s card');
      await f.scrollTo(find.byKey(ValueKey('sjd_card_$jid')));
      await f.shot('watcher_finished');
      final board = await f.net(() => api.getJson('/journey/watch-board'));
      final fin = _rows(board, 'finished').firstWhere((c) => c['id'] == jid,
          orElse: () => throw TestFailure('not in Finished: $board'));
      if ((fin['badges'] as List).isNotEmpty) throw TestFailure('badges on a normal trip: $fin');
      final got = await f.net(() => _pushes(api, since, p.a));
      final alerts = got.where(_watcherKinds.contains).toList();
      if (alerts.isNotEmpty) throw TestFailure('alerts pushed to A: $alerts');
      f.note('pushes to A: $got');
      await _pop(f, JourneyWatchScreen);
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 3 route change
  realityFlow('sjp03_route_change_extend', 'Safe Journey V2 proof',
      'Route change with extend: off route -> PRIVATE "Changed route?" only on the traveller phone -> Yes, add 40 min -> family sees only "Time extended", never Check on',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final p = await f.net(() => _people(api, apiB));
    late int jid;
    late double since;
    final detour = _east(_north(_o, 19 * 300.0), 4000 + 3 * 400.0);
    await f.step('A rides 19 min north, then 4 min on a detour 5 km east', () async {
      since = await f.net(() => _now(api));
      jid = await f.net(() => _start(api, p.bMemberOfA));
      final r = await f.net(() => _replay(api, jid, 23, [
            for (var m = 0; m < 20; m++) (m, _north(_o, m * 300.0)),
            for (var k = 0; k < 4; k++) (20 + k, _east(_north(_o, 19 * 300.0), 4000 + k * 400.0)),
          ]));
      final ask = r['ask'] as Map?;
      if (ask?['kind'] != 'off_route') throw TestFailure('no private off-route ask: $r');
      final got = await f.net(() => _pushes(apiB, since, p.b));
      if (got.where(_watcherKinds.contains).isNotEmpty) {
        throw TestFailure('the family was told before the traveller answered: $got');
      }
      await _geo(f, detour);
    });
    await f.step('A\'s phone: the private screen opens by itself (only on this phone)', () async {
      await _openLive(f, jid);
      await f.waitFor(find.byType(SjPrivateAskScreen), seconds: 20, what: 'private "Changed route?" screen');
      await f.waitFor(find.byKey(const ValueKey('sjd_only_you')), what: '"only on your phone" note');
      await f.waitFor(find.byKey(const ValueKey('sjd_ask_card')), what: 'amber card');
      await f.shot('private_ask');
      final m40 = f.tester.widget<ChoiceChip>(find.byKey(const ValueKey('sjd_min_40')));
      if (!m40.selected) throw TestFailure('default is not 40 minutes');
    });
    await f.step('Yes, add time (40) -> watchers get only "Time extended", no place', () async {
      final btn = find.byKey(const ValueKey('sjd_extend'));
      await f.tester.ensureVisible(btn);
      await f.tap(btn, settleSeconds: 3);
      f.expectHttp('POST', '/journey/$jid/answer');
      await f.eventually('B got "extended"', () async =>
          (await _pushes(apiB, since, p.b)).contains('extended'));
      final rows = _rows(await f.net(() => apiB.getJson('/ci-e2e/outbox?since=$since&kind=push&user=${p.b}')), 'rows');
      final ext = rows.firstWhere((r) => (r['data'] as Map?)?['event'] == 'extended');
      if ('${(ext['data'] as Map)['lat'] ?? ''}'.isNotEmpty) {
        throw TestFailure('the stop place was sent without the traveller choosing it: $ext');
      }
      // five more minutes on the detour: answered = no amber, ever
      final r = await f.net(() => _sim(api, {'op': 'replay', 'journey': jid, 'points': []}));
      if ((r['events'] as List).any(_watcherKinds.contains)) {
        throw TestFailure('watcher alert after the traveller answered: ${r['events']}');
      }
      await f.shot('answered');
      await _pop(f, JourneyLiveScreen);
      await f.net(() => _endActive(api));
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 4 tea stop
  realityFlow('sjp04_tea_stop_near_destination', 'Safe Journey V2 proof',
      'Tea stop 600 m before the destination, past the ETA: "Nearly there" + green "No alert even if late" for the watcher, zero alerts; after 30 min the TRAVELLER is asked first',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final p = await f.net(() => _people(api, apiB));
    final tea = _north(_o, 19400);
    late int jid;
    late double since;
    await f.step('B (late by design) stops for tea 600 m short for 29 minutes', () async {
      since = await f.net(() => _now(api));
      jid = await f.net(() => _start(apiB, p.aMemberOfB, etaMin: 40));
      final r = await f.net(() => _replay(apiB, jid, 92, [
            for (var m = 0; m < 64; m++) (m, _north(_o, math.min(19400.0, m * 300.0))),
            for (var m = 64; m <= 92; m++) (m, tea),
          ]));
      final ask = (r['ask'] as Map?)?['kind'];
      if ((r['events'] as List).any(_watcherKinds.contains) ||
          (ask != null && !(ask == 'night_checkin' && _night()))) {
        throw TestFailure('alert or ask during a 29-minute tea stop: $r');
      }
      if (ask != null) f.note('night trip: private night check-in only (no alert)');
    });
    await f.step('A (watcher): Nearly there + the green note; no alert push', () async {
      await f.pushScreen(const JourneyWatchScreen());
      final card = find.byKey(ValueKey('sjd_card_$jid'));
      await f.waitFor(card, seconds: 20, what: 'B\'s card');
      await f.scrollTo(card);
      await f.waitFor(find.descendant(of: card, matching: find.byKey(const ValueKey('sjd_near_note'))),
          what: 'green "No alert even if late" note');
      if (find.descendant(of: card, matching: find.text(f.t.sjdStNearly)).evaluate().isEmpty) {
        throw TestFailure('card state is not "Nearly there"');
      }
      await f.shot('watcher_nearly_note');
      final got = await f.net(() => _pushes(api, since, p.a));
      if (got.where(_watcherKinds.contains).isNotEmpty) throw TestFailure('alerts to A: $got');
      await _pop(f, JourneyWatchScreen);
    });
    await f.step('30+ minutes there: B is asked privately first, the family still nothing', () async {
      final s2 = await f.net(() => _now(api));
      final j2 = await f.net(() => _start(apiB, p.aMemberOfB, etaMin: 40));
      final r = await f.net(() => _replay(apiB, j2, 97, [
            for (var m = 0; m < 64; m++) (m, _north(_o, math.min(19400.0, m * 300.0))),
            for (var m = 64; m <= 97; m++) (m, tea),
          ]));
      final kind = (r['ask'] as Map?)?['kind'];
      if (kind != 'near_stop' && !(kind == 'night_checkin' && _night())) {
        throw TestFailure('no private near-stop ask: $r');
      }
      if ((r['events'] as List).any(_watcherKinds.contains)) throw TestFailure('family alerted: $r');
      final toB = await f.net(() => _pushes(api, s2, p.b));
      final toA = await f.net(() => _pushes(api, s2, p.a));
      if (toA.where(_watcherKinds.contains).isNotEmpty) throw TestFailure('alerts to A: $toA');
      f.note('to traveller B: $toB');
      await f.net(() => _endActive(apiB));
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 7 two journeys
  realityFlow('sjp07_two_journeys', 'Safe Journey V2 proof',
      'Two journeys at once: A and B on different routes watch each other; A sees own Moving trip + "also watching" B; each board counts 1',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final p = await f.net(() => _people(api, apiB));
    late int ja, jb;
    await f.step('A rides north, B rides east to the airport, 12 minutes each', () async {
      ja = await f.net(() => _start(api, p.bMemberOfA));
      jb = await f.net(() => _start(apiB, p.aMemberOfB,
          dest: (23.8500, 90.4000), name: 'Sample Airport', kind: 'airport', mode: 'cng'));
      final ra = await f.net(() => _replay(api, ja, 12, [
            for (var m = 0; m <= 12; m++) (m, _north(_o, m * 300.0))
          ]));
      final rb = await f.net(() => _replay(apiB, jb, 12, [
            for (var m = 0; m <= 12; m++) (m, _east(_o, -m * 250.0))
          ]));
      if (ra['state'] != 'moving' && ra['state'] != 'slow') throw TestFailure('A: $ra');
      if (rb['status'] != 'active') throw TestFailure('B: $rb');
      await _geo(f, _north(_o, 12 * 300.0));
      final ba = await f.net(() => api.getJson('/journey/watch-board'));
      final bb = await f.net(() => apiB.getJson('/journey/watch-board'));
      if (ba['count'] != 1 || bb['count'] != 1) {
        throw TestFailure('boards: A ${ba['count']} B ${bb['count']}');
      }
      if (_rows(ba, 'active').first['id'] != jb || _rows(bb, 'active').first['id'] != ja) {
        throw TestFailure('each must watch the other');
      }
    });
    await f.step('A\'s phone: own trip "Moving" + B in "also watching"', () async {
      await _openLive(f, ja);
      await f.waitFor(find.byKey(const ValueKey('sjd_state')), seconds: 20, what: 'state line');
      await f.waitFor(_sees(f.t.sjdStMoving), what: '"Moving"');
      await f.scrollTo(_sees(Seed.nameB));
      await f.shot('own_moving_also_watching');
      await _pop(f, JourneyLiveScreen);
    });
    await f.step('A\'s watcher board: 1 active (B, by CNG)', () async {
      await f.pushScreen(const JourneyWatchScreen());
      await f.waitFor(find.byKey(ValueKey('sjd_card_$jb')), seconds: 20, what: 'B\'s card');
      await f.waitFor(find.byKey(const ValueKey('sjd_active_head')), what: 'active count');
      await f.shot('watching_b');
      await _pop(f, JourneyWatchScreen);
      await f.net(() => _endActive(api));
      await f.net(() => _endActive(apiB));
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 8 child
  realityFlow('sjp08_child_unknown_place', 'Safe Journey V2 proof',
      'Children Corner: child (B\'s phone) leaves school for an unknown place in school hours -> after 10 min ONE question to the guardian (A), never red, never to the child -> "I know"',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final p = await f.net(() => _people(api, apiB));
    final dhaka = DateTime.now().toUtc().add(const Duration(hours: 6));
    final mins = dhaka.hour * 60 + dhaka.minute;
    if (mins < 70 || mins > 23 * 60 + 20) {
      f.skip('Dhaka clock ${dhaka.hour}:${dhaka.minute}: a school window around now would cross midnight');
    }
    String hm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
    const home = (23.7808, 90.4130);
    final school = _east(home, 2000);
    final unknown = _east(school, 1200);
    late int plan;
    late double since;
    await f.step('A sets School for B (window around now, every day); B accepts on B\'s phone', () async {
      final r = await f.net(() => api.postJson('/school-mode/plans', {
            'child_user_id': p.b, 'child_name': 'Sample child',
            'start': hm(mins - 60), 'end': hm(math.min(23 * 60 + 59, mins + 60)),
            'commute_min': 20, 'late_min': 15, 'days': [0, 1, 2, 3, 4, 5, 6],
            'home': {'lat': home.$1, 'lng': home.$2, 'radius_m': 150, 'name': 'Home'},
            'school': {'lat': school.$1, 'lng': school.$2, 'radius_m': 150, 'name': 'School'},
            'watcher_ids': <int>[],
          }));
      plan = (((r['plan'] as Map)['id']) as num).toInt();
      await f.net(() => apiB.postJson('/school-mode/plans/$plan/accept'));
    });
    await f.step('B\'s phone: at school, then 16 minutes at an unknown place', () async {
      since = await f.net(() => _now(api));
      await f.net(() => _sim(apiB, {
            'op': 'school',
            'points': [
              [45, school.$1, school.$2], [35, school.$1, school.$2], [25, school.$1, school.$2],
              for (final m in [16, 14, 11, 8, 5, 2, 1]) [m, unknown.$1, unknown.$2],
            ],
          }));
      final toA = await f.net(() => _pushes(api, since, p.a));
      final toB = await f.net(() => _pushes(api, since, p.b));
      if (toA.where((e) => e == 'kc_ask_unknown').length != 1) {
        throw TestFailure('guardian A not asked exactly once: $toA');
      }
      if (toB.contains('kc_ask_unknown')) throw TestFailure('the child got the question: $toB');
      if (toA.any((e) => e == 'left_school_early' || e == 'sos')) {
        throw TestFailure('a red alarm for an unknown place: $toA');
      }
    });
    await f.step('A: the question card in Child School -> "I know" -> answered', () async {
      await f.pushScreen(const SjChildSchoolScreen());
      final ask = find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('kc_ask_ok_'));
      await f.scrollTo(ask);
      await f.waitFor(ask, seconds: 20, what: 'open question card');
      await f.shot('guardian_question');
      await f.tester.ensureVisible(ask.first);
      await f.tap(ask.first, settleSeconds: 3);
      f.expectHttp('POST', '/school-mode/plans/$plan/kc-answer');
      await f.eventually('answered on the server', () async {
        final r = await api.getJson('/school-mode/plans/$plan');
        final asks = _rows(((r['plan'] as Map)['kids_corner'] as Map).cast<String, dynamic>(), 'asks');
        return asks.isNotEmpty && asks.first['state'] == 'ok';
      });
      await f.shot('answered');
      await _pop(f, SjChildSchoolScreen);
      await f.net(() => api.postJsonRaw('/school-mode/plans/$plan/delete'));
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 9 train
  realityFlow('sjp09_train_three_passengers', 'Safe Journey V2 proof',
      'Train position from 3 fake passengers (a train running now): live, within 2 km of the true train, "3 sharing", no names',
      (f) async {
    await f.home();
    final api = _apiA(f);
    late Map<String, dynamic> s;
    await f.step('3 made-up passengers share 20 minutes of fixes (real validation)', () async {
      s = await f.net(() => _sim(api, {'op': 'train'}));
      f.note('train ${s['no']} ${s['date']}: sharers ${s['sharers']}, mode ${s['mode']}, '
          'error ${s['error_m']} m, accepted ${s['accepted']}');
      if (s['mode'] != 'live' || s['sharers'] != 3) throw TestFailure('not live from 3: $s');
      final err = (s['error_m'] as num?)?.toDouble();
      if (err == null || err >= 2000) throw TestFailure('position off by $err m (target < 2000)');
    });
    await f.step('A opens the train screen: header, "3 sharing live", Now passing, line', () async {
      final live = await f.net(() => api.getJson('/train/${s['no']}/live?date=${s['date']}'));
      final body = '$live';
      if (body.contains('Sample passenger') || body.contains('0199900000')) {
        throw TestFailure('a passenger name / phone leaked');
      }
      await f.pushScreen(TrainLiveScreen(no: '${s['no']}', date: '${s['date']}'), settleSeconds: 5);
      await f.waitFor(find.byKey(const ValueKey('sjt_header')), seconds: 20, what: 'train header');
      final en = f.t.sjtSharingMany('3');
      final bn = en.replaceAll('3', '৩');
      if (!await f.appears(_sees(en), seconds: 10) && _sees(bn).evaluate().isEmpty) {
        throw TestFailure('"3 sharing live" not shown');
      }
      await f.waitFor(find.byKey(const ValueKey('sjt_now')), what: '"Now: passing"');
      await f.shot('train_live_3');
      await f.scrollTo(find.byKey(const ValueKey('sjt_line')));
      await f.shot('train_line');
      await _pop(f, TrainLiveScreen);
    });
  }, timeout: const Duration(minutes: 4));

  // ------------------------------------------------------------ 5 impossible early
  realityFlow('sjp05_impossible_early_arrival', 'Safe Journey V2 proof',
      'Impossible early arrival blocked: Badda -> Gazipur, "I\'ve arrived" after 2 min AT the destination (real GPS) -> PIN asked, trip stays live, watchers see "Unusually fast arrival, PIN asked"; safe PIN -> Confirmed with PIN',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final p = await f.net(() => _people(api, apiB));
    late int jid;
    late double since;
    await f.step('A sets a safe PIN + a danger PIN; starts at the start point (real GPS)', () async {
      await f.net(() => api.postJson('/journey/duress-pin', {'pin': _pin, 'duress_pin': _dangerPin}));
      await _geo(f, _o);
      since = await f.net(() => _now(api));
      jid = await f.net(() => _start(api, p.bMemberOfA));
      await _openLive(f, jid);
      await f.shot('live_start');
    });
    await f.step('GPS jumps to the destination 2 minutes later -> tap "I\'ve arrived"', () async {
      final at = _north(_d, -40);
      await _geo(f, at);
      // the same fix through the phone's own endpoint (the tracker may not
      // have sent one yet on a cold emulator)
      await f.net(() => api.postJson('/journey/$jid/location', {'lat': at.$1, 'lng': at.$2, 'acc': 12}));
      await f.pumpFor(const Duration(seconds: 3));
      final btn = find.byKey(const ValueKey('j100_arrived'));
      await f.scrollTo(btn);
      await f.tester.ensureVisible(btn);
      await f.tap(btn, settleSeconds: 2);
      await f.waitFor(find.byKey(const ValueKey('j100_pin_field')), what: 'PIN asked');
      await f.shot('pin_asked');
      if (find.text(f.t.journeyArrivedSafely).evaluate().isNotEmpty) {
        throw TestFailure('"Arrived safely" for an impossible arrival');
      }
      final a = await f.net(() => api.getJson('/journey/active'));
      if (a['id'] != jid) throw TestFailure('the trip ended without the PIN: $a');
      await f.eventually('B: "Unusually fast arrival, PIN asked"', () async =>
          (await _pushes(apiB, since, p.b)).contains('fast_pin'));
      final card = _rows(await f.net(() => apiB.getJson('/journey/watch-board')), 'active')
          .firstWhere((c) => c['id'] == jid);
      if (!(card['badges'] as List).contains('fast_pin')) throw TestFailure('no amber badge: $card');
    });
    await f.step('safe PIN -> Confirmed with PIN (green shield + the amber badge)', () async {
      await f.tester.enterText(find.byKey(const ValueKey('j100_pin_field')), _pin);
      await f.tap(find.byKey(const ValueKey('j100_pin_ok')), settleSeconds: 3);
      await f.eventually('A has no active journey', () async =>
          (await api.getJson('/journey/active'))['id'] == null);
      final fin = _rows(await f.net(() => apiB.getJson('/journey/watch-board')), 'finished')
          .firstWhere((c) => c['id'] == jid);
      final b = (fin['badges'] as List).toSet();
      if (!b.contains('pin_ok') || !b.contains('fast_pin')) throw TestFailure('badges $b');
      await f.shot('confirmed');
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 6 danger PIN
  realityFlow('sjp06_danger_pin_silent_red', 'Safe Journey V2 proof',
      'Danger PIN: the traveller screen shows a normal Arrived; watchers silently get RED with live location (+ 30 s audio); nothing on the traveller phone',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final p = await f.net(() => _people(api, apiB));
    late int jid;
    late double since;
    await f.step('A starts; GPS at the destination too early; "I\'ve arrived" -> PIN box', () async {
      await f.net(() => api.postJson('/journey/duress-pin', {'pin': _pin, 'duress_pin': _dangerPin}));
      await _geo(f, _o);
      since = await f.net(() => _now(api));
      jid = await f.net(() => _start(api, p.bMemberOfA));
      await _openLive(f, jid);
      final at = _north(_d, -40);
      await _geo(f, at);
      await f.net(() => api.postJson('/journey/$jid/location', {'lat': at.$1, 'lng': at.$2, 'acc': 12}));
      final btn = find.byKey(const ValueKey('j100_arrived'));
      await f.scrollTo(btn);
      await f.tester.ensureVisible(btn);
      await f.tap(btn, settleSeconds: 2);
      await f.waitFor(find.byKey(const ValueKey('j100_pin_field')), what: 'PIN asked');
    });
    await f.step('danger PIN -> the same "Arrived safely" here; nothing red on this phone', () async {
      await f.tester.enterText(find.byKey(const ValueKey('j100_pin_field')), _dangerPin);
      await f.tap(find.byKey(const ValueKey('j100_pin_ok')), settleSeconds: 0.5);
      await f.waitFor(find.text(f.t.journeyArrivedSafely), seconds: 6, what: 'normal "Arrived safely"');
      await f.shot('traveller_sees_arrived');
      if (find.text(f.t.sjdLevelRed).evaluate().isNotEmpty) throw TestFailure('red on the traveller phone');
      await f.pumpFor(const Duration(seconds: 2));
      if (find.byType(JourneyLiveScreen).evaluate().isNotEmpty) throw TestFailure('live screen still open');
      if (!JourneyTracker.I.running) throw TestFailure('the phone stopped sharing location');
      final a = await f.net(() => api.getJson('/journey/active'));
      if (a['id'] != null) throw TestFailure('the traveller phone still shows a trip: $a');
    });
    await f.step('B (watcher): silent RED with the live location; A got nothing', () async {
      await f.eventually('B got danger_pin', () async =>
          (await _pushes(apiB, since, p.b)).contains('danger_pin'));
      final card = _rows(await f.net(() => apiB.getJson('/journey/watch-board')), 'active')
          .firstWhere((c) => c['id'] == jid, orElse: () => throw TestFailure('not active for B'));
      if (card['level'] != 'red' || card['lat'] == null) throw TestFailure('B card $card');
      final toA = await f.net(() => _pushes(api, since, p.a));
      if (toA.any((e) => e == 'danger_pin' || e == 'sos')) throw TestFailure('A was told: $toA');
      // the phone keeps sending: a fresh fix reaches B's card
      final moved = _north(_d, 300);
      await f.net(() => api.postJson('/journey/$jid/location', {'lat': moved.$1, 'lng': moved.$2, 'acc': 12}));
      await f.eventually('B sees the new position', () async {
        final c = _rows(await apiB.getJson('/journey/watch-board'), 'active')
            .firstWhere((c) => c['id'] == jid, orElse: () => {});
        return ((c['lat'] as num?) ?? 0) > _d.$1;
      });
      final audio = await f.net(() async {
        try {
          return await apiB.getJson('/journey/$jid/danger-audio');
        } catch (_) {
          return <String, dynamic>{}; // no clip (the emulator has no microphone)
        }
      });
      f.note('30 s clip at B: ${audio['audio_b64'] != null ? 'yes' : 'not yet (emulator mic)'}');
      await f.net(() => JourneyTracker.I.stop());
    });
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------ 10 offline alarm
  realityFlow('sjp10_offline_destination_alarm', 'Safe Journey V2 proof',
      'Destination alarm OFFLINE (real airplane mode, real emulator GPS): set offline, rings before the stop, loud until "I\'m awake" — 3 of 3',
      (f) async {
    await f.home();
    const target = (23.9000, 90.4100);
    var rang = 0;
    try {
      await f.step('airplane mode ON', () async => _airplane(f, true));
      for (var round = 1; round <= 3; round++) {
        await f.step('round $round: set the alarm offline, GPS approaches, it rings', () async {
          await _geo(f, _north(target, -6000));
          await f.pushScreen(DestAlarmScreen(
            suggested: const [
              {'id': 'sjp_t', 'en': 'Sample Halt', 'bn': 'নমুনা হল্ট', 'lat': 23.9, 'lng': 90.41},
            ],
            suggestedIds: const ['sjp_t'],
            initialStationId: 'sjp_t',
          ), settleSeconds: 4);
          final start = find.text(f.t.trAlarmStart);
          await f.scrollTo(start);
          await f.tester.ensureVisible(start.first);
          await f.tap(start.first, settleSeconds: 3);
          final plan = DestAlarmController.I.value.plan;
          if (plan == null) throw TestFailure('alarm did not start offline');
          if (round == 1) await f.shot('alarm_set_offline');
          // still far: never rings
          await f.pumpFor(const Duration(seconds: 8));
          if (DestAlarmController.I.value.phase == DestAlarmPhase.ringing) {
            throw TestFailure('rang 6 km away (set ${plan.setM} m)');
          }
          // the bus comes closer: inside the set distance
          await _geo(f, _north(target, -(plan.setM * 0.6 + 100)));
          final end = DateTime.now().add(const Duration(seconds: 150));
          while (DateTime.now().isBefore(end) &&
              DestAlarmController.I.value.phase != DestAlarmPhase.ringing) {
            await f.pumpFor(const Duration(seconds: 2));
          }
          if (DestAlarmController.I.value.phase != DestAlarmPhase.ringing) {
            throw TestFailure('did not ring offline (state ${DestAlarmController.I.value.phase}, '
                'distance ${DestAlarmController.I.value.distanceM}, off ${DestAlarmController.I.value.locationOff})');
          }
          rang++;
          await f.waitFor(find.text(f.t.trImAwake), what: '"I\'m awake" button');
          await f.shot('ringing_$round');
          await f.tap(find.text(f.t.trImAwake).first, settleSeconds: 2);
          if (DestAlarmController.I.value.phase == DestAlarmPhase.ringing) {
            throw TestFailure('still ringing after "I\'m awake"');
          }
          await DestAlarmController.I.stop();
          await _pop(f, DestAlarmScreen);
        });
      }
    } finally {
      f.note('offline alarm rang $rang of 3');
      await DestAlarmController.I.stop();
      await _airplane(f, false);
    }
  }, timeout: const Duration(minutes: 12));
}
