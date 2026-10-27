// agent-core WP-APP: gallery states for test/screenshots_test.dart (and so
// the a11y guideline sweep) — the hidden agent screen, approval inbox,
// history. Fake server only (agent_core_fakes.dart).
import 'package:flutter/material.dart';

import 'package:assisto/screens/agent_core/agent_approvals_screen.dart';
import 'package:assisto/screens/agent_core/agent_core_screen.dart';
import 'package:assisto/screens/agent_core/agent_core_source.dart';
import 'package:assisto/screens/agent_core/agent_history_screen.dart';

import 'agent_core_fakes.dart';

const _noPoll = <Duration>[];

AcRun _run(String l, String state, {String error = '', String text = '', bool ap = false}) =>
    AcRun.fromJson(acRunJson(state,
        bn: l == 'bn',
        error: error,
        errorText: text,
        credits: error.isEmpty ? 7 : 0,
        approvals: ap ? [acApprovalJson(bn: l == 'bn')] : null));

final Map<String, Widget Function(String)> agentCoreShots = {
  'ac_compose': (l) => AgentCoreScreen(source: FakeAgentCore('data', bn: l == 'bn')),
  'ac_estimate': (l) => AgentCoreScreen(
      source: FakeAgentCore('approval', bn: l == 'bn'),
      debugPhase: AcPhase.confirm,
      debugGoal: l == 'bn' ? 'এই মাসে কোথায় বেশি খরচ হলো?' : 'Where did I spend the most this month?'),
  'ac_sending': (l) => AgentCoreScreen(
      source: HangingAgentCore(),
      debugPhase: AcPhase.sending,
      debugGoal: l == 'bn' ? 'এই মাসে কোথায় বেশি খরচ হলো?' : 'Where did I spend the most this month?'),
  'ac_offline': (l) => AgentCoreScreen(
      source: FakeAgentCore('data', bn: l == 'bn'),
      debugPhase: AcPhase.offline,
      debugGoal: l == 'bn' ? 'এই মাসে কোথায় বেশি খরচ হলো?' : 'Where did I spend the most this month?'),
  'ac_run_done': (l) => AgentCoreScreen(
      source: FakeAgentCore('data', bn: l == 'bn'),
      debugPhase: AcPhase.run,
      debugRun: _run(l, 'done'),
      pollSchedule: _noPoll),
  'ac_run_running': (l) => AgentCoreScreen(
      source: FakeAgentCore('data', bn: l == 'bn'),
      debugPhase: AcPhase.run,
      debugRun: _run(l, 'running'),
      pollSchedule: _noPoll),
  'ac_run_approval': (l) => AgentCoreScreen(
      source: FakeAgentCore('approval', bn: l == 'bn'),
      debugPhase: AcPhase.run,
      debugRun: _run(l, 'waiting_approval', ap: true),
      pollSchedule: _noPoll),
  'ac_run_no_ai': (l) => AgentCoreScreen(
      source: FakeAgentCore('data', bn: l == 'bn'),
      debugPhase: AcPhase.run,
      debugRun: _run(l, 'failed',
          error: 'ai_no_key',
          text: l == 'bn' ? 'এজেন্ট এখনো চালু হয়নি।' : 'The agent is not switched on yet.'),
      pollSchedule: _noPoll),
  'ac_run_no_credits': (l) => AgentCoreScreen(
      source: FakeAgentCore('data', bn: l == 'bn'),
      debugPhase: AcPhase.run,
      debugRun: _run(l, 'failed',
          error: 'credits',
          text: l == 'bn'
              ? 'ক্রেডিট শেষ — ক্রেডিট নিয়ে আবার চেষ্টা করুন।'
              : 'Out of credits — top up and try again.'),
      pollSchedule: _noPoll),
  'ac_feature_off': (l) => AgentCoreScreen(source: FakeAgentCore('off', bn: l == 'bn')),
  'ac_approvals': (l) => AgentApprovalsScreen(source: FakeAgentCore('approval', bn: l == 'bn')),
  'ac_approvals_from_notif': (l) => AgentApprovalsScreen(
      source: FakeAgentCore('approval', bn: l == 'bn'), focusId: 12, fromApproveAction: true),
  'ac_approvals_empty': (l) => AgentApprovalsScreen(source: FakeAgentCore('empty', bn: l == 'bn')),
  'ac_history': (l) => AgentHistoryScreen(source: FakeAgentCore('data', bn: l == 'bn')),
};
