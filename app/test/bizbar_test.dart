// bizbar — business khata + CRM launch bar (2 Nov).
//
//  * statement PDF: pagination + a valid multi-page PDF (Bangla is drawn by
//    Flutter's own text engine, so only the container is tested here);
//  * daily cash close on the REAL server contract (auto lines, carried
//    opening, a failed tap says so, share);
//  * low stock: hub card, products filter;
//  * quick sell checkout: discount in the total, empty "paid" = exact cash,
//    a due sale must name its customer (sent to the server);
//  * the chosen business sticks; the khata shortcut opens offline;
//  * bn + en, Bangla digits, 48 dp / labels.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/cctvx/mini_pdf.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/business_common.dart';
import 'package:assisto/screens/business/cashbox_screen.dart';
import 'package:assisto/screens/business/khata_entry_screen.dart';
import 'package:assisto/screens/business/khata_screen.dart';
import 'package:assisto/screens/business/low_stock_card.dart';
import 'package:assisto/screens/business/products_screen.dart';
import 'package:assisto/screens/business/quick_sell_screen.dart';
import 'package:assisto/screens/business/statement_pdf.dart';
import 'package:assisto/services/khata_offline.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

class _BzApi extends FakeApi {
  _BzApi({super.lang = 'en'});
  bool cashboxDown = false;
  bool profilesDown = false;
  bool offline = false;
  final posts = <String, List<Map<String, dynamic>>>{};

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (profilesDown && path.startsWith('/business/profiles')) {
      throw const SocketException('offline');
    }
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (cashboxDown && path.contains('/business/cashbox/')) {
      throw const SocketException('offline');
    }
    if (offline && path.contains('/business/khata')) {
      throw const SocketException('offline');
    }
    posts.putIfAbsent(path.split('?').first, () => []).add(body);
    if (path.split('?').first == '/business/khata/parties') {
      return {'id': 77, 'name': body['name'], 'book': body['book']};
    }
    if (path.contains('/business/sales/checkout')) {
      return {'sale_id': 9, 'total': 20000, 'lines': const [], 'low_stock': const []};
    }
    return super.postJson(path, body);
  }
}

Widget _app(Widget child, {String lang = 'en', bool dark = false}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      darkTheme: AssistoTheme.dark,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: child,
    );

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, _BzApi api,
    {String lang = 'en', bool dark = false, Map<String, Object>? prefs,
    bool settle = true}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s, child: _app(screen, lang: lang, dark: dark)));
  if (settle) await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

const _biz = {'id': 1, 'name': 'Rahim Store', 'role': 'owner'};

/// Opens [child] as a pushed route, so a sheet that pops itself after a sale
/// has a route under it.
class _Host extends StatelessWidget {
  final Widget child;
  const _Host(this.child);
  @override
  Widget build(BuildContext context) => Scaffold(
      body: Center(
          child: TextButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => Scaffold(body: child))),
              child: const Text('open'))));
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('statement PDF', () {
    test('pagination: empty = one page, long statements split, summary fits', () {
      expect(paginateRows(const []).length, 1);
      final many = List<double>.filled(80, 54);
      final plan = paginateRows(many);
      expect(plan.length, greaterThan(2));
      expect(plan.expand((p) => p).toList(), List.generate(80, (i) => i));
      // no page is over-full
      for (final p in plan) {
        expect(p.length * 54, lessThan(pdfPageH));
      }
    });

    test('a valid multi-page PDF with correct cross references', () {
      final px = Uint8List(4 * 3 * 3);
      final pdf = imagePagesPdf(
          [PdfPageImage(px, 4, 3), PdfPageImage(px, 4, 3), PdfPageImage(px, 4, 3)]);
      final s = latin1.decode(pdf);
      expect(s.startsWith('%PDF-1.4'), isTrue);
      expect(s, contains('/Count 3'));
      expect(s.trimRight().endsWith('%%EOF'), isTrue);
      // every xref offset points at its "n 0 obj"
      final xrefAt = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(s)!.group(1)!);
      final rows = s.substring(xrefAt).split('\n').skip(3).take(11).toList();
      for (var i = 0; i < rows.length; i++) {
        final off = int.parse(rows[i].substring(0, 10));
        expect(s.substring(off).startsWith('${i + 1} 0 obj'), isTrue, reason: 'obj ${i + 1}');
      }
      expect(() => imagePagesPdf(const []), throwsArgumentError);
    });

    testWidgets('statement has the PDF button (bn, 48 dp, labelled)', (tester) async {
      final api = _BzApi(lang: 'bn');
      final t = await _pump(
          tester,
          khataStatementPreview(_biz,
              {'id': 1, 'name': 'Karim', 'phone': '01712345678', 'book': 'customer'}),
          api,
          lang: 'bn');
      expect(find.byKey(const ValueKey('bb-stmt-pdf')), findsOneWidget);
      expect(find.text(t.bbPdfButton), findsOneWidget);
      final h = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      h.dispose();
    });
  });

  group('daily cash close (cashbox)', () {
    testWidgets('bn: real contract — auto lines, carried opening, Bangla digits',
        (tester) async {
      final t = await _pump(tester, const CashboxScreen(business: _biz),
          _BzApi(lang: 'bn'), lang: 'bn');
      expect(find.text('নগদ বিক্রি (দোকান)'), findsOneWidget);
      expect(find.text('বাকি আদায় (খাতা)'), findsOneWidget);
      expect(find.text(t.bbCbCarried), findsOneWidget);
      expect(find.text('৳৭,০০০'), findsWidgets);
      expect(find.text(t.bbCbDuesHint), findsOneWidget);
      expect(find.byKey(const ValueKey('bb-cb-share')), findsOneWidget);
    });

    testWidgets('a failed cash-in says so (it used to vanish silently)',
        (tester) async {
      final api = _BzApi()..cashboxDown = true;
      final t = await _pump(tester, const CashboxScreen(business: _biz), api);
      await tester.tap(find.text(t.cashboxCashIn));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '250');
      await tester.tap(find.text(t.save));
      await tester.pumpAndSettle();
      expect(find.text(t.actionFailedRetry), findsOneWidget);
    });

    testWidgets('en + dark + large text: no overflow', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, const CashboxScreen(business: _biz), _BzApi(), dark: true);
      expect(tester.takeException(), isNull);
    });
  });

  group('low stock', () {
    testWidgets('hub card shows the count and opens the list', (tester) async {
      var opened = false;
      final t = await _pump(
          tester,
          Scaffold(body: LowStockCard(businessId: 1, onOpen: () => opened = true)),
          _BzApi(lang: 'bn'),
          lang: 'bn');
      expect(find.text(t.bbLowStockTitle('১')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bb-low-stock-card')));
      expect(opened, isTrue);
    });

    testWidgets('products: low-only shows just the low ones', (tester) async {
      final t = await _pump(
          tester, const ProductsScreen(businessId: 1, lowOnly: true), _BzApi());
      expect(find.byKey(const ValueKey('bb-low-chip')), findsOneWidget);
      // the fake catalog: one item with stock 8 (not low), one at 0 (low)
      expect(find.text(t.biz_out_of_stock), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bb-low-chip')));
      await tester.pumpAndSettle();
      expect(find.text(t.biz_out_of_stock), findsOneWidget);
    });
  });

  group('quick sell checkout', () {
    const cart = {
      'lines': [
        {'id': 1, 'product_id': 5, 'product_name': 'Soap', 'variant_key': '__base__',
         'qty': 2, 'unit_price': 10000}
      ],
      'subtotal': 20000,
      'total': 20000,
    };

    testWidgets('due sale needs a customer, then sends name + phone', (tester) async {
      final api = _BzApi();
      final t = await _pump(
          tester, const _Host(CheckoutSheet(cart: cart, businessId: 1)), api);
      await _open(tester);
      await tester.tap(find.text(t.biz_pay_due));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(t.biz_sale_done));
      await tester.tap(find.text(t.biz_sale_done));
      await tester.pumpAndSettle();
      expect(find.text(t.bbDueNeedsCustomer), findsOneWidget);
      expect(api.posts['/business/sales/checkout'], isNull);
      await tester.enterText(find.byKey(const ValueKey('bb-due-name')), 'Karim');
      await tester.enterText(find.byKey(const ValueKey('bb-due-phone')), '01712345678');
      await tester.ensureVisible(find.text(t.biz_sale_done));
      await tester.tap(find.text(t.biz_sale_done));
      await tester.pumpAndSettle();
      final body = api.posts['/business/sales/checkout']!.single;
      expect(body['payment_method'], 'due');
      expect(body['customer_name'], 'Karim');
      expect(body['customer_phone'], '01712345678');
    });

    testWidgets('cash with an empty "paid" box is exact cash (no short-pay stop)',
        (tester) async {
      final api = _BzApi();
      final t = await _pump(
          tester, const _Host(CheckoutSheet(cart: cart, businessId: 1)), api);
      await _open(tester);
      expect(find.text(t.bbPaidEmptyIsExact), findsOneWidget);
      await tester.ensureVisible(find.text(t.biz_sale_done));
      await tester.tap(find.text(t.biz_sale_done));
      await tester.pumpAndSettle();
      expect(find.text(t.biz_short_payment), findsNothing);
      expect(api.posts['/business/sales/checkout']!.single['payment_method'], 'cash');
    });
  });

  group('business choice + offline shortcut', () {
    test('pickBusiness: remembered > server > first', () {
      final list = [
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': 'B'},
      ];
      expect(pickBusiness(list, 1, 2)!['id'], 2);
      expect(pickBusiness(list, 1, 9)!['id'], 1);
      expect(pickBusiness(list, null, null)!['id'], 1);
      expect(pickBusiness(const [], 1, 2), isNull);
    });

    testWidgets('the khata shortcut opens from the saved list with no internet',
        (tester) async {
      final api = _BzApi()..profilesDown = true;
      SharedPreferences.setMockInitialValues({});
      await KhataOffline.cachePut(KhataOffline.businessesKey, {
        'businesses': [_biz],
        'selected_id': 1,
      });
      final raw = Map<String, Object>.from(
          {for (final k in (await SharedPreferences.getInstance()).getKeys())
            k: (await SharedPreferences.getInstance()).get(k)!});
      await _pump(tester, const KhataEntryScreen(), api, prefs: raw);
      expect(find.byType(KhataScreen), findsOneWidget);
    });
  });

  group('offline: a new customer + entries, synced in order', () {
    test('party first, then its entries move to the real id', () async {
      SharedPreferences.setMockInitialValues({});
      final api = _BzApi()..offline = true;
      final temp = KhataOffline.newTempPartyId();
      expect(temp, lessThan(0));
      await KhataOffline.enqueue(KhataOp(
          cid: 'kx-party-0001', bizId: 1, partyId: temp, partyName: 'Rahim',
          book: 'customer', kind: 'party', amountPoisha: 0,
          atIso: '2026-11-02T10:00:00', createdAt: DateTime(2026, 11, 2, 10),
          phone: '01712345678'));
      await KhataOffline.enqueue(KhataOp(
          cid: 'kx-entry-0001', bizId: 1, partyId: temp, partyName: 'Rahim',
          book: 'customer', kind: 'entry', direction: 'gave', amountPoisha: 50000,
          atIso: '2026-11-02T10:01:00', createdAt: DateTime(2026, 11, 2, 10, 1)));
      expect((await KhataOffline.pendingParties(1, 'customer')).single.phone,
          '01712345678');
      var r = await KhataOffline.sync(api);
      expect(r.offline, isTrue);
      expect((await KhataOffline.all()).length, 2);
      api.offline = false;
      r = await KhataOffline.sync(api);
      expect(r.synced, 2);
      expect(await KhataOffline.all(), isEmpty);
      final party = api.posts['/business/khata/parties']!.single;
      expect(party['client_id'], 'kx-party-0001');
      expect(party['phone'], '01712345678');
      expect(api.posts['/business/khata/parties/77/entries']!.single['client_id'],
          'kx-entry-0001');
    });
  });
}
