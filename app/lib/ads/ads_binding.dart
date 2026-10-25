import 'admob_ads_bridge.dart';
import 'admob_platform.dart';
import 'ads_bridge.dart';

/// Which [AdsBridge] / [InterstitialBridge] the app uses (admob, owner
/// 25 Oct): the real google_mobile_ads bridge on Android; the no-op one
/// elsewhere (host unit tests, iOS — whose AdMob setup is not part of this
/// release), so no plugin channel is ever touched there.
AdsBridge createAdsBridge() =>
    admobSupported() ? AdmobAdsBridge() : const NoopAdsBridge();

InterstitialBridge createInterstitialBridge() =>
    admobSupported() ? AdmobAdsBridge() : const NoopInterstitialBridge();
