import 'package:flutter/foundation.dart';

import '../state.dart';
import 'dest_alarm_math.dart';
import 'dest_alarm_service.dart';

/// journeymode (owner order 2 Nov 17:40): Train tracker and Destination alarm
/// INSIDE Safe Journey. One flow, no copies — Safe Journey CALLS the
/// destination alarm ([DestAlarmController]) and the train tracker's picker
/// and API; this file only maps "how are you going?" to an alarm plan.
///
/// Privacy: the alarm itself runs on the phone (distance on the phone); the
/// journey's own location sharing is unchanged and separate.

/// The start-screen chips, in the owner's order.
const List<String> kTravelModes = [
  'local_bus', 'long_bus', 'train', 'metro', 'launch', 'car', 'cng'
];

/// Remembered last choice (on the phone).
const String kTravelModeKey = 'journey_travel_mode';

/// Which alarm mode a travel mode uses; null = no destination alarm
/// (car / CNG / walking ... — the driver stops where you say).
TransportMode? alarmModeFor(String? travel) => switch (travel) {
      'local_bus' || 'bus' => TransportMode.cityBus,
      'long_bus' => TransportMode.longBus,
      'train' => TransportMode.train,
      'metro' => TransportMode.metro,
      'launch' => TransportMode.launch,
      _ => null,
    };

/// Bus (local / long-distance): the alarm is ON by default (owner order).
/// Train / metro / launch: also on — that is why people pick them here.
bool alarmOnByDefault(String? travel) => alarmModeFor(travel) != null;

/// The train the traveller is on (from the train tracker's picker) and
/// their station.
@immutable
class JourneyTrainPick {
  final String no, nameBn, date;
  final DestStation station;
  final DateTime? stationAt; // timetable estimate at their station
  final List<DestStation> stops; // the train's listed stops, in order
  final List<List<double>> path; // the train's own line
  const JourneyTrainPick(
      {required this.no,
      required this.nameBn,
      required this.date,
      required this.station,
      this.stationAt,
      this.stops = const [],
      this.path = const []});

  /// What the server stores (core.logic.journey_dest.clean_train).
  Map<String, dynamic> toLink() => {'no': no, 'date': date, 'to': station.id};
}

/// Stops of a /train/<no>/live answer as stations, in order.
List<DestStation> trainStops(Map<String, dynamic> live) => [
      for (final s in (live['stops'] as List? ?? const []))
        if (s is Map && s['lat'] is num && s['lng'] is num)
          DestStation('${s['id']}', '${s['en'] ?? ''}', '${s['bn'] ?? ''}',
              (s['lat'] as num).toDouble(), (s['lng'] as num).toDouble())
    ];

/// The alarm plan for a journey, or null when there is nothing to ring for
/// (no alarm mode, no pinned destination, metro stations not chosen).
/// Pure: the same [DestPlan] the standalone alarm builds.
DestPlan? journeyAlarmPlan({
  required String? travel,
  required String destName,
  double? destLat,
  double? destLng,
  required int setM,
  AlertPrefs alerts = const AlertPrefs(),
  JourneyTrainPick? train,
  List<DestStation> stations = const [],
  bool bn = true,
  List<MetroStation> metro = const [],
  int? metroFrom,
  int? metroTo,
  DateTime? now,
}) {
  final mode = alarmModeFor(travel);
  if (mode == null) return null;
  if (mode == TransportMode.metro) {
    if (metroFrom == null || metroTo == null || metroFrom == metroTo) return null;
    if (metroFrom < 0 || metroTo < 0 || metroFrom >= metro.length || metroTo >= metro.length) {
      return null;
    }
    final to = metro[metroTo];
    return DestPlan(
        mode: mode,
        target: DestTarget(to.name(bn), to.lat, to.lng),
        setM: 0,
        alerts: alerts,
        metro: metro,
        metroFrom: metroFrom,
        metroTo: metroTo,
        metroLeftAt: now ?? DateTime.now());
  }
  if (mode == TransportMode.train && train != null) {
    final st = train.station;
    final prev = prevStationOnPath(train.path, stations, st, listedStops: train.stops);
    return DestPlan(
        mode: mode,
        target: DestTarget(st.name(bn), st.lat, st.lng),
        setM: clampFor(mode, setM),
        alerts: alerts,
        prevStation: prev == null ? null : DestTarget(prev.name(bn), prev.lat, prev.lng));
  }
  if (destLat == null || destLng == null) return null;
  return DestPlan(
      mode: mode,
      target: DestTarget(destName, destLat, destLng),
      setM: clampFor(mode, setM),
      alerts: alerts);
}

/// Index of the metro station nearest (lat, lng) within [maxM], else null.
int? nearestMetro(List<MetroStation> metro, double? lat, double? lng, {double maxM = 1500}) {
  if (lat == null || lng == null) return null;
  int? best;
  var bestD = maxM;
  for (var i = 0; i < metro.length; i++) {
    final d = haversineM(lat, lng, metro[i].lat, metro[i].lng);
    if (d <= bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

/// Remembered travel mode (best-effort; none = no chip pre-selected).
Future<String?> loadTravelMode() async {
  try {
    final v = await Settings.getString(kTravelModeKey);
    return kTravelModes.contains(v) ? v : null;
  } catch (_) {
    return null; // best-effort: nothing remembered
  }
}

Future<void> saveTravelMode(String mode) async {
  try {
    await Settings.setString(kTravelModeKey, mode);
  } catch (_) {
    // best-effort: only a convenience
  }
}

/// The destination alarm a Safe Journey armed. Stopping / arriving the
/// journey turns it off; an alarm the user set by itself (standalone) is
/// never touched.
class JourneyAlarmLink extends ChangeNotifier {
  JourneyAlarmLink({DestAlarmController? controller}) : _c = controller;
  static JourneyAlarmLink I = JourneyAlarmLink();

  final DestAlarmController? _c;
  DestAlarmController get c => _c ?? DestAlarmController.I;
  int? journeyId;

  bool armedFor(int id) => journeyId == id && c.on;

  Future<void> arm(int id, DestPlan plan, DestAlarmTexts texts) async {
    await c.start(plan, texts);
    journeyId = id;
    notifyListeners();
  }

  Future<void> disarm(int id) async {
    if (journeyId != id) return;
    journeyId = null;
    if (c.on) await c.stop();
    notifyListeners();
  }
}

/// For the settings memory: the per-mode distance + alerts of the alarm
/// (the same memory the standalone alarm uses).
Future<(int, AlertPrefs)> alarmMemoryFor(String? travel) async {
  final m = alarmModeFor(travel);
  if (m == null) return (0, const AlertPrefs());
  return DestModeMemory.load(m);
}
