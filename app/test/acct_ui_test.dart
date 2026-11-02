// acctui: the accounting UI (flag accounting_v2) on the server's real
// response shapes (backend/core/ledger_entry_views.py + ledger_views.py):
// plain-word entry (no debit/credit words), one-tap party, offline queue with
// a replay-safe client_id, opening wizard, reports incl. cash flow + VAT,
// month close / reopen-with-reason, audit trail, Excel/CSV export bytes,
// Bangla digits, 200% font + dark.
import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/l10n/app_localizations_en.dart';
import 'package:assisto/screens/business/acct/acct_audit_screen.dart';
import 'package:assisto/screens/business/acct/acct_close_screen.dart';
import 'package:assisto/screens/business/acct/acct_common.dart';
import 'package:assisto/screens/business/acct/acct_entry_screen.dart';
import 'package:assisto/screens/business/acct/acct_home_screen.dart';
import 'package:assisto/screens/business/acct/acct_opening_screen.dart';
import 'package:assisto/screens/business/acct/acct_report_model.dart';
import 'package:assisto/screens/business/acct/acct_reports_screen.dart';
import 'package:assisto/screens/business/acct/mini_xlsx.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_acct.dart';
import 'fake_books.dart';

class _Fake extends ApiClient {
  _Fake({this.empty = false, this.offline = false, this.refuse = false}) {
    token = 't';
  }

  final bool empty;
  bool offline;
  final bool refuse;
  final List<String> gets = [];
  final List<(String, Map<String, dynamic>)> posts = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (offline) throw Exception('SocketException: no route');
    return fakeAcctGet(path, empty: empty) ?? fakeBooksGet(path, empty: empty) ?? const {};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (offline) throw Exception('SocketException: no route');
    posts.add((path, body));
    if (refuse) {
      return {'_status': 400, 'error': 'locked_period', 'detail': 'The books are closed for that day.'};
    }
    return fakeAcctPost(path, body)!;
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

/// A host page so the entry screen can pop back with its result.
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

  // ------------------------------------------------------------ pure
  test('amount parsing accepts Bangla digits and commas', () {
    expect(parseTakaToPoisha('1,250'), 125000);
    expect(parseTakaToPoisha('১২৫০.৫'), 125050);
    expect(parseTakaToPoisha('0'), isNull);
    expect(parseTakaToPoisha('abc'), isNull);
    expect(poishaToField(125050), '1250.50');
    expect(poishaToField(125000), '1250');
  });

  test('periods mirror the server (month / quarter / year, capped at today)', () {
    final now = DateTime(2026, 11, 2);
    expect(const AcctPeriod(AcctPeriodKind.month).range(now), (DateTime(2026, 11, 1), now));
    expect(const AcctPeriod(AcctPeriodKind.month, -1).range(now),
        (DateTime(2026, 10, 1), DateTime(2026, 10, 31)));
    expect(const AcctPeriod(AcctPeriodKind.quarter).range(now), (DateTime(2026, 10, 1), now));
    expect(const AcctPeriod(AcctPeriodKind.quarter, -4).range(now),
        (DateTime(2025, 10, 1), DateTime(2025, 12, 31)));
    expect(const AcctPeriod(AcctPeriodKind.year, -1).range(now),
        (DateTime(2025, 1, 1), DateTime(2025, 12, 31)));
    expect(AcctPeriod(AcctPeriodKind.month, -10).range(DateTime(2026, 2, 3)).$1, DateTime(2025, 4, 1));
  });

  test('party book: only where the khata needs a person', () {
    expect(acctPartyBook('due'), 'customer');
    expect(acctPartyBook('purchase'), isNull);
    expect(acctPartyBook('purchase', pay: 'due'), 'supplier');
    expect(acctPartyBook('money_in', purpose: 'customer'), 'customer');
    expect(acctPartyBook('money_in', purpose: 'capital'), isNull);
    expect(acctPartyBook('money_out', purpose: 'supplier'), 'supplier');
  });

  test('xlsx: a real zip with the sheets, numbers in taka, Bangla kept', () {
    final r = cfReport(_en, fakeAcctGet('/business/books/cash-flow')!, '1 Nov to 2 Nov');
    final sheet = reportSheet(r,
        shop: 'Rahman Store',
        colAccount: 'Account',
        colCode: 'Code',
        colAmount: 'Amount',
        balancedText: 'ok');
    final bytes = buildXlsx([sheet, XlsxSheet('হিসাব', [
      [const XlsxCell('নগদ'), const XlsxCell(12.5)]
    ])]);
    final files = _unzip(bytes);
    expect(files.keys, containsAll(['[Content_Types].xml', 'xl/workbook.xml',
      'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml', 'xl/styles.xml']));
    final s1 = files['xl/worksheets/sheet1.xml']!;
    expect(s1, contains('Money at the end'));
    expect(s1, contains('<v>27420.0</v>')); // ৳27,420 closing, in taka
    expect(files['xl/worksheets/sheet2.xml'], contains('নগদ'));
    expect(files['xl/workbook.xml'], contains('Cash flow'));
    expect(xlsxSheetName('a/b:c', {}), 'a b c');
    expect(xlsxColumn(27), 'AB');
  });

  test('csv: BOM + taka numbers + two columns for the trial balance', () {
    final r = tbReport(_en, fakeBooksGet('/business/books/trial-balance')!, 'As of 2 Nov');
    final csv = reportCsv(r, shop: 'Shop, Dhaka', colAccount: 'Account', colCode: 'Code', colAmount: 'Amount');
    expect(csv.startsWith('﻿'), isTrue);
    expect(csv, contains('"Shop, Dhaka"'));
    expect(csv, contains('Code,Account,Debit,Credit'));
    expect(csv, contains('1010,Cash in hand,70.00,0.00'));
  });

  // ------------------------------------------------------------ home
  testWidgets('home: plain-word buttons, recent entries, cancelled shown', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(), const AcctHomeScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text('What happened today?'), findsOneWidget);
    for (final k in ['Sale', 'Purchase', 'Expense', 'Due (on credit)', 'Money received', 'Money paid']) {
      expect(find.descendant(of: find.byType(InkWell), matching: find.text(k)), findsWidgets);
    }
    expect(find.text('Expense · Rent'), findsOneWidget);
    expect(find.text('৳500'), findsOneWidget);
    expect(find.textContaining('Cancelled'), findsOneWidget);
    // no debit / credit words on the owner's home
    expect(find.textContaining('Debit'), findsNothing);
    expect(find.textContaining('Credit'), findsNothing);
    final tile = find.byKey(const ValueKey('acct-home-expense'));
    expect(t.getSize(tile).height, greaterThanOrEqualTo(48));
    await t.tap(tile);
    await t.pumpAndSettle();
    expect(find.text('What kind of expense?'), findsOneWidget);
  });

  testWidgets('home empty: benefit + big button + how-to + opening card', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(empty: true), const AcctHomeScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text('Know your real profit, in plain words'), findsOneWidget);
    expect(find.textContaining('How: 1)'), findsOneWidget);
    final cta = find.byKey(const ValueKey('acct-empty-cta'));
    expect(t.getSize(cta).height, greaterThanOrEqualTo(48));
    expect(find.text('Start right: add your opening balances'), findsOneWidget);
    await t.tap(cta);
    await t.pumpAndSettle();
    expect(find.text('What happened?'), findsOneWidget);
  });

  // ------------------------------------------------------------ entry
  Future<void> openEntry(WidgetTester t, _Fake api, String kind, {String lang = 'en'}) async {
    await t.pumpWidget(_app(api, _Host(AcctEntryScreen(businessId: 1, kind: kind), (_) {}), lang: lang));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('sale on bKash: plain effect line, then one balanced post', (t) async {
    tall(t);
    final api = _Fake();
    await openEntry(t, api, 'sale');
    await t.enterText(find.byKey(const ValueKey('acct-amount')), '1250');
    await t.tap(find.text('bKash'));
    await t.pumpAndSettle();
    expect(find.text('৳1,250 comes into bKash. Your sales go up.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-save')));
    await t.pumpAndSettle();
    expect(api.posts.length, 1);
    final (path, body) = api.posts.single;
    expect(path, '/business/acct/entries');
    expect(body['kind'], 'sale');
    expect(body['amount'], 125000);
    expect(body['account'], 'bkash');
    expect(body['business'], 1);
    expect('${body['client_id']}'.length, 16);
    expect(find.text('open'), findsOneWidget); // popped back
  });

  testWidgets('due needs a person; khata pick fills it', (t) async {
    tall(t);
    final api = _Fake();
    await openEntry(t, api, 'due');
    await t.enterText(find.byKey(const ValueKey('acct-amount')), '300');
    await t.tap(find.byKey(const ValueKey('acct-save')));
    await t.pumpAndSettle();
    expect(find.text('Choose who this is with.'), findsOneWidget);
    expect(api.posts, isEmpty);
    // the picker: type a new name -> "New: Rahim"
    await t.tap(find.byKey(const ValueKey('acct-party')));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Rahim');
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('acct-party-new')));
    await t.pumpAndSettle();
    expect(find.text('Rahim — tap to change'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-save')));
    await t.pumpAndSettle();
    expect(api.posts.single.$2['party_name'], 'Rahim');
    expect(api.posts.single.$2.containsKey('account'), isFalse);
  });

  testWidgets('offline: kept on the phone, sent later ONCE with the same id', (t) async {
    tall(t);
    final api = _Fake(offline: true);
    await openEntry(t, api, 'expense');
    await t.enterText(find.byKey(const ValueKey('acct-amount')), '80');
    await t.tap(find.text('Rent'));
    await t.tap(find.byKey(const ValueKey('acct-save')));
    await t.pumpAndSettle();
    expect(find.textContaining('No internet'), findsOneWidget);
    final q = await AcctQueue.load();
    expect(q.length, 1);
    final cid = (q.single['entry'] as Map)['client_id'];
    expect((q.single['entry'] as Map)['category'], '6010');
    api.offline = false;
    expect(await AcctQueue.flush(api), 1);
    expect(await AcctQueue.load(), isEmpty);
    expect(api.posts.single.$2['client_id'], cid);
    expect(await AcctQueue.flush(api), 0); // nothing sent twice
  });

  testWidgets('server refusal is shown in its own words', (t) async {
    tall(t);
    await openEntry(t, _Fake(refuse: true), 'sale');
    await t.enterText(find.byKey(const ValueKey('acct-amount')), '50');
    await t.tap(find.byKey(const ValueKey('acct-save')));
    await t.pumpAndSettle();
    expect(find.text('The books are closed for that day.'), findsOneWidget);
  });

  testWidgets('transfer to the same place is stopped before sending', (t) async {
    tall(t);
    final api = _Fake();
    await openEntry(t, api, 'transfer');
    await t.enterText(find.byKey(const ValueKey('acct-amount')), '50');
    await t.tap(find.text('Bank').first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('acct-save')));
    await t.pumpAndSettle();
    expect(find.text('Choose two different places.'), findsOneWidget);
    expect(api.posts, isEmpty);
  });

  // ------------------------------------------------------------ opening
  testWidgets('opening wizard: khata dues shown, stock kept when empty', (t) async {
    tall(t);
    final api = _Fake(empty: true);
    await t.pumpWidget(_app(api, _Host(const AcctOpeningScreen(businessId: 1), (_) {})));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Where did the shop start?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-opening-next')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('acct-opening-cash')), '5000');
    await t.tap(find.byKey(const ValueKey('acct-opening-next')));
    await t.pumpAndSettle();
    expect(find.textContaining('customers owe ৳350'), findsOneWidget);
    expect(find.textContaining('do not write them again'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-opening-next')));
    await t.pumpAndSettle();
    expect(find.textContaining('৳6,650'), findsOneWidget); // our stock estimate
    await t.tap(find.byKey(const ValueKey('acct-opening-next')));
    await t.pumpAndSettle();
    expect(find.text('Keep our estimate'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-opening-next')));
    await t.pumpAndSettle();
    final (path, body) = api.posts.single;
    expect(path, '/business/books/opening'); // the core's opening balances
    expect(body['cash'], 500000);
    expect(body['date'], '2026-10-15'); // the books' start day
    expect(body['inventory'], isNull); // empty = keep the reconstructed stock
    expect(body['receivables'], isEmpty);
  });

  // ------------------------------------------------------------ reports
  testWidgets('reports: P&L, cash flow ties, VAT, trial balance two columns', (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AcctReportsScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text('Net profit'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-rep-cf')));
    await t.pumpAndSettle();
    expect(find.text('Money at the end'), findsOneWidget);
    expect(find.text('৳27,420'), findsOneWidget);
    expect(find.text('Start + change = end: the money adds up'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-rep-vat')));
    await t.pumpAndSettle();
    expect(find.text('Still to pay'), findsOneWidget);
    expect(find.text('৳40'), findsOneWidget);
    expect(find.textContaining('does not file it'), findsOneWidget);
    expect(find.textContaining('BIN 000123456-0101'), findsOneWidget); // core register
    await t.tap(find.byKey(const ValueKey('acct-rep-tb')));
    await t.pumpAndSettle();
    expect(find.textContaining('Debit: ৳10,770'), findsOneWidget);
    // only the report on screen is fetched (2 GB phones)
    expect(api.gets.where((g) => g.contains('balance-sheet')), isEmpty);
    await t.tap(find.text('Year'));
    await t.pumpAndSettle();
    expect(api.gets.last, contains('as_of='));
  });

  testWidgets('reports empty period: benefit + big button + how-to', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(empty: true), const AcctReportsScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text('Nothing in this period yet'), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('acct-rep-empty-cta'))).height, greaterThanOrEqualTo(48));
  });

  testWidgets('export sheet offers Excel, PDF and CSV', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(), const AcctReportsScreen(businessId: 1)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('acct-export')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('acct-export-xlsx')), findsOneWidget);
    expect(find.byKey(const ValueKey('acct-export-pdf')), findsOneWidget);
    expect(find.byKey(const ValueKey('acct-export-csv')), findsOneWidget);
  });

  // ------------------------------------------------------------ close / audit
  testWidgets('close: shows the lock; reopening needs a 5-letter reason', (t) async {
    tall(t);
    final api = _Fake();
    await t.pumpWidget(_app(api, const AcctCloseScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text('Closed up to 31 Oct 2026'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('acct-reopen')));
    await t.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('acct-reopen-confirm'));
    expect(t.widget<FilledButton>(confirm).onPressed, isNull);
    await t.enterText(find.byKey(const ValueKey('acct-reopen-reason')), 'late bill from Akij');
    await t.pumpAndSettle();
    expect(t.widget<FilledButton>(confirm).onPressed, isNotNull);
    await t.tap(confirm);
    await t.pumpAndSettle();
    final (path, body) = api.posts.single;
    expect(path, '/business/acct/lock');
    expect(body['reason'], 'late bill from Akij');
    expect(body['lock_date'], isNull); // October was the first month: fully open
  });

  testWidgets('audit: who/when, reversal pairs both ways, owner actions', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(), const AcctAuditScreen(businessId: 1)));
    await t.pumpAndSettle();
    expect(find.text('Reversed by #15'), findsOneWidget);
    expect(find.text('Reverses #14'), findsOneWidget);
    expect(find.text('Closed the books up to 31 Oct 2026'), findsOneWidget);
    expect(find.text('Cancelled an entry — reason: typo'), findsOneWidget);
    expect(find.textContaining('placed on the next open day'), findsOneWidget);
  });

  // ------------------------------------------------------------ bn / a11y
  testWidgets('Bangla: Bangla words and digits', (t) async {
    tall(t);
    await t.pumpWidget(_app(_Fake(), const AcctHomeScreen(businessId: 1), lang: 'bn'));
    await t.pumpAndSettle();
    expect(find.text('আজ কী হলো?'), findsOneWidget); // আজ কী হলো?
    expect(find.text('৳৫০০'), findsOneWidget); // ৳৫০০
  });

  testWidgets('200% font + dark: no overflow on every screen', (t) async {
    tall(t);
    for (final w in <Widget>[
      const AcctHomeScreen(businessId: 1),
      const AcctEntryScreen(businessId: 1, kind: 'money_in'),
      const AcctReportsScreen(businessId: 1, initialReport: 'cf'),
      const AcctOpeningScreen(businessId: 1),
      const AcctCloseScreen(businessId: 1),
      const AcctAuditScreen(businessId: 1),
    ]) {
      for (final lang in ['en', 'bn']) {
        await t.pumpWidget(_app(_Fake(), w, dark: true, scale: 2, lang: lang));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: '${w.runtimeType} $lang');
      }
    }
  });
}

Map<String, String> _unzip(Uint8List z) {
  final out = <String, String>{};
  final bd = ByteData.sublistView(z);
  var i = 0;
  while (i + 4 <= z.length && bd.getUint32(i, Endian.little) == 0x04034b50) {
    final method = bd.getUint16(i + 8, Endian.little);
    final csize = bd.getUint32(i + 18, Endian.little);
    final nlen = bd.getUint16(i + 26, Endian.little);
    final xlen = bd.getUint16(i + 28, Endian.little);
    final name = utf8.decode(z.sublist(i + 30, i + 30 + nlen));
    final start = i + 30 + nlen + xlen;
    final data = z.sublist(start, start + csize);
    final raw = method == 8 ? ZLibDecoder(raw: true).convert(data) : data;
    out[name] = utf8.decode(raw);
    i = start + csize;
  }
  return out;
}
