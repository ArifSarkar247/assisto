// cityapp B5: Around me — hospital, pharmacy, ATM, mosque, police, fuel,
// public toilet, food. From Assisto's own place list + OpenStreetMap (the
// server's GET /nearby: zero Google cost, nothing from Google Places is ever
// stored); every row opens in Google Maps (a free link). The ONLY paid
// listings in City Service live here, under Food, with a clear Ad label
// (B15) — never in route results, never on safety screens.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import '../../widgets/skeleton.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../api.dart';
import '../../city/city_offline.dart' show havM;
import '../../city/city_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart' show PlacePick, placeHereNow;
import '../../services/action_feedback.dart' show openForUser;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;

/// (server type, Google Maps search words, icon, colour)
const kCityAroundCats = <(String, String, IconData, Color)>[
  ('hospital', 'hospital', Icons.local_hospital_rounded, Brand.danger),
  ('pharmacy', 'pharmacy', Icons.local_pharmacy_rounded, Brand.success),
  ('atm', 'ATM', Icons.atm_rounded, Brand.blue),
  ('mosque', 'mosque', Icons.mosque_rounded, Brand.success),
  ('police', 'police station', Icons.local_police_rounded, Brand.blueDeep),
  ('fuel', 'petrol pump', Icons.local_gas_station_rounded, Brand.warning),
  ('toilets', 'public toilet', Icons.wc_rounded, Brand.blueDeep),
  ('restaurant', 'restaurants', Icons.restaurant_rounded, Brand.danger),
];

String cityAroundName(AppLocalizations t, String type) => switch (type) {
      'hospital' => t.cityAroundHospital,
      'pharmacy' => t.cityAroundPharmacy,
      'atm' => t.cityAroundAtm,
      'mosque' => t.cityAroundMosque,
      'police' => t.cityAroundPolice,
      'fuel' => t.cityAroundFuel,
      'toilets' => t.cityAroundToilet,
      _ => t.cityAroundFood,
    };

class CityAroundScreen extends StatefulWidget {
  @visibleForTesting
  final ({double lat, double lon})? debugHere;
  final String initial;

  /// gap-city: opened from City Service -> each place gets "Go by bus /
  /// metro" which returns it (a PlacePick) to plan the trip there.
  final bool routeHere;
  const CityAroundScreen({super.key, this.debugHere, this.initial = 'hospital', this.routeHere = false});
  @override
  State<CityAroundScreen> createState() => _CityAroundScreenState();
}

class _CityAroundScreenState extends State<CityAroundScreen> {
  ({double lat, double lon})? _here;
  late String _type = widget.initial;
  bool _loading = true, _failed = false;
  List<Map<String, dynamic>> _places = const [];
  List<Map<String, dynamic>> _ads = const [];
  String _attribution = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    _here ??= widget.debugHere;
    if (_here == null) {
      if (mounted) setState(() => _loading = true);
      final p = await placeHereNow(context);
      if (p != null) _here = (lat: p.lat, lon: p.lng);
    }
    await _load();
  }

  Future<void> _load() async {
    final h = _here;
    if (h == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _ads = const [];
    });
    final ApiClient api = context.read<AppState>().api;
    final type = _type;
    try {
      final r = await api.nearby(h.lat, h.lon, type);
      if (!mounted || type != _type) return;
      setState(() {
        _places = [for (final p in (r['places'] as List? ?? const [])) if (p is Map) p.cast<String, dynamic>()];
        _attribution = '${r['attribution'] ?? ''}';
        _failed = r['state'] == 'unavailable';
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() {
        _failed = true;
        _loading = false;
      });
    }
    if (type == 'restaurant') {
      try {
        final s = await api.nearbySponsored(h.lat, h.lon, 'food');
        if (!mounted || _type != type) return;
        setState(() => _ads = [
              for (final e in (s['places'] as List? ?? const []))
                if (e is Map && e['sponsored'] == true) e.cast<String, dynamic>()
            ]);
      } catch (_) {} // best-effort: listings are optional
    }
  }

  String get _mapsSearch {
    final q = kCityAroundCats.firstWhere((c) => c.$1 == _type, orElse: () => kCityAroundCats.first).$2;
    return 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeQueryComponent('$q near me')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.cityAroundMe)),
      body: ListView(
        key: const ValueKey('city_around_list'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final c in kCityAroundCats)
              ChoiceChip(
                key: ValueKey('city_around_${c.$1}'),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                selected: _type == c.$1,
                avatar: Icon(c.$3, size: 18, color: c.$4),
                label: Text(cityAroundName(t, c.$1)),
                onSelected: (_) {
                  setState(() => _type = c.$1);
                  _load();
                },
              ),
          ]),
          const SizedBox(height: Gap.md),
          if (_loading)
            const SkeletonList(count: 3)
          else if (_here == null)
            CityRetryCard(
                key: const ValueKey('city_around_need_location'),
                icon: Icons.location_off_rounded,
                text: t.cityAroundNeedLocation,
                buttonText: t.cityTryAgain,
                onPressed: _init)
          else if (_failed)
            CityRetryCard(
                key: const ValueKey('city_around_failed'),
                text: t.cityAroundFailed,
                buttonText: t.cityTryAgain,
                onPressed: _load)
          else if (_places.isEmpty)
            _info(t.cityAroundNone(cityAroundName(t, _type)), Icons.search_off_rounded)
          else
            for (final p in _places) _row(t, p),
          if (_ads.isNotEmpty) ...[
            CitySection(t.cityAdListings),
            for (final a in _ads) _row(t, a, ad: true),
          ],
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            key: const ValueKey('city_around_gmaps'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: () => openForUser(context, Uri.parse(_mapsSearch),
                where: 'city.around_maps', mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.map_rounded),
            label: Text(t.citySeeMoreGoogleMaps),
          ),
          if (_attribution.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(_attribution, style: AType.bodySmall.copyWith(color: s.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  Widget _info(String text, IconData icon) => DsCard(
    padding: const EdgeInsets.all(Gap.lg),
    child: Row(children: [
            Icon(icon),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(text)),
          ]),
  );

  Widget _row(AppLocalizations t, Map<String, dynamic> p, {bool ad = false}) {
    final s = Theme.of(context).colorScheme;
    final lat = (p['lat'] as num?)?.toDouble(), lon = (p['lon'] as num?)?.toDouble();
    final h = _here;
    final dist = (p['distance_m'] as num?)?.toDouble() ??
        (h != null && lat != null && lon != null ? havM(h.lat, h.lon, lat, lon) : null);
    final phone = '${p['phone'] ?? ''}';
    return DsCard(key: ValueKey('city_place_${p['id'] ?? p['name']}'),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(cityD(context, '${p['name'] ?? ''}'),
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
            if (ad) CityPill(t.cityAdLabel, bg: s.tertiaryContainer, fg: s.onTertiaryContainer),
          ]),
          if ('${p['address'] ?? ''}'.isNotEmpty) Text(cityD(context, '${p['address']}'), style: AType.bodySmall),
          if (dist != null) Text(cityDistance(context, dist), style: AType.bodySmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            if (widget.routeHere && lat != null && lon != null)
              CityRouteHereButton(
                  key: ValueKey('city_route_here_${p['id'] ?? p['name']}'),
                  onPressed: () => Navigator.pop<PlacePick>(context,
                      (name: '${p['name'] ?? ''}', address: '${p['address'] ?? ''}', lat: lat, lng: lon))),
            if (lat != null && lon != null)
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => openForUser(
                    context, Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lon'),
                    where: 'city.around_dir', mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.directions_rounded, size: 18),
                label: Text(t.cityOpenInGoogleMaps),
              ),
            if (phone.isNotEmpty)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => openForUser(context, Uri.parse('tel:$phone'), where: 'city.around_call'),
                icon: const Icon(Icons.call_rounded, size: 18),
                label: Text(t.cityCall),
              ),
          ]),
        ]),
    );
  }
}
