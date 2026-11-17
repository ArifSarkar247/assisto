// cityapp B12: "Start this route as a Safe Journey" — one tap. Safe Journey's
// own start API (POST /journey/start: the family picked from My Circle sees
// the trip live) + the destination alarm at the get-off stop (the same
// DestAlarmController Safe Journey uses, via JourneyAlarmLink so stopping
// the journey turns it off). Then the trip guide: the steps, and on leaving
// the metro (an on-phone geofence around the station) "Which gate to take".
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_widgets.dart';
import '../../city/map/city_trip_learn_card.dart' show learnableRides, showCityTripLearnCard; // mapapp
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart' show PlacePick;
import '../../state.dart';
import '../../theme.dart';
import '../../train/dest_alarm_math.dart';
import '../../train/dest_alarm_service.dart';
import '../../train/journey_transit.dart';
import '../../widgets/app_sheet.dart' show showAppSheet, withNavBarInset;
import '../../widgets/chatnav.dart' show ChatNav;
import '../../widgets/journey_api.dart';
import '../../widgets/permission_reason.dart';
import '../journey_live_screen.dart';
import '../journey_start_screen.dart' show journeyWatcherRows;
import '../train/dest_alarm_screen.dart' show destAlarmTexts;

/// Safe Journey's travel mode for a city option.
String cityJourneyMode(CityOption o) => switch (o.lastRide?.mode) {
      'metro' => 'metro',
      'water' => 'launch',
      _ => 'local_bus',
    };

/// Trip learning: one point every 15 s, at most 2 000 per trip, sent only
/// when the trip has at least 10.
const int kCityTraceEveryS = 15, kCityTraceMax = 2000, kCityTraceMinPoints = 10;

/// Metres from the get-off stop at which the alarm rings (city bus / metro).
const int kCityAlarmM = 400;

/// Arms the get-off alarm for journey [id] (prod: Safe Journey's link to the
/// destination alarm; tests pass a recorder).
typedef CityArmFn = Future<void> Function(int id, DestPlan plan, DestAlarmTexts texts);

Future<void> startCityJourney(BuildContext context,
    {required CityOption option,
    required PlacePick dest,
    @visibleForTesting CityArmFn? arm,
    @visibleForTesting Future<void> Function()? askLocation}) async {
  final api = context.read<AppState>().api;
  final t = AppLocalizations.of(context);
  List<Map<String, dynamic>> people = [];
  try {
    people = journeyWatcherRows(await api.getJson('/circle/members'));
  } catch (_) {} // offline: the sheet says so and still offers the alarm
  if (!context.mounted) return;
  final ride = option.lastRide;
  final stop = ride?.alight;
  final res = await showAppSheet<({Set<int> ids, bool alarm})>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _StartSheet(people: people, stopName: stop?.label(cityBn(context)) ?? ''),
  );
  if (res == null || !context.mounted) return;
  try {
    if (askLocation != null) {
      await askLocation();
    } else {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && context.mounted &&
          await showPermissionReason(context, PermKind.journey)) {
        await Geolocator.requestPermission();
      }
    }
  } catch (_) {} // best-effort: the live screen says "location is off"
  if (!context.mounted) return;
  final msg = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  final h = DateTime.now().hour;
  Map<String, dynamic>? started;
  try {
    started = await api.journeyStart(
      destination: {'name': dest.name, 'lat': dest.lat, 'lng': dest.lng},
      etaIso: DateTime.now().add(Duration(minutes: option.minutes + 10)).toUtc().toIso8601String(),
      watcherIds: res.ids.toList(),
      mode: cityJourneyMode(option),
      night: h >= 20 || h < 6,
    );
  } catch (_) {
    started = null;
  }
  if (started == null) {
    // gap-city: no internet -> the family cannot be told, but the get-off
    // alarm runs on the phone and the trip guide (steps, which gate) works
    if (res.alarm && stop?.lat != null && stop?.lon != null && context.mounted) {
      final name = stop!.label(cityBn(context));
      try {
        await (arm ?? (int _, DestPlan p, DestAlarmTexts x) => DestAlarmController.I.start(p, x))(
            0,
            DestPlan(
                mode: TransportMode.cityBus,
                target: DestTarget(name, stop.lat!, stop.lon!),
                setM: kCityAlarmM,
                notifyCircleIds: const []),
            destAlarmTexts(context, t, name));
        msg.showSnackBar(SnackBar(content: Text(t.cityGOfflineAlarmOnly)));
        await nav.push(MaterialPageRoute(builder: (_) => CityTripScreen(option: option)));
        return;
      } catch (_) {} // falls through to the honest "could not start"
    }
    msg.showSnackBar(SnackBar(content: Text(t.cityStartFailed)));
    return;
  }
  try {
    final r = started;
    final id = (r['id'] as num?)?.toInt() ?? 0;
    if (res.alarm && stop?.lat != null && stop?.lon != null && context.mounted) {
      final name = stop!.label(cityBn(context));
      try {
        await (arm ?? JourneyAlarmLink.I.arm)(
            id,
            DestPlan(
                mode: TransportMode.cityBus,
                target: DestTarget(name, stop.lat!, stop.lon!),
                setM: kCityAlarmM,
                notifyCircleIds: res.ids.toList()),
            destAlarmTexts(context, t, name));
      } catch (_) {
        msg.showSnackBar(SnackBar(content: Text(t.cityAlarmFailed)));
      }
    }
    var learn = false;
    try {
      learn = (await api.cityTripConsent())['on'] == true;
    } catch (_) {} // offline: no learning this trip
    await nav.push(MaterialPageRoute(builder: (_) => CityTripScreen(option: option, journeyId: id, learn: learn)));
  } catch (_) {
    msg.showSnackBar(SnackBar(content: Text(t.cityStartFailed)));
  }
}

class _StartSheet extends StatefulWidget {
  final List<Map<String, dynamic>> people;
  final String stopName;
  const _StartSheet({required this.people, required this.stopName});
  @override
  State<_StartSheet> createState() => _StartSheetState();
}

class _StartSheetState extends State<_StartSheet> {
  final Set<int> _ids = {};
  bool _alarm = true;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cityStartSafeJourney, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(t.cityWhoWatches),
          const SizedBox(height: Gap.sm),
          if (widget.people.isEmpty) ...[
            Text(t.cityNoCircle),
            const SizedBox(height: Gap.xs),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => ChatNav.push(context, 'circle_add'),
              icon: const Icon(Icons.person_add_alt_rounded),
              label: Text(t.cityAddFamily),
            ),
          ] else
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final p in widget.people)
                if ((p['id'] as num?)?.toInt() case final id?)
                  FilterChip(
                    key: ValueKey('city_watch_$id'),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    selected: _ids.contains(id),
                    onSelected: (v) => setState(() => v ? _ids.add(id) : _ids.remove(id)),
                    avatar: const Icon(Icons.person_rounded, size: 18),
                    label: Text(cityD(context, '${p['name'] ?? p['phone'] ?? ''}')),
                  ),
            ]),
          const SizedBox(height: Gap.sm),
          if (widget.stopName.isNotEmpty)
            SwitchListTile(
              key: const ValueKey('city_alarm_switch'),
              contentPadding: EdgeInsets.zero,
              value: _alarm,
              onChanged: (v) => setState(() => _alarm = v),
              secondary: const Icon(Icons.alarm_rounded),
              title: Text(t.cityGetOffAlarm),
              subtitle: Text(cityD(context, t.cityGetOffAlarmSub(widget.stopName))),
            ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('city_sj_go'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.pop(context, (ids: _ids, alarm: _alarm && widget.stopName.isNotEmpty)),
              icon: const Icon(Icons.shield_rounded),
              label: Text(t.cityStartNow),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The metro station a trip gets off at + the gate to take (from the plan).
({CityPoint station, CityGate gate})? cityMetroExit(CityOption o) {
  for (final l in o.legs) {
    if (l.mode == 'metro' && l.alight?.lat != null && l.exitGate != null) {
      return (station: l.alight!, gate: l.exitGate!);
    }
  }
  return null;
}

/// Geofence around the get-off station: inside [radius] metres = "you are
/// at the station now" (show which gate). Pure, testable.
bool cityAtStation(CityPoint station, double lat, double lon, {double radius = 150}) =>
    station.lat != null && station.lon != null && haversineM(lat, lon, station.lat!, station.lon!) <= radius;

/// The trip guide while travelling: steps + the live "Which gate" card.
class CityTripScreen extends StatefulWidget {
  final CityOption option;
  final int journeyId;

  /// Test: a position stream instead of GPS.
  @visibleForTesting
  final Stream<({double lat, double lon})>? debugPositions;
  @visibleForTesting
  final DateTime Function()? debugClock;

  /// The user agreed to trip learning (city/trips/consent).
  final bool learn;
  const CityTripScreen(
      {super.key, required this.option, this.journeyId = 0, this.debugPositions, this.debugClock, this.learn = false});
  @override
  State<CityTripScreen> createState() => _CityTripScreenState();
}

class _CityTripScreenState extends State<CityTripScreen> {
  StreamSubscription<({double lat, double lon})>? _sub;
  bool _atStation = false;
  final List<List<num>> _trace = []; // [unix_s, lat, lon] — trip learning only
  int _lastS = 0;
  ApiClient? _api;

  /// Trip learning (B13, owner decision 9 Nov 14:20): only with consent,
  /// only on a bus / leguna ride, only while this journey screen runs in
  /// the foreground — never in the background, no new permission.
  bool get _learn => widget.learn && widget.journeyId > 0 && widget.option.legs.any((l) => l.mode == 'bus' || l.mode == 'leguna');

  @override
  void initState() {
    super.initState();
    final exit = cityMetroExit(widget.option);
    if (exit == null && !_learn) return;
    if (_learn) _api = context.read<AppState>().api;
    final Stream<({double lat, double lon})> s;
    if (widget.debugPositions != null) {
      s = widget.debugPositions!;
    } else {
      try {
        s = Geolocator.getPositionStream(
                locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 25))
            .map((p) => (lat: p.latitude, lon: p.longitude));
      } catch (_) {
        return; // no GPS: the gate is still shown in the steps
      }
    }
    _sub = s.listen((p) {
      if (_learn) _keep(p.lat, p.lon);
      if (exit == null) return;
      final inside = cityAtStation(exit.station, p.lat, p.lon);
      if (inside && !_atStation) {
        HapticFeedback.heavyImpact();
      }
      if (inside != _atStation && mounted) setState(() => _atStation = inside);
    }, onError: (_) {}); // best-effort: GPS off -> the steps still show the gate
  }

  void _keep(double lat, double lon) {
    final now = (widget.debugClock?.call() ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (now - _lastS < kCityTraceEveryS || _trace.length >= kCityTraceMax) return;
    _lastS = now;
    _trace.add([now, double.parse(lat.toStringAsFixed(6)), double.parse(lon.toStringAsFixed(6))]);
  }

  @override
  void dispose() {
    _sub?.cancel();
    final api = _api;
    if (api != null && _trace.length >= kCityTraceMinPoints) {
      // fire-and-forget: the server trims the first/last 300 m, keeps no
      // names and deletes raw points within 7 days
      // citycov: a leguna-only trip teaches leguna stops, not bus stops
      final legs = widget.option.legs;
      final mode = legs.any((l) => l.mode == 'bus') ? 'bus' : 'leguna';
      unawaited(api.cityTripUpload(List.of(_trace), mode: mode).then((_) {}, onError: (_) {}));
    }
    super.dispose();
  }

  /// mapapp: "Which bus? What fare?" then back to City Service.
  Future<void> _arrived() async {
    final nav = Navigator.of(context);
    await showCityTripLearnCard(context, option: widget.option);
    if (mounted && nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final exit = cityMetroExit(widget.option);
    return Scaffold(
      appBar: AppBar(title: Text(t.cityTripTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          if (_atStation && exit != null) ...[
            Text(cityD(context, t.cityWhichGateNow(exit.station.label(cityBn(context)))),
                key: const ValueKey('city_which_gate_now'),
                style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
            CityGateBox(gate: exit.gate, big: true),
            const SizedBox(height: Gap.lg),
          ],
          if (widget.journeyId > 0)
            FilledButton.tonalIcon(
              key: const ValueKey('city_open_live'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => JourneyLiveScreen(journeyId: widget.journeyId))),
              icon: const Icon(Icons.shield_rounded),
              label: Text(t.cityOpenSafeJourney),
            ),
          const SizedBox(height: Gap.md),
          CityOptionSummary(widget.option),
          const Divider(height: Gap.xl),
          CityStepList(widget.option),
          if (learnableRides(widget.option).isNotEmpty) ...[
            // mapapp (owner 10 Nov, LEARN FROM TRIPS): one tap at the end
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('city_trip_done'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                onPressed: _arrived,
                icon: const Icon(Icons.flag_rounded),
                label: Text(t.cityTripArrived),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
