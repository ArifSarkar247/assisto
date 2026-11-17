// mapapp (owner order 10 Nov 00:35, PART A 1 + 3 + screens): City map.
//
//  * ASSISTO MAP (default): MapLibre + our own tiles, light / night, 3D
//    buildings, small credits, offline Dhaka. Layer chips — metro, bus
//    routes, fares, waterlogging, women bus — drawn from OUR City Service
//    data only (never mixed into the tile data).
//  * GOOGLE VIEW (switch): Google Maps SDK base map + satellite, Google
//    transit results shown ONLY here with Google attribution; Google is asked
//    only when our data has no answer or the user taps "More routes".
//  * Route results side by side: Assisto verified · CNG / rickshaw fares ·
//    (Google view) Google transit.
// No ads on this screen.
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_offline.dart';
import '../../city/city_widgets.dart';
import '../../city/map/assisto_map_view.dart';
import '../../city/map/city_map_data.dart';
import '../../city/map/city_map_style.dart';
import '../../city/map/city_route_compare.dart';
import '../../city/map/google_city_view.dart';
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart' show PlacePick;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show showAppSheet, withNavBarInset;
import 'city_journey.dart';

enum CityMapView { assisto, google }

class CityMapScreen extends StatefulWidget {
  final ({double lat, double lon}) here;
  final PlacePick? to;
  final CityPlan? plan;
  final String city;
  final CityStore? store;

  /// Test / gallery.
  @visibleForTesting
  final CityMapView? debugView;
  @visibleForTesting
  final Set<CityLayer>? debugLayers;
  @visibleForTesting
  final bool? debugNight;

  /// Test / gallery: route shapes instead of the phone's city package.
  @visibleForTesting
  final List<Map<String, dynamic>>? debugShapes;

  /// Gallery: ask Google at once (as if "More routes" was tapped).
  @visibleForTesting
  final bool debugMoreRoutes;

  const CityMapScreen(
      {super.key,
      required this.here,
      this.to,
      this.plan,
      this.city = 'dhaka',
      this.store,
      this.debugView,
      this.debugLayers,
      this.debugNight,
      this.debugShapes,
      this.debugMoreRoutes = false});

  @override
  State<CityMapScreen> createState() => _CityMapScreenState();
}

class _CityMapScreenState extends State<CityMapScreen> {
  late CityMapView _view = widget.debugView ?? CityMapView.assisto;
  late Set<CityLayer> _on = {...(widget.debugLayers ?? const {CityLayer.metro, CityLayer.bus})};
  bool? _nightOverride;
  bool _3d = true, _satellite = false, _gl = true;
  List<Map<String, dynamic>> _shapes = const [];
  List<CityReport> _water = const [];
  Set<String> _womenIds = const {};
  bool _womenLoaded = false;
  CityPlan? _plan;
  bool _planning = false;
  List<GTransitRoute> _google = const [];
  bool _gLoading = false, _gTried = false;
  int _gSel = 0;
  CityLayerSet _layers = CityLayerSet.empty;

  ApiClient get _api => context.read<AppState>().api;
  CityStore get _store => widget.store ?? CityStore.I;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    _nightOverride = widget.debugNight;
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    unawaited(_loadPlan());
    if (widget.debugShapes != null) {
      _shapes = widget.debugShapes!;
    } else {
      try {
        await _store.sync(_api, widget.city);
      } catch (_) {} // offline: the saved copy
      final r = await _store.router(widget.city);
      _shapes = r?.routeShapes() ?? const [];
    }
    if (!mounted) return;
    _rebuild();
    if (_on.contains(CityLayer.waterlogging)) unawaited(_loadWater());
    if (_on.contains(CityLayer.women)) unawaited(_loadWomen());
    if (_view == CityMapView.google) unawaited(_googleIfNoAnswer());
  }

  Future<void> _loadPlan() async {
    final d = widget.to;
    if (_plan != null || d == null) return;
    setState(() => _planning = true);
    CityPlan? p;
    try {
      p = CityPlan.from(await _api.cityPlan(widget.here.lat, widget.here.lon, d.lat, d.lng));
    } catch (_) {
      final r = await _store.router(widget.city);
      if (r != null && r.covers(widget.here.lat, widget.here.lon)) {
        p = CityPlan.from(r.plan(widget.here.lat, widget.here.lon, d.lat, d.lng), offline: true);
      }
    }
    if (!mounted) return;
    setState(() {
      _plan = p;
      _planning = false;
    });
    if (_view == CityMapView.google) {
      unawaited(widget.debugMoreRoutes ? _moreRoutes() : _googleIfNoAnswer());
    }
  }

  Future<void> _loadWater() async {
    try {
      final r = await _api.cityReports(widget.here.lat, widget.here.lon, km: 8);
      _water = [for (final e in (r['reports'] as List? ?? const [])) CityReport.from(e)];
    } catch (_) {} // best-effort: the chip then shows nothing new
    if (mounted) _rebuild();
  }

  Future<void> _loadWomen() async {
    try {
      final w = CityWomen.from(await _api.cityWomen(widget.city));
      _womenIds = {for (final b in w.buses) '${b['route_id'] ?? ''}'}..remove('');
    } catch (_) {}
    _womenLoaded = true;
    if (!mounted) return;
    _rebuild();
    if (_on.contains(CityLayer.women) && _womenIds.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).cityMapWomenNone)));
    }
  }

  void _rebuild() {
    final bn = cityBn(context);
    final t = AppLocalizations.of(context);
    setState(() => _layers = buildCityLayers(
          on: _on,
          shapes: _shapes,
          water: _water,
          womenIds: _womenIds,
          bn: bn,
          lat: widget.here.lat,
          lon: widget.here.lon,
          taka: (lo, hi) => cityTaka(context, lo, hi),
          waterText: (n) => cityD(context, t.cityMapWaterLabel('$n')),
        ));
  }

  void _toggle(CityLayer k) {
    setState(() => _on.contains(k) ? _on.remove(k) : _on.add(k));
    if (k == CityLayer.waterlogging && _on.contains(k)) unawaited(_loadWater());
    if (k == CityLayer.women && _on.contains(k) && !_womenLoaded) {
      unawaited(_loadWomen());
    } else if (k == CityLayer.women && _on.contains(k) && _womenIds.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).cityMapWomenNone)));
    }
    _rebuild();
  }

  bool get _ourAnswer => _plan != null && _plan!.ok && _plan!.options.isNotEmpty;

  /// Google only when our data has no answer (or on "More routes").
  Future<void> _googleIfNoAnswer() async {
    if (_planning || widget.to == null || _ourAnswer || _gTried) return;
    await _moreRoutes();
  }

  Future<void> _moreRoutes() async {
    final d = widget.to;
    if (d == null || _gLoading) return;
    setState(() => _gLoading = true);
    var got = const <GTransitRoute>[];
    try {
      got = GTransitRoute.listFrom(await _api.mapsTransit(widget.here.lat, widget.here.lon, d.lat, d.lng));
    } catch (_) {} // silent: only our results stay (never a limit message)
    if (!mounted) return;
    setState(() {
      _google = got;
      _gSel = 0;
      _gLoading = false;
      _gTried = true;
    });
  }

  void _setView(CityMapView v) {
    setState(() => _view = v);
    if (v == CityMapView.google) unawaited(_googleIfNoAnswer());
  }

  bool _night(BuildContext c) => _nightOverride ?? Theme.of(c).brightness == Brightness.dark;

  // ---------------------------------------------------------------- offline
  Future<void> _offline() async {
    final t = AppLocalizations.of(context);
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OfflineSheet(api: _api, t: t),
    );
    if (mounted) setState(() {}); // the style picks the pack up on next open
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final night = _night(context);
    final d = widget.to;
    return Scaffold(
      appBar: AppBar(title: Text(t.cityMapScreenTitle), actions: [
        if (_view == CityMapView.assisto) ...[
          IconButton(
            key: const ValueKey('city_map_night'),
            tooltip: night ? t.cityMapLight : t.cityMapNight,
            onPressed: () => setState(() => _nightOverride = !night),
            icon: Icon(night ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
          ),
          IconButton(
            key: const ValueKey('city_map_offline'),
            tooltip: t.cityMapOffline,
            onPressed: _offline,
            icon: const Icon(Icons.download_for_offline_rounded),
          ),
        ],
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
          child: SegmentedButton<CityMapView>(
            key: const ValueKey('city_map_switch'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                  value: CityMapView.assisto,
                  icon: const Icon(Icons.map_rounded),
                  label: Text(t.cityMapAssisto, key: const ValueKey('city_map_view_assisto'))),
              ButtonSegment(
                  value: CityMapView.google,
                  icon: const Icon(Icons.public_rounded),
                  label: Text(t.cityMapGoogleView, key: const ValueKey('city_map_view_google'))),
            ],
            selected: {_view},
            onSelectionChanged: (v) => _setView(v.first),
          ),
        ),
        // a Row (not a fixed-height list): grows with 200% font, all chips built
        SingleChildScrollView(
          key: const ValueKey('city_map_chips'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
          child: Row(
            children: _view == CityMapView.assisto
                ? [
                    for (final k in CityLayer.values) _chip(t, k),
                    FilterChip(
                      key: const ValueKey('city_layer_3d'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      showCheckmark: false,
                      avatar: const Icon(Icons.apartment_rounded, size: 18),
                      label: Text(t.cityMap3d),
                      selected: _3d,
                      onSelected: (v) => setState(() => _3d = v),
                    ),
                  ]
                : [
                    FilterChip(
                      key: const ValueKey('city_gview_satellite'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      showCheckmark: false,
                      avatar: const Icon(Icons.satellite_alt_rounded, size: 18),
                      label: Text(t.cityMapSatellite),
                      selected: _satellite,
                      onSelected: (v) => setState(() => _satellite = v),
                    ),
                  ],
          ),
        ),
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: _view == CityMapView.assisto
                  ? AssistoMapView(
                      key: const ValueKey('city_map_assisto'),
                      lat: widget.here.lat,
                      lon: widget.here.lon,
                      night: night,
                      bn: cityBn(context),
                      show3d: _3d,
                      layers: _layers,
                      pins: [
                        (lat: widget.here.lat, lon: widget.here.lon, dest: false),
                        if (d != null) (lat: d.lat, lon: d.lng, dest: true),
                      ],
                      onMode: (gl) {
                        if (mounted && gl != _gl) setState(() => _gl = gl);
                      },
                      fallback: _listView,
                    )
                  : GoogleCityView(
                      key: const ValueKey('city_map_google'),
                      lat: widget.here.lat,
                      lon: widget.here.lon,
                      dest: d == null ? null : (lat: d.lat, lon: d.lng),
                      routes: _google,
                      selected: _gSel,
                      satellite: _satellite,
                    ),
            ),
            if (_view == CityMapView.assisto && _gl)
              Positioned(
                left: Gap.sm,
                bottom: Gap.xs,
                right: 96,
                child: IgnorePointer(
                  child: Text(kMapCredits,
                      key: const ValueKey('city_map_credits'),
                      maxLines: 2,
                      style: AType.labelSmall.copyWith(
                          color: s.onSurface,
                          backgroundColor: s.surface.withValues(alpha: 0.75))),
                ),
              ),
          ]),
        ),
        _bottom(t),
      ]),
    );
  }

  Widget _chip(AppLocalizations t, CityLayer k) {
    final (IconData icon, String label) = switch (k) {
      CityLayer.metro => (Icons.subway_rounded, t.cityMapLayerMetro),
      CityLayer.bus => (Icons.directions_bus_rounded, t.cityMapLayerBus),
      CityLayer.fares => (Icons.payments_rounded, t.cityMapLayerFares),
      CityLayer.waterlogging => (Icons.water_drop_rounded, t.cityMapLayerWater),
      CityLayer.women => (Icons.woman_rounded, t.cityMapLayerWomen),
    };
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: FilterChip(
        key: ValueKey('city_layer_${k.name}'),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        showCheckmark: false,
        avatar: Icon(icon, size: 18, color: layerColor(k)),
        label: Text(label),
        selected: _on.contains(k),
        onSelected: (_) => _toggle(k),
      ),
    );
  }

  Widget _bottom(AppLocalizations t) {
    final d = widget.to;
    if (d == null) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
          child: Text(t.cityMapHint, key: const ValueKey('city_map_hint'), style: AType.bodyMedium),
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.42),
      child: SingleChildScrollView(
        key: const ValueKey('city_map_results'),
        padding: withNavBarInset(context, const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: Text(t.cityMapRoutesTo(d.name.isEmpty ? t.cityWhereTo : d.name),
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800), maxLines: 2),
          ),
          const SizedBox(height: Gap.xs),
          CityRouteCompare(
            plan: _plan,
            planning: _planning,
            googleView: _view == CityMapView.google,
            google: _google,
            googleLoading: _gLoading,
            googleTried: _gTried,
            googleSelected: _gSel,
            onMoreRoutes: _moreRoutes,
            onPickGoogle: (i) => setState(() => _gSel = i),
            onSwitchToGoogle: () => _setView(CityMapView.google),
            onOpenOption: (o) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _OptionScreen(o, d))),
          ),
        ]),
      ),
    );
  }

  /// The list view when the GL map cannot run (old GPU, a crash last time,
  /// no style yet): the same layers as rows — never a dead screen.
  Widget _listView(BuildContext context) {
    final t = AppLocalizations.of(context);
    final rows = _layers.rows;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: ListView(
        key: const ValueKey('city_map_list'),
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Row(children: [
            const Icon(Icons.list_alt_rounded),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.cityMapListNote, style: AType.bodyMedium)),
          ]),
          const SizedBox(height: Gap.xs),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('city_map_retry'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () async {
                await CityMapGuard.reset();
                if (!context.mounted) return;
                Navigator.of(context).pushReplacement(MaterialPageRoute(
                    builder: (_) => CityMapScreen(
                        here: widget.here, to: widget.to, plan: _plan, city: widget.city, store: widget.store)));
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(t.cityMapRetry),
            ),
          ),
          if (rows.isEmpty) Text(t.cityMapListEmpty, style: AType.bodyMedium),
          for (final r in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                  switch (r.kind) {
                    CityLayer.metro => Icons.subway_rounded,
                    CityLayer.bus => Icons.directions_bus_rounded,
                    CityLayer.fares => Icons.payments_rounded,
                    CityLayer.waterlogging => Icons.water_drop_rounded,
                    CityLayer.women => Icons.woman_rounded,
                  },
                  color: layerColor(r.kind)),
              title: Text(r.title),
              subtitle: r.sub.isEmpty
                  ? null
                  : Text(r.kind == CityLayer.metro ? cityD(context, t.cityStopsCount(r.sub)) : r.sub),
            ),
        ],
      ),
    );
  }
}

/// One of our options, full steps (same widgets as City Service).
class _OptionScreen extends StatelessWidget {
  final CityOption option;
  final PlacePick dest;
  const _OptionScreen(this.option, this.dest);
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cityTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          CityOptionSummary(option),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            key: const ValueKey('city_map_start'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: () => startCityJourney(context, option: option, dest: dest),
            icon: const Icon(Icons.shield_rounded),
            label: Text(t.cityStartSafeJourney),
          ),
          const Divider(height: Gap.xl),
          CityStepList(option),
        ],
      ),
    );
  }
}

class _OfflineSheet extends StatefulWidget {
  final ApiClient api;
  final AppLocalizations t;
  const _OfflineSheet({required this.api, required this.t});
  @override
  State<_OfflineSheet> createState() => _OfflineSheetState();
}

class _OfflineSheetState extends State<_OfflineSheet> {
  Map<String, dynamic>? _m;
  bool _loading = true, _ready = false, _failed = false;
  double? _p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final have = await CityMapStyle.I.offlineFiles();
    final m = have == null ? await CityMapStyle.I.offlineManifest(widget.api) : null;
    // gap-city: an older pack without fonts/sprites gets them now (names offline)
    if (have != null && have.assets.isEmpty) unawaited(CityMapStyle.I.ensureAssets(widget.api));
    if (!mounted) return;
    setState(() {
      _ready = have != null;
      _m = m;
      _loading = false;
    });
  }

  Future<void> _go() async {
    final m = _m;
    if (m == null) return;
    setState(() {
      _p = 0;
      _failed = false;
    });
    final ok = await CityMapStyle.I.downloadPack(widget.api, m, progress: (v) {
      if (mounted) setState(() => _p = v);
    });
    if (!mounted) return;
    setState(() {
      _p = null;
      _ready = ok;
      _failed = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final s = Theme.of(context).colorScheme;
    final mb = _m == null ? 0 : (CityMapStyle.packBytes(_m!) / (1024 * 1024)).ceil();
    return Padding(
      key: const ValueKey('city_map_offline_sheet'),
      padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.cityMapOfflineTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.cityMapOfflineBody, style: AType.bodyMedium.copyWith(color: s.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_ready) ...[
          Row(children: [
            const Icon(Icons.offline_pin_rounded, color: Brand.success),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.cityMapOfflineReady, key: const ValueKey('city_map_offline_ready'))),
          ]),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            key: const ValueKey('city_map_offline_delete'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () async {
              await CityMapStyle.I.deletePack();
              if (mounted) setState(() => _ready = false);
              await _load();
            },
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(t.cityMapOfflineDelete),
          ),
        ] else if (_m == null)
          Text(t.cityMapOfflineNotYet, key: const ValueKey('city_map_offline_none'))
        else ...[
          Text(cityD(context, t.cityMapOfflineSize('$mb')), style: AType.titleMedium),
          Text(t.cityMapOfflineWifi, style: AType.bodySmall.copyWith(color: s.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          if (_p != null) LinearProgressIndicator(value: _p),
          if (_failed) Text(t.cityMapOfflineFailed, style: AType.bodyMedium.copyWith(color: s.error)),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('city_map_offline_go'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _p != null ? null : _go,
              icon: const Icon(Icons.download_rounded),
              label: Text(t.cityMapOfflineDownload),
            ),
          ),
        ],
      ]),
    );
  }
}
