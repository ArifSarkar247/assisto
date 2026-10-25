import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../screens/money_common.dart';

/// Visual pieces for the BUDGET module (#50): the per-category progress card,
/// the colour/label mapping for a budget state, and the total header. Every
/// amount is pre-formatted Taka from the server — this layer only paints.

/// state ∈ ok|near|over|none -> bar colour.
Color budgetStateColor(String? state) {
  switch (state) {
    case 'over':
      return Brand.danger;
    case 'near':
      return Brand.warning;
    case 'none':
      return Brand.blue;
    default:
      return Brand.success;
  }
}

/// state -> localised short label.
String budgetStateLabel(AppLocalizations t, String? state) {
  switch (state) {
    case 'over':
      return t.budgetStateOver;
    case 'near':
      return t.budgetStateNear;
    case 'none':
      return t.budgetStateNone;
    default:
      return t.budgetStateOk;
  }
}

/// One budget line as a tappable card: category, spent/limit, a state-coloured
/// progress bar (clamped via bar_pct so an over-budget bar fills to 100% and
/// turns red), and an honest over/near alert row with the exact over-by amount.
class BudgetCard extends StatelessWidget {
  final Map<String, dynamic> line;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const BudgetCard({super.key, required this.line, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = line['state']?.toString() ?? 'ok';
    final color = budgetStateColor(state);
    final barPct = ((line['bar_pct'] as num?)?.toInt() ??
            (line['pct'] as num?)?.toInt() ??
            0)
        .clamp(0, 100);
    final pct = (line['pct'] as num?)?.toInt() ?? 0;
    final rollover = line['rollover'] == true;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(line['category']?.toString() ?? '',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (rollover)
                Padding(
                  padding: const EdgeInsets.only(left: Gap.xs),
                  child: Icon(Icons.autorenew_rounded, size: 14, color: scheme.secondary),
                ),
              const SizedBox(width: Gap.sm),
              Text('$pct%',
                  style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ]),
            const SizedBox(height: Gap.xs),
            Text(
                t.budgetSpentOf(
                    tkFmt(line['spent']), tkFmt(line['effective_limit'])),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: LinearProgressIndicator(
                value: barPct / 100,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
                color: color,
              ),
            ),
            if (state == 'over')
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Row(children: [
                  const Icon(Icons.error_outline_rounded, size: 14, color: Brand.danger),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(t.budgetOverBy(tkFmt(line['over_by'])),
                        style: const TextStyle(
                            color: Brand.danger,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ]),
              )
            else if (state == 'near')
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(t.budgetStateNear,
                    style: const TextStyle(
                        color: Brand.warning, fontSize: 12)),
              )
            else if (state == 'none')
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(t.budgetAiMarker,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 11)),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(
                    '${t.budgetRemaining}: ${tkFmt(line['remaining'])}',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The gradient total header: whole-budget spent vs limit for the month, plus
/// an honest "un-budgeted spending" note when real spend exists outside any
/// budgeted category.
class BudgetTotalHeader extends StatelessWidget {
  final Map<String, dynamic> totals;
  const BudgetTotalHeader({super.key, required this.totals});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final pct = ((totals['pct'] as num?)?.toInt() ?? 0).clamp(0, 100);
    final unbudgeted = dbl(totals['unbudgeted_spent']);
    return Container(
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.budgetTotalHeader,
            style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: Gap.xs),
        Text(t.budgetSpentOf(tkFmt(totals['spent']), tkFmt(totals['limit'])),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.sm),
          child: LinearProgressIndicator(
            value: pct / 100,
            minHeight: 8,
            backgroundColor: Colors.white24,
            color: Colors.white,
          ),
        ),
        if (unbudgeted > 0) ...[
          const SizedBox(height: Gap.md),
          Row(children: [
            const Icon(Icons.info_outline_rounded, size: 14, color: Colors.white70),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(
                  t.budgetUnbudgetedHint(tkFmt(totals['unbudgeted_spent'])),
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ]),
        ],
      ]),
    );
  }
}
