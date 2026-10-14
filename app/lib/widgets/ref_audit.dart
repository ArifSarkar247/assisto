import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Points AUDIT: earned vs spent vs reversed, plus the redeemed-for-Premium
/// history (feature #102 advanced).
///
/// Both come from the backend: `audit` (earned_total/spent_total/
/// reversed_total/balance — reconciles to the ledger by construction) and
/// `redeemed` (one row per points->Premium-days redemption). The client sums
/// nothing itself, so what the user sees always matches their real balance.
class RefAudit extends StatelessWidget {
  final Map<String, dynamic> audit;
  final List<Map<String, dynamic>> redeemed;
  const RefAudit({super.key, required this.audit, required this.redeemed});

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  String _shortDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final i = iso.indexOf('T');
    return i > 0 ? iso.substring(0, i) : iso;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final earned = _int(audit['earned_total']);
    final spent = _int(audit['spent_total']);
    final reversed = _int(audit['reversed_total']);
    final bal = _int(audit['balance']);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(children: [
          _row(context, t.refAuditEarned, '+$earned', Brand.success),
          if (reversed > 0)
            _row(context, t.refAuditReversed, '-$reversed', Brand.danger),
          _row(context, t.refAuditSpent, '-$spent', Brand.danger),
          Divider(color: scheme.outlineVariant, height: Gap.lg),
          _row(context, t.refAuditBalance, '$bal', scheme.onSurface,
              bold: true),
        ]),
      ),
      const SizedBox(height: Gap.lg),
      Text(t.refRedeemedTitle,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: Gap.sm),
      if (redeemed.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.md),
          child: Text(t.refRedeemedEmpty,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        )
      else
        for (final r in redeemed) _redeemTile(context, t, scheme, r),
    ]);
  }

  Widget _row(BuildContext context, String label, String value, Color color,
      {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
        ),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: bold ? 18 : 15,
                color: color)),
      ]),
    );
  }

  Widget _redeemTile(BuildContext context, AppLocalizations t,
      ColorScheme scheme, Map<String, dynamic> r) {
    final days = _int(r['days']);
    final spent = _int(r['spent']);
    final when = _shortDate(r['created_at']?.toString());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: scheme.primary.withValues(alpha: 0.12),
          child: Icon(Icons.workspace_premium,
              size: 18, color: scheme.primary),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.refRedeemedRow(days),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (when.isNotEmpty)
              Text(when,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
        ),
        Text('-$spent',
            style: const TextStyle(
                fontWeight: FontWeight.w800, color: Brand.danger)),
      ]),
    );
  }
}
