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
import 'package:assisto/family_v3/fc_section_page.dart'; // gap-familycare
import 'package:assisto/screens/guardian_request_screen.dart'; // gap-familycare

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

  // gap-familycare: the gaps a real user saw (owner_actions/gaps/familycare_BN.md)
  //   a) an OPEN Family screen gets B's new task by itself (no pull)
  //   b) A deletes a wrong task (confirm first) -> gone on the server
  //   c) "Location" on B's card opens the ask form with B picked already
  //   d) B pauses sharing -> A's status line says "paused", not "no news"
  realityFlow('13c_family_v3_gaps', 'Family & safety',
      'Family v3 gaps: live refresh, delete a task, Location picks the person, paused line',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    late int fid;
    late int bId;
    late int bCircleId;
    await f.step('B is in A\'s family (by consent)', () async {
      final fams = await f.net(() => api.getJson('/family/v3/families'));
      fid = (((fams['families'] as List).first as Map)['id'] as num).toInt();
      final pick = await f.net(() => api.getJson('/family/circle-pick'));
      final b = (pick['results'] as List).cast<Map>().firstWhere((r) => '${r['name']}' == Seed.nameB,
          orElse: () => throw TestFailure('seeded B not in A\'s My Circle'));
      bCircleId = (b['circle_id'] as num).toInt();
      var board = await f.net(() => api.getJson('/family/v3/families/$fid/board'));
      if (!(board['members'] as List).any((m) => (m as Map)['me'] != true)) {
        await f.net(() => api.postJson('/family/v3/families/$fid/invite',
            {'circle_member_id': bCircleId, 'role': 'adult'}));
        final inv = await f.net(() => apiB.getJson('/family/v3/families'));
        final mine = (inv['invites'] as List).cast<Map>().where((x) => x['family_id'] == fid);
        await f.net(() => apiB.postJson('/family/v3/invites/${mine.first['membership_id']}/accept'));
        board = await f.net(() => api.getJson('/family/v3/families/$fid/board'));
      }
      bId = (((board['members'] as List).cast<Map>().firstWhere((m) => m['me'] != true))['user_id'] as num)
          .toInt();
      await f.net(() => apiB.postJson('/family/brain/pause', {'resume': true}));
      await f.net(() => apiB.postJson('/rt/send', {
            'topic': 'presence.set',
            'payload': {'state': 'online'}
          }));
    });
    late int taskId;
    final title = 'gap e2e rice ${DateTime.now().millisecondsSinceEpoch % 100000}';
    await f.step('A keeps Family open; B adds a task -> it appears with no pull', () async {
      FamilyV3Screen.pollEvery = const Duration(seconds: 4);
      await f.pushScreen(const FamilyV3Screen(), settleSeconds: 3);
      final r = await f.net(() => apiB.postJson('/family/v3/families/$fid/tasks',
          {'title': title, 'kind': 'other'}));
      taskId = (((r['task'] ?? r) as Map)['id'] as num).toInt();
      await f.waitFor(find.text(title), seconds: 25, what: 'B\'s task on A\'s open screen');
      await f.shot('live_task');
    });
    await f.step('A deletes the task (asks first) -> gone on the server', () async {
      await f.scrollTo(find.byKey(ValueKey('fcg-task-delete-$taskId')));
      await f.tap(find.byKey(ValueKey('fcg-task-delete-$taskId')));
      await f.waitFor(find.byKey(const ValueKey('fcg-task-delete-ok')), what: 'delete confirm');
      await f.shot('delete_confirm');
      await f.tap(find.byKey(const ValueKey('fcg-task-delete-ok')), settleSeconds: 3);
      await f.eventually('task deleted', () async {
        final b = await api.getJson('/family/v3/families/$fid/board');
        return !(b['tasks'] as List).any((x) => (x as Map)['id'] == taskId);
      });
    });
    await f.step('Location on B\'s card -> the ask form with B picked', () async {
      final card = find.byWidgetPredicate((w) =>
          w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('fc3-member-$bId-'));
      await f.scrollTo(card);
      await f.tap(find.descendant(of: card, matching: find.text(f.t.fc3Location)), settleSeconds: 4);
      await f.waitFor(find.byType(GuardianRequestScreen), seconds: 15, what: 'ask form');
      final chip = await f.waitFor(find.byKey(ValueKey('gj_person_$bCircleId')), what: 'B chip');
      if (f.tester.widget<ChoiceChip>(chip).selected != true) {
        throw TestFailure('B is not picked on the ask form');
      }
      await f.shot('location_preselected');
      await f.back();
      await f.back();
    });
    await f.step('B pauses sharing -> A\'s line says paused, not "no news"', () async {
      await f.net(() => apiB.postJson('/family/brain/pause', {'hours': 1}));
      await f.waitFor(find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.pause_circle_rounded) /* gap-nearby: the reality guard forbids the icon finder */, seconds: 25, what: 'paused line');
      await f.shot('paused_line');
      await f.net(() => apiB.postJson('/family/brain/pause', {'resume': true}));
      FamilyV3Screen.pollEvery = const Duration(minutes: 2);
    });
    await f.step('shared ledger: B\'s spend + goal show on A\'s phone; A adds money', () async {
      final note = 'gap e2e bazar $title';
      final board = await f.net(() => api.getJson('/family/v3/families/$fid/board'));
      final aId = ((board['me'] as Map)['user_id'] as num).toInt();
      await f.net(() => apiB.postJson('/family/accounting/expenses', {
            'family': fid, 'payer': 'self', 'total_poisha': 90001,
            'members': ['self', 'u$aId'], 'note': note,
          }));
      final g = await f.net(() => apiB.postJson('/family/accounting/goals',
          {'family': fid, 'name': 'Eid $title', 'target_poisha': 1000000}));
      final gid = (g['id'] as num).toInt();
      await f.pushScreen(FcSectionPage(section: FcSection.ledger, title: f.t.fc3MoreLedger,
          familyId: fid, familyMembers: [{'id': 'u$bId', 'name': Seed.nameB}]), settleSeconds: 4);
      await f.waitFor(find.text(note), seconds: 20, what: 'B\'s expense on A\'s ledger');
      await f.shot('ledger_shared');
      await f.tap(find.text(f.t.fcgGoalsTab), settleSeconds: 2);
      await f.waitFor(find.text('Eid $title'), what: 'B\'s goal');
      await f.tap(find.byKey(ValueKey('fcg-goal-add-$gid')));
      await f.tapText(f.t.medForSelf);
      await f.waitFor(find.byKey(const ValueKey('fa-amount-field')), what: 'amount field');
      await f.tester.enterText(find.byKey(const ValueKey('fa-amount-field')), '250');
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.tap(find.byKey(const ValueKey('fa-amount-save')), settleSeconds: 3);
      await f.eventually('A\'s 250 taka on the goal', () async {
        final s = await apiB.getJson('/family/accounting/goals?family=$fid');
        final mine = (s['goals'] as List).cast<Map>().firstWhere((x) => x['id'] == gid);
        return mine['collected_poisha'] == 25000;
      });
      await f.shot('goal_added');
    });
  });
}
