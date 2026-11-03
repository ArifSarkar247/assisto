// p3life (owner PART 3, 3 Nov): travel transport/documents, trip-scoped
// split, offline copy, wedding vendors/gifts/card, food diary.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/life/life_common.dart';
import 'package:assisto/screens/life/life_logic.dart';
import 'package:assisto/screens/life/life_ride.dart';
import 'package:assisto/screens/life/life_travel.dart';
import 'package:assisto/screens/life/life_wedding.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

class _Api extends ApiClient {
  _Api() {
    token = 'test-token';
  }
  final Map<String, List<Map<String, dynamic>>> rows = {};
  final created = <String, Map<String, dynamic>>{};
  final posts = <String>[];

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async =>
      [for (final r in rows[path] ?? const <Map<String, dynamic>>[]) {...r}];

  @override
  Future<Map<String, dynamic>> createItem(String path, Map<String, dynamic> body) async {
    created[path] = body;
    final r = {...body, 'id': 100 + (rows[path]?.length ?? 0)};
    rows.putIfAbsent(path, () => []).add(r);
    return r;
  }

  @override
  Future<Map<String, dynamic>> postJson(String path, [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    if (path == '/life/share') return {'url': 'https://lifeassisto.com/p/x'};
    return {'ok': true};
  }
}

Widget _app(ApiClient api, Widget home, {String lang = 'en'}) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Rina', phone: '01711000001', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: home),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    LifeCache.forceOffline = false;
  });

  group('logic', () {
    final today = DateTime(2026, 11, 3);
    test('document status vs the trip', () {
      final end = DateTime(2026, 12, 25);
      expect(docStatus({'expiry': '2026-11-01'}, tripEnd: end, today: today), 'expired');
      expect(docStatus({'expiry': '2026-12-20'}, tripEnd: end, today: today), 'before_trip');
      expect(docStatus({'kind': 'passport', 'expiry': '2027-03-01'}, tripEnd: end, today: today), 'passport_6m');
      expect(docStatus({'kind': 'passport', 'expiry': '2027-08-01'}, tripEnd: end, today: today), 'ok');
      expect(docStatus({'kind': 'nid', 'expiry': '2027-03-01'}, tripEnd: end, today: today), 'ok');
      expect(docStatus({'expiry': ''}, tripEnd: end, today: today), 'nodate');
    });

    test('money parse + format (Bangla digits, commas, poisha)', () {
      expect(parsePoisha('১,৫০০'), 150000);
      expect(parsePoisha('৳ 200.50'), 20050);
      expect(parsePoisha('abc'), isNull);
      expect(parsePoisha('-5'), isNull);
      expect(fmtTaka(15000000), '৳1,50,000');
      expect(fmtTaka(20050), '৳200.50');
      expect(fmtTaka(99900), '৳999');
    });

    test('vendor + gift totals', () {
      final v = vendorTotals([
        {'quote': 800000, 'paid': 300000},
        {'quote': 100000, 'paid': 150000}, // overpaid never makes due negative
      ]);
      expect((v.quoted, v.paid, v.due), (900000, 450000, 500000));
      final g = giftTotals([
        {'amount': 500000, 'thanked': true},
        {'amount': 0},
      ]);
      expect((g.count, g.cash, g.toThank), (2, 500000, 1));
    });

    test('food month: only this month, budget left / over, by provider', () {
      final rows = [
        {'date': '2026-11-02', 'provider': 'foodpanda', 'amount': 45000},
        {'date': '2026-11-01', 'provider': 'pathao_food', 'amount': 60000},
        {'date': '2026-10-30', 'provider': 'foodpanda', 'amount': 99999},
      ];
      final m = foodMonth(rows, '2026-11', 100000);
      expect((m.spent, m.orders, m.left), (105000, 2, -5000));
      expect(m.byProvider.first.key, 'pathao_food');
      expect(foodMonth(rows, '2026-11', null).left, isNull);
    });

    test('legs sort by date+time, undated last; unknown mode = other', () {
      final s = sortLegs([
        {'id': 1, 'date': ''},
        {'id': 2, 'date': '2026-12-02', 'time': '08:00'},
        {'id': 3, 'date': '2026-12-02', 'time': '06:00'},
      ]);
      expect(s.map((r) => r['id']), [3, 2, 1]);
      expect(normMode('rocket'), 'other');
    });

    test('split scope keeps trip rows apart from the general group', () {
      expect(inSplitScope({'name': 'a'}, null), isTrue);
      expect(inSplitScope({'name': 'a', 'scope': 'trip:1'}, null), isFalse);
      expect(inSplitScope({'scope': 'trip:1'}, tripSplitScope(1)), isTrue);
      expect(inSplitScope({'scope': 'trip:2'}, tripSplitScope(1)), isFalse);
    });

    test('official sources are https government / national-carrier sites', () {
      for (final m in kLegModes) {
        final s = officialForMode(m);
        if (s == null) continue;
        expect(s.url, startsWith('https://'));
      }
      expect(officialForMode('train')!.url, contains('railway.gov.bd'));
      expect(officialForMode('car'), isNull);
      for (final s in kTourismSources) {
        expect(Uri.parse(s.url).host, endsWith('.gov.bd'));
      }
    });
  });

  group('widgets', () {
    testWidgets('transport tab: train leg has Track + official site; trip filter',
        (tester) async {
      final api = _Api()
        ..rows['travel/legs'] = [
          {'id': 1, 'trip_id': 7, 'mode': 'train', 'from': 'Dhaka', 'to': 'Sylhet', 'date': '2026-12-01'},
          {'id': 2, 'trip_id': 8, 'mode': 'bus', 'from': 'OTHERTRIP'},
        ];
      await tester.pumpWidget(_app(api, const TravelLegsTab(tripId: 7)));
      await tester.pumpAndSettle();
      expect(find.text('Dhaka → Sylhet'), findsOneWidget);
      expect(find.textContaining('OTHERTRIP'), findsNothing);
      expect(find.byKey(const ValueKey('life-leg-track')), findsOneWidget);
      expect(find.byKey(const ValueKey('life-leg-official-railway')), findsOneWidget);
    });

    testWidgets('empty tab: benefit + big button + how-to; add stamps trip_id',
        (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(api, const TravelLegsTab(tripId: 7)));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p3lLegsEmptyBody), findsOneWidget);
      expect(find.text(t.p3lLegsHowTo), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('life-empty-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('life-field-from')), 'Sadarghat');
      await tester.tap(find.byKey(const ValueKey('life-choice-mode-launch')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('life-form-save')));
      await tester.tap(find.byKey(const ValueKey('life-form-save')));
      await tester.pumpAndSettle();
      expect(api.created['travel/legs']!['trip_id'], 7);
      expect(api.created['travel/legs']!['mode'], 'launch');
      expect(find.text('Sadarghat'), findsOneWidget);
    });

    testWidgets('required field blocks save with an honest message', (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(api, const TravelLegsTab(tripId: 7)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('life-empty-add')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('life-form-save')));
      await tester.tap(find.byKey(const ValueKey('life-form-save')));
      await tester.pumpAndSettle();
      expect(api.created, isEmpty);
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p3lRequired(t.p3lLegFrom)), findsOneWidget);
    });

    testWidgets('offline: the saved copy is shown with the banner', (tester) async {
      final api = _Api()
        ..rows['wedding/vendors'] = [
          {'id': 1, 'name': 'Decor', 'service': 'decor', 'quote': 800000, 'paid': 300000},
        ];
      await tester.pumpWidget(_app(api, const WeddingVendorsTab()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('life-offline')), findsNothing);
      LifeCache.forceOffline = true;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(api, const WeddingVendorsTab()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('life-offline')), findsOneWidget);
      expect(find.textContaining('Decor'), findsOneWidget);
      expect(find.textContaining('৳5,000'), findsWidgets); // due
    });

    testWidgets('offline with no saved copy = honest error, never invented',
        (tester) async {
      LifeCache.forceOffline = true;
      await tester.pumpWidget(_app(_Api(), const WeddingGiftsTab()));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    });

    testWidgets('documents: passport too close to trip end warns', (tester) async {
      final now = DateTime.now();
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final api = _Api()
        ..rows['travel/docs'] = [
          {'id': 1, 'trip_id': 3, 'kind': 'passport', 'expiry': iso(now.add(const Duration(days: 60)))},
        ];
      await tester.pumpWidget(_app(api,
          TravelDocsTab(tripId: 3, tripEnd: iso(now.add(const Duration(days: 30))))));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.textContaining(t.p3lDocSixMonths), findsOneWidget);
    });

    testWidgets('food diary: month total vs budget', (tester) async {
      final now = DateTime.now();
      final m = monthKey(now);
      SharedPreferences.setMockInitialValues({'food_budget_poisha_v1': '300000'});
      Settings.resetForTest();
      final api = _Api()
        ..rows['food/orders'] = [
          {'id': 1, 'date': '$m-01', 'provider': 'foodpanda', 'amount': 45000},
        ];
      await tester.pumpWidget(_app(api, const FoodLogScreen()));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p3lFoodLeft('৳2,550', '৳3,000')), findsOneWidget);
    });

    testWidgets('invitation card renders every design at 200% text', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      for (final d in kCardDesigns) {
        await tester.pumpWidget(MaterialApp(
            builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2.0)),
                child: child!),
            home: Scaffold(
              body: SingleChildScrollView(
                child: InvitationCard(design: d, heading: 'H', names: 'Rina & Karim',
                    invite: 'Welcome', date: '12 Dec 2026', time: '7 pm',
                    venue: 'Senakunja', hosts: 'Family'),
              ),
            ),
        ));
        expect(tester.takeException(), isNull);
        expect(find.text('Rina & Karim'), findsOneWidget);
      }
    });

    testWidgets('share sheet: link made on the server; turn off calls revoke',
        (tester) async {
      final api = _Api();
      await tester.pumpWidget(_app(api, Builder(
          builder: (c) => TextButton(
              onPressed: () => shareLifeLink(c, kind: 'trip', id: 5, title: 'Cox'),
              child: const Text('go')))));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(api.posts, ['/life/share']);
      expect(find.byKey(const ValueKey('life-share-circle')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('life-share-off')));
      await tester.tap(find.byKey(const ValueKey('life-share-off')));
      await tester.pumpAndSettle();
      expect(api.posts.last, '/life/share/revoke');
    });

    testWidgets('share-my-ride card opens Safe Journey (flag on) — Bangla',
        (tester) async {
      await tester.pumpWidget(_app(_Api(), const RideShareMyRideCard(), lang: 'bn'));
      await tester.pumpAndSettle();
      // flag registry default for safe_journey is ON; card shows its button
      expect(find.byKey(const ValueKey('ride-share-my-ride')), findsOneWidget);
    });
  });
}
