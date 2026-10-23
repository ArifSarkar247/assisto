import 'consent.dart';

/// Which [ConsentBridge] (Google UMP) the app uses.
///
/// INTEGRATOR: `.phaseB/proposals/a6-admob-apply.sh` (the AdMob activation)
/// also renames `admob_consent_bridge.dart.pending` -> `.dart` and switches
/// this to `ConsentBridge createConsentBridge() => AdmobConsentBridge();` —
/// AdMob and its consent gate always go live together.
ConsentBridge createConsentBridge() => const NoopConsentBridge();
