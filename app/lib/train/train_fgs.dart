import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// train: ONE location foreground service shared by "I am on this train"
/// sharing and the destination alarm. Started only while one of them is on
/// (from the foreground, with a visible notification that has a Stop
/// button), stopped the moment both are off. If another Assisto service
/// (Safe Journey / voice SOS) already runs, it already keeps location alive
/// and we do not start a second one. No WorkManager, nothing at launch.
const String kTrainTickMsg = 'train_tick';
const String kTrainStopMsg = 'train_stop';
const String kTrainStopButton = 'train_stop_btn';
const int kTrainServiceId = 4713;

@pragma('vm:entry-point')
void trainServiceStartCallback() {
  FlutterForegroundTask.setTaskHandler(TrainTaskHandler());
}

class TrainTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    FlutterForegroundTask.sendDataToMain(kTrainTickMsg);
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == kTrainStopButton) FlutterForegroundTask.sendDataToMain(kTrainStopMsg);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

typedef TrainFgsListener = void Function(String msg);

class TrainFgs {
  TrainFgs._();
  static final TrainFgs I = TrainFgs._();

  /// Tests / gallery: no platform service.
  static bool disabled = false;

  final Set<String> _owners = {};
  final Map<String, TrainFgsListener> _listeners = {};
  bool _own = false;
  bool running = false;

  Set<String> get owners => Set.unmodifiable(_owners);

  Future<bool> acquire(String owner, TrainFgsListener onMsg,
      {required String title, required String text, required String stopLabel}) async {
    _owners.add(owner);
    _listeners[owner] = onMsg;
    if (disabled) return false;
    try {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.removeTaskDataCallback(_onData);
      FlutterForegroundTask.addTaskDataCallback(_onData);
      if (await FlutterForegroundTask.isRunningService) {
        if (_own) {
          await FlutterForegroundTask.updateService(
              notificationTitle: title, notificationText: text);
        }
        running = true;
        return true;
      }
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'assisto_train',
          channelName: title,
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(5000),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: false,
        ),
      );
      final r = await FlutterForegroundTask.startService(
        serviceId: kTrainServiceId,
        serviceTypes: const [ForegroundServiceTypes.location],
        notificationTitle: title,
        notificationText: text,
        notificationButtons: [NotificationButton(id: kTrainStopButton, text: stopLabel)],
        callback: trainServiceStartCallback,
      );
      _own = r is ServiceRequestSuccess;
      running = _own;
      return _own;
    } catch (e) {
      if (kDebugMode) print('train fgs start failed: $e');
      running = false;
      return false; // best-effort: works while the app is open
    }
  }

  Future<void> release(String owner) async {
    _owners.remove(owner);
    _listeners.remove(owner);
    if (_owners.isNotEmpty || disabled) return;
    try {
      FlutterForegroundTask.removeTaskDataCallback(_onData);
    } catch (_) {
      // best-effort: nothing registered
    }
    if (_own) {
      _own = false;
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {
        // best-effort: already gone
      }
    }
    running = false;
  }

  void _onData(Object data) {
    if (data is! String) return;
    for (final l in List.of(_listeners.values)) {
      l(data);
    }
  }
}
