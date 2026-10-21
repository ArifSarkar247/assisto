import 'firebase_push_bridge.dart';
import 'push_bridge.dart';

/// Which [PushBridge] the app uses: Firebase (FCM). Key-gated at build time —
/// without the GOOGLE_SERVICES_JSON_B64 secret, FirebasePushBridge.init()
/// returns false and push stays silently off.
PushBridge createPushBridge() => FirebasePushBridge();
