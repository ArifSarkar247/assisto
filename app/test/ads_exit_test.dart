// admobump — OWNER ADS FINAL (2 Nov): interstitials ONLY on the exit after
// a finished task, through the ONE registry (AdExitPlacement). Proves:
// exit-only timing, max 4 a day, >= 800 s gap, none on the first day of use,
// never on a paid plan, quick tools once a day, Ad impact "closed the app
// right after" event, and the never-list guard (no ad API reachable from
// the owner's never-list files; AdExit.maybeShow only on an exit).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/ads_bridge.dart';
import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/api.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

Map<String, dynamic> _cfgJson({bool paid = false, int cap = 4, int gap = 800}) => {
      'configured': false,
      'plan': paid ? 'premium' : 'free',
      'paid': paid,
      'ads_enabled': !paid,
      'placements': {'interstitial': !paid},
      'interstitial_daily_cap': cap,
      'interstitial_min_gap_sec': gap,
      'interstitial_moments': [for (final p in AdExitPlacement.values) p.id],
    };

class _Api extends ApiClient {
  _Api(this.cfg) {
    token = 't';
  }
  final Map<String, dynamic> cfg;
  final posts = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      path == '/ads/config' ? cfg : {};
  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/ads/event') posts.add(body);
    return {'ok': true};
  }
}

class _Inter implements InterstitialBridge {
  final shown = <String>[];
  @override
  bool get linked => true;
  @override
  Future<bool> showInterstitial(String unitId, {required String placement}) async {
    shown.add(placement);
    return true;
  }
}

AppState _app(_Api api) {
  final app = AppState();
  app.api = api;
  app.user = AppUser(
      id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en');
  app.loading = false;
  return app;
}

final _now = DateTime(2026, 11, 10, 12);
AdDecision _d(String id,
        {Map<String, dynamic>? j,
        DateTime? first,
        DateTime? last,
        int today = 0,
        int here = 0}) =>
    AdPlacements.interstitial(id, AdConfig.fromJson(j ?? _cfgJson()),
        loggedIn: true,
        now: _now,
        firstUseDay: first ?? DateTime(2026, 11, 1),
        lastFullScreenAt: last,
        shownToday: today,
        shownTodayHere: here);

void main() {
  setUp(() {
    AdExit.resetForTest();
    AdsService.instance.resetForTest();
  });

  group('rules', () {
    test('max 4 a day, even if the server asks for more', () {
      expect(_d('photo_after_save', today: 3).allowed, isTrue);
      expect(_d('photo_after_save', today: 4).reason, 'daily_cap');
      expect(_d('photo_after_save', j: _cfgJson(cap: 20), today: 4).reason,
          'daily_cap');
      expect(AdRules.maxInterstitialsPerDay, 4);
    });

    test('>= 800 s after ANY full-screen ad, even if the server says 300', () {
      final j = _cfgJson(gap: 300);
      expect(_d('scan_after_save', j: j, last: _now.subtract(const Duration(seconds: 799)))
          .reason, 'too_soon');
      expect(_d('scan_after_save', j: j, last: _now.subtract(const Duration(seconds: 800)))
          .allowed, isTrue);
    });

    test('never on the first day of use (or when it is unknown)', () {
      expect(_d('cv_after_download', first: DateTime(2026, 11, 10, 7)).reason,
          'first_day');
      expect(
          AdPlacements.interstitial('cv_after_download', AdConfig.fromJson(_cfgJson()),
                  loggedIn: true, now: _now)
              .reason,
          'first_day');
      expect(_d('cv_after_download', first: DateTime(2026, 11, 9, 23)).allowed, isTrue);
    });

    test('never for a paid plan', () {
      expect(_d('photo_after_save', j: _cfgJson(paid: true)).reason, 'paid_plan');
    });

    test('quick tools: once a day; other placements only the global cap', () {
      expect(_d('quick_tool_exit', here: 0).allowed, isTrue);
      expect(_d('quick_tool_exit', here: 1).reason, 'placement_daily_cap');
      expect(_d('plan_after_save', here: 3).allowed, isTrue);
    });

    test('only registered placements; every placement passes the fence', () {
      expect(_d('task_done').reason, 'moment_not_allowed');
      expect(_d('sos_sent').reason, 'moment_not_allowed');
      for (final p in AdExitPlacement.values) {
        expect(AdRules.isBlockedScreen(p.screen), isFalse, reason: p.id);
        expect(_d(p.id).allowed, isTrue, reason: p.id);
      }
      expect(AdExitPlacement.values.length, 11);
    });
  });

  group('exit-only timing', () {
    test('the result appearing never shows an ad; leaving it may', () {
      final got = <AdExitPlacement>[];
      AdExit.sink = got.add;
      AdExit.taskDone(AdExitPlacement.photoAfterSave);
      expect(got, isEmpty); // result on screen: nothing
      expect(AdExit.maybeShow(AdExitPlacement.photoAfterSave), isTrue);
      expect(got, [AdExitPlacement.photoAfterSave]);
      // consumed: leaving again without a new finished task -> nothing
      expect(AdExit.maybeShow(AdExitPlacement.photoAfterSave), isFalse);
      expect(got.length, 1);
    });

    test('leaving without a finished task never shows an ad', () {
      final got = <AdExitPlacement>[];
      AdExit.sink = got.add;
      expect(AdExit.maybeShow(AdExitPlacement.quickToolExit), isFalse);
      expect(got, isEmpty);
    });

    test('a task finished long ago does not count', () {
      final got = <AdExitPlacement>[];
      AdExit.sink = got.add;
      AdExit.taskDone(AdExitPlacement.planAfterSave, _now);
      expect(AdExit.maybeShow(AdExitPlacement.planAfterSave,
          _now.add(const Duration(minutes: 31))), isFalse);
      expect(got, isEmpty);
    });
  });

  group('service', () {
    testWidgets('first day blocked, later day shown, quick tools once a day',
        (tester) async {
      final api = _Api(_cfgJson());
      final inter = _Inter();
      AdsService.instance.interstitials = inter;
      final today = DateTime.now();
      final d =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      SharedPreferences.setMockInitialValues({'ads_first_use_day': d});
      AdsService.instance.attachForTest(_app(api));
      expect(await AdsService.instance.maybeInterstitial('quick_tool_exit'), isFalse);
      expect(inter.shown, isEmpty);

      SharedPreferences.setMockInitialValues({'ads_first_use_day': '2000-01-01'});
      expect(await AdsService.instance.maybeInterstitial('quick_tool_exit'), isTrue);
      expect(inter.shown, ['interstitial_quick_tool_exit']);
      // even after the gap, the quick-tools placement is spent for today
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('ads_fullscreen_last_ms', 0);
      expect(await AdsService.instance.maybeInterstitial('quick_tool_exit'), isFalse);
      expect(await AdsService.instance.maybeInterstitial('plan_after_save'), isTrue);
    });

    testWidgets('paid plan: nothing', (tester) async {
      SharedPreferences.setMockInitialValues({'ads_first_use_day': '2000-01-01'});
      final inter = _Inter();
      AdsService.instance.interstitials = inter;
      AdsService.instance.attachForTest(_app(_Api(_cfgJson(paid: true))));
      expect(await AdsService.instance.maybeInterstitial('photo_after_save'), isFalse);
      expect(inter.shown, isEmpty);
    });

    testWidgets('Ad impact: app closed within 10 s of the ad closing -> one '
        'aggregate exit event; later -> none', (tester) async {
      SharedPreferences.setMockInitialValues({'ads_first_use_day': '2000-01-01'});
      final api = _Api(_cfgJson());
      AdsService.instance.interstitials = _Inter();
      AdsService.instance.attachForTest(_app(api));
      final s = AdsService.instance;
      expect(await s.maybeInterstitial('photo_after_save'), isTrue);
      final t0 = DateTime(2026, 11, 10, 12);
      s.noteImpactPause(t0); // the ad itself covers the app: not an exit
      s.noteImpactResume(t0.add(const Duration(seconds: 20))); // ad closed
      s.noteImpactPause(t0.add(const Duration(seconds: 25))); // left 5 s later
      await tester.pump();
      final exits = api.posts.where((b) => b['kind'] == 'exit').toList();
      expect(exits.length, 1);
      expect(exits.first['placement'], 'interstitial_photo_after_save');
      expect(exits.first['format'], 'interstitial');
      expect(exits.first.keys.toSet(), {'placement', 'format', 'kind'}); // no ids

      // next ad: the user stays > 10 s -> no exit event
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('ads_fullscreen_last_ms', 0);
      expect(await s.maybeInterstitial('scan_after_save'), isTrue);
      s.noteImpactResume(t0.add(const Duration(minutes: 1)));
      s.noteImpactPause(t0.add(const Duration(minutes: 2)));
      await tester.pump();
      expect(api.posts.where((b) => b['kind'] == 'exit').length, 1);
    });
  });

  group('never-list guard (allow-list design)', () {
    // the owner's never list, as path tokens of lib/ files
    const never = [
      'sos', 'journey', 'family_alert', 'antitheft', 'anti_theft', 'cctv',
      'vehicle', 'missing', 'blood', 'train_tracker', 'destination',
      'circle_chat', 'circle_call', 'circle_group_chat', '/calls/',
      'incoming_call', 'assisto_chat', 'ai_chat', 'payment', 'checkout',
      'budget', 'money', 'remit', 'prepaid', 'vault', 'khata', 'sales',
      'selling', 'invoice', 'crm', 'quran', 'ramadan', 'calorie', 'food',
      'health', 'medicine', 'reminder', 'notes', 'todo', 'task', 'school',
      'kids', 'child', 'credit',
    ];
    // owner decision pending (STATUS): the user-chosen "watch an ad to earn
    // credits" sheet — rewarded only, never a passive ad
    const rewardedOnly = {
      'lib/screens/credits_screen.dart',
      'lib/payments/credits_out_sheet.dart',
    };
    final adApi = RegExp(
        r'AdBannerSlot\(|AdExit\.|SponsoredPostSlot\(|HomeHero\(|AdmobSdk\.|'
        r'SponsorAppOpenScreen|maybeInterstitial|showInterstitial|'
        r'AdsService\.instance|RewardedAdSheet');
    final passive = RegExp(r'AdBannerSlot\(|AdExit\.|SponsoredPostSlot\(|HomeHero\(|'
        r'maybeInterstitial|showInterstitial|SponsorAppOpenScreen');

    List<File> libFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    String rel(File f) => f.path.replaceAll('\\', '/');
    String code(File f) => f
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('no ad API is reachable from a never-list file', () {
      final bad = <String>[];
      var scanned = 0;
      for (final f in libFiles()) {
        final p = rel(f).toLowerCase();
        if (p.startsWith('lib/ads/') || p.contains('/l10n/')) continue;
        if (!never.any(p.contains)) continue;
        scanned++;
        final src = code(f);
        if (rewardedOnly.contains(rel(f))) {
          if (passive.hasMatch(src)) bad.add('${rel(f)} (passive ad)');
          continue;
        }
        if (adApi.hasMatch(src)) bad.add(rel(f));
        if (src.contains("ads/ad_banner_slot.dart") ||
            src.contains("ads/hero_ad.dart")) {
          bad.add('${rel(f)} (imports an ad widget)');
        }
      }
      expect(scanned, greaterThan(30), reason: 'guard must actually scan');
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('interstitials are shown ONLY through the registry', () {
      final bad = <String>[];
      for (final f in libFiles()) {
        final p = rel(f);
        if (p == 'lib/ads/ads_service.dart' || p.startsWith('lib/ads/admob_') ||
            p == 'lib/ads/ads_bridge.dart' || p == 'lib/ads/ads_binding.dart') {
          continue;
        }
        if (RegExp(r'maybeInterstitial\(|showInterstitial\(|InterstitialAd\.')
            .hasMatch(code(f))) {
          bad.add(p);
        }
      }
      // Photo Studio's old ENTRY-ad seam: the app's bridge
      // (AdmobPhotoAdBridge.showInterstitial) always returns false, so an
      // entry interstitial can never show; proven below.
      const psSeam = {
        'lib/photo_studio/admob_photo_bridge.dart',
        'lib/photo_studio/ps_ads.dart',
        'lib/photo_studio/ps_controller.dart',
      };
      expect(bad.where((p) => !psSeam.contains(p)), isEmpty, reason: bad.join('\n'));
      final bridge = File('lib/photo_studio/admob_photo_bridge.dart').readAsStringSync();
      expect(bridge, contains('Future<bool> showInterstitial(String unitId) async => false;'));
    });

    test('AdExit.maybeShow is called only on an EXIT (dispose)', () {
      final bad = <String>[];
      var calls = 0;
      for (final f in libFiles()) {
        final p = rel(f);
        if (p.startsWith('lib/ads/')) continue;
        final lines = code(f).split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('AdExit.maybeShow(')) continue;
          calls++;
          // nearest enclosing method header above the call
          var j = i;
          while (j > 0 &&
              !RegExp(r'^  [A-Za-z<>?, ]+ \w+\([^)]*\)\s*(async\s*)?\{')
                  .hasMatch(lines[j])) {
            j--;
          }
          if (!lines[j].contains('void dispose()')) bad.add('$p:${i + 1}');
        }
      }
      expect(calls, greaterThanOrEqualTo(12));
      expect(bad, isEmpty, reason: bad.join('\n'));
    });
  });
}
