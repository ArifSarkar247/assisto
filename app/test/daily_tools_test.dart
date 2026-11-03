// p2tools — Daily tools (flag daily_tools): engine maths with real reference
// values + widget flows (search, favourites kept, Bangla digits, honest
// "type the price/rate first" states, indicative rate fill).
import 'dart:convert';
import 'dart:math' as math;

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/daily_tools_pages.dart';
import 'package:assisto/screens/daily_tools_screen.dart';
import 'package:assisto/services/bangla_calendar.dart';
import 'package:assisto/widgets/daily_tools_engine.dart';
import 'package:assisto/world/world_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeWorld implements WorldApi {
  _FakeWorld(this.answer);
  final Map<String, dynamic> answer;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> today() async {
    calls++;
    return answer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(String lang, Widget home) => MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  group('engine', () {
    test('parseNum reads Bangla digits, commas and the taka sign', () {
      expect(parseNum('১,২৩,৪৫৬.৫'), 123456.5);
      expect(parseNum(' 1,500 '), 1500);
      expect(parseNum('৳ 250'), 250);
      expect(parseNum('abc'), isNull);
      expect(parseNum(''), isNull);
    });

    test('fmtNum uses lakh/crore grouping', () {
      expect(fmtNum(12345678.5), '1,23,45,678.5');
      expect(fmtNum(100), '100');
      expect(fmtNum(100000), '1,00,000');
      expect(fmtNum(-1500), '-1,500');
      expect(fmtNum(8884.88), '8,884.88');
    });

    test('BD land units (standard measure)', () {
      expect(convertUnit('land', 'bigha', 'katha', 1), closeTo(20, 1e-9));
      expect(convertUnit('land', 'bigha', 'decimal', 1), closeTo(33.0579, 1e-3));
      expect(convertUnit('land', 'katha', 'sqft', 1), closeTo(720, 1e-9));
      expect(convertUnit('land', 'katha', 'decimal', 1), closeTo(1.6529, 1e-3));
      expect(convertUnit('land', 'decimal', 'acre', 100), closeTo(1, 1e-9));
      expect(convertUnit('land', 'acre', 'hectare', 1), closeTo(0.404686, 1e-5));
    });

    test('BD weight units (bhori / tola, seer, maund)', () {
      expect(convertUnit('weight', 'bhori', 'gram', 10), closeTo(116.64, 1e-9));
      expect(convertUnit('weight', 'bhori', 'ana', 1), closeTo(16, 1e-9));
      expect(convertUnit('weight', 'bhori', 'rati', 1), closeTo(96, 1e-9));
      expect(convertUnit('weight', 'seer', 'bhori', 1), closeTo(80, 1e-9));
      expect(convertUnit('weight', 'maund', 'seer', 1), closeTo(40, 1e-9));
      expect(convertUnit('weight', 'maund', 'kg', 1), closeTo(37.3248, 1e-9));
    });

    test('length / temperature / unknown unit', () {
      expect(convertUnit('length', 'hath', 'inch', 1), closeTo(18, 1e-9));
      expect(convertUnit('length', 'mile', 'km', 1), closeTo(1.609344, 1e-9));
      expect(convertUnit('temp', 'c', 'f', 100), closeTo(212, 1e-9));
      expect(convertUnit('temp', 'f', 'c', -40), closeTo(-40, 1e-9));
      expect(convertUnit('temp', 'k', 'c', 0), closeTo(-273.15, 1e-9));
      expect(convertUnit('land', 'bigha', 'nope', 1), isNull);
      expect(convertAll('land', 'bigha', 1).length, kUnitCats['land']!.length);
    });

    test('currency uses only the given rate', () {
      expect(fxConvert(100, 122.5), 12250);
      expect(fxConvert(12250, 122.5, toBdt: false), 100);
      expect(fxConvert(100, 0), 0);
    });

    test('age: exact y/m/d, leap-day birthday, future birth', () {
      final a = ageOn(DateTime(2000, 2, 29), DateTime(2026, 11, 3))!;
      expect([a.years, a.months, a.days], [26, 8, 5]);
      expect(a.nextBirthdayIn, 117); // 28 Feb 2027 (not a leap year)
      expect(ageOn(DateTime(1990, 11, 3), DateTime(2026, 11, 3))!.nextBirthdayIn, 0);
      expect(ageOn(DateTime(2027, 1, 1), DateTime(2026, 11, 3)), isNull);
    });

    test('EMI: flat vs reducing on 1 lakh, 12%, 12 months', () {
      final c = emiCompare(100000, 12, 12);
      expect(c.reducing.emi, 8884.88);
      expect(c.flat.emi, 9333.33);
      expect(c.flatExtra, greaterThan(5000));
      expect(c.flatEffectiveRate, closeTo(21.46, 0.02));
    });

    test('zakat: never "due" without a nisab price', () {
      final none = zakatCalc(basis: 'silver', cash: 500000);
      expect(none.priceMissing, isTrue);
      expect(none.due, 0);
      expect(none.aboveNisab, isFalse);
      final z = zakatCalc(basis: 'silver', silverPricePerBhori: 2500, cash: 200000);
      expect(z.nisabValue, 131250);
      expect(z.aboveNisab, isTrue);
      expect(z.due, 5000);
      final below = zakatCalc(basis: 'gold', goldPricePerBhori: 200000, cash: 200000);
      expect(below.aboveNisab, isFalse);
      expect(below.due, 0);
      final g = zakatCalc(
          basis: 'silver', silverPricePerBhori: 2500, goldPricePerBhori: 200000,
          goldBhori: 2, cash: 100000, debts: 50000);
      expect(g.wealth, 450000);
      expect(g.due, 11250);
    });

    test('VAT, discount, percent', () {
      final a = vatAdd(1000, 15);
      expect([a.vat, a.total], [150, 1150]);
      final o = vatExtract(1150, 15);
      expect([o.base, o.vat], [1000, 150]);
      expect(discount(2000, 25), (500.0, 1500.0));
      expect(percentOf(25, 200), 12.5);
      expect(percentOf(1, 0), isNull);
      expect(percentChange(80, 100), 25);
    });

    test('split bill with tip and whole-taka rounding', () {
      final s = splitBill(1000, 3, tipPct: 10)!;
      expect(s.total, 1100);
      expect(s.perPerson, 366.67);
      expect(s.perPersonRounded, 367);
      expect(s.roundingExtra, 1);
      expect(splitBill(100, 0), isNull);
    });

    test('BMI uses Asian cut-offs', () {
      final b = bmiCalc(70, 170)!;
      expect(b.bmi, 24.2);
      expect(b.band, 'over'); // WHO global would say "normal"
      expect(bmiCalc(55, 170)!.band, 'normal');
      expect(feetInchToCm(5, 7), closeTo(170.18, 1e-9));
    });

    test('Hijri (tabular) and back', () {
      final h = HijriDate.of(DateTime(2026, 2, 18));
      expect([h.year, h.month, h.day], [1447, 9, 1]);
      expect(h.toGregorian(), DateTime.utc(2026, 2, 18));
      for (var d = DateTime.utc(2026, 1, 1); d.year == 2026; d = d.add(const Duration(days: 1))) {
        final x = HijriDate.of(d);
        expect(x.toGregorian(), d);
        expect(x.day, lessThanOrEqualTo(HijriDate.monthLength(x.year, x.month)));
      }
    });

    test('Bangabda -> Gregorian matches the national days and round-trips', () {
      expect(bangabdaToGregorian(1433, 9, 1), DateTime.utc(2026, 12, 16)); // 1 Poush
      expect(bangabdaToGregorian(1433, 11, 8), DateTime.utc(2027, 2, 21)); // 8 Falgun
      expect(bangabdaToGregorian(1433, 1, 1), DateTime.utc(2026, 4, 14));
      expect(bangabdaToGregorian(1433, 11, 30), isNull); // Falgun 29 (2027 not leap)
      expect(bangabdaToGregorian(1433, 13, 1), isNull);
      for (var d = DateTime.utc(2026, 1, 1); d.year == 2026; d = d.add(const Duration(days: 1))) {
        final b = BanglaDate.of(d);
        expect(bangabdaToGregorian(b.year, b.month, b.day), d);
      }
    });

    test('word counter understands Bangla', () {
      final s = wordStats('আমি ভাত খাই। I eat rice.');
      expect(s.words, 6);
      expect(s.banglaWords, 3);
      expect(s.englishWords, 3);
      expect(s.sentences, 2);
      expect(wordStats('   ').words, 0);
    });

    test('dice / lottery', () {
      final rng = math.Random(7);
      final d = rollDice(3, rng);
      expect(d.length, 3);
      expect(d.every((x) => x >= 1 && x <= 6), isTrue);
      expect(pickNumbers(1, 5, 5, rng), [1, 2, 3, 4, 5]);
      expect(pickNumbers(1, 3, 5, rng), isNull);
      expect(pickNumbers(10, 1, 1, rng), isNull);
    });

    test('recents keep the newest 6, no duplicates', () {
      var r = <String>[];
      for (final id in ['a', 'b', 'c', 'a', 'd', 'e', 'f', 'g']) {
        r = DailyToolsStore.pushRecent(r, id);
      }
      expect(r, ['g', 'f', 'e', 'd', 'a', 'c']);
    });
  });

  group('search', () {
    test('Bangla and English words find the right tool', () async {
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(dailyToolMatches(bn, 'land', 'বিঘা'), isTrue); // bigha
      expect(dailyToolMatches(bn, 'emi', 'emi'), isTrue); // English word in bn UI
      expect(dailyToolMatches(en, 'weight', 'bhori'), isTrue);
      expect(dailyToolMatches(en, 'zakat', 'nisab'), isTrue);
      expect(dailyToolMatches(en, 'zakat', 'bigha'), isFalse);
      for (final id in kDailyTools) {
        expect(dailyToolTitle(bn, id), isNot(dailyToolTitle(en, id)), reason: id);
      }
    });
  });

  group('widgets', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('hub: favourite is kept on the phone and shown on top', (tester) async {
      await tester.pumpWidget(_app('en', const DailyToolsScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Tap the star on any tool to keep it here at the top.'), findsOneWidget);
      await tester.tap(find.byTooltip('Add to favourites').first);
      await tester.pumpAndSettle();
      final p = await SharedPreferences.getInstance();
      final saved = jsonDecode(p.getString(DailyToolsStore.key)!) as Map;
      expect(saved['fav'], ['land']);
      expect(find.byTooltip('Remove from favourites'), findsOneWidget);
    });

    testWidgets('hub: search with no match offers "Show all tools"', (tester) async {
      await tester.pumpWidget(_app('en', const DailyToolsScreen(debugFavs: [])));
      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump();
      expect(find.text('Show all tools'), findsOneWidget);
      await tester.tap(find.text('Show all tools'));
      await tester.pump();
      expect(find.text('Land measure'), findsOneWidget);
    });

    testWidgets('land page in Bangla: 1 bigha = 20 katha in Bangla digits', (tester) async {
      await tester.pumpWidget(_app('bn', const DailyToolPage(tool: 'land')));
      await tester.pumpAndSettle();
      expect(find.text('২০'), findsOneWidget); // 20
      expect(find.text('১৪,৪০০'), findsOneWidget); // 14,400 sq ft
    });

    testWidgets('EMI shows both rates and the flat penalty', (tester) async {
      await tester.pumpWidget(_app('en', const DailyToolPage(tool: 'emi')));
      await tester.pumpAndSettle();
      expect(find.text('Type the loan amount, rate and months to compare.'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '100000');
      await tester.enterText(fields.at(1), '12');
      await tester.pump();
      expect(find.text('৳ 8,884.88'), findsOneWidget);
      expect(find.text('৳ 9,333.33'), findsOneWidget);
    });

    testWidgets('zakat asks for the price before saying anything is due', (tester) async {
      await tester.pumpWidget(_app('en', const DailyToolPage(tool: 'zakat')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Type today\'s silver price first'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '2500'); // silver per bhori
      await tester.enterText(fields.at(2), '200000'); // cash
      await tester.pump();
      expect(find.text('৳ 5,000'), findsOneWidget);
    });

    testWidgets('currency: indicative rate filled with its source note', (tester) async {
      final world = _FakeWorld({
        'cards': {
          'currency': {
            'rows': [
              {'code': 'USD', 'name': 'US dollar', 'bdt': 122.5},
            ],
            'updated': '2026-11-03',
          },
        },
      });
      await tester.pumpWidget(_app('en', DailyToolPage(tool: 'currency', worldApi: world, debugNow: DateTime(2026, 11, 3))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Type the rate first'), findsOneWidget);
      await tester.ensureVisible(find.text('Use today\'s indicative rate'));
      await tester.tap(find.text('Use today\'s indicative rate'));
      await tester.pumpAndSettle();
      expect(world.calls, 1);
      expect(find.text('৳ 12,250'), findsOneWidget);
      expect(find.textContaining('not Bangladesh Bank'), findsOneWidget);
    });

    testWidgets('currency: no feed -> honest message, nothing invented', (tester) async {
      final world = _FakeWorld({'cards': {}});
      await tester.pumpWidget(_app('en', DailyToolPage(tool: 'currency', worldApi: world, debugNow: DateTime(2026, 11, 3))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use today\'s indicative rate'));
      await tester.tap(find.text('Use today\'s indicative rate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not available right now'), findsOneWidget);
      expect(find.textContaining('Type the rate first'), findsOneWidget);
    });

    testWidgets('date page in Bangla: 16 Dec = 1 Poush 1433, Hijri labelled approximate', (tester) async {
      await tester.pumpWidget(_app('bn', DailyToolPage(tool: 'date', debugNow: DateTime(2026, 12, 16))));
      await tester.pumpAndSettle();
      expect(find.text(BanglaDate.of(DateTime(2026, 12, 16)).format(bn: true)), findsOneWidget);
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.text(bn.dtHijriApprox), findsOneWidget);
    });
  });
}
