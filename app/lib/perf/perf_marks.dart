// perf2gb: startup timing marks for the CI 2 GB performance run
// (.github/workflows/perf2gb.yml). Compiled in ONLY when the build passes
// --dart-define=ASSISTO_PERF=true (the CI profile APK); in every shipped
// build [enabled] is a const false, so each call is a no-op the compiler drops.
//
// A mark prints `ASSISTO_PERF <name> <epoch ms>` to logcat. The host script
// (tools/perf2gb/run_perf.sh) reads the device-clock epoch just before
// `am start` and subtracts, so no Dart-side process-start clock is needed.
import 'package:flutter/foundation.dart';

class PerfMarks {
  PerfMarks._();

  static const bool enabled = bool.fromEnvironment('ASSISTO_PERF');
  static final Set<String> _once = <String>{};

  /// Print [name] once per process (later calls with the same name are ignored).
  static void once(String name) {
    if (!enabled) return;
    if (!_once.add(name)) return;
    mark(name);
  }

  static void mark(String name) {
    if (!enabled) return;
    // ignore: avoid_print
    print('ASSISTO_PERF $name ${DateTime.now().millisecondsSinceEpoch}');
  }

  @visibleForTesting
  static void resetForTest() => _once.clear();
}
