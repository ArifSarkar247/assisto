// remhbud: gallery states for test/screenshots_test.dart (and so the a11y
// guideline + dead-button sweeps) — the plain Budget module with real-shaped
// data (remhbud_fakes.dart) and the empty Remittance month.
import 'package:flutter/material.dart';

import 'package:assisto/screens/money_budget_screen.dart';
import 'package:assisto/screens/remittance/remittance_screen.dart';

import 'budrem_fakes.dart';
import 'fake_api.dart' show FakeMode;

final _now = DateTime(2026, 10, 20);

final Map<String, ({Widget Function(String) build, FakeMode mode})> remhbudShots = {
  'rhb_budget_month': (build: (_) => MoneyBudgetScreen(now: _now), mode: FakeMode.data),
  'rhb_budget_empty': (build: (_) => MoneyBudgetScreen(now: _now), mode: FakeMode.empty),
  'rhb_budget_history': (build: (_) => MoneyBudgetScreen(now: _now, initialTab: 1), mode: FakeMode.data),
  'rhb_budget_plan': (build: (_) => MoneyBudgetScreen(now: _now, initialTab: 2), mode: FakeMode.data),
  'rhb_budget_drill': (build: (_) => MoneyBudgetScreen(category: 'food', now: _now), mode: FakeMode.data),
  'rhb_rmt_month_empty': (build: (_) => RemittanceScreen(source: FakeRemit('empty'), guide: false, now: _now),
      mode: FakeMode.data),
};
