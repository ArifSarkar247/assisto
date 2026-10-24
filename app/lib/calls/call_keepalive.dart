import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'call_log.dart';

/// play-fgs: id of the ongoing-call notification's "Hang up" button.
const String kCallHangupButton = 'call_hangup';

/// Task-isolate entry point for the call keep-alive: it only forwards the
/// notification's Hang up button to the app (the call lives in the app).
@pragma('vm:entry-point')
void callKeepAliveStartCallback() {
  FlutterForegroundTask.setTaskHandler(_CallKeepAliveHandler());
}

class _CallKeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == kCallHangupButton) {
      FlutterForegroundTask.sendDataToMain(kCallHangupButton);
    }
  }
}

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

  /// play-fgs: what the notification's Hang up button does (the call screen
  /// passes its own hang-up). Cleared on stop.
  static Future<void> Function()? _onHangup;

  static void _onData(Object data) {
    if (data == kCallHangupButton) {
      final h = _onHangup;
      if (h != null) h().catchError((Object e) => callLog('keepalive#hangup', e));
    }
  }

  static Future<void> start({
    required String channelName,
    required String title,
    required String text,
    String hangupLabel = 'Hang up',
    Future<void> Function()? onHangup,
  }) async {
    if (onHangup != null) _onHangup = onHangup;
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
        notificationButtons: [
          NotificationButton(id: kCallHangupButton, text: hangupLabel),
        ],
        callback: callKeepAliveStartCallback,
      );
      if (r is ServiceRequestSuccess) {
        FlutterForegroundTask.removeTaskDataCallback(_onData);
        FlutterForegroundTask.addTaskDataCallback(_onData);
      }
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
    _onHangup = null;
    try {
      FlutterForegroundTask.removeTaskDataCallback(_onData);
    } catch (_) {}
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
