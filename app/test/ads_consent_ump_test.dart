// admobump (owner 2 Nov) — the Google UMP flow end to end, with UMP's debug
// settings (DebugGeography EEA + a test device id from Owner Admin) going
// through a FAKE ConsentInformation (CI cannot reach Google). Proves:
//  * no ad request can be built before the consent info update;
//  * Google's form is shown when consent is required (EEA debug geography)
//    and not elsewhere;
//  * after "Do not consent" (or any answer) the request is NON-personalised;
//    personalised only where UMP says consent is not required AND the owner
//    allows it; canRequestAds() false = no ad at all;
//  * a hanging UMP update never blocks: it is time-boxed;
//  * Settings -> "Ads privacy": the row appears when required and re-opens
//    Google's privacy options form; withdrawing there stops the next request;
//    an honest line (no button) when not required;
//  * debug builds never load a REAL unit id;
//  * ads never on SOS / safety / calls / open chat / payment / login /
//    permission screens.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_privacy_tile.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/ads/admob_sdk.dart';
import 'package:assisto/ads/ads_service.dart';
import 'package:assisto/ads/consent.dart';
import 'package:assisto/ads/hero_ad.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

// Shape-valid but made-up ids (never a real publisher).
const _realAppId = 'ca-app-pub-1111111111111111~2222222222';
const _realBanner = 'ca-app-pub-1111111111111111/3333333333';
const _testDevice = 'TEST-DEVICE-HASHED-ID-0001';

/// A fake of Google's ConsentInformation + ConsentForm that behaves like UMP
/// with debug settings: with DebugGeography EEA on a listed test device the
/// status is `required` until the form is answered; elsewhere `notRequired`.
class _FakeUmp implements ConsentBridge {
  _FakeUmp({this.userConsents = false, this.hangUpdate = false});

  /// What the user taps in Google's form ("Consent" vs "Do not consent").
  bool userConsents;
  bool hangUpdate;
  final calls = <String>[];
  UmpConsentStatus _status = UmpConsentStatus.unknown;
  bool eea = false;
  bool _canRequest = false;

  @override
  bool get linked => true;

  @override
  Future<bool> requestUpdate(
      {required bool debugEea, required List<String> testDeviceIds}) async {
    calls.add('update(eea=$debugEea, devices=$testDeviceIds)');
    if (hangUpdate) return Completer<bool>().future; // never answers
    eea = debugEea && testDeviceIds.contains(_testDevice);
    if (_status == UmpConsentStatus.unknown) {
      _status = eea ? UmpConsentStatus.required : UmpConsentStatus.notRequired;
      _canRequest = !eea;
    }
    return true;
  }

  @override
  Future<void> loadAndShowIfRequired() async {
    if (_status != UmpConsentStatus.required) return; // Google: no form
    calls.add('form.shown');
    _status = UmpConsentStatus.obtained;
    // UMP: after ANY answer the app may request ads (limited / NPA when
    // declined, TCF string tells the SDK)
    _canRequest = true;
  }

  @override
  Future<bool> canRequestAds() async {
    calls.add('canRequestAds');
    return _canRequest;
  }

  @override
  Future<PrivacyOptionsStatus> privacyOptionsStatus() async => eea
      ? PrivacyOptionsStatus.required
      : (_status == UmpConsentStatus.unknown
          ? PrivacyOptionsStatus.unknown
          : PrivacyOptionsStatus.notRequired);

  @override
  Future<UmpConsentStatus> consentStatus() async => _status;

  /// What the user does in the privacy options form (null = just closes).
  bool? revokeInPrivacyForm;

  @override
  Future<bool> showPrivacyOptionsForm() async {
    calls.add('privacyForm.shown');
    if (revokeInPrivacyForm == true) _canRequest = false;
    return true;
  }
}

class _Api extends ApiClient {
  _Api({this.eea = true, this.personalized = false}) {
    token = 't';
  }
  final bool eea;
  final bool personalized;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/ads/config') {
      return {
        'configured': false,
        'app_id': '',
        'units': const {},
        'plan': 'free',
        'paid': false,
        'ads_enabled': true,
        'personalized': personalized,
        'consent_debug_eea': eea,
        'consent_test_devices': eea ? [_testDevice] : const [],
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

AppState _app({bool eea = true}) {
  final app = AppState();
  app.api = _Api(eea: eea);
  app.user = AppUser(
      id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en');
  app.loading = false;
  return app;
}

Widget _host(AppState app, Widget child, {String lang = 'en'}) =>
    ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: ListView(children: [child])),
      ),
    );

/// Owner Admin -> Ads "Force EEA consent" + Integrations UMP test device.
void _debugEea(AdConsent c, {bool on = true}) => c.applyServerConfig({
      'consent_debug_eea': on,
      'consent_test_devices': on ? [_testDevice] : <String>[],
    });

void main() {
  late _FakeUmp ump;
  final c = AdConsent.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdsService.instance.resetForTest();
    AdmobSdk.resetForTest();
    ump = _FakeUmp();
    c.resetForTest(appId: _realAppId, bridge: ump);
  });

  group('UMP flow (DebugGeography EEA + test device)', () {
    test('no ad request can be built before the consent info update', () {
      expect(c.canServe, isFalse);
      expect(() => AdmobSdk.request(), throwsStateError);
      expect(ump.calls, isEmpty);
    });

    test('EEA: update -> Google form -> canRequestAds -> request', () async {
      _debugEea(c);
      expect(await c.allowsAds(), isTrue);
      expect(ump.calls, [
        'update(eea=true, devices=[$_testDevice])',
        'form.shown',
        'canRequestAds',
      ]);
      expect(c.canServe, isTrue);
      expect(AdmobSdk.request(), isNotNull);
    });

    test('not required (e.g. Bangladesh): no form, ads allowed', () async {
      _debugEea(c, on: false);
      expect(await c.allowsAds(), isTrue);
      expect(ump.calls.contains('form.shown'), isFalse);
      expect(c.consentStatus, UmpConsentStatus.notRequired);
    });

    test('"Do not consent" -> non-personalised even when the owner allows '
        'personalised ads', () async {
      _debugEea(c);
      ump.userConsents = false;
      AdmobSdk.personalized = true; // Owner Admin -> Ads -> personalised ON
      await c.allowsAds();
      expect(c.consentStatus, UmpConsentStatus.obtained);
      expect(c.mayPersonalise, isFalse);
      expect(AdmobSdk.request().nonPersonalizedAds, isTrue);
    });

    test('EEA "Consent" is still non-personalised (plugin cannot tell the '
        'answer -> safe side)', () async {
      _debugEea(c);
      ump.userConsents = true;
      AdmobSdk.personalized = true;
      await c.allowsAds();
      expect(AdmobSdk.request().nonPersonalizedAds, isTrue);
    });

    test('consent not required + owner allows -> personalised; owner off -> '
        'non-personalised', () async {
      _debugEea(c, on: false);
      await c.allowsAds();
      AdmobSdk.personalized = true;
      expect(AdmobSdk.request().nonPersonalizedAds, isFalse);
      AdmobSdk.personalized = false;
      expect(AdmobSdk.request().nonPersonalizedAds, isTrue);
    });

    test('canRequestAds false -> the gate stays shut, no request', () async {
      // the user closed the form without answering: UMP keeps "required"
      final b = _NoAnswerUmp();
      c.resetForTest(appId: _realAppId, bridge: b);
      _debugEea(c);
      expect(await c.allowsAds(), isFalse);
      expect(c.canServe, isFalse);
      expect(b.calls, contains('form.dismissed'));
      expect(() => AdmobSdk.request(), throwsStateError);
    });

    testWidgets('a hanging UMP update is time-boxed (never blocks)',
        (tester) async {
      ump.hangUpdate = true;
      _debugEea(c);
      bool? out;
      unawaited(c.allowsAds().then((v) => out = v));
      await tester.pump(const Duration(seconds: 13));
      await tester.pump();
      expect(out, isNotNull);
      expect(out, isFalse); // nothing known -> no ad
      expect(ump.calls.contains('form.shown'), isFalse);
    });

    testWidgets('AdsService feeds the Owner Admin debug knobs to UMP',
        (tester) async {
      final app = _app(eea: true);
      await AdsService.instance.configFor(app);
      expect(c.debugEea, isTrue);
      expect(c.testDeviceIds, [_testDevice]);
      await c.allowsAds();
      expect(ump.calls.first, 'update(eea=true, devices=[$_testDevice])');
    });
  });

  group('Settings -> Ads privacy', () {
    testWidgets('required: row shown; tap re-opens Google\'s form; withdrawing '
        'stops the next ad request', (tester) async {
      _debugEea(c);
      final app = _app(eea: true);
      await AdsService.instance.configFor(app);
      await c.allowsAds();
      expect(c.canServe, isTrue);
      ump.revokeInPrivacyForm = true;
      await tester.pumpWidget(_host(app, const AdPrivacyTile()));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.adsPrivacyTitle), findsOneWidget);
      expect(find.text(t.adsPrivacySub), findsOneWidget);
      final h = tester.getSize(find.byKey(const Key('settings-ad-privacy'))).height;
      expect(h, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('settings-ad-privacy')));
      await tester.pumpAndSettle();
      expect(ump.calls.contains('privacyForm.shown'), isTrue);
      expect(c.canServe, isFalse);
      expect(() => AdmobSdk.request(), throwsStateError);
    });

    testWidgets('Bangla title', (tester) async {
      _debugEea(c);
      final app = _app(eea: true);
      await AdsService.instance.configFor(app);
      await c.allowsAds();
      await tester.pumpWidget(_host(app, const AdPrivacyTile(), lang: 'bn'));
      await tester.pumpAndSettle();
      expect(find.text('বিজ্ঞাপনের গোপনীয়তা'), findsOneWidget);
    });

    testWidgets('not required: an honest line, not a button', (tester) async {
      _debugEea(c, on: false);
      final app = _app(eea: false);
      await tester.pumpWidget(_host(app, const AdPrivacyTile()));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byKey(const Key('settings-ad-privacy')), findsNothing);
      expect(find.byKey(const Key('settings-ad-privacy-info')), findsOneWidget);
      expect(find.text(t.adsPrivacyNotRequired), findsOneWidget);
      final tile = tester.widget<ListTile>(
          find.byKey(const Key('settings-ad-privacy-info')));
      expect(tile.onTap, isNull);
      expect(ump.calls.contains('form.shown'), isFalse); // Settings shows no form
    });
  });

  group('debug builds never load a REAL unit', () {
    setUp(() => AdIds.realUnitsAllowed = false);

    test('server real ids -> Google test units; rewarded not offered', () {
      final cfg = AdConfig.fromJson({
        'configured': true,
        'real_ids': true,
        'ads_enabled': true,
        'app_id': _realAppId,
        'units': {'banner': _realBanner, 'rewarded': '$_realBanner-r'},
      });
      expect(cfg.unitFor(AdKind.banner, builtAppId: _realAppId),
          AdIds.testBanner);
      expect(cfg.unitFor(AdKind.rewarded, builtAppId: _realAppId), isNull);
      const hero = HeroAdConfig(
          enabled: true,
          configured: true,
          appId: _realAppId,
          nativeUnit: '$_realBanner-n');
      expect(hero.unit(builtAppId: _realAppId), HeroAdIds.testNative);
    });

    test('the gate refuses a real unit, allows Google test units', () {
      expect(AdmobSdk.unitAllowed(_realBanner), isFalse);
      expect(AdmobSdk.unitAllowed(AdIds.testBanner), isTrue);
      expect(AdmobSdk.unitAllowed(''), isFalse);
      AdIds.realUnitsAllowed = true; // release build
      expect(AdmobSdk.unitAllowed(_realBanner), isTrue);
    });
  });

  test('ads never on SOS / safety / calls / open chat / payment / login / '
      'permission screens', () {
    for (final s in [
      'sos', 'safety', 'circle_call', 'incoming_call', 'circle_chat', 'chat',
      'payment', 'checkout', 'plans', 'login', 'otp', 'permission',
    ]) {
      for (final slot in AdSurface.values) {
        expect(AdPlacements.screenAllowed(slot, s), isFalse, reason: '$slot/$s');
      }
    }
    // the My Circle chat LIST may carry the one small banner
    expect(AdPlacements.screenAllowed(AdSurface.banner, 'circle_list'), isTrue);
  });
}

/// UMP where the user never answered the form (app closed): still required.
class _NoAnswerUmp extends _FakeUmp {
  @override
  Future<void> loadAndShowIfRequired() async => calls.add('form.dismissed');
}
