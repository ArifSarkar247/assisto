import 'package:flutter/material.dart';

import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'action_models.dart';

/// Bottom sheet to review + optionally edit a PENDING action before it runs
/// (SPEC v2.1 §21 — Approve/Reject/EDIT). For draftable actions (a message /
/// note body) the user tweaks the text; the edited value is returned to the
/// caller, which passes it to `approveAction(edit: ...)`. For non-text actions
/// the sheet is a read-only confirmation of exactly what will happen —
/// transparency before approval. No Bangla literals.
///
/// Returns:
///   * a `Map<String,dynamic>` edit payload when the user confirms (empty map
///     = approve unchanged),
///   * `null` when the user dismisses without approving.
Future<Map<String, dynamic>?> showActionEditSheet(
  BuildContext context,
  PendingAction item,
) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ActionEditSheet(item: item),
  );
}

/// The draft field we let the user edit, if any. We look for the common
/// free-text keys a prepared action would carry.
String? _editableKey(Map<String, dynamic> detail) {
  for (final k in const ['body', 'text', 'message', 'note', 'draft']) {
    if (detail[k] is String) return k;
  }
  return null;
}

class _ActionEditSheet extends StatefulWidget {
  final PendingAction item;
  const _ActionEditSheet({required this.item});

  @override
  State<_ActionEditSheet> createState() => _ActionEditSheetState();
}

class _ActionEditSheetState extends State<_ActionEditSheet> {
  late final String? _key = _editableKey(widget.item.detail);
  late final TextEditingController _ctl = TextEditingController(
      text: _key != null ? widget.item.detail[_key] as String : '');

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(actionIcon(widget.item.module), color: cs.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(widget.item.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text(
            '${moduleLabel(t, widget.item.module)} · ${actionLabel(t, widget.item.action)}',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: Gap.md),
          if (_key != null) ...[
            Text(t.actionEditFieldLabel,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: _ctl,
              maxLines: 6,
              minLines: 3,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: t.actionEditHint,
              ),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                widget.item.summary.isNotEmpty
                    ? widget.item.summary
                    : t.actionEditReadOnly,
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: Gap.lg),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text(t.actionApproveRun),
                  onPressed: () {
                    final edit = (_key != null && _ctl.text != widget.item.detail[_key])
                        ? <String, dynamic>{_key!: _ctl.text}
                        : <String, dynamic>{};
                    Navigator.of(context).pop(edit);
                  },
                ),
              ),
              const SizedBox(width: Gap.sm),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t.actionCancel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
