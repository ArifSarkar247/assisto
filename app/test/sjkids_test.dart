// sjkids — Children Corner (Safe Journey v2): the guardian question card,
// the places list and the add / edit form. Made-up data only.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/safe_journey/kids_corner.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_sjkids.dart';

class _Hit {
  final String method, path;
  final Map<String, dynamic> body;
  _Hit(this.method, this.path, this.body);
}

class _Api extends ApiClient {
  _Api() {
    token = 'test-token';
  }
  final hits = <_Hit>[];
  bool patchFails = false;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    hits.add(_Hit('GET', path, const {}));
    if (path == '/school-mode/places') {
      return {
        'places': [
          {'id': 9, 'label': 'Coaching centre', 'name': '', 'lat': 23.7741, 'lng': 90.4182},
        ]
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    hits.add(_Hit('POST', path, body));
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> patchJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    hits.add(_Hit('PATCH', path, body));
    if (patchFails) throw ApiException('bad_window', 400);
    return {'ok': true, 'plan': {'config': {'kc_places': body['kc_places']}}};
  }

  List<_Hit> of(String m, String p) =>
      hits.where((h) => h.method == m && h.path == p).toList();
}

Widget _app(_Api api, Widget home, {String lang = 'en', double scale = 1, bool dark = false}) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Abbu', phone: '01711000001', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    ),
  );
}

Widget _section(Map<String, dynamic> plan, Future<void> Function() onChanged) => Scaffold(
    body: ListView(padding: const EdgeInsets.all(16), children: [
      KidsCornerSection(plan: plan, onChanged: onChanged),
    ]));

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

late AppLocalizations en, bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pure', () {
    test('kinds, defaults, weekday mapping', () {
      expect(kcIsWatch('river'), isTrue);
      expect(kcIsWatch('coaching'), isFalse);
      expect(kcDefaultWindow('school'),
          {'days': [6, 0, 1, 2, 3], 'start': '08:00', 'end': '13:00'});
      expect(kcDefaultWindow('coaching')!['start'], '16:00');
      expect(kcDefaultWindow('river'), isNull);
      expect(kcDefaultWindow('relative'), isNull);
      expect(kcMaterialDay(6), 0); // Python Sunday -> Material Sunday
      expect(kcMaterialDay(5), 6); // Saturday
      expect(kcPlaceName(en, 'river', ''), en.kcKindRiver);
      expect(kcPlaceName(bn, 'relative', ' '), bn.kcKindRelative);
      expect(kcPlaceName(en, 'market', 'Notun Bazar'), 'Notun Bazar');
    });
  });

  testWidgets('guardian question: I know -> kc-answer with the ask id', (tester) async {
    final api = _Api();
    var reloaded = 0;
    await tester.pumpWidget(_app(api, _section(kcFakePlan('en'), () async => reloaded++)));
    await _settle(tester);
    expect(find.text(en.kcAskTitle('Rina')), findsOneWidget);
    expect(find.text(en.kcAskMap), findsOneWidget);           // last location button
    await tester.tap(find.byKey(const ValueKey('kc_ask_ok_2026-11-09-0@0800')));
    await _settle(tester);
    final hits = api.of('POST', '/school-mode/plans/5/kc-answer');
    expect(hits, hasLength(1));
    expect(hits.single.body, {'ask_id': '2026-11-09-0@0800', 'answer': 'ok'});
    expect(reloaded, 1);
  });

  testWidgets('no places: benefit line + add button; watcher sees no add button',
      (tester) async {
    final api = _Api();
    final plan = kcFakePlan('en', empty: true);
    await tester.pumpWidget(_app(api, _section(plan, () async {})));
    await _settle(tester);
    expect(find.text(en.kcEmptyBody), findsOneWidget);
    expect(find.byKey(const ValueKey('kc_places_5')), findsOneWidget);
    await tester.pumpWidget(_app(api, _section({...plan, 'mine': false}, () async {})));
    await _settle(tester);
    expect(find.byKey(const ValueKey('kc_places_5')), findsNothing);
    expect(find.text(en.kcOnlyOwner), findsOneWidget);
  });

  testWidgets('add a coaching place on Sun + Tue 4-6 pm from a saved place', (tester) async {
    final api = _Api();
    await tester.pumpWidget(_app(api, KidsPlacesScreen(plan: kcFakePlan('en', empty: true))));
    await _settle(tester);
    expect(find.text(en.kcEmptyTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kc_add')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('kc_kind_coaching')));
    await _settle(tester);
    // saving without a location is refused with a reason
    await tester.ensureVisible(find.byKey(const ValueKey('kc_save')));
    await tester.tap(find.byKey(const ValueKey('kc_save')));
    await _settle(tester);
    expect(find.text(en.kcNeedLocation), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('kc_pick_loc')));
    await tester.tap(find.byKey(const ValueKey('kc_pick_loc')));
    await _settle(tester);
    await tester.tap(find.text('Coaching centre'));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('kc_save')));
    await tester.tap(find.byKey(const ValueKey('kc_save')));
    await _settle(tester);
    final p = api.of('PATCH', '/school-mode/plans/5');
    expect(p, hasLength(1));
    final places = (p.single.body['kc_places'] as List).cast<Map>();
    expect(places, hasLength(1));
    expect(places.single['kind'], 'coaching');
    expect(places.single['lat'], 23.7741);
    expect(places.single['windows'], [
      {'days': [0, 2], 'start': '16:00', 'end': '18:00'}
    ]);
    expect(find.text(en.kcSaved), findsOneWidget);
    expect(find.text(en.kcKindCoaching), findsWidgets);
  });

  testWidgets('a watch place is sent with no time windows', (tester) async {
    final api = _Api();
    await tester.pumpWidget(_app(api, KidsPlacesScreen(plan: kcFakePlan('en', empty: true))));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('kc_add')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('kc_kind_river')));
    await _settle(tester);
    expect(find.text(en.kcWatchExplain), findsOneWidget);
    expect(find.byKey(const ValueKey('kc_timed')), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('kc_pick_loc')));
    await tester.tap(find.byKey(const ValueKey('kc_pick_loc')));
    await _settle(tester);
    await tester.tap(find.text('Coaching centre'));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('kc_save')));
    await tester.tap(find.byKey(const ValueKey('kc_save')));
    await _settle(tester);
    final body = api.of('PATCH', '/school-mode/plans/5').single.body;
    final place = (body['kc_places'] as List).single as Map;
    expect(place['kind'], 'river');
    expect(place['windows'], isEmpty);
  });

  testWidgets('server refusal shows a plain reason, nothing is lost', (tester) async {
    final api = _Api()..patchFails = true;
    await tester.pumpWidget(_app(api, KidsPlacesScreen(plan: kcFakePlan('en'))));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('kc_place_0')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('kc_delete')));
    await tester.tap(find.byKey(const ValueKey('kc_delete')));
    await _settle(tester);
    expect(find.text(en.kcBadTime), findsOneWidget);
    expect(find.byKey(const ValueKey('kc_place_4')), findsOneWidget); // still 5 places
  });

  testWidgets('Bangla: Bangla digits in times, 200% font, dark — no overflow',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(
        _app(api, KidsPlacesScreen(plan: kcFakePlan('bn')), lang: 'bn', scale: 2, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.contains('·'))
        .toList();
    expect(texts, isNotEmpty);
    for (final s in texts) {
      expect(RegExp(r'[0-9]').hasMatch(s), isFalse, reason: s);
    }
    await tester.pumpWidget(_app(api, _section(kcFakePlan('bn'), () async {}),
        lang: 'bn', scale: 2, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(bn.kcAskTitle('রিনা')), findsOneWidget);
  });
}
