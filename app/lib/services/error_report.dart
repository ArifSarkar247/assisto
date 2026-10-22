import 'package:flutter/foundation.dart';

/// Report a NON-FATAL failure of a user action or storage step (scrubbed: the
/// error TYPE and where it happened only — never message text, keys, tokens,
/// phone numbers or names). Crashlytics + Owner Admin → Reports wiring lands
/// with the crash-reporting build; until then this only logs in debug.
void reportNonFatal(String where, Object error) {
  if (kDebugMode) debugPrint('[nonfatal] $where: ${error.runtimeType}');
}
