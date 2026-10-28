import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'crash_scrub.dart';

/// ops-watch — why did the PREVIOUS run of the app die? Android keeps the
/// answer (ApplicationExitInfo, API 30+): ANR, Java crash or native crash.
/// The Dart crash reporter cannot see those deaths itself, so our own crash /
/// ANR rate (Owner Admin → Crash rate) would miss them.
///
/// Native side: ExitInfoChannel.kt ("com.assisto/exit_info"), a handler only;
/// the lookup runs on a background thread when [pending] is called. Called by
/// [CrashReporter] once per session, ~20 s after start, signed-in users only.
/// Every call is time-boxed and never throws.
class ExitInfo {
  const ExitInfo();

  static const _ch = MethodChannel('com.assisto/exit_info');

  /// Exits not yet reported (oldest first). [] off Android / on any error.
  Future<List<Map<String, dynamic>>> pending() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
    try {
      final r = await _ch
          .invokeMethod<List<dynamic>>('pending')
          .timeout(const Duration(seconds: 5));
      final out = <Map<String, dynamic>>[
        for (final e in r ?? const [])
          if (e is Map) e.map((k, v) => MapEntry('$k', v)),
      ];
      out.sort((a, b) => _ts(a).compareTo(_ts(b)));
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Remember that exits up to [ts] were reported.
  Future<void> ack(int ts) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _ch.invokeMethod('ack', {'ts': ts}).timeout(
          const Duration(seconds: 3));
    } catch (_) {}
  }

  static int _ts(Map<String, dynamic> e) {
    final v = e['ts'];
    return v is int ? v : (v is num ? v.toInt() : 0);
  }

  /// The /client/crash-report body for one exit (scrubbed; no frames — the
  /// server groups exits by kind + where).
  static Map<String, dynamic>? body(Map<String, dynamic> e) {
    final kind = '${e['kind'] ?? ''}';
    if (kind != 'anr' && kind != 'exit_crash') return null;
    final native = e['native'] == true;
    final where = kind == 'anr'
        ? 'exit.anr'
        : (native ? 'exit.native' : 'exit.java');
    return {
      'v': 2,
      'kind': kind,
      'error_type':
          kind == 'anr' ? 'ANR' : (native ? 'NativeCrash' : 'JavaCrash'),
      'message': CrashScrub.message('${e['description'] ?? ''}'),
      'frames': const <String>[],
      'fatal': kind != 'anr',
      'where': where,
      'occurred_ms': _ts(e),
    };
  }
}
