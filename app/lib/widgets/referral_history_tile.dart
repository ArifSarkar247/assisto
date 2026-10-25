import 'package:flutter/material.dart';
import '../theme.dart';

/// One row of the referral points ledger (grant / bonus / clawback / redeem).
/// Positive amounts are shown green with a '+', negatives red with a '-', so
/// the history reads like a statement.
class ReferralHistoryTile extends StatelessWidget {
  final Map<String, dynamic> entry;
  const ReferralHistoryTile({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pts = (entry['points'] is num) ? (entry['points'] as num).toInt() : 0;
    final positive = pts >= 0;
    final label = (entry['label'] ?? '').toString();
    final when = _shortDate(entry['created_at']?.toString());
    final color = positive ? Brand.success : Brand.danger;
    final icon = _iconFor(entry['kind']?.toString(), positive);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (when.isNotEmpty)
              Text(when,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
        ),
        Text('${positive ? '+' : ''}$pts',
            style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 16, color: color)),
      ]),
    );
  }

  IconData _iconFor(String? kind, bool positive) {
    switch (kind) {
      case 'redeem':
        return Icons.workspace_premium_rounded;
      case 'clawback':
        return Icons.undo_rounded;
      case 'bonus':
        return Icons.card_giftcard_rounded;
      default:
        return positive ? Icons.group_add_rounded : Icons.remove_rounded;
    }
  }

  /// 'YYYY-MM-DDТ...' -> 'YYYY-MM-DD' (no locale parsing needed).
  String _shortDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final i = iso.indexOf('T');
    return i > 0 ? iso.substring(0, i) : iso;
  }
}
