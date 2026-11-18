// gap-carecall — Care Call main path on the emulator (board row 21).
// Opt-in group 'carecall' (e2e.yml group start+carecall: needs the
// settings_e2eproof fakes — fake clock tick + push outbox). Runs ONLY when
// asked by name; never part of "all".
//
//   B (family) sets a ONE-TIME Care Call for A ~2 min ahead on A's clock,
//   with NO date (the once-date fix: the server picks the next time that
//   clock time comes on A's clock) -> A accepts in the app (consent) ->
//   A's phone plans its OWN alarm at the server's instant (receiver's clock,
//   the emulator is on UTC) -> Android posts the full-screen call-style ring
//   at that time (real clock) -> the server tick rings A too and the phone
//   keeps ONE ring -> the ring screen (what the full-screen intent opens) ->
//   A taps Done -> the server records it and B (family) is told.
//
// The killed-app / screen-off full-screen wake is proven by the notifproof
// case 'carecall' (tools/notifproof/np_driver.py, notif-closed.yml only=carecall).
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/carecall/carecall_alarms.dart';
import 'package:assisto/carecall/carecall_api.dart';
import 'package:assisto/carecall/carecall_plan.dart';
import 'package:assisto/carecall/carecall_ring_screen.dart';
import 'package:assisto/carecall/carecall_screen.dart' show ccReceivedOf;
import 'package:assisto/notifications.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/push/push_service.dart' show appNavigatorKey;

import '../support/harness.dart';

const _oem = MethodChannel('com.assisto/oem_guide');
final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r, String key) =>
    ((r[key] ?? const []) as List).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();

int _uid(Map<String, dynamic> me) => ((me['id'] ?? (me['user'] as Map?)?['id']) as num).toInt();

ApiClient _apiA(RFlow f) {
  final c = ApiClient.detached(f.app.api.token ?? '');
  c.lang = 'en';
  return c;
}

Future<List<Map<String, dynamic>>> _outbox(ApiClient api, {required double since}) async =>
    _rows(await api.getJson('/ci-e2e/outbox?since=$since&kind=push'), 'rows');

Future<double> _now(ApiClient api) async =>
    ((await api.getJson('/ci-e2e/outbox?kind=none'))['now'] as num).toDouble();

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

void registerCareCallProofFlows() {
  realityFlow('cc1_once_rings_on_time', 'Care Call proof',
      'Care Call: B sets a one-time call for A (no date) -> A accepts -> the phone alarm rings at the server slot -> one ring -> Done -> B told',
      (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final since = await f.net(() => _now(api));
    final aId = _uid(await f.net(() => api.getJson('/me')));
    late int ccId;
    late DateTime next;
    await f.step('B sets a ONE-TIME Care Call for A, no date, ~2 min ahead on A\'s clock', () async {
      // the receiver's clock = the zone A's phone reports (the CI emulator is on UTC)
      await f.net(() => api.postJson('/family/brain/ping',
          {'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes}));
      // a re-run: B's older proof calls off (the active limit stays free)
      for (final c in _rows(await f.net(() => apiB.getJson('/carecall')), 'sent')) {
        if ('${c['text']}'.contains('(CC proof')) {
          await f.net(() => apiB.postJson('/carecall/${c['id']}/delete', {}));
        }
      }
      final n = DateTime.now();
      final at = n.add(Duration(minutes: n.second > 40 ? 3 : 2));
      final r = await f.net(() => apiB.postJson('/carecall', {
            'receiver_id': aId,
            'text': 'ওষুধ খাওয়ার সময় (CC proof $_tag)',
            'time': _hhmm(at),
            'repeat': 'once', // no 'date': the server picks the next one on A's clock
          }));
      // quiet hours far from the slot — AFTER the call exists: the link
      // (B -> A) is made by the first call with A's default 22:00-07:00, and
      // /carecall/quiet changes A's existing links (run 44235735125: the UTC
      // emulator sat inside 22-07, the ring was correctly held to 07:00)
      final q = DateTime.now().add(const Duration(hours: 12));
      await f.net(() => api.postJson('/carecall/quiet',
          {'start': _hhmm(q), 'end': _hhmm(q.add(const Duration(minutes: 1)))}));
      final cc = r['care_call'] as Map;
      ccId = (cc['id'] as num).toInt();
      next = DateTime.parse('${cc['next_at']}');
      final ahead = next.difference(DateTime.now()).inSeconds;
      f.note('next_at=${next.toUtc().toIso8601String()} ahead=${ahead}s '
          'date=${cc['date']} receiver_offset_min=${cc['receiver_offset_min']}');
      if (ahead < 30 || ahead > 4 * 60) {
        throw TestFailure('slot not ~2 min ahead on A\'s clock (ahead ${ahead}s, '
            'phone ${DateTime.now().timeZoneOffset})');
      }
      if ((cc['receiver_offset_min'] as num?)?.toInt() != DateTime.now().timeZoneOffset.inMinutes) {
        throw TestFailure('server does not tell the app A\'s clock: ${cc['receiver_offset_min']}');
      }
    });
    await f.step('A opens Care Call -> the invite -> Accept (consent)', () async {
      await f.openRoute('carecall');
      await f.waitFor(find.text('Accept'), seconds: 20, what: 'consent invite');
      await f.shot('invite');
      await f.tap(find.text('Accept'), settleSeconds: 3);
      await f.eventually('B sees "accepted"', () async =>
          _rows(await apiB.getJson('/carecall'), 'sent')
              .any((c) => c['id'] == ccId && c['link'] == 'accepted'));
      await f.shot('accepted');
    });
    late CcLocalRing ring1;
    await f.step('A\'s phone plans its OWN ring at the server\'s instant', () async {
      await f.net(() => Notifications.init());
      await f.eventually('own alarm handed to Android', () async {
        await CareCallSync.run(HttpCareCallApi(f.app.api), lang: 'en', force: true);
        final m = CareCallSync.lastMine;
        if (m == null) return false;
        final plan = ccPlanLocal(ccReceivedOf(m), DateTime.now())
            .where((p) => p.item.id == ccId && p.attempt == 1)
            .toList();
        if (plan.isEmpty) return false;
        ring1 = plan.first;
        final ids = await Notifications.pendingIds();
        return ids != null && ids.contains(ring1.id);
      }, seconds: 40);
      f.note('own ring at ${ring1.at.toUtc().toIso8601String()} slot ${ring1.slot}');
      if (ring1.at.difference(next).inSeconds.abs() > 1) {
        throw TestFailure('own alarm ${ring1.at.toUtc()} != server slot ${next.toUtc()}');
      }
    });
    await f.step('real clock: Android posts the full-screen ring on time (<= 60 s late)', () async {
      int? post;
      await f.eventually('ring posted', () async {
        final m = await _oem.invokeMethod<Map>('activePostTimes');
        final v = m?[ring1.id];
        post = v is int ? v : null;
        return post != null;
      }, seconds: 300);
      final lateS = ((post! - next.millisecondsSinceEpoch) / 1000).round();
      f.note('ring posted ${lateS}s after its time');
      await f.shot('ring-posted');
      if (lateS < -5 || lateS > 60) throw TestFailure('ring ${lateS}s off its time');
    });
    late Map<String, String> pushData;
    await f.step('server tick rings A too -> the phone keeps ONE ring', () async {
      await f.net(() => api.postJson('/ci-e2e/tick', {'job': 'carecall_tick', 'advance_min': 1}));
      await f.eventually('ring push to A in the outbox', () async {
        final rows = (await _outbox(api, since: since))
            .where((r) => r['user_id'] == aId && '${r['push_kind']}' == 'carecall' &&
                '${(r['data'] as Map?)?['care_call_id']}' == '$ccId')
            .toList();
        if (rows.isEmpty) return false;
        pushData = (rows.last['data'] as Map).map((k, v) => MapEntry('$k', '$v'));
        return true;
      });
      if (pushData['slot'] != ring1.slot) {
        throw TestFailure('server slot ${pushData['slot']} != phone slot ${ring1.slot}');
      }
      final show = await f.net(() => CareCallAlarms.onPush(PushPayload(pushData)));
      if (show) throw TestFailure('the push would ring a SECOND time after the own alarm');
    });
    await f.step('the ring screen (what the full-screen intent opens) -> Done', () async {
      CareCallRingScreen.openOnce(appNavigatorKey.currentState, pushData);
      await f.waitFor(find.textContaining('(CC proof $_tag)'), seconds: 15, what: 'ring text');
      await f.waitFor(find.text('Done'), seconds: 15, what: 'ring screen Done');
      await f.shot('ringing');
      await f.tap(find.text('Done'), settleSeconds: 4);
      await f.shot('done');
    });
    await f.step('recorded on the server; B (family) is told', () async {
      await f.eventually('B feed: confirmed', () async =>
          _rows(await apiB.getJson('/carecall'), 'feed')
              .any((x) => x['care_call_id'] == ccId && x['kind'] == 'confirmed'));
      final bId = _uid(await f.net(() => apiB.getJson('/me')));
      await f.eventually('"confirmed" push to B in the outbox', () async =>
          (await _outbox(api, since: since)).any((r) =>
              r['user_id'] == bId && '${r['push_kind']}' == 'carecall_status' &&
              '${(r['data'] as Map?)?['status']}' == 'done'));
      final sent = _rows(await f.net(() => apiB.getJson('/carecall')), 'sent')
          .firstWhere((c) => c['id'] == ccId);
      if (sent['active'] != false) throw TestFailure('the one-time call did not switch itself off');
    });
  }, timeout: const Duration(minutes: 9));
}
