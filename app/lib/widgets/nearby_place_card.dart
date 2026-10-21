import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'nearby_data.dart';

/// One place row: name, category, distance, open/closed + hours, one-tap call,
/// directions deep-link, save favourite. All copy via AppLocalizations.
class NearbyPlaceCard extends StatelessWidget {
  final NearbyPlace place;
  final bool bn;
  final double? distanceMeters; // null when location unavailable
  final bool favourite;
  final VoidCallback onToggleFav;
  final DateTime now;

  const NearbyPlaceCard({
    super.key,
    required this.place,
    required this.bn,
    required this.distanceMeters,
    required this.favourite,
    required this.onToggleFav,
    required this.now,
  });

  String _bnDigits(String s) {
    // Bangla digits via codepoints (zero == U+09E6) — no Bangla literals in source.
    const base = 0x09E6;
    final buf = StringBuffer();
    for (final ch in s.runes) {
      buf.writeCharCode((ch >= 0x30 && ch <= 0x39) ? base + (ch - 0x30) : ch);
    }
    return buf.toString();
  }

  String _dist(AppLocalizations t) {
    final d = distanceMeters!;
    final s = d >= 1000
        ? t.nearbyKmAway((d / 1000).toStringAsFixed(1))
        : t.nearbyMAway(d.round().toString());
    return bn ? _bnDigits(s) : s;
  }

  String _hours(AppLocalizations t) {
    String hm(int m) {
      final h = (m ~/ 60) % 24;
      final mm = m % 60;
      final s = '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
      return bn ? _bnDigits(s) : s;
    }

    if (place.open24) return t.nearbyOpen24h;
    if (place.openMin == null) return '';
    return t.nearbyHoursRange(hm(place.openMin!), hm(place.closeMin!));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final meta = catMeta(place.cat);
    final open = place.openAt(now);
    final phone = place.phone;

    final statusColor = open == true
        ? Brand.success
        : open == false
            ? Brand.danger
            : scheme.onSurfaceVariant;
    final statusText = open == true
        ? t.nearbyOpenNow
        : open == false
            ? t.nearbyClosedNow
            : t.nearbyHoursUnknown;

    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              height: 40,
              width: 40,
              decoration: BoxDecoration(
                  color: meta.tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(Radii.sm)),
              child: Icon(meta.icon, color: meta.tint, size: 22),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(place.name(bn),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15, height: 1.25)),
                const SizedBox(height: 2),
                Text(place.addr(bn),
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.3)),
              ]),
            ),
            IconButton(
              tooltip: favourite ? t.nearbyUnsave : t.nearbySave,
              onPressed: onToggleFav,
              icon: Icon(favourite ? Icons.star : Icons.star_border,
                  color: favourite ? Brand.gold : scheme.onSurfaceVariant),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (distanceMeters != null)
              _chip(Icons.near_me, _dist(t), scheme.primary, scheme),
            _chip(open == true ? Icons.check_circle : Icons.schedule,
                statusText, statusColor, scheme),
            if (place.open24 || place.openMin != null)
              _chip(Icons.access_time, _hours(t), scheme.onSurfaceVariant, scheme),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            if (phone != null && phone.isNotEmpty)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse('tel:$phone')),
                  icon: const Icon(Icons.call, size: 18, color: Brand.success),
                  label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(t.nearbyCall, maxLines: 1)),
                ),
              ),
            if (phone != null && phone.isNotEmpty) const SizedBox(width: Gap.sm),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => launchUrl(Uri.parse(place.directionsUrl),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.directions, size: 18),
                // one line, scaled to fit (large font broke "Direction s")
                label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(t.nearbyDirections, maxLines: 1)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color color, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Radii.pill)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }
}
