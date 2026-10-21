import 'firebase_push_bridge.dart';
import 'push_bridge.dart';

/// Which [PushBridge] the app uses.
///
/// INTEGRATOR: after applying the pubspec part of
/// `.phaseB/proposals/a6-leftovers.md` (firebase_core + firebase_messaging),
/// rename `firebase_push_bridge.dart.pending` -> `firebase_push_bridge.dart`
/// and switch this file to:
///
///   import 'firebase_push_bridge.dart';
///   PushBridge createPushBridge() => FirebasePushBridge();
///
/// Until then push is silently off and nothing Firebase-related is linked.
PushBridge createPushBridge() => FirebasePushBridge();
