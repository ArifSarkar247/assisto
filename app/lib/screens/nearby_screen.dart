import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';

/// Nearby places (extra C). Gets GPS, asks the backend (Google Places → OSM
/// fallback). Shows real data only — never invented ratings.
class NearbyScreen extends StatefulWidget {
  final String placeType;
  const NearbyScreen({super.key, this.placeType = 'restaurant'});
  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  List<dynamic> _places = [];
  String _source = '';
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw 'location_off';
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        if (mounted &&
            !await showPermissionReason(context,
                icon: PermReasons.location.icon,
                reasonBn: PermReasons.location.bn,
                reasonEn: PermReasons.location.en)) {
          throw 'perm';
        }
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw 'perm';
      }
      final pos = await Geolocator.getCurrentPosition();
      final r = await context.read<AppState>().api
          .nearby(pos.latitude, pos.longitude, widget.placeType);
      _places = (r['places'] ?? []) as List;
      _source = (r['source'] ?? '').toString();
    } catch (e) {
      _err = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String t(String bn, String e) => en ? e : bn;
    final titles = {
      'restaurant': t('কাছে রেস্টুরেন্ট', 'Nearby restaurants'),
      'pharmacy': t('কাছে ফার্মেসি', 'Nearby pharmacies'),
      'atm': t('কাছে ATM', 'Nearby ATMs'),
      'hospital': t('কাছে হাসপাতাল', 'Nearby hospitals'),
      'lodging': t('কাছে হোটেল', 'Nearby hotels'),
    };
    return Scaffold(
      appBar: AppBar(title: Text(titles[widget.placeType] ?? t('আশেপাশে', 'Nearby'))),
      body: _loading
          ? const SkeletonList()
          : _err != null
              ? StateMessage(
                  icon: Icons.location_off,
                  tint: Theme.of(context).colorScheme.error,
                  title: t('লোকেশন লাগবে', 'Location needed'),
                  message: t('লোকেশন চালু করে অনুমতি দিন।',
                      'Turn on location and grant permission.'),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t('আবার', 'Retry'))))
              : _places.isEmpty
                  ? StateMessage(
                      icon: Icons.search_off,
                      title: t('কিছু পাওয়া যায়নি', 'Nothing found'))
                  : ListView(
                      padding: const EdgeInsets.all(Gap.md),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: Gap.sm, left: 4),
                          child: Text(
                              _source == 'osm'
                                  ? 'OpenStreetMap'
                                  : t('Google থেকে', 'via Google'),
                              style: TextStyle(fontSize: 11,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ),
                        for (final p in _places) _tile(p, t),
                      ],
                    ),
    );
  }

  Widget _tile(dynamic p, String Function(String, String) t) {
    final dist = p['distance_m'];
    final open = p['open_now'];
    final phone = (p['phone'] ?? '').toString();
    return Card(
      child: ListTile(
        title: Text(p['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          if (dist != null) '${(dist / 1000).toStringAsFixed(1)} km',
          if ((p['address'] ?? '').toString().isNotEmpty) p['address'],
          if (open == true) t('এখন খোলা', 'Open now'),
          if (p['rating'] != null) '★ ${p['rating']}',
        ].where((e) => e != null && e.toString().isNotEmpty).join(' · ')),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (phone.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.call, color: Colors.green),
                onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
          IconButton(
              icon: const Icon(Icons.map_outlined),
              onPressed: () => launchUrl(Uri.parse(p['maps'] ?? ''),
                  mode: LaunchMode.externalApplication)),
        ]),
      ),
    );
  }
}
