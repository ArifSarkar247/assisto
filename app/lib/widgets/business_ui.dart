import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Shared building blocks for the Business v2 screens so every surface in the
/// module feels like one app (brand gradient, premium gate, honest states).
///
/// NOTE on strings: this module uses ARB keys ONLY (no hardcoded user-facing
/// text). New keys referenced here that are NOT already in biz_ai_arb.json are
/// listed in the integrator report. Each getter below is declared on
/// AppLocalizations by the integrator (camelCase of the arb key).

/// A rounded card section with a title + optional trailing + body.
class BizCard extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final Widget child;
  final IconData? icon;
  const BizCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: Gap.sm),
            ],
            Expanded(
              child: Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: Gap.md),
          child,
        ]),
      ),
    );
  }
}

/// A soft informational banner (used for the never-hold-money /
/// no-personal-WhatsApp / mock-booking honesty notes).
class BizNote extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? tint;
  const BizNote({super.key, required this.text, this.icon = Icons.info_outline, this.tint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = tint ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: c.withValues(alpha: 0.30)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(height: 1.4, color: scheme.onSurface)),
        ),
      ]),
    );
  }
}

/// A key-gated honest banner: "mock booking — a provider key is required to go
/// live". Pass the already-localised note text.
class BizMockBanner extends StatelessWidget {
  final String text;
  const BizMockBanner({super.key, required this.text});
  @override
  Widget build(BuildContext context) =>
      BizNote(text: text, icon: Icons.construction_outlined, tint: Brand.warning);
}

/// A chip that shows a status with a dot; colour is semantic.
class BizStatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const BizStatusChip({super.key, required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: Gap.sm),
        // p1: a long label ellipsizes inside its parent (Wrap/Row) instead
        // of overflowing at 360 px
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Brand.onTint(context, color))),
        ),
      ]),
    );
  }
}

/// The Premium upgrade gate shown in place of a PAID screen's body when the
/// Business AI plan is not active. Uses plan ARB keys + a brand-gradient hero,
/// lists the paid benefits, and offers an upgrade CTA (which routes to the
/// plans screen). NEVER shows a price — pricing is owner-review (TBD).
class BizPremiumGate extends StatelessWidget {
  /// Localised one-line reason / value prop for this specific feature.
  final String featureLine;
  final VoidCallback onUpgrade;
  const BizPremiumGate({
    super.key,
    required this.featureLine,
    required this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // Paid Business benefits — from plan §8 (ARB keys, no prices).
    final benefits = <String>[
      tr.bizPlanBenefitAi,
      tr.bizPlanBenefitAutoReply,
      tr.bizPlanBenefitBargain,
      tr.bizPlanBenefitVoice,
      tr.bizPlanBenefitPaperKhata,
      tr.bizPlanBenefitInsights,
    ];
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Container(
        padding: const EdgeInsets.all(Gap.xl),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.auto_awesome, color: Colors.white, size: 30),
          const SizedBox(height: Gap.md),
          Text(tr.bizPlanPaidTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          Text(featureLine,
              style: const TextStyle(color: Colors.white, height: 1.4)),
        ]),
      ),
      const SizedBox(height: Gap.lg),
      BizCard(
        title: tr.bizPlanWhatsIncluded,
        icon: Icons.workspace_premium_outlined,
        child: Column(children: [
          for (final b in benefits)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check_circle, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(b, style: const TextStyle(height: 1.4))),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      // Honest: pricing is owner-review (placeholder, no invented numbers).
      BizNote(text: tr.bizPlanPriceTbd, icon: Icons.schedule_outlined),
      const SizedBox(height: Gap.lg),
      FilledButton.icon(
        onPressed: onUpgrade,
        icon: const Icon(Icons.arrow_forward),
        label: Text(tr.bizPlanUpgradeCta),
      ),
    ]);
  }
}
