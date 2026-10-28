import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// MANDATORY-REASON action dialog shared by both admin screens
/// (admin_moderation_screen, admin_users_screen). Every admin action —
/// remove / restore / warn / suspend / ban / reset-sessions — must carry a
/// written reason that the backend audits (append-only). The confirm button
/// stays disabled until a non-blank reason is typed, so the UI cannot even
/// attempt a reason-less action. Original Assisto identity.
///
/// Returns the trimmed reason string, or null if cancelled.
class MsgrModActionDialog extends StatefulWidget {
  /// Localized verb for the action (e.g. "Suspend", "Remove").
  final String actionLabel;

  /// Localized one-line description of what the action does.
  final String description;

  /// Whether this is a destructive/severe action (tints confirm red).
  final bool destructive;

  const MsgrModActionDialog({
    super.key,
    required this.actionLabel,
    required this.description,
    this.destructive = false,
  });

  static Future<String?> show(
    BuildContext context, {
    required String actionLabel,
    required String description,
    bool destructive = false,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => MsgrModActionDialog(
        actionLabel: actionLabel,
        description: description,
        destructive: destructive,
      ),
    );
  }

  @override
  State<MsgrModActionDialog> createState() => _MsgrModActionDialogState();
}

class _MsgrModActionDialogState extends State<MsgrModActionDialog> {
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final canConfirm = _reason.text.trim().isNotEmpty;
    final tint = widget.destructive ? Brand.danger : scheme.primary;

    return AlertDialog(
      scrollable: true, // insets: 200% text / keyboard
      title: Text(widget.actionLabel),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.description,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _reason,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: t.msgrModReasonRequiredLabel,
              hintText: t.msgrModReasonRequiredHint,
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            t.msgrModReasonAuditNote,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.msgrModCancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: tint),
          onPressed:
              canConfirm ? () => Navigator.of(context).pop(_reason.text.trim()) : null,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

/// Small coloured status pill reused across the admin screens for content
/// status (visible/hidden/removed/restored), queue state and user status.
class MsgrModStatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  const MsgrModStatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
