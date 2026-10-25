import 'admob_consent_bridge.dart';
import 'admob_platform.dart';
import 'consent.dart';

/// Which [ConsentBridge] (Google UMP) the app uses: the real one wherever
/// AdMob runs (they always go live together), else the no-op.
ConsentBridge createConsentBridge() =>
    admobSupported() ? AdmobConsentBridge() : const NoopConsentBridge();
