import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/journey_api.dart';
import '../widgets/permission_reason.dart';
import 'journey_live_screen.dart';
import 'journey_watch_screen.dart';
import 'messenger/messenger_home_screen.dart';
import '../services/journey_tracker.dart' show kPhonesKey;
import '../services/action_feedback.dart'; // db1

/// Start a Safe Journey (item 1 + 3): pick a destination (saved place or map
/// lat/lng), an expected-arrival time, the watchers (circle members), and
/// optional ride details (item 3 — CNG/rickshaw plate). One-tap presets reuse
/// saved places. Watchers are the ONLY audience.
/// The watcher picker's rows from GET /circle/members. The server answers
/// `{"results": [...]}` with each edge's `state`; only accepted circle members
/// can watch. (sjfix: this used to read `members`/`accepted` + `status`, keys
/// the server never sends, so the picker was always empty.)
List<Map<String, dynamic>> journeyWatcherRows(Object? r) {
  final raw = r is List
      ? r
      : (r is Map ? (r['results'] ?? r['members'] ?? r['accepted']) : null);
  if (raw is! List) return [];
  return raw
      .whereType<Map>()
      .map((m) => m.cast<String, dynamic>())
      .where((m) => '${m['state'] ?? m['status'] ?? 'accepted'}' == 'accepted')
      .toList();
}

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
  // journey100: night trip (tighter grace) defaults on between 20:00-06:00
  bool _night = DateTime.now().hour >= 20 || DateTime.now().hour < 6;
  bool _stopAlert = true;
  bool _loading = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    // journey100: a journey already running -> straight back to it (a push
    // "Are you OK?" / the notification lands here too)
    try {
      final a = await api.journeyActive();
      final id = (a['id'] as num?)?.toInt();
      if (id != null && mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (_) => JourneyLiveScreen(journeyId: id)));
        return;
      }
    } catch (_) {
      // best-effort: offline — the start form still loads below
    }
    try {
      _places = await api.savedPlaces();
    } catch (_) {} // best-effort: no saved places offline, form still works
    try {
      final r = await api.getJson('/circle/members');
      _watchers = journeyWatcherRows(r);
    } catch (_) {} // best-effort: offline -> empty list shows the add-family step
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
    // location for the live share (while-in-use only; the journey's own
    // foreground service keeps it going with the screen off)
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && mounted &&
          await showPermissionReason(context, PermKind.location)) {
        perm = await Geolocator.requestPermission();
      }
    } catch (_) {
      // best-effort: the live screen says "location is off" if it stays off
    }
    if (!mounted) return;
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
            night: _night,
            stopAlertMin: _stopAlert ? 20 : 0,
          );
      final id = (r['id'] as num?)?.toInt();
      final phones = _watchers
          .where((m) => _selectedWatchers.contains((m['id'] as num?)?.toInt()))
          .map((m) => (m['phone'] ?? '').toString())
          .where((p) => p.isNotEmpty)
          .join(',');
      await Settings.setString(kPhonesKey, phones);
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
      appBar: AppBar(title: Text(t.journeyStartTitle), actions: [
        IconButton(
            key: const ValueKey('j100_watching'),
            icon: const Icon(Icons.visibility_rounded),
            tooltip: t.j100Watching,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const JourneyWatchScreen()))),
      ]),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Text(t.journeyDestSection,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.sm),
        if (_places.isNotEmpty)
          Wrap(spacing: 8, children: [
            for (final p in _places)
              ActionChip(
                avatar: const Icon(Icons.place_rounded, size: 18),
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
        const SizedBox(height: Gap.sm),
        TextField(
            key: const ValueKey('j100_dest'),
            controller: _destName,
            decoration: InputDecoration(
                labelText: t.journeyDestLabel,
                suffixIcon: IconButton(
                    icon: const Icon(Icons.my_location_rounded),
                    tooltip: t.journeyUseCurrent,
                    onPressed: _useCurrentAsDest))),
        const Divider(height: 28),

        Text(t.journeyEtaSection,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.xs),
        OutlinedButton.icon(
          icon: const Icon(Icons.schedule_rounded),
          label: Text(t.journeyEtaBy(_eta.format(context))),
          onPressed: () async {
            final picked = await showTimePicker(context: context, initialTime: _eta);
            if (picked != null) setState(() => _eta = picked);
          },
        ),
        const Divider(height: 28),

        Text(t.journeyWatchersSection,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: Gap.xs),
        // truth: no watcher = nobody can be alerted. Not a dead end: one tap
        // to add a family member, then the list reloads on return.
        if (_watchers.isEmpty) ...[
          Text(t.journeyNoWatchers, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              key: const ValueKey('truth_journey_add_watcher'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(t.truthJourneyAddFamily),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const MessengerHomeScreen(startAdd: true)));
                if (mounted) _load();
              },
            ),
          ),
        ],
        ..._watchers.map((m) {
          final id = (m['id'] as num?)?.toInt();
          return CheckboxListTile(
            key: ValueKey('j100_w_$id'),
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
            const SizedBox(height: Gap.sm),
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
                key: const ValueKey('j100_night'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.j100Night),
                subtitle: Text(t.j100NightDesc),
                value: _night,
                onChanged: (v) => setState(() => _night = v)),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.j100StopAlert),
                subtitle: Text(t.j100StopAlertDesc(20)),
                value: _stopAlert,
                onChanged: (v) => setState(() => _stopAlert = v)),
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
                style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('j100_start'),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: Gap.lg)),
            onPressed: _starting ? null : _start,
            icon: _starting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.navigation_rounded),
            label: Text(t.journeyStartButton,
                style: AType.titleLarge),
          ),
        ),
      ]),
    );
  }
}
