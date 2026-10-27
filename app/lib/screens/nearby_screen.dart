import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';
import '../widgets/nearby_data.dart';
import '../widgets/nearby_category_bar.dart';
import '../widgets/nearby_place_card.dart';

/// ADVANCED Nearby module.
///
/// Map / Places APIs are KEY-GATED (owner Google Maps key). This screen runs
/// FULLY on a curated BD dataset now (categories, open/closed, call,
/// directions, favourites, search/filter/sort, nearest-X from emergency), and
/// shows an honest banner that it goes live once a Maps key + location are
/// enabled. Distance is computed locally when GPS permission is granted;
/// without it the UX stays usable (no distance column, honest prompt).
enum _Sort { distance, openFirst, name }

class NearbyScreen extends StatefulWidget {
  /// From emergency / quick-access context: 'hospital', 'pharmacy', 'police',
  /// 'atm', 'restaurant', 'lodging'… Pre-selects the matching category.
  final String placeType;
  const NearbyScreen({super.key, this.placeType = ''});
  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  static const _favKey = 'nearby_favourites';
  final _searchCtrl = TextEditingController();

  NearbyCat? _cat;
  bool _showFav = false;
  _Sort _sort = _Sort.distance;
  String _query = '';
  Set<String> _favs = {};

  Position? _pos; // null = no location yet
  bool _loading = true;
  bool _permNeeded = false;

  @override
  void initState() {
    super.initState();
    _cat = _mapType(widget.placeType);
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
    final raw = await Settings.getString(_favKey);
    if (raw != null && raw.isNotEmpty && mounted) {
      setState(() => _favs = raw.split(',').where((e) => e.isNotEmpty).toSet());
    }
  }

  Future<void> _toggleFav(String id) async {
    setState(() {
      _favs.contains(id) ? _favs.remove(id) : _favs.add(id);
    });
    await Settings.setString(_favKey, _favs.join(','));
  }

  Future<void> _locate() async {
    setState(() {
      _loading = true;
      _permNeeded = false;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'off';
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        if (mounted && !await showPermissionReason(context, PermKind.location)) {
          throw 'perm';
        }
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw 'perm';
      }
      _pos = await Geolocator.getCurrentPosition();
    } catch (_) {
      _permNeeded = true; // honest: no location → curated list still shows
    }
    if (mounted) setState(() => _loading = false);
  }

  double _haversine(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLa = rad(la2 - la1), dLo = rad(lo2 - lo1);
    final a = math.sin(dLa / 2) * math.sin(dLa / 2) +
        math.cos(rad(la1)) *
            math.cos(rad(la2)) *
            math.sin(dLo / 2) *
            math.sin(dLo / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  double? _distOf(NearbyPlace p) {
    if (_pos == null) return null;
    return _haversine(_pos!.latitude, _pos!.longitude, p.lat, p.lon);
  }

  List<NearbyPlace> _filtered(bool bn, DateTime now) {
    var list = kNearbyMock.where((p) {
      if (_showFav) return _favs.contains(p.id);
      if (_cat != null && p.cat != _cat) return false;
      if (_query.isNotEmpty) {
        final q = _query.toLowerCase();
        if (!p.nameEn.toLowerCase().contains(q) &&
            !p.addrEn.toLowerCase().contains(q)) return false;
      }
      return true;
    }).toList();

    switch (_sort) {
      case _Sort.distance:
        if (_pos != null) {
          list.sort((a, b) => (_distOf(a) ?? 1e12).compareTo(_distOf(b) ?? 1e12));
        }
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
      body: _loading
          ? const SkeletonList()
          : Column(children: [
              _banner(t),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
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
                            tooltip: AppLocalizations.of(context).f2ClearSearch,
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
                selected: _cat,
                showFavourites: _showFav,
                onSelect: (c) => setState(() {
                  _cat = c;
                  _showFav = false;
                }),
                onToggleFavView: () => setState(() => _showFav = !_showFav),
              ),
              const SizedBox(height: Gap.sm),
              Expanded(child: _list(t, bn, now)),
            ]),
    );
  }

  Widget _banner(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    // Honest: live Maps/Places is key-gated; we show curated data meanwhile.
    return Container(
      width: double.infinity,
      color: Brand.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(children: [
        const Icon(Icons.info_outline_rounded, size: 16, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            _permNeeded ? t.nearbyLocationBanner : t.nearbyMockBanner,
            style: AType.bodySmall.copyWith(color: scheme.onSurface, height: 1.3),
          ),
        ),
        if (_permNeeded)
          TextButton(onPressed: _locate, child: Text(t.nearbyEnable)),
      ]),
    );
  }

  Widget _list(AppLocalizations t, bool bn, DateTime now) {
    final items = _filtered(bn, now);
    if (items.isEmpty) {
      return StateMessage(
        icon: _showFav ? Icons.star_border_rounded : Icons.search_off_rounded,
        title: _showFav ? t.nearbyNoFavourites : t.nothingFound,
        message: _showFav ? t.nearbyNoFavouritesHint : null,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final p = items[i];
        return NearbyPlaceCard(
          place: p,
          bn: bn,
          distanceMeters: _distOf(p),
          favourite: _favs.contains(p.id),
          onToggleFav: () => _toggleFav(p.id),
          now: now,
        );
      },
    );
  }
}
