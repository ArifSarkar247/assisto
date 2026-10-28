import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../vehicle/veh_map.dart' show VehMap, VehMapConfig;
import '../widgets/journey_ride.dart';

/// journey2 — pick a destination on the map. Only opened when the owner
/// configured map tiles (VehMapConfig.hasTiles — the same MAP_TILE_URL as
/// vehicle tracking; never tile.openstreetmap.org). The centre crosshair is
/// the spot; "Use this spot" returns (lat, lng). Without tiles the start
/// form never shows this button and says so instead.
class JourneyMapPickScreen extends StatefulWidget {
  final VehMapConfig config;
  final double? lat, lng;
  const JourneyMapPickScreen({super.key, required this.config, this.lat, this.lng});

  @override
  State<JourneyMapPickScreen> createState() => _JourneyMapPickScreenState();
}

class _JourneyMapPickScreenState extends State<JourneyMapPickScreen> {
  // Dhaka (Zero Point) when nothing better is known
  late LatLng _center = LatLng(widget.lat ?? 23.7286, widget.lng ?? 90.4106);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.j2PickMapTitle)),
      body: Stack(children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: _center,
            initialZoom: widget.lat != null ? 16 : 12,
            maxZoom: widget.config.maxZoom.toDouble(),
            minZoom: 4,
            backgroundColor: cs.surfaceContainerHighest,
            interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            onPositionChanged: (cam, _) => _center = cam.center,
          ),
          children: [
            TileLayer(
              urlTemplate: widget.config.tileUrl,
              maxZoom: widget.config.maxZoom.toDouble(),
              userAgentPackageName: widget.config.userAgentPackage,
              tileProvider: VehMap.debugTileProvider,
            ),
            Align(
              alignment: AlignmentDirectional.topEnd,
              child: Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: Colors.white.withValues(alpha: 0.85),
                child: Text(widget.config.attribution,
                    style: const TextStyle(fontSize: 11, color: Colors.black87)),
              ),
            ),
          ],
        ),
        IgnorePointer(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: Icon(Icons.location_on_rounded, size: 48, color: cs.error,
                  semanticLabel: t.j2PickMapTitle),
            ),
          ),
        ),
        Positioned(
          left: Gap.lg,
          right: Gap.lg,
          bottom: Gap.lg + MediaQuery.paddingOf(context).bottom,
          child: FilledButton.icon(
            key: const ValueKey('j2_map_use'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.check_rounded),
            label: Text(t.j2PickMapUse),
            onPressed: () => Navigator.pop(
                context, (lat: _center.latitude, lng: _center.longitude)),
          ),
        ),
      ]),
    );
  }
}

/// Distance line for a pinned destination ("2.4 km from here").
String jFromHere(BuildContext c, AppLocalizations t, double m) => t.j2PinnedFar(jKm(c, m));
