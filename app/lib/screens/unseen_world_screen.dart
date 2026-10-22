import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';
import '../widgets/unseen_data.dart';
import '../widgets/unseen_card.dart';
import '../widgets/unseen_filters.dart';

/// Unseen World — ADVANCED travel companion (launch gap F / Appendix #41).
///
/// Surfaces lesser-known Bangladesh destinations (hidden gems) by division and
/// category, with destination cards (best time, how to get there, APPROX cost
/// + source, nearby, tip), search + filters, save/wishlist, "near me" (local
/// distance when GPS is granted), seasonal suggestions, trip ideas, share, and
/// an OFFLINE cache of saved destinations.
///
/// HONESTY: destinations come from the owner's own unseenbangladesh.com plus
/// open data (each card is source-noted). Cost ranges are stable, widely-
/// published APPROXIMATIONS — always labelled "approx" with their source, never
/// live prices and never invented. A top banner names the data sources. The
/// `/unseen` endpoint's attribution is shown when it loads; everything else
/// runs on the curated bundled dataset so the full UX works offline too.
class UnseenWorldScreen extends StatefulWidget {
  const UnseenWorldScreen({super.key});
  @override
  State<UnseenWorldScreen> createState() => _UnseenWorldScreenState();
}

class _UnseenWorldScreenState extends State<UnseenWorldScreen> {
  static const _savedKey = 'unseen_wishlist';
  static const _cacheKey = 'unseen_saved_cache'; // offline cache of saved
  final _searchCtrl = TextEditingController();

  TravelCat? _cat;
  Division? _division;
  bool _showWishlist = false;
  String _query = '';
  Set<String> _saved = {};

  Position? _pos;
  bool _permNeeded = false;
  bool _loading = true;

  String? _attribution; // from /unseen when online; null otherwise

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _loadSaved();
    await _loadAttribution();
    await _locate();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadSaved() async {
    final raw = await Settings.getString(_savedKey);
    if (raw != null && raw.isNotEmpty) {
      _saved = raw.split(',').where((e) => e.isNotEmpty).toSet();
    }
  }

  Future<void> _loadAttribution() async {
    try {
      final data = await context.read<AppState>().api.unseenCompanion();
      _attribution = data['attribution'] as String?;
    } catch (_) {
      // Offline / endpoint down — curated dataset + saved cache still work.
      _attribution = null;
    }
  }

  Future<void> _locate() async {
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
      _permNeeded = false;
    } catch (_) {
      _permNeeded = true; // honest: curated list still works without location
    }
  }

  Future<void> _toggleSave(Destination d) async {
    setState(() {
      _saved.contains(d.id) ? _saved.remove(d.id) : _saved.add(d.id);
    });
    await Settings.setString(_savedKey, _saved.join(','));
    await _writeCache();
  }

  // Offline cache of saved: a compact snapshot so wishlist details survive with
  // no network. Only stable, non-invented fields are cached.
  Future<void> _writeCache() async {
    final list = kDestinations
        .where((d) => _saved.contains(d.id))
        .map((d) => {
              'id': d.id,
              'name': d.name,
              'bestTime': d.bestTime,
              'howToGet': d.howToGet,
              'low': d.approxCostLow,
              'high': d.approxCostHigh,
              'source': d.source.label,
            })
        .toList();
    await Settings.setString(_cacheKey, jsonEncode(list));
  }

  double? _distOf(Destination d) {
    if (_pos == null) return null;
    return haversineMeters(_pos!.latitude, _pos!.longitude, d.lat, d.lon);
  }

  String _catLabel(AppLocalizations t, TravelCat c) => switch (c) {
        TravelCat.nature => t.unseenCatNature,
        TravelCat.historical => t.unseenCatHistorical,
        TravelCat.beach => t.unseenCatBeach,
        TravelCat.hill => t.unseenCatHill,
        TravelCat.religious => t.unseenCatReligious,
        TravelCat.island => t.unseenCatIsland,
        TravelCat.waterfall => t.unseenCatWaterfall,
      };

  String _divLabel(AppLocalizations t, Division d) => switch (d) {
        Division.dhaka => t.unseenDivDhaka,
        Division.chattogram => t.unseenDivChattogram,
        Division.sylhet => t.unseenDivSylhet,
        Division.khulna => t.unseenDivKhulna,
        Division.rajshahi => t.unseenDivRajshahi,
        Division.barishal => t.unseenDivBarishal,
        Division.rangpur => t.unseenDivRangpur,
        Division.mymensingh => t.unseenDivMymensingh,
      };

  String _seasonLabel(AppLocalizations t, Season s) {
    // A short localized window summary from the stable month list.
    const seasonOf = {
      12: 0, 1: 0, 2: 0, // winter
      3: 1, 4: 1, 5: 1, // summer
      6: 2, 7: 2, 8: 2, 9: 2, // monsoon
      10: 3, 11: 3, // autumn
    };
    final tags = <int>{for (final m in s.months) seasonOf[m] ?? 0};
    final labels = [
      t.unseenSeasonWinter,
      t.unseenSeasonSummer,
      t.unseenSeasonMonsoon,
      t.unseenSeasonAutumn,
    ];
    final parts = tags.toList()..sort();
    return parts.map((i) => labels[i]).join(' / ');
  }

  List<Destination> _results() => searchDestinations(
        division: _division,
        cat: _showWishlist ? null : _cat,
        query: _query,
        savedOnly: _showWishlist ? _saved.contains : null,
      )..sort((a, b) {
          if (_pos == null) return 0;
          return (_distOf(a) ?? 1e12).compareTo(_distOf(b) ?? 1e12);
        });

  Future<void> _shareDest(Destination d) async {
    final t = AppLocalizations.of(context);
    final text = [
      d.name,
      '${t.unseenBestSeason}: ${d.bestTime}',
      '${t.unseenHowToGet}: ${d.howToGet}',
      '${t.unseenApproxCost}: ${t.unseenCostRange('${d.approxCostLow}', '${d.approxCostHigh}')}',
      '${t.unseenSource}: ${d.source.label}',
      d.mapsUrl,
      '— Assisto',
    ].join('\n');
    try {
      await Share.share(text);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.copied)));
      }
    }
  }

  Future<void> _openDirections(Destination d) async {
    await Clipboard.setData(ClipboardData(text: d.directionsUrl));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).copied)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.unseenTitle),
        actions: [
          PopupMenuButton<Division?>(
            icon: const Icon(Icons.filter_alt_outlined),
            tooltip: t.unseenDivision,
            onSelected: (d) => setState(() => _division = d),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                  value: null,
                  checked: _division == null,
                  child: Text(t.unseenAllDivisions)),
              for (final d in Division.values)
                CheckedPopupMenuItem(
                    value: d,
                    checked: _division == d,
                    child: Text(_divLabel(t, d))),
            ],
          ),
        ],
      ),
      body: _loading ? const SkeletonList() : _content(t),
    );
  }

  Widget _content(AppLocalizations t) {
    final results = _results();
    return Column(children: [
      _attributionBanner(t),
      if (_permNeeded) _locationBanner(t),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _query = v.trim()),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: t.unseenSearchHint,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    }),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.md)),
          ),
        ),
      ),
      UnseenCategoryBar(
        selected: _cat,
        showWishlist: _showWishlist,
        onSelect: (c) => setState(() {
          _cat = c;
          _showWishlist = false;
        }),
        onToggleWishlist: () => setState(() => _showWishlist = !_showWishlist),
        catLabel: (c) => _catLabel(t, c),
      ),
      const SizedBox(height: Gap.sm),
      Expanded(child: _list(t, results)),
    ]);
  }

  Widget _attributionBanner(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: Brand.blue.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(children: [
        const Icon(Icons.travel_explore_outlined, size: 16, color: Brand.blue),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(
            _attribution ?? t.unseenAttribution,
            style: TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.3),
          ),
        ),
      ]),
    );
  }

  Widget _locationBanner(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: Brand.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 16, color: Brand.warning),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(t.unseenLocationBanner,
              style:
                  TextStyle(fontSize: 12, color: scheme.onSurface, height: 1.3)),
        ),
        TextButton(
            onPressed: () async {
              await _locate();
              if (mounted) setState(() {});
            },
            child: Text(t.unseenEnable)),
      ]),
    );
  }

  Widget _list(AppLocalizations t, List<Destination> results) {
    final month = DateTime.now().month;
    final seasonal = seasonalFor(month)
        .where((d) => !_saved.contains(d.id))
        .take(3)
        .toList();

    if (results.isEmpty) {
      return StateMessage(
        icon: _showWishlist ? Icons.bookmark_border : Icons.search_off,
        title: _showWishlist ? t.unseenNoWishlist : t.nothingFound,
        message: _showWishlist ? t.unseenNoWishlistHint : null,
      );
    }

    final showExtras = !_showWishlist && _query.isEmpty && _cat == null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg),
      children: [
        if (showExtras && seasonal.isNotEmpty) ...[
          _sectionHeader(Icons.wb_sunny_outlined, t.unseenSeasonalNow),
          for (final d in seasonal) _card(t, d),
          const SizedBox(height: Gap.sm),
        ],
        if (showExtras) ...[
          _sectionHeader(Icons.map_outlined, t.unseenTripIdeas),
          for (final trip in kTripIdeas) _tripCard(t, trip),
          const SizedBox(height: Gap.sm),
          _sectionHeader(Icons.explore_outlined, t.unseenDestinations),
        ],
        for (final d in results)
          if (!(showExtras && seasonal.any((s) => s.id == d.id))) _card(t, d),
      ],
    );
  }

  Widget _sectionHeader(IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, Gap.md, 0, Gap.sm),
      child: Row(children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      ]),
    );
  }

  Widget _card(AppLocalizations t, Destination d) => UnseenCard(
        dest: d,
        divisionLabel: _divLabel(t, d.division),
        catLabel: _catLabel(t, d.cat),
        seasonLabel: _seasonLabel(t, d.season),
        distanceMeters: _distOf(d),
        saved: _saved.contains(d.id),
        onToggleSave: () => _toggleSave(d),
        onDirections: () => _openDirections(d),
        onShare: () => _shareDest(d),
      );

  Widget _tripCard(AppLocalizations t, TripIdea trip) {
    final scheme = Theme.of(context).colorScheme;
    final meta = catMeta(trip.cat);
    final stops = trip.stops();
    final (lo, hi) = trip.approxCost();
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: meta.tint.withValues(alpha: 0.16),
          child: Icon(meta.icon, color: meta.tint, size: 20),
        ),
        title: Text(stops.map((s) => s.name).join(' → '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(
            '${t.unseenTripDays(trip.days)}  •  ${t.unseenApproxCost}: ${t.unseenCostRange('$lo', '$hi')}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.md, Gap.sm),
        children: [
          for (final s in stops)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(catMeta(s.cat).icon,
                  size: 18, color: catMeta(s.cat).tint),
              title: Text(s.name, style: const TextStyle(fontSize: 13)),
              subtitle: Text('${s.bestTime}  •  ${s.source.label}',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(t.unseenApproxNote,
                style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
