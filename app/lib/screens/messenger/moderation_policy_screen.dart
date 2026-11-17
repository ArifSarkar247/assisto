import 'package:flutter/material.dart';
import '../../ds/ds.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

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
          icon: Icons.policy_rounded,
        );
      case MsgrModPolicyKind.communityGuidelines:
        return (
          title: t.msgrModPolicyGuidelinesTitle,
          intro: t.msgrModPolicyGuidelinesIntro,
          icon: Icons.handshake_rounded,
        );
      case MsgrModPolicyKind.adultContent:
        return (
          title: t.msgrModPolicyAdultTitle,
          intro: t.msgrModPolicyAdultIntro,
          icon: Icons.no_adult_content_rounded,
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
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          // the policy title as the soft DS hero (no white-on-gradient text)
          DsHeroCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DsAvatar(child: Icon(c.icon, color: scheme.ds.primaryInk)),
                const SizedBox(height: Gap.md),
                Text(c.title,
                    style: AType.titleLarge.copyWith(
                        color: scheme.ds.text, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          const SizedBox(height: Gap.lg),

          // Prominent, honest "to be reviewed by owner" marker.
          DsSurface(
            flat: true,
            color: Brand.warning.withValues(alpha: 0.12),
            borderColor: Brand.warning.withValues(alpha: 0.5),
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(Icons.rate_review_rounded,
                  color: Brand.onTint(context, Brand.warning), size: 20),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  t.msgrModPolicyOwnerReview,
                  style: AType.bodyMedium.copyWith(height: 1.4, fontWeight: FontWeight.w600, color: scheme.ds.text),
                ),
              ),
            ]),
          ),
          const SizedBox(height: Gap.lg),

          Text(
            c.intro,
            style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.5),
          ),
          const SizedBox(height: Gap.lg),

          Text(
            t.msgrModPolicyPlaceholderBody,
            style: AType.bodyMedium.copyWith(color: scheme.ds.muted, height: 1.5),
          ),
        ],
      ),
    );
  }
}
