import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'train_share_service.dart';

/// train-app (Train Tracker V2, B): "Are you on this train?".
///
/// While the train's screen is OPEN (app in the foreground; no background
/// location) and the location permission was ALREADY given (we never ask
/// for it here), the phone looks at its own position twice, 30 s apart.
/// Only when both points are on that train's rail line (within 300 m) and
/// it moves at train speed (20-140 km/h) does the app ask ONCE, with one
/// tap, whether the user is on this train. Nothing is sent and nothing is
/// stored by this check; sharing starts only on "Yes".

/// Distance in metres from (lat, lng) to the polyline [path] ([[lat, lng]]).
double trainDistToPathM(double lat, double lng, List<List<double>> path) {
  if (path.isEmpty) return double.infinity;
  // local flat projection around the point (fine for < 50 km)
  final kx = 111320.0 * math.cos(lat * math.pi / 180), ky = 110540.0;
  (double, double) p(List<double> q) => ((q[1] - lng) * kx, (q[0] - lat) * ky);
  if (path.length == 1) {
    final a = p(path[0]);
    return math.sqrt(a.$1 * a.$1 + a.$2 * a.$2);
  }
  var best = double.infinity;
  for (var i = 0; i + 1 < path.length; i++) {
    final a = p(path[i]), b = p(path[i + 1]);
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : -(a.$1 * dx + a.$2 * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final x = a.$1 + t * dx, y = a.$2 + t * dy;
    best = math.min(best, math.sqrt(x * x + y * y));
  }
  return best;
}

const double kOnboardNearM = 300;
const double kOnboardMinKmh = 20;
const double kOnboardMaxKmh = 140;

/// Two foreground fixes -> "this phone rides this train".
bool trainLooksOnboard(TrainFix a, TrainFix b, List<List<double>> path) {
  if (a.mock || b.mock) return false;
  final secs = b.at.difference(a.at).inMilliseconds / 1000.0;
  if (secs < 15) return false;
  if (trainDistToPathM(a.lat, a.lng, path) > kOnboardNearM) return false;
  if (trainDistToPathM(b.lat, b.lng, path) > kOnboardNearM) return false;
  final kmh = trainDistM(a.lat, a.lng, b.lat, b.lng) / secs * 3.6;
  final v = b.speedKmh ?? kmh;
  return kmh >= kOnboardMinKmh && kmh <= kOnboardMaxKmh && v >= kOnboardMinKmh;
}

String _askKey(String no, String date) => 'train_onboard_asked_${no}_$date';

Future<bool> trainOnboardAsked(String no, String date) async {
  try {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_askKey(no, date)) ?? false;
  } catch (_) {
    return true; // can't remember -> don't risk asking twice
  }
}

Future<void> trainOnboardMarkAsked(String no, String date) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_askKey(no, date), true);
  } catch (_) {
    // best-effort
  }
}

/// Foreground position WITHOUT asking for permission (null when not given).
Future<TrainFix?> trainForegroundFix() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.whileInUse && perm != LocationPermission.always) return null;
    final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)));
    return TrainFix(p.latitude, p.longitude, p.accuracy, DateTime.now(),
        speedKmh: p.speed >= 0 ? p.speed * 3.6 : null, mock: p.isMocked);
  } catch (_) {
    return null;
  }
}

/// Runs only while the train screen is open. [onAsk] is called at most
/// once per train and day.
class TrainOnboardWatch {
  TrainOnboardWatch(
      {required this.no,
      required this.date,
      required this.path,
      required this.onAsk,
      Future<TrainFix?> Function()? fix,
      this.gap = const Duration(seconds: 30)})
      : _fix = fix ?? trainForegroundFix;

  final String no, date;
  final List<List<double>> path;
  final Future<void> Function() onAsk;
  final Future<TrainFix?> Function() _fix;
  final Duration gap;
  Timer? _t;
  TrainFix? _prev;
  bool _done = false, _stopped = false;
  int _tries = 0;

  /// 10 looks (about 5 min) at most per screen visit.
  static const int maxTries = 10;

  Future<void> start() async {
    if (path.length < 2 || await trainOnboardAsked(no, date) || _stopped) return;
    _prev = await _fix();
    if (_stopped) return; // the screen closed meanwhile
    _t = Timer.periodic(gap, (_) => check());
  }

  Future<void> check() async {
    if (_done) return;
    if (++_tries > maxTries) {
      stop();
      return;
    }
    final f = await _fix();
    final p = _prev;
    _prev = f ?? p;
    if (f == null || p == null || !trainLooksOnboard(p, f, path)) return;
    _done = true;
    stop();
    await trainOnboardMarkAsked(no, date);
    await onAsk();
  }

  void stop() {
    _stopped = true;
    _t?.cancel();
    _t = null;
  }
}
