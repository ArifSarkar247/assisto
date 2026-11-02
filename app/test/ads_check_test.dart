// Owner ads check (28 Oct):
//  1) "interstitial_photo_saved shows 2 impressions and 3 clicks" — the
//     per-ad-instance tracker: one impression, at most one click and only
//     after that impression, one paid value; every event carries the ad
//     instance id the server dedupes on.
//  2) the placement -> screen map: every ad placement in lib/ is walked and
//     no ad may sit on a payment / checkout / paywall / credits-buy / plans /
//     refund, SOS / safety, call, conversation, login, permission or
//     onboarding screen; banner_money is the My Account tracker only;
//     banner_circle_list is the Chats LIST tab only.
//  3) nothing ever asks or rewards a user for CLICKING an ad (AdMob invalid
//     traffic) — copy lint over both ARB files and the Dart sources.
//  4) the interstitial accidental-click guard.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

String _stripComments(String s) => s
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

Iterable<File> _dartFiles() sync* {
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is File && f.path.endsWith('.dart')) yield f;
  }
}

String _rel(File f) => f.path.replaceAll('\\', '/');

void main() {
  group('1. per-ad-instance counting', () {
    final events = <AdEventRecord>[];
    setUp(() {
      events.clear();
      AdTelemetry.sink = events.add;
    });
    tearDown(() => AdTelemetry.sink = null);

    test('the reported bug: repeat callbacks never inflate the counts', () {
      // two interstitials after two saved photos; the user taps the first ad
      // three times (Google calls onAdClicked on every recorded tap) and the
      // SDK reports showed + impression for both
      final a = AdTelemetry.track('interstitial_photo_saved', 'interstitial');
      final b = AdTelemetry.track('interstitial_photo_saved', 'interstitial');
      for (final t in [a, b]) {
        t.impression(); // onAdShowedFullScreenContent
        t.impression(); // onAdImpression
      }
      a.click();
      a.click();
      a.click();
      final imps = events.where((e) => e.kind == 'impression').length;
      final clicks = events.where((e) => e.kind == 'click').length;
      expect(imps, 2);
      expect(clicks, 1);
      expect(clicks <= imps, isTrue);
    });

    test('a click before the impression is never counted', () {
      final t = AdTelemetry.track('banner_money', 'banner');
      t.click();
      expect(events, isEmpty);
      t.impression();
      t.click();
      expect(events.map((e) => e.kind), ['impression', 'click']);
    });

    test('one paid value per instance; bad values dropped', () {
      final t = AdTelemetry.track('home_native', 'native');
      t.paid(valueMicros: double.nan, currency: 'usd', precision: 'precise');
      t.paid(valueMicros: 1200, currency: 'usd', precision: 'precise');
      t.paid(valueMicros: 1200, currency: 'usd', precision: 'precise');
      expect(events.length, 1);
      expect(events.single.currency, 'USD');
      expect(events.single.valueMicros, 1200);
    });

    test('every event carries the instance id; instances differ', () {
      final a = AdTelemetry.track('app_open', 'app_open');
      final b = AdTelemetry.track('app_open', 'app_open');
      expect(a.eventId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(a.eventId == b.eventId, isFalse);
      a.impression();
      a.click();
      for (final e in events) {
        expect(e.toJson()['ad_event_id'], a.eventId);
      }
      // legacy events carry no id (the server then dedupes clicks per minute)
      expect(const AdEventRecord(placement: 'x1', format: 'banner', kind: 'click')
          .toJson()
          .containsKey('ad_event_id'), isFalse);
    });

    test('every SDK bridge routes callbacks through a tracker', () {
      const bridges = [
        'lib/ads/admob_ads_bridge.dart',
        'lib/ads/admob_banner_bridge.dart',
        'lib/ads/admob_hero_bridge.dart',
        'lib/photo_studio/admob_photo_bridge.dart',
      ];
      for (final p in bridges) {
        final src = _stripComments(File(p).readAsStringSync());
        expect(src.contains('AdTelemetry.track('), isTrue, reason: p);
        expect(RegExp(r'AdTelemetry\.(impression|click|paid)\(').hasMatch(src), isFalse,
            reason: '$p must not use the undeduped legacy calls');
      }
      // and no other file in lib/ reports undeduped events
      final bad = <String>[];
      for (final f in _dartFiles()) {
        final rel = _rel(f);
        if (rel == 'lib/ads/ad_telemetry.dart') continue;
        if (RegExp(r'AdTelemetry\.(impression|click|paid)\(')
            .hasMatch(_stripComments(f.readAsStringSync()))) {
          bad.add(rel);
        }
      }
      expect(bad, isEmpty);
    });
  });

  group('2. placement -> screen map', () {
    // banner key -> the ONE file that shows it
    final banners = <String, List<String>>{};
    final moments = <String, List<String>>{};
    final rewarded = <String>{};
    final sponsored = <String>{};
    final native = <String>{};
    setUpAll(() {
      final slot = RegExp(r"AdBannerSlot\(\s*screen:\s*'([a-z_]+)'");
      final moment = RegExp(r"AdMoments\.report\(\s*'([a-z_]+)'");
      for (final f in _dartFiles()) {
        final rel = _rel(f);
        final src = _stripComments(f.readAsStringSync());
        for (final m in slot.allMatches(src)) {
          banners.putIfAbsent(m.group(1)!, () => []).add(rel);
        }
        for (final m in moment.allMatches(src)) {
          moments.putIfAbsent(m.group(1)!, () => []).add(rel);
        }
        if (RegExp(r'RewardedAdSheet\.show\(|\.showRewardedSsv\(|\.showRewarded\(')
            .hasMatch(src)) {
          rewarded.add(rel);
        }
        if (RegExp(r'SponsoredPostSlot\(|SponsorAppOpenScreen\.push\(').hasMatch(src)) {
          sponsored.add(rel);
        }
        if (RegExp(r'\bHomeHero\(').hasMatch(src)) native.add(rel);
      }
    });

    // a file on any of these is an ad-free screen by the owner's rules
    final forbiddenFile = RegExp(
        r'(^lib/payments/|^lib/plans_v2/|^lib/billing/|^lib/calls/|^lib/safety/|^lib/antitheft/|'
        r'pay|checkout|paywall|plans|credits|topup|top_up|refund|purchase|billing|'
        r'sos|safety|safe_|journey|fall_|antitheft|anti_theft|lost|alarm|'
        r'call|chat_screen|conversation|thread|chat_lock|vault|'
        r'login|otp|sign_?up|password|permission|onboarding|language_pick)');

    test('every banner key is on the allowlist and shown by exactly one file', () {
      expect(banners.keys.toSet(), AdPlacements.bannerScreens,
          reason: 'used banner keys must equal the allowlist');
      banners.forEach((k, files) => expect(files.length, 1, reason: '$k: $files'));
    });

    test('no banner, interstitial moment or native card on a forbidden screen', () {
      final bad = <String>[];
      banners.forEach((k, files) {
        for (final f in files) {
          if (forbiddenFile.hasMatch(f)) bad.add('banner_$k -> $f');
        }
      });
      moments.forEach((k, files) {
        for (final f in files) {
          if (forbiddenFile.hasMatch(f)) bad.add('interstitial_$k -> $f');
        }
      });
      for (final f in native) {
        if (forbiddenFile.hasMatch(f)) bad.add('home_native -> $f');
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('banner_money is the My Account tracker, never a payment screen', () {
      expect(banners['money'], ['lib/screens/money_screen.dart']);
      final src = File('lib/screens/money_screen.dart').readAsStringSync();
      expect(src.contains('My Account'), isTrue);
      // the tracker opens no payment / checkout flow of its own
      for (final s in [
        'CheckoutSheet',
        'checkout_sheet.dart',
        'PaywallSheet',
        'CreditsOut',
        'store_billing.dart',
        'play_billing',
        'payments_api.dart',
      ]) {
        expect(src.contains(s), isFalse, reason: 'money_screen.dart uses $s');
      }
    });

    test('banner_circle_list: Chats LIST tab only, never a conversation or call', () {
      expect(banners['circle_list'], ['lib/screens/messenger/messenger_home_screen.dart']);
      final src = File('lib/screens/messenger/messenger_home_screen.dart').readAsStringSync();
      expect(src.contains("AdBannerSlot(screen: 'circle_list', enabled: _tab == 0)"), isTrue);
      final all = banners.values.expand((e) => e).toList();
      for (final f in all) {
        expect(RegExp(r'(chat_screen|conversation|call|group_chat|thread)').hasMatch(f),
            isFalse, reason: f);
      }
      for (final f in [
        'lib/screens/circle_chat_screen.dart',
        'lib/screens/circle_group_chat_screen.dart',
        'lib/screens/circle_call_screen.dart',
      ]) {
        if (!File(f).existsSync()) continue;
        final s = _stripComments(File(f).readAsStringSync());
        expect(RegExp(r'AdBannerSlot\(|SponsoredPostSlot\(|HomeHero\(|AdMoments\.report\(')
            .hasMatch(s), isFalse, reason: '$f must carry no ad');
      }
    });

    test('interstitials only at the two natural breaks', () {
      expect(moments.keys.toSet(), AdPlacements.interstitialMoments.keys.toSet());
      expect(moments['photo_saved'], ['lib/photo_studio/ps_controller.dart']);
      expect(moments['task_done'], ['lib/screens/notes_todos_screen.dart']);
    });

    test('rewarded is user-chosen and only where the owner allows it', () {
      const allowed = {
        'lib/ads/ads_service.dart', // the service itself
        'lib/ads/admob_ads_bridge.dart',
        'lib/ads/ads_bridge.dart',
        'lib/widgets/rewarded_ad_sheet.dart', // the opt-in sheet
        'lib/screens/credits_screen.dart', // "watch a short ad" on Credits
        'lib/payments/credits_out_sheet.dart', // the opt-in row (Free only)
        'lib/photo_studio/admob_photo_bridge.dart',
        'lib/photo_studio/ps_ads.dart',
        'lib/photo_studio/ps_export.dart', // Photo Studio unlock
        'lib/chat_vision/cv_controller.dart', // photo question to Assisto AI
      };
      expect(rewarded.difference(allowed), isEmpty,
          reason: 'new rewarded entry point: ${rewarded.difference(allowed)}');
    });

    test('sponsored cards: app-open + the end of large channels/communities only', () {
      expect(
          sponsored,
          {
            'lib/ads/ads_service.dart',
            'lib/ads/sponsor_widgets.dart', // the widgets themselves
            'lib/screens/messenger/community_detail_screen.dart',
            'lib/screens/messenger/channel_detail_screen.dart',
          });
    });
  });

  group('3. never ask or reward a user for clicking an ad', () {
    // "click/tap the ad to earn", "ক্লিক করুন ও ক্রেডিট পান", "বিজ্ঞাপনে ক্লিক"
    final en = RegExp(
        r'((click|tap|press)\w*\s+(on\s+)?(the\s+|an\s+|this\s+)?(ad|ads|advert\w*|banner|sponsor\w*)\b)'
        r'|((ad|ads|banner|advert\w*)\s+(click|tap)\w*\s+.{0,30}(earn|credit|reward|win|bonus|free|point))'
        r'|((click|tap)\w*\s+to\s+(earn|win|get\s+(free\s+)?credits?))',
        caseSensitive: false);
    final bn = RegExp(
        r'((বিজ্ঞাপন|অ্যাড|ব্যানার|স্পনসর)\S*\s*(এ|তে)?\s*(ক্লিক|ট্যাপ|চাপ))'
        r'|((ক্লিক|ট্যাপ)\s*(করুন|করে|করলে|করলেই)\s*.{0,20}'
        r'((ক্রেডিট|পুরস্কার|বোনাস|টাকা|পয়েন্ট)\s*(পান|নিন|পাবেন|জিতুন)|জিতুন))');

    test('no ARB string asks for or rewards an ad click', () {
      final bad = <String>[];
      for (final p in ['lib/l10n/app_en.arb', 'lib/l10n/app_bn.arb']) {
        final j = jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;
        j.forEach((k, v) {
          if (k.startsWith('@') || v is! String) return;
          if (en.hasMatch(v) || bn.hasMatch(v)) bad.add('$p $k: $v');
        });
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('the lint itself catches the forbidden phrasing', () {
      for (final s in [
        'Click the ad to earn credits',
        'Tap an ad and win',
        'Click to earn',
        'tap on the banner',
      ]) {
        expect(en.hasMatch(s), isTrue, reason: s);
      }
      for (final s in [
        'বিজ্ঞাপনে ক্লিক করুন',
        'ক্লিক করুন ও ক্রেডিট পান',
        'অ্যাডে ট্যাপ করুন',
      ]) {
        expect(bn.hasMatch(s), isTrue, reason: s);
      }
      // a completed, user-chosen rewarded VIEW is allowed copy
      expect(en.hasMatch('Watch a short ad for free credits'), isFalse);
      expect(bn.hasMatch('একটি ছোট ভিডিও দেখে ক্রেডিট নিন'), isFalse);
    });

    test('no Dart code grants anything from an ad click', () {
      final bad = <String>[];
      final grantOnClick = RegExp(
          r'onAdClicked[^;\n]*(credit|reward|grant|wallet|unlock|earn)',
          caseSensitive: false);
      for (final f in _dartFiles()) {
        final src = _stripComments(f.readAsStringSync());
        if (grantOnClick.hasMatch(src)) bad.add(_rel(f));
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });
  });

  group('4. interstitial accidental-click guard', () {
    tearDown(AdTouchGuard.resetForTest);

    test('no touch yet: show at once', () {
      final now = DateTime(2026, 10, 28, 12);
      expect(AdTouchGuard.idle(now), isTrue);
      expect(AdTouchGuard.waitFor(now, now), Duration.zero);
    });

    test('a recent tap delays the ad; constant tapping cancels it', () {
      final t0 = DateTime(2026, 10, 28, 12);
      AdTouchGuard.notePointerDown(t0);
      final at = t0.add(const Duration(milliseconds: 500));
      expect(AdTouchGuard.idle(at), isFalse);
      expect(AdTouchGuard.waitFor(at, t0), const Duration(milliseconds: 1000));
      // the user keeps ticking to-dos: 4 s after the moment there is no ad
      final late = t0.add(const Duration(seconds: 3, milliseconds: 900));
      AdTouchGuard.notePointerDown(late);
      expect(AdTouchGuard.waitFor(late, t0), isNull);
      expect(AdTouchGuard.idle(late.add(AdTouchGuard.quiet)), isTrue);
    });

    test('the interstitial bridge waits for the guard before show()', () {
      final src = File('lib/ads/admob_ads_bridge.dart').readAsStringSync();
      expect(src.contains('_showWhenIdle(ad, done, loadedFrom)'), isTrue);
      expect(File('lib/ads/ads_service.dart').readAsStringSync()
          .contains('AdTouchGuard.notePointerDown()'), isTrue);
    });
  });
}
