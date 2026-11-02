import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../feature_flags.dart';
import 'auto_guard_source.dart';

/// cctvarm: "am I near Home?" for the camera guard — ONLY for a member who
/// said yes on the Auto guard screen, ONLY while Assisto is open (app
/// open/resume, at most every [gap]). The phone measures the distance to Home
/// itself and sends just that number (+ GPS accuracy) — never coordinates.
/// Never asks for a permission here (the consent screen does, once), never
/// runs in the background (no WorkManager), never throws.
class HomePresenceSync {
  HomePresenceSync._();

  static const _prefAt = 'carm_presence_at';
  static const gap = Duration(minutes: 10);

  /// Pure: one report per consenting place with a Home point.
  static List<Map<String, dynamic>> reportsFor(
      List<Map<String, dynamic>> sites, double lat, double lng, double accuracy,
      {double Function(double, double, double, double)? distance}) {
    final d = distance ?? Geolocator.distanceBetween;
    final out = <Map<String, dynamic>>[];
    for (final s in sites) {
      final home = s['home'];
      if (s['consent'] != true || home is! Map) continue;
      final hl = (home['lat'] as num?)?.toDouble();
      final hg = (home['lng'] as num?)?.toDouble();
      if (hl == null || hg == null) continue;
      out.add({
        'site': s['site'],
        'distance_m': d(lat, lng, hl, hg).round(),
        'accuracy_m': accuracy.round(),
      });
    }
    return out;
  }

  static Future<int> maybeSend(ApiClient api,
      {AutoGuardSource? source,
      Future<({double lat, double lng, double acc})?> Function()? locate,
      bool force = false}) async {
    try {
      if (!FeatureFlags.instance.isOn('home_watchman')) return 0;
      final p = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now - (p.getInt(_prefAt) ?? 0) < gap.inMilliseconds) return 0;
      final src = source ?? ApiAutoGuardSource(api);
      final mine = await src.mine();
      final sites = (mine['sites'] is List ? mine['sites'] as List : const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((s) => s['consent'] == true && s['home'] is Map)
          .toList();
      await p.setInt(_prefAt, now);
      if (sites.isEmpty) return 0;
      final pos = await (locate ?? _locate)();
      if (pos == null) return 0;
      final reports = reportsFor(sites, pos.lat, pos.lng, pos.acc);
      if (reports.isEmpty) return 0;
      await src.presence(reports);
      return reports.length;
    } catch (_) {
      return 0;
    }
  }

  static Future<({double lat, double lng, double acc})?> _locate() async {
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) {
      return null;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
    ).timeout(const Duration(seconds: 8));
    return (lat: pos.latitude, lng: pos.longitude, acc: pos.accuracy);
  }
}
