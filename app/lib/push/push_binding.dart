import 'push_bridge.dart';

// BISECT ONLY: no Firebase at all.
PushBridge createPushBridge() => NoopPushBridge();
