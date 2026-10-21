import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Shared building blocks for the expanded hub Settings sub-screens. Keeps the
/// sub-screens tidy and visually consistent (Original Assisto look — our own
/// icons/wording, never Meta assets). No Bangla literals here; every label is
/// passed in from AppLocalizations by the caller.

/// A section header inside a settings list.
class MsgrSetSection extends StatelessWidget {
  final String label;
  const MsgrSetSection(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xs),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: scheme.primary),
      ),
    );
  }
}

/// A one-line navigation row with icon, title and optional subtitle/trailing.
/// Labels @360dp: title up to 2 lines then ellipsises, never clips.
class MsgrSetRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value; // right-aligned current value (e.g. "English")
  final VoidCallback? onTap;
  final Color? color;
  const MsgrSetRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: color),
      // QA a6: 2 lines — at large font one line cut titles to
      // "Create chat backu…".
      title: Text(title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: color == null ? null : TextStyle(color: color)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 3, overflow: TextOverflow.ellipsis),
      trailing: value == null
          ? (onTap == null ? null : const Icon(Icons.chevron_right))
          : Text(value!,
              style: TextStyle(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}

/// An HONEST "coming soon / needs key X" inline panel for surfaces that can't
/// act yet (so the row that opens the screen is never a dead tap — it lands on
/// a truthful state that explains exactly what's missing). [requirement] is an
/// already-localized sentence naming the missing piece.
class MsgrSetComingSoon extends StatelessWidget {
  final String title;
  final String requirement;
  final IconData icon;
  const MsgrSetComingSoon({
    super.key,
    required this.title,
    required this.requirement,
    this.icon = Icons.schedule_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 52, color: scheme.primary),
          const SizedBox(height: Gap.md),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(requirement,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
        ]),
      ),
    );
  }
}

/// A short footer note (e.g. "server-enforced") shown under a settings list.
class MsgrSetNote extends StatelessWidget {
  final String text;
  final IconData icon;
  const MsgrSetNote(this.text, {super.key, this.icon = Icons.info_outline});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant, height: 1.3)),
        ),
      ]),
    );
  }
}
