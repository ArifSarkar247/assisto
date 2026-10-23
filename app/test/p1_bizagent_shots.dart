// p1-bizagent: gallery states for test/screenshots_test.dart (bn/en × light/dark
// come from the harness). FakeApi serves /bizagent/* via p1_bizagent_fakes.dart.
import 'package:flutter/material.dart';

import 'package:assisto/screens/business/bizagent/approvals_screen.dart';
import 'package:assisto/screens/business/bizagent/seller_agent_screen.dart';
import 'package:assisto/screens/business/bizagent/seller_inbox_screen.dart';
import 'package:assisto/screens/business/bizagent/seller_setup_screen.dart';

import 'p1_bizagent_fakes.dart';

class _FirstRun extends StatelessWidget {
  final Widget child;
  const _FirstRun(this.child);
  @override
  Widget build(BuildContext context) {
    p1Connected = false;
    return child;
  }
}

class _Connected extends StatelessWidget {
  final Widget child;
  const _Connected(this.child);
  @override
  Widget build(BuildContext context) {
    p1Connected = true;
    return child;
  }
}

final Map<String, Widget Function(String)> p1Shots = {
  'p1_agent_home': (_) => const _Connected(SellerAgentScreen()),
  'p1_agent_first_run': (_) => const _FirstRun(SellerAgentScreen()),
  'p1_agent_setup': (_) => const _Connected(SellerSetupScreen()),
  'p1_agent_approvals': (_) => const _Connected(ApprovalsScreen()),
  'p1_agent_inbox': (_) => const _Connected(SellerInboxScreen()),
  'p1_agent_chat': (_) => const _Connected(SellerChatScreen(threadId: 5)),
};
