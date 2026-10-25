import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../screens/money_common.dart';

/// Insight + savings-goal-link widgets for the BUDGET module (#50).
///
/// Insights arrive as structured {code, category, pct, over_by} rows from the
/// engine — the app localises the KEY so the message is strict bn/en and never
/// mixed. Nothing here computes numbers; it paints what budget.py returned.

/// A ranked list of plain-language insights ("Food is 20% over"). Empty list
/// renders nothing (the caller decides the empty state).
class BudgetInsights extends StatelessWidget {
  final List<Map<String, dynamic>> insights;
  const BudgetInsights({super.key, required this.insights});

  String _text(AppLocalizations t, Map<String, dynamic> i) {
    final cat = i['category']?.toString() ?? '';
    final pct = (i['pct'] as num?)?.toInt() ?? 0;
    switch (i['code']) {
      case 'over':
        return t.budgetInsightOver(cat, '$pct');
      case 'near':
        return t.budgetInsightNear(cat, '$pct');
      default:
        return t.budgetInsightOnTrack;
    }
  }

  IconData _icon(String? code) {
    switch (code) {
      case 'over':
        return Icons.trending_up_rounded;
      case 'near':
        return Icons.warning_amber_rounded;
      default:
        return Icons.check_circle_outline_rounded;
    }
  }

  Color _color(String? code) {
    switch (code) {
      case 'over':
        return Brand.danger;
      case 'near':
        return Brand.warning;
      default:
        return Brand.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.budgetInsightsTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: Gap.sm),
      for (final i in insights)
        Card(
          child: ListTile(
            dense: true,
            leading: Icon(_icon(i['code']?.toString()),
                color: _color(i['code']?.toString())),
            title: Text(_text(t, i)),
          ),
        ),
    ]);
  }
}

/// The savings-goal-link result card. Shows this-month underspend moving into
/// the goal + the resulting progress. Tapping [onLink] calls the server (which
/// floors an over-budget month to a zero contribution).
class BudgetGoalLinkCard extends StatelessWidget {
  final Map<String, dynamic>? result; // null until linked / previewed
  final bool hasGoal;
  final VoidCallback? onLink;
  const BudgetGoalLinkCard(
      {super.key, this.result, required this.hasGoal, this.onLink});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (!hasGoal) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.savings_rounded),
          title: Text(t.budgetGoalLinkTitle),
          subtitle: Text(t.budgetGoalLinkNone),
        ),
      );
    }
    final reached = result?['reached'] == true;
    final pct = ((result?['progress_pct'] as num?)?.toInt() ?? 0).clamp(0, 100);
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.savings_rounded, color: scheme.onSecondaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.budgetGoalLinkTitle,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.onSecondaryContainer)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
              reached
                  ? t.budgetGoalReached
                  : t.budgetGoalLinkBody(
                      tkFmt(result?['contribution'] ?? '0')),
              style: TextStyle(color: scheme.onSecondaryContainer)),
          if (result != null) ...[
            const SizedBox(height: Gap.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 8,
                backgroundColor: Colors.white30,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
                onPressed: onLink,
                child: Text(t.budgetGoalLinkTitle)),
          ),
        ]),
      ),
    );
  }
}
