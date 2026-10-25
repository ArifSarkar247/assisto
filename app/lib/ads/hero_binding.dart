import 'admob_hero_bridge.dart';
import 'admob_platform.dart';
import 'hero_ad.dart';

/// Which [HeroAdBridge] the home native card uses: the real AdMob one on
/// Android (admob, owner 25 Oct), the no-op one elsewhere (host tests).
HeroAdBridge createHeroAdBridge() =>
    admobSupported() ? AdmobHeroAdBridge() : const NoopHeroAdBridge();
