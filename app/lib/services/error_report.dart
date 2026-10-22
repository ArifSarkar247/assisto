// db1: placeholder created by the dead-button sweep because agent sc1's
// Crashlytics/error-reporting module was not on origin/main yet. sc1 owns this
// file — when its version lands, keep ITS implementation; the signature below
// is the agreed contract: reportNonFatal(String where, Object error).
import 'package:flutter/foundation.dart';

/// Records a non-fatal error from a user action. Placeholder: debug log only
/// (no network, no plugin) until sc1's reporter replaces it.
void reportNonFatal(String where, Object error) {
  debugPrint('[nonfatal] $where: $error');
}
