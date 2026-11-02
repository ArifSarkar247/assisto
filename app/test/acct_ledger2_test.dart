// ledger2: business accounting phase 2 UI on the server's real shapes
// (backend/core/ledger2_views.py + ledger_views.py): VAT tab = the core's
// numbers only (output / input / paid / still due + both registers), payment
// method on khata payments (sent + kept offline), purchase bill no. / BIN,
// cashbox sorting, per-product VAT (no invented rate), year close + reopen
// with a reason, the cost-price-0 banner and its one-tap fix. Bangla digits,
// 200% font, dark.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/app_localizations_en.dart';
import 'package:assisto/screens/business/acct/acct_close_screen.dart';
import 'package:assisto/screens/business/acct/acct_entry_screen.dart';
import 'package:assisto/screens/business/acct/acct_ledger2.dart';
import 'package:assisto/screens/business/acct/acct_reports_screen.dart';
import 'package:assisto/screens/business/khata_screen.dart';
import 'package:assisto/services/khata_offline.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_acct.dart';
import 'fake_books.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false}) {
    token = 't';
  }

  final bool empty;
  final List<String> gets = [];
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    return fakeAcctGet(path, empty: empty) ?? fakeBooksGet(path, empty: empty) ?? const {};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    return fakeAcctPost(path, body)!;
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add((path, body));
    return {'entry_id': 5, 'id': 5, 'client_id': body['client_id'], 'version': 1,
      'duplicate': false, 'method': body['method'] ?? ''};
  }
}

Widget _app(ApiClient api, Widget home,
    {String lang = 'en', bool dark = false, double scale = 1}) {
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
      home: home,
    ),
  );
}

/// A host page so a sheet / screen can pop back with its result.
class _Host extends StatelessWidget {
  final Widget child;
  final void Function(Object?) onResult;
  const _Host(this.child, this.onResult);
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () async =>
                onResult(await Navigator.of(context).push(MaterialPageRoute(builder: (_) => child))),
            child: const Text('open'),
          ),
        ),
      );
}

final _en = AppLocalizationsEn();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  void tall(WidgetTester t) {
    t.view.physicalSize = const Size(1080, 7000);
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
  }

  // ------------------------------------------------------------ 1) VAT
  testWidgets('VAT tab: core numbers only — output, input, paid, still due, both registers',
      (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AcctReportsScreen(businessId: 1, initialReport: 'vat')));
    await t.pumpAndSettle();
    expect(api.gets.where((g) => g.contains('/business/acct/vat')), isEmpty); // one source
    expect(api.gets.where((g) => g.contains('/business/books/vat')), hasLength(1));
    expect(find.text('৳150'), findsWidgets); // output VAT (not netted with paid)
    expect(find.text('৳60'), findsWidgets); // input VAT
    expect(find.text('৳50'), findsOneWidget); // paid to NBR
    expect(find.text('৳40'), findsOneWidget); // still due
    expect(find.text(_en.lg2VatExemptSales), findsOneWidget);
    expect(find.text(_en.lg2PurchaseRegister), findsOneWidget);
    expect(find.textContaining('BIN 000999888-0101'), findsOneWidget);
    expect(find.textContaining('does not file it'), findsOneWidget);
    expect(find.byKey(const ValueKey('acct-vat-rates')), findsOneWidget);
  });

  // ------------------------------------------------------------ 2) method
  testWidgets('khata payment: pick bKash -> sent as method; due entry has no picker', (t) async {
    tall(t);
    final api = _Fake();
    Object? result;
    await t.pumpWidget(_app(api, _Host(Scaffold(body: khataEntrySheetPreview(
        {'id': 1, 'name': 'X', 'role': 'owner'}, isDue: false)), (r) => result = r)));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text(_en.lg2HowReceived), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('ldg-entry-amount')), '70');
    await t.tap(find.byKey(const ValueKey('ldg-method-bkash')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('ldg-entry-save')));
    await t.pumpAndSettle();
    final (path, body) = api.posts.single;
    expect(path, contains('/payment'));
    expect(body['method'], 'bkash');
    expect(body['amount'], 7000);
    expect(result, 'saved');

    await t.pumpWidget(_app(_Fake(), Scaffold(body: khataEntrySheetPreview(
        {'id': 1, 'name': 'X', 'role': 'owner'}, isDue: true))));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ldg-entry-method')), findsNothing);
  });

  test('offline khata op keeps the payment method across a restart', () {
    final op = KhataOp(cid: 'kx-1234567', bizId: 1, partyId: 2, partyName: 'Karim',
        book: 'customer', kind: 'payment', amountPoisha: 500, atIso: '2026-11-02T10:00:00',
        createdAt: DateTime(2026, 11, 2), method: 'nagad');
    expect(KhataOp.fromJson(op.toJson())!.method, 'nagad');
    expect(KhataOp.fromJson(op.copyWith(state: 'failed').toJson())!.method, 'nagad');
    final old = KhataOp.fromJson({'cid': 'kx-old0001', 'party': 2, 'amt': 5}); // pre-ledger2
    expect(old!.method, ''); // = cash in the books, never guessed
  });

  // ------------------------------------------------------------ 3) purchase
  testWidgets('purchase entry sends bill no. + supplier BIN (Mushak-6.1)', (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, _Host(const AcctEntryScreen(businessId: 1, kind: 'purchase'),
        (_) {})));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('acct-amount')), '1150');
    await t.tap(find.byKey(const ValueKey('acct-more'))); // optional details
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('acct-bill-no')), 'CH-77');
    await t.enterText(find.byKey(const ValueKey('acct-supplier-bin')), '000999888-0101');
    await t.ensureVisible(find.byKey(const ValueKey('acct-save')));
    await t.tap(find.byKey(const ValueKey('acct-save')));
    await t.pumpAndSettle();
    final (path, body) = api.posts.single;
    expect(path, '/business/acct/entries');
    expect(body['kind'], 'purchase');
    expect(body['bill_no'], 'CH-77');
    expect(body['supplier_bin'], '000999888-0101');
  });

  testWidgets('VAT by product: exempt / reduced shown; reduced needs a typed rate', (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AcctVatRatesScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text('Your shop\'s VAT rate: 15% (from invoice settings)'), findsOneWidget);
    expect(find.textContaining('VAT-exempt'), findsWidgets);
    expect(find.textContaining('Reduced rate 5%'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-vatp-3')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('acct-vatmode-reduced')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('acct-vat-save')));
    await t.pumpAndSettle();
    expect(find.text(_en.lg2VatRateBad), findsOneWidget); // nothing invented
    expect(api.posts, isEmpty);
    await t.enterText(find.byKey(const ValueKey('acct-vat-rate')), '7.5');
    await t.tap(find.byKey(const ValueKey('acct-vat-save')));
    await t.pumpAndSettle();
    final (path, body) = api.posts.single;
    expect(path, '/business/acct/vat-rates');
    expect(body['mode'], 'reduced');
    expect(body['vat_bp'], 750);
    expect(parsePctToBp('৭.৫'), 750);
    expect(parsePctToBp('100'), isNull);
  });

  // ------------------------------------------------------------ 4) cashbox
  testWidgets('cashbox: unsorted first, pick a kind -> classify posted', (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AcctCashboxScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.textContaining('2 not sorted yet'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-cash-31')));
    await t.pumpAndSettle();
    expect(find.text(_en.lg2CashInWhat), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-cls-4100')));
    await t.pumpAndSettle();
    final (path, body) = api.posts.single;
    expect(path, '/business/acct/cashbox/31/classify');
    expect(body['code'], '4100');
  });

  testWidgets('cashbox empty: benefit + big button + how-to', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(empty: true), const AcctCashboxScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text(_en.lg2CashboxEmptyTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('acct-open-cashbox')), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('acct-open-cashbox'))).height,
        greaterThanOrEqualTo(48));
  });

  // ------------------------------------------------------------ 5) year close
  testWidgets('year close needs "I understand"; reopen needs a 5-letter reason', (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AcctCloseScreen(businessId: 1)));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const ValueKey('acct-year-close-2026-06-30')));
    await t.tap(find.byKey(const ValueKey('acct-year-close-2026-06-30')));
    await t.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('acct-year-confirm'));
    expect(t.widget<FilledButton>(confirm).onPressed, isNull);
    await t.tap(find.byKey(const ValueKey('acct-year-understand')));
    await t.pumpAndSettle();
    await t.tap(confirm);
    await t.pumpAndSettle();
    expect(api.posts.last.$1, '/business/acct/year-close');
    expect(api.posts.last.$2['end'], '2026-06-30');

    await t.ensureVisible(find.byKey(const ValueKey('acct-year-reopen-2025-12-31')));
    await t.tap(find.byKey(const ValueKey('acct-year-reopen-2025-12-31')));
    await t.pumpAndSettle();
    final go = find.byKey(const ValueKey('acct-year-reopen-confirm'));
    expect(t.widget<FilledButton>(go).onPressed, isNull);
    await t.enterText(find.byKey(const ValueKey('acct-year-reason')), 'missed a bill');
    await t.pumpAndSettle();
    await t.tap(go);
    await t.pumpAndSettle();
    expect(api.posts.last.$1, '/business/acct/year-reopen');
    expect(api.posts.last.$2['reason'], 'missed a bill');
  });

  // ------------------------------------------------------------ 6) cost 0
  testWidgets('P&L shows the honest cost-0 banner; one tap lists products; fix posts',
      (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AcctReportsScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('acct-cost-banner')), findsOneWidget);
    expect(find.textContaining('Profit may be overstated: 3 sales'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-cost-open')));
    await t.pumpAndSettle();
    expect(find.text('Soybean oil 1L'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-cost-apply-2')));
    await t.pumpAndSettle();
    expect(api.posts.last.$1, '/business/acct/cost-gaps/apply');
    expect(api.posts.last.$2['product_id'], 2);
    expect(api.posts.last.$2.containsKey('cost'), isFalse); // catalog cost used
    // a product with no cost needs one typed first
    await t.tap(find.byKey(const ValueKey('acct-cost-apply-3')));
    await t.pumpAndSettle();
    expect(api.posts.where((p) => p.$2['product_id'] == 3), isEmpty);
    await t.enterText(find.byKey(const ValueKey('acct-cost-field-3')), '80');
    await t.tap(find.byKey(const ValueKey('acct-cost-apply-3')));
    await t.pumpAndSettle();
    expect(api.posts.last.$2['cost'], 8000);
  });

  testWidgets('no banner when every sale has a cost', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(empty: true), const AcctReportsScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('acct-cost-banner')), findsNothing);
  });

  // ------------------------------------------------------------ a11y / bn
  testWidgets('Bangla digits, 200% font + dark: no overflow', (t) async {
    tall(t);
    for (final w in const [
      AcctCashboxScreen(businessId: 1),
      AcctVatRatesScreen(businessId: 1),
      AcctCloseScreen(businessId: 1),
      AcctReportsScreen(businessId: 1),
    ]) {
      await t.pumpWidget(_app(_Fake(), w, lang: 'bn', dark: true, scale: 2));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '$w');
    }
    await t.pumpWidget(_app(_Fake(), const AcctCashboxScreen(businessId: 1), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.textContaining('২টি এখনো বাছা হয়নি'), findsOneWidget);
  });
}
