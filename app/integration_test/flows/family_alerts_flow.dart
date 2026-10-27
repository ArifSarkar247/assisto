// family100: family alerts by server push on two seeded accounts. B presses
// SOS (the same POST /family/sos every SOS surface uses); the SERVER records
// a delivery for A (the push itself needs FCM on a real phone); A opens the
// Family alerts screen (the push tap's deep link `family_alerts`), sees B's
// SOS, taps "I've seen it" -> B's side shows A as seen; B taps "I'm safe now"
// through the API -> A's SOS card is no longer active.
// Push ringing a locked phone / the receipt time (quality bar ৭) need two
// real phones: owner_actions/FAMILY_SAFETY_100_BN.md.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/family_alerts_screen.dart';

import '../support/harness.dart';

void registerFamilyAlertsFlows() {
  realityFlow('17_family_alerts', 'Family & safety',
      'Family alerts: B SOS -> A sees it in-app -> seen on B\'s side -> safe now (two accounts)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    late int did;
    await f.step('B presses SOS -> server addresses A', () async {
      final r = await f.net(() => apiB.postJson('/family/sos', {
            'source': 'reality',
            'client_id': 'reality-${DateTime.now().millisecondsSinceEpoch}',
          }));
      if (((r['recipients'] as num?) ?? 0) < 1) {
        throw TestFailure('SOS reached nobody: $r (seed edge B->A missing?)');
      }
      f.note('SOS result: $r');
      await f.eventually('A has the SOS delivery', () async {
        final a = await api.getJson('/family/alerts');
        final rows = (a['received'] as List).cast<Map>();
        final sos = rows.where((x) => x['kind'] == 'sos' && x['seen'] != true);
        if (sos.isEmpty) return false;
        did = (sos.first['id'] as num).toInt();
        return true;
      });
    });
    await f.step('A opens Family alerts (push deep link) -> sees B\'s SOS -> I\'ve seen it',
        () async {
      await f.openRoute('family_alerts');
      await f.waitFor(find.byType(FamilyAlertsScreen), what: 'family alerts screen');
      final btn = find.byKey(ValueKey('fa100-seen-$did'));
      await f.waitFor(btn, what: 'SOS card for delivery $did');
      await f.shot('sos_card');
      await f.tester.ensureVisible(btn);
      await f.tap(btn, settleSeconds: 2);
      f.expectHttp('POST', '/family/alerts/$did/seen');
      await f.shot('seen');
    });
    await f.step('B\'s side shows A as seen; B is safe now -> A\'s card stale', () async {
      await f.eventually('B sees "seen"', () async {
        final b = await apiB.getJson('/family/alerts');
        final ev = (b['sent'] as List).cast<Map>().where((e) => e['kind'] == 'sos');
        return ev.isNotEmpty &&
            (ev.first['recipients'] as List).any((r) => r['seen'] == true);
      });
      await f.net(() => apiB.postJson('/family/sos/resolve'));
      await f.eventually('A\'s SOS no longer active', () async {
        final a = await api.getJson('/family/alerts');
        return (a['received'] as List)
            .cast<Map>()
            .where((x) => x['id'] == did)
            .every((x) => x['active'] != true);
      });
    });
  });
}
