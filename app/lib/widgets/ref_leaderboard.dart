import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// "Who joined via me" leaderboard (feature #102 advanced).
///
/// HONEST BY DESIGN: the backend `invite_leaderboard` returns ONE row per
/// invitee who actually JOINED (earned an effective referral grant). People who
/// were invited but never joined have NO row here — we never surface a
/// non-joiner's identity or hint at who declined. Each row shows a display name
/// the integrator already resolved from the existing Connected-Circle
/// relationship (so no new PII), the points earned, and when.
class RefLeaderboard extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const RefLeaderboard({super.key, required this.rows});

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xl),
        child: Column(children: [
          Icon(Icons.groups_outlined, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: Gap.sm),
          Text(t.refLeaderboardEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      );
    }
    return Column(children: [
      for (final r in rows) _tile(context, t, scheme, r),
      const SizedBox(height: Gap.sm),
      Text(t.refLeaderboardHonestNote,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }

  Widget _tile(BuildContext context, AppLocalizations t, ColorScheme scheme,
      Map<String, dynamic> r) {
    final rank = _int(r['rank']);
    final points = _int(r['points']);
    // The integrator joins invitee_id -> display name; fall back to a neutral
    // "member #N" label so we NEVER show a raw id and never fabricate a name.
    final name = (r['name'] ?? r['invitee_name'] ?? '').toString().trim();
    final shown = name.isNotEmpty ? name : t.refLeaderboardMember(rank);
    final medal = _medal(rank, scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: medal, shape: BoxShape.circle),
          child: Text('$rank',
              style: const TextStyle(
                  fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(shown,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(t.refLeaderboardJoined,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
        ),
        Text('+$points',
            style: const TextStyle(
                fontWeight: FontWeight.w800, color: Brand.success)),
      ]),
    );
  }

  Color _medal(int rank, ColorScheme scheme) {
    switch (rank) {
      case 1:
        return const Color(0xFFD4AF37); // gold
      case 2:
        return const Color(0xFF9BA3AF); // silver
      case 3:
        return const Color(0xFFB07A42); // bronze
      default:
        return scheme.primary;
    }
  }
}
