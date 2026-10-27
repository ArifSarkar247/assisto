// perf2gb: the lazy reminders list keeps the old order (header, cards, gap
// per non-empty group) — only the rows on screen are built now.
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/reminders_screen.dart';

void main() {
  test('groups flatten to header/cards/gap, empty groups skipped', () {
    final Map<String, dynamic> a = {'id': 1}, b = {'id': 2}, c = {'id': 3};
    final groups = <(String, List<Map<String, dynamic>>)>[
      ('overdue', [a]),
      ('today', <Map<String, dynamic>>[]),
      ('upcoming', [b, c]),
    ];
    final rows = remRows(groups, (g) => g.$2);
    expect(rows.map((r) => r.kind).toList(), [
      RemRowKind.header, RemRowKind.card, RemRowKind.gap,
      RemRowKind.header, RemRowKind.card, RemRowKind.card, RemRowKind.gap,
    ]);
    expect(rows[1].item, same(a));
    expect(rows[4].item, same(b));
    expect(rows[5].item, same(c));
    expect(rows[3].group.$1, 'upcoming');
  });

  test('500 reminders = 500 cards + 2 rows per group', () {
    final items = <Map<String, dynamic>>[for (var i = 0; i < 500; i++) {'id': i}];
    final rows = remRows(<(String, List<Map<String, dynamic>>)>[('upcoming', items)], (g) => g.$2);
    expect(rows.length, 502);
  });
}
