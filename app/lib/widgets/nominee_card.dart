import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'nominee_scope_picker.dart';

/// One trusted person in the list. Shows their name, relationship, priority,
/// the categories they may reach, the configured release trigger, and the
/// current release status (armed / pending / open). The only state-changing
/// control routes through the release sheet (passed in) so every open/close is
/// confirmed and cancellable.
class NomineeCard extends StatelessWidget {
  final Map<String, dynamic> nominee;
  final VoidCallback onManageRelease;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const NomineeCard({
    super.key,
    required this.nominee,
    required this.onManageRelease,
    required this.onEdit,
    required this.onDelete,
  });

  /// Locale-aware priority digit (no Bangla literal in source).
  static String _priorityDigits(int n, String localeName) {
    final latin = n.toString();
    if (!localeName.startsWith('bn')) return latin;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final ch in latin.runes) {
      b.writeCharCode(ch >= 0x30 && ch <= 0x39 ? bnZero + (ch - 0x30) : ch);
    }
    return b.toString();
  }

  String _relationshipLabel(AppLocalizations tr, String r) {
    switch (r) {
      case 'spouse':
        return tr.nomineeRelSpouse;
      case 'child':
        return tr.nomineeRelChild;
      case 'parent':
        return tr.nomineeRelParent;
      case 'sibling':
        return tr.nomineeRelSibling;
      case 'lawyer':
        return tr.nomineeRelLawyer;
      case 'friend':
        return tr.nomineeRelFriend;
      case 'family':
      default:
        return tr.nomineeRelFamily;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context).toString();

    final activated = nominee['activated'] == true;
    final pending = nominee['release_pending'] == true;
    final trigger = (nominee['trigger'] ?? 'owner_grant') as String;
    final priority = (nominee['priority'] ?? 0) as int;
    final scopes = <String>{
      ...((nominee['scopes'] as List?)?.cast<String>() ??
          [nominee['scope'] ?? 'emergency'])
    };

    final (statusColor, statusLabel, statusIcon) = activated
        ? (scheme.error, tr.nomineeStatusOpen, Icons.lock_open_rounded)
        : pending
            ? (Brand.warning, tr.nomineeStatusPending, Icons.hourglass_top_rounded)
            : (Brand.success, tr.nomineeStatusArmed, Icons.lock_outline_rounded);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Priority badge.
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                priority > 0 ? _priorityDigits(priority, locale) : '•',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: scheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(nominee['name'] ?? '',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      _relationshipLabel(
                          tr, (nominee['relationship'] ?? 'family') as String),
                      nominee['contact'],
                    ].where((e) => (e ?? '').toString().isNotEmpty).join(' · '),
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr.nomineeEdit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
          const SizedBox(height: Gap.md),
          // Category chips.
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.xs,
            children: [
              for (final s in NomineeScope.all)
                if (scopes.contains('all') || scopes.contains(s.key))
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(s.icon, size: 16),
                    label: Text(s.label(tr),
                        style: const TextStyle(fontSize: 12)),
                  ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          // Trigger + status row.
          Row(children: [
            Icon(Icons.bolt_rounded,
                size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Text(_triggerLabel(tr, trigger),
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ),
          ]),
          const SizedBox(height: Gap.md),
          // qa1: status pill + "Manage access" wrap at large font
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: Gap.xs,
              children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm, vertical: Gap.xs),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(statusIcon, size: 14, color: statusColor),
                const SizedBox(width: Gap.xs),
                Text(statusLabel,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: statusColor)),
              ]),
            ),
            TextButton.icon(
              onPressed: onManageRelease,
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: Text(tr.nomineeManageAccess),
            ),
          ]),
        ]),
      ),
    );
  }

  String _triggerLabel(AppLocalizations tr, String t) {
    switch (t) {
      case 'inactivity':
        return tr.nomineeTriggerInactivity;
      case 'multi_verify':
        return tr.nomineeTriggerMultiVerify;
      case 'owner_grant':
      default:
        return tr.nomineeTriggerOwnerGrant;
    }
  }
}
