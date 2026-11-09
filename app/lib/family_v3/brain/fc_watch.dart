import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../config.dart';
import '../../services/journey_tracker.dart' show readBatteryLevel;
import 'fc_brain_api.dart';
import 'fc_geofence.dart';

/// fcbrain — the phone side of Family Care v3 BRAIN 2 + 3.
///
///  * [onAppOpen] (every app open / resume, throttled 10 min, never throws):
///    one heartbeat ping (battery, charging, network, background limits,
///    time zone) so the family card is honest even without the watch; the
///    15 % last-location share once per discharge while Assisto is open; and
///    the native FamilyWatchService brought back if the member left it on.
///  * [enable] / [disable]: the member's OWN switch "tell my family when I
///    arrive" (server consent first, then the scoped token + the saved places
///    as fences go to the native service).
/// Everything is lazy: nothing here runs at launch, no WorkManager, no
/// background location permission.
class FcWatch {
  FcWatch._();

  static const MethodChannel _ch = MethodChannel('com.assisto/family_watch');
  static const _kAt = 'fcb_ping_at';
  static const _kLowArmed = 'fcb_low_armed';
  static const gap = Duration(minutes: 10);
  static final FcLowBattery _low = FcLowBattery();

  /// Notification texts (localized by the caller).
  static Map<String, String> texts({required String title, required String body}) =>
      {'title': title, 'body': body};

  static Future<Map<String, dynamic>> device() async {
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('device');
      if (m != null) return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      // older build / iOS / test: battery only
    }
    final b = await readBatteryLevel();
    return {if (b != null) 'battery': b};
  }

  static Future<Map<String, dynamic>> counters() async {
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('counters');
      if (m != null) return m.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      // not available: the settings screen shows "measured on the phone only"
    }
    return const {};
  }

  static Future<bool> running() async {
    try {
      return await _ch.invokeMethod<bool>('running') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _isOn() async {
    try {
      return await _ch.invokeMethod<bool>('isOn') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The body every ping carries.
  static Future<Map<String, dynamic>> pingBody({List<Map<String, dynamic>> events = const []}) async {
    final d = await device();
    final watch = await running();
    return {
      ...d..remove('battery_optimised'),
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
      'watch_on': watch,
      'interval_s': watch ? 3600 : 10800,
      'events': <Map<String, dynamic>>[...events],
    };
  }

  static Future<void> onAppOpen(ApiClient api,
      {Map<String, String> notif = const {}, bool force = false}) async {
    try {
      final p = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now - (p.getInt(_kAt) ?? 0) < gap.inMilliseconds) return;
      await p.setInt(_kAt, now);
      final body = await pingBody();
      _low.armed = p.getBool(_kLowArmed) ?? true;
      final pct = (body['battery'] as num?)?.toInt();
      if (_low.check(pct, body['charging'] == true)) {
        final pos = await _locate();
        (body['events'] as List).add({
          'id': 'fab-$now',
          'kind': 'battery_low',
          'at': DateTime.now().toUtc().toIso8601String(),
          if (pos != null) ...{'lat': pos.latitude, 'lng': pos.longitude, 'acc': pos.accuracy.round()},
        });
      }
      await p.setBool(_kLowArmed, _low.armed);
      final r = await api.fcbPing(body);
      // the member left the watch on but Android / an update stopped it
      if (r['paused'] != true && await _isOn() && !await running()) {
        await _startNative(api, notif);
      }
    } catch (_) {
      // best-effort: offline / logged out — the next open retries
    }
  }

  static Future<Position?> _locate() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.always && perm != LocationPermission.whileInUse) return null;
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      return await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  /// true when the open app may start the location watch (asks once; the
  /// screen shows its own prominent disclosure BEFORE calling this).
  static Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      return perm == LocationPermission.whileInUse || perm == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _startNative(ApiClient api, Map<String, String> notif) async {
    try {
      final w = await api.fcbWatch();
      final tok = (w['token'] ?? '').toString();
      if (tok.isEmpty) return false;
      return await _ch.invokeMethod<bool>('start', {
            'token': tok,
            'api': AppConfig.apiBase + AppConfig.apiPrefix,
            'fences': jsonEncode(w['fences'] ?? const []),
            'title': notif['title'] ?? '',
            'body': notif['body'] ?? '',
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The member's own "tell my family when I arrive" ON. Returns
  /// 'on' | 'no_permission' | 'no_places' | 'error'.
  static Future<String> enable(ApiClient api, Map<String, String> notif) async {
    try {
      if (!await ensurePermission()) return 'no_permission';
      await api.fcbSetPrefs({'auto_arrive': true});
      final w = await api.fcbWatch();
      if ((w['fences'] as List?)?.isEmpty ?? true) {
        // consent is kept; the watch starts once a place is saved
        return 'no_places';
      }
      final ok = await _startNative(api, notif);
      await onAppOpen(api, notif: notif, force: true);
      return ok ? 'on' : 'error';
    } catch (_) {
      return 'error';
    }
  }

  static Future<void> disable(ApiClient api) async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {
      // not running
    }
    try {
      await api.fcbSetPrefs({'auto_arrive': false});
    } catch (_) {
      // the server token is revoked on the next successful call
    }
  }
}
