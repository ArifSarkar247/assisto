import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'nearby_data.dart';

/// Horizontal scrollable category filter. `null` selection = All.
/// Includes an "All" chip and a "Favourites" chip (favKey = '__fav__').
class NearbyCategoryBar extends StatelessWidget {
  final NearbyCat? selected;
  final bool showFavourites;
  final ValueChanged<NearbyCat?> onSelect;
  final VoidCallback onToggleFavView;

  /// truth: live places are fetched per category, so the live screen hides
  /// the "All" chip (there is no honest single "everything" query).
  final bool showAll;

  const NearbyCategoryBar({
    super.key,
    this.showAll = true,
    required this.selected,
    required this.showFavourites,
    required this.onSelect,
    required this.onToggleFavView,
  });

  String _label(AppLocalizations t, NearbyCat c) {
    switch (c) {
      case NearbyCat.hospital:
        return t.nearbyCatHospital;
      case NearbyCat.pharmacy:
        return t.nearbyCatPharmacy;
      case NearbyCat.atmBank:
        return t.nearbyCatAtm;
      case NearbyCat.police:
        return t.nearbyCatPolice;
      case NearbyCat.fire:
        return t.nearbyCatFire;
      case NearbyCat.transport:
        return t.nearbyCatTransport;
      case NearbyCat.fuel:
        return t.nearbyCatFuel;
      case NearbyCat.restaurant:
        return t.nearbyCatRestaurant;
      case NearbyCat.mosque:
        return t.nearbyCatMosque;
      case NearbyCat.govt:
        return t.nearbyCatGovt;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: FilterChip(
              avatar: const Icon(Icons.star_rounded, size: 16, color: Brand.gold),
              label: Text(t.nearbyFavourites),
              selected: showFavourites,
              onSelected: (_) => onToggleFavView(),
            ),
          ),
          if (showAll)
          Padding(
            padding: const EdgeInsets.only(right: Gap.sm),
            child: ChoiceChip(
              label: Text(t.nearbyAll),
              selected: !showFavourites && selected == null,
              onSelected: (_) => onSelect(null),
            ),
          ),
          for (final m in kNearbyCats)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: ChoiceChip(
                avatar: Icon(m.icon,
                    size: 16,
                    color: (!showFavourites && selected == m.cat)
                        ? scheme.onSecondaryContainer
                        : m.tint),
                label: Text(_label(t, m.cat)),
                selected: !showFavourites && selected == m.cat,
                onSelected: (_) => onSelect(m.cat),
              ),
            ),
        ],
      ),
    );
  }
}
