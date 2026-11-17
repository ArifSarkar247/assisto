// mapapp: the GOOGLE VIEW (owner order 10 Nov 00:35 item 3). Google Maps SDK
// base map (+ satellite) — only when this build carries the Android key
// (MapsSdk / MAPS_ANDROID_KEY, an owner item). Google transit results are
// drawn ONLY here, with Google's own logo on the map and "Google" on the
// results; nothing from Google is ever put on the Assisto map or stored.
// Without the key the view still works: a plain panel + "Open in Google
// Maps" (free link) while the transit results show below.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../l10n/app_localizations.dart';
import '../../maps/maps_sdk.dart';
import '../../services/action_feedback.dart' show openForUser;
import '../../theme.dart';
import '../city_offline.dart' show googleMapsTransit;
import 'city_map_data.dart';

class GoogleCityView extends StatefulWidget {
  final double lat, lon;
  final ({double lat, double lon})? dest;
  final List<GTransitRoute> routes;
  final int selected;
  final bool satellite;

  /// Tests + gallery: never create the native GoogleMap.
  @visibleForTesting
  static bool debugNoSdk = false;

  const GoogleCityView(
      {super.key,
      required this.lat,
      required this.lon,
      this.dest,
      this.routes = const [],
      this.selected = 0,
      this.satellite = false});

  @override
  State<GoogleCityView> createState() => _GoogleCityViewState();
}

class _GoogleCityViewState extends State<GoogleCityView> {
  bool? _sdk;

  @override
  void initState() {
    super.initState();
    if (GoogleCityView.debugNoSdk) {
      _sdk = false;
      return;
    }
    MapsSdk.available().then((v) {
      if (mounted) setState(() => _sdk = v);
    }, onError: (_) {
      if (mounted) setState(() => _sdk = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    if (_sdk == null) return ColoredBox(color: s.surfaceContainerHighest);
    if (_sdk == false) {
      final d = widget.dest;
      return ColoredBox(
        key: const ValueKey('city_gview_nosdk'),
        color: s.surfaceContainerHighest,
        // design3 (2.0x font): the note + button scroll inside the map area
        // when the route list below leaves it short (never overflows)
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.public_rounded, size: 40, color: s.onSurfaceVariant),
              const SizedBox(height: Gap.sm),
              Text(t.cityMapGoogleOpenNote, textAlign: TextAlign.center, style: AType.bodyMedium),
              const SizedBox(height: Gap.sm),
              FilledButton.tonalIcon(
                key: const ValueKey('city_gview_open'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => openForUser(
                    context, Uri.parse(googleMapsTransit(widget.lat, widget.lon, d?.lat, d?.lon)),
                    where: 'city.gview', mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.map_rounded),
                label: Text(t.cityOpenGoogleMapsTransit),
              ),
            ]),
          ),
        ),
      );
    }
    final r = widget.selected < widget.routes.length ? widget.routes[widget.selected] : null;
    final pts = r == null ? const <(double, double)>[] : decodePolyline(r.polyline);
    final d = widget.dest;
    return gm.GoogleMap(
      key: const ValueKey('city_gmap'),
      initialCameraPosition: gm.CameraPosition(target: gm.LatLng(widget.lat, widget.lon), zoom: 13),
      mapType: widget.satellite ? gm.MapType.hybrid : gm.MapType.normal,
      myLocationButtonEnabled: false,
      mapToolbarEnabled: false,
      compassEnabled: true,
      polylines: {
        if (pts.length > 1)
          gm.Polyline(
              polylineId: const gm.PolylineId('transit'),
              points: [for (final p in pts) gm.LatLng(p.$1, p.$2)],
              color: Brand.blue,
              width: 5),
      },
      markers: {
        gm.Marker(markerId: const gm.MarkerId('from'), position: gm.LatLng(widget.lat, widget.lon)),
        if (d != null) gm.Marker(markerId: const gm.MarkerId('to'), position: gm.LatLng(d.lat, d.lon)),
      },
    );
  }
}
