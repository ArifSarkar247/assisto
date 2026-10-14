import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'subs_common.dart';

/// Reusable building blocks for the advanced Subscriptions screen.
/// Pure presentation — no I/O. All strings via AppLocalizations.

/// Big two-stat hero: monthly + yearly recurring spend.
class SubsSpendHero extends StatelessWidget {
  final int monthlyPoisha;
  final int yearlyPoisha;
  final int activeCount;
  const SubsSpendHero({
    super.key,
    required this.monthlyPoisha,
    required this.yearlyPoisha,
    required this.activeCount,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.autorenew, color: cs.onSecondaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.subsActiveCount(fmtInt(context, activeCount)),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: cs.onSecondaryContainer,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: Gap.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _stat(context, t.subsPerMonth,
                      taka(context, monthlyPoisha), cs.onSecondaryContainer),
                ),
                Container(
                  width: 1,
                  height: 40,
                  color: cs.onSecondaryContainer.withValues(alpha: 0.2),
                ),
                Expanded(
                  child: _stat(context, t.subsPerYear,
                      taka(context, yearlyPoisha), cs.onSecondaryContainer),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext c, String label, String value, Color fg) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.75))),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w800, color: fg)),
        ],
      ),
    );
  }
}

/// A labelled section header with an optional trailing hint.
class SubsSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color? tint;
  const SubsSection({super.key, required this.icon, required this.title, this.tint});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.lg, Gap.xs, Gap.sm),
      child: Row(children: [
        Icon(icon, size: 18, color: tint ?? cs.primary),
        const SizedBox(width: Gap.sm),
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// A horizontal "pill" callout banner for trial / nudge alerts.
class SubsAlertBanner extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String body;
  final VoidCallback? onTap;
  const SubsAlertBanner({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    required this.body,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: tint.withValues(alpha: 0.12),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Icon(icon, color: tint),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A single subscription row card with icon chip, cycle/next-due, mark-paid.
class SubsTile extends StatelessWidget {
  final Map<String, dynamic> sub;
  final VoidCallback onEdit;
  final VoidCallback onMarkPaid;
  const SubsTile({
    super.key,
    required this.sub,
    required this.onEdit,
    required this.onMarkPaid,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final name = (sub['name'] ?? '').toString();
    final color = subColor(context, name.isEmpty ? '?' : name);
    final status = (sub['status'] ?? 'active').toString();
    final paused = status == 'paused';
    final cancelled = status == 'cancelled';
    final n = daysUntil(sub['next_due'], DateTime.now());
    final overdue = !cancelled && !paused && n != null && n < 0;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(categoryIcon(sub['category'] as String?), color: color),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            decoration:
                                cancelled ? TextDecoration.lineThrough : null,
                          )),
                    ),
                    if (paused) _tag(context, t.subsStatusPaused, cs.outline),
                    if (cancelled)
                      _tag(context, t.subsStatusCancelled, cs.error),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    [
                      taka(context, poishaOf(sub)),
                      cycleLabel(t, sub['cycle'] as String?),
                    ].join('  ·  '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (!cancelled && sub['next_due'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        dueRelative(context, t, sub['next_due']),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: overdue ? cs.error : cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            if (!cancelled && !paused)
              IconButton(
                tooltip: t.subsMarkPaid,
                icon: const Icon(Icons.check_circle_outline),
                color: Brand.success,
                onPressed: onMarkPaid,
              ),
          ]),
        ),
      ),
    );
  }

  Widget _tag(BuildContext context, String label, Color c) {
    return Container(
      margin: const EdgeInsets.only(left: Gap.sm),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
    );
  }
}

/// Horizontal breakdown bar (category or payment-method share of monthly spend).
class SubsBreakdownRow extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String label;
  final int monthlyPoisha;
  final double fraction; // 0..1 of the largest bucket
  const SubsBreakdownRow({
    super.key,
    required this.icon,
    required this.tint,
    required this.label,
    required this.monthlyPoisha,
    required this.fraction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        Icon(icon, size: 18, color: tint),
        const SizedBox(width: Gap.sm),
        SizedBox(
          width: 96,
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.04, 1.0),
              minHeight: 8,
              backgroundColor: tint.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation(tint),
            ),
          ),
        ),
        const SizedBox(width: Gap.sm),
        Text(taka(context, monthlyPoisha),
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

/// Income-burden gauge: monthly recurring vs known monthly income.
class SubsBurdenGauge extends StatelessWidget {
  final double burdenPct;
  final int monthlyPoisha;
  final int incomePoisha;
  const SubsBurdenGauge({
    super.key,
    required this.burdenPct,
    required this.monthlyPoisha,
    required this.incomePoisha,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final heavy = burdenPct >= 25;
    final tint = heavy ? Brand.warning : Brand.success;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.subsBurdenTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: (burdenPct / 100).clamp(0.0, 1.0),
                minHeight: 10,
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(tint),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              t.subsBurdenBody(
                fmtInt(context, burdenPct.round()),
                taka(context, monthlyPoisha),
                taka(context, incomePoisha),
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
