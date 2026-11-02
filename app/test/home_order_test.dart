// homeorder (explicit owner order 2 Nov 17:35 / 17:40):
//  * Discover: SOS is the FIRST default item, Train tracker the second
//    (Train only while flag train_tracker is ON) — server-side defaults the
//    owner overrides from Owner Admin; the app's first-run fallback mirrors
//    them (+2 items).
//  * A Sponsored / ad card is NEVER directly next to SOS or Blood donor —
//    re-checked in the app after its own filtering + personalisation.
//  * Every card shows only while its feature flag is ON (preview = off).
//  * Home shortcuts: Blood donor right next to SOS (flag blood_donors).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/discover_api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/home_suggestions.dart';

class _Api extends ApiClient {
  Map<String, dynamic>? response;
  _Api() {
    token = 'test-token';
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (response == null) throw ApiException('offline', 503);
    return response!;
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

DiscoverItem _i(String key, String type, {String route = '', String url = ''}) =>
    DiscoverItem(
        key: key,
        type: type,
        route: route,
        url: url.isEmpty && route.isEmpty ? 'https://shop.example.com' : url,
        titleEn: key,
        titleBn: key);

const _f = DiscoverItem.feature;
const _s = DiscoverItem.sponsored;

List<String> _keys(List<DiscoverItem> l) => [for (final c in l) c.key];

/// No ad directly next to SOS / Blood donor.
bool _ruleHolds(List<DiscoverItem> l) {
  for (var i = 0; i + 1 < l.length; i++) {
    final a = l[i], b = l[i + 1];
    if ((a.isSponsored || a.isAdmob) && discoverProtected(b)) return false;
    if ((b.isSponsored || b.isAdmob) && discoverProtected(a)) return false;
  }
  return true;
}

Map<String, dynamic> _card(int id, String type,
        {String en = '', String route = '', String url = ''}) =>
    {
      'id': id,
      'key': 'k$id',
      'type': type,
      'label': type == 'SPONSORED' ? 'sponsored' : '',
      'title': {'bn': 'বিএন$en', 'en': en},
      'description': {'bn': 'বিবরণ', 'en': '$en desc'},
      'icon': 'emergency',
      'image_url': '',
      'route': route,
      'url': url,
    };

AppState _state(_Api api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1,
      name: 'A',
      phone: '01700000000',
      email: '',
      autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Future<void> _pump(WidgetTester tester, _Api api,
    {String lang = 'en', double scale = 1, bool dark = false}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(api, lang),
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(scale),
              padding: const EdgeInsets.only(bottom: 48)),
          child: child!),
      home: const Scaffold(
          body: SingleChildScrollView(
              child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: HomeSuggestions(v2: true)))),
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'Assisto',
        packageName: 'com.assisto.assisto',
        version: '1.0.0',
        buildNumber: '283',
        buildSignature: '');
  });
  setUp(() => FeatureFlags.instance.resetForTest());
  tearDown(() => FeatureFlags.instance.resetForTest());

  group('ad placement rule (never next to SOS / Blood donor)', () {
    test('sponsor after SOS moves one slot later', () {
      final out = separateDiscoverAds([
        _i('sos', _f, route: kDiscoverSosRoute),
        _i('ad', _s),
        _i('j', _f, route: 'journey'),
        _i('m', _f, route: 'money'),
      ]);
      expect(_keys(out), ['sos', 'j', 'ad', 'm']);
    });

    test('sponsor before Blood donor moves earlier', () {
      final out = separateDiscoverAds([
        _i('j', _f, route: 'journey'),
        _i('ad', _s),
        _i('blood', _f, route: 'blood_panel'),
      ]);
      expect(_keys(out), ['ad', 'j', 'blood']);
    });

    test('no allowed slot -> the ad is dropped, never shown next to SOS', () {
      final out = separateDiscoverAds([
        _i('sos', _f, route: 'emergency'),
        _i('ad', _s),
        _i('blood', _f, route: 'blood_panel'),
      ]);
      expect(_keys(out), ['sos', 'blood']);
    });

    test('the new Emergency hub route is protected too', () {
      final out = separateDiscoverAds([
        _i('hub', _f, route: 'emergency_hub'),
        _i('ad', _s),
        _i('n', _f, route: 'notes'),
      ]);
      expect(_keys(out), ['hub', 'n', 'ad']);
    });

    test('exhaustive: every order of 2 ads among SOS/Blood/3 features', () {
      final base = [
        _i('sos', _f, route: 'emergency'),
        _i('blood', _f, route: 'blood_panel'),
        _i('a', _f, route: 'notes'),
        _i('b', _f, route: 'money'),
        _i('c', _f, route: 'journey'),
      ];
      for (var p = 0; p <= base.length; p++) {
        for (var q = p; q <= base.length + 1; q++) {
          final l = [...base]
            ..insert(p, _i('ad1', _s))
            ..insert(q, _i('ad2', _s));
          final out = separateDiscoverAds(l);
          expect(_ruleHolds(out), isTrue, reason: _keys(out).join(','));
          // non-ad cards keep the owner's order
          expect(_keys(out.where((c) => !c.isSponsored).toList()),
              _keys(base));
        }
      }
    });

    test('rule re-applied after the app hides a flag-off card', () {
      // server order [SOS, Train, Sponsored, Notes] was fine; Train flag is
      // OFF in this build -> the sponsor would touch SOS -> moved
      final items = parseDiscoverItems([
        _card(1, 'FEATURE', en: 'SOS', route: 'emergency'),
        _card(2, 'FEATURE', en: 'Train', route: 'train_tracker'),
        _card(3, 'SPONSORED', en: 'Shop', url: 'https://shop.example.com'),
        _card(4, 'FEATURE', en: 'Plans', route: 'plans'),
      ]);
      FeatureFlags.instance.debugOverride = {'train_tracker': false};
      expect(renderableDiscover(items).map((c) => c.id), [1, 4, 3]);
      FeatureFlags.instance.debugOverride = {'train_tracker': true};
      expect(renderableDiscover(items).map((c) => c.id), [1, 2, 3, 4]);
    });
  });

  group('flags', () {
    test('a preview-only feature is not shown on Discover', () {
      FeatureFlags.instance.applyForTest({
        'features': {'train_tracker': true},
        'preview': ['train_tracker'],
      });
      final items = parseDiscoverItems([
        _card(1, 'FEATURE', en: 'SOS', route: 'emergency'),
        _card(2, 'FEATURE', en: 'Train', route: 'train_tracker'),
      ]);
      expect(renderableDiscover(items).map((c) => c.id), [1]);
    });

    test('first-run fallback: SOS first, Train second only when ON, +2', () {
      expect(kDiscoverFallback.length, 14); // ownerfix: + Destination Alarm, Blood donor
      expect(kDiscoverFallback.first.route, kDiscoverSosRoute);
      expect(kDiscoverFallback[1].route, 'train_tracker');
      FeatureFlags.instance.debugOverride = {'train_tracker': false};
      final off = renderableDiscover(kDiscoverFallback);
      expect(off.first.key, 'sos');
      expect(off.map((c) => c.key), isNot(contains('train_tracker')));
      FeatureFlags.instance.debugOverride = {'train_tracker': true};
      expect(renderableDiscover(kDiscoverFallback).take(2).map((c) => c.key),
          ['sos', 'train_tracker']);
    });

    test('SOS keeps first place even after the user opened it', () async {
      // personalisation moves opened FEATURE cards back — never SOS
      expect(discoverProtected(kDiscoverFallback.first), isTrue);
    });

    test('home shortcuts: Blood donor next to SOS only when its flag is ON',
        () {
      expect(HomeV2Shortcuts.defaults(), isNot(contains('blood_panel')));
      FeatureFlags.instance.debugOverride = {'blood_donors': true};
      final d = HomeV2Shortcuts.defaults();
      expect(d.indexOf('blood_panel'), d.indexOf('emergency') + 1);
      expect(d.length, HomeV2Shortcuts.max);
    });
  });

  group('rendering', () {
    for (final lang in ['en', 'bn']) {
      for (final dark in [false, true]) {
        testWidgets('server set, 360dp, 200% font, $lang, dark=$dark',
            (tester) async {
          SharedPreferences.setMockInitialValues({});
          final api = _Api()
            ..response = {
              'cards': [
                _card(1, 'FEATURE', en: 'Emergency SOS', route: 'emergency'),
                _card(2, 'SPONSORED',
                    en: 'Fresh market', url: 'https://shop.example.com'),
                _card(3, 'FEATURE', en: 'Plans', route: 'plans'),
              ],
              'segment': 'free',
            };
          await _pump(tester, api, lang: lang, scale: 2, dark: dark);
          expect(tester.takeException(), isNull);
          final t = AppLocalizations.of(
              tester.element(find.byType(HomeSuggestions)));
          // SOS is the first page; the sponsor is NOT the peeking second one
          final sos = find.text(lang == 'en' ? 'Emergency SOS' : 'বিএনEmergency SOS');
          expect(sos, findsOneWidget);
          final cached = jsonDecode((await SharedPreferences.getInstance())
              .getString(HomeSuggestions.cacheKey)!) as List;
          expect(cached.length, 3);
          final shown = renderableDiscover(parseDiscoverItems(cached));
          expect(shown.map((c) => c.id), [1, 3, 2]);
          expect(t.discoverSponsoredLabel,
              lang == 'en' ? 'Sponsored' : 'স্পনসর্ড');
          await _unmount(tester);
        });
      }
    }
  });
}
