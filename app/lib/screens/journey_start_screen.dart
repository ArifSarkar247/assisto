import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/journey_api.dart';
import '../widgets/permission_reason.dart';
import 'journey_live_screen.dart';
import '../services/action_feedback.dart'; // db1

/// Start a Safe Journey (item 1 + 3): pick a destination (saved place or map
/// lat/lng), an expected-arrival time, the watchers (circle members), and
/// optional ride details (item 3 — CNG/rickshaw plate). One-tap presets reuse
/// saved places. Watchers are the ONLY audience.
class JourneyStartScreen extends StatefulWidget {
  const JourneyStartScreen({super.key});
  @override
  State<JourneyStartScreen> createState() => _JourneyStartScreenState();
}

class _JourneyStartScreenState extends State<JourneyStartScreen> {
  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _watchers = [];
  final Set<int> _selectedWatchers = {};

  Map<String, dynamic>? _dest; // {name, lat, lng}
  final _destName = TextEditingController();
  TimeOfDay _eta = TimeOfDay.now().replacing(
      hour: (TimeOfDay.now().hour + 1) % 24);
  String? _mode;
  final _plate = TextEditingController();
  int _graceMin = 10;
  bool _routeDeviation = false;
  int _retentionHours = 24;
  bool _loading = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      _places = await api.savedPlaces();
    } catch (_) {}
    try {
      final r = await api.getJson('/circle/members');
      _watchers = ((r['members'] ?? r['accepted'] ?? []) as List)
          .cast<Map<String, dynamic>>()
          .where((m) => (m['status'] ?? 'accepted') == 'accepted')
          .toList();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _useCurrentAsDest() async {
    final t = AppLocalizations.of(context);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        if (mounted && !await showPermissionReason(context, PermKind.location)) {
          return;
        }
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition();
      setState(() {
        _destName.text = t.journeyDestPinned;
        _dest = {
          'name': _destName.text,
          'lat': pos.latitude,
          'lng': pos.longitude
        };
      });
    } catch (e) {
      showActionFailed(context, 'journey.currentLocation', e); // db1
    }
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = _destName.text.trim();
    if (name.isEmpty && _dest == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.journeyNeedDest)));
      return;
    }
    if (_selectedWatchers.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.journeyNeedWatcher)));
      return;
    }
    final now = DateTime.now();
    var eta = DateTime(now.year, now.month, now.day, _eta.hour, _eta.minute);
    if (eta.isBefore(now)) eta = eta.add(const Duration(days: 1));
    final dest = <String, dynamic>{
      'name': name.isEmpty ? (_dest?['name'] ?? '') : name,
      if (_dest?['lat'] != null) 'lat': _dest!['lat'],
      if (_dest?['lng'] != null) 'lng': _dest!['lng'],
    };
    setState(() => _starting = true);
    try {
      final r = await context.read<AppState>().api.journeyStart(
            destination: dest,
            etaIso: eta.toIso8601String(),
            watcherIds: _selectedWatchers.toList(),
            mode: _mode,
            vehicle: _plate.text.trim().isEmpty
                ? null
                : {'plate': _plate.text.trim(), 'mode': _mode},
            overdueGraceMin: _graceMin,
            routeDeviationOn: _routeDeviation,
            locationRetentionHours: _retentionHours,
          );
      final id = (r['id'] as num?)?.toInt();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => JourneyLiveScreen(journeyId: id ?? 0)));
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(t.journeyStartFailed)));
        setState(() => _starting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.journeyStartTitle)),
          body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.journeyStartTitle)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(t.journeyDestSection,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        if (_places.isNotEmpty)
          Wrap(spacing: 8, children: [
            for (final p in _places)
              ActionChip(
                avatar: const Icon(Icons.place, size: 18),
                label: Text((p['label'] ?? p['name'] ?? '').toString()),
                onPressed: () => setState(() {
                  _dest = {
                    'name': p['name'],
                    'lat': p['lat'],
                    'lng': p['lng']
                  };
                  _destName.text = (p['name'] ?? '').toString();
                }),
              ),
          ]),
        const SizedBox(height: 8),
        TextField(
            controller: _destName,
            decoration: InputDecoration(
                labelText: t.journeyDestLabel,
                suffixIcon: IconButton(
                    icon: const Icon(Icons.my_location),
                    tooltip: t.journeyUseCurrent,
                    onPressed: _useCurrentAsDest))),
        const Divider(height: 28),

        Text(t.journeyEtaSection,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.schedule),
          label: Text(t.journeyEtaBy(_eta.format(context))),
          onPressed: () async {
            final picked = await showTimePicker(context: context, initialTime: _eta);
            if (picked != null) setState(() => _eta = picked);
          },
        ),
        const Divider(height: 28),

        Text(t.journeyWatchersSection,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        if (_watchers.isEmpty)
          Text(t.journeyNoWatchers, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ..._watchers.map((m) {
          final id = (m['id'] as num?)?.toInt();
          return CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: id != null && _selectedWatchers.contains(id),
            title: Text((m['name'] ?? m['phone'] ?? '').toString()),
            onChanged: id == null
                ? null
                : (v) => setState(() {
                      if (v == true) {
                        _selectedWatchers.add(id);
                      } else {
                        _selectedWatchers.remove(id);
                      }
                    }),
          );
        }),
        const Divider(height: 28),

        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(t.journeyRideSection),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: InputDecoration(labelText: t.journeyModeLabel),
              items: [
                DropdownMenuItem(value: 'cng', child: Text(t.journeyModeCng)),
                DropdownMenuItem(
                    value: 'rickshaw', child: Text(t.journeyModeRickshaw)),
                DropdownMenuItem(value: 'car', child: Text(t.journeyModeCar)),
                DropdownMenuItem(value: 'bus', child: Text(t.journeyModeBus)),
                DropdownMenuItem(value: 'walk', child: Text(t.journeyModeWalk)),
              ],
              onChanged: (v) => setState(() => _mode = v),
            ),
            const SizedBox(height: 8),
            TextField(
                controller: _plate,
                decoration: InputDecoration(labelText: t.journeyPlateLabel)),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(t.journeyAdvancedSection),
          children: [
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.journeyGraceLabel(_graceMin))),
            Slider(
                value: _graceMin.toDouble(),
                min: 0,
                max: 60,
                divisions: 12,
                label: '$_graceMin',
                onChanged: (v) => setState(() => _graceMin = v.round())),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.journeyRouteDeviation),
                subtitle: Text(t.journeyRouteDeviationDesc),
                value: _routeDeviation,
                onChanged: (v) => setState(() => _routeDeviation = v)),
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.journeyRetentionLabel(_retentionHours))),
            Slider(
                value: _retentionHours.toDouble(),
                min: 0,
                max: 168,
                divisions: 14,
                label: '$_retentionHours',
                onChanged: (v) => setState(() => _retentionHours = v.round())),
            Text(t.journeyRetentionNote,
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: _starting ? null : _start,
            icon: _starting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.navigation),
            label: Text(t.journeyStartButton,
                style: const TextStyle(fontSize: 18)),
          ),
        ),
      ]),
    );
  }
}
