import 'push_bridge.dart';

// BISECT ONLY (branch bisect-nofcm, never merged): push OFF to test whether
// Firebase init wedges the CI emulator.
PushBridge createPushBridge() => NoopPushBridge();
