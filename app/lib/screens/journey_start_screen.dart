import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../vehicle/veh_map.dart' show VehMapConfig;
import '../widgets/journey_api.dart';
import '../widgets/journey_dest_sheets.dart';
import '../widgets/journey_ride.dart';
import '../widgets/permission_reason.dart';
import 'guardian_journey_screen.dart';
import 'journey_live_screen.dart';
import 'journey_map_pick_screen.dart';
import 'journey_settings_screen.dart';
import 'journey_watch_screen.dart';
import 'messenger/messenger_home_screen.dart';
import '../services/journey_tracker.dart' show kPhonesKey;
import 'package:assisto/widgets/app_sheet.dart';
import '../services/action_feedback.dart'; // db1

/// Start a Safe Journey: where to (saved Home/School/Office, current
/// location, a pasted Google Maps link, place search when the server has a
/// geocoder, the map when tiles are configured), by when, who watches (My
/// Circle, one tap each or all), and the ride (CNG/bike/car…, Pathao/Uber,
/// plate, driver). journey2: a destination WITHOUT a pin is allowed but said
/// honestly — arrival is then not noticed by itself.
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

  Map<String, dynamic>? _dest; // {name, lat, lng} — a PIN when lat/lng set
  final _destName = TextEditingController();
  TimeOfDay _eta = TimeOfDay.now().replacing(
      hour: (TimeOfDay.now().hour + 1) % 24);
  String? _mode;
  String? _app;
  final _plate = TextEditingController();
  final _driverName = TextEditingController();
  final _driverPhone = TextEditingController();
  int _graceMin = 10;
  bool _routeDeviation = false;
  int _retentionHours = 24;
  // journey100: night trip (tighter grace) defaults on between 20:00-06:00
  bool _night = DateTime.now().hour >= 20 || DateTime.now().hour < 6;
  bool _stopAlert = true;
  bool _loading = true;
  bool _starting = false;
  // journey2: what this server/phone can offer for picking a destination
  bool _canSearch = false;
  VehMapConfig _map = const VehMapConfig();
  ({double lat, double lng})? _here; // last known, never prompts on open

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _destName.dispose();
    _plate.dispose();
    _driverName.dispose();
    _driverPhone.dispose();
    super.dispose();
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
    try {
      _canSearch = (await api.journeyGeocode(''))['available'] == true;
    } catch (_) {} // best-effort: no search box offline (link / saved / map still work)
    _map = await VehMapConfig.load(api); // never throws; empty = no map
    if (mounted) setState(() => _loading = false);
    _lastKnown();
  }

  /// Distance "from here" without ever prompting: only when location is
  /// already allowed, and only the phone's last known fix.
  Future<void> _lastKnown() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.whileInUse && perm != LocationPermission.always) return;
      final p = await Geolocator.getLastKnownPosition();
      if (p != null && mounted) setState(() => _here = (lat: p.latitude, lng: p.longitude));
    } catch (_) {
      // best-effort: no distance line, nothing else changes
    }
  }

  bool get _pinned => _dest?['lat'] is num && _dest?['lng'] is num;

  void _setDest(String name, double lat, double lng) {
    setState(() {
      if (name.isNotEmpty) _destName.text = name;
      _dest = {'name': _destName.text.trim(), 'lat': lat, 'lng': lng};
    });
  }

  Future<void> _useCurrentAsDest() async {
    final t = AppLocalizations.of(context);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) _snack(t.j100LocOffBody);
        return;
      }
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
      if (!mounted) return;
      _here = (lat: pos.latitude, lng: pos.longitude);
      _setDest(_destName.text.trim().isEmpty ? t.journeyDestPinned : '', pos.latitude,
          pos.longitude);
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.currentLocation', e); // db1
    }
  }

  Future<void> _pasteLink() async {
    final got = await showJourneyLinkSheet(context, context.read<AppState>().api);
    if (got != null && mounted) _setDest(got.name, got.lat, got.lng);
  }

  Future<void> _search() async {
    final got = await showJourneySearchSheet(context, context.read<AppState>().api,
        lat: _here?.lat, lng: _here?.lng);
    if (got != null && mounted) _setDest(got.name, got.lat, got.lng);
  }

  Future<void> _pickOnMap() async {
    final got = await Navigator.of(context).push<({double lat, double lng})>(
        MaterialPageRoute(
            builder: (_) => JourneyMapPickScreen(
                config: _map,
                lat: (_dest?['lat'] as num?)?.toDouble() ?? _here?.lat,
                lng: (_dest?['lng'] as num?)?.toDouble() ?? _here?.lng)));
    if (got != null && mounted) {
      _setDest(_destName.text.trim().isEmpty
          ? AppLocalizations.of(context).journeyDestPinned : '', got.lat, got.lng);
    }
  }

  Future<void> _savePlace() async {
    final t = AppLocalizations.of(context);
    if (!_pinned) return;
    final have = _places.map(jPlaceKind).toSet();
    final first = kPlaceKinds.firstWhere((k) => !have.contains(k), orElse: () => 'other');
    final pick = await showJourneySavePlaceSheet(context,
        kind: first,
        name: _destName.text.trim() == t.journeyDestPinned ? '' : _destName.text.trim());
    if (pick == null || !mounted) return;
    try {
      final api = context.read<AppState>().api;
      await api.saveSavedPlace({
        'kind': pick.kind,
        'label': pick.kind == 'other' ? pick.name : pick.kind,
        'name': pick.name.isNotEmpty ? pick.name : jKindLabel(t, pick.kind),
        'lat': _dest!['lat'],
        'lng': _dest!['lng'],
      });
      final rows = await api.savedPlaces();
      if (!mounted) return;
      setState(() => _places = rows);
      _snack(t.j2SavePlaceDone);
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.savePlace', e);
    }
  }

  Future<void> _removePlace(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final id = (p['id'] as num?)?.toInt();
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.j2PlaceRemoveTitle(jPlaceLabel(t, p))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const ValueKey('j2_place_remove_ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.j2PlaceRemove)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.deleteSavedPlace(id);
      if (!mounted) return;
      setState(() => _places.removeWhere((x) => x['id'] == p['id']));
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.removePlace', e);
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  double? get _distM {
    if (!_pinned || _here == null) return null;
    return jDistanceM(_here!.lat, _here!.lng, (_dest!['lat'] as num).toDouble(),
        (_dest!['lng'] as num).toDouble());
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
    final ride = <String, dynamic>{
      if (_plate.text.trim().isNotEmpty) 'plate': _plate.text.trim(),
      if (_mode != null) 'mode': _mode,
      if (_app != null) 'app': _app,
      if (_driverName.text.trim().isNotEmpty) 'driver_name': _driverName.text.trim(),
      if (_driverPhone.text.trim().isNotEmpty) 'driver_phone': _driverPhone.text.trim(),
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
            etaIso: eta.toUtc().toIso8601String(), // sjfix: absolute instant, not phone-local wall time
            watcherIds: _selectedWatchers.toList(),
            mode: _mode,
            vehicle: ride.isEmpty ? null : ride,
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

  Widget _h(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
      );

  Widget _intro(AppLocalizations t, ColorScheme cs) => Container(
        key: const ValueKey('j2_intro'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.verified_user_rounded, color: cs.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.j2IntroTitle,
                  style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Text(t.j2IntroBody, style: AType.bodyMedium),
            ]),
          ),
        ]),
      );

  Widget _pinCard(AppLocalizations t, ColorScheme cs) {
    if (_pinned) {
      final d = _distM;
      return Container(
        key: const ValueKey('j2_pinned'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
            color: Brand.successFill.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(Radii.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.where_to_vote_rounded, color: Brand.successFill),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(t.j2Pinned, style: AType.bodyMedium)),
            IconButton(
                key: const ValueKey('j2_unpin'),
                tooltip: t.j2Unpin,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() => _dest = null)),
          ]),
          if (d != null)
            Text(t.j2PinnedFar(jKm(context, d)),
                style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          OutlinedButton.icon(
            key: const ValueKey('j2_save_place'),
            icon: const Icon(Icons.bookmark_add_rounded),
            label: Text(t.j2SavePlace),
            onPressed: _savePlace,
          ),
        ]),
      );
    }
    if (_destName.text.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('j2_no_pin'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: Brand.warnInk(context).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline_rounded, color: Brand.warnInk(context)),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(t.j2NoPin, style: AType.bodyMedium)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(t.journeyStartTitle)),
          body: const Center(child: CircularProgressIndicator()));
    }
    final d = _distM;
    final rough = d == null ? null : jRoughMinutes(d, _mode);
    final ids = _watchers.map((m) => (m['id'] as num?)?.toInt()).whereType<int>().toList();
    final allOn = ids.isNotEmpty && ids.every(_selectedWatchers.contains);
    return Scaffold(
      appBar: AppBar(title: Text(t.journeyStartTitle), actions: [
        IconButton(
            key: const ValueKey('j100_watching'),
            icon: const Icon(Icons.visibility_rounded),
            tooltip: t.j100Watching,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const JourneyWatchScreen(fromStart: true)))),
        IconButton(
            key: const ValueKey('gj_entry'),
            icon: const Icon(Icons.family_restroom_rounded),
            tooltip: t.gjTitle,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const GuardianJourneyScreen()))),
        IconButton(
            key: const ValueKey('j2_settings'),
            icon: const Icon(Icons.tune_rounded),
            tooltip: t.journeySettingsTitle,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const JourneySettingsScreen()))),
      ]),
      // the whole (short) form is built at once: no lazy rows below the fold
      body: ListView(
          cacheExtent: 4000,
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        _intro(t, cs),
        const SizedBox(height: Gap.lg),
        _h(t.journeyDestSection),
        if (_places.isNotEmpty)
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final p in _places)
              Semantics(
                label: jPlaceLabel(t, p),
                hint: t.j2PlaceLongPress,
                child: GestureDetector(
                  onLongPress: () => _removePlace(p),
                  child: ActionChip(
                    key: ValueKey('j2_place_${p['id']}'),
                    avatar: Icon(jPlaceIcon(jPlaceKind(p)), size: 18),
                    label: Text(jPlaceLabel(t, p)),
                    onPressed: () {
                      final lat = (p['lat'] as num?)?.toDouble();
                      final lng = (p['lng'] as num?)?.toDouble();
                      if (lat == null || lng == null) {
                        setState(() {
                          _destName.text = jPlaceLabel(t, p);
                          _dest = null;
                        });
                      } else {
                        _destName.text = jPlaceLabel(t, p);
                        _setDest('', lat, lng);
                      }
                    },
                  ),
                ),
              ),
          ])
        else
          Text(t.j2PlacesEmpty,
              style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        TextField(
            key: const ValueKey('j100_dest'),
            controller: _destName,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: t.journeyDestLabel,
                suffixIcon: IconButton(
                    icon: const Icon(Icons.my_location_rounded),
                    tooltip: t.journeyUseCurrent,
                    onPressed: _useCurrentAsDest))),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          OutlinedButton.icon(
              key: const ValueKey('j2_paste_link'),
              icon: const Icon(Icons.link_rounded),
              label: Text(t.j2PasteLink),
              onPressed: _pasteLink),
          if (_canSearch)
            OutlinedButton.icon(
                key: const ValueKey('j2_search'),
                icon: const Icon(Icons.search_rounded),
                label: Text(t.j2Search),
                onPressed: _search),
          if (_map.hasTiles)
            OutlinedButton.icon(
                key: const ValueKey('j2_pick_map'),
                icon: const Icon(Icons.map_rounded),
                label: Text(t.j2PickMap),
                onPressed: _pickOnMap),
        ]),
        if (!_map.hasTiles)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.j2NoMapNote,
                key: const ValueKey('j2_no_map'),
                style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          ),
        const SizedBox(height: Gap.sm),
        _pinCard(t, cs),
        const Divider(height: 28),

        _h(t.journeyEtaSection),
        OutlinedButton.icon(
          icon: const Icon(Icons.schedule_rounded),
          label: Text(t.journeyEtaBy(_eta.format(context))),
          onPressed: () async {
            final picked = await showTimePicker(context: context, initialTime: _eta);
            if (picked != null) setState(() => _eta = picked);
          },
        ),
        if (rough != null) ...[
          const SizedBox(height: Gap.xs),
          Text(t.j2Rough(jDigits(context, rough)),
              key: const ValueKey('j2_rough'),
              style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
                key: const ValueKey('j2_rough_use'),
                onPressed: () => setState(() => _eta = TimeOfDay.fromDateTime(
                    DateTime.now().add(Duration(minutes: rough + 10)))),
                child: Text(t.j2RoughUse)),
          ),
        ],
        const Divider(height: 28),

        Row(children: [
          Expanded(child: _h(t.journeyWatchersSection)),
          if (ids.length > 1)
            TextButton(
                key: const ValueKey('j2_all'),
                onPressed: () => setState(() {
                      if (allOn) {
                        _selectedWatchers.clear();
                      } else {
                        _selectedWatchers.addAll(ids);
                      }
                    }),
                child: Text(allOn ? t.j2SelectNone : t.j2SelectAll)),
        ]),
        // truth: no watcher = nobody can be alerted. Not a dead end: one tap
        // to add a family member, then the list reloads on return.
        if (_watchers.isEmpty) ...[
          Text(t.journeyNoWatchers, style: TextStyle(color: cs.onSurfaceVariant)),
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
        Text(t.j2NoAppPeople,
            style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
        const Divider(height: 28),

        ExpansionTile(
          key: const ValueKey('j2_ride'),
          tilePadding: EdgeInsets.zero,
          title: Text(t.journeyRideSection),
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('j2_mode'),
              initialValue: _mode,
              isExpanded: true,
              decoration: InputDecoration(labelText: t.journeyModeLabel),
              items: [
                for (final m in kJourneyModes)
                  DropdownMenuItem(value: m, child: Text(jModeLabel(t, m))),
              ],
              onChanged: (v) => setState(() => _mode = v),
            ),
            const SizedBox(height: Gap.sm),
            DropdownButtonFormField<String>(
              key: const ValueKey('j2_app'),
              initialValue: _app,
              isExpanded: true,
              decoration: InputDecoration(labelText: t.j2AppLabel),
              items: [
                DropdownMenuItem<String>(value: null, child: Text(t.j2AppNone)),
                for (final a in kRideApps)
                  DropdownMenuItem(value: a, child: Text(jAppLabel(t, a))),
              ],
              onChanged: (v) => setState(() => _app = v),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
                key: const ValueKey('j2_plate'),
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(labelText: t.journeyPlateLabel)),
            const SizedBox(height: Gap.sm),
            TextField(
                key: const ValueKey('j2_driver_name'),
                controller: _driverName,
                decoration: InputDecoration(labelText: t.j2DriverName)),
            const SizedBox(height: Gap.sm),
            TextField(
                key: const ValueKey('j2_driver_phone'),
                controller: _driverPhone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: t.j2DriverPhone)),
            const SizedBox(height: Gap.xs),
            Text(t.j2RideHint,
                style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(t.journeyAdvancedSection),
          children: [
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.journeyGraceLabel(jDigits(context, _graceMin)))),
            Slider(
                value: _graceMin.toDouble(),
                min: 0,
                max: 60,
                divisions: 12,
                label: jDigits(context, _graceMin),
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
                subtitle: Text(t.j100StopAlertDesc(jDigits(context, 20))),
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
                title: Text(t.journeyRetentionLabel(jDigits(context, _retentionHours)))),
            Slider(
                value: _retentionHours.toDouble(),
                min: 0,
                max: 168,
                divisions: 14,
                label: jDigits(context, _retentionHours),
                onChanged: (v) => setState(() => _retentionHours = v.round())),
            Text(t.journeyRetentionNote,
                style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
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
