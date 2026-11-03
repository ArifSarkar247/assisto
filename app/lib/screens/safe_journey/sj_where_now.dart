import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/journey_tracker.dart' show journeyAccBand, journeyMapsLink;
import '../../state.dart';
import '../../theme.dart';
import '../../vehicle/veh_map.dart';
import '../../widgets/journey_ride.dart' show jDigits;
import 'sj_live_api.dart';

/// "± 12 m" / "± 1.8 km (rough)" — the honest accuracy line, or null.
String? sjAccText(BuildContext context, AppLocalizations t, num? acc) {
  if (acc == null) return null;
  final band = journeyAccBand(acc.toDouble());
  final v = acc >= 1000
      ? t.sjlKm(jDigits(context, (acc / 1000).toStringAsFixed(1)))
      : t.sjlM(jDigits(context, acc.round()));
  return band == 'rough' ? t.sjlAccRough(v) : t.sjlAcc(v);
}

/// "updated just now / N min ago / N h ago" — or null when unknown.
String? sjAgeText(BuildContext context, AppLocalizations t, num? ageS) {
  if (ageS == null) return null;
  final m = (ageS / 60).floor();
  if (m < 1) return t.sjlAgeNow;
  if (m < 60) return t.sjlAgeMin(jDigits(context, m));
  return t.sjlAgeHour(jDigits(context, (m / 60).floor()));
}

/// The kind label for a "who is where" row.
String sjKindText(AppLocalizations t, Map<String, dynamic> r) => switch ('${r['kind']}') {
      'share' => t.sjlBtnShare,
      'request' => t.sjlBtnRequest,
      'school' => t.sjlBtnSchool,
      _ => t.sjlBtnTrip,
    };

/// sjlive — "Who is where now": list + map of everyone I may see right now
/// (their live trip, share for a while, a location request they accepted,
/// my School Mode children). Real server rows only; refreshed every 30 s;
/// honest "updated N min ago" and "± N m". The map appears only when the
/// server has a tile provider; otherwise each row opens the phone's maps app.
class SjWhereNow extends StatefulWidget {
  final VoidCallback onRequest;
  final void Function(Map<String, dynamic> row) onOpen;
  const SjWhereNow({super.key, required this.onRequest, required this.onOpen});
  @override
  State<SjWhereNow> createState() => SjWhereNowState();
}

class SjWhereNowState extends State<SjWhereNow> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _error = false;
  VehMapConfig _map = const VehMapConfig();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    reload();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> reload() async {
    final api = context.read<AppState>().api;
    try {
      final rows = await api.sjWhereNow();
      final map = await VehMapConfig.load(api); // never throws
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _map = map;
        _loading = false;
        _error = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  Future<void> _openMaps(Map<String, dynamic> r) async {
    final lat = (r['lat'] as num?)?.toDouble(), lng = (r['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    try {
      await launchUrl(Uri.parse(journeyMapsLink(lat, lng)),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      // best-effort: no maps app / browser on this phone
    }
  }

  Widget _mapView(List<Map<String, dynamic>> pts) {
    final cs = Theme.of(context).colorScheme;
    final ll = [
      for (final r in pts)
        LatLng((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble())
    ];
    return SizedBox(
      key: const ValueKey('sjl_where_map'),
      height: 220,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: ll.first,
            initialZoom: 14,
            initialCameraFit: ll.length >= 2
                ? CameraFit.coordinates(
                    coordinates: ll, padding: const EdgeInsets.all(36), maxZoom: 16)
                : null,
            maxZoom: _map.maxZoom.toDouble(),
            minZoom: 3,
            backgroundColor: cs.surfaceContainerHighest,
            interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            TileLayer(
              urlTemplate: _map.tileUrl,
              maxZoom: _map.maxZoom.toDouble(),
              userAgentPackageName: _map.userAgentPackage,
              tileProvider: VehMap.debugTileProvider,
            ),
            MarkerLayer(markers: [
              for (var i = 0; i < pts.length; i++)
                Marker(
                  point: ll[i],
                  width: 44,
                  height: 44,
                  child: Semantics(
                    label: '${pts[i]['name'] ?? ''}',
                    child: CircleAvatar(
                      backgroundColor: pts[i]['sos'] == true ? cs.error : cs.primary,
                      foregroundColor:
                          pts[i]['sos'] == true ? cs.onError : cs.onPrimary,
                      child: Text(_initial(pts[i]),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
            ]),
            Align(
              alignment: AlignmentDirectional.bottomEnd,
              child: Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                color: Colors.white70,
                child: Text(_map.attribution,
                    style: const TextStyle(fontSize: 11, color: Colors.black87)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initial(Map<String, dynamic> r) {
    final n = '${r['name'] ?? ''}'.trim();
    return n.isEmpty ? '?' : n.characters.first.toUpperCase();
  }

  Widget _row(AppLocalizations t, Map<String, dynamic> r) {
    final cs = Theme.of(context).colorScheme;
    final sos = r['sos'] == true;
    final hasFix = r['lat'] is num && r['lng'] is num;
    final bits = <String>[
      sjKindText(t, r),
      if (sos) t.j100StSos,
      if (sjAgeText(context, t, r['fix_age_s'] as num?) case final a?) a,
      if (sjAccText(context, t, r['acc_m'] as num?) case final a?) a,
      if (r['battery'] is num) t.sjlBattery(jDigits(context, r['battery'])),
      if (!hasFix) t.sjlNoFixYet,
    ];
    return Card(
      key: ValueKey('sjl_where_${r['kind']}_${r['journey_id'] ?? r['plan_id']}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: () => widget.onOpen(r),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              backgroundColor: sos ? cs.error : cs.primaryContainer,
              foregroundColor: sos ? cs.onError : cs.onPrimaryContainer,
              child: Icon(switch ('${r['kind']}') {
                'school' => Icons.school_rounded,
                'share' => Icons.share_location_rounded,
                'request' => Icons.person_pin_circle_rounded,
                _ => Icons.route_rounded,
              }),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['name'] ?? ''}',
                    style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(bits.join(' · '),
                    style: AType.bodySmall.copyWith(
                        color: sos ? cs.error : cs.onSurfaceVariant)),
              ]),
            ),
            if (hasFix)
              IconButton(
                key: ValueKey('sjl_where_maps_${r['journey_id'] ?? r['plan_id']}'),
                tooltip: t.sjlOpenMaps,
                icon: const Icon(Icons.map_rounded),
                onPressed: () => _openMaps(r),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
          padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()));
    }
    if (_error && _rows.isEmpty) {
      return Column(key: const ValueKey('sjl_where_error'), children: [
        Text(t.sjlWhereError, style: AType.bodyMedium),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.sjlRetry),
            onPressed: () {
              setState(() => _loading = true);
              reload();
            }),
      ]);
    }
    if (_rows.isEmpty) {
      return Container(
        key: const ValueKey('sjl_where_empty'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(Radii.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.sjlWhereEmptyTitle,
              style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.sjlWhereEmptyBody, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const ValueKey('sjl_where_ask'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.person_pin_circle_rounded),
            label: Text(t.sjlBtnRequest),
            onPressed: widget.onRequest,
          ),
          const SizedBox(height: Gap.xs),
          Text(t.sjlWhereEmptyHow,
              style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
        ]),
      );
    }
    final pts = _rows.where((r) => r['lat'] is num && r['lng'] is num).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_map.hasTiles && pts.isNotEmpty) ...[
        _mapView(pts),
        const SizedBox(height: Gap.sm),
      ], // jsearch: no internal "the map is not set up yet" text for users
      for (final r in _rows) _row(t, r),
    ]);
  }
}
