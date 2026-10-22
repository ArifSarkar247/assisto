import 'hero_ad.dart';

/// Which [HeroAdBridge] the home hero uses.
///
/// INTEGRATOR: after the AdMob pubspec + manifest part (a6 proposal, plus
/// `.phaseB/proposals/h1-home.md` §A) is live, copy
/// `.phaseB/pending_native/h1/admob_hero_bridge.dart.pending` to
/// `app/lib/ads/admob_hero_bridge.dart` and switch this to
/// `HeroAdBridge createHeroAdBridge() => AdmobHeroAdBridge();`.
HeroAdBridge createHeroAdBridge() => const NoopHeroAdBridge();
