import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../feature_flags.dart';
import '../missing_alert_api.dart';

/// missing (owner 2 Nov): nearby safety alerts use the user's area ONLY while
/// Assisto is OPEN. When the user turned on "update my area when I open
/// Assisto", each app open/resume (at most every 2 h) sends ONE point rounded
/// to ~1 km. Never asks for a permission here (the opt-in screen does, once),
/// never runs in the background, never throws.
class MissingNearbySync {
  MissingNearbySync._();

  static const prefOn = 'ma_open_loc';
  static const _prefAt = 'ma_open_loc_at';
  static const gap = Duration(hours: 2);

  static Future<void> setEnabled(bool on) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefOn, on);
      if (!on) await p.remove(_prefAt);
    } catch (_) {}
  }

  static Future<bool> maybeSend(ApiClient api,
      {Future<({double lat, double lng})?> Function()? locate}) async {
    try {
      if (!FeatureFlags.instance.isOn('missing_alert')) return false;
      final p = await SharedPreferences.getInstance();
      if (p.getBool(prefOn) != true) return false;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - (p.getInt(_prefAt) ?? 0) < gap.inMilliseconds) return false;
      final pos = await (locate ?? _locate)();
      if (pos == null) return false;
      await p.setInt(_prefAt, now);
      await api.maWhereIAm(maCoarse(pos.lat), maCoarse(pos.lng));
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<({double lat, double lng})?> _locate() async {
    final perm = await Geolocator.checkPermission();
    if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) {
      return null;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    // a fresh fix only (a "last known" one can be days old = a wrong area)
    final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
        ).timeout(const Duration(seconds: 8));
    return (lat: pos.latitude, lng: pos.longitude);
  }
}
