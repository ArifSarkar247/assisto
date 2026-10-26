// retention1: gallery states for test/screenshots_test.dart (and therefore the
// a11y guideline sweep + dead-button sweep) — Retention automation.
import 'package:flutter/material.dart';

import 'package:assisto/screens/retention/retention_inbox.dart';
import 'package:assisto/screens/retention/retention_people.dart';
import 'package:assisto/screens/retention/retention_results.dart';
import 'package:assisto/screens/retention/retention_screen.dart';
import 'package:assisto/screens/retention/retention_wizard.dart';

import 'retention1_fakes.dart';

Map<String, dynamic> _ov(String mode) => {
      'plan_ok': true,
      'shop': 'Rina Store',
      'channels_ready': ['in_app', 'whatsapp'],
      'kinds': FakeRetention.kinds,
      'max_automations': 10,
      'caps': {'per_customer_day': 1, 'per_customer_week': 2, 'business_daily': 100},
      'server_max': {'per_customer_day': 1, 'per_customer_week': 2, 'business_daily': 100},
    };

final Map<String, Widget Function(String)> retention1Shots = {
  'rt_first_run': (_) => RetentionScreen(source: FakeRetention('empty')),
  'rt_list': (_) => RetentionScreen(source: FakeRetention('data'), guide: false),
  'rt_list_guide': (_) => RetentionScreen(source: FakeRetention('data'), guide: true),
  'rt_plan_needed': (_) => RetentionScreen(source: FakeRetention('plan'), guide: false),
  'rt_feature_off': (_) => RetentionScreen(source: FakeRetention('off'), guide: false),
  'rt_load_error': (_) => RetentionScreen(source: FakeRetention('fail'), guide: false),
  'rt_wizard_what': (_) => RetentionWizardScreen(source: FakeRetention(), overview: _ov('data')),
  'rt_wizard_who': (_) =>
      RetentionWizardScreen(source: FakeRetention(), overview: _ov('data'), initialStep: 1),
  'rt_wizard_message': (_) =>
      RetentionWizardScreen(source: FakeRetention(), overview: _ov('data'), initialStep: 2),
  'rt_wizard_how': (_) => RetentionWizardScreen(
      source: FakeRetention(),
      overview: _ov('data'),
      initial: FakeRetention.automation(channel: 'whatsapp'),
      initialStep: 3),
  'rt_results': (_) => RetentionResultsScreen(source: FakeRetention(), automationId: 1),
  'rt_results_empty': (_) => RetentionResultsScreen(source: FakeRetention('empty'), automationId: 1),
  'rt_birthdays': (_) => RetentionBirthdaysScreen(source: FakeRetention()),
  'rt_stock_asks': (_) => RetentionStockAsksScreen(source: FakeRetention()),
  'rt_limits_sheet': (_) =>
      Scaffold(body: RetentionLimitsSheet(source: FakeRetention(), overview: _ov('data'))),
  'rt_inbox': (_) => RetentionInboxScreen(source: FakeRetention()),
  'rt_inbox_empty': (_) => RetentionInboxScreen(source: FakeRetention('inbox_empty')),
};
