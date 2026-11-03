import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/business/invoice/new_invoice_screen.dart';
import '../services/action_feedback.dart';
import 'chatnav.dart';

// aifinal (owner AI order 3 Nov 23:15, PART 5): up to 3 action buttons under
// an AI answer, ONLY from the fixed allow-list the server sends (meta.actions).
// Nothing runs on its own: a tap asks first, and the opened screen keeps its
// own plan / credit rules. A button whose screen is not available for this
// user (feature flag off) is not shown — never a dead button.

typedef AiActionOpener = Future<void> Function(BuildContext context, String id, String route);

class AiActionButtons extends StatelessWidget {
  final Map<String, dynamic> meta;

  /// Tests: replace navigation (default opens the real screen / dialer).
  final AiActionOpener? opener;
  const AiActionButtons(this.meta, {super.key, this.opener});

  static const allowed = {
    'safe_journey': 'journey',
    'dest_alarm': 'dest_alarm',
    'reminder': 'reminders',
    'invoice': 'new_invoice',
    'cctv': 'watchman',
    'call_999': 'tel:999',
  };

  static List<String> idsOf(Map<String, dynamic> meta) {
    final raw = meta['actions'];
    if (raw is! List) return const [];
    final out = <String>[];
    for (final a in raw) {
      final id = a is Map ? a['id'] : null;
      if (id is String && allowed.containsKey(id) && !out.contains(id)) out.add(id);
      if (out.length == 3) break;
    }
    return out;
  }

  static bool _routeLive(String id) {
    final r = allowed[id]!;
    if (id == 'call_999' || id == 'invoice') return true;
    return ChatNav.routes.containsKey(r);
  }

  static bool shows(Map<String, dynamic> meta) => idsOf(meta).any(_routeLive);

  String _label(AppLocalizations t, String id) => switch (id) {
        'safe_journey' => t.aiactSafeJourney,
        'dest_alarm' => t.aiactDestAlarm,
        'reminder' => t.aiactReminder,
        'invoice' => t.aiactInvoice,
        'cctv' => t.aiactCctv,
        _ => t.aiactCall999,
      };

  IconData _icon(String id) => switch (id) {
        'safe_journey' => Icons.shield_moon_rounded,
        'dest_alarm' => Icons.alarm_rounded,
        'reminder' => Icons.notifications_active_rounded,
        'invoice' => Icons.receipt_long_rounded,
        'cctv' => Icons.videocam_rounded,
        _ => Icons.call_rounded,
      };

  Future<void> _tap(BuildContext context, String id) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(_label(t, id)),
        content: Text(id == 'call_999' ? t.aiactConfirmCall : t.aiactConfirmOpen),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(id == 'call_999' ? t.aiactCallNow : t.aimdOpenLink)),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final route = allowed[id]!;
    if (opener != null) return opener!(context, id, route);
    if (id == 'call_999') {
      await openForUser(context, Uri.parse(route), where: 'ai.action.999');
    } else if (id == 'invoice') {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const NewInvoiceScreen()));
    } else {
      ChatNav.push(context, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ids = idsOf(meta).where(_routeLive).toList();
    if (ids.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        for (final id in ids)
          OutlinedButton.icon(
            key: Key('aiact-$id'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _tap(context, id),
            icon: Icon(_icon(id), size: 18),
            label: Text(_label(t, id)),
          ),
      ]),
    );
  }
}
