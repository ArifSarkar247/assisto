import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../services/error_kind.dart' show honestFailText;
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';
import '../widgets/nearby_data.dart';
import '../widgets/nearby_category_bar.dart';
import '../widgets/nearby_place_card.dart';

/// Nearby — REAL places only.
///
/// truth (owner FINAL ORDER 27 Oct): the curated Dhaka sample list (made-up
/// phone numbers and hours) is gone. Each category is fetched from the
/// server's live layer (GET /nearby: Google Places when the owner's key
/// works, else OpenStreetMap Overpass) for the user's real position, and the
/// source's licence line is shown under the list. Honest states: no location
/// (turn it on — no list), loading, source down (retry), nothing nearby, no
/// favourites. Favourites are saved on the phone as the source returned them.
enum _Sort { distance, openFirst, name }

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

  const NearbyScreen(
      {super.key,
      this.placeType = '',
      this.debugLocation,
      this.debugLocationDenied = false});
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

  bool _fetching = false;
  Object? _error;
  List<NearbyPlace> _places = const [];
  String _attribution = '';

  @override
  void initState() {
    super.initState();
    _cat = _mapType(widget.placeType) ?? NearbyCat.hospital;
    _loadFavs();
    _locate();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  NearbyCat? _mapType(String s) {
    switch (s) {
      case 'hospital':
        return NearbyCat.hospital;
      case 'pharmacy':
        return NearbyCat.pharmacy;
      case 'police':
        return NearbyCat.police;
      case 'atm':
        return NearbyCat.atmBank;
      case 'restaurant':
        return NearbyCat.restaurant;
      default:
        return null;
    }
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
        _pos = null; // honest: no location -> no list, no sample
      }
    }
    if (!mounted) return;
    setState(() => _locating = false);
    if (_pos != null) await _fetch();
  }

  Future<void> _fetch() async {
    final pos = _pos;
    if (pos == null) return;
    final cat = _cat;
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .nearby(pos.lat, pos.lon, nearbyServerType(cat));
      if (!mounted || cat != _cat) return;
      final list = <NearbyPlace>[];
      for (final e in (r['places'] as List? ?? const [])) {
        if (e is! Map) continue;
        final p = NearbyPlace.fromServer(e.cast<String, dynamic>(), cat);
        if (p != null) list.add(p);
      }
      setState(() {
        _places = list;
        _attribution = '${r['attribution'] ?? ''}';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  double? _distOf(NearbyPlace p) {
    final pos = _pos;
    if (pos == null) return null;
    return Geolocator.distanceBetween(pos.lat, pos.lon, p.lat, p.lon);
  }

  List<NearbyPlace> _filtered(bool bn, DateTime now) {
    var list = (_showFav ? _favs.values : _places).where((p) {
      if (_query.isNotEmpty) {
        final q = _query.toLowerCase();
        if (!p.nameEn.toLowerCase().contains(q) &&
            !p.addrEn.toLowerCase().contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    switch (_sort) {
      case _Sort.distance:
        list.sort((a, b) => (_distOf(a) ?? 1e12).compareTo(_distOf(b) ?? 1e12));
        break;
      case _Sort.openFirst:
        int rank(NearbyPlace p) => p.openAt(now) == true ? 0 : 1;
        list.sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          if (r != 0) return r;
          return (_distOf(a) ?? 1e12).compareTo(_distOf(b) ?? 1e12);
        });
        break;
      case _Sort.name:
        list.sort((a, b) => a.name(bn).compareTo(b.name(bn)));
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final now = DateTime.now();

    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      bottomNavigationBar: const AdBannerSlot(screen: 'nearby'),
      appBar: AppBar(
        title: Text(t.nearby),
        actions: [
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
                  value: _Sort.openFirst,
                  checked: _sort == _Sort.openFirst,
                  child: Text(t.nearbySortOpen)),
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
              ),
              NearbyCategoryBar(
                showAll: false,
                selected: _showFav ? null : _cat,
                showFavourites: _showFav,
                onSelect: (c) {
                  if (c == null) return;
                  final changed = c != _cat;
                  setState(() {
                    _cat = c;
                    _showFav = false;
                    if (changed) _places = const [];
                  });
                  if (changed || _error != null) _fetch();
                },
                onToggleFavView: () => setState(() => _showFav = !_showFav),
              ),
              const SizedBox(height: Gap.sm),
              Expanded(child: _body(t, bn, now)),
            ]),
    );
  }

  Widget _body(AppLocalizations t, bool bn, DateTime now) {
    if (!_showFav) {
      if (_pos == null) {
        // honest: without the user's real position there is nothing true
        // to list — no sample rows.
        return StateMessage(
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
        );
      }
      if (_fetching && _places.isEmpty) return const SkeletonList();
      if (_error != null) {
        return StateMessage(
          key: const ValueKey('truth_nearby_error'),
          icon: Icons.cloud_off_rounded,
          title: t.truthNearbyLoadFailed,
          message: honestFailText(t, _error),
          action: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _fetch,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry),
          ),
        );
      }
    }
    final items = _filtered(bn, now);
    if (items.isEmpty) {
      return StateMessage(
        key: const ValueKey('truth_nearby_empty'),
        icon: _showFav ? Icons.star_border_rounded : Icons.search_off_rounded,
        title: _showFav
            ? t.nearbyNoFavourites
            : (_query.isEmpty ? t.truthNearbyNoneNearby : t.nothingFound),
        message: _showFav ? t.nearbyNoFavouritesHint : null,
      );
    }
    final showAttribution = !_showFav && _attribution.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg),
      itemCount: items.length + (showAttribution ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == items.length) {
          return Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.truthNearbySource(_attribution),
                key: const ValueKey('truth_nearby_attribution'),
                style: AType.bodySmall.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          );
        }
        final p = items[i];
        return NearbyPlaceCard(
          place: p,
          bn: bn,
          distanceMeters: _distOf(p),
          favourite: _favs.containsKey(p.id),
          onToggleFav: () => _toggleFav(p),
          now: now,
        );
      },
    );
  }
}
