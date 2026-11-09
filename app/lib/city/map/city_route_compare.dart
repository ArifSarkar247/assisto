// mapapp: route results side by side — "Assisto verified" (our own routes),
// CNG / rickshaw fare estimates, and (ONLY on the Google view) Google transit
// with Google's attribution. Google is asked only when our data has no
// answer or the user taps "More routes"; when Google gives nothing (budget,
// key off, no route) the card simply isn't there — never a limit message.
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../city_models.dart';
import '../city_widgets.dart';
import 'city_map_data.dart';

class CityRouteCompare extends StatelessWidget {
  final CityPlan? plan;
  final bool planning;
  final bool googleView;
  final List<GTransitRoute> google;
  final bool googleLoading, googleTried;
  final int googleSelected;
  final VoidCallback? onMoreRoutes;
  final ValueChanged<int>? onPickGoogle;
  final ValueChanged<CityOption>? onOpenOption;
  final VoidCallback? onSwitchToGoogle;

  const CityRouteCompare(
      {super.key,
      required this.plan,
      this.planning = false,
      this.googleView = false,
      this.google = const [],
      this.googleLoading = false,
      this.googleTried = false,
      this.googleSelected = 0,
      this.onMoreRoutes,
      this.onPickGoogle,
      this.onOpenOption,
      this.onSwitchToGoogle});

  bool get ourAnswer => plan != null && plan!.ok && plan!.options.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cards = <Widget>[];
    if (planning) {
      cards.add(_Card(
          key: const ValueKey('city_cmp_loading'),
          title: t.cityMapAssistoVerified,
          icon: Icons.verified_rounded,
          color: Brand.success,
          child: const Padding(
              padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()))));
    } else if (ourAnswer) {
      final opts = plan!.options;
      final seen = <String>{};
      for (final e in opts.entries) {
        final o = e.value; // one card per distinct way (fastest == fewest changes often)
        if (!seen.add('${o.minutes}|${o.fare.low}|${o.fare.high}|${o.modes.join(',')}|${o.changes}')) continue;
        cards.add(_Card(
          key: ValueKey('city_cmp_ours_${kCityPickKeys[e.key]}'),
          title: o.status == 'verified' ? t.cityMapAssistoVerified : t.cityMapAssistoRoutes,
          sub: cityPickName(t, e.key),
          icon: Icons.verified_rounded,
          color: Brand.success,
          badge: e.value.status,
          onTap: onOpenOption == null ? null : () => onOpenOption!(e.value),
          child: CityOptionSummary(e.value),
        ));
      }
    } else if (plan != null) {
      cards.add(_Card(
          key: const ValueKey('city_cmp_ours_none'),
          title: t.cityMapAssistoVerified,
          icon: Icons.verified_rounded,
          color: Brand.success,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.cityMapOursNone),
            if (!googleView && onSwitchToGoogle != null) ...[
              const SizedBox(height: Gap.sm),
              FilledButton.tonalIcon(
                key: const ValueKey('city_cmp_try_google'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onSwitchToGoogle,
                icon: const Icon(Icons.public_rounded),
                label: Text(t.cityMapSeeGoogle),
              ),
            ],
          ])));
    }
    // CNG / rickshaw fare estimates (our fare rules, never Google's)
    for (final w in plan?.otherWays ?? const <CityOtherWay>[]) {
      if (w.mode != 'cng' && w.mode != 'rickshaw') continue;
      cards.add(_Card(
        key: ValueKey('city_cmp_${w.mode}'),
        title: cityModeName(t, w.mode),
        sub: cityD(context, [cityMinutes(context, w.minutes), t.cityKm(w.km.toStringAsFixed(1))].join(' · ')),
        icon: cityModeIcon(w.mode),
        color: cityModeColor(w.mode),
        child: w.fare == null ? Text(t.cityMapNoFare) : CityFareChip(w.fare!),
      ));
    }
    if (googleView) {
      if (google.isNotEmpty) {
        for (var i = 0; i < google.length; i++) {
          // the Google view leads with Google's own routes
          cards.insert(i, _GoogleCard(google[i], selected: i == googleSelected, onTap: () => onPickGoogle?.call(i), index: i));
        }
      } else if (googleLoading) {
        cards.add(_Card(
            key: const ValueKey('city_cmp_g_loading'),
            title: t.cityMapGoogleTransit,
            icon: Icons.public_rounded,
            color: Brand.blue,
            child: const Padding(
                padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()))));
      } else if (!googleTried && onMoreRoutes != null) {
        cards.add(_Card(
          key: const ValueKey('city_cmp_more'),
          title: t.cityMapGoogleTransit,
          icon: Icons.public_rounded,
          color: Brand.blue,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.cityMapMoreRoutesSub),
            const SizedBox(height: Gap.sm),
            FilledButton.icon(
              key: const ValueKey('city_more_routes'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onMoreRoutes,
              icon: const Icon(Icons.alt_route_rounded),
              label: Text(t.cityMapMoreRoutes),
            ),
          ]),
        ));
      }
    }
    if (cards.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, c) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final w = (c.maxWidth * 0.78).clamp(240.0, 340.0) * (scale > 1.5 ? 1.15 : 1);
      return SingleChildScrollView(
        key: const ValueKey('city_cmp_row'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final card in cards)
            Padding(
              padding: const EdgeInsets.only(right: Gap.sm),
              child: SizedBox(width: w.toDouble(), child: card),
            ),
        ]),
      );
    });
  }
}

String cityPickName(AppLocalizations t, CityPick p) => switch (p) {
      CityPick.cheapest => t.cityCheapest,
      CityPick.fastest => t.cityFastest,
      CityPick.fewestChanges => t.cityFewestChanges,
      CityPick.saferNight => t.citySaferNight,
    };

class _Card extends StatelessWidget {
  final String title;
  final String? sub, badge;
  final IconData icon;
  final Color color;
  final Widget child;
  final VoidCallback? onTap;
  const _Card(
      {super.key,
      required this.title,
      required this.icon,
      required this.color,
      required this.child,
      this.sub,
      this.badge,
      this.onTap});
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: Gap.xs),
              Expanded(
                  child: Text(title,
                      style: AType.titleSmall.copyWith(fontWeight: FontWeight.w800),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis)),
              if (badge != null && badge!.isNotEmpty) CityStatusBadge(badge!),
            ]),
            if (sub != null) Text(sub!, style: AType.bodySmall.copyWith(color: s.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            child,
          ]),
        ),
      ),
    );
  }
}

class _GoogleCard extends StatelessWidget {
  final GTransitRoute r;
  final bool selected;
  final VoidCallback onTap;
  final int index;
  const _GoogleCard(this.r, {required this.selected, required this.onTap, required this.index});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final rides = r.steps.where((x) => x.mode != 'walk').toList();
    return Card(
      key: ValueKey('city_cmp_google_$index'),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: selected ? Brand.blue : s.outlineVariant, width: selected ? 2 : 1)),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.public_rounded, color: Brand.blue, size: 22),
              const SizedBox(width: Gap.xs),
              Expanded(
                  child: Text(t.cityMapGoogleTransit,
                      style: AType.titleSmall.copyWith(fontWeight: FontWeight.w800),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.md, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(cityMinutes(context, r.minutes),
                  style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800)),
              if (r.fareBdt != null)
                CityPill(cityTaka(context, r.fareBdt!, r.fareBdt!), bg: s.secondaryContainer, fg: s.onSecondaryContainer),
            ]),
            const SizedBox(height: Gap.xs),
            for (final x in rides)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(cityModeIcon(x.mode == 'train' ? 'metro' : x.mode), size: 20, color: cityModeColor(x.mode)),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                    child: Text(
                        [
                          if (x.line.isNotEmpty) x.line,
                          if (x.from.isNotEmpty && x.to.isNotEmpty) '${x.from} → ${x.to}',
                        ].join(' · '),
                        style: AType.bodyMedium),
                  ),
                ]),
              ),
            Text(t.cityMapByGoogle, style: AType.labelSmall.copyWith(color: s.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}
