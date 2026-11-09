import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
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
///    arrive" (server consent first, then the saved places as fences).
///  * Owner decision 9 Nov 14:20: the native BACKGROUND watch runs only
///    while the server switch family_auto_arrival is ON (Play background-
///    location declaration approved). While it is OFF the server gives no
///    token and arrival news works in FOREGROUND mode: the same fence rule
///    ([FcFenceEngine]) checks a fix every minute while Assisto is open;
///    when it is closed the family card turns honestly gray ("No news").
/// Everything is lazy: nothing here runs at launch, no WorkManager, no
/// background location permission.
class FcWatch {
  FcWatch._();

  static const MethodChannel _ch = MethodChannel('com.assisto/family_watch');
  static const _kAt = 'fcb_ping_at';
  static const _kLowArmed = 'fcb_low_armed';
  static const _kFences = 'fcb_fences';
  static const _kInside = 'fcb_inside';
  static const _kAuto = 'fcb_auto';
  static const _kNextAt = 'fcb_next_at';
  static const fgEvery = Duration(seconds: 60);
  static Timer? _fg;
  static bool _fgBusy = false;
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
      if (p.getBool(_kAuto) == true && !await running()) _startForeground(api);
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

  /// FOREGROUND mode: one fence check now and every [fgEvery] while the app
  /// is in front (the timer skips when it is not). No service, no
  /// notification, nothing when Assisto is closed.
  static void _startForeground(ApiClient api) {
    unawaited(foregroundCheck(api));
    _fg ??= Timer.periodic(fgEvery, (_) {
      final st = WidgetsBinding.instance.lifecycleState;
      if (st == null || st == AppLifecycleState.resumed) unawaited(foregroundCheck(api));
    });
  }

  static void _stopForeground() {
    _fg?.cancel();
    _fg = null;
  }

  /// One foreground fence check -> arrive / leave events to the server.
  /// Returns the events sent (tests).
  static Future<List<Map<String, dynamic>>> foregroundCheck(ApiClient api,
      {Future<Position?> Function()? locate}) async {
    if (_fgBusy) return const [];
    _fgBusy = true;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_kAuto) != true) return const [];
      final raw = p.getString(_kFences);
      final fences = raw == null
          ? <FcFence>[]
          : (jsonDecode(raw) as List).map(FcFence.fromJson).whereType<FcFence>().toList();
      if (fences.isEmpty) return const [];
      // the same battery policy as the native watch: no fix before it is due
      final due = p.getInt(_kNextAt) ?? 0;
      if (locate == null && DateTime.now().millisecondsSinceEpoch < due) return const [];
      final pos = await (locate ?? _locate)();
      if (pos == null) return const [];
      final eng = FcFenceEngine(fences);
      final saved = p.getString(_kInside);
      if (saved != null) {
        eng.inside.addAll((jsonDecode(saved) as List).map((e) => (e as num).toInt()));
        eng.primed = true;
      }
      final fix = FcFix(pos.latitude, pos.longitude, pos.accuracy, pos.timestamp.toUtc());
      final evs = eng.step(fix);
      await p.setString(_kInside, jsonEncode(eng.inside.toList()));
      await p.setInt(_kNextAt, DateTime.now().millisecondsSinceEpoch + eng.nextDelayS(fix) * 1000);
      if (evs.isEmpty) return const [];
      final now = DateTime.now().toUtc();
      final out = [
        for (final e in evs)
          {
            'id': 'fg-${fix.at.millisecondsSinceEpoch}-${e.fence.id}-${e.kind}',
            'kind': e.kind,
            'at': now.toIso8601String(),
            'crossed_at': fix.at.toIso8601String(),
            'place_id': e.fence.id,
            'place_kind': e.fence.kind,
            'place_label': e.fence.label,
          }
      ];
      await api.fcbPing(await pingBody(events: out));
      return out;
    } catch (_) {
      return const []; // best-effort: the next minute retries
    } finally {
      _fgBusy = false;
    }
  }

  static Future<bool> _startNative(ApiClient api, Map<String, String> notif) async {
    try {
      final w = await api.fcbWatch();
      await _saveFences(w);
      final tok = (w['token'] ?? '').toString();
      if (tok.isEmpty) return false; // owner switch OFF -> foreground mode
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

  static Future<void> _saveFences(Map<String, dynamic> w) async {
    final p = await SharedPreferences.getInstance();
    final f = jsonEncode(w['fences'] ?? const []);
    if (p.getString(_kFences) != f) {
      await p.setString(_kFences, f);
      await p.remove(_kInside); // new places: learn where we are first
    }
  }

  /// The member's own "tell my family when I arrive" ON. Returns
  /// 'on' (background watch) | 'foreground' (owner switch OFF: while the
  /// app is open) | 'no_permission' | 'no_places' | 'error'.
  static Future<String> enable(ApiClient api, Map<String, String> notif) async {
    try {
      if (!await ensurePermission()) return 'no_permission';
      await api.fcbSetPrefs({'auto_arrive': true});
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAuto, true);
      final w = await api.fcbWatch();
      await _saveFences(w);
      if ((w['fences'] as List?)?.isEmpty ?? true) {
        // consent is kept; the watch starts once a place is saved
        return 'no_places';
      }
      if (w['mode'] != 'background') {
        _startForeground(api);
        await onAppOpen(api, notif: notif, force: true);
        return 'foreground';
      }
      final ok = await _startNative(api, notif);
      await onAppOpen(api, notif: notif, force: true);
      return ok ? 'on' : 'error';
    } catch (_) {
      return 'error';
    }
  }

  static Future<void> disable(ApiClient api) async {
    _stopForeground();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAuto, false);
      await p.remove(_kInside);
    } catch (_) {
      // nothing stored
    }
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
