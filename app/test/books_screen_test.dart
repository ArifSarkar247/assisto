// ledger (owner Part 1 f): the Books screen (flag accounting_v2) on the
// server's real response shapes (backend/core/ledger_views.py) for the hand-
// worked grocery fixture in backend/core/tests_ledger.py: net profit ৳370,
// total assets ৳8,470, books balance. Money arrives as integer poisha.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/business/books_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_books.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.staff = false}) {
    token = 't';
  }

  bool empty;
  final bool staff;
  final List<String> gets = [];
  final List<String> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (staff) throw ApiException('Only the owner can see this.', 403, null, 'staff_restricted');
    return fakeBooksGet(path, empty: empty)!;
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    empty = false; // the sync posted the shop's history
    return {'posted': 13, 'reversed': 0, 'unchanged': 0, '_status': 200};
  }
}

Widget _app(ApiClient api, {String lang = 'en', bool dark = false, double scale = 1}) {
  final s = AppState();
  s.api = api;
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
      builder: scale == 1
          ? null
          : (ctx, w) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: const BooksScreen(businessId: 1),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  void tall(WidgetTester t) {
    t.view.physicalSize = const Size(1080, 6000);
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
  }

  testWidgets('P&L shows the hand-worked numbers; period chips reload', (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api));
    await t.pumpAndSettle();
    expect(find.text('Net profit'), findsOneWidget);
    expect(find.text('৳370'), findsOneWidget);
    expect(find.text('৳2,100'), findsOneWidget); // net sales
    expect(find.text('(৳1,150)'), findsOneWidget); // COGS in brackets
    expect(api.gets.first, contains('business=1'));
    await t.tap(find.text('This year'));
    await t.pumpAndSettle();
    expect(api.gets.where((g) => g.contains('profit-loss')).length, 2);
  });

  testWidgets('balance sheet + trial balance show "books balance"', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake()));
    await t.pumpAndSettle();
    await t.tap(find.text('Balance sheet'));
    await t.pumpAndSettle();
    expect(find.text('Debits equal credits: the books balance'), findsOneWidget);
    expect(find.text('৳8,470'), findsNWidgets(2)); // total assets = total L + E
    await t.tap(find.text('Trial balance'));
    await t.pumpAndSettle();
    expect(find.text('৳10,770'), findsNWidgets(2));
  });

  testWidgets('Bangla: Bangla digits and lakh grouping', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.text('হিসাবের বই'), findsOneWidget);
    expect(find.text('৳৩৭০'), findsOneWidget);
    await t.tap(find.text('ব্যালান্স শিট'));
    await t.pumpAndSettle();
    expect(find.text('৳৮,৪৭০'), findsNWidgets(2));
  });

  testWidgets('empty: benefit + big button + how-to; the button syncs', (t) async {
    tall(t);
    final api = _Fake(empty: true);
    await t.pumpWidget(_app(api));
    await t.pumpAndSettle();
    expect(find.text('Your books fill themselves'), findsOneWidget);
    final btn = find.widgetWithText(FilledButton, 'Update books');
    expect(btn, findsOneWidget);
    expect(t.getSize(btn).height, greaterThanOrEqualTo(48));
    await t.tap(btn);
    await t.pumpAndSettle();
    expect(api.posts, ['/business/books/sync']);
    expect(find.text('Net profit'), findsOneWidget);
  });

  testWidgets('staff: honest owner-only message, no retry loop', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(staff: true)));
    await t.pumpAndSettle();
    expect(find.text('Only the owner can see this.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('200% font + dark: no overflow on any tab', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(), dark: true, scale: 2));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    for (final tab in ['Balance sheet', 'Trial balance']) {
      await t.tap(find.text(tab));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }
  });
}
