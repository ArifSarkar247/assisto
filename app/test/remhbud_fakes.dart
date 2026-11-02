// remhbud: fake answers for the plain Budget module's endpoints
// (/money/budget/month|history|plan|template) — shapes mirror
// backend/core/logic/budget.py. Used by fake_api.dart (gallery) and
// remhbud_test.dart. Categories are the family KEYS ('food', 'rent') plus one
// the user typed ('Transport' / Bangla), so a raw key leaking into the UI is
// visible in the screenshots and caught by the tests.

Map<String, dynamic>? fakeBudgetGet(String path, {bool bn = false, bool empty = false}) {
  if (!path.startsWith('/money/budget')) return null;
  final typed = bn ? 'যাতায়াত' : 'Transport';
  if (path.startsWith('/money/budget/month')) {
    final q = Uri.parse(path).queryParameters['month'] ?? '2026-10';
    if (empty) {
      return {
        'month': q, 'lines': [], 'insights': [],
        'totals': {'limit': '0', 'spent': '0', 'remaining': '0', 'carried_in': '0', 'pct': 0, 'unbudgeted_spent': '0'},
      };
    }
    return {
      'month': q,
      'lines': [
        {'category': 'food', 'limit': '12000.00', 'carried_in': '0.00', 'effective_limit': '12000.00',
          'spent': '13450.50', 'remaining': '-1450.50', 'pct': 112, 'bar_pct': 100, 'state': 'over',
          'over_by': '1450.50', 'rollover': false},
        {'category': typed, 'limit': '3000.00', 'carried_in': '0.00', 'effective_limit': '3000.00',
          'spent': '2550.00', 'remaining': '450.00', 'pct': 85, 'bar_pct': 85, 'state': 'near',
          'over_by': '0.00', 'rollover': false},
        {'category': 'rent', 'limit': '15000.00', 'carried_in': '500.00', 'effective_limit': '15500.00',
          'spent': '15000.00', 'remaining': '500.00', 'pct': 96, 'bar_pct': 96, 'state': 'near',
          'over_by': '0.00', 'rollover': true},
        {'category': 'education', 'limit': '5000.00', 'carried_in': '0.00', 'effective_limit': '5000.00',
          'spent': '1200.00', 'remaining': '3800.00', 'pct': 24, 'bar_pct': 24, 'state': 'ok',
          'over_by': '0.00', 'rollover': false},
      ],
      'totals': {'limit': '35000.00', 'spent': '32200.50', 'remaining': '2799.50', 'carried_in': '500.00',
        'pct': 91, 'unbudgeted_spent': '1800.00'},
      'insights': [
        {'code': 'over', 'category': 'food', 'pct': 12, 'over_by': '1450.50'},
        {'code': 'near', 'category': typed, 'pct': 85, 'over_by': '0.00'},
      ],
    };
  }
  if (path.startsWith('/money/budget/history')) {
    final cat = Uri.parse(path).queryParameters['category'] ?? 'food';
    return {
      'category': cat,
      'rollover': true,
      'carry_forward': '650.00',
      'months': [
        for (final m in ['2026-08', '2026-09', '2026-10'])
          {'month': m, 'limit': '12000.00', 'carried_in': '0.00', 'effective_limit': '12000.00',
            'spent': m == '2026-10' ? '11350.00' : '9800.00', 'remaining': '2200.00',
            'pct': m == '2026-10' ? 95 : 82, 'bar_pct': m == '2026-10' ? 95 : 82, 'state': 'near', 'over_by': '0.00'},
      ],
    };
  }
  if (path.startsWith('/money/budget/plan')) {
    if (empty) return {'months': [], 'suggestions': []};
    return {
      'months': ['2026-08', '2026-09', '2026-10'],
      'suggestions': [
        {'category': 'food', 'avg_spent': '11200.00', 'suggested_limit': '12320.00'},
        {'category': typed, 'avg_spent': '2600.00', 'suggested_limit': '2860.00'},
      ],
    };
  }
  if (path.startsWith('/money/budget/template')) {
    final inc = double.tryParse(Uri.parse(path).queryParameters['income'] ?? '') ?? 0;
    return {
      'income': inc.toStringAsFixed(2),
      'buckets': [
        {'bucket': 'needs', 'percent': 50, 'amount': (inc * .5).toStringAsFixed(2)},
        {'bucket': 'wants', 'percent': 30, 'amount': (inc * .3).toStringAsFixed(2)},
        {'bucket': 'savings', 'percent': 20, 'amount': (inc * .2).toStringAsFixed(2)},
      ],
    };
  }
  return null;
}
