import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// "Earn X Premium days by inviting Y friends" progress (feature #102 advanced).
///
/// Every number here comes from the backend `progress` block
/// (referral.py → progress): friends_joined, friends_to_next_day,
/// progress_to_next_day, days_earned_total. The client NEVER hard-codes a point
/// value or a conversion — it only renders what the server computed from the
/// OWNER-REVIEW constants, so the UI can never disagree with the ledger.
class RefProgressCard extends StatelessWidget {
  final int friendsJoined;
  final int daysEarnedTotal;
  final int friendsToNextDay;
  final double progressToNextDay; // 0..1
  const RefProgressCard({
    super.key,
    required this.friendsJoined,
    required this.daysEarnedTotal,
    required this.friendsToNextDay,
    required this.progressToNextDay,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final frac = progressToNextDay.clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.flag_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.refProgressTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text(t.refProgressJoined(friendsJoined),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: Gap.sm),
        Text(t.refProgressDaysEarned(daysEarnedTotal),
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: LinearProgressIndicator(
            value: frac,
            minHeight: 10,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(scheme.primary),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(
          friendsToNextDay > 0
              ? t.refProgressNext(friendsToNextDay)
              : t.refProgressReadyToRedeem,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: friendsToNextDay > 0 ? scheme.onSurface : Brand.success),
        ),
      ]),
    );
  }
}
