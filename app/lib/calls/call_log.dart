import 'package:flutter/foundation.dart';

/// c2-calls: every guarded failure on the call path is recorded here instead
/// of being swallowed silently — visible in debug logs and kept (last 50) so
/// a bug report / the call screen's debug trace can show what went wrong.
/// The USER-facing honesty is the call phase / end reason itself.
class CallLog {
  CallLog._();
  static final List<String> recent = <String>[];

  static void add(String where, Object e) {
    final line = '${DateTime.now().toIso8601String()} $where: $e';
    recent.add(line);
    if (recent.length > 50) recent.removeAt(0);
    if (kDebugMode) debugPrint('call: $line');
  }
}

void callLog(String where, Object e) {
  try {
    CallLog.add(where, e);
  } catch (_) {
    // logging must never throw into the call path
  }
}
