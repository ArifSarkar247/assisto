import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../plans_v2/plans_v2.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'billing_api.dart';
import 'billing_format.dart';

/// billapp — the Plan screen's "where you stand" panel, built ONLY from
/// server data: trial days left and exactly what ends with it, how long this
/// period's plan credits last, the locked credits line, and usage meters
/// (AI credits this month vs the plan's included pool; CRM contacts n/limit
/// from plans_v2). A meter is shown only when the server sent its numbers —
/// no promise the server does not enforce.
class PlanStatusPanel extends StatelessWidget {
  const PlanStatusPanel({
    super.key,
    required this.plan,
    this.v2 = PlansV2State.off,
    this.credits,
    this.usage = const {},
    this.now,
    this.onOpenCredits,
  });

  /// /me/plan
  final Map<String, dynamic> plan;
  final PlansV2State v2;

  /// /credits/state (null = not loaded)
  final CreditsState? credits;

  /// /me/usage-summary
  final Map<String, dynamic> usage;

  /// Tests: a fixed "now".
  final DateTime? now;
  final VoidCallback? onOpenCredits;

  static int _i(Object? v) => v is num ? v.toInt() : 0;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    final nowT = now ?? DateTime.now();

    // ---- trial ----
    final trialActive = plan['trial_active'] == true || v2.trialActive;
    final trialUntil = v2.trialUntil ??
        DateTime.tryParse('${plan['trial_until'] ?? ''}')?.toLocal();
    if (trialActive && trialUntil != null && trialUntil.isAfter(nowT)) {
      final hoursLeft = trialUntil.difference(nowT).inHours;
      final days = (hoursLeft / 24).ceil();
      rows.add(_line(
        context,
        Icons.hourglass_bottom_rounded,
        hoursLeft < 24 ? t.billPlanTrialLastDay : t.billPlanTrialLeft(fmtInt(context, days)),
        sub: t.billPlanTrialEnds(billDate(context, trialUntil)),
        key: const Key('plan-trial-left'),
      ));
    }

    // ---- this period's plan credits ----
    final c = credits;
    if (c != null && c.planExpiresAt != null) {
      rows.add(_line(context, Icons.event_rounded,
          t.billPlanCreditsUntil(billDate(context, c.planExpiresAt!)),
          key: const Key('plan-credits-until')));
    }
    if (c != null && c.locked > 0 && c.untilUnlock() != null) {
      rows.add(_line(
          context,
          Icons.lock_clock_rounded,
          t.billNowAndLocked(fmtInt(context, c.nowUsable), fmtInt(context, c.locked),
              unlockWhen(context, c.untilUnlock()!)),
          key: const Key('plan-locked-line')));
    }

    // ---- usage meters ----
    final meters = <Widget>[];
    final pool = _i(usage['included_pool']);
    if (usage.isNotEmpty && pool > 0) {
      final used = _i(usage['month_total']);
      meters.add(_meter(
        context,
        t.billPlanUsageCredits(fmtInt(context, used), fmtInt(context, pool)),
        used / pool,
        key: const Key('plan-meter-credits'),
      ));
    }
    final oc = v2.on ? v2.ownContacts : null;
    if (oc != null) {
      final txt = '${t.billPlanUsageContacts}: ${contactUsageText(context, oc)}';
      meters.add(_meter(
        context,
        txt,
        oc.unlimited || oc.limit <= 0 ? null : oc.used / oc.limit,
        warn: !oc.canAdd ? t.billPlanLimitReached : null,
        key: const Key('plan-meter-contacts'),
      ));
    }

    if (rows.isEmpty && meters.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('plan-status-panel'),
      margin: const EdgeInsets.only(top: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...rows,
        if (meters.isNotEmpty) ...[
          if (rows.isNotEmpty) const Divider(height: Gap.lg),
          Semantics(
            header: true,
            child: Text(t.billPlanUsageTitle,
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: Gap.sm),
          ...meters,
        ],
        if (onOpenCredits != null)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              key: const Key('plan-open-credits'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onOpenCredits,
              child: Text(t.billSeeMyCredits),
            ),
          ),
      ]),
    );
  }

  Widget _line(BuildContext context, IconData icon, String text,
      {String? sub, Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (sub != null)
              Text(sub,
                  style: AType.bodySmall
                      .copyWith(color: scheme.onSurfaceVariant, height: 1.35)),
          ]),
        ),
      ]),
    );
  }

  Widget _meter(BuildContext context, String label, double? value,
      {String? warn, Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    final over = value != null && value >= 1;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(label),
        if (value != null) ...[
          const SizedBox(height: Gap.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: value.clamp(0, 1).toDouble(),
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(over ? scheme.error : scheme.primary),
              semanticsLabel: label,
            ),
          ),
        ],
        if (warn != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xxs),
            child: Text(warn,
                style: AType.bodySmall.copyWith(
                    color: scheme.error, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}
