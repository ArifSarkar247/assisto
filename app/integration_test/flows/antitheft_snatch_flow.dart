// at100: two-phone snatch proof on two seeded accounts.
//   PROTECTED phone = account B. Its native engine is driven through the SAME
//     HTTP contract the Kotlin AntiTheftService uses (X-Assisto-Engine token:
//     /security/engine/ingest heartbeats, events, command results).
//   TRUSTED CONTACT = account A, the app on screen.
// B turns protection on with A as the trusted contact -> a simulated grab
// reaches the server -> A is told (watched phones list + timeline) -> the
// phone goes quiet (offline: no check-ins) -> A turns LOST MODE on and rings
// the ALARM from the app: both wait honestly -> the phone comes back online,
// its check-in receives both switches and reports the results -> A's card
// says Done, and A's signed web watch page shows the switch states.
// The real radio / power-off / FCM wake on two physical phones:
// owner_actions/ANTITHEFT_100_BN.md (10-minute owner test).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:assisto/config.dart';
import 'package:assisto/screens/watched_phones_screen.dart';
import 'package:assisto/widgets/remote_switches_card.dart';

import '../support/harness.dart';

const _base = String.fromEnvironment('REALITY_API_BASE');
const _pin = '4826';

Future<Map<String, dynamic>> _engine(String token, List<Map<String, dynamic>> items) async {
  final r = await http.post(AppConfig.api('/security/engine/ingest'),
      headers: {'Content-Type': 'application/json', 'X-Assisto-Engine': token},
      body: jsonEncode({
        'sent_at': DateTime.now().toUtc().toIso8601String(),
        'items': items,
      }));
  if (r.statusCode != 200) {
    throw TestFailure('engine ingest ${r.statusCode}: ${r.body}');
  }
  return (jsonDecode(r.body) as Map).cast<String, dynamic>();
}

Map<String, dynamic> _hb(String id) => {
      'id': id,
      'kind': 'heartbeat',
      'at': DateTime.now().millisecondsSinceEpoch,
      'battery': 64,
      'network': 'mobile',
      'interval': 5,
      'lat': 23.7330,
      'lng': 90.4172,
      'acc': 18.0,
      'fix_at': DateTime.now().millisecondsSinceEpoch,
    };

void registerAntiTheftSnatchFlows() {
  realityFlow('18_antitheft_snatch', 'Family & safety',
      'Anti-theft: B protected, A trusted -> grab alert -> offline -> lost mode + alarm wait -> back online -> done (two accounts)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    late String token;
    late int phoneId;
    final run = DateTime.now().millisecondsSinceEpoch;

    await f.step('B turns protection on with A as the trusted contact', () async {
      await f.net(() => apiB.postJsonRaw('/security/pin/set', {'new_pin': _pin}));
      final st = await f.net(() => apiB.getJson('/security/engine/state'));
      phoneId = (st['phone_id'] as num).toInt();
      final cands = ((st['candidates'] as List?) ?? const []).cast<Map>();
      final a = cands.where((c) => '${c['name']}'.contains('Rahim')).toList();
      if (a.isEmpty) throw TestFailure('A is not in B\'s circle: $cands');
      final r = await f.net(() => apiB.postJsonRaw('/security/engine/enable', {
            'pin': _pin,
            'alert_member_ids': [a.first['id']],
            'capabilities': {'deviceAdmin': true, 'locationPermission': true},
          }));
      if (r['ok'] != true) throw TestFailure('enable failed: $r');
      token = '${r['engine_token']}';
      await f.net(() => _engine(token, [_hb('hb-$run-1')]));
    });

    await f.step('phone B is grabbed -> A is told', () async {
      final res = await f.net(() => _engine(token, [
            {
              'id': 'snatch-$run',
              'kind': 'snatch',
              'at': DateTime.now().millisecondsSinceEpoch,
              'lat': 23.7331, 'lng': 90.4170, 'acc': 12.0,
              'data': {'locked': false, 'charging': false, 'hour': 14},
            }
          ]));
      f.note('ingest: ${res['accepted']}');
      await f.eventually('A watches B\'s phone', () async {
        final w = await api.getJson('/security/engine/watching');
        return ((w['watching'] as List?) ?? const [])
            .any((p) => (p as Map)['phone_id'] == phoneId);
      });
      final tl = await f.net(() => api.getJson('/security/engine/timeline?phone_id=$phoneId'));
      final grab = ((tl['events'] as List?) ?? const [])
          .cast<Map>()
          .where((e) => e['kind'] == 'snatch')
          .toList();
      if (grab.isEmpty) throw TestFailure('no grab on A\'s timeline: $tl');
      final rc = (grab.first['recipients'] as num?)?.toInt() ?? 0;
      if (rc < 1) throw TestFailure('grab told nobody: ${grab.first}');
    });

    await f.step('phone goes quiet; A turns on lost mode + rings from the app', () async {
      await f.openRoute('watched_phones');
      await f.waitFor(find.byType(RemoteSwitchesCard), what: 'remote switches');
      expect(find.byType(WatchedPhoneScreen), findsWidgets);
      await f.shot('watched_phone');
      final lost = find.byKey(const Key('at100-lost_mode'));
      await f.scrollTo(lost);
      await f.tap(lost);
      await f.tester.enterText(find.byKey(const Key('at100-msg')),
          'Reality: this phone is lost, please call');
      await f.tap(find.byKey(const Key('at100-msg-send')), settleSeconds: 3);
      f.expectHttp('POST', '/security/engine/command');
      final alarm = find.byKey(const Key('at100-alarm'));
      await f.scrollTo(alarm);
      await f.tap(alarm);
      await f.tap(find.byKey(const Key('at100-confirm')), settleSeconds: 3);
      final c = await f.net(() => api.getJson('/security/engine/commands?phone_id=$phoneId'));
      final states = ((c['commands'] as List).cast<Map>())
          .where((x) => x['kind'] == 'alarm' || x['kind'] == 'lost_mode')
          .map((x) => x['state'])
          .toSet();
      if (!states.every((s) => s == 'queued' || s == 'sent')) {
        throw TestFailure('switches should wait for the phone: $states');
      }
      await f.shot('switches_waiting');
    });

    await f.step('phone back online: receives both, reports done', () async {
      final res = await f.net(() => _engine(token, [_hb('hb-$run-2')]));
      final cmds = ((res['commands'] as List?) ?? const []).cast<Map>();
      final kinds = cmds.map((c) => c['kind']).toSet();
      if (!kinds.containsAll({'lost_mode', 'alarm'})) {
        throw TestFailure('check-in did not carry the switches: $cmds');
      }
      if (res['lost_mode'] != true) throw TestFailure('lost mode not on: $res');
      await f.net(() => _engine(token, [
            for (final c in cmds)
              {
                'id': 'cmd-${c['id']}',
                'kind': 'command_result',
                'at': DateTime.now().millisecondsSinceEpoch,
                'data': {'command_id': c['id'], 'ok': true,
                    'detail': c['kind'] == 'alarm' ? 'rang_60s' : 'lost_mode_message_shown'},
              }
          ]));
      final refresh = find.byKey(const Key('at100-refresh'));
      await f.scrollTo(refresh);
      await f.tap(refresh, settleSeconds: 3);
      final c = await f.net(() => api.getJson('/security/engine/commands?phone_id=$phoneId'));
      final done = ((c['commands'] as List).cast<Map>())
          .where((x) => (x['kind'] == 'alarm' || x['kind'] == 'lost_mode') && x['state'] == 'done');
      if (done.length < 2) throw TestFailure('not done: ${c['commands']}');
      await f.shot('switches_done');
      if (_base.isNotEmpty && '${c['web_path']}'.startsWith('/w/phone/')) {
        final r = await f.net(() => http.get(Uri.parse('$_base${c['web_path']}?lang=en')));
        if (r.statusCode != 200 || !r.body.contains('Remote actions') ||
            !r.body.contains('Done')) {
          throw TestFailure('watch page: ${r.statusCode}');
        }
      }
    });

    await f.step('cleanup: B turns protection off', () async {
      // lost mode stays (only the owner + PIN turns it off) — reset for reruns
      await f.net(() => apiB.postJsonRaw('/security/action',
          {'action': 'turn_off_lost', 'pin': _pin}));
      await f.net(() => apiB.postJsonRaw('/security/engine/disable', {'pin': _pin}));
    });
  });
}
