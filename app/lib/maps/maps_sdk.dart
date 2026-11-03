import 'dart:convert';

import 'package:flutter/services.dart';

/// mapscost — is Google's Maps SDK usable in THIS build? The Android key is
/// put into the manifest at build time from the CI secret MAPS_ANDROID_KEY
/// (never committed); the same CI step flips assets/maps/sdk.json to
/// {"android_key": true}. Without the key a GoogleMap would crash on Android,
/// so every map screen checks this first and otherwise keeps its old path.
class MapsSdk {
  static bool? _cached;

  /// Tests set this.
  static bool? debugAvailable;

  static Future<bool> available() async {
    if (debugAvailable != null) return debugAvailable!;
    if (_cached != null) return _cached!;
    try {
      final j = jsonDecode(await rootBundle.loadString('assets/maps/sdk.json'));
      _cached = j is Map && j['android_key'] == true;
    } catch (_) {
      _cached = false;
    }
    return _cached!;
  }
}
