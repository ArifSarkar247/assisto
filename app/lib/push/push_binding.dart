import 'push_bridge.dart';

/// Which [PushBridge] the app uses.
///
/// NOOP in this build: firebase_core/firebase_messaging are not linked yet.
/// The FCM build (with its own launch smoke) restores
/// `.phaseB/pending_native/firebase_push_bridge.dart` to `lib/push/`, adds the
/// pubspec entries back and switches this file to:
///
///   import 'firebase_push_bridge.dart';
///   PushBridge createPushBridge() => FirebasePushBridge();
///
/// Until then push is silently off and the app polls on open/resume.
PushBridge createPushBridge() => NoopPushBridge();
