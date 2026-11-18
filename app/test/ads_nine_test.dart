// ads-nine (board row 54): consent "not required" + once-per-session form,
// request / no-fill counting, the honest "Why this ad?" sheet, a slow ad
// never blocking the page, no blank gap on failure, the banner growing in
// (no jump), no two full-screen ads close together, and a Premium account
// never inheriting a Free account's "ads allowed" after a switch.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/ad_telemetry.dart';
import 'package:assisto/ads/ad_why_sheet.dart';
import 'package:assisto/ads/admob_sdk.dart';
import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/ads/app_open_gate.dart';
import 'package:assisto/ads/consent.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/safety/ad_block_context.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

const _realAppId = 'ca-app-pub-1111111111111111~2222222222';

/// UMP fake: [eea] -> consent required and the user closes the form
/// without answering (status stays required, canRequestAds false).
class _Ump implements ConsentBridge {
  _Ump({this.eea = false});
  final bool eea;
  final calls = <String>[];

  @override
  bool get linked => true;
  @override
  Future<bool> requestUpdate(
      {required bool debugEea, required List<String> testDeviceIds}) async {
    calls.add('update');
    return true;
  }

  @override
  Future<void> loadAndShowIfRequired() async {
    if (eea) calls.add('form');
  }

  @override
  Future<bool> canRequestAds() async => !eea;
  @override
  Future<PrivacyOptionsStatus> privacyOptionsStatus() async =>
      eea ? PrivacyOptionsStatus.required : PrivacyOptionsStatus.notRequired;
  @override
  Future<UmpConsentStatus> consentStatus() async =>
      eea ? UmpConsentStatus.required : UmpConsentStatus.notRequired;
  @override
  Future<bool> showPrivacyOptionsForm() async => true;
}

Map<String, dynamic> _server({String plan = 'free'}) {
  final paid = plan != 'free';
  return {
    'plan': plan,
    'paid': paid,
    'ads_enabled': !paid,
    'placements': {'banner': !paid},
    'banner_screens': paid ? <String>[] : AdPlacements.bannerScreens.toList(),
  };
}

class _Handle implements BannerAdHandle {
  @override
  double get height => 50;
  @override
  Widget view() => const ColoredBox(
      key: ValueKey('fake-banner'), color: Color(0xFF888888), child: SizedBox(height: 50));
  @override
  void dispose() {}
}

/// Answers each load with [gate] (a slow network) or null (no fill).
class _SlowBridge implements BannerBridge {
  _SlowBridge({this.fail = false});
  final bool fail;
  final gate = Completer<void>();
  int loads = 0;
  @override
  bool get linked => true;
  @override
  Future<BannerAdHandle?> load(String unitId,
      {required double width, required String placement}) async {
    loads++;
    await gate.future;
    return fail ? null : _Handle();
  }
}

AppState _app(String lang) {
  final s = AppState();
  s.api = FakeApi(mode: FakeMode.empty, lang: lang);
  s.user = AppUser(
      id: 1, name: lang == 'bn' ? 'রহিম' : 'Rahim', phone: '01700000000', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _wrap(Widget home, {String lang = 'en'}) => ChangeNotifierProvider<AppState>.value(
      value: _app(lang),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BannerPacer.resetForTest();
    AdTouchGuard.resetForTest();
    AdmobSdk.resetForTest();
    AdBannerSlot.debugBridge = null;
    AdBannerSlot.debugLoadConfig = null;
    AdBannerSlot.debugPlansBuilder = null;
    AdTelemetry.sink = null;
  });

  group('consent (Google UMP)', () {
    test('"not required" (Bangladesh): no form, ads allowed, no privacy row', () async {
      final ump = _Ump();
      final c = AdConsent.instance..resetForTest(appId: _realAppId, bridge: ump);
      expect(await c.allowsAds(), isTrue);
      expect(ump.calls.contains('form'), isFalse);
      expect(c.consentStatus, UmpConsentStatus.notRequired);
      expect(c.privacyOptionsRequired.value, isFalse);
      expect(c.privacyStatus.value, PrivacyOptionsStatus.notRequired);
      // personalised only when the owner allows it too
      expect(AdmobSdk.request().nonPersonalizedAds, isTrue);
      AdmobSdk.personalized = true;
      expect(AdmobSdk.request().nonPersonalizedAds, isFalse);
      c.resetForTest();
    });

    test('a closed form is NOT shown again on every banner refresh', () async {
      final ump = _Ump(eea: true);
      final c = AdConsent.instance..resetForTest(appId: _realAppId, bridge: ump);
      for (var i = 0; i < 5; i++) {
        expect(await c.allowsAds(), isFalse); // no answer -> no ad, fail closed
      }
      expect(ump.calls.where((x) => x == 'form').length, 1);
      expect(ump.calls.where((x) => x == 'update').length, 1);
      expect(() => AdmobSdk.request(), throwsStateError);
      c.resetForTest();
    });
  });

  group('request / no-fill counting', () {
    test('one request and one no_fill per ad instance; never before requested',
        () {
      final got = <AdEventRecord>[];
      AdTelemetry.sink = got.add;
      final before = AdTelemetry.requestCount;
      final tr = AdTelemetry.track('banner_dictionary', 'banner');
      tr.failed(); // not requested yet -> nothing
      tr.requested();
      tr.requested();
      tr.failed();
      tr.failed();
      expect(got.map((e) => e.kind).toList(), ['request', 'no_fill']);
      expect(got.first.toJson()['ad_event_id'], tr.eventId);
      expect(AdTelemetry.requestCount, before + 1);
      expect(AdTelemetry.requestLog.last.placement, 'banner_dictionary');
      expect(tr.requestedAt, isNotNull);
      // an ad that was seen is never a "no fill"
      final b = AdTelemetry.track('home_native', 'native')..requested();
      b.impression();
      b.failed();
      expect(got.where((e) => e.kind == 'no_fill').length, 1);
    });

    test('a request is counted only when the SDK gate allows it', () {
      AdBlockContext.resetForTest(planAllowsAds: false); // Premium
      expect(AdmobSdk.requestAllowed, isFalse);
      AdBlockContext.resetForTest(planAllowsAds: true);
      AdConsent.instance.resetForTest(); // test app id: no UMP
      expect(AdmobSdk.requestAllowed, isFalse); // gate not passed yet
    });

    test('every SDK bridge reports request + no_fill (source guard)', () {
      for (final p in [
        'lib/ads/admob_banner_bridge.dart',
        'lib/ads/admob_hero_bridge.dart',
        'lib/ads/admob_ads_bridge.dart',
        'lib/photo_studio/admob_photo_bridge.dart',
      ]) {
        final s = File(p).readAsStringSync();
        final loads = 'request: AdmobSdk.request()'.allMatches(s).length;
        expect('tr.requested()'.allMatches(s).length, loads, reason: p);
        expect(s.contains('tr.failed()'), isTrue, reason: p);
      }
    });
  });

  group('honest "Why this ad?"', () {
    test('the ad request carries no user data (keywords, URLs, extras)', () {
      final sdk = File('lib/ads/admob_sdk.dart').readAsStringSync();
      expect(sdk, contains('AdRequest(nonPersonalizedAds: !personalisedNow)'));
      final dir = Directory('lib');
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final s = f.readAsStringSync();
        if (!s.contains('google_mobile_ads')) continue;
        for (final bad in ['keywords:', 'contentUrl:', 'neighboringContentUrls:',
            'extras:', 'customTargeting']) {
          expect(s.contains(bad), isFalse, reason: '${f.path}: $bad');
        }
      }
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('Ad label opens the sheet ($lang); Remove ads goes to plans',
          (tester) async {
        var removed = 0;
        await tester.pumpWidget(_wrap(
            Scaffold(body: Center(child: AdLabelChip(onRemoveAds: () => removed++))),
            lang: lang));
        await tester.pump();
        final t = lookupAppLocalizations(Locale(lang));
        final chip = tester.getSize(find.byKey(const ValueKey('ad-why-open')));
        expect(chip.height, greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(const ValueKey('ad-why-open')));
        await _settle(tester);
        expect(find.text(t.adWhyTitle), findsOneWidget);
        expect(find.text(t.adWhyNoShare), findsOneWidget);
        expect(find.text(t.adWhyNever), findsOneWidget);
        // consent not gathered -> never claims personalisation
        expect(find.byKey(const ValueKey('ad-why-nonpersonal')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('ad-why-remove')));
        await _settle(tester);
        expect(removed, 1);
        expect(find.text(t.adWhyTitle), findsNothing);
      });
    }

    testWidgets('personalised line only when personalisation is really on',
        (tester) async {
      await tester.pumpWidget(_wrap(const Scaffold(body: AdWhySheet(personalised: true))));
      await tester.pump();
      expect(find.byKey(const ValueKey('ad-why-personal')), findsOneWidget);
      expect(find.byKey(const ValueKey('ad-why-remove')), findsNothing);
    });
  });

  group('slow / failed ad never hurts the page', () {
    testWidgets('a slow ad never blocks the page; then it grows in', (tester) async {
      final br = _SlowBridge();
      var taps = 0;
      await tester.pumpWidget(_wrap(Scaffold(
        body: Center(
            child: ElevatedButton(
                key: const ValueKey('page-button'),
                onPressed: () => taps++,
                child: const Text('Work'))),
        bottomNavigationBar: AdBannerSlot(
            screen: 'dictionary',
            bridge: br,
            loadConfig: () async => AdConfig.fromJson(_server())),
      )));
      await _settle(tester);
      expect(br.loads, 1);
      // still loading: the page works and the slot takes no space
      await tester.tap(find.byKey(const ValueKey('page-button')));
      await tester.pump();
      expect(taps, 1);
      expect(tester.getSize(find.byType(AdBannerSlot)).height, 0);
      br.gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // grows in over AdBannerSlot.reveal instead of jumping
      final mid = tester.getSize(find.byType(AdBannerSlot)).height;
      await _settle(tester);
      final full = tester.getSize(find.byType(AdBannerSlot)).height;
      expect(mid, lessThan(full));
      expect(find.byKey(const ValueKey('fake-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('ad-why-open')), findsOneWidget);
      expect(AdBannerSlot.lastLoadToPaintMs, greaterThanOrEqualTo(0));
    });

    testWidgets('no fill / offline -> no blank gap, page unchanged', (tester) async {
      final br = _SlowBridge(fail: true)..gate.complete();
      await tester.pumpWidget(_wrap(Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: AdBannerSlot(
            screen: 'dictionary',
            bridge: br,
            loadConfig: () async => AdConfig.fromJson(_server())),
      )));
      await _settle(tester);
      expect(br.loads, 1);
      expect(tester.getSize(find.byType(AdBannerSlot)).height, 0);
      expect(find.byKey(const ValueKey('ad-banner-slot')), findsNothing);
    });

    testWidgets('the first ad waits until the finger is off the screen',
        (tester) async {
      final br = _SlowBridge()..gate.complete();
      AdTouchGuard.notePointerDown(DateTime.now());
      await tester.pumpWidget(_wrap(Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: AdBannerSlot(
            screen: 'dictionary',
            bridge: br,
            loadConfig: () async => AdConfig.fromJson(_server())),
      )));
      await _settle(tester);
      expect(find.byKey(const ValueKey('ad-banner-slot')), findsNothing);
      await tester.runAsync(() => Future<void>.delayed(AdTouchGuard.quiet));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      await _settle(tester);
      expect(find.byKey(const ValueKey('ad-banner-slot')), findsOneWidget);
    });
  });

  group('frequency caps', () {
    test('no app-open ad within 3 min of another full-screen ad', () {
      final now = DateTime(2026, 11, 18, 12);
      AdDecision d(DateTime? fs) => AppOpenGate.decide(
          loggedIn: true,
          paid: false,
          enabled: true,
          screen: 'home',
          entry: '',
          now: now,
          joined: DateTime(2026, 11, 1),
          lastFullScreenAt: fs);
      expect(d(now.subtract(const Duration(seconds: 60))).reason, 'after_fullscreen');
      expect(d(now.subtract(const Duration(minutes: 4))).allowed, isTrue);
      expect(d(null).allowed, isTrue);
    });

    test('a notification / call entry never gets an app-open ad', () {
      for (final e in ['notification', 'call', 'sos', 'deeplink', 'safety_alert']) {
        final d = AppOpenGate.decide(
            loggedIn: true,
            paid: false,
            enabled: true,
            screen: 'home',
            entry: e,
            now: DateTime(2026, 11, 18, 12));
        expect(d.reason, 'blocked_entry', reason: e);
      }
      AppEntry.reset();
      AppEntry.mark('notification');
      final g = AppOpenGuard.check(
          firstLaunchEver: false,
          sessionAfterLogin: false,
          suppressed: AppEntry.consumeSuppression(),
          screen: 'home',
          resumed: false);
      expect(g.reason, 'blocked_entry');
      AppEntry.reset();
    });
  });

  group('account switch', () {
    test('sign-out forgets "ads allowed" (a Premium account never inherits it)',
        () {
      AdsService.instance.resetForTest();
      AdBlockContext.resetForTest(planAllowsAds: true); // the Free account
      expect(AdBlockContext.sdkAllowed, isTrue);
      AdsService.instance.noteSignedOut();
      expect(AdBlockContext.planAllowsAds, isNull);
      expect(AdBlockContext.sdkAllowed, isFalse);
      expect(AdsService.instance.config.adsEnabled, isFalse);
      AdsService.instance.resetForTest();
    });
  });
}
