// fcscreen (Family Care v3, owner order 9 Nov 10:50) — two seeded accounts on
// the throw-away backend:
//   1 A invites B from My Circle into A's family; B is NOT a member until B
//     taps Join on B's own phone (API as B) — consent only;
//   2 B's phone reports (presence heartbeat, a real endpoint) -> A's Family
//     screen shows B GREEN (fresh data);
//   3 the SAME server data read by A's phone 3 h 5 min later (the screen's
//     clock is moved forward, like fake GPS for time) -> B's card turns GRAY
//     with a DASHED border, a plain-words reason and "How to fix"; the
//     status line no longer says All OK (zero false green);
//   4 the fix guide opens with the per-brand steps.
// Server-side expiry with a moving clock is proven in backend
// core/tests_fcscreen.py (test_e2e_stale_data_turns_gray).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/family_v3/family_v3_screen.dart';

import '../support/harness.dart';

void registerFamilyV3Flows() {
  realityFlow('13b_family_v3_stale', 'Family & safety',
      'Family v3: B joins by consent, shows green, then the same data turns gray (dashed + reason) when old',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    late int fid;
    late int bId;
    await f.step('A invites B from My Circle; B is not in until B taps Join', () async {
      final fams = await f.net(() => api.getJson('/family/v3/families'));
      fid = (((fams['families'] as List).first as Map)['id'] as num).toInt();
      final pick = await f.net(() => api.getJson('/family/circle-pick'));
      final rows = (pick['results'] as List).cast<Map>();
      final b = rows.firstWhere((r) => '${r['name']}' == Seed.nameB,
          orElse: () => throw TestFailure('seeded B not in A\'s My Circle: $rows'));
      await f.net(() => api.postJson('/family/v3/families/$fid/invite',
          {'circle_member_id': b['circle_id'], 'role': 'adult'}));
      final before = await f.net(() => api.getJson('/family/v3/families/$fid/board'));
      if ((before['members'] as List).any((m) => (m as Map)['me'] != true)) {
        throw TestFailure('B became a member WITHOUT consent');
      }
      final inv = await f.net(() => apiB.getJson('/family/v3/families'));
      final mine = (inv['invites'] as List).cast<Map>().where((x) => x['family_id'] == fid);
      if (mine.isEmpty) throw TestFailure('B has no invite: $inv');
      await f.net(() => apiB.postJson('/family/v3/invites/${mine.first['membership_id']}/accept'));
    });
    await f.step('B\'s phone reports -> A sees B green', () async {
      await f.net(() => apiB.postJson('/rt/send', {
            'topic': 'presence.set',
            'payload': {'state': 'online'}
          }));
      final board = await f.net(() => api.getJson('/family/v3/families/$fid/board'));
      final b = (board['members'] as List).cast<Map>().firstWhere((m) => m['me'] != true);
      bId = (b['user_id'] as num).toInt();
      f.note('server status of B: ${b['status']}');
      await f.openFeature(f.t.moduleFamily, 'family');
      f.expectHttp('GET', '/family/v3/families/$fid/board');
      await f.waitFor(find.byKey(ValueKey('fc3-member-$bId-ok')), what: 'B green card');
      await f.shot('b_green');
    });
    await f.step('same data, phone clock +3 h 5 min -> B gray dashed + reason', () async {
      await f.pushScreen(
          FamilyV3Screen(debugNow: DateTime.now().add(const Duration(hours: 3, minutes: 5))),
          settleSeconds: 4);
      await f.waitFor(find.byKey(ValueKey('fc3-member-$bId-stale')), what: 'B gray card');
      f.expectVisible(find.byKey(ValueKey('fc3-dashed-$bId')), 'dashed border');
      f.expectVisible(find.byKey(ValueKey('fc3-reason-$bId')), 'plain reason');
      if (find.byKey(const ValueKey('fc3-line-ok')).evaluate().isNotEmpty) {
        throw TestFailure('FALSE GREEN: status line still says All OK');
      }
      await f.shot('b_gray_dashed');
    });
    await f.step('How to fix -> per-brand guide', () async {
      await f.tap(find.byKey(ValueKey('fc3-fix-$bId')), settleSeconds: 2);
      await f.waitFor(find.byKey(const ValueKey('fc3-fix-guide')), what: 'fix guide');
      f.expectVisible(find.byKey(const ValueKey('fc3-brand-Xiaomi')), 'Xiaomi chip');
      await f.shot('fix_guide');
    });
  });
}
