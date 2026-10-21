import 'ads_bridge.dart';

/// Which [AdsBridge] the app uses.
///
/// INTEGRATOR: after applying the pubspec + manifest parts of
/// `.phaseB/proposals/a6-leftovers-admob.md`, run
/// `.phaseB/proposals/a6-admob-apply.sh` (renames
/// `admob_ads_bridge.dart.pending` -> `.dart` and switches this to
/// `AdsBridge createAdsBridge() => const NoopAdsBridge();`).
AdsBridge createAdsBridge() => const NoopAdsBridge();
