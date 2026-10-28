import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/business_ui.dart';
import '../plans_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Business plans: FREE vs PAID Business.
///
/// FREE  = khata (also offline) / selling / tagada you send yourself /
///         daily totals — "free forever" (ledger100).
/// PAID  = AI sales assistant / auto-reply / bargaining / voice entry /
///         paper-khata digitising / insights.
///
/// Prices are shown as TBD / owner-review via a placeholder ARB key — this
/// screen NEVER invents a number. The upgrade CTA routes to the shared plans
/// (billing) screen.
class BusinessPlansScreen extends StatelessWidget {
  const BusinessPlansScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.bizPlansTitle)),
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        _planCard(
          context,
          highlighted: false,
          title: tr.bizPlanFreeTitle,
          subtitle: tr.bizPlanFreeSubtitle,
          // ledger100: only what is really free (server FreeForeverTests).
          // "Automatic reminder messages" and weekly/monthly reports were
          // listed here but are paid (credits / the reports capability).
          benefits: [
            tr.bizPlanBenefitKhata,
            tr.ldgFreeL2,
            tr.bizPlanBenefitSelling,
            tr.ldgFreeL4,
            tr.ldgPlanDailyTotals,
          ],
          priceLine: tr.bizPlanFreeForever,
        ),
        const SizedBox(height: Gap.sm),
        Text(tr.ldgFreePaidSms,
            style: AType.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.lg),
        _planCard(
          context,
          highlighted: true,
          title: tr.bizPlanPaidTitle,
          subtitle: tr.bizPlanPaidSubtitle,
          benefits: [
            tr.bizPlanBenefitAi,
            tr.bizPlanBenefitAutoReply,
            tr.bizPlanBenefitBargain,
            tr.bizPlanBenefitVoice,
            tr.bizPlanBenefitPaperKhata,
            tr.bizPlanBenefitInsights,
            tr.bizPlanBenefitReports,
          ],
          // Price intentionally a placeholder — owner review, not invented.
          priceLine: tr.f6BizPlanPriceOnPlans, // f6: real prices live on Plans (server)
          cta: FilledButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const PlansScreen())),
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(tr.bizPlanUpgradeCta),
          ),
        ),
      ]),
    );
  }

  Widget _planCard(
    BuildContext context, {
    required bool highlighted,
    required String title,
    required String subtitle,
    required List<String> benefits,
    required String priceLine,
    Widget? cta,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: highlighted ? Brand.gradient : null,
        color: highlighted ? null : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: highlighted ? null : Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(highlighted ? Icons.workspace_premium_rounded : Icons.check_circle_outline_rounded,
              color: highlighted ? Colors.white : scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: highlighted ? Colors.white : scheme.onSurface)),
        ]),
        const SizedBox(height: Gap.xs),
        Text(subtitle,
            style: TextStyle(
                height: 1.4,
                color: highlighted ? Colors.white : scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.lg),
        for (final b in benefits)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_rounded,
                  size: 18, color: highlighted ? Colors.white : scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(b,
                    style: TextStyle(
                        height: 1.4,
                        color: highlighted ? Colors.white : scheme.onSurface)),
              ),
            ]),
          ),
        const SizedBox(height: Gap.md),
        Text(priceLine,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: highlighted ? Colors.white : scheme.onSurface)),
        if (cta != null) ...[
          const SizedBox(height: Gap.lg),
          SizedBox(width: double.infinity, child: cta),
        ],
      ]),
    );
  }
}
