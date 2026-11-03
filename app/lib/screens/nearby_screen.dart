import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;
import '../widgets/app_sheet.dart' show showAppSheet, withNavBarInset; // lifebar
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../nearby/area_cache.dart';
import '../nearby/emergency_numbers.dart';
import '../nearby/emergency_numbers_card.dart';
import '../nearby/phone_country.dart';
import '../services/action_feedback.dart' show openForUser;
import '../state.dart';
import '../theme.dart';
import '../services/error_kind.dart' show honestFailText;
import '../widgets/local_counter.dart';
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';
import '../widgets/nearby_data.dart';
import '../widgets/nearby_category_bar.dart';
import '../widgets/nearby_place_card.dart';

/// Nearby — Assisto's OWN emergency list, zero Google cost (owner 3 Nov 18:50).
///
/// Emergency categories (hospital, clinic, pharmacy, police, fire service,
/// ambulance): the server hands the phone the area around it (GET
/// /nearby/area: OpenStreetMap extract + owner corrections, ODbL); the phone
/// keeps it (offline next time), computes every distance itself, nearest
/// first, one-tap call, one-tap directions (Google Maps app, free), "Report
/// wrong number". The country's official emergency numbers sit on top, with
/// or without location or network. No ads on any emergency list.
///
/// General categories (ATM, fuel, food, shops, ...): "Open in Google Maps"
/// with the search pre-filled (free) + Assisto businesses with a clearly
/// labelled Sponsored placement (server switch, default off).
/// Every list ends with "See more in Google Maps".
enum _Sort { distance, name }

class NearbyScreen extends StatefulWidget {
  /// From emergency / quick-access context: 'hospital', 'pharmacy', 'police',
  /// 'atm', 'restaurant'… Pre-selects the matching category.
  final String placeType;

  /// Test-only position (skips the GPS / permission flow).
  @visibleForTesting
  final ({double lat, double lon})? debugLocation;

  /// Test-only: behave as if location is off / denied (no GPS call).
  @visibleForTesting
  final bool debugLocationDenied;

  /// Test-only: the offline area cache (prod: files on the phone).
  @visibleForTesting
  final AreaCache? cache;

  /// Test-only: the SIM / network country.
  @visibleForTesting
  final PhoneCountry? debugPhoneCountry;

  const NearbyScreen(
      {super.key,
      this.placeType = '',
      this.debugLocation,
      this.debugLocationDenied = false,
      this.cache,
      this.debugPhoneCountry});
  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  // v2: favourites hold the real place (v1 held ids of the removed sample).
  static const _favKey = 'nearby_favourites_v2';
  final _searchCtrl = TextEditingController();

  late NearbyCat _cat;
  bool _showFav = false;
  _Sort _sort = _Sort.distance;
  String _query = '';
  Map<String, NearbyPlace> _favs = {};

  ({double lat, double lon})? _pos; // null = no location
  bool _locating = true;

  PhoneCountry _phone = const PhoneCountry();
  EmergencyArea? _area;
  bool _offline = false; // showing the saved area (server not reached)
  bool _fetching = false;
  Object? _error;

  List<Map<String, dynamic>> _sponsored = const [];
  String _sponsoredLabel = '';

  AreaCache get _cache => widget.cache ?? AreaCache.shared;

  @override
  void initState() {
    super.initState();
    _cat = _mapType(widget.placeType) ?? NearbyCat.hospital;
    _loadFavs();
    _readCountry();
    _locate();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  NearbyCat? _mapType(String s) => switch (s) {
        'hospital' => NearbyCat.hospital,
        'clinic' => NearbyCat.clinic,
        'pharmacy' => NearbyCat.pharmacy,
        'police' => NearbyCat.police,
        'fire' => NearbyCat.fire,
        'ambulance' => NearbyCat.ambulance,
        'atm' => NearbyCat.atmBank,
        'fuel' => NearbyCat.fuel,
        'restaurant' || 'food' => NearbyCat.restaurant,
        'shop' => NearbyCat.shop,
        _ => null,
      };

  Future<void> _readCountry() async {
    final p = widget.debugPhoneCountry ??
        ((widget.debugLocation != null || widget.debugLocationDenied)
            ? const PhoneCountry()
            : await PhoneCountry.read());
    if (mounted) setState(() => _phone = p);
  }

  Future<void> _loadFavs() async {
    try {
      final raw = await Settings.getString(_favKey);
      if (raw == null || raw.isEmpty) return;
      final out = <String, NearbyPlace>{};
      for (final e in (jsonDecode(raw) as List)) {
        final p = NearbyPlace.fromJson((e as Map).cast<String, dynamic>());
        if (p != null) out[p.id] = p;
      }
      if (mounted) setState(() => _favs = out);
    } catch (_) {
      // a broken store just means "no favourites"
    }
  }

  Future<void> _toggleFav(NearbyPlace p) async {
    setState(() {
      _favs.containsKey(p.id) ? _favs.remove(p.id) : _favs[p.id] = p;
    });
    await Settings.setString(
        _favKey, jsonEncode([for (final f in _favs.values) f.toJson()]));
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    final dbg = widget.debugLocation;
    if (dbg != null || widget.debugLocationDenied) {
      _pos = dbg;
    } else {
      try {
        if (!await Geolocator.isLocationServiceEnabled()) throw 'off';
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          if (mounted &&
              !await showPermissionReason(context, PermKind.location)) {
            throw 'perm';
          }
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          throw 'perm';
        }
        final p = await Geolocator.getCurrentPosition();
        _pos = (lat: p.latitude, lon: p.longitude);
      } catch (_) {
        _pos = null; // honest: no location -> numbers only, no sample list
      }
    }
    if (!mounted) return;
    setState(() => _locating = false);
    if (_pos != null) {
      await _loadArea();
      if (!_cat.isEmergency) _loadSponsored();
    }
  }

  /// Saved area first (works offline), then ask the server with its token.
  Future<void> _loadArea() async {
    final pos = _pos;
    if (pos == null) return;
    setState(() {
      _fetching = true;
      _error = null;
    });
    EmergencyArea? saved;
    try {
      saved = await _cache.lookup(pos.lat, pos.lon);
    } catch (_) {
      saved = null;
    }
    if (saved != null && mounted) {
      setState(() {
        _area = saved;
        _offline = true; // until the server confirms
      });
    }
    try {
      final r = await context
          .read<AppState>()
          .api
          .nearbyArea(pos.lat, pos.lon, v: saved?.version ?? '');
      if (!mounted) return;
      if (r['unchanged'] == true && saved != null) {
        setState(() => _offline = false);
      } else {
        final a = EmergencyArea.fromServer(r);
        if (a != null) {
          setState(() {
            _area = a;
            _offline = false;
          });
          try {
            await _cache.put(a);
          } catch (_) {
            // no offline copy this time; the list still shows
          }
        }
      }
    } catch (e) {
      if (mounted && _area == null) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _loadSponsored() async {
    final pos = _pos;
    final cat = _cat.sponsorCat;
    if (pos == null || cat.isEmpty) {
      setState(() => _sponsored = const []);
      return;
    }
    try {
      final r = await context
          .read<AppState>()
          .api
          .nearbySponsored(pos.lat, pos.lon, cat);
      if (!mounted || _cat.sponsorCat != cat) return;
      setState(() {
        _sponsored = [
          for (final e in (r['places'] as List? ?? const []))
            if (e is Map && e['sponsored'] == true) e.cast<String, dynamic>()
        ];
        _sponsoredLabel = '${r['label'] ?? ''}';
      });
    } catch (_) {
      if (mounted) setState(() => _sponsored = const []);
    }
  }

  double? _distOf(NearbyPlace p) {
    final pos = _pos;
    if (pos == null) return null;
    return distanceM(pos.lat, pos.lon, p.lat, p.lon);
  }

  String get _country =>
      pickEmergencyCountry(
          network: _phone.network, data: _area?.country, sim: _phone.sim) ??
      '';

  /// The emergency rows of the current category, nearest first (on the phone).
  List<NearbyPlace> _emergencyRows() {
    final a = _area, pos = _pos;
    if (a == null || pos == null) return const [];
    final rows = nearestFirst(a.places, pos.lat, pos.lon, cats: {_cat.listCat});
    var list = [for (final r in rows) NearbyPlace.fromArea(r.$1, _cat)];
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where((p) =>
              p.nameEn.toLowerCase().contains(q) ||
              p.addrEn.toLowerCase().contains(q))
          .toList();
    }
    if (_sort == _Sort.name) {
      list.sort((a, b) => a.nameEn.compareTo(b.nameEn));
    }
    return list;
  }

  Future<void> _report(NearbyPlace p) async {
    final id = p.serverId;
    if (id == null) return;
    final t = AppLocalizations.of(context);
    final phoneCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final api = context.read<AppState>().api;
    final send = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg,
            Gap.lg + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.nearbyReportTitle, style: AType.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(p.nameEn, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: Gap.sm),
                Text(t.nearbyReportBody),
                const SizedBox(height: Gap.md),
                TextField(
                  key: const ValueKey('nearby_report_phone'),
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  maxLength: 40,
                  buildCounter: localCounter,
                  decoration: InputDecoration(
                      labelText: t.nearbyReportPhoneHint,
                      border: const OutlineInputBorder()),
                ),
                const SizedBox(height: Gap.sm),
                TextField(
                  controller: noteCtrl,
                  maxLength: 300,
                  buildCounter: localCounter,
                  decoration: InputDecoration(
                      labelText: t.nearbyReportNoteHint,
                      border: const OutlineInputBorder()),
                ),
                const SizedBox(height: Gap.sm),
                FilledButton(
                  key: const ValueKey('nearby_report_send'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(t.nearbyReportSend),
                ),
              ]),
        ),
      ),
    );
    // (controllers are not disposed here: the sheet may still be animating
    // out with them attached; they are tiny and collected with the closure)
    final phone = phoneCtrl.text.trim(), note = noteCtrl.text.trim();
    if (send != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.nearbyReport(id, phone: phone, note: note);
      messenger.showSnackBar(SnackBar(content: Text(t.nearbyReportThanks)));
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(honestFailText(t, e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final emergency = _showFav || _cat.isEmergency;

    return Scaffold(
      // banners-everywhere (owner 26 Oct) — but never on an emergency list
      // (owner 3 Nov 18:50): the banner shows only on general categories.
      bottomNavigationBar:
          emergency ? null : const AdBannerSlot(screen: 'nearby'),
      appBar: AppBar(
        title: Text(t.nearby),
        actions: [
          if (emergency)
            PopupMenuButton<_Sort>(
              icon: const Icon(Icons.sort_rounded),
              tooltip: t.nearbySortBy,
              onSelected: (s) => setState(() => _sort = s),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                    value: _Sort.distance,
                    checked: _sort == _Sort.distance,
                    child: Text(t.nearbySortDistance)),
                CheckedPopupMenuItem(
                    value: _Sort.name,
                    checked: _sort == _Sort.name,
                    child: Text(t.nearbySortName)),
              ],
            ),
        ],
      ),
      body: _locating
          ? const SkeletonList()
          : Column(children: [
              if (emergency)
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v.trim()),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t.nearbySearchHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: t.f2ClearSearch,
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _query = '');
                              }),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.md)),
                    ),
                  ),
                )
              else
                const SizedBox(height: Gap.sm),
              NearbyCategoryBar(
                showAll: false,
                selected: _showFav ? null : _cat,
                showFavourites: _showFav,
                onSelect: (c) {
                  if (c == null) return;
                  setState(() {
                    _cat = c;
                    _showFav = false;
                    _sponsored = const [];
                  });
                  if (!c.isEmergency) _loadSponsored();
                },
                onToggleFavView: () => setState(() => _showFav = !_showFav),
              ),
              const SizedBox(height: Gap.sm),
              Expanded(
                  child: _showFav
                      ? _favBody(t)
                      : _cat.isEmergency
                          ? _emergencyBody(t)
                          : _generalBody(t)),
            ]),
    );
  }

  bool get _bn => Localizations.localeOf(context).languageCode == 'bn';

  Widget _seeMore(AppLocalizations t) => Padding(
        padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.sm),
        child: OutlinedButton.icon(
          key: const ValueKey('nearby_see_more_maps'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => openForUser(context, Uri.parse(_cat.mapsSearchUrl),
              where: 'nearby.maps', mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.map_rounded),
          label: Text(t.nearbySeeMoreMaps),
        ),
      );

  Widget _numbers() =>
      EmergencyNumbersCard(data: emergencyFor(_country), bn: _bn);

  Widget _emergencyBody(AppLocalizations t) {
    final pad = withNavBarInset(
        context, const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg));
    final head = <Widget>[_numbers()];
    if (_pos == null) {
      // honest: without the user's real position there is nothing true
      // to list — the numbers still work, and Google Maps can search.
      return ListView(padding: pad, children: [
        ...head,
        StateMessage(
          key: const ValueKey('truth_nearby_no_location'),
          icon: Icons.location_off_rounded,
          title: t.truthNearbyNeedLocation,
          message: t.truthNearbyNeedLocationBody,
          action: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _locate,
            icon: const Icon(Icons.my_location_rounded),
            label: Text(t.nearbyEnable),
          ),
        ),
        _seeMore(t),
      ]);
    }
    if (_fetching && _area == null) {
      return ListView(padding: pad, children: [...head, const SkeletonList()]);
    }
    if (_error != null && _area == null) {
      return ListView(padding: pad, children: [
        ...head,
        StateMessage(
          key: const ValueKey('truth_nearby_error'),
          icon: Icons.cloud_off_rounded,
          title: t.truthNearbyLoadFailed,
          message: honestFailText(t, _error),
          action: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _loadArea,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry),
          ),
        ),
        _seeMore(t),
      ]);
    }
    final items = _emergencyRows();
    final now = DateTime.now();
    return ListView(padding: pad, children: [
      ...head,
      // ODbL attribution with the list (shown above it so it is always seen)
      if (items.isNotEmpty && (_area?.attribution ?? '').isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Text(t.truthNearbySource(_area!.attribution),
              key: const ValueKey('truth_nearby_attribution'),
              style: AType.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      if (_offline)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(children: [
            Icon(Icons.cloud_off_rounded,
                size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Expanded(
                child: Text(t.nearbyOfflineNote,
                    key: const ValueKey('nearby_offline_note'),
                    style: AType.bodySmall)),
          ]),
        ),
      if (items.isEmpty)
        StateMessage(
          key: const ValueKey('truth_nearby_empty'),
          icon: Icons.search_off_rounded,
          title: _query.isEmpty ? t.truthNearbyNoneNearby : t.nothingFound,
          message: _query.isEmpty ? t.lifebarNearbyNoneHint : null,
          action: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _query.isNotEmpty
                ? () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  }
                : _loadArea,
            icon: Icon(_query.isNotEmpty
                ? Icons.clear_rounded
                : Icons.refresh_rounded),
            label: Text(_query.isNotEmpty ? t.lifebarClearSearch : t.retry),
          ),
        ),
      for (final p in items)
        NearbyPlaceCard(
          key: ValueKey('nearby_place_${p.serverId}'),
          place: p,
          bn: _bn,
          distanceMeters: _distOf(p),
          favourite: _favs.containsKey(p.id),
          onToggleFav: () => _toggleFav(p),
          now: now,
          onReport: p.serverId == null ? null : () => _report(p),
        ),
      _seeMore(t),
    ]);
  }

  Widget _favBody(AppLocalizations t) {
    final now = DateTime.now();
    final items = _favs.values.toList()
      ..sort((a, b) => (_distOf(a) ?? 1e12).compareTo(_distOf(b) ?? 1e12));
    if (items.isEmpty) {
      return StateMessage(
        key: const ValueKey('truth_nearby_empty'),
        icon: Icons.star_border_rounded,
        title: t.nearbyNoFavourites,
        message: t.nearbyNoFavouritesHint,
      );
    }
    return ListView(
      padding: withNavBarInset(
          context, const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg)),
      children: [
        for (final p in items)
          NearbyPlaceCard(
            place: p,
            bn: _bn,
            distanceMeters: _distOf(p),
            favourite: true,
            onToggleFav: () => _toggleFav(p),
            now: now,
          ),
      ],
    );
  }

  Widget _generalBody(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final meta = catMeta(_cat);
    return ListView(
      padding: withNavBarInset(
          context, const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg)),
      children: [
        Card(
          key: const ValueKey('nearby_general_panel'),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(meta.icon, size: 40, color: meta.tint),
              const SizedBox(height: Gap.sm),
              Text(t.nearbyGeneralTitle,
                  textAlign: TextAlign.center, style: AType.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(t.nearbyGeneralBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              FilledButton.icon(
                key: const ValueKey('nearby_open_in_maps'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                onPressed: () => openForUser(
                    context, Uri.parse(_cat.mapsSearchUrl),
                    where: 'nearby.maps', mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.map_rounded),
                label: Text(t.nearbyOpenInMaps),
              ),
            ]),
          ),
        ),
        if (_sponsored.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          Text(t.nearbySponsoredHint, style: AType.titleSmall),
          const SizedBox(height: Gap.xs),
          for (final s in _sponsored) _sponsoredCard(t, s),
        ],
        const SizedBox(height: Gap.sm),
        _seeMore(t),
      ],
    );
  }

  Widget _sponsoredCard(AppLocalizations t, Map<String, dynamic> s) {
    final lat = (s['lat'] as num?)?.toDouble();
    final lon = (s['lon'] as num?)?.toDouble();
    final phone = '${s['phone'] ?? ''}';
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('nearby_sponsored_${s['id']}'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('${s['name'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
              decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(Radii.pill)),
              child: Text(
                  _sponsoredLabel.isNotEmpty ? _sponsoredLabel : t.nearbySponsored,
                  style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            if (phone.isNotEmpty)
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => openForUser(context, Uri.parse('tel:$phone'),
                      where: 'nearby.sponsored_call'),
                  icon: const Icon(Icons.call_rounded, size: 18),
                  label: Text(t.nearbyCall),
                ),
              ),
            if (phone.isNotEmpty) const SizedBox(width: Gap.sm),
            if (lat != null && lon != null)
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => openForUser(
                      context,
                      Uri.parse(
                          'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon'),
                      where: 'nearby.sponsored_directions',
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.directions_rounded, size: 18),
                  label: Text(t.nearbyDirections),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
