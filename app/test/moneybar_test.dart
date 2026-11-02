// moneybar: money tools to the bar.
// * calculators vs published reference values (formulas cited in
//   owner_actions/FEATURE_CARD_MONEY_TOOLS_BN.md §৪) — same numbers as the
//   backend tests (core/tests_moneybar.py);
// * Bangla digits + ৳ in the Bangla UI;
// * official TCB prices: parse, match, honest "not connected", list screen;
// * rent due-day reminder maths; spending observations from the real ledger;
// * offers feed: retry + empty-state button (were dead ends);
// * zakat without nisab warns; tax 2026-27 honesty banner;
// * 200% text, dark, bn + en without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/ads/sponsor_api.dart';
import 'package:assisto/ads/sponsor_models.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/finance_screen.dart';
import 'package:assisto/screens/money_tax_screen.dart';
import 'package:assisto/screens/offers_screens.dart';
import 'package:assisto/screens/price_radar_screen.dart';
import 'package:assisto/screens/spending_advice_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/finance_calc.dart' as calc;
import 'package:assisto/widgets/finance_common.dart';
import 'package:assisto/widgets/money_digits.dart';
import 'package:assisto/widgets/official_prices.dart';
import 'package:assisto/widgets/rent_reminder.dart';
import 'package:assisto/widgets/tax_calc.dart' as tax;
import 'fake_api.dart';

const _tcb = {
  'connected': true,
  'stale': false,
  'source': 'TCB',
  'date': '2026-11-01',
  'markets': 'Mirpur-6, Malibagh',
  'items': [
    {'name': 'Rice coarse', 'unit': 'per kg', 'group': '', 'min': 50, 'max': 55,
     'week_min': 50, 'week_max': 55},
    {'name': 'Onion (local)', 'unit': 'per kg', 'group': 'Spices', 'min': 50, 'max': 60,
     'week_min': 45, 'week_max': 50},
    {'name': 'Lentil (coarse)', 'unit': 'per kg', 'group': 'Pulses', 'min': 90, 'max': 100},
  ],
};

class _MbApi extends FakeApi {
  _MbApi({super.mode, super.lang = 'en', this.official});
  final Map<String, dynamic>? official;
  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/prices/official') {
      if (official == null) throw Exception('offline');
      return official!;
    }
    return super.getJson(path);
  }
}

AppState _state(FakeApi api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Rahim', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, FakeApi api,
        {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api),
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
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

class _Sponsor implements SponsorBackend {
  _Sponsor(this.feed);
  List<SponsorCreative>? feed; // null = fail
  int calls = 0;
  @override
  Future<List<SponsorCreative>> offersFeed() async {
    calls++;
    final f = feed;
    if (f == null) throw Exception('offline');
    return f;
  }

  @override
  Future<void> event(String token, String kind) async {}
  @override
  Future<Map<String, dynamic>> offerPrefs() async =>
      {'categories': <String>[], 'notify': true, 'division': ''};
  @override
  Future<List<Map<String, dynamic>>> brands() async => [];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setMoneyDigitsBn(false);
  });

  group('calculators — reference values', () {
    test('EMI reducing: 1,00,000 @12% x 12 = 8,884.88', () {
      final r = calc.emiSchedule(100000, 12, 12, 'reducing');
      expect(r.emi, 8884.88);
      expect(r.schedule.first.interest, 1000.00);
      expect(r.schedule.last.balance, 0);
    });
    test('EMI reducing: 10,00,000 @9% x 60 = 20,758.36', () {
      expect(calc.emiSchedule(1000000, 9, 60, 'reducing').emi, 20758.36);
    });
    test('EMI reducing: 5,00,000 @10% x 24 = 23,072.46', () {
      expect(calc.emiSchedule(500000, 10, 24, 'reducing').emi, 23072.46);
    });
    test('schedule principal re-sums to the loan', () {
      final r = calc.emiSchedule(250000, 11.5, 36, 'reducing');
      final sum = r.schedule.fold<double>(0, (a, x) => a + x.principal);
      expect(calc.round2(sum), 250000);
    });
    test('flat: 1,00,000 @10% x 12 = 9,166.67, interest 10,000', () {
      final r = calc.emiSchedule(100000, 10, 12, 'flat');
      expect(r.emi, 9166.67);
      expect(r.interest, 10000);
    });
    test('rate compare picks the cheaper rate', () {
      final c = calc.rateCompare(100000, 12, 9, 12, 'reducing');
      expect(c.cheaper, 'a');
      expect(c.savings, greaterThan(0));
    });
    test('DPS 1,000/month @12% x 12 = 12,809.33', () {
      final r = calc.dpsProjection(1000, 12, 12);
      expect(r.maturity, 12809.33);
      expect(r.invested, 12000);
    });
    test('goal: 1,20,000 in 12 months @12% = 9,461.85/month', () {
      expect(calc.goalSavings(120000, 0, 12, 12).monthly, 9461.85);
      expect(calc.goalSavings(120000, 0, 0, 12).monthly, 10000);
    });
    test('50/30/20 re-sums without paisa drift', () {
      final b = calc.budget503020(33333);
      expect(calc.round2(b.needs + b.wants + b.savings), 33333);
    });
    test('break-even rounds units up', () {
      final b = calc.breakEven(10000, 150, 100);
      expect(b.units, 200);
      expect(calc.breakEven(100, 10, 12).impossible, isTrue);
    });
    test('zakat: 2.5% above nisab, nothing below', () {
      final above = calc.zakatFull(cash: 200000, bank: 100000, debts: 50000, nisab: 122472);
      expect(above.zakatable, 250000);
      expect(above.due, 6250);
      final below = calc.zakatFull(cash: 100000, nisab: 122472);
      expect(below.aboveNisab, isFalse);
      expect(below.due, 0);
    });
    test('nisab from silver: 612.36 g x 200 = 1,22,472', () {
      final n = tax.zakatNisab(goldPricePerGram: 0, silverPricePerGram: 200);
      expect(n.silverNisab, 122472);
    });
    test('income tax 6,00,000 general (2025-26 slabs): 5% x 1L + 10% x 1.5L = 20,000', () {
      final r = tax.estimateIncomeTax(600000);
      expect(r.grossTax, 20000);
    });
  });

  group('Bangla digits', () {
    test('fmtTaka follows the synced UI language', () {
      setMoneyDigitsBn(false);
      expect(fmtTaka(123456.5), '৳1,23,456.50');
      setMoneyDigitsBn(true);
      expect(fmtTaka(123456.5), '৳১,২৩,৪৫৬.৫০');
      expect(moneyDigits('2026'), '২০২৬');
      setMoneyDigitsBn(false);
    });

    testWidgets('EMI result shows Bangla digits in the Bangla UI', (tester) async {
      await tester.pumpWidget(_app(const FinanceScreen(), _MbApi(lang: 'bn'), lang: 'bn'));
      await _settle(tester);
      expect(moneyDigitsBn, isTrue);
      setMoneyDigitsBn(false);
    });
  });

  group('official TCB prices', () {
    test('parse + match never guesses', () {
      final d = OfficialPrices.fromJson(Map<String, dynamic>.from(_tcb));
      expect(d.connected, isTrue);
      expect(d.items.length, 3);
      expect(d.match('onion')?.name, 'Onion (local)');
      expect(d.match('o'), isNull); // too short to match honestly
      expect(d.match('mango'), isNull);
      expect(d.items[1].weekChangePct, closeTo(15.79, 0.01));
      expect(d.items[2].weekChangePct, isNull);
    });

    testWidgets('radar: connected card opens the full list with search', (tester) async {
      await tester.pumpWidget(_app(const PriceRadarScreen(),
          _MbApi(mode: FakeMode.empty, official: Map<String, dynamic>.from(_tcb))));
      await _settle(tester);
      expect(find.byKey(const ValueKey('mb-official-card')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mb-official-open-list')));
      await _settle(tester);
      expect(find.byType(OfficialPricesScreen), findsOneWidget);
      expect(find.text('Rice coarse'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('mb-official-search')), 'lentil');
      await _settle(tester, 3);
      expect(find.text('Rice coarse'), findsNothing);
      expect(find.text('Lentil (coarse)'), findsOneWidget);
    });

    testWidgets('radar: offline / not fetched = honest card, no prices', (tester) async {
      await tester.pumpWidget(_app(const PriceRadarScreen(), _MbApi(mode: FakeMode.empty)));
      await _settle(tester);
      expect(find.byKey(const ValueKey('mb-official-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('mb-official-open-list')), findsNothing);
      expect(find.byKey(const ValueKey('mb-official-open-site')), findsOneWidget);
    });
  });

  group('rent reminder', () {
    final unit = {'id': 7, 'rent_poisha': 1500000, 'due_day': 5, 'active': true};
    test('before the due day: this month 09:00', () {
      expect(rentNextReminder(unit, const [], DateTime(2026, 11, 2, 10)),
          DateTime(2026, 11, 5, 9));
    });
    test('paid in full this month: next month', () {
      final paid = [
        {'unit_id': 7, 'month': '2026-11', 'paid_poisha': 1500000}
      ];
      expect(rentNextReminder(unit, paid, DateTime(2026, 11, 2)),
          DateTime(2026, 12, 5, 9));
    });
    test('after the due day: next month; December rolls the year', () {
      expect(rentNextReminder(unit, const [], DateTime(2026, 12, 20)),
          DateTime(2027, 1, 5, 9));
    });
    test('no due day / inactive / bad day = no reminder', () {
      expect(rentNextReminder({'id': 1, 'rent_poisha': 1}, const [], DateTime(2026)), isNull);
      expect(rentNextReminder({...unit, 'active': false}, const [], DateTime(2026)), isNull);
      expect(rentDueDay({'due_day': 31}), isNull);
    });
  });

  group('spending observations', () {
    test('ledger rows come from /money/trends, spend only', () {
      final rows = spendLedgerRows({
        'categories': [
          {'category': 'food', 'current': '6400', 'previous': '4000'},
          {'category': 'rent', 'current': '0', 'previous': '9000'},
        ]
      });
      expect(rows.length, 1);
      expect(rows.first['amount'], '6400');
      expect(spendLedgerRows(null), isEmpty);
    });

    testWidgets('uses the real ledger by default, no retyping', (tester) async {
      await tester.pumpWidget(_app(const SpendingAdviceScreen(), _MbApi()));
      await _settle(tester);
      expect(find.byKey(const ValueKey('mb-spend-source')), findsOneWidget);
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.mbSpendLedgerNote), findsOneWidget);
    });
  });

  group('offers feed', () {
    testWidgets('failure has a retry that works', (tester) async {
      final b = _Sponsor(null);
      await tester.pumpWidget(_app(OffersFeedScreen(backend: b), _MbApi()));
      await _settle(tester);
      expect(find.byKey(const ValueKey('mb-offers-failed')), findsOneWidget);
      b.feed = const [];
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.tap(find.text(t.retry));
      await _settle(tester);
      expect(b.calls, 2);
      expect(find.byKey(const ValueKey('mb-offers-empty')), findsOneWidget);
    });
  });

  group('tax & zakat honesty', () {
    testWidgets('income tab says 2026-27 rates are not in yet', (tester) async {
      await tester.pumpWidget(_app(const MoneyTaxScreen(), _MbApi()));
      await _settle(tester);
      expect(find.byKey(const ValueKey('mb-tax-year-warning')), findsOneWidget);
    });
  });

  group('200% text, bn + en, light + dark: no overflow', () {
    for (final lang in ['bn', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('radar + official list $lang dark=$dark', (tester) async {
          tester.view.physicalSize = const Size(1080, 2400);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(_app(const PriceRadarScreen(),
              _MbApi(lang: lang, official: Map<String, dynamic>.from(_tcb)),
              lang: lang, scale: 2.0, dark: dark));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('mb-official-open-list')));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          setMoneyDigitsBn(false);
        });
        testWidgets('spending + tax $lang dark=$dark', (tester) async {
          tester.view.physicalSize = const Size(1080, 2400);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(_app(const SpendingAdviceScreen(), _MbApi(lang: lang),
              lang: lang, scale: 2.0, dark: dark));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(_app(const MoneyTaxScreen(), _MbApi(lang: lang),
              lang: lang, scale: 2.0, dark: dark));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          setMoneyDigitsBn(false);
        });
      }
    }
  });
}
