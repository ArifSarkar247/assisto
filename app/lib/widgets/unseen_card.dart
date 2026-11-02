// Destination card for the ADVANCED Unseen World module.
//
// Shows a category hero (no fake photo — tinted band + icon, with a verbatim
// photo-credit line when one exists), best time, how to get there, an APPROX
// cost range (always labelled "approx" + sourced), nearby spots, a practical
// tip, and a source attribution. Actions: save/wishlist, directions, share.
//
// Zero Bangla literals: proper nouns come from the dataset as romanized data;
// every label comes from AppLocalizations.

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'unseen_data.dart';
import 'unseen_l10n.dart'; // lifebar
import 'local_digits.dart'; // lifebar

class UnseenCard extends StatelessWidget {
  final Destination dest;
  final String divisionLabel;
  final String catLabel;
  final String seasonLabel; // localized "Best time" window
  final double? distanceMeters; // null = no location
  final bool saved;
  final VoidCallback onToggleSave;
  final VoidCallback onDirections;
  final VoidCallback onShare;

  const UnseenCard({
    super.key,
    required this.dest,
    required this.divisionLabel,
    required this.catLabel,
    required this.seasonLabel,
    required this.distanceMeters,
    required this.saved,
    required this.onToggleSave,
    required this.onDirections,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final meta = catMeta(dest.cat);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final tx = uwText(t, dest, bn); // lifebar: Bangla prose in a Bangla UI
    final cost = t.unseenCostRange(toLocalDigits(_bdt(dest.approxCostLow), bn),
        toLocalDigits(_bdt(dest.approxCostHigh), bn));

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Category hero — honest tint band, not a fabricated photo.
        Container(
          // min height (not fixed): grows with large fonts instead of clipping
          constraints: const BoxConstraints(minHeight: 72),
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [meta.tint.withValues(alpha: 0.85), meta.tint.withValues(alpha: 0.55)],
            ),
          ),
          padding: const EdgeInsets.all(Gap.md),
          child: Row(children: [
            Icon(meta.icon, color: Colors.white, size: 28),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tx.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16)),
                    Text('$catLabel  •  $divisionLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.92),
                            fontSize: 12)),
                  ]),
            ),
            IconButton(
              tooltip: saved ? t.unseenRemoveWishlist : t.unseenAddWishlist,
              onPressed: onToggleSave,
              icon: Icon(saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                  color: Colors.white),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (distanceMeters != null)
              _chipRow(scheme, Icons.near_me_rounded,
                  t.unseenKmAway(toLocalDigits(_km(distanceMeters!), bn))),
            _fact(scheme, Icons.event_available_rounded, t.unseenBestSeason,
                '${tx.best}  ($seasonLabel)'),
            _fact(scheme, Icons.directions_bus_rounded, t.unseenHowToGet,
                tx.how),
            _fact(scheme, Icons.payments_rounded, t.unseenApproxCost, cost),
            if (dest.nearby.isNotEmpty)
              _fact(scheme, Icons.place_rounded, t.unseenNearby,
                  tx.near),
            _fact(scheme, Icons.lightbulb_outline_rounded, t.unseenTip, tx.tip),
            const SizedBox(height: Gap.xs),
            // Honest source + photo credit.
            Text('${t.unseenSource}: ${dest.source.label}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            // lifebar: no photo is shown, so no (English) photo credit line
          ]),
        ),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
                onPressed: onDirections,
                icon: const Icon(Icons.map_rounded, size: 18),
                label: Text(t.unseenDirections)),
            TextButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.share_rounded, size: 18),
                label: Text(t.unseenShare)),
          ],
        ),
      ]),
    );
  }

  Widget _fact(ColorScheme scheme, IconData icon, String label, String body) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 13, color: scheme.onSurface, height: 1.3),
              children: [
                TextSpan(
                    text: '$label: ',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: body),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _chipRow(ColorScheme scheme, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Icon(icon, size: 15, color: scheme.secondary),
        const SizedBox(width: 6),
        Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.secondary)),
      ]),
    );
  }

  // Bangla/Latin digits are locale-rendered by the framework via String; here
  // we only format numbers (no Bangla literals).
  static String _bdt(int v) => v.toString();
  static String _km(double m) => (m / 1000).toStringAsFixed(1);
}
