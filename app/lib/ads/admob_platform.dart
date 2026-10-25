import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// AdMob runs on Android only in this release (the APK manifest carries the
/// AdMob APPLICATION_ID and removes the SDK's startup provider). Host unit
/// tests and iOS get the no-op bridges. Never throws.
bool admobSupported() {
  try {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  } catch (_) {
    return false;
  }
}
