import 'package:flutter/material.dart';
import '../../feature_flags.dart';
import '../../l10n/app_localizations.dart';
import 'probashi_plan_screen.dart';

/// probashi-plan: a small card the Plans screen (agent/billapp) can drop in.
/// Renders NOTHING while the `probashi_plan` flag is off for this user.
class ProbashiPlanEntryCard extends StatelessWidget {
  /// Tests / callers may force visibility; default = the feature flag.
  final bool? visible;
  const ProbashiPlanEntryCard({super.key, this.visible});

  @override
  Widget build(BuildContext context) {
    if (visible != null) return _card(context, visible!);
    return ListenableBuilder(
      listenable: FeatureFlags.instance,
      builder: (ctx, _) => _card(ctx, FeatureFlags.instance.isOn('probashi_plan')),
    );
  }

  Widget _card(BuildContext context, bool on) {
    if (!on) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        key: const ValueKey('pbs-entry-card'),
        minVerticalPadding: 12,
        leading: Icon(Icons.flight_takeoff_rounded, color: Theme.of(context).colorScheme.primary),
        title: Text(t.pbsEntryTitle),
        subtitle: Text(t.pbsEntryBody),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProbashiPlanScreen())),
      ),
    );
  }

}
