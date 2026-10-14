import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'referral_balance_card.dart';
import 'referral_history_tile.dart';

/// Referral-points block for the Plans screen (Section 21: "earn Premium days
/// by inviting" + points balance + progress + history). This is the *monetary*
/// bridge on the paywall — you can pay with money OR earn Premium time by
/// inviting people into your Connected Circle. It reuses the same balance /
/// history widgets as the standalone Referral screen so the two stay identical.
///
/// It owns no network calls: the Plans screen loads `referralBalance()` /
/// `referralHistory()` and passes the parsed values in. `balance` may be null
/// while loading or when referral data failed to load (we then render a quiet
/// "couldn't load points" strip instead of a broken block — Section 21 error
/// state — without blocking the rest of the paywall).
class PlansReferralSection extends StatelessWidget {
  final Map<String, dynamic>? balance;
  final List<Map<String, dynamic>> history;

  /// True when the referral fetch failed (balance stays null). The paywall
  /// itself has already finished loading by the time this block is shown, so
  /// there is no separate loading state here — on failure we show a quiet
  /// "couldn't load points" strip instead of blocking the screen.
  final bool failed;
  final bool busy;
  final VoidCallback onInvite;
  final VoidCallback? onRedeem;

  /// Show the full points history ledger (Plans screen keeps it collapsed by
  /// default and lets the user expand it to avoid a very long paywall).
  final bool showHistory;
  final VoidCallback onToggleHistory;

  const PlansReferralSection({
    super.key,
    required this.balance,
    required this.history,
    required this.failed,
    required this.busy,
    required this.onInvite,
    required this.onRedeem,
    required this.showHistory,
    required this.onToggleHistory,
  });

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t.plansEarnPremiumTitle,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
      const SizedBox(height: 2),
      Text(t.plansEarnPremiumSubtitle,
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),

      if (failed || balance == null)
        _errorStrip(context, t, scheme)
      else
        _balanceBlock(context, t, scheme),
    ]);
  }

  Widget _balanceBlock(
      BuildContext context, AppLocalizations t, ColorScheme scheme) {
    final b = balance!;
    final points = _int(b['points']);
    final days = _int(b['redeemable_days']);
    final perDay = _int(b['points_per_day']);
    final canRedeem = b['can_redeem'] == true;

    // Progress toward the NEXT whole Premium day (motivational nudge).
    final towardNext = (perDay > 0) ? (points % perDay) : 0;
    final needed = (perDay > 0) ? perDay - towardNext : 0;
    final progress = (perDay > 0) ? (towardNext / perDay).clamp(0.0, 1.0) : 0.0;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ReferralBalanceCard(
          points: points, redeemableDays: days, pointsPerDay: perDay),
      const SizedBox(height: Gap.md),

      // "earn Premium days" progress toward the next redeemable day.
      if (perDay > 0 && days < 1) ...[
        Text(t.plansPointsToNextDay(needed),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: Gap.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            semanticsLabel: t.plansPointsToNextDay(needed),
          ),
        ),
        const SizedBox(height: Gap.md),
      ],

      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onInvite,
            icon: const Icon(Icons.person_add_alt, size: 18),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            label: Text(t.referralInvite),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: (busy || !canRedeem) ? null : onRedeem,
            icon: const Icon(Icons.workspace_premium, size: 18),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            label: Text(t.plansRedeemForDays),
          ),
        ),
      ]),
      const SizedBox(height: Gap.md),

      // Points history (collapsed by default; Section 21 empty state inside).
      InkWell(
        onTap: onToggleHistory,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(children: [
            Icon(Icons.history, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.referralHistoryTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            Icon(showHistory ? Icons.expand_less : Icons.expand_more,
                color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
      if (showHistory)
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.md),
            child: Row(children: [
              Icon(Icons.inbox_outlined,
                  size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.referralHistoryEmpty,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
            ]),
          )
        else
          for (final e in history) ReferralHistoryTile(entry: e),

      const SizedBox(height: Gap.sm),
      Text(t.referralRateReviewNote,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }

  Widget _errorStrip(
          BuildContext context, AppLocalizations t, ColorScheme scheme) =>
      Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(children: [
          Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(t.plansReferralLoadFailed)),
        ]),
      );
}
