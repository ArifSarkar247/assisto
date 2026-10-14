import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'dict_store.dart';

/// Dictionary ADVANCED — supporting widgets (feature 39, SPEC v2.1 §21):
/// word-of-the-day card, quick-chip rows (recent / history / suggestions), and
/// the designed empty / offline / error states. CONTENT (headwords/examples) is
/// backend open-license data; chrome is ARB. Zero Bangla literals in .dart.

/// Word of the day — a backend-chosen open-license entry, tappable to look up.
class DictWordOfTheDayCard extends StatelessWidget {
  final DictEntry entry;
  final void Function(String query) onOpen;
  const DictWordOfTheDayCard({super.key, required this.entry, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onOpen(entry.en.isNotEmpty ? entry.en : entry.bn),
        child: Container(
          decoration: const BoxDecoration(gradient: Brand.gradient),
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(t.dictWordOfTheDay,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 0.5)),
            ]),
            const SizedBox(height: Gap.sm),
            Text(entry.bn,
                style: const TextStyle(
                    color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
            Text(entry.en,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            if (entry.pos.isNotEmpty || entry.ipa.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                [if (entry.pos.isNotEmpty) entry.pos, if (entry.ipa.isNotEmpty) '/${entry.ipa}/']
                    .join('  ·  '),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 12),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// A labelled row of tappable word chips (recent searches / history / suggestions).
class DictChipRow extends StatelessWidget {
  final String title;
  final List<String> words;
  final void Function(String word) onTap;
  final VoidCallback? onClear;
  final String? clearLabel;
  final IconData icon;
  const DictChipRow({
    super.key,
    required this.title,
    required this.words,
    required this.onTap,
    this.onClear,
    this.clearLabel,
    this.icon = Icons.history,
  });

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(title,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: cs.onSurfaceVariant)),
        ),
        if (onClear != null && clearLabel != null)
          TextButton(onPressed: onClear, child: Text(clearLabel!)),
      ]),
      const SizedBox(height: 6),
      Wrap(
        spacing: Gap.sm,
        runSpacing: 6,
        children: [
          for (final w in words)
            ActionChip(
              label: Text(w),
              onPressed: () => onTap(w),
            ),
        ],
      ),
    ]);
  }
}

/// Generic designed state (empty / offline / error) with icon, title, body and
/// an optional action button.
class DictStateView extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;
  const DictStateView({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.iconColor,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 52, color: iconColor ?? cs.onSurfaceVariant),
          const SizedBox(height: Gap.md),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          if (body != null) ...[
            const SizedBox(height: Gap.xs),
            Text(body!,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant)),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: Gap.md),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ]),
      ),
    );
  }
}

/// A thin inline banner (used for the "offline — from cache" notice).
class DictOfflineBanner extends StatelessWidget {
  final String text;
  const DictOfflineBanner({super.key, required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Brand.warning.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(children: [
        const Icon(Icons.cloud_off, size: 16, color: Color(0xFF8A6D00)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFF8A6D00))),
        ),
      ]),
    );
  }
}
