import 'dart:async';
import 'dart:io' show Platform;

/// proof-notif — keep the reminder LIST fresh while Assisto is open, so the
/// phone's own alarm is set for reminders made somewhere else.
///
/// The bug: the list was fetched from the server only on a cold start (and
/// after the app's own edits / AI chat confirms). A reminder created while
/// Assisto sat in front or in memory — by the AI on another device, by a
/// family member ("Mom, take your medicine" = a family task), from the
/// website — got no phone alarm until the app was fully restarted. With the
/// app then swiped away, only the server's backup push could ring it.
///
/// Now the list re-syncs (and the sync's change notification re-plans the
/// alarms, ReminderAlarms via AppState.syncReminderAlarms):
///   * at once when a reminder / family-task push arrives in the foreground;
///   * when the app comes back to the front (throttled: [minGap]);
///   * every [period] while the app is in front (light: one GET of the list;
///     a Dart Timer only — no WorkManager, nothing runs in the background).
class ReminderFreshness {
  ReminderFreshness({
    required this.sync,
    DateTime Function()? clock,
    this.minGap = const Duration(seconds: 60),
    this.period = const Duration(minutes: 10),
  }) : _clock = clock ?? DateTime.now;

  final Future<void> Function() sync;
  final DateTime Function() _clock;
  final Duration minGap;
  final Duration period;

  DateTime? _last;
  bool _busy = false;
  Timer? _timer;

  /// Set from the app lifecycle (resumed = true, paused = false).
  bool foreground = true;

  DateTime? get lastSync => _last;
  bool get periodicOn => _timer != null;

  /// Push data that means "your reminder list changed on the server".
  static bool isReminderChange(Map<String, dynamic> data) {
    final kind = '${data['kind'] ?? ''}';
    final type = '${data['type'] ?? ''}';
    return kind == 'reminder' ||
        kind == 'family_task' ||
        type == 'family_task' ||
        '${data['route'] ?? ''}' == 'reminders';
  }

  /// Sync now unless one ran less than [minGap] ago ([force] skips that).
  /// Returns whether a sync was started. Never throws.
  Future<bool> kick({bool force = false}) async {
    if (_busy) return false;
    final now = _clock();
    final last = _last;
    if (!force && last != null && now.difference(last) < minGap) return false;
    _busy = true;
    _last = now;
    try {
      await sync();
    } catch (_) {
      // offline / server down: the next trigger retries
    } finally {
      _busy = false;
    }
    return true;
  }

  /// Start the in-front periodic sync (idempotent). Not in widget tests:
  /// a pending periodic timer would fail every test that builds AppState.
  void startPeriodic() {
    if (_timer != null || _inFlutterTest) return;
    _timer = Timer.periodic(period, (_) {
      if (foreground) unawaited(kick());
    });
  }

  void stopPeriodic() {
    _timer?.cancel();
    _timer = null;
  }

  static bool get _inFlutterTest {
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }
}
