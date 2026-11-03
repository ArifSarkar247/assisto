// p2food: food photo -> calories. Cited math (never invented), manual pick ->
// portion -> log, uncited dish needs the user's own number, goal, honest
// states (feature off / no photo key / offline), Bangla digits, 200% text,
// dark, 48 dp, and the vision job's dish ids.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/chat_vision/cv_backend.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/food_calories_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/health_disclaimer_bar.dart';

import 'fake_api.dart';
import 'fake_food.dart';

class _OffApi extends FakeApi {
  _OffApi() : super(lang: 'en');
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/food/table') throw ApiException('feature_off', 403);
    return super.getJson(path);
  }
}

class _RecApi extends FakeApi {
  _RecApi() : super(lang: 'en');
  final created = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) {
    if (path == foodLogPath) created.add(body);
    return super.createItem(path, body);
  }
}

AppState _state(FakeApi api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  s.online = true;
  return s;
}

Widget _app(FakeApi api,
        {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api, lang),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: const FoodCaloriesScreen(),
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

FoodDish _d(String id) => (fakeFoodTable(bn: false)['dishes'] as List)
    .map((e) => FoodDish.fromJson(Map<String, dynamic>.from(e as Map)))
    .firstWhere((d) => d.id == id);

void main() {
  group('FoodMath (mirrors backend/core/logic/food_calories.py)', () {
    test('cited scaling; uncited dish never gets a number', () {
      final n = FoodMath.of(_d('bhat'), 316)!;
      expect(n['kcal'], 351); // 111 kcal/100 g (FCT 01_0041) x 3.16
      expect(n['carb'], 78.4);
      expect(FoodMath.of(_d('fuchka'), 100), isNull);
      expect(FoodMath.of(_d('bhat'), 0), isNull);
      expect(FoodMath.of(_d('bhat'), 3001), isNull);
    });

    test('day totals count unknown entries separately', () {
      final d = FoodMath.day(fakeFoodLog(DateTime(2026, 11, 3)), '2026-11-03');
      expect(d['kcal'], 402);
      expect(d['count'], 3);
      expect(d['unknown'], 1);
    });

    test('goal bounds', () {
      expect(FoodMath.cleanGoal('700'), isNull);
      expect(FoodMath.cleanGoal('1800'), 1800);
      expect(FoodMath.cleanGoal('x'), isNull);
    });

    test('vision job carries dish ids', () {
      final j = CvJob.fromJson({
        'id': 3,
        'status': 'done',
        'dishes': [
          {'id': 'bhat', 'confidence': 'high'},
          {'id': 'dal'},
          'junk',
        ],
      })!;
      expect(j.dishes, ['bhat', 'dal']);
      expect(CvJob.fromJson({'id': 1})!.dishes, isEmpty);
    });
  });

  testWidgets('today card, cited source, no photo key -> honest line', (tester) async {
    await tester.pumpWidget(_app(FakeApi(lang: 'en')));
    await _settle(tester);
    expect(find.byKey(const Key('food-today')), findsOneWidget);
    expect(find.text('402 of 1800 kcal'), findsOneWidget);
    expect(find.textContaining('1 item(s) without a cited value'), findsOneWidget);
    expect(find.byKey(const Key('food-photo-not-ready')), findsOneWidget);
    expect(find.byKey(const Key('food-photo')), findsNothing);
    final src = find.textContaining('Source: FCT Bangladesh 2013 · 01_0041');
    await tester.scrollUntilVisible(src, 200,
        scrollable: find.byType(Scrollable).first);
    expect(src, findsWidgets);
    expect(find.byKey(HealthDisclaimerBar.barKey), findsOneWidget);
  });

  testWidgets('pick from list -> portion -> logged with the cited numbers', (tester) async {
    final api = _RecApi();
    await tester.pumpWidget(_app(api));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('food-pick')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('food-search')), 'bhat');
    await _settle(tester, 3);
    await tester.tap(find.text('Rice (white, boiled)').last);
    await _settle(tester);
    expect(find.byKey(const Key('food-source-line')), findsOneWidget);
    expect(find.text('351 kcal'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add_circle_outline_rounded)); // 1.5 plates
    await _settle(tester, 3);
    expect(find.text('526 kcal'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('food-add')));
    await tester.tap(find.byKey(const Key('food-add')));
    await _settle(tester);
    expect(api.created, hasLength(1));
    final row = api.created.single;
    expect(row['dish'], 'bhat');
    expect(row['kcal'], 526);
    expect(row['src'], 'fct');
    expect(row['code'], '01_0041');
    expect(row['grams'], 474);
    expect(find.text('928 of 1800 kcal'), findsOneWidget);
  });

  testWidgets('uncited dish: no number unless the user types one', (tester) async {
    final api = _RecApi();
    await tester.pumpWidget(_app(api));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('food-pick')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('food-search')), 'fuchka');
    await _settle(tester, 3);
    await tester.tap(find.text('Fuchka').last);
    await _settle(tester);
    expect(find.byKey(const Key('food-kcal')), findsNothing);
    expect(find.textContaining('never make up a number'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('food-self-kcal')), '250');
    await _settle(tester, 3);
    await tester.ensureVisible(find.byKey(const Key('food-add')));
    await tester.tap(find.byKey(const Key('food-add')));
    await _settle(tester);
    final row = api.created.single;
    expect(row['kcal'], 250);
    expect(row['self'], true);
    expect(row['src'], '');
  });

  testWidgets('goal sheet validates the range', (tester) async {
    await tester.pumpWidget(_app(FakeApi(lang: 'en')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('food-goal')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('food-goal-field')), '300');
    await tester.tap(find.byKey(const Key('food-goal-save')));
    await _settle(tester, 3);
    expect(find.textContaining('from 800 to 5000'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('food-goal-field')), '2200');
    await tester.tap(find.byKey(const Key('food-goal-save')));
    await _settle(tester);
    expect(find.text('402 of 2200 kcal'), findsOneWidget);
  });

  testWidgets('empty state: benefit + big button + how-to', (tester) async {
    await tester.pumpWidget(_app(FakeApi(mode: FakeMode.empty, lang: 'en')));
    await _settle(tester);
    expect(find.byKey(const Key('food-empty')), findsOneWidget);
    final b = tester.getSize(find.byKey(const Key('food-empty-cta')));
    expect(b.height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const Key('food-empty-cta')));
    await _settle(tester);
    expect(find.byKey(const Key('food-search')), findsOneWidget);
  });

  testWidgets('feature off and offline are honest', (tester) async {
    await tester.pumpWidget(_app(_OffApi()));
    await _settle(tester);
    expect(find.text('This feature is not available yet.'), findsOneWidget);
    await tester.pumpWidget(_app(FakeApi(mode: FakeMode.fail, lang: 'en')));
    await _settle(tester);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('Bangla digits, 200% text and dark mode do not overflow', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        _app(FakeApi(lang: 'bn'), lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('১৮০০ ক্যালরির মধ্যে ৪০২'), findsOneWidget);
    expect(find.textContaining('402'), findsNothing);
  });
}
