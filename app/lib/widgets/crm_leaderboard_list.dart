import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../screens/crm/crm_common.dart';

/// Activity LEADERBOARD (CRM spec #8). Rows are server-ranked
/// (logic_team.leaderboard): a composite score from calls/meetings/proposals/
/// deals, with dense ranks + shared rank on ties. Top 3 get medal accents.
class CrmLeaderboardList extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const CrmLeaderboardList({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [for (final r in rows) _row(context, t, r)],
    );
  }

  Widget _row(BuildContext context, AppLocalizations t, Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    final rank = (r['rank'] as num?)?.toInt() ?? 0;
    final medal = _medal(rank);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: medal ?? scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Text('$rank',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: medal != null ? Colors.white : scheme.onSurfaceVariant)),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['name']?.toString() ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Wrap(spacing: Gap.sm, children: [
                _chip(context, Icons.call_outlined, r['calls'], t.crmCalls),
                _chip(context, Icons.groups_outlined, r['meetings'], t.crmMeetings),
                _chip(context, Icons.description_outlined, r['proposals'], t.crmProposalsLabel),
                _chip(context, Icons.emoji_events_outlined, r['deals_won'], t.crmWon),
              ]),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${(r['score'] as num?)?.toStringAsFixed(0) ?? '0'}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            Text(t.crmPoints,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            if (r['won_amount'] != null)
              Text(bdt(r['won_amount'] as num?),
                  style: TextStyle(fontSize: 11, color: Brand.success)),
          ]),
        ]),
      ),
    );
  }

  Color? _medal(int rank) {
    switch (rank) {
      case 1:
        return const Color(0xFFD4AF37); // gold
      case 2:
        return const Color(0xFF9AA0A6); // silver
      case 3:
        return const Color(0xFFB08D57); // bronze
      default:
        return null;
    }
  }

  Widget _chip(BuildContext context, IconData icon, dynamic value, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: scheme.onSurfaceVariant),
      const SizedBox(width: 3),
      Text('${(value as num?)?.toInt() ?? 0}',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    ]);
  }
}
