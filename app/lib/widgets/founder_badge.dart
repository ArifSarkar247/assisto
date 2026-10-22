import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models.dart';
import '../theme.dart';

/// f1-founders: the subtle "Founding Member" badge (owner-granted; read from
/// `/me` -> founding_member). A thin brand-gradient outline pill with a
/// small laurel icon — readable in light and dark, never clipped (it wraps
/// inside its parent and the label ellipsizes as a last resort).
class FounderBadge extends StatelessWidget {
  final bool dense;
  const FounderBadge({super.key, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? const Color(0xFFD9CCFF) : const Color(0xFF4B2BB8);
    return Semantics(
      label: t.fmBadge,
      child: Container(
        key: const Key('founder-badge'),
        padding: const EdgeInsets.all(1.2),
        decoration: BoxDecoration(
          gradient: Brand.gradient,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: dense ? Gap.sm : Gap.md, vertical: dense ? 2 : 4),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
                Brand.purple.withValues(alpha: dark ? 0.16 : 0.07),
                scheme.surface),
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.workspace_premium_rounded,
                size: dense ? 14 : 16, color: fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                t.fmBadge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: dense ? 11.5 : 12.5,
                    letterSpacing: 0.2),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Badge + "Free Premium until <date>" line + thank-you, for profile screens.
/// Renders nothing for non-members.
class FounderBadgeBlock extends StatelessWidget {
  final AppUser? user;
  const FounderBadgeBlock({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final u = user;
    if (u == null || !u.isFounder) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lang = Localizations.localeOf(context).languageCode;
    String? until;
    final d = DateTime.tryParse(u.founderPremiumUntil ?? '');
    if (d != null && d.isAfter(DateTime.now())) {
      until = t.fmPremiumUntil(DateFormat.yMMMd(lang).format(d.toLocal()));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const FounderBadge(),
      const SizedBox(height: Gap.xs),
      Text(until ?? t.fmThanks,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
    ]);
  }
}
