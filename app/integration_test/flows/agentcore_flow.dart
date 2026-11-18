// agentcore (18 Nov 2026): the Agent Core proactive proof, opt-in group
// 'agentcore' (reality.yml only=agentcore). Its seed (seed_reality, drive
// contains "agentcore") allow-lists demo user A for agent_core, gives A two
// made-up loans due TOMORROW and runs ONE proactive pass: each loan becomes a
// card with a proposed reminder that waits for A's tap. No AI call is made
// (template only; the CI AI is the repo's fake and is never reached).
//   41 trigger (loan due tomorrow) -> agent card -> Approve -> reminder exists
//      -> audit trail shows it; second card -> Not now -> nothing created,
//      audit says rejected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/agent_core/agent_core_screen.dart';

import '../support/harness.dart';

const _approveName = 'Karim Bhai (demo)';
const _rejectName = 'Sumon (demo)';

void registerAgentCoreFlows() {
  realityFlow('41_agent_proactive', 'Work',
      'Agent Core: bill due tomorrow -> card -> approve -> reminder -> audit; reject path',
      (f) async {
    await f.home();
    late int approveId, rejectId;
    await f.step('server made two cards, nothing done yet', () async {
      final j = await f.net(() => f.app.api.getJson('/agent-core/nudges'));
      final rows = (j['results'] as List).cast<Map>();
      int idFor(String who) {
        final r = rows.firstWhere((x) => '${x['title']}'.contains(who),
            orElse: () => throw TestFailure('no card for $who: ${rows.map((x) => x['title'])}'));
        final a = r['action'] as Map?;
        if (a == null || a['status'] != 'pending') throw TestFailure('no pending action for $who');
        if (r['verified'] != true) throw TestFailure('card numbers not verified for $who');
        return a['approval_id'] as int;
      }
      approveId = idFor(_approveName);
      rejectId = idFor(_rejectName);
      final rem = await f.net(() => f.app.api.listItems('/reminders'));
      if ('$rem'.contains(_approveName) || '$rem'.contains(_rejectName)) {
        throw TestFailure('a reminder existed before any tap');
      }
    });
    await f.step('open the agent -> "For you" cards', () async {
      try {
        await f.openFeature(f.t.acTitle, 'agent_core');
      } catch (e) {
        f.note('open failed ($e); pushed AgentCoreScreen');
        await f.backToHome();
        await f.pushScreen(const AgentCoreScreen());
      }
      await f.waitFor(find.byKey(ValueKey('ac_nudge_approve_$approveId')), what: 'approve button');
      await f.shot('cards');
      f.expectHttp('GET', '/agent-core/nudges');
    });
    await f.step('Approve -> the reminder is created', () async {
      await f.tap(find.byKey(ValueKey('ac_nudge_approve_$approveId')), settleSeconds: 3);
      await f.waitFor(find.byKey(ValueKey('ac_nudge_result_$approveId')), what: 'done line');
      f.expectHttp('POST', '/agent-core/approvals/$approveId');
      final rem = await f.net(() => f.app.api.listItems('/reminders'));
      if (!'$rem'.contains('Repay loan: $_approveName')) {
        throw TestFailure('reminder not found after approve');
      }
      await f.shot('approved');
    });
    await f.step('Not now -> nothing is created', () async {
      final b = find.byKey(ValueKey('ac_nudge_reject_$rejectId'));
      await f.scrollTo(b);
      await f.tap(b, settleSeconds: 3);
      await f.waitFor(find.byKey(ValueKey('ac_nudge_result_$rejectId')), what: 'rejected line');
      final rem = await f.net(() => f.app.api.listItems('/reminders'));
      if ('$rem'.contains(_rejectName)) throw TestFailure('a reminder was created on reject');
      await f.shot('rejected');
    });
    await f.step('audit trail: approved + done + rejected', () async {
      await f.tap(find.byKey(const ValueKey('ac_open_activity')), settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('ac_activity_list')), what: 'activity list');
      f.expectHttp('GET', '/agent-core/activity');
      final j = await f.net(() => f.app.api.getJson('/agent-core/activity'));
      final ev = (j['events'] as List).map((e) => '${(e as Map)['event']}').toList();
      for (final want in ['approval.approved', 'tool.done', 'approval.rejected', 'approval.requested']) {
        if (!ev.contains(want)) throw TestFailure('audit missing $want: $ev');
      }
      await f.shot('activity');
    });
  }, timeout: const Duration(minutes: 5));
}
