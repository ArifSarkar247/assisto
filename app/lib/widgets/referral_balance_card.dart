import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Gradient hero card for the Referral screen: shows the point balance and how
/// many Premium days those points can currently buy. Mirrors the Plans current-
/// plan card look (brand gradient) so the two screens feel like one surface.
class ReferralBalanceCard extends StatelessWidget {
  final int points;
  final int redeemableDays;
  final int pointsPerDay;
  const ReferralBalanceCard({
    super.key,
    required this.points,
    required this.redeemableDays,
    required this.pointsPerDay,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Container(
      decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.lg)),
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.referralBalanceLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$points',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(t.referralPoints,
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Row(children: [
          const Icon(Icons.workspace_premium, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: Text(t.referralRedeemableDays(redeemableDays),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 2),
        Text(t.referralRate(pointsPerDay),
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ]),
    );
  }
}
