import 'package:flutter/foundation.dart';

import 'crash_reporter.dart';

/// sc1 — one seam for "something went wrong but the app carries on".
/// Public entry point for app code: `reportNonFatal` in
/// lib/services/error_report.dart.
///
/// Reports go to [CrashReporter.instance] (in-memory buffer until the reporter
/// has started after the first frame and the user consented; scrubbed before
/// anything leaves the phone). [sink] overrides that (tests). Callers pass an
/// error OBJECT — never a stored value, message text, key or phone number.
typedef NonFatalSink = void Function(String where, Object error,
    StackTrace? stack);

class NonFatal {
  NonFatal._();

  static NonFatalSink? sink;

  /// Last few "where: ErrorType" lines (diagnostics/tests; no messages).
  static final List<String> recent = <String>[];

  static void report(String where, Object error, [StackTrace? stack]) {
    try {
      recent.add('$where: ${error.runtimeType}');
      if (recent.length > 30) recent.removeRange(0, recent.length - 30);
      if (kDebugMode) debugPrint('non-fatal [$where] ${error.runtimeType}');
      final s = sink;
      if (s != null) {
        s(where, error, stack);
      } else {
        CrashReporter.instance.capture(error, stack, where: where);
      }
    } catch (_) {
      // reporting must never throw into the caller
    }
  }
}
