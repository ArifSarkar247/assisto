import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Shared OWNER-ADMIN note cards (SPEC v2.1 §21 — #174 users, #175 moderation).
///
/// Two standing disclosures the owner spec requires on every admin surface:
///   * [AdminPrivacyNote] — the HARD guarantee that an admin never sees message
///     contents or contact lists (the backend strips them in
///     `admin_user_projection`; this is the UI half of the promise).
///   * [AdminLegalNote] — "records are kept for legally-required reporting of
///     illegal content" so moderators understand why audit rows persist.
///
/// Also [AdminTimelineEntry]: one reviewer-grade audit row (who / what / when /
/// why) for the append-only trail. Original Assisto identity; all copy via
/// [AppLocalizations] (zero Bangla in source).

/// Severity tone so the icon + accent match the kind of note.
enum AdminNoteTone { privacy, legal }

class AdminNoteCard extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color accent;
  const AdminNoteCard({
    super.key,
    required this.icon,
    required this.text,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  color: scheme.onSurface, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// The standing "admin never sees message contents or contact lists" guarantee.
class AdminPrivacyNote extends StatelessWidget {
  final String text;
  const AdminPrivacyNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) => AdminNoteCard(
        icon: Icons.lock_outline,
        text: text,
        accent: Theme.of(context).colorScheme.secondary,
      );
}

/// The standing "records kept for legally-required reporting" note.
class AdminLegalNote extends StatelessWidget {
  final String text;
  const AdminLegalNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) => AdminNoteCard(
        icon: Icons.account_balance_outlined,
        text: text,
        accent: Brand.purple,
      );
}

/// Reviewer-grade audit-trail entry: an action label + its mandatory reason,
/// with actor + timestamp, on a connected timeline rail. [isFirst]/[isLast]
/// trim the connecting line at the ends so the column reads as one thread.
class AdminTimelineEntry extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String reason;
  final String meta;
  final bool isFirst;
  final bool isLast;
  const AdminTimelineEntry({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.reason,
    required this.meta,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rail: connecting line above/below a coloured action node.
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 2,
                  height: 6,
                  color: isFirst
                      ? Colors.transparent
                      : scheme.outlineVariant,
                ),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                  ),
                  child: Icon(icon, size: 13, color: color),
                ),
                Expanded(
                  child: Container(
                    width: 2,
                    color: isLast ? Colors.transparent : scheme.outlineVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.md, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700, color: color)),
                  if (reason.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(reason,
                        style: TextStyle(
                            color: scheme.onSurface, height: 1.35)),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(meta,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
