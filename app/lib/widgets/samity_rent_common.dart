import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
// Reuse the proven money helpers from the ladder module so poisha math + Bangla
// digit/taka formatting can never drift between modules.
import 'ladder_common.dart' show taka, fmtInt, takaToPoisha, poishaOf;

export 'ladder_common.dart' show taka, fmtInt, takaToPoisha;

/// Shared pure logic + small UI helpers for the two Section-20 thin modules:
///   • Samity / committee (#184)  — mirrors backend/core/logic/samity.py
///   • Landlord–tenant rent (#185) — mirrors backend/core/logic/landlord_tenant.py
///
/// These mirrors let both screens render the SAME collected/pending/arrears math
/// OFFLINE, straight off the generic list-endpoint row shapes. Every number here
/// matches the Python engine (the backend self-tests pin the same cases).
///
/// HARD RULES (identical to the engines):
///   * NEVER HOLD MONEY — `kHoldsMoney` = false. These modules only TRACK.
///   * NO AUTO-CHARGE    — `kChargesMoney` = false. Nothing moves money.
/// All money is INTEGER POISHA (1 taka = 100 poisha); digits render Bangla via
/// the shared helpers (no Bangla literal in source). Every user-facing string
/// comes from AppLocalizations.

const bool kHoldsMoney = false;
const bool kChargesMoney = false;

// Generic owned-collection paths (see up_samityrent_integration.md). A samity
// screen keeps the samity header in one collection and its members/contributions
// /payouts in sibling collections scoped by `samity_id`.
const kColSamity = 'samity_groups';
const kColSamityMember = 'samity_members';
const kColSamityContribution = 'samity_contributions';
const kColSamityPayout = 'samity_payouts';
const kColRentUnit = 'rent_units';
const kColRentPayment = 'rent_payments';

const kPeriods = ['weekly', 'biweekly', 'monthly'];
const kRentMethods = ['cash', 'bkash', 'nagad', 'bank', 'other'];

// ---------------------------------------------------------------- SAMITY mirror

int samityPerMember(Map samity) =>
    poishaOf(samity, poishaKey: 'amount_poisha', takaKey: 'amount');

/// Active members in agreed payout order (explicit payout_order, then id, then
/// name) — deterministic, exactly like samity.active_members.
List<Map<String, dynamic>> samityActiveMembers(List members) {
  final ms = members
      .whereType<Map>()
      .where((m) => m['active'] != false)
      .map((m) => Map<String, dynamic>.from(m))
      .toList();
  ms.sort((a, b) {
    final ao = a['payout_order'] is int ? 0 : 1;
    final bo = b['payout_order'] is int ? 0 : 1;
    if (ao != bo) return ao - bo;
    final aov = a['payout_order'] is int ? a['payout_order'] as int : 0;
    final bov = b['payout_order'] is int ? b['payout_order'] as int : 0;
    if (aov != bov) return aov - bov;
    final aid = a['id'] is int ? a['id'] as int : 1 << 30;
    final bid = b['id'] is int ? b['id'] as int : 1 << 30;
    if (aid != bid) return aid - bid;
    return '${a['name'] ?? ''}'.compareTo('${b['name'] ?? ''}');
  });
  return ms;
}

/// Honest per-cycle collected/pending summary. Mirrors samity.cycle_status;
/// expected == collected + pending always holds.
Map<String, dynamic> samityCycleStatus(
    Map samity, List members, List contributions, int cycle) {
  final per = samityPerMember(samity);
  final active = samityActiveMembers(members);
  final byMember = <dynamic, Map>{};
  for (final c in contributions.whereType<Map>()) {
    if (c['cycle'] == cycle) byMember[c['member_id']] = c;
  }
  var collected = 0;
  var paidCount = 0;
  final rows = <Map<String, dynamic>>[];
  for (final m in active) {
    final c = byMember[m['id']] ?? const {};
    int paid;
    if (c['paid_poisha'] != null) {
      final v = int.tryParse('${c['paid_poisha']}') ?? 0;
      paid = v < 0 ? 0 : (v > per ? per : v);
    } else {
      paid = c['paid'] == true ? per : 0;
    }
    final fully = paid >= per && per > 0;
    if (fully) paidCount++;
    collected += paid;
    rows.add({
      'member_id': m['id'],
      'name': m['name'],
      'paid': fully,
      'paid_poisha': paid,
      'due_poisha': (per - paid) < 0 ? 0 : (per - paid),
    });
  }
  final expected = per * active.length;
  return {
    'cycle': cycle,
    'per_member_poisha': per,
    'member_count': active.length,
    'expected_poisha': expected,
    'collected_poisha': collected,
    'pending_poisha': (expected - collected) < 0 ? 0 : expected - collected,
    'paid_count': paidCount,
    'pending_count': active.length - paidCount,
    'members': rows,
  };
}

/// The member scheduled to receive the pot in `cycle` (1-based), or null.
Map<String, dynamic>? samityRecipientForCycle(List members, int cycle) {
  final active = samityActiveMembers(members);
  if (cycle < 1 || cycle > active.length) return null;
  return active[cycle - 1];
}

/// Next member due to receive, skipping anyone with a recorded hand-over; null
/// when the whole round is paid out. Mirrors samity.next_turn.
Map<String, dynamic>? samityNextTurn(List members, List payouts) {
  final done = <dynamic>{};
  for (final p in payouts.whereType<Map>()) {
    if (p['handed_over'] == true) done.add(p['member_id']);
  }
  for (final m in samityActiveMembers(members)) {
    if (!done.contains(m['id'])) return m;
  }
  return null;
}

bool samityPayoutDone(List payouts, int cycle) {
  for (final p in payouts.whereType<Map>()) {
    if (p['cycle'] == cycle && p['handed_over'] == true) return true;
  }
  return false;
}

// ------------------------------------------------------------ LANDLORD mirror

/// One utility line → this tenant's share in integer poisha. Mirrors
/// landlord_tenant.utility_amount (fixed amount OR floor(total*num/den)).
int rentUtilityAmount(Map util) {
  if (util.containsKey('share_of_poisha') || util.containsKey('share_of')) {
    final total = poishaOf(util, poishaKey: 'share_of_poisha', takaKey: 'share_of');
    final num = int.tryParse('${util['share_num'] ?? 1}') ?? 1;
    final den = int.tryParse('${util['share_den'] ?? 1}') ?? 1;
    if (den <= 0 || num <= 0) return 0;
    return (total * num) ~/ den;
  }
  return poishaOf(util, poishaKey: 'amount_poisha', takaKey: 'amount');
}

/// Itemised monthly bill = base rent + utility shares. Mirrors monthly_bill.
Map<String, dynamic> rentMonthlyBill(Map unit) {
  final rent = poishaOf(unit, poishaKey: 'rent_poisha', takaKey: 'rent');
  final utils = (unit['utilities'] as List? ?? const []).whereType<Map>();
  final breakdown = <Map<String, dynamic>>[];
  var utilTotal = 0;
  for (final u in utils) {
    final a = rentUtilityAmount(u);
    utilTotal += a;
    breakdown.add({'name': u['name'] ?? '', 'amount_poisha': a});
  }
  return {
    'rent_poisha': rent,
    'utilities_poisha': utilTotal,
    'bill_poisha': rent + utilTotal,
    'breakdown': breakdown,
  };
}

List<Map<String, dynamic>> rentActiveUnits(List units) {
  final us = units
      .whereType<Map>()
      .where((u) => u['active'] != false)
      .map((u) => Map<String, dynamic>.from(u))
      .toList();
  us.sort((a, b) {
    final c = '${a['label'] ?? ''}'.compareTo('${b['label'] ?? ''}');
    if (c != 0) return c;
    final aid = a['id'] is int ? a['id'] as int : 1 << 30;
    final bid = b['id'] is int ? b['id'] as int : 1 << 30;
    return aid - bid;
  });
  return us;
}

int _rentPaidFor(List payments, dynamic unitId, String month) {
  var total = 0;
  for (final p in payments.whereType<Map>()) {
    if (p['unit_id'] == unitId && p['month'] == month) {
      total += poishaOf(p, poishaKey: 'paid_poisha', takaKey: 'paid');
    }
  }
  return total;
}

/// Honest per-unit per-month status. Mirrors landlord_tenant.unit_month;
/// bill == paid + outstanding (credit reported separately, never applied).
Map<String, dynamic> rentUnitMonth(Map unit, List payments, String month) {
  final b = rentMonthlyBill(unit);
  final bill = b['bill_poisha'] as int;
  final paid = _rentPaidFor(payments, unit['id'], month);
  final outstanding = (bill - paid) < 0 ? 0 : bill - paid;
  final credit = (paid - bill) < 0 ? 0 : paid - bill;
  final String status;
  if (bill <= 0 || paid >= bill) {
    status = 'paid';
  } else if (paid > 0) {
    status = 'partial';
  } else {
    status = 'due';
  }
  return {
    'unit_id': unit['id'],
    'label': unit['label'],
    'tenant_name': unit['tenant_name'],
    'month': month,
    'bill_poisha': bill,
    'rent_poisha': b['rent_poisha'],
    'utilities_poisha': b['utilities_poisha'],
    'breakdown': b['breakdown'],
    'paid_poisha': paid,
    'outstanding_poisha': outstanding,
    'credit_poisha': credit,
    'status': status,
  };
}

/// Whole-portfolio month summary. Mirrors landlord_tenant.month_summary.
Map<String, dynamic> rentMonthSummary(List units, List payments, String month) {
  final rows = rentActiveUnits(units)
      .map((u) => rentUnitMonth(u, payments, month))
      .toList();
  var billed = 0, collected = 0, outstanding = 0, credit = 0;
  var paidC = 0, partialC = 0, dueC = 0;
  for (final r in rows) {
    final bill = r['bill_poisha'] as int;
    final paid = r['paid_poisha'] as int;
    billed += bill;
    collected += paid < bill ? paid : bill;
    outstanding += r['outstanding_poisha'] as int;
    credit += r['credit_poisha'] as int;
    switch (r['status']) {
      case 'paid':
        paidC++;
        break;
      case 'partial':
        partialC++;
        break;
      default:
        dueC++;
    }
  }
  return {
    'month': month,
    'unit_count': rows.length,
    'billed_poisha': billed,
    'collected_poisha': collected,
    'outstanding_poisha': outstanding,
    'credit_poisha': credit,
    'paid_count': paidC,
    'partial_count': partialC,
    'due_count': dueC,
    'units': rows,
  };
}

// --------------------------------------------------------------- month helpers

/// Current ISO year-month ('YYYY-MM') from a DateTime, ASCII digits.
String isoMonth(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

/// Shift an ISO 'YYYY-MM' by `delta` months (can be negative). Pure arithmetic.
String shiftMonth(String month, int delta) {
  final parts = month.split('-');
  var y = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
  var m = (int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1) + delta;
  while (m > 12) {
    m -= 12;
    y += 1;
  }
  while (m < 1) {
    m += 12;
    y -= 1;
  }
  return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}';
}

/// Localised month label, e.g. "2026-02" → "February 2026" / Bangla month.
String monthLabel(BuildContext context, String iso) {
  final t = AppLocalizations.of(context);
  final parts = iso.split('-');
  final y = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
  final m = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
  final names = [
    t.monthJan, t.monthFeb, t.monthMar, t.monthApr, t.monthMay, t.monthJun,
    t.monthJul, t.monthAug, t.monthSep, t.monthOct, t.monthNov, t.monthDec,
  ];
  final name = (m >= 1 && m <= 12) ? names[m - 1] : '';
  // a year is not a quantity: no thousands separator ("2,026" was shown).
  // fmtInt still localises the digits; strip its grouping comma.
  return '$name ${fmtInt(context, y).replaceAll(',', '')}';
}

// ---------------------------------------------------------------- shared UI

/// The structural "we never hold money" banner both modules show.
class NoMoneyBanner extends StatelessWidget {
  final String text;
  const NoMoneyBanner({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(Icons.verified_user_outlined, size: 20, color: scheme.secondary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
        ),
      ]),
    );
  }
}

/// A single-line labelled money/stat row used in hero + detail cards.
class StatLine extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool strong;
  const StatLine(this.label, this.value,
      {super.key, this.valueColor, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(width: Gap.sm),
        Text(value,
            style: TextStyle(
                color: valueColor ?? scheme.onSurface,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w600)),
      ]),
    );
  }
}

/// A coloured status pill (paid / partial / due) reused across both screens.
class StatusPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  const StatusPill(
      {super.key, required this.text, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        ),
      ]),
    );
  }
}

Color statusColor(String status) {
  switch (status) {
    case 'paid':
      return Brand.success;
    case 'partial':
      return Brand.warning;
    default:
      return Brand.danger;
  }
}
