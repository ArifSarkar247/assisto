import 'package:flutter/material.dart';

import '../theme.dart';
import '../l10n/app_localizations.dart';

/// "@Assisto" action sheet (M2 item 9).
///
/// The user long-presses a message and chooses "@Assisto" to turn the message
/// into a reminder / expense / event. The DECRYPTED text is parsed ON-DEVICE and
/// ONLY on this explicit tap — never automatically, never on the server, never
/// over ciphertext.
///
/// The AUTHORITATIVE parse lives in core/logic/circle_extras.assisto_actions
/// (which reuses nlp_datetime + money engines). The integrator may either:
///   (a) call a tiny on-device endpoint that runs assisto_actions over the
///       locally-decrypted text (the text is already on the device; the request
///       stays local), or
///   (b) run an in-Dart parse.
/// This sheet takes the already-computed candidate actions and lets the user
/// confirm which to create, then routes to the existing reminder/expense/event
/// create flows. It does NOT itself send chat content anywhere.
class AssistoAction {
  final String type; // 'reminder' | 'event' | 'expense'
  final double confidence;
  final Map<String, dynamic> payload;
  const AssistoAction(this.type, this.confidence, this.payload);

  factory AssistoAction.fromJson(Map<String, dynamic> j) => AssistoAction(
        '${j['type']}',
        (j['confidence'] as num?)?.toDouble() ?? 0,
        (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

class AssistoActionSheet extends StatelessWidget {
  final List<AssistoAction> actions;
  final ValueChanged<AssistoAction> onCreate;
  const AssistoActionSheet(
      {super.key, required this.actions, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Text(t.circleExtrasAssistoTitle,
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(t.circleExtrasAssistoHint,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            if (actions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.lg),
                child: Text(t.circleExtrasAssistoNone,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              )
            else
              for (final a in actions) _ActionTile(action: a, onCreate: onCreate),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final AssistoAction action;
  final ValueChanged<AssistoAction> onCreate;
  const _ActionTile({required this.action, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    late final IconData icon;
    late final String title;
    late final String detail;
    switch (action.type) {
      case 'expense':
        icon = Icons.receipt_long_rounded;
        title = t.circleExtrasMakeExpense;
        final amt = '${action.payload['amount'] ?? ''}';
        // ৳ (taka) sign is explicitly allowed in .dart.
        detail = amt.isEmpty ? '' : '৳$amt';
        break;
      case 'event':
        icon = Icons.event_rounded;
        title = t.circleExtrasMakeEvent;
        detail = '${action.payload['datetime'] ?? action.payload['title'] ?? ''}';
        break;
      default:
        icon = Icons.notifications_active_rounded;
        title = t.circleExtrasMakeReminder;
        detail = '${action.payload['datetime'] ?? action.payload['title'] ?? ''}';
    }
    return Card(
      margin: const EdgeInsets.only(top: Gap.sm),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(title),
        subtitle: detail.isEmpty
            ? null
            : Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: FilledButton(
          onPressed: () {
            onCreate(action);
            Navigator.of(context).maybePop();
          },
          child: Text(t.circleExtrasCreate),
        ),
      ),
    );
  }
}
