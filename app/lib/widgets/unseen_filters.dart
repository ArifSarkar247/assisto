// Category + division filter bar for the ADVANCED Unseen World module.
//
// Horizontal chip rails: a category rail (nature / historical / beach / hill /
// religious / island / waterfall) plus a wishlist toggle; the division filter
// is a compact dropdown in the screen's app bar. Zero Bangla literals — all
// labels come from AppLocalizations via the label-resolver callbacks.

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'unseen_data.dart';

class UnseenCategoryBar extends StatelessWidget {
  final TravelCat? selected;
  final bool showWishlist;
  final ValueChanged<TravelCat?> onSelect;
  final VoidCallback onToggleWishlist;
  final String Function(TravelCat) catLabel;

  const UnseenCategoryBar({
    super.key,
    required this.selected,
    required this.showWishlist,
    required this.onSelect,
    required this.onToggleWishlist,
    required this.catLabel,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          _chip(
            context,
            icon: Icons.bookmark_border,
            label: t.unseenWishlist,
            selected: showWishlist,
            onTap: onToggleWishlist,
          ),
          const SizedBox(width: Gap.sm),
          _chip(
            context,
            icon: Icons.apps_outlined,
            label: t.unseenAll,
            selected: !showWishlist && selected == null,
            onTap: () => onSelect(null),
          ),
          for (final m in kTravelCats) ...[
            const SizedBox(width: Gap.sm),
            _chip(
              context,
              icon: m.icon,
              label: catLabel(m.cat),
              selected: !showWishlist && selected == m.cat,
              tint: m.tint,
              onTap: () => onSelect(m.cat),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
      Color? tint}) {
    final scheme = Theme.of(context).colorScheme;
    final c = tint ?? scheme.primary;
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? c.withValues(alpha: 0.16) : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(
                color: selected ? c : scheme.outlineVariant,
                width: selected ? 1.4 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: selected ? c : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? c : scheme.onSurface)),
          ]),
        ),
      ),
    );
  }
}
