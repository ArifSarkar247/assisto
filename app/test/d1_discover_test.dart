// d1-discover: the home Discover cards are server-driven, cached for offline,
// fall back to the built-in list only on first run, label sponsored / our
// products cards, pick bn/en copy by UI language, render nothing for ADMOB and
// record impressions + taps fire-and-forget.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/discover_api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/home_suggestions.dart';

class _Api extends ApiClient {
  Map<String, dynamic>? response;
  bool fail = false;
  final List<String> gets = [];
  final List<Map<String, dynamic>> tracked = [];

  _Api() {
    token = 'test-token';
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (fail || response == null) {
      throw ApiException('offline', 503);
    }
    return response!;
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/discover/track') tracked.add(body);
    return {'ok': true, 'counted': 1};
  }
}

Map<String, dynamic> _card(int id, String type,
        {String en = '', String bn = '', String route = '', String url = ''}) =>
    {
      'id': id,
      'key': 'k$id',
      'type': type,
      'label': '',
      'title': {'bn': bn, 'en': en},
      'description': {'bn': '$bn desc', 'en': '$en desc'},
      'icon': 'star',
      'image_url': '',
      'route': route,
      'url': url,
    };

final _server = {
  'cards': [
    _card(7, 'SPONSORED',
        en: 'Fresh market', bn: 'BN-fresh', url: 'https://shop.example.com'),
    _card(8, 'ADMOB'),
    _card(9, 'FEATURE', en: 'Notes now', bn: 'BN-notes', route: 'notes'),
    _card(10, 'OUR_PRODUCT',
        en: 'Asalify', bn: 'Asalify', url: 'https://asalify.com'),
  ],
  'segment': 'free',
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
      home: const Scaffold(body: Center(child: HomeSuggestions())),
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

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'Assisto',
        packageName: 'com.assisto.assisto',
        version: '1.0.0',
        buildNumber: '148',
        buildSignature: '');
  });

  testWidgets('server cards render with Sponsored label, build sent, '
      'ADMOB skipped, impression tracked, set cached', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api()..response = _server;
    await _pump(tester, api);
    expect(api.gets.single, '/discover/cards?build=148');
    expect(find.text('Fresh market'), findsOneWidget);
    expect(find.text(_t(tester).discoverSponsored), findsOneWidget);
    // ADMOB renders nothing: 3 renderable cards -> 3 page dots.
    expect(find.byType(AnimatedContainer), findsNWidgets(3));
    expect(api.tracked, [
      {'card_id': 7, 'event': 'impression'}
    ]);
    final prefs = await SharedPreferences.getInstance();
    final cached = jsonDecode(prefs.getString(HomeSuggestions.cacheKey)!) as List;
    expect(cached.length, 4);
    await _unmount(tester);
  });

  testWidgets('UI language picks the Bangla copy', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api()..response = _server;
    await _pump(tester, api, lang: 'bn');
    expect(find.text('BN-fresh'), findsOneWidget);
    expect(find.text('Fresh market'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('offline -> last cached server set is shown', (tester) async {
    SharedPreferences.setMockInitialValues({
      HomeSuggestions.cacheKey: jsonEncode([
        _card(11, 'OUR_PRODUCT',
            en: 'Cached product', bn: 'c', url: 'https://axonerpsoftware.com')
      ]),
    });
    final api = _Api()..fail = true;
    await _pump(tester, api);
    expect(find.text('Cached product'), findsOneWidget);
    expect(find.text(_t(tester).discoverOurProducts), findsOneWidget);
    expect(find.text(_t(tester).b2PhotoStudioTitle), findsNothing);
    await _unmount(tester);
  });

  testWidgets('first run, no cache, no network -> built-in fallback',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api()..fail = true;
    await _pump(tester, api);
    expect(find.text(_t(tester).b2PhotoStudioTitle), findsOneWidget);
    // fallback cards carry no server id -> nothing is tracked
    expect(api.tracked, isEmpty);
    await _unmount(tester);
  });

  testWidgets('owner disabled everything -> Discover renders nothing',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api()..response = {'cards': [], 'segment': 'premium'};
    await _pump(tester, api);
    expect(find.byType(PageView), findsNothing);
    await _unmount(tester);
  });

  testWidgets('tap is tracked fire-and-forget', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _Api()..response = _server;
    await _pump(tester, api);
    await tester.tap(find.text('Fresh market'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.tracked.where((e) => e['event'] == 'click').toList(), [
      {'card_id': 7, 'event': 'click'}
    ]);
    await _unmount(tester);
  });

  test('renderable filter: ADMOB, unknown route, non-https dropped', () {
    final items = parseDiscoverItems([
      _card(1, 'ADMOB'),
      _card(2, 'FEATURE', en: 'x', route: 'no_such_screen'),
      _card(3, 'OUR_PRODUCT', en: 'y', url: 'http://plain.example.com'),
      _card(4, 'FEATURE', en: 'z', route: 'plans'),
    ]);
    expect(renderableDiscover(items).map((c) => c.id), [4]);
    expect(DiscoverItem.fromJson(_card(5, 'SPONSORED')).isSponsored, isTrue);
  });
}
