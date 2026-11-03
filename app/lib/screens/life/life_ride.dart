import 'package:flutter/material.dart';

import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/local_digits.dart';
import '../journey_start_screen.dart';
import '../travel_planner_screen.dart' show tvNiceDate;
import 'life_common.dart';
import 'life_logic.dart';

/// p3life — Ride & food additions (owner PART 3, 3 Nov):
///   * [RideShareMyRideCard]  any ride (Pathao, Uber, CNG, bus) → our own
///                            Safe Journey live location to My Circle. Safety
///                            is never paywalled; hidden only if Safe Journey
///                            itself is switched off (never a dead button).
///   * [RideCompareNote]      how to compare honestly (we show no fares)
///   * [FoodLogCard] / [FoodLogScreen]  the user's own food-order diary +
///                            monthly budget (nothing imported or scraped).

class RideShareMyRideCard extends StatelessWidget {
  const RideShareMyRideCard({super.key});
  @override
  Widget build(BuildContext context) {
    if (!FeatureFlags.instance.isOn('safe_journey')) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Card(
      color: s.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.shield_rounded, color: s.onSecondaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.p3lShareRideTitle,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: s.onSecondaryContainer)),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.p3lShareRideBody, style: TextStyle(color: s.onSecondaryContainer)),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            key: const ValueKey('ride-share-my-ride'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.share_location_rounded),
            label: Text(t.p3lShareRideButton),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const JourneyStartScreen())),
          ),
        ]),
      ),
    );
  }
}

class RideCompareNote extends StatelessWidget {
  const RideCompareNote({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      child: ExpansionTile(
        key: const ValueKey('ride-compare'),
        leading: const Icon(Icons.compare_arrows_rounded),
        title: Text(t.p3lCompareTitle),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.md),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(t.p3lCompareBody)],
      ),
    );
  }
}

class FoodLogCard extends StatelessWidget {
  const FoodLogCard({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      child: ListTile(
        key: const ValueKey('ride-food-log'),
        minTileHeight: 56,
        leading: const Icon(Icons.receipt_long_rounded),
        title: Text(t.p3lFoodTitle),
        subtitle: Text(t.p3lFoodCardBody),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const FoodLogScreen())),
      ),
    );
  }
}

const List<String> kFoodProviders = ['foodpanda', 'pathao_food', 'restaurant', 'other'];

String foodProviderLabel(AppLocalizations t, String k) => switch (k) {
      'foodpanda' => 'foodpanda',
      'pathao_food' => 'Pathao Food',
      'restaurant' => t.p3lFoodRestaurant,
      _ => t.p3lFoodOther,
    };

const String _kBudget = 'food_budget_poisha_v1';

class FoodLogScreen extends StatefulWidget {
  const FoodLogScreen({super.key});
  @override
  State<FoodLogScreen> createState() => _FoodLogScreenState();
}

class _FoodLogScreenState extends State<FoodLogScreen> {
  int? _budget;

  @override
  void initState() {
    super.initState();
    Settings.getString(_kBudget).then((v) {
      if (mounted) setState(() => _budget = int.tryParse(v ?? ''));
    });
  }

  Future<void> _setBudget() async {
    final t = AppLocalizations.of(context);
    final r = await showLifeForm(context,
        title: t.p3lFoodBudgetSet,
        fields: [LifeField('budget', t.p3lFoodBudget, kind: LifeFieldKind.money, maxLength: 12)],
        existing: _budget == null ? null : {'budget': _budget});
    if (r == null) return;
    final p = poishaOf(r['budget']);
    await Settings.setString(_kBudget, p > 0 ? '$p' : '');
    if (mounted) setState(() => _budget = p > 0 ? p : null);
  }

  Widget _summary(BuildContext context, List<Map<String, dynamic>> rows) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final m = foodMonth(rows, monthKey(DateTime.now()), _budget);
    final over = m.left != null && m.left! < 0;
    return Card(
      color: (over ? s.errorContainer : s.primaryContainer).withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.p3lFoodThisMonth, style: TextStyle(color: s.onSurfaceVariant)),
          Text(ld(context, fmtTaka(m.spent)), style: Theme.of(context).textTheme.headlineSmall),
          Text(ld(context, t.p3lFoodOrders(m.orders))),
          const SizedBox(height: Gap.xs),
          if (m.left == null)
            Text(t.p3lFoodNoBudget)
          else if (over)
            Text(ld(context, t.p3lFoodOver(fmtTaka(-m.left!))),
                style: TextStyle(color: s.error, fontWeight: FontWeight.w700))
          else
            Text(ld(context, t.p3lFoodLeft(fmtTaka(m.left!), fmtTaka(_budget!)))),
          for (final e in m.byProvider)
            Text(ld(context, '${foodProviderLabel(t, e.key)}: ${fmtTaka(e.value)}'),
                style: TextStyle(color: s.onSurfaceVariant)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('food-budget'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.savings_rounded),
              label: Text(_budget == null ? t.p3lFoodBudgetSet : t.p3lFoodBudgetChange),
              onPressed: _setBudget,
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.p3lFoodTitle)),
      body: LifeCollectionView(
        path: 'food/orders',
        sort: (rows) => [...rows]..sort((a, b) => '${b['date'] ?? ''}'.compareTo('${a['date'] ?? ''}')),
        emptyIcon: Icons.receipt_long_rounded,
        emptyTitle: t.p3lFoodEmptyTitle,
        emptyBody: t.p3lFoodEmptyBody,
        emptyHowTo: t.p3lFoodHowTo,
        addLabel: t.p3lFoodAdd,
        formTitle: t.p3lFoodEdit,
        deleteBody: t.p3lFoodDelete,
        header: (context, rows) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: _summary(context, rows),
        ),
        fields: [
          LifeField('date', t.p3lLegDate, kind: LifeFieldKind.date, required: true),
          LifeField('provider', t.p3lFoodFrom, kind: LifeFieldKind.choice, options: [
            for (final k in kFoodProviders) (k, foodProviderLabel(t, k)),
          ]),
          LifeField('what', t.p3lFoodWhat, maxLength: 80),
          LifeField('amount', t.p3lFoodAmount, kind: LifeFieldKind.money, maxLength: 12, required: true),
        ],
        item: (context, r, onEdit, onDelete) {
          final date = '${r['date'] ?? ''}';
          final what = '${r['what'] ?? ''}';
          return Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
              leading: const Icon(Icons.fastfood_rounded),
              title: Text(ld(context,
                  '${fmtTaka(poishaOf(r['amount']))} · ${foodProviderLabel(t, '${r['provider'] ?? 'other'}')}')),
              subtitle: Text([
                if (date.isNotEmpty) tvNiceDate(context, date),
                if (what.isNotEmpty) what,
              ].join(' · ')),
              trailing: LifeRowMenu(onEdit: onEdit, onDelete: onDelete),
              onTap: onEdit,
            ),
          );
        },
      ),
    );
  }
}
