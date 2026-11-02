/// moneybar: house-rent due-day reminder (local notification, no server).
///
/// A unit may carry `due_day` (1–28). The reminder fires at 09:00 on the next
/// due day; this month is skipped when the unit's rent for this month is
/// already recorded as paid in full (sum of rent_payments for that month ≥
/// rent). Re-armed on every load of the rent screen with a stable id
/// ("rent-<unit id>"), so it never doubles and follows edits. Pure function —
/// unit-tested in test/moneybar_test.dart.
library;

int? rentDueDay(Map<String, dynamic> unit) {
  final v = unit['due_day'];
  final d = v is int ? v : int.tryParse('${v ?? ''}');
  if (d == null || d < 1 || d > 28) return null;
  return d;
}

String _ym(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

int _paidFor(List<Map<String, dynamic>> payments, Object? unitId, String month) {
  var sum = 0;
  for (final p in payments) {
    if ('${p['unit_id']}' != '$unitId' || '${p['month']}' != month) continue;
    final v = p['paid_poisha'];
    sum += v is int ? v : (int.tryParse('${v ?? 0}') ?? 0);
  }
  return sum;
}

/// Next reminder moment (local time) or null (no due day / inactive unit).
DateTime? rentNextReminder(Map<String, dynamic> unit,
    List<Map<String, dynamic>> payments, DateTime now) {
  final day = rentDueDay(unit);
  if (day == null || unit['active'] == false) return null;
  final rentV = unit['rent_poisha'];
  final rent = rentV is int ? rentV : (int.tryParse('${rentV ?? 0}') ?? 0);
  final thisMonth = DateTime(now.year, now.month, day, 9);
  final paidThisMonth = rent > 0 && _paidFor(payments, unit['id'], _ym(now)) >= rent;
  if (thisMonth.isAfter(now) && !paidThisMonth) return thisMonth;
  return DateTime(now.year, now.month + 1, day, 9);
}
