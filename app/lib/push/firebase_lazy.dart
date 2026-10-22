import 'dart:async';

import 'package:firebase_core/firebase_core.dart';

/// sc1 — ONE lazy, single-flight Firebase initialisation shared by push
/// (FirebasePushBridge) and crash reporting (CrashlyticsBridge).
///
/// Never called before the first frame. The auto-init FirebaseInitProvider is
/// removed from the manifest (ColorOS startup-provider history), so nothing
/// initialises Firebase at process start. Without google-services.json (a
/// build without the CI secret) initializeApp throws; we return false and both
/// features stay silently off. Time-boxed so a stuck Play-services call can
/// never hold up its callers.
class FirebaseLazy {
  FirebaseLazy._();

  static Future<bool>? _run;

  static Future<bool> ensure() => _run ??= _init();

  static Future<bool> _init() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp().timeout(const Duration(seconds: 15));
      }
      return true;
    } catch (_) {
      // let a later caller try again (e.g. a transient Play-services error)
      _run = null;
      return Firebase.apps.isNotEmpty;
    }
  }
}
