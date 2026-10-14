import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';

/// OWNER-REVIEW policy placeholders: Content policy / Community guidelines /
/// 18+ (adult content). The legal text is NOT written here — per
/// `.phaseB/msg_moderation_integration.md`, owner/lawyer must supply and
/// approve it before any public launch. These pages exist so the app can link
/// to them today; each is clearly marked "to be reviewed by owner" so nobody
/// mistakes a placeholder for a published policy.
///
/// Original Assisto identity; all copy via AppLocalizations (no Bangla in
/// source).
enum MsgrModPolicyKind { contentPolicy, communityGuidelines, adultContent }

class ModerationPolicyScreen extends StatelessWidget {
  final MsgrModPolicyKind kind;
  const ModerationPolicyScreen({super.key, required this.kind});

  /// Convenience: list all three for a settings "Policies" section.
  static const all = MsgrModPolicyKind.values;

  ({String title, String intro, IconData icon}) _copy(AppLocalizations t) {
    switch (kind) {
      case MsgrModPolicyKind.contentPolicy:
        return (
          title: t.msgrModPolicyContentTitle,
          intro: t.msgrModPolicyContentIntro,
          icon: Icons.policy_outlined,
        );
      case MsgrModPolicyKind.communityGuidelines:
        return (
          title: t.msgrModPolicyGuidelinesTitle,
          intro: t.msgrModPolicyGuidelinesIntro,
          icon: Icons.handshake_outlined,
        );
      case MsgrModPolicyKind.adultContent:
        return (
          title: t.msgrModPolicyAdultTitle,
          intro: t.msgrModPolicyAdultIntro,
          icon: Icons.no_adult_content,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final c = _copy(t);

    return Scaffold(
      appBar: AppBar(title: Text(c.title)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.lg),
            decoration: BoxDecoration(
              gradient: Brand.gradient,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(c.icon, color: Colors.white),
                const SizedBox(height: Gap.sm),
                Text(
                  c.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.lg),

          // Prominent, honest "to be reviewed by owner" marker.
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: Brand.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: Brand.warning.withValues(alpha: 0.5)),
            ),
            child: Row(children: [
              const Icon(Icons.rate_review_outlined,
                  color: Brand.warning, size: 20),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.msgrModPolicyOwnerReview,
                  style: const TextStyle(height: 1.4, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
          const SizedBox(height: Gap.lg),

          Text(
            c.intro,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: Gap.lg),

          Text(
            t.msgrModPolicyPlaceholderBody,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
          ),
        ],
      ),
    );
  }
}
