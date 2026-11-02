// remhbud (board group 13): Budget + Remittance to the launch bar.
//  * strict bn/en: Bangla digits in every amount / percent, category KEYS
//    ('food', a typed 'Food', 'uncategorized') shown in the UI language,
//    month chips as "October 2026" not "2026-10";
//  * Asia/Dhaka month boundaries (fixed clocks only — never DateTime.now());
//  * Bangla-keyboard digits understood and sent to the server as ASCII;
//  * the budget sheet: one-tap categories from the user's own expenses, Save
//    says what is missing (was a silent dead button);
//  * the 50-30-20 sheet: no dead "Apply" — an honest guide with Close;
//  * no savings goal -> a real button (was a dead end);
//  * Remittance: empty month = benefit + big button + how-to (no second FAB),
//    who sent how much this month / this year with % that add up to 100,
//    the honest conversion line (the rate the user typed, never a live rate),
//    My Circle chips for "who usually sends";
//  * every new gallery state at 200% text, bn + en, light + dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/money_budget_screen.dart';
import 'package:assisto/screens/money_common.dart';
import 'package:assisto/screens/remittance/remit_entry_screen.dart';
import 'package:assisto/screens/remittance/remit_parser.dart';
import 'package:assisto/screens/remittance/remit_source.dart';
import 'package:assisto/screens/remittance/remittance_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/budget_card.dart';
import 'package:assisto/widgets/budget_insights.dart';
import 'package:assisto/widgets/budget_sheets.dart';
import 'budrem_fakes.dart';
import 'fake_api.dart';
import 'remhbud_shots.dart';

AppState _state(String lang, FakeMode mode) {
  final s = AppState();
  s.api = FakeApi(mode: mode, lang: lang);
  s.user = AppUser(id: 1, name: 'Rahim', phone: '01712345678', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(Widget home,
        {String lang = 'en', double scale = 1.0, bool dark = false, FakeMode mode = FakeMode.data}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(lang, mode),
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
        builder: (ctx, child) =>
            MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

/// A page with one button that runs [open] (to test a sheet on its own).
Widget _launcher(Future<void> Function(BuildContext) open) => Scaffold(
      body: Builder(
        builder: (c) => Center(
          child: ElevatedButton(key: const ValueKey('open'), onPressed: () => open(c), child: const Text('open')),
        ),
      ),
    );

late AppLocalizations en;
late AppLocalizations bn;
final _now = DateTime(2026, 10, 20);

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('helpers', () {
    test('Bangla digits in taka and percent; English untouched', () {
      expect(moneyLangDigits('bn', tkFmt(123456)), '৳১,২৩,৪৫৬');
      expect(moneyLangDigits('en', tkFmt(123456)), '৳1,23,456');
      expect(moneyLangDigits('bn', '85%'), '৮৫%');
    });
    test('Bangla-keyboard amounts are understood and become ASCII', () {
      expect(moneyAscii('৫,০০০.৫০'), '5000.50');
      expect(moneyParse('৩২.৫'), 32.5);
      expect(moneyParse(''), 0);
      expect(rmAscii('১৬,২৫০'), '16250');
      expect(rmNum('১৬,২৫০'), 16250);
      expect(rmNum('16,250.75'), 16250.75);
    });
    test('Asia/Dhaka month boundary: 19:00 UTC on 31 Oct is already November in Dhaka', () {
      final d = dhakaNow(DateTime.utc(2026, 10, 31, 19));
      expect(d, DateTime(2026, 11, 1, 1));
      expect(moneyMonthKey(d), '2026-11');
      expect(rmMonthKey(rmDhakaNow(DateTime.utc(2026, 10, 31, 17, 59))), '2026-10');
      expect(rmMonthKey(rmDhakaNow(DateTime.utc(2026, 10, 31, 18))), '2026-11');
      expect(rmMonthKey(rmDhakaNow(DateTime.utc(2026, 12, 31, 18, 30))), '2027-01');
    });
    test('category keys (any case) and the no-category bucket show in the UI language', () {
      expect(moneyCatLabel(bn, 'food'), bn.rmtCatFood);
      expect(moneyCatLabel(bn, 'Food'), bn.rmtCatFood);
      expect(moneyCatLabel(bn, ' RENT '), bn.rmtCatRent);
      expect(moneyCatLabel(bn, 'uncategorized'), bn.rmtCatOther);
      expect(moneyCatLabel(en, 'health'), en.rmtCatMedicine);
      expect(moneyCatLabel(bn, 'Transport'), 'Transport'); // typed by the user: as typed
    });
    test('category chips: the user\'s own expense categories first, then family keys, no duplicates', () {
      final txns = [
        {'data': {'kind': 'expense', 'category': 'Transport'}},
        {'data': {'kind': 'expense', 'category': 'Transport'}},
        {'data': {'kind': 'expense', 'category': 'Food'}},
        {'data': {'kind': 'income', 'category': 'Salary'}},
        {'data': {'kind': 'expense', 'category': ''}},
      ];
      expect(budgetCategoryChoices(txns, taken: ['rent']),
          ['Transport', 'Food', 'education', 'health', 'loan', 'other']);
      expect(budgetCategoryChoices(const []), kBudgetFamilyKeys);
    });
  });

  group('budget widgets', () {
    testWidgets('a budget card in Bangla: category label, Bangla percent and taka', (tester) async {
      _phone(tester);
      const line = {
        'category': 'food', 'spent': '13450.50', 'effective_limit': '12000.00', 'pct': 112, 'bar_pct': 100,
        'state': 'over', 'over_by': '1450.50', 'remaining': '-1450.50',
      };
      await tester.pumpWidget(_app(const Scaffold(body: BudgetCard(line: line)), lang: 'bn'));
      await _settle(tester, 3);
      expect(find.text(bn.rmtCatFood), findsOneWidget);
      expect(find.text('food'), findsNothing);
      expect(find.text('১১২%'), findsOneWidget);
      expect(find.text(bn.budgetSpentOf('৳১৩,৪৫০.৫', '৳১২,০০০')), findsOneWidget);
      expect(find.text(bn.budgetOverBy('৳১,৪৫০.৫')), findsOneWidget);
      // a month heading for the drill-down
      await tester.pumpWidget(_app(const Scaffold(body: BudgetCard(line: line, title: 'Oct')), lang: 'bn'));
      await _settle(tester, 3);
      expect(find.text('Oct'), findsOneWidget);
    });

    testWidgets('insights name the category in Bangla with Bangla digits', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
          const Scaffold(body: BudgetInsights(insights: [
            {'code': 'over', 'category': 'food', 'pct': 12},
          ])),
          lang: 'bn'));
      await _settle(tester, 3);
      expect(find.text(bn.budgetInsightOver(bn.rmtCatFood, '১২')), findsOneWidget);
    });

    testWidgets('no savings goal -> a real "Set a savings goal" button, not a dead end', (tester) async {
      _phone(tester);
      var taps = 0;
      await tester.pumpWidget(_app(Scaffold(body: BudgetGoalLinkCard(hasGoal: false, onCreateGoal: () => taps++))));
      await _settle(tester, 3);
      expect(find.text(en.budgetGoalLinkNone), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rhb_goal_create')));
      expect(taps, 1);
    });

    testWidgets('goal sheet: says what is missing; Bangla digits become ASCII', (tester) async {
      _phone(tester);
      GoalDraft? got;
      await tester.pumpWidget(_app(_launcher((c) async => got = await showGoalCreateSheet(c)), lang: 'bn'));
      await tester.tap(find.byKey(const ValueKey('open')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('rhb_goal_save')));
      await _settle(tester, 4);
      expect(find.text(bn.rhbErrGoalTitle), findsOneWidget);
      expect(find.text(bn.rhbErrLimit), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('rhb_goal_title')), 'ছাদ');
      await tester.enterText(find.byKey(const ValueKey('rhb_goal_target')), '১,০০,০০০');
      await tester.tap(find.byKey(const ValueKey('rhb_goal_save')));
      await _settle(tester);
      expect(got?.title, 'ছাদ');
      expect(got?.target, '100000');
    });

    testWidgets('budget sheet: Save with nothing says why; chip + Bangla digits -> the right budget', (tester) async {
      _phone(tester, height: 1200);
      BudgetInput? got;
      await tester.pumpWidget(_app(
          _launcher((c) async => got = await showBudgetSheet(c, choices: ['Transport', 'food', 'rent'])),
          lang: 'bn'));
      await tester.tap(find.byKey(const ValueKey('open')));
      await _settle(tester);
      // the family keys show in Bangla; the user's own word as typed
      expect(find.text(bn.rmtCatFood), findsOneWidget);
      expect(find.text('Transport'), findsOneWidget);
      expect(find.text('food'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('rhb_budget_save')));
      await _settle(tester, 4);
      expect(find.text(bn.rhbErrCategory), findsOneWidget);
      expect(find.text(bn.rhbErrLimit), findsOneWidget);
      expect(got, isNull); // still open, nothing saved
      await tester.tap(find.byKey(const ValueKey('rhb_cat_food')));
      await tester.enterText(find.byKey(const ValueKey('rhb_limit')), '৫,০০০');
      await tester.tap(find.byKey(const ValueKey('rhb_budget_save')));
      await _settle(tester);
      expect((got?.category, got?.monthlyLimit, got?.rollover), ('food', '5000', false));
    });

    testWidgets('budget sheet: a typed category wins over a chip', (tester) async {
      _phone(tester, height: 1200);
      BudgetInput? got;
      await tester.pumpWidget(_app(_launcher((c) async => got = await showBudgetSheet(c, choices: ['food']))));
      await tester.tap(find.byKey(const ValueKey('open')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('rhb_cat_food')));
      await tester.enterText(find.byKey(const ValueKey('rhb_cat_custom')), 'Mobile recharge');
      await tester.enterText(find.byKey(const ValueKey('rhb_limit')), '500');
      await tester.tap(find.byKey(const ValueKey('rhb_budget_save')));
      await _settle(tester);
      expect(got?.category, 'Mobile recharge');
    });

    testWidgets('50-30-20: an honest guide with Close — no dead "Apply"; Bangla digits', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(_app(
          _launcher((c) => showTemplateSheet(c, fetchTemplate: (inc) async => {
                'buckets': [
                  {'bucket': 'needs', 'percent': 50, 'amount': '25000.00'},
                  {'bucket': 'wants', 'percent': 30, 'amount': '15000.00'},
                  {'bucket': 'savings', 'percent': 20, 'amount': '10000.00'},
                ],
              })),
          lang: 'bn'));
      await tester.tap(find.byKey(const ValueKey('open')));
      await _settle(tester);
      expect(find.text(bn.budgetTemplateApply), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('rhb_tpl_income')), '৫০০০০');
      await _settle(tester);
      expect(find.text('${bn.budgetBucketNeeds} · ৫০%'), findsOneWidget);
      expect(find.text('৳২৫,০০০'), findsOneWidget);
      expect(find.text(bn.rhbTemplateHow), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rhb_tpl_close')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('rhb_tpl_income')), findsNothing);
    });

    testWidgets('50-30-20: a failed fetch says so', (tester) async {
      _phone(tester, height: 1400);
      await tester.pumpWidget(_app(_launcher((c) => showTemplateSheet(c, fetchTemplate: (_) async => throw Exception('x')))));
      await tester.tap(find.byKey(const ValueKey('open')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rhb_tpl_income')), '50000');
      await _settle(tester);
      expect(find.text(en.budgetOffline), findsOneWidget);
    });
  });

  group('budget page', () {
    testWidgets('this month in Bangla: no raw category keys, Bangla digits', (tester) async {
      _phone(tester, height: 2400);
      await tester.pumpWidget(_app(MoneyBudgetScreen(now: _now), lang: 'bn'));
      await _settle(tester, 16);
      expect(find.text(bn.rmtCatFood), findsWidgets);
      expect(find.text(bn.rmtCatRent), findsOneWidget);
      for (final raw in ['food', 'rent', 'education']) {
        expect(find.text(raw), findsNothing, reason: 'raw key "$raw" leaked');
      }
      expect(find.text('১১২%'), findsOneWidget);
      expect(find.text(bn.budgetInsightOver(bn.rmtCatFood, '১২')), findsOneWidget);
      expect(find.textContaining('৳৩২,২০০.৫'), findsOneWidget);
      expect(find.textContaining(RegExp(r'৳[0-9]')), findsNothing, reason: 'English digits in a Bangla amount');
    });

    testWidgets('history: six months back across the new year, named in the UI language', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(MoneyBudgetScreen(now: DateTime(2026, 1, 15), initialTab: 1)));
      await _settle(tester, 16);
      for (final m in ['2026-01', '2025-12', '2025-11', '2025-10', '2025-09', '2025-08']) {
        expect(find.byKey(ValueKey('rhb_month_$m')), findsOneWidget, reason: m);
      }
      expect(find.byKey(const ValueKey('rhb_month_2026-02')), findsNothing); // never the future
      expect(find.text('January 2026'), findsOneWidget);
      expect(find.text('2026-01'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('rhb_month_2025-12')));
      await _settle(tester, 8);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('rhb_month_2025-12'))).selected, isTrue);
    });

    testWidgets('history months in Bangla', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(MoneyBudgetScreen(now: _now, initialTab: 1), lang: 'bn'));
      await _settle(tester, 16);
      expect(find.text('2026-10'), findsNothing);
      expect(find.textContaining('২০২৬'), findsWidgets);
    });

    testWidgets('plan: suggestions named in Bangla, amounts in Bangla digits', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(MoneyBudgetScreen(now: _now, initialTab: 2), lang: 'bn'));
      await _settle(tester, 16);
      expect(find.text(bn.rmtCatFood), findsOneWidget);
      expect(find.text('food'), findsNothing);
      expect(find.text('৳১২,৩২০'), findsOneWidget);
    });

    testWidgets('a category drill-down: Bangla title, months as headings', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(MoneyBudgetScreen(category: 'food', now: _now), lang: 'bn'));
      await _settle(tester, 16);
      expect(find.text(bn.rmtCatFood), findsOneWidget); // app bar
      expect(find.text('2026-10'), findsNothing);
      expect(find.text('food'), findsNothing);
    });

    testWidgets('empty: benefit line + big button + how-to', (tester) async {
      _phone(tester, height: 1600);
      await tester.pumpWidget(_app(MoneyBudgetScreen(now: _now), mode: FakeMode.empty));
      await _settle(tester, 16);
      expect(find.byKey(const ValueKey('rhb_budget_empty')), findsOneWidget);
      expect(find.text(en.budgetEmptyBody), findsOneWidget);
      expect(find.text(en.rhbBudgetHow1), findsOneWidget);
      expect(find.text(en.budgetAddFirst), findsOneWidget);
    });
  });

  group('remittance', () {
    testWidgets('empty month: benefit + big button + how-to, and no second FAB', (tester) async {
      _phone(tester, height: 2000);
      await tester.pumpWidget(_app(RemittanceScreen(source: FakeRemit('empty'), guide: false, now: _now), lang: 'bn'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('rhb_month_empty')), findsOneWidget);
      expect(find.text(bn.rhbMonthBenefit), findsOneWidget);
      expect(find.text(bn.rhbMonthHow2), findsOneWidget);
      expect(find.byKey(const ValueKey('rmt_add')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('rhb_month_add')));
      await _settle(tester);
      expect(find.text(bn.rmtAddEntryTitle), findsOneWidget);
    });

    testWidgets('the FAB comes back on the other tabs of an empty month', (tester) async {
      _phone(tester, height: 2000);
      await tester.pumpWidget(_app(RemittanceScreen(source: FakeRemit('empty'), guide: false, now: _now, initialTab: 1)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('rmt_add')), findsOneWidget);
    });

    testWidgets('who sent how much this month: taka + % that add up to 100', (tester) async {
      _phone(tester, height: 2400);
      await tester.pumpWidget(_app(RemittanceScreen(source: FakeRemit('data'), guide: false, now: _now)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('rhb_shares_month')), findsOneWidget);
      expect(find.text(en.rhbWhoSentMonth), findsOneWidget);
      // Bhai ৳20,000 + Karim ৳16,250 = ৳36,250 -> 55% + 45%
      expect(find.text('55%'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
      expect(find.byKey(const ValueKey('rhb_month_empty')), findsNothing);
    });

    testWidgets('the shares in Bangla digits', (tester) async {
      _phone(tester, height: 2400);
      await tester.pumpWidget(_app(RemittanceScreen(source: FakeRemit('data'), guide: false, now: _now), lang: 'bn'));
      await _settle(tester);
      expect(find.text('৫৫%'), findsOneWidget);
      expect(find.text('৳২০,০০০'), findsWidgets);
    });

    testWidgets('the year: each sender\'s share of the year', (tester) async {
      _phone(tester, height: 3000);
      await tester.pumpWidget(_app(RemittanceScreen(source: FakeRemit('data'), guide: false, now: _now, initialTab: 2)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('rhb_shares_year')), findsOneWidget);
      expect(find.text('69%'), findsOneWidget);
      expect(find.text('31%'), findsOneWidget);
    });

    testWidgets('entry: Bangla digits, the honest conversion line, ASCII to the server', (tester) async {
      _phone(tester, height: 2400);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(
          RemitEntryScreen(
              source: f,
              queue: RemitQueue(f),
              draft: const RemitDraft(currency: 'SAR'),
              members: const [
                {'id': 7, 'name': 'Karim', 'relation': 'brother'},
              ],
              now: _now),
          lang: 'bn'));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rmt_amount')), '৫০০');
      await tester.enterText(find.byKey(const ValueKey('rmt_rate')), '৩২.৫');
      await _settle(tester, 4);
      final conv = find.byKey(const ValueKey('rhb_conv'));
      expect(conv, findsOneWidget);
      expect(find.descendant(of: conv, matching: find.textContaining('৳১৬,২৫০')), findsOneWidget);
      expect(find.descendant(of: conv, matching: find.textContaining('৩২.৫')), findsOneWidget);
      expect(find.text(bn.rhbConvHonest), findsOneWidget);
      // the honest wording: never a live / official rate claim
      expect(bn.rhbConvHonest.contains('লাইভ'), isTrue); // says we DON'T fetch one
      expect(en.rmtFieldRate, 'Rate you got');
      await tester.tap(find.text('Karim'));
      await tester.ensureVisible(find.byKey(const ValueKey('rmt_save')));
      await tester.tap(find.byKey(const ValueKey('rmt_save')));
      await _settle(tester);
      final body = f.created.last;
      expect((body['amount'], body['rate'], body['taka'], body['currency']), ('500', '32.5', '16250', 'SAR'));
      expect(body['received_on'], '2026-10-20');
    });

    testWidgets('entry: a different taka amount is kept and said so', (tester) async {
      _phone(tester, height: 2400);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(
          RemitEntryScreen(source: f, queue: RemitQueue(f), draft: const RemitDraft(currency: 'SAR'), members: const [], now: _now)));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rmt_amount')), '500');
      await tester.enterText(find.byKey(const ValueKey('rmt_rate')), '32.5');
      await tester.enterText(find.byKey(const ValueKey('rmt_taka')), '16000');
      await _settle(tester, 4);
      expect(find.text(en.rhbConvYours('৳16,000')), findsOneWidget);
    });

    testWidgets('expected money: "who usually sends" in one tap from My Circle', (tester) async {
      _phone(tester, height: 2000);
      final f = FakeRemit('data');
      await tester.pumpWidget(_app(RemittanceScreen(source: f, guide: false, now: _now)));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('rmt_menu')));
      await _settle(tester);
      await tester.tap(find.text(en.rmtExpectedTitle).last);
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rmt_exp_sender')), '');
      await tester.tap(find.byKey(const ValueKey('rmt_exp_m_8')));
      await _settle(tester, 4);
      await tester.ensureVisible(find.byKey(const ValueKey('rmt_sheet_save')));
      await tester.tap(find.byKey(const ValueKey('rmt_sheet_save')));
      await _settle(tester);
      expect(f.expected['sender'], 'Salma');
    });
  });

  // 200% font, bn + en, light + dark: no overflow / layout error anywhere.
  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('every new budget state at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
        _phone(tester);
        for (final e in remhbudShots.entries) {
          await tester.pumpWidget(_app(e.value.build(lang), lang: lang, scale: 2.0, dark: dark, mode: e.value.mode));
          await _settle(tester, 10);
          final err = tester.takeException();
          expect(err, isNull, reason: '${e.key} ($lang, 2.0x): $err');
        }
      });
    }
  }
}
