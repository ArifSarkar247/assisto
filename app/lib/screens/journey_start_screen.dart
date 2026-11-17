import 'dart:async';
import '../widgets/skeleton.dart' show SkeletonList;
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show ImageSource; // sjstart2
import '../theme.dart';
import '../ds/ds.dart';
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
import '../services/oem_guide.dart';
import 'battery_guidance_screen.dart';
import '../train/journey_transit.dart';
import '../widgets/journey_mode_section.dart';
import 'train/journey_train_pick_screen.dart';
import '../maps/address_resolver.dart'; // mapscost
import '../maps/maps_sdk.dart'; // mapscost
import '../maps/maps_api.dart'; // jsearch
import '../maps/place_search.dart'; // jsearch
import '../services/journey_habits.dart'; // sjstart2
import '../widgets/journey_plate_photo.dart'; // sjstart2
import '../widgets/journey_watcher_chips.dart'; // sjstart2

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

/// journey100b (owner real trip 2 Nov: "No location" for 15 min): does this
/// phone need the battery-saver / auto-start steps BEFORE the trip? Android
/// says so (background restricted, or battery optimisation still on), or the
/// brand is known to kill background apps (Xiaomi, Realme, Oppo, Vivo,
/// Samsung…) and the user has not been through the guide yet. Pure.
bool journeyNeedsBgSetup(OemInfo? i, {required bool guidedBefore}) {
  if (i == null) return false; // unknown phone: never block the start
  if (i.bgRestricted == true) return true;
  if (i.batteryOptIgnored != true) return true;
  return i.family != OemFamily.nearStock && !guidedBefore;
}

const String kJourneyBgGuidedKey = 'journey_bg_guided';

class JourneyStartScreen extends StatefulWidget {
  /// Native OEM bridge (tests pass a fake).
  final OemGuideNative? oem;

  /// sjstart2: a usual trip suggested by the "Going to Office?" notification
  /// (destination + mode filled in); [autoStart] = its "Start" button.
  final JourneySuggestion? suggest;
  final bool autoStart;

  /// Tests: swap the camera / gallery picker.
  final Future<Uint8List?> Function(ImageSource src)? platePicker;
  const JourneyStartScreen(
      {super.key, this.oem, this.suggest, this.autoStart = false, this.platePicker});
  @override
  State<JourneyStartScreen> createState() => _JourneyStartScreenState();
}

class _JourneyStartScreenState extends State<JourneyStartScreen> {
  List<Map<String, dynamic>> _places = [];
  List<Map<String, dynamic>> _watchers = [];
  final Set<int> _selectedWatchers = {};

  Map<String, dynamic>? _dest; // {name, lat, lng} — a PIN when lat/lng set
  final _destName = TextEditingController();
  // jsearch (owner 4 Nov): no made-up default. Filled from ONE Routes ETA
  // for the chosen travel mode once the destination is pinned (editable);
  // empty with a hint when road time is not available.
  TimeOfDay? _eta;
  int? _etaMin; // the Routes answer behind _eta ("about 1 h 20 min by car")
  bool _etaEdited = false; // the user picked the time: never overwrite it
  String _destAddress = '';
  // qjourney: the picked row's kind (district, airport, ...) -> the server's
  // arrival ring; set only by a pick from the search list
  String? _destKind, _pendingKind;
  String? _mode;
  String? _app;
  final _plate = TextEditingController();
  Uint8List? _platePhoto; // sjstart2: optional, sent to watchers after start
  bool _suggestOn = true; // sjstart2: "Going to Office?" suggestions
  // gap-safejourney: usual trips for right now, offered on this screen too
  List<JourneySuggestion> _usual = const [];
  bool _usualClosed = false;
  // gap-safejourney: "pick at least one" turns red only after Start was
  // pressed without anyone — not before the user has done anything
  bool _askedWatcher = false;
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
  PlaceSearchMode _psMode = PlaceSearchMode.off; // jsearch
  VehMapConfig _map = const VehMapConfig();
  bool _gmaps = false; // mapscost: Google Maps SDK key built in (free map display)
  ({double lat, double lng})? _here; // last known, never prompts on open
  // sjstart2 (owner V2 "From"): null = My current location (shown as an
  // area name from OUR list, free); else a picked start (saved/search/map)
  PlacePick? _fromPick;
  String? _hereArea;
  ({double lat, double lng})? get _origin =>
      _fromPick == null ? _here : (lat: _fromPick!.lat, lng: _fromPick!.lng);
  // journeymode: "How are you going?" + train + destination alarm
  final JourneyModeController _jm = JourneyModeController();

  @override
  void initState() {
    super.initState();
    _load();
    _probeOem();
    unawaited(_jm.init().then((_) {
      if (mounted && _jm.travel != null) setState(() => _mode = _jm.travel);
      if (mounted && _jm.train != null) _applyTrain(_jm.train!);
    }));
  }

  /// journeymode: the train tracker's picker -> train + "where do you get
  /// off?" -> that station becomes the destination (pinned) and the
  /// estimated arrival (+15 min slack) the ETA.
  Future<void> _pickTrain() async {
    final p = await pickJourneyTrain(context);
    if (p == null || !mounted) return;
    _applyTrain(p);
  }

  void _applyTrain(JourneyTrainPick p) {
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    _jm.setTrain(p);
    _destName.text = p.station.name(bn);
    _setDest('', p.station.lat, p.station.lng);
    final at = p.stationAt;
    if (at != null) {
      setState(() => _eta = TimeOfDay.fromDateTime(at.add(const Duration(minutes: 15))));
    }
  }

  // journey100b: read the phone's background rules once, early, so tapping
  // Start never waits on the platform channel.
  OemInfo? _oemInfo;
  bool _bgGuided = false;

  Future<void> _probeOem() async {
    try {
      final info = await (widget.oem ?? const ChannelOemGuideNative()).info();
      final guided = await Settings.getBool(kJourneyBgGuidedKey, false);
      if (!mounted) return;
      _oemInfo = info;
      _bgGuided = guided;
    } catch (_) {
      // best-effort: unknown phone -> no pre-start sheet
    }
  }

  @override
  void dispose() {
    _destName.dispose();
    _plate.dispose();
    _driverName.dispose();
    _driverPhone.dispose();
    _jm.dispose();
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
    // speedproof: the form's reads go out TOGETHER — they used to wait for
    // each other (places -> members -> habits -> maps/status -> map config:
    // ~0.7 s of chained round trips in CI, several seconds on 3G).
    final placesF = api
        .savedPlaces()
        .then<List<Map<String, dynamic>>?>((v) => v, onError: (Object _) => null);
    final membersF = api.getJson('/circle/members')
        .then<Map<String, dynamic>?>((v) => v, onError: (Object _) => null);
    final memoryF = JourneyWatcherMemory.load().catchError((Object _) => <int>{});
    final suggestF = JourneyHabits.enabled(); // sjstart2
    final psModeF = placeSearchMode(api); // jsearch: never throws
    final mapF = VehMapConfig.load(api); // never throws; empty = no map
    final gmapsF = MapsSdk.available(); // mapscost: never throws
    final places = await placesF; // best-effort: no saved places offline, form still works
    if (places != null) {
      _places = places;
      try {
        _places = sjgOrderPlaces(_places, await PlaceRecents.ranked()); // gap-safejourney
      } catch (_) {} // best-effort: recents only reorder
    }
    try {
      final r = await membersF;
      if (r != null) {
        _watchers = journeyWatcherRows(r);
        // sjstart2: the last watchers again (still in the circle only)
        final again = JourneyWatcherMemory.stillThere(await memoryF, _watchers);
        if (_selectedWatchers.isEmpty) _selectedWatchers.addAll(again);
      }
    } catch (_) {} // best-effort: offline -> empty list shows the add-family step
    _suggestOn = await suggestF;
    if (_suggestOn && widget.suggest == null) {
      try {
        _usual = sj2UsualTrips(await JourneyHabits.trips(), DateTime.now());
      } catch (_) {} // best-effort: a habit is only a hint
    }
    _psMode = await psModeF;
    _map = await mapF;
    _gmaps = await gmapsF;
    if (mounted) setState(() => _loading = false);
    _lastKnown();
    _applySuggestion();
  }

  /// sjstart2: the suggested usual trip -> destination + mode filled in;
  /// its "Start" button starts at once once the road time is known.
  Future<void> _applySuggestion([JourneySuggestion? own]) async {
    final s = own ?? widget.suggest;
    if (s == null || !mounted) return;
    _pendingKind = s.kind;
    if (s.mode != null) setState(() => _mode = s.mode);
    _setDest(s.name, s.dLat, s.dLng);
    if (own == null && !widget.autoStart) return;
    // the ONE road-time answer usually lands within a second or two; without
    // it _start asks for the arrival time (never a dead end)
    for (var i = 0; i < 20 && mounted && _eta == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (mounted && !_starting) await _start();
  }

  /// Distance "from here" without ever prompting: only when location is
  /// already allowed, and only the phone's last known fix.
  Future<void> _lastKnown() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.whileInUse && perm != LocationPermission.always) return;
      final p = await Geolocator.getLastKnownPosition();
      if (p != null && mounted) {
        setState(() => _here = (lat: p.latitude, lng: p.longitude));
        if (_pinned && _eta == null) unawaited(_fetchEta());
        unawaited(_loadHereArea());
      }
    } catch (_) {
      // best-effort: no distance line, nothing else changes
    }
  }

  bool get _pinned => _dest?['lat'] is num && _dest?['lng'] is num;

  void _setDest(String name, double lat, double lng, {String address = ''}) {
    setState(() {
      if (name.isNotEmpty) _destName.text = name;
      _dest = {'name': _destName.text.trim(), 'lat': lat, 'lng': lng};
      _destKind = _pendingKind;
      _pendingKind = null;
      _destAddress = address;
      if (!_etaEdited) {
        _eta = null;
        _etaMin = null;
      }
    });
    unawaited(_fetchEta());
  }

  void _unpin() => setState(() {
        _dest = null;
        _destKind = null;
        _destAddress = '';
        if (!_etaEdited) {
          _eta = null;
          _etaMin = null;
        }
      });

  /// Road modes Google's Routes answers for (DRIVE / TWO_WHEELER); train
  /// times come from the train, metro / launch have no road time.
  static const _roadModes = <String?>{null, 'local_bus', 'long_bus', 'car', 'cng', 'bike', 'walk'}; // sjstart2: bike = TWO_WHEELER, walk = WALK

  /// jsearch: ONE Routes call (our capped server; cached 10 min there) for
  /// the pinned destination + chosen mode -> the default arrival time.
  /// Unavailable / capped / no fix -> stays empty with a hint.
  Future<void> _fetchEta() async {
    if (_etaEdited || !_pinned) return;
    if (!_roadModes.contains(_mode)) {
      if (_jm.train == null && _etaMin != null) {
        setState(() {
          _eta = null;
          _etaMin = null;
        });
      }
      return;
    }
    final here = _origin; // sjstart2: from the chosen start
    if (here == null) return;
    final lat = (_dest!['lat'] as num).toDouble(), lng = (_dest!['lng'] as num).toDouble();
    final mode = _mode;
    Map<String, dynamic> r;
    try {
      r = await context.read<AppState>().api.mapsEta(here.lat, here.lng, lat, lng, mode: mode ?? '');
    } catch (_) {
      r = const {'state': 'failed'};
    }
    if (!mounted || _etaEdited || _mode != mode) return;
    if (_dest?['lat'] != lat || _dest?['lng'] != lng) return; // a newer pin
    final ok = r['state'] == 'ok' || r['state'] == 'cache';
    final m = ok && r['minutes'] is num ? (r['minutes'] as num).toInt() : null;
    setState(() {
      _etaMin = m;
      _eta = m == null ? null : TimeOfDay.fromDateTime(DateTime.now().add(Duration(minutes: m)));
    });
  }

  /// "car" / "local bus" / "CNG" inside a sentence (Bangla as is).
  String _modeWord(AppLocalizations t) {
    final l = _mode == null ? '' : jTravelLabel(t, _mode!);
    if (Localizations.localeOf(context).languageCode == 'bn' || l == l.toUpperCase()) return l;
    return l.toLowerCase();
  }

  /// "1 h 20 min" (Bangla words + digits in Bangla).
  String _dur(AppLocalizations t, int min) => jDigits(
      context, min >= 60 ? t.psDurHM(min ~/ 60, min % 60) : t.psDurM(min));

  Future<void> _pasteLink() async {
    final got = await showJourneyLinkSheet(context, context.read<AppState>().api);
    if (got != null && mounted) _setDest(got.name, got.lat, got.lng);
  }

  /// Saved places with a pin, for the search's pre-typing list.
  List<PlacePick> _savedPicks(AppLocalizations t) => [
        for (final p in _places)
          if (p['lat'] is num && p['lng'] is num)
            (
              name: jPlaceLabel(t, p),
              address: '${p['address'] ?? ''}',
              lat: (p['lat'] as num).toDouble(),
              lng: (p['lng'] as num).toDouble()
            )
      ];

  Future<({double lat, double lng})?> _mapPoint() =>
      Navigator.of(context).push<({double lat, double lng})>(MaterialPageRoute(
          builder: (_) => JourneyMapPickScreen(
              config: _map,
              google: _gmaps,
              lat: (_dest?['lat'] as num?)?.toDouble() ?? _here?.lat,
              lng: (_dest?['lng'] as num?)?.toDouble() ?? _here?.lng)));

  Future<void> _pickOnMap() async {
    final got = await _mapPoint();
    if (got != null && mounted) {
      final pinned = AppLocalizations.of(context).journeyDestPinned;
      final blank = _destName.text.trim().isEmpty || _destName.text.trim() == pinned;
      _setDest(blank ? pinned : '', got.lat, got.lng);
      if (blank) _nameFromAddress(got.lat, got.lng, pinned);
    }
  }

  /// mapscost: name a map-picked pin by its address — the phone's own free
  /// Geocoder first, our capped server only as fallback, else it stays
  /// "Pinned spot" (the coordinates are already shown on the pin card).
  Future<void> _nameFromAddress(double lat, double lng, String pinned) async {
    final api = context.read<AppState>().api;
    final lang = Localizations.localeOf(context).languageCode;
    final r = await AddressResolver.resolve(api, lat, lng, lang: lang);
    if (!mounted || !r.isAddress) return;
    // only if the user has not typed a name meanwhile and the pin is the same
    if (_destName.text.trim() == pinned && _dest?['lat'] == lat && _dest?['lng'] == lng) {
      _setDest(r.text, lat, lng);
    }
  }

  Future<void> _savePlace() async {
    if (!_pinned) return;
    final t = AppLocalizations.of(context);
    await _saveAs(_destName.text.trim() == t.journeyDestPinned ? '' : _destName.text.trim(),
        (_dest!['lat'] as num).toDouble(), (_dest!['lng'] as num).toDouble());
  }

  /// jsearch: "Add a place" — the same place search, then Home / School /
  /// Office / other.
  Future<void> _addPlace() async {
    final got = await showPlaceSearchSheet(context, context.read<AppState>().api,
        lat: _here?.lat,
        lng: _here?.lng,
        mode: _psMode,
        onMap: (_map.hasTiles || _gmaps) ? _mapPoint : null);
    if (got == null || !mounted) return;
    await _saveAs(got.name, got.lat, got.lng);
  }

  Future<void> _saveAs(String name, double lat, double lng) async {
    final t = AppLocalizations.of(context);
    final have = _places.map(jPlaceKind).toSet();
    final first = kPlaceKinds.firstWhere((k) => !have.contains(k), orElse: () => 'other');
    final pick = await showJourneySavePlaceSheet(context,
        kind: first,
        name: name);
    if (pick == null || !mounted) return;
    try {
      final api = context.read<AppState>().api;
      await api.saveSavedPlace({
        'kind': pick.kind,
        'label': pick.kind == 'other' ? pick.name : pick.kind,
        'name': pick.name.isNotEmpty ? pick.name : jKindLabel(t, pick.kind),
        'lat': lat,
        'lng': lng,
        'theft_safe': pick.theftSafe,
      });
      final rows = sjgOrderPlaces(await api.savedPlaces(), await PlaceRecents.ranked());
      if (!mounted) return;
      setState(() => _places = rows);
      _snack(t.j2SavePlaceDone);
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.savePlace', e);
    }
  }

  /// placesafe: long-press -> the place's sheet (anti-theft switch +
  /// Remove). Remove still asks once more.
  Future<void> _editPlace(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final remove = await showJourneyPlaceEditSheet(
        context, context.read<AppState>().api, p,
        title: jPlaceLabel(t, p),
        onChanged: (row) {
          if (!mounted) return;
          setState(() {
            final i = _places.indexWhere((x) => x['id'] == row['id']);
            if (i >= 0) _places[i] = row;
          });
        });
    if (remove == true && mounted) await _removePlace(p);
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
    final o = _origin; // sjstart2
    if (!_pinned || o == null) return null;
    return jDistanceM(o.lat, o.lng, (_dest!['lat'] as num).toDouble(),
        (_dest!['lng'] as num).toDouble());
  }

  /// true = go ahead with the start; false = the user went to fix it (or
  /// closed the sheet) and will tap Start again.
  Future<bool> _bgReady(AppLocalizations t) async {
    if (!journeyNeedsBgSetup(_oemInfo, guidedBefore: _bgGuided) || !mounted) return true;
    final pick = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('j100b_bg_sheet'),
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.battery_alert_rounded, color: Brand.warnInk(ctx)),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(t.j100bBgSheetTitle,
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: Gap.sm),
            Text(t.j100bBgSheetBody, style: AType.bodyMedium),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
                key: const ValueKey('j100b_bg_fix'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: const Icon(Icons.build_circle_rounded),
                label: Text(t.j100bBgSheetFix),
                onPressed: () => Navigator.pop(ctx, 'fix')),
            const SizedBox(height: Gap.sm),
            OutlinedButton(
                key: const ValueKey('j100b_bg_skip'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.pop(ctx, 'start'),
                child: Text(t.j100bBgSheetSkip)),
          ]),
        ),
      ),
    );
    if (pick == 'start') return true;
    if (pick == 'fix' && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BatteryGuidanceScreen(native: widget.oem)));
      await Settings.setBool(kJourneyBgGuidedKey, true);
      _bgGuided = true;
      unawaited(_probeOem()); // the user may have changed the settings
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.j100bBgReady)));
      }
    }
    return false;
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = _destName.text.trim();
    if (name.isEmpty && _dest == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.journeyNeedDest)));
      return;
    }
    // qjourney (owner V2 root cause): a typed name alone has no coordinates,
    // so arrival could never be checked — pick it from the list or the map
    if (_dest?['lat'] == null || _dest?['lng'] == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.qjDestNeedsPlace)));
      return;
    }
    // qjourney: a destination where you already are would "arrive" at once
    final h = _origin;
    if (h != null &&
        jDistanceM(h.lat, h.lng, (_dest!['lat'] as num).toDouble(),
                (_dest!['lng'] as num).toDouble()) <
            300) {
      messenger.showSnackBar(SnackBar(content: Text(t.qjDestIsHere)));
      return;
    }
    if (_selectedWatchers.isEmpty) {
      setState(() => _askedWatcher = true);
      messenger.showSnackBar(SnackBar(content: Text(t.journeyNeedWatcher)));
      return;
    }
    // jsearch: no ETA yet (no road time) -> the user sets it now, once
    if (_eta == null) {
      final picked = await showTimePicker(context: context, initialTime: TimeOfDay.now());
      if (!mounted) return;
      if (picked == null) {
        messenger.showSnackBar(SnackBar(content: Text(t.psEtaNeed)));
        return;
      }
      setState(() {
        _eta = picked;
        _etaEdited = true;
      });
    }
    final at = _eta!;
    final now = DateTime.now();
    var eta = DateTime(now.year, now.month, now.day, at.hour, at.minute);
    if (eta.isBefore(now)) eta = eta.add(const Duration(days: 1));
    final dest = <String, dynamic>{
      'name': name.isEmpty ? (_dest?['name'] ?? '') : name,
      if (_dest?['lat'] != null) 'lat': _dest!['lat'],
      if (_dest?['lng'] != null) 'lng': _dest!['lng'],
      if (_destKind != null && _destKind!.isNotEmpty) 'kind': _destKind,
      // sjp0: the arrival window travels with the trip (watchers + web page)
      if (_windowTimes() case final w?) ...{
        'window_from': w.a.toUtc().toIso8601String(),
        'window_to': w.b.toUtc().toIso8601String(),
        if (w.c != null) 'earliest_at': w.c!.toUtc().toIso8601String(),
      },
    };
    final train = _mode == 'train' && jmTrainOn ? _jm.train?.toLink() : null;
    final ride = <String, dynamic>{
      if (_plate.text.trim().isNotEmpty) 'plate': _plate.text.trim(),
      if (_mode != null) 'mode': _mode,
      if (train != null) 'train': train,
      if (_app != null) 'app': _app,
      if (_driverName.text.trim().isNotEmpty) 'driver_name': _driverName.text.trim(),
      if (_driverPhone.text.trim().isNotEmpty) 'driver_phone': _driverPhone.text.trim(),
    };
    // journey100b: phones that kill background apps — fix it BEFORE the trip
    if (!await _bgReady(t)) return;
    if (!mounted) return;
    setState(() => _starting = true);
    // location for the live share (while-in-use only; the journey's own
    // foreground service keeps it going with the screen off)
    try {
      var perm = await Geolocator.checkPermission();
      // playall: the journey's location keeps going with the app closed /
      // screen off (location foreground service) — so the disclosure says so.
      if (perm == LocationPermission.denied && mounted &&
          await showPermissionReason(context, PermKind.journey)) {
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
            // sjstart2: where the trip starts (picked start, else the phone)
            origin: _origin == null
                ? null
                : {
                    'lat': _origin!.lat,
                    'lng': _origin!.lng,
                    'name': _fromPick?.name ?? _hereArea ?? '',
                  },
            mode: _mode,
            vehicle: ride.isEmpty ? null : ride,
            overdueGraceMin: _graceMin,
            routeDeviationOn: _routeDeviation,
            locationRetentionHours: _retentionHours,
            night: _night,
            stopAlertMin: _stopAlert ? 20 : 0,
          );
      final id = (r['id'] as num?)?.toInt();
      // sjstart2: remember the watchers + this trip (phone only), then the
      // plate photo to the watchers through the live screen's upload path
      unawaited(JourneyWatcherMemory.save(_selectedWatchers));
      final h0 = _here;
      if (h0 != null) {
        unawaited(JourneyHabits.record(JourneyHabitTrip(
            fLat: h0.lat,
            fLng: h0.lng,
            dLat: (dest['lat'] as num).toDouble(),
            dLng: (dest['lng'] as num).toDouble(),
            name: '${dest['name']}',
            kind: _destKind,
            mode: _mode,
            at: DateTime.now())));
      }
      final photo = _platePhoto;
      if (photo != null && id != null) {
        try {
          await context.read<AppState>().api.journeyVehiclePhoto(id, base64Encode(photo),
              plate: _plate.text.trim().isEmpty ? null : _plate.text.trim(), mode: _mode);
        } catch (_) {
          // the journey runs; the live screen still offers "Ride photo"
          messenger.showSnackBar(SnackBar(content: Text(t.sj2PlateNotSent)));
        }
        if (!mounted) return;
      }
      final phones = _watchers
          .where((m) => _selectedWatchers.contains((m['id'] as num?)?.toInt()))
          .map((m) => (m['phone'] ?? '').toString())
          .where((p) => p.isNotEmpty)
          .join(',');
      await Settings.setString(kPhonesKey, phones);
      if (!mounted) return;
      // jsearch: My Trip no longer arms the destination alarm (owner 4 Nov) —
      // it is set only on the Destination Alarm card.
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

  Widget _modePicker() {
    final lat = (_dest?['lat'] as num?)?.toDouble(), lng = (_dest?['lng'] as num?)?.toDouble();
    if (_jm.travel == 'metro') {
      _jm.guessMetro(hereLat: _origin?.lat, hereLng: _origin?.lng, destLat: lat, destLng: lng);
    }
    return JourneyModePicker(
      c: _jm,
      destPinned: _pinned,
      destName: _destName.text.trim(),
      destLat: lat,
      destLng: lng,
      onMode: (m) {
        setState(() => _mode = m);
        unawaited(_fetchEta()); // same road call is cached on the server
      },
      onPickTrain: _pickTrain,
    );
  }

  /// qjourney (owner V2): the arrival window card — "Arrive between A and
  /// B" from the ONE Routes answer (traffic) and, under it, "Earlier than C
  /// is not possible" (straight-line distance at the mode's top speed — the
  /// same rule the server uses to refuse an impossible "Arrived").
  /// sjp0: the window's three instants (A, B, C) — from the Routes answer
  /// or, when there is none (no budget / offline), from the distance at a
  /// typical speed for the mode, so the card and the watchers ALWAYS get a
  /// window. Sent with the trip (destination.window_from / window_to /
  /// earliest_at) so "Trips I am following" and the live web page show it.
  ({DateTime a, DateTime b, DateTime? c})? _windowTimes() {
    final d = _dest;
    if (d == null || d['lat'] is! num || d['lng'] is! num) return null;
    final dm = _distM;
    final m = _etaMin ?? (dm == null ? null : jRoughMinutes(dm, _mode));
    if (m == null) return null;
    final now = DateTime.now();
    final a = now.add(Duration(minutes: m));
    final b = now.add(Duration(minutes: (m * 1.4).round() + 10));
    DateTime? c;
    final h = _origin; // sjstart2: C from the chosen start
    if (h != null) {
      final km = (jDistanceM(h.lat, h.lng, (d['lat'] as num).toDouble(),
                      (d['lng'] as num).toDouble()) -
                  1000)
              .clamp(0, double.infinity) /
          1000;
      final c0 = now.add(Duration(minutes: (km / qjTopKmh(_mode) * 60).floor()));
      if (c0.isBefore(a)) c = c0;
    }
    return (a: a, b: b, c: c);
  }

  Widget? _window(BuildContext context, AppLocalizations t) {
    final w = _windowTimes();
    if (w == null) return null;
    String hm(DateTime x) => jDigits(context, TimeOfDay.fromDateTime(x).format(context));
    final a = w.a, b = w.b;
    final c = w.c == null ? null : hm(w.c!);
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('qj_window'),
      margin: const EdgeInsets.only(top: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: DsTokens.of(context).primarySoft.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.qjWindow(hm(a), hm(b)),
            style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
        if (c != null)
          Text(t.qjEarliest(c),
              key: const ValueKey('qj_earliest'),
              style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
      ]),
    );
  }

  /// sjstart2: the area name of the phone's own point (our free BD list;
  /// nothing near / offline -> just "My current location").
  Future<void> _loadHereArea() async {
    final h = _here;
    if (h == null) return;
    try {
      final r = await context.read<AppState>().api.getJson(
          '/maps/area?lat=${h.lat.toStringAsFixed(5)}&lng=${h.lng.toStringAsFixed(5)}');
      final a = r['area'];
      final name = a is Map ? '${a['name'] ?? ''}'.trim() : '';
      if (mounted && name.isNotEmpty) setState(() => _hereArea = name);
    } catch (_) {} // best-effort: the row still says "My current location"
  }

  void _setFrom(PlacePick? p) {
    setState(() {
      _fromPick = p;
      if (!_etaEdited) {
        _eta = null;
        _etaMin = null;
      }
    });
    if (_pinned) unawaited(_fetchEta());
  }

  /// sjstart2: tap "From" -> My current location / a saved place / search
  /// (with Pick on map inside the search sheet).
  Future<void> _pickFrom() async {
    final t = AppLocalizations.of(context);
    final saved = _savedPicks(t);
    final pick = await showAppSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                key: const ValueKey('sj2_from_here'),
                leading: const Icon(Icons.my_location_rounded),
                title: Text(t.sj2FromHere),
                subtitle: _hereArea == null ? null : Text(_hereArea!),
                onTap: () => Navigator.pop(ctx, 'here')),
            for (var i = 0; i < saved.length && i < 6; i++)
              ListTile(
                  key: ValueKey('sj2_from_saved_$i'),
                  leading: const Icon(Icons.bookmark_rounded),
                  title: Text(saved[i].name),
                  subtitle: saved[i].address.isEmpty ? null : Text(saved[i].address, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, saved[i])),
            ListTile(
                key: const ValueKey('sj2_from_search'),
                leading: const Icon(Icons.search_rounded),
                title: Text(t.sj2FromSearch),
                onTap: () => Navigator.pop(ctx, 'search')),
          ]),
        ),
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == 'here' || pick is PlacePick) {
      _setFrom(pick is PlacePick ? pick : null);
      return;
    }
    final got = await showPlaceSearchSheet(context, context.read<AppState>().api,
        lat: _here?.lat,
        lng: _here?.lng,
        mode: _psMode,
        saved: saved,
        onMap: (_map.hasTiles || _gmaps) ? _mapPoint : null,
        fieldKey: const ValueKey('sj2_from_field'));
    if (got != null && mounted) _setFrom(got);
  }

  /// gap-safejourney: "Going to Office?" right on the form — only before a
  /// destination is chosen, never when the notification already filled it.
  JourneySuggestion? _screenSuggestion() {
    if (_usualClosed || widget.suggest != null || _dest != null) return null;
    if (_destName.text.trim().isNotEmpty) return null;
    return sjgScreenSuggestion(_usual, _origin);
  }

  Widget _usualCard(AppLocalizations t, ColorScheme cs, JourneySuggestion s) {
    return Container(
      key: const ValueKey('gsj_usual_card'),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.md),
      decoration: BoxDecoration(
          color: cs.secondaryContainer, borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Icon(Icons.auto_awesome_rounded, color: cs.onSecondaryContainer),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(t.sj2SuggestTitle(s.name),
                  style: AType.titleSmall
                      .copyWith(fontWeight: FontWeight.w700, color: cs.onSecondaryContainer)),
            ),
          ),
          IconButton(
              key: const ValueKey('gsj_usual_close'),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: Icon(Icons.close_rounded, color: cs.onSecondaryContainer),
              onPressed: () => setState(() => _usualClosed = true)),
        ]),
        Padding(
          padding: const EdgeInsets.only(right: Gap.sm),
          child: Text(t.sj2SuggestBody,
              style: AType.bodyMedium.copyWith(color: cs.onSecondaryContainer)),
        ),
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
          key: const ValueKey('gsj_usual_go'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(t.sj2SuggestGo),
          onPressed: _starting
              ? null
              : () {
                  setState(() => _usualClosed = true);
                  unawaited(_applySuggestion(s));
                },
        ),
      ]),
    );
  }

  Widget _fromRow(AppLocalizations t, ColorScheme cs) {
    final p = _fromPick;
    final here = p == null;
    final line = here
        ? (_hereArea == null ? t.sj2FromHere : t.sj2FromHereArea(_hereArea!))
        : p.name;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(Radii.md),
      child: ListTile(
        key: const ValueKey('sj2_from'),
        minVerticalPadding: Gap.sm,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        leading: Icon(here ? Icons.my_location_rounded : Icons.trip_origin_rounded, color: cs.primary),
        title: Text(t.sj2From, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
        subtitle: Text(line,
            key: const ValueKey('sj2_from_text'),
            style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
        trailing: Text(t.sj2FromChange, style: AType.bodyMedium.copyWith(color: cs.primary)),
        onTap: _pickFrom,
      ),
    );
  }

  Widget _h(String s) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.sm),
        child: Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
      );

  Widget _intro(AppLocalizations t, ColorScheme cs) => Container(
        key: const ValueKey('j2_intro'),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
            color: DsTokens.of(context).primarySoft.withValues(alpha: 0.45),
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
      // jsearch: the confirm card — full address, the pin on Google's map
      // when this build has the Maps SDK key, Change; the arrival geofence
      // is this pin.
      final d = _distM;
      return KeyedSubtree(
        key: const ValueKey('j2_pinned'),
        child: PlaceConfirmCard(
          pick: (
            name: _destName.text.trim().isEmpty ? t.journeyDestPinned : _destName.text.trim(),
            address: _destAddress,
            lat: (_dest!['lat'] as num).toDouble(),
            lng: (_dest!['lng'] as num).toDouble()
          ),
          showMap: _gmaps,
          title: t.j2Pinned,
          onChange: _unpin,
          extra: [
            if (d != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.j2PinnedFar(jKm(context, d)),
                    style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
              ),
            const SizedBox(height: Gap.xs),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('j2_save_place'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.bookmark_add_rounded),
                label: Text(t.j2SavePlace),
                onPressed: _savePlace,
              ),
            ),
          ],
        ),
      );
    }
    if (_destName.text.trim().isEmpty) return const SizedBox.shrink();
    // sjp0 (owner P0 9 Nov): no scary "No pin yet" warning — the honest V2
    // rule, calmly: pick the place from the list or the map (a trip never
    // starts without coordinates).
    return Container(
      key: const ValueKey('j2_no_pin'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: DsTokens.of(context).cardHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.place_outlined, color: cs.primary),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(t.qjDestNeedsPlace, style: AType.bodyMedium)),
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
          body: const SkeletonList());
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
            tooltip: t.j100Following,
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
        if (widget.suggest != null) ...[
          const SizedBox(height: Gap.sm),
          Container(
            key: const ValueKey('sj2_suggest_banner'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
                color: cs.secondaryContainer,
                borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(children: [
              Icon(Icons.auto_awesome_rounded, color: cs.onSecondaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(
                      t.sj2SuggestBanner(widget.suggest!.name,
                          jDigits(context, TimeOfDay(hour: widget.suggest!.usualMin ~/ 60, minute: widget.suggest!.usualMin % 60).format(context))),
                      style: AType.bodyMedium.copyWith(color: cs.onSecondaryContainer))),
            ]),
          ),
        ],
        if (_screenSuggestion() case final s?) ...[
          const SizedBox(height: Gap.sm),
          _usualCard(t, cs, s),
        ],
        const SizedBox(height: Gap.md),
        _fromRow(t, cs), // sjstart2 (owner V2 START 1)
        const SizedBox(height: Gap.lg),
        _modePicker(),
        const Divider(height: 28),
        _h(t.journeyDestSection),
        if (_places.isNotEmpty)
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final p in _places)
              Semantics(
                label: jPlaceLabel(t, p),
                hint: t.j2PlaceLongPressEdit,
                child: GestureDetector(
                  onLongPress: () => _editPlace(p),
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
              style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
        if (_psMode != PlaceSearchMode.off)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
                key: const ValueKey('j2_place_add'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.add_location_alt_rounded),
                label: Text(t.psAddPlace),
                onPressed: _addPlace),
          ),
        const SizedBox(height: Gap.sm),
        // jsearch: the field itself is the place search (live suggestions
        // from 2 letters; before typing: current location, map, saved,
        // recent). A typed name without a pick still works (no-pin card).
        PlaceSearchBox(
            api: context.read<AppState>().api,
            mode: _psMode,
            controller: _destName,
            fieldKey: const ValueKey('j100_dest'),
            label: t.journeyDestLabel,
            nearLat: _here?.lat,
            nearLng: _here?.lng,
            saved: _savedPicks(t),
            onCurrent: () async {
              final p = await placeHereNow(context);
              if (p != null && mounted) setState(() => _here = p);
              return p;
            },
            onMap: (_map.hasTiles || _gmaps) ? _mapPoint : null,
            // qjourney (owner V2 root cause): typing a NEW name after a pick
            // kept the OLD pin's coordinates (e.g. "Gazipur" pinned in Badda
            // -> "arrived" minutes after leaving) — a changed name drops the pin
            onTyped: (txt) {
              if (_dest != null && txt.trim() != '${_dest!['name'] ?? ''}'.trim()) {
                _unpin();
              } else {
                setState(() {});
              }
            },
            // qjourney: no "use my location" button on the DESTINATION field
            // (a trip to where you already are "arrives" at once)
            onRow: (r) => _pendingKind = '${r['kind'] ?? ''}',
            onPicked: (p) => _setDest(p.name, p.lat, p.lng, address: p.address)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          OutlinedButton.icon(
              key: const ValueKey('j2_paste_link'),
              icon: const Icon(Icons.link_rounded),
              label: Text(t.j2PasteLink),
              onPressed: _pasteLink),
          // design3 (lead 17 Nov): no separate "Find a place" button — the
          // field above IS the place search (it did the same thing twice).
          if (_map.hasTiles || _gmaps)
            OutlinedButton.icon(
                key: const ValueKey('j2_pick_map'),
                icon: const Icon(Icons.map_rounded),
                label: Text(t.j2PickMap),
                onPressed: _pickOnMap),
        ]),
        // jsearch: no internal "the map is not set up yet" text on user screens
        const SizedBox(height: Gap.sm),
        _pinCard(t, cs),
        const Divider(height: 28),

        _h(t.journeyEtaSection),
        OutlinedButton.icon(
          key: const ValueKey('js_eta_btn'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.schedule_rounded),
          label: Text(_eta == null ? t.psEtaSet : t.journeyEtaBy(_eta!.format(context))),
          onPressed: () async {
            final picked = await showTimePicker(
                context: context, initialTime: _eta ?? TimeOfDay.now());
            if (picked != null) {
              setState(() {
                _eta = picked;
                _etaEdited = true;
              });
            }
          },
        ),
        if (_etaMin != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
                _modeWord(t).isEmpty
                    ? t.psEtaAboutRoad(_dur(t, _etaMin!))
                    : t.psEtaAbout(_dur(t, _etaMin!), _modeWord(t)),
                key: const ValueKey('js_eta_about'),
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
          )
        else if (_eta == null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.psEtaHint,
                key: const ValueKey('js_eta_hint'),
                style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
          ),
        if (_window(context, t) case final w?) w,
        if (rough != null && _etaMin == null) ...[
          const SizedBox(height: Gap.xs),
          Text(t.j2Rough(jDigits(context, rough)),
              key: const ValueKey('j2_rough'),
              style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
                key: const ValueKey('j2_rough_use'),
                onPressed: () => setState(() {
                      _eta = TimeOfDay.fromDateTime(DateTime.now().add(Duration(minutes: rough + 10)));
                      _etaEdited = true;
                    }),
                child: Text(t.j2RoughUse)),
          ),
        ],
        const Divider(height: 28),

        Row(children: [
          Expanded(child: _h(t.journeyWhoKnows)),
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
          Text(t.journeyNoWatchers, style: AType.bodyMedium.copyWith(color: DsTokens.of(context).muted)),
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
        // sjstart2 (owner V2 item 5): chips, Family first, more than one
        if (_watchers.isNotEmpty) ...[
          JourneyWatcherChips(
            rows: _watchers,
            selected: _selectedWatchers,
            onChanged: (v) => setState(() {
              _selectedWatchers
                ..clear()
                ..addAll(v);
            }),
          ),
          const SizedBox(height: Gap.xs),
          Text(
              _selectedWatchers.isEmpty
                  ? t.sj2WatchNone
                  : t.sj2WatchCount(jDigits(context, _selectedWatchers.length)),
              key: const ValueKey('sj2_w_count'),
              style: AType.bodySmall.copyWith(
                  color: _selectedWatchers.isEmpty && _askedWatcher
                      ? cs.error
                      : cs.onSurfaceVariant)),
        ],
        Text(t.j2NoAppPeople,
            style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
        const Divider(height: 28),

        // sjstart2 (owner V2 item 6): optional number-plate photo
        if (sj2PlatePhotoFits(_mode, _app)) ...[
          JourneyPlatePhotoTile(
            bytes: _platePhoto,
            onPick: () async {
              try {
                final b = await sj2PickPlatePhoto(context, picker: widget.platePicker);
                if (b != null && mounted) setState(() => _platePhoto = b);
              } catch (e) {
                if (mounted) showActionFailed(context, 'journey.platePhoto', e);
              }
            },
            onRemove: () => setState(() => _platePhoto = null),
          ),
          const SizedBox(height: Gap.sm),
        ],
        ExpansionTile(
          key: const ValueKey('j2_ride'),
          tilePadding: EdgeInsets.zero,
          title: Text(t.journeyRideSection),
          children: [
            KeyedSubtree(
              key: ValueKey('j2_mode_sub_$_mode'),
              child: DropdownButtonFormField<String>(
              key: const ValueKey('j2_mode'),
              initialValue: _mode,
              isExpanded: true,
              decoration: InputDecoration(labelText: t.journeyModeLabel),
              items: [
                for (final m in kJourneyModes)
                  DropdownMenuItem(value: m, child: Text(jModeLabel(t, m))),
              ],
              onChanged: (v) => setState(() => _mode = v),
            )),
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
                style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
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
                style: AType.bodySmall.copyWith(color: DsTokens.of(context).muted)),
            // sjstart2: usual-trip suggestions (learned on this phone only)
            SwitchListTile(
                key: const ValueKey('sj2_suggest_switch'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.sj2SuggestSwitch),
                subtitle: Text(t.sj2SuggestSwitchDesc),
                value: _suggestOn,
                onChanged: (v) {
                  setState(() => _suggestOn = v);
                  unawaited(JourneyHabits.setEnabled(v));
                }),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                  key: const ValueKey('sj2_suggest_forget'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () async {
                    final m = ScaffoldMessenger.of(context);
                    await JourneyHabits.forget();
                    m.showSnackBar(SnackBar(content: Text(t.sj2SuggestForgotten)));
                  },
                  child: Text(t.sj2SuggestForget)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          // design3: Start = the one glowing DS button (key on the inner button)
          child: DsButton(
            buttonKey: const ValueKey('j100_start'),
            onPressed: _start,
            busy: _starting,
            icon: Icons.navigation_rounded,
            label: t.journeyStartButton,
          ),
        ),
      ]),
    );
  }
}

/// qjourney: straight-line top speed (km/h) per travel mode — the mirror of
/// backend core/logic/journey_arrival.py TOP_KMH (C is a true lower bound).
double qjTopKmh(String? mode) => switch (mode) {
      'walk' => 10,
      'rickshaw' => 25,
      'launch' => 45,
      'cng' || 'local_bus' => 80,
      'metro' => 100,
      'bike' || 'bus' || 'long_bus' => 110,
      _ => 130,
    };
