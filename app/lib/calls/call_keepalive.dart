import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'call_log.dart';

/// Keeps the microphone working when the user leaves the app during a call
/// (Android 11+ blocks background mic access without a foreground service).
/// Reuses the app's existing flutter_foreground_task service (declared in the
/// manifest with type microphone|location for voice SOS) with type
/// MICROPHONE only, started while Assisto is on screen (Android 14 rule) and
/// stopped when the call ends. If voice SOS already runs the service, the
/// mic is already covered and we leave it alone. Every step crash-guarded.
class CallKeepAlive {
  CallKeepAlive._();
  static bool _ours = false;
  static bool _busy = false;
  static bool _stopAsked = false;
  static const int serviceId = 4711;

  static Future<void> start({
    required String channelName,
    required String title,
    required String text,
  }) async {
    if (_ours || _busy) return;
    _busy = true;
    _stopAsked = false;
    try {
      if (await FlutterForegroundTask.isRunningService) return; // SOS has it
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'assisto_call_ongoing',
          channelName: channelName,
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      final r = await FlutterForegroundTask.startService(
        serviceId: serviceId,
        serviceTypes: const [ForegroundServiceTypes.microphone],
        notificationTitle: title,
        notificationText: text,
      );
      _ours = r is ServiceRequestSuccess;
      if (_ours && _stopAsked) {
        _busy = false;
        await stop();
      }
    } catch (e) {
      callLog('keepalive#start', e);
    } finally {
      _busy = false;
    }
  }

  static Future<void> stop() async {
    if (_busy) _stopAsked = true;
    if (!_ours) return;
    _ours = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      callLog('keepalive#stop', e);
    }
  }
}
