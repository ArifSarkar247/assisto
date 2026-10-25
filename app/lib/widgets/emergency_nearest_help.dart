import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../services/action_feedback.dart'; // db1

/// Nearest-help finder. Reuses the EXISTING /nearby provider (api.nearby) to
/// list the closest hospital + police station, with one-tap directions and
/// (when available) one-tap call. No new backend.
///
/// Full empty / loading / error / permission states.
class EmergencyNearestHelp extends StatefulWidget {
  const EmergencyNearestHelp({super.key});

  @override
  State<EmergencyNearestHelp> createState() => _EmergencyNearestHelpState();
}

class _EmergencyNearestHelpState extends State<EmergencyNearestHelp> {
  bool _loading = false;
  String? _error; // localised message key resolved to text
  List<Map<String, dynamic>> _places = [];

  Future<void> _find() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() {
          _loading = false;
          _error = t.locationOff;
        });
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        setState(() {
          _loading = false;
          _error = t.locationNeeded;
        });
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final api = context.read<AppState>().api;
      final results = <Map<String, dynamic>>[];
      // Only request types the /nearby provider actually supports today
      // (hospital, pharmacy). A dedicated 'police' type is a backend ask —
      // see the integration note — until then 999/100 cover police contact.
      for (final type in ['hospital', 'pharmacy']) {
        try {
          final r = await api.nearby(pos.latitude, pos.longitude, type);
          final items = ((r['results'] ?? r['places'] ?? []) as List)
              .cast<Map<String, dynamic>>();
          for (final p in items.take(2)) {
            results.add({...p, 'kind': type});
          }
        } catch (_) {/* best-effort: one type failing shouldn't kill the other */}
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _places = results;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _directions(Map<String, dynamic> p) async {
    final lat = p['lat'], lng = p['lng'] ?? p['lon'];
    if (lat == null || lng == null) return;
    await openForUser(context, Uri.parse('https://maps.google.com/?daddr=$lat,$lng'), // db1
        where: 'nearestHelp.directions', mode: LaunchMode.externalApplication);
  }

  Future<void> _call(String phone) async {
    await openForUser(context, Uri.parse('tel:$phone'), where: 'nearestHelp.call'); // db1
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(Gap.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_error != null)
        Container(
          padding: const EdgeInsets.all(Gap.md),
          margin: const EdgeInsets.only(bottom: Gap.sm),
          decoration: BoxDecoration(
            color: Brand.danger.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Text(_error!,
              style: const TextStyle(color: Brand.danger, fontSize: 13)),
        ),
      if (_places.isEmpty && _error == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Text(t.emergencyNearestHint,
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
        ),
      for (final p in _places)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            leading: Icon(p['kind'] == 'pharmacy'
                ? Icons.local_pharmacy_rounded
                : Icons.local_hospital_rounded),
            title: Text('${p['name'] ?? ''}'),
            subtitle: Text(
              [
                if (p['kind'] == 'pharmacy')
                  t.emergencyNearestPharmacy
                else
                  t.emergencyNearestHospital,
                if ((p['address'] ?? '').toString().trim().isNotEmpty)
                  '${p['address']}',
              ].join(' · '),
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if ((p['phone'] ?? '').toString().trim().isNotEmpty)
                IconButton(
                    tooltip: t.call,
                    icon: const Icon(Icons.call_rounded, color: Brand.success),
                    onPressed: () => _call('${p['phone']}')),
              IconButton(
                  tooltip: t.emergencyDirections,
                  icon: const Icon(Icons.directions_rounded),
                  onPressed: () => _directions(p)),
            ]),
          ),
        ),
      FilledButton.tonalIcon(
        onPressed: _find,
        icon: const Icon(Icons.search_rounded),
        label: Text(_places.isEmpty
            ? t.emergencyFindNearest
            : t.emergencyRefreshNearest),
      ),
    ]);
  }
}
