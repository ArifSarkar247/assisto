// discms (owner 10 Nov 01:53 + 01:56 + ads final 03:45): Home Discover is the
// owner's ads + app-updates slot. Owner cards (What's new, Offer, Sponsored
// labelled Ad) render for everyone; the AdMob slot shows ONE native ad in the
// same card box (Free only, owner switch `discover_native`), no empty card on
// no fill; the carousel's size / place on Home never changes; offline = the
// last cached cards; a card for a Home tile is not repeated.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/hero_ad.dart';
import 'package:assisto/api.dart';
import 'package:assisto/discover_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/home_v2/home_v2_tokens.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/home_suggestions.dart';

class _Api extends ApiClient {
  Map<String, dynamic>? response;
  bool fail = false;

  _Api() {
    token = 'test-token';
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (fail || response == null) throw ApiException('offline', 503);
    return response!;
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};
}

class _Handle implements HeroAdHandle {
  bool disposed = false;
  @override
  bool get hasVideo => false;
  @override
  Widget view() => const ColoredBox(
      key: ValueKey('fake_native'), color: Colors.white, child: SizedBox.expand());
  @override
  void dispose() => disposed = true;
}

class _Bridge implements HeroAdBridge {
  _Bridge({this.fill = true});
  final bool fill;
  int loads = 0;
  @override
  bool get linked => true;
  @override
  Future<HeroAdHandle?> load(String unitId,
      {required bool startMuted,
      HeroAdLook? look,
      HeroAdSize size = HeroAdSize.compact}) async {
    loads++;
    return fill ? _Handle() : null;
  }
}

Map<String, dynamic> _card(int id, String type,
        {String en = '', String route = '', String url = ''}) =>
    {
      'id': id,
      'key': 'k$id',
      'type': type,
      'title': {'bn': 'বি$en', 'en': en},
      'description': {'bn': 'বিবরণ', 'en': '$en desc'},
      'icon': 'star',
      'image_url': '',
      'route': route,
      'url': url,
    };

Map<String, dynamic> _feed({bool admob = true}) => {
      'cards': [
        _card(1, 'WHATS_NEW', en: 'New update', route: 'notes'),
        _card(2, 'OFFER', en: 'Big offer', url: 'https://shop.example.com'),
        _card(3, 'SPONSORED', en: 'Brand', url: 'https://brand.example.com'),
        if (admob) _card(4, 'ADMOB'),
        _card(5, 'FEATURE', en: 'Reminders', route: 'reminders'),
      ],
      'segment': admob ? 'free' : 'premium',
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

Future<void> _pump(WidgetTester tester, _Api api, {String lang = 'en'}) async {
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
      theme: AssistoTheme.light,
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

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(HomeSuggestions)));

double _carouselHeight(WidgetTester tester) =>
    tester.getSize(find.byType(PageView)).height;

Future<void> _swipeTo(WidgetTester tester, int page) async {
  final pv = tester.widget<PageView>(find.byType(PageView));
  pv.controller!.jumpToPage(page);
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'Assisto',
        packageName: 'com.assisto.assisto',
        version: '1.0.0',
        buildNumber: '320',
        buildSignature: '');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    homeTilesShown.value = const <String>{};
    HomeSuggestions.debugAdConfig =
        () async => {'plan': 'free', 'paid': false, 'units': {}};
  });

  tearDown(() {
    HomeSuggestions.debugAdBridge = null;
    HomeSuggestions.debugAdConfig = null;
    homeTilesShown.value = const <String>{};
  });

  testWidgets('Free user: one AdMob native card in the SAME card box',
      (tester) async {
    final bridge = _Bridge();
    HomeSuggestions.debugAdBridge = bridge;
    final api = _Api()..response = _feed();
    await _pump(tester, api);
    expect(bridge.loads, 1);
    // Sponsored (3rd page) and AdMob are never side by side: one owner card
    // between them -> the ad is the 5th page
    await _swipeTo(tester, 4);
    expect(find.byKey(const ValueKey('discover_v2_admob')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake_native')), findsOneWidget);
    // Home layout unchanged: the carousel keeps the reference card height
    expect(_carouselHeight(tester), HV2.discoverHeight(1));
    final adBox = tester.getSize(find.byKey(const ValueKey('discover_v2_admob')));
    expect(adBox.height, HV2.discoverHeight(1));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('no fill -> the slot is left out (never an empty card)',
      (tester) async {
    HomeSuggestions.debugAdBridge = _Bridge(fill: false);
    final api = _Api()..response = _feed();
    await _pump(tester, api);
    for (var i = 0; i < 4; i++) {
      await _swipeTo(tester, i);
      expect(find.byKey(const ValueKey('discover_v2_admob')), findsNothing);
    }
    expect(find.byKey(const ValueKey('discover_v2_k4')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('Premium / Plus: no AdMob slot, owner cards still shown',
      (tester) async {
    final bridge = _Bridge();
    HomeSuggestions.debugAdBridge = bridge;
    final api = _Api()..response = _feed(admob: false); // server drops it
    await _pump(tester, api);
    expect(bridge.loads, 0);
    expect(find.text('New update'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('paid plan in /ads/config never loads an ad, even if sent',
      (tester) async {
    final bridge = _Bridge();
    HomeSuggestions.debugAdBridge = bridge;
    HomeSuggestions.debugAdConfig =
        () async => {'plan': 'plus', 'paid': true, 'units': {}};
    final api = _Api()..response = _feed();
    await _pump(tester, api);
    expect(bridge.loads, 0);
    await _unmount(tester);
  });

  testWidgets('owner Ad control switch OFF -> no Discover ad', (tester) async {
    final bridge = _Bridge();
    HomeSuggestions.debugAdBridge = bridge;
    HomeSuggestions.debugAdConfig = () async => {
          'plan': 'free',
          'units': {},
          'control': {
            'placements': {
              'discover_native': {'on': false, 'type': 'native'}
            }
          }
        };
    final api = _Api()..response = _feed();
    await _pump(tester, api);
    expect(bridge.loads, 0);
    await _unmount(tester);
  });

  test('switch helper: missing registry = ON (owner default)', () {
    expect(discoverAdSwitchOn(null), isTrue);
    expect(discoverAdSwitchOn({'units': {}}), isTrue);
    expect(
        discoverAdSwitchOn({
          'control': {
            'placements': {
              'discover_native': {'on': true}
            }
          }
        }),
        isTrue);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] badges: Sponsored = Ad, What\'s new, Offer',
        (tester) async {
      final api = _Api()..response = _feed(admob: false);
      await _pump(tester, api, lang: lang);
      final t = _t(tester);
      expect(find.text(t.discmsWhatsNewBadge), findsOneWidget);
      await _swipeTo(tester, 1);
      expect(find.text(t.discmsOfferBadge), findsOneWidget);
      await _swipeTo(tester, 2);
      expect(find.text(t.discoverAdBadge), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }

  test('the Ad badge comes from the type, never from server text', () {
    final sp = DiscoverItem.fromJson({
      ..._card(3, 'SPONSORED', en: 'Brand', url: 'https://b.example.com'),
      'label': '',
    });
    expect(sp.hasBadge, isTrue);
  });

  testWidgets('every card type keeps the reference carousel height',
      (tester) async {
    for (final feed in [
      {
        'cards': [_card(9, 'FEATURE', en: 'Reminders', route: 'reminders')]
      },
      _feed(admob: false),
    ]) {
      SharedPreferences.setMockInitialValues({});
      final api = _Api()..response = feed;
      await _pump(tester, api);
      expect(_carouselHeight(tester), HV2.discoverHeight(1));
      await _unmount(tester);
    }
  });

  testWidgets('offline: the last cached owner cards still show',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      HomeSuggestions.cacheKey: jsonEncode([
        _card(1, 'WHATS_NEW', en: 'New update', route: 'notes'),
      ]),
    });
    final api = _Api()..fail = true;
    await _pump(tester, api);
    expect(find.text('New update'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('an owner card for a Home tile is not repeated', (tester) async {
    homeTilesShown.value = {'reminders'};
    final api = _Api()..response = _feed(admob: false);
    await _pump(tester, api);
    for (var i = 0; i < 3; i++) {
      await _swipeTo(tester, i);
    }
    expect(find.text('Reminders'), findsNothing);
    expect(find.byKey(const ValueKey('discover_v2_k5')), findsNothing);
    await _unmount(tester);
  });
}
