// cctvbox — PURE Guard Box rules (no Flutter, no I/O), unit-tested:
// what an alert is, when a check may run, the health report, the live
// picture rate.
import '../phonecam/phonecam_logic.dart' show healthReport;

/// The alert for one motion event on an IP camera watched by this phone.
/// Same rules as the phone camera (phonecam_logic.phoneAlert): with the
/// on-phone person model only a PERSON alerts; without it, movement alerts
/// and says honestly that no person check ran.
({String type, Map<String, dynamic> signals})? ipcamAlert(
    {required bool modelAvailable, List<List<double>>? boxes, String brand = ''}) {
  final base = <String, dynamic>{
    'source': 'ip_camera_via_phone',
    if (brand.isNotEmpty) 'camera_brand': brand,
  };
  if (!modelAvailable) {
    return (
      type: 'motion',
      signals: {
        ...base,
        'detector': 'android_frame_diff',
        'person_check': 'unavailable',
        'multiple_frames': true,
      }
    );
  }
  if (boxes == null || boxes.isEmpty) return null;
  var best = 0.0;
  for (final b in boxes) {
    if (b.length >= 5 && b[4] > best) best = b[4];
  }
  return (
    type: 'person_detected',
    signals: {
      ...base,
      'detector': 'yolox_nano_phone',
      'conf': double.parse(best.toStringAsFixed(2)),
      'persons': boxes.length,
    }
  );
}

/// Cool-downs: one alert a minute with the person check, one every 3 min on
/// movement only; a person check at most every 5 s (old phones).
class AlertClock {
  final Duration personCooldown;
  final Duration motionCooldown;
  final Duration checkEvery;
  DateTime? lastAlert, lastCheck;
  AlertClock({
    this.personCooldown = const Duration(seconds: 60),
    this.motionCooldown = const Duration(minutes: 3),
    this.checkEvery = const Duration(seconds: 5),
  });

  bool mayCheck(DateTime now, {required bool model}) {
    final la = lastAlert;
    if (la != null && now.difference(la) < (model ? personCooldown : motionCooldown)) return false;
    final lc = lastCheck;
    if (lc != null && now.difference(lc) < checkEvery) return false;
    return true;
  }
}

/// Heartbeat health: the phone's battery + the camera's state. `cam_lost`
/// is reported after [lostFor] without pictures (the owner gets ONE push:
/// "the IP camera can't be reached from the guard phone").
Map<String, dynamic> ipcamHealth(Map? battery,
    {required bool dark, DateTime? lostSince, DateTime? now, Duration lostFor = const Duration(minutes: 2)}) {
  final out = healthReport(battery, dark: dark);
  final n = now ?? DateTime.now();
  if (lostSince != null && n.difference(lostSince) >= lostFor) out['cam_lost'] = true;
  return out;
}

/// Live picture pacing on the guard phone: SD = 640 px, HD = 1280 px wide;
/// at most [fps] pictures a second, and only when the viewer acknowledged
/// the previous one (so a slow relay never queues minutes of pictures).
class LivePace {
  final int fps;
  bool hd = false;
  LivePace({this.fps = 4});
  int get maxW => hd ? 1280 : 640;
  Duration get every => Duration(milliseconds: 1000 ~/ fps);
}

/// A plain-language reason for a failed camera test (ARB key suffix).
String failKey(String kind) => switch (kind) {
      'auth' => 'auth',
      'unreachable' => 'unreachable',
      'notFound' => 'notFound',
      'codec' => 'codec',
      'decoder' => 'decoder',
      _ => 'noVideo',
    };

/// Alerts made while the internet is down wait here (newest kept, at most
/// [max]) and go out, oldest first, when the server answers again — with the
/// time they really happened in the signals.
class OfflineQueue<T> {
  final int max;
  final _items = <T>[];
  int droppedOld = 0;
  OfflineQueue({this.max = 20});
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;

  void add(T item) {
    _items.add(item);
    while (_items.length > max) {
      _items.removeAt(0);
      droppedOld++;
    }
  }

  /// Send oldest first; stops at the first failure (still offline).
  Future<int> flush(Future<bool> Function(T item) send) async {
    var sent = 0;
    while (_items.isNotEmpty) {
      if (!await send(_items.first)) break;
      _items.removeAt(0);
      sent++;
    }
    return sent;
  }
}

/// speedproof: how often a guarding phone asks "does someone want live view?"
/// from the server's `live_poll_s` (heartbeat). 0 or less = off (only the
/// 20 s heartbeat, as before); otherwise 2..60 s. The CI live test took
/// 17.4 s to the first picture when only the heartbeat carried the request.
Duration? livePollEvery(int seconds) =>
    seconds <= 0 ? null : Duration(seconds: seconds.clamp(2, 60));
