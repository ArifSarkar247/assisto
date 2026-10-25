import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/ads/ad_rules.dart';

void main() {
  final now = DateTime(2026, 10, 21, 12);

  AdConfig free({bool configured = true, int cap = 4, int gapSec = 10800}) =>
      AdConfig.fromJson({
        'configured': configured,
        'app_id': 'ca-app-pub-1234567890123456~1234567890',
        'units': {
          'app_open': 'ca-app-pub-1234567890123456/2222222222',
          'rewarded': 'ca-app-pub-1234567890123456/1111111111',
        },
        'plan': 'free',
        'paid': false,
        'app_open_enabled': true,
        'rewarded_enabled': true,
        'appopen_min_gap_sec': gapSec,
        'appopen_daily_cap': cap,
        'blocked_screens': ['vault'],
      });

  AdConfig paid() => AdConfig.fromJson({
        'configured': true,
        'plan': 'premium',
        'paid': true,
        'app_open_enabled': true,
        'rewarded_enabled': true,
        'appopen_daily_cap': 4,
      });

  AdDecision appOpen(AdConfig c,
          {String screen = 'home',
          DateTime? last,
          int today = 0,
          bool loggedIn = true}) =>
      AdRules.decide(
          kind: AdKind.appOpen,
          screen: screen,
          config: c,
          now: now,
          loggedIn: loggedIn,
          lastAppOpenAt: last,
          appOpensToday: today);

  AdDecision rewarded(AdConfig c,
          {String screen = 'credits', bool optIn = true, bool checkout = false}) =>
      AdRules.decide(
          kind: AdKind.rewarded,
          screen: screen,
          config: c,
          now: now,
          loggedIn: true,
          userOptedIn: optIn,
          checkoutInProgress: checkout);

  group('screen allowlist / blocklist', () {
    test('never on safety, payment, login/OTP or call screens', () {
      for (final s in [
        'sos', 'voice_sos', 'safety', 'emergency', 'fall_detect', 'journey',
        'payment', 'payment_ladder', 'topup', 'checkout', 'plans',
        'business_plans', 'login', 'otp', 'otp_verify', 'signup',
        'reset_password', 'call', 'circle_call', 'incoming_call',
        'circle_calls', 'lost_stolen', 'security',
      ]) {
        expect(AdRules.isBlockedScreen(s), isTrue, reason: s);
        expect(appOpen(free(), screen: s).reason, 'blocked_screen', reason: s);
        expect(rewarded(free(), screen: s).reason, 'blocked_screen', reason: s);
      }
    });

    test('unknown / empty screens are blocked (default deny)', () {
      expect(appOpen(free(), screen: 'unknown').allowed, isFalse);
      expect(appOpen(free(), screen: '').allowed, isFalse);
      expect(appOpen(free(), screen: 'money').reason, 'screen_not_allowed');
    });

    test('server-extended blocked screens apply', () {
      expect(appOpen(free(), screen: 'vault').reason, 'blocked_screen');
    });

    test('app-open only on home; rewarded only on credits', () {
      expect(appOpen(free()).allowed, isTrue);
      expect(appOpen(free(), screen: 'credits').reason, 'screen_not_allowed');
      expect(rewarded(free()).allowed, isTrue);
      expect(rewarded(free(), screen: 'home').reason, 'screen_not_allowed');
    });

    test('no rewarded while a checkout is in progress', () {
      expect(rewarded(free(), checkout: true).reason, 'checkout');
    });

    test('signed out -> nothing', () {
      expect(appOpen(free(), loggedIn: false).reason, 'logged_out');
    });
  });

  group('frequency cap', () {
    test('app-open at most once per 3 h', () {
      expect(appOpen(free(), last: now.subtract(const Duration(hours: 1)))
          .reason, 'too_soon');
      expect(
          appOpen(free(),
                  last: now.subtract(const Duration(hours: 2, minutes: 59)))
              .reason,
          'too_soon');
      expect(appOpen(free(), last: now.subtract(const Duration(hours: 3)))
          .allowed, isTrue);
    });

    test('server can change the gap but never below 1 h (p2-money)', () {
      final short = free(gapSec: 60);
      expect(appOpen(short, last: now.subtract(const Duration(minutes: 59)))
          .reason, 'too_soon');
      expect(appOpen(short, last: now.subtract(const Duration(hours: 1)))
          .allowed, isTrue);
      final long = free(gapSec: 6 * 3600);
      expect(appOpen(long, last: now.subtract(const Duration(hours: 4)))
          .reason, 'too_soon');
    });

    test('daily cap (0 = off)', () {
      expect(appOpen(free(cap: 2), today: 2).reason, 'daily_cap');
      expect(appOpen(free(cap: 2), today: 1).allowed, isTrue);
      expect(appOpen(free(cap: 0)).reason, 'daily_cap');
    });
  });

  group('plan gating', () {
    test('paid plans never get app-open ads', () {
      expect(appOpen(paid()).reason, 'paid_plan');
    });

    test('paid plans get ZERO ads, not even rewarded; never without opt-in', () {
      // admob (owner 25 Oct): Premium and Business see zero ads
      expect(rewarded(paid()).reason, 'paid_plan');
      expect(rewarded(paid(), optIn: false).reason, 'paid_plan');
      expect(rewarded(free(), optIn: false).reason, 'not_opted_in');
    });

    test('kill switches', () {
      final off = AdConfig.fromJson({'plan': 'free'});
      expect(appOpen(off).reason, 'disabled');
      expect(rewarded(off).reason, 'disabled');
    });

    test('any non-free plan string counts as paid', () {
      expect(AdConfig.fromJson({'plan': 'annual'}).paid, isTrue);
      expect(AdConfig.fromJson({}).paid, isFalse);
    });
  });

  group('test ids until real ones are set', () {
    const built = 'ca-app-pub-1234567890123456~1234567890';

    test('real ids only when configured AND the APK app id matches', () {
      expect(free().unitFor(AdKind.rewarded, builtAppId: built, testMode: false),
          'ca-app-pub-1234567890123456/1111111111');
      // APK built with another AdMob app id -> never real units: the
      // Google TEST unit instead (admob, owner 25 Oct)
      expect(
          free().unitFor(AdKind.rewarded,
              builtAppId: AdIds.testAppId, testMode: false),
          AdIds.testRewarded);
    });

    test('unconfigured: Google TEST units in every build (ship with test ids)', () {
      final c = free(configured: false);
      expect(c.unitFor(AdKind.appOpen, builtAppId: built, testMode: true),
          AdIds.testAppOpen);
      expect(c.unitFor(AdKind.rewarded, builtAppId: built, testMode: true),
          AdIds.testRewarded);
      expect(c.unitFor(AdKind.rewarded, builtAppId: built, testMode: false),
          AdIds.testRewarded);
    });

    test('test ids are Google\'s public sample publisher', () {
      for (final id in [AdIds.testAppId, AdIds.testAppOpen, AdIds.testRewarded]) {
        expect(id.startsWith('ca-app-pub-3940256099942544'), isTrue);
      }
    });
  });
}
