import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../state.dart';

/// journey100 — live location for the user's OWN active Safe Journey.
///
/// * Started only when the user starts (or reopens) a journey, stopped the
///   moment it arrives / stops / the server says it is over.
/// * Keeps working with the screen off: Assisto's existing foreground service
///   (flutter_foreground_task, declared `microphone|location`) is started
///   with type LOCATION ONLY, while the app is on screen (Android 14 rule),
///   with a visible "Safe Journey is on" notification. No
///   ACCESS_BACKGROUND_LOCATION: a location-type foreground service started
///   from the foreground keeps the while-in-use permission. If another Assisto
///   service (voice SOS) already runs, it already covers location and we only
///   add our timer.
/// * Store-and-forward: every fix is queued on the phone first (max
///   [kMaxQueue], oldest dropped) and sent as one batch when the network is
///   back; the server de-duplicates, orders and checks each point.
/// * Battery % rides along with each fix (native channel, no permission) —
///   the server alerts watchers below 15 % ("last location").
///
/// Everything is lazy and crash-guarded: a failing plugin never breaks the
/// journey screen; the honest state ([JourneyTrackState]) tells the UI.
const int kMaxQueue = 300;
const Duration kTickEvery = Duration(seconds: 30);
const String kQueueKey = 'journey_fix_queue';
const String kActiveKey = 'journey_active_id';
const String kPhonesKey = 'journey_sms_phones';
const String kJourneyTickMsg = 'journey_tick';
const String kJourneyAliveMsg = 'journey_alive';
const String kServiceOwnKey = 'journey_service_own';

class JourneyFix {
  final double lat, lng;
  final DateTime at;
  final int? battery;
  const JourneyFix(this.lat, this.lng, this.at, [this.battery]);

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'at': at.toUtc().toIso8601String(),
        if (battery != null) 'battery': battery,
      };

  static JourneyFix? fromJson(Object? m) {
    if (m is! Map) return null;
    final lat = (m['lat'] as num?)?.toDouble();
    final lng = (m['lng'] as num?)?.toDouble();
    final at = DateTime.tryParse('${m['at']}');
    if (lat == null || lng == null || at == null) return null;
    return JourneyFix(lat, lng, at, (m['battery'] as num?)?.toInt());
  }
}

/// Pure offline queue (persisted as JSON by the tracker).
class JourneyFixQueue {
  final List<JourneyFix> items = [];

  void add(JourneyFix f) {
    items.add(f);
    while (items.length > kMaxQueue) {
      items.removeAt(0);
    }
  }

  /// Drop the first [n] (they reached the server).
  void ack(int n) => items.removeRange(0, n.clamp(0, items.length));

  String encode() => jsonEncode(items.map((f) => f.toJson()).toList());

  static JourneyFixQueue decode(String? raw) {
    final q = JourneyFixQueue();
    if (raw == null || raw.isEmpty) return q;
    try {
      for (final m in (jsonDecode(raw) as List)) {
        final f = JourneyFix.fromJson(m);
        if (f != null) q.items.add(f);
      }
    } catch (_) {
      // best-effort: a corrupt queue is dropped (fixes are re-taken next tick)
    }
    return q;
  }
}

enum JourneyNet { unknown, ok, offline }

/// What the live screen shows. Never optimistic: `lastSentAt` is the last
/// time the SERVER confirmed a batch.
class JourneyTrackState {
  final int? journeyId;
  final String status; // active | arrived | stopped | expired
  final String overdue; // on_time | grace | ask | alert | no_eta ...
  final int overdueMinutes;
  final JourneyNet net;
  final bool locationOff;
  final bool serviceOn; // the screen-off foreground service is running
  final int queued;
  final DateTime? lastSentAt;
  final JourneyFix? lastFix;
  const JourneyTrackState({
    this.journeyId,
    this.status = 'active',
    this.overdue = 'on_time',
    this.overdueMinutes = 0,
    this.net = JourneyNet.unknown,
    this.locationOff = false,
    this.serviceOn = false,
    this.queued = 0,
    this.lastSentAt,
    this.lastFix,
  });

  JourneyTrackState copyWith({
    String? status,
    String? overdue,
    int? overdueMinutes,
    JourneyNet? net,
    bool? locationOff,
    bool? serviceOn,
    int? queued,
    DateTime? lastSentAt,
    JourneyFix? lastFix,
  }) =>
      JourneyTrackState(
        journeyId: journeyId,
        status: status ?? this.status,
        overdue: overdue ?? this.overdue,
        overdueMinutes: overdueMinutes ?? this.overdueMinutes,
        net: net ?? this.net,
        locationOff: locationOff ?? this.locationOff,
        serviceOn: serviceOn ?? this.serviceOn,
        queued: queued ?? this.queued,
        lastSentAt: lastSentAt ?? this.lastSentAt,
        lastFix: lastFix ?? this.lastFix,
      );
}

typedef JourneyPositionFn = Future<({double lat, double lng})?> Function();
typedef JourneyBatteryFn = Future<int?> Function();
typedef JourneySendFn = Future<Map<String, dynamic>> Function(
    int journeyId, List<Map<String, dynamic>> points);

/// Task-isolate entry point. While the app's main isolate is alive it sends
/// a heartbeat each tick and does the work itself; if the heartbeat stops
/// (Assisto swiped away from recents, so the screen engine is gone) the
/// service isolate takes fixes and posts them itself with the session it was
/// handed in memory (never written to disk).
@pragma('vm:entry-point')
void journeyServiceStartCallback() {
  FlutterForegroundTask.setTaskHandler(JourneyTaskHandler());
}

class JourneyTaskHandler extends TaskHandler {
  String? _url, _auth, _lang;
  DateTime? _alive;
  final JourneyFixQueue _q = JourneyFixQueue();
  bool _busy = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onReceiveData(Object data) {
    if (data == kJourneyAliveMsg) {
      _alive = DateTime.now();
    } else if (data is Map) {
      _url = data['url']?.toString();
      _auth = data['auth']?.toString();
      _lang = data['lang']?.toString();
      _alive = DateTime.now();
    }
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    FlutterForegroundTask.sendDataToMain(kJourneyTickMsg);
    final alive = _alive;
    if (alive != null && DateTime.now().difference(alive) < const Duration(seconds: 75)) {
      return; // the app does the work
    }
    if (_url == null || _auth == null || _busy) return;
    _busy = true;
    try {
      final pos = await _defaultPosition();
      if (pos != null) _q.add(JourneyFix(pos.lat, pos.lng, DateTime.now()));
      if (_q.items.isEmpty) return;
      final batch = _q.items.take(100).toList();
      final r = await http.post(Uri.parse(_url!),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': _auth!,
            'Accept-Language': _lang ?? 'bn',
          },
          body: jsonEncode({'points': batch.map((f) => f.toJson()).toList()}))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode >= 200 && r.statusCode < 300) {
        _q.ack(batch.length);
        final body = jsonDecode(r.body);
        if (body is Map && (body['status'] ?? 'active') != 'active') {
          await FlutterForegroundTask.stopService();
        }
      }
    } catch (_) {
      // best-effort: offline — the fix stays queued in memory for next tick
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class JourneyTracker extends ValueNotifier<JourneyTrackState> {
  JourneyTracker({
    JourneyPositionFn? position,
    JourneyBatteryFn? battery,
    this.useService = true,
    DateTime Function()? clock,
  })  : _position = position ?? _defaultPosition,
        _battery = battery ?? readBatteryLevel,
        _clock = clock ?? DateTime.now,
        super(const JourneyTrackState());

  static final JourneyTracker I = JourneyTracker();

  final JourneyPositionFn _position;
  final JourneyBatteryFn _battery;
  final DateTime Function() _clock;
  final bool useService;
  JourneySendFn? _send;
  Timer? _timer;
  bool _busy = false;
  bool _ownService = false;
  DateTime? _lastTick;
  JourneyFixQueue _queue = JourneyFixQueue();
  Map<String, String>? _session;

  bool get running => value.journeyId != null && value.status == 'active';

  /// Begin (or resume) tracking [journeyId]. Idempotent for the same id.
  Future<void> start(int journeyId, JourneySendFn send,
      {String notifTitle = '',
      String notifText = '',
      Map<String, String>? serviceSession}) async {
    _send = send;
    _session = serviceSession;
    if (value.journeyId == journeyId && _timer != null) {
      unawaited(tick());
      return;
    }
    await stop(keepQueue: true);
    _queue = JourneyFixQueue.decode(await Settings.getString(kQueueKey));
    value = JourneyTrackState(journeyId: journeyId, queued: _queue.items.length);
    await Settings.setString(kActiveKey, '$journeyId');
    // the app-wide tracker inside `flutter test` (gallery / a11y sweeps):
    // one honest tick, no periodic timer or service left behind
    final underTest = useService && _underFlutterTest();
    if (!underTest) {
      _timer = Timer.periodic(kTickEvery, (_) => tick());
      if (useService) await _startService(notifTitle, notifText);
    }
    await tick();
  }

  /// Stop tracking. The persisted queue is cleared unless [keepQueue].
  Future<void> stop({bool keepQueue = false}) async {
    _timer?.cancel();
    _timer = null;
    if (!keepQueue) {
      _queue = JourneyFixQueue();
      await Settings.setString(kQueueKey, '');
      await Settings.setString(kActiveKey, '');
    }
    await _stopService();
    if (value.journeyId != null && !keepQueue) {
      value = JourneyTrackState(
          journeyId: value.journeyId,
          status: value.status == 'active' ? 'stopped' : value.status);
    }
  }

  /// One cycle: take a fix (if location is on), queue it, flush the queue.
  Future<void> tick() async {
    final id = value.journeyId;
    final send = _send;
    if (id == null || send == null || _busy || value.status != 'active') return;
    final now = _clock();
    if (_lastTick != null && now.difference(_lastTick!) < const Duration(seconds: 10)) {
      return; // timer + service wake-ups landing together
    }
    _lastTick = now;
    _busy = true;
    _heartbeat();
    try {
      ({double lat, double lng})? pos;
      try {
        pos = await _position();
      } catch (_) {
        pos = null; // best-effort: shown as "location off" below
      }
      int? batt;
      try {
        batt = await _battery();
      } catch (_) {
        batt = null; // best-effort: battery is optional
      }
      JourneyFix? fix;
      if (pos != null) {
        fix = JourneyFix(pos.lat, pos.lng, now, batt);
        _queue.add(fix);
        await Settings.setString(kQueueKey, _queue.encode());
      }
      value = value.copyWith(
          locationOff: pos == null, queued: _queue.items.length, lastFix: fix);
      if (_queue.items.isEmpty) return;
      final batch = _queue.items.take(100).toList();
      Map<String, dynamic> r;
      try {
        r = await send(id, batch.map((f) => f.toJson()).toList());
      } catch (_) {
        // offline / server down: keep the queue, say so on screen
        value = value.copyWith(net: JourneyNet.offline, queued: _queue.items.length);
        return;
      }
      _queue.ack(batch.length);
      await Settings.setString(kQueueKey, _queue.encode());
      final status = (r['status'] ?? 'active').toString();
      value = value.copyWith(
        net: JourneyNet.ok,
        status: status,
        overdue: (r['overdue_state'] ?? value.overdue).toString(),
        overdueMinutes: (r['overdue_minutes'] as num?)?.toInt() ?? 0,
        queued: _queue.items.length,
        lastSentAt: _clock(),
      );
      if (status != 'active') {
        await stop();
      }
    } finally {
      _busy = false;
    }
  }

  /// The journey ended in the app (arrived / stopped / duress): stop now.
  Future<void> finished(String status) async {
    value = value.copyWith(status: status);
    await stop();
  }

  void _heartbeat() {
    if (!useService || !value.serviceOn) return;
    try {
      FlutterForegroundTask.sendDataToTask(kJourneyAliveMsg);
    } catch (_) {
      // best-effort: no service isolate to tell
    }
  }

  void _onServiceData(Object data) {
    if (data == kJourneyTickMsg) unawaited(tick());
  }

  Future<void> _startService(String title, String text) async {
    try {
      FlutterForegroundTask.initCommunicationPort();
      if (await FlutterForegroundTask.isRunningService) {
        // ours from before the app was reopened, or voice SOS
        // (microphone|location) which already keeps location alive
        _ownService = await Settings.getBool(kServiceOwnKey, false);
      } else {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'assisto_journey',
            channelName: title,
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
            onlyAlertOnce: true,
          ),
          iosNotificationOptions: const IOSNotificationOptions(),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction:
                ForegroundTaskEventAction.repeat(kTickEvery.inMilliseconds),
            autoRunOnBoot: false,
            allowWakeLock: true,
            allowWifiLock: false,
          ),
        );
        final r = await FlutterForegroundTask.startService(
          serviceId: 4712,
          serviceTypes: const [ForegroundServiceTypes.location],
          notificationTitle: title,
          notificationText: text,
          callback: journeyServiceStartCallback,
        );
        _ownService = r is ServiceRequestSuccess;
        await Settings.setBool(kServiceOwnKey, _ownService);
      }
      FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
      FlutterForegroundTask.addTaskDataCallback(_onServiceData);
      final session = _session;
      if (_ownService && session != null) {
        FlutterForegroundTask.sendDataToTask(session);
      }
      value = value.copyWith(serviceOn: await FlutterForegroundTask.isRunningService);
    } catch (_) {
      // best-effort: no service -> tracking continues while the app is open;
      // the live screen shows "keep Assisto open" (serviceOn=false)
      value = value.copyWith(serviceOn: false);
    }
  }

  Future<void> _stopService() async {
    try {
      FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
    } catch (_) {
      // best-effort: nothing registered
    }
    if (!useService) return;
    final own = _ownService || await Settings.getBool(kServiceOwnKey, false);
    _ownService = false;
    if (!own) return;
    await Settings.setBool(kServiceOwnKey, false);
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // best-effort: the service may already be gone
    }
  }

  @visibleForTesting
  JourneyFixQueue get queue => _queue;
}

bool _underFlutterTest() {
  try {
    return !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false; // best-effort: no environment on this platform
  }
}

Future<({double lat, double lng})?> _defaultPosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) return null;
  final perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied ||
      perm == LocationPermission.deniedForever) {
    return null;
  }
  final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
  return (lat: p.latitude, lng: p.longitude);
}

const MethodChannel _journeyChannel = MethodChannel('com.assisto/journey');

/// Battery percent from the native "com.assisto/journey" channel
/// (BatteryManager, no permission). Null when unavailable (older build,
/// iOS, test) — the journey works without it.
Future<int?> readBatteryLevel() async {
  try {
    final v = await _journeyChannel.invokeMethod<int>('batteryLevel');
    return (v != null && v >= 0 && v <= 100) ? v : null;
  } catch (_) {
    return null; // best-effort: optional signal
  }
}

/// The user-tapped SMS fallback: opens the phone's own SMS app with the
/// recipients and text filled in. The USER presses Send (their SIM, their
/// cost) — Assisto has no SMS permission.
Uri journeySmsUri(List<String> phones, String body) {
  final to = phones
      .map((p) => p.replaceAll(RegExp(r'[^0-9+]'), ''))
      .where((p) => p.length >= 6)
      .toSet()
      .join(',');
  return Uri.parse('sms:$to?body=${Uri.encodeComponent(body)}');
}

/// Google Maps link for a position (works in any browser / maps app).
String journeyMapsLink(double lat, double lng) =>
    'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
