import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models.dart';
import '../theme.dart';
import 'mem_privacy.dart';

/// Shared presentational widgets for the advanced Memory module.
/// No business logic lives here — the screen owns state and callbacks.

/// Localized label for a canonical category.
String memCatLabel(AppLocalizations t, MemCat c) {
  switch (c) {
    case MemCat.family:
      return t.memCatFamily;
    case MemCat.health:
      return t.memCatHealth;
    case MemCat.preferences:
      return t.memCatPreferences;
    case MemCat.work:
      return t.memCatWork;
    case MemCat.dates:
      return t.memCatDates;
    case MemCat.other:
      return t.memCatOther;
  }
}

/// A small pill tag (category / provenance / privacy / sync).
class MemTag extends StatelessWidget {
  final IconData? icon;
  final String text;
  final Color color;
  const MemTag({super.key, this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(icon == null ? Gap.sm : 6, 2,
          Gap.sm, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
        ],
        Text(text,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Horizontal category filter row with counts. Always leads with "All".
class MemCategoryBar extends StatelessWidget {
  final MemCat? selected; // null = All
  final Map<MemCat, int> counts;
  final ValueChanged<MemCat?> onSelect;
  const MemCategoryBar({
    super.key,
    required this.selected,
    required this.counts,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          _chip(
            context,
            icon: Icons.apps_outlined,
            label: '${t.all} ($total)',
            color: Brand.blue,
            on: selected == null,
            onTap: () => onSelect(null),
          ),
          for (final c in MemCategories.order)
            if ((counts[c] ?? 0) > 0)
              _chip(
                context,
                icon: MemCategories.icon(c),
                label: '${memCatLabel(t, c)} (${counts[c]})',
                color: MemCategories.color(c),
                on: selected == c,
                onTap: () => onSelect(selected == c ? null : c),
              ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required IconData icon,
      required String label,
      required Color color,
      required bool on,
      required VoidCallback onTap}) {
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: ChoiceChip(
        avatar: Icon(icon,
            size: 16, color: on ? Colors.white : color),
        label: Text(label),
        selected: on,
        selectedColor: color,
        labelStyle: TextStyle(
            color: on ? Colors.white : null, fontWeight: FontWeight.w600),
        onSelected: (_) => onTap(),
      ),
    );
  }
}

/// The "AI wants to remember this" consent card — confirm before the AI learns.
/// Nothing is persisted to memory until [onConfirm]; [onDismiss] discards it.
class MemConsentCard extends StatelessWidget {
  final MemPending pending;
  final String localizedTitle;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;
  const MemConsentCard({
    super.key,
    required this.pending,
    required this.localizedTitle,
    required this.onConfirm,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: Brand.cyan.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: Brand.cyan.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome, size: 18, color: Brand.cyan),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.memConsentTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(localizedTitle,
              style: TextStyle(color: scheme.onSurface, height: 1.35)),
          const SizedBox(height: 4),
          Text(t.memConsentAsk,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant, height: 1.3)),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 16),
                // one line, scaled to fit: never breaks mid-word at large font
                label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(t.memConsentNo, maxLines: 1)),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: onConfirm,
                icon: const Icon(Icons.check, size: 16),
                label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(t.memConsentYes, maxLines: 1)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// One memory item row with provenance + privacy badges.
class MemItemCard extends StatelessWidget {
  final MemoryItem item;
  final MemFlags flags;
  final MemCat category;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onPrivacy;
  const MemItemCard({
    super.key,
    required this.item,
    required this.flags,
    required this.category,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onPrivacy,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final catColor = MemCategories.color(category);
    final semantic = [
      item.title,
      if (item.detail.isNotEmpty) item.detail,
      memCatLabel(t, category),
      item.isAi ? t.memoryTagAi : t.memoryTagManual,
      if (flags.excludeFromAi) t.memPrivacyExcludeShort,
      if (flags.sensitive) t.memPrivacySensitive,
      if (flags.private) t.memPrivacyPrivate,
    ].join('. ');

    return Semantics(
      label: semantic,
      button: true,
      child: Card(
        child: ListTile(
          onTap: onTap,
          leading: CircleAvatar(
            backgroundColor: catColor.withValues(alpha: 0.15),
            child: Icon(MemCategories.icon(category), color: catColor, size: 20),
          ),
          title: Text(item.title,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.detail.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: Gap.xs),
                  child: Text(item.detail),
                ),
              Wrap(spacing: 6, runSpacing: 4, children: [
                MemTag(
                    icon: MemCategories.icon(category),
                    text: memCatLabel(t, category),
                    color: catColor),
                MemTag(
                  icon: item.isAi ? Icons.auto_awesome : Icons.edit_outlined,
                  text: item.isAi ? t.memoryTagAi : t.memoryTagManual,
                  color: item.isAi ? Brand.cyan : Brand.blue,
                ),
                if (flags.excludeFromAi)
                  MemTag(
                      icon: Icons.visibility_off_outlined,
                      text: t.memPrivacyExcludeShort,
                      color: Brand.danger),
                if (flags.sensitive)
                  MemTag(
                      icon: Icons.shield_outlined,
                      text: t.memPrivacySensitive,
                      color: Brand.warning),
                if (flags.private)
                  MemTag(
                      icon: Icons.lock_outline,
                      text: t.memPrivacyPrivate,
                      color: Colors.blueGrey),
                if (item.pendingOp != 'none')
                  MemTag(
                      icon: Icons.sync,
                      text: t.memoryTagSyncing,
                      color: Brand.warning),
              ]),
            ],
          ),
          isThreeLine: item.detail.isNotEmpty,
          trailing: PopupMenuButton<String>(
            tooltip: t.memActions,
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'privacy') onPrivacy();
              if (v == 'del') onDelete();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'edit',
                  child: _mi(Icons.edit_outlined, t.edit)),
              PopupMenuItem(
                  value: 'privacy',
                  child: _mi(Icons.lock_outline, t.memPrivacyControls)),
              PopupMenuItem(
                  value: 'del', child: _mi(Icons.delete_outline, t.delete)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mi(IconData i, String label) => Row(children: [
        Icon(i, size: 18),
        const SizedBox(width: Gap.sm),
        Text(label),
      ]);
}

/// A labelled switch row used inside the privacy sheet.
class MemSwitchRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const MemSwitchRow({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile.adaptive(
      value: value,
      onChanged: onChanged,
      secondary: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.14),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.sm),
    );
  }
}
