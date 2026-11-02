// invoices — layout per template × paper size × language, bn/en digits,
// QR content, PDF page sizes and the screens' main paths.
import 'dart:convert';
import 'dart:typed_data';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/invoice/invoice_doc.dart';
import 'package:assisto/screens/business/invoice/invoice_paper.dart';
import 'package:assisto/screens/business/invoice/invoice_screen.dart';
import 'package:assisto/screens/business/invoice/invoice_settings_screen.dart';
import 'package:assisto/screens/business/invoice/invoices_screen.dart';
import 'package:assisto/screens/business/invoice/new_invoice_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_fonts.dart';
import 'fake_api.dart';
import 'fake_invoices.dart';

final _latinDigit = RegExp(r'[0-9]');

InvoiceDoc _doc({String template = 'restaurant', bool vat = true, bool cancelled = false,
        int due = 0, int lines = 3}) =>
    InvoiceDoc.fromJson(fakeSaleInvoice(
        template: template, vat: vat, cancelled: cancelled, due: due, lines: lines));

class _InvApi extends FakeApi {
  _InvApi() : super(lang: 'en');
  final posts = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    final p = path.split('?').first;
    posts[p] = body;
    if (p == '/business/invoices') {
      return {
        ...fakeSaleInvoice(template: '${body['template']}'),
        'kind': 'manual', 'id': 9, 'number': 'SV-0009',
        'buyer': body['buyer'],
      };
    }
    if (p == '/business/invoice/settings') return fakeInvoiceSettings();
    return super.postJson(path, body);
  }
}

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, FakeApi api,
    {String lang = 'en'}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: screen,
    ),
  ));
  await tester.pumpAndSettle();
  return lookupAppLocalizations(Locale(lang));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppFonts);

  group('money, digits, rates', () {
    test('bn / en money and digits', () {
      expect(invMoney(123450, 'en'), '৳1,234.50');
      expect(invMoney(123450, 'bn'), '৳১,২৩৪.৫০');
      expect(invMoney(5, 'en'), '৳0.05');
      expect(invMoney(100000000, 'en'), '৳1,000,000.00');
      expect(invMoney(-2500, 'en'), '-৳25.00');
      expect(invRate(1500, 'en'), '15%');
      expect(invRate(750, 'en'), '7.5%');
      expect(invRate(1500, 'bn'), '১৫%');
      expect(invNum('S-0041', 'bn'), 'S-০০৪১');
    });

    test('server wall time is kept (no phone time-zone shift)', () {
      final d = _doc();
      expect(d.issuedAt!.hour, 14);
      expect(d.issuedAt!.minute, 5);
      expect(invDate(d.issuedAt!, 'en'), '02/11/2026');
      expect(invTime(d.issuedAt!, 'bn'), '১৪:০৫');
    });

    test('typed numbers accept Bangla digits', () {
      expect(percentToBp('15'), 1500);
      expect(percentToBp('৭.৫'), 750);
      expect(percentToBp('x'), isNull);
      expect(bpToPercent(750), '7.5');
      expect(typedPoisha('১,২৫০.৫০'), 125050);
      expect(typedPoisha('-1'), isNull);
      expect(typedQty(''), 1);
      expect(typedQty('0'), isNull);
    });
  });

  group('QR content', () {
    test('verify link always; pay link only when money is due', () {
      var q = invoiceQrs(_doc());
      expect(q.map((e) => e.kind), ['verify']);
      expect(q.first.data, fakeInvoiceVerifyUrl);
      q = invoiceQrs(_doc(vat: false, due: 10000));
      expect(q.map((e) => e.kind), ['verify', 'pay']);
      expect(q.last.data, 'https://shop.bkash.com/kacchi-ghor');
      // a cancelled paper never asks for money
      q = invoiceQrs(_doc(vat: false, due: 10000, cancelled: true));
      expect(q.map((e) => e.kind), ['verify']);
      // no link from the server -> no QR at all (never invented)
      final none = InvoiceDoc.fromJson({...fakeSaleInvoice(), 'verify_url': '', 'payment_link': 'http://x'});
      expect(invoiceQrs(none), isEmpty);
    });

    test('the QR payloads encode', () {
      for (final data in [fakeInvoiceVerifyUrl, 'https://shop.bkash.com/kacchi-ghor']) {
        final v = QrValidator.validate(
            data: data,
            version: QrVersions.auto,
            errorCorrectionLevel: QrErrorCorrectLevel.M);
        expect(v.status, QrValidationStatus.valid);
      }
    });
  });

  group('layout per template, paper and language', () {
    for (final lang in ['bn', 'en']) {
      final t = lookupAppLocalizations(Locale(lang));
      for (final paper in InvoicePaper.values) {
        for (final tpl in invoiceTemplates) {
          test('$tpl ${paper.code} $lang', () {
            final d = _doc(template: tpl);
            final l = layoutInvoice(d, paper, t, lang);
            expect(l.width, paper.widthPx);
            expect(l.height, greaterThan(200));
            for (final b in l.blocks) {
              expect(b.usedWidth, lessThanOrEqualTo(l.contentWidth + 0.5),
                  reason: '${b.kind} ${b.texts} is wider than the paper');
              expect(b.height, greaterThanOrEqualTo(0));
            }
            final texts = l.allTexts;
            // the template's own fields print with their labels
            for (final k in templateFields[tpl]!) {
              expect(texts, contains(extraLabel(t, k)), reason: k);
            }
            // a VAT invoice says Mushak-6.3, the rate and the amount
            expect(texts, contains(t.invTitleTax));
            expect(texts, contains(t.invMushak));
            expect(texts, contains(t.invVat(invRate(1500, lang))));
            expect(texts, contains(invMoney(15000, lang)));
            expect(texts, contains(invMoney(115000, lang)));
            expect(texts, contains(t.invVatIncluded));
            expect(texts.any((s) => s.startsWith(t.invSignature)), isTrue);
            expect(l.ofKind('qr').length, 1);
            expect(texts, contains(fakeInvoiceVerifyUrl));
            if (tpl == 'electronics') expect(texts, contains(t.invWarrantyKeep));
            if (serviceTemplates.contains(tpl)) expect(texts, contains(t.invSubFees));
            if (lang == 'bn') {
              // every number the paper prints is in Bangla digits (free text
              // typed by the shop, and the QR link itself, stay as typed)
              final typed = {
                fakeInvoiceVerifyUrl, 'Kacchi Ghor', 'Dhanmondi, Dhaka',
                'Kacchi biryani (full)', 'Borhani', 'Firni', 'Karim Mia', 'Mirpur',
                'Open every day', 'Rahim Uddin, Manager',
              };
              for (final s in texts) {
                if (typed.contains(s) || s.contains('Rahim Uddin')) continue;
                expect(_latinDigit.hasMatch(s), isFalse, reason: 'Latin digit in "$s"');
              }
            }
          });
        }
      }
    }

    test('plain (not VAT registered) paper has no tax line and the right title', () {
      final t = lookupAppLocalizations(const Locale('en'));
      for (final (tpl, title) in [
        ('cafe', t.invTitleBill),
        ('retail', t.invTitleMemo),
        ('ecommerce', t.invTitleInvoice),
      ]) {
        final l = layoutInvoice(_doc(template: tpl, vat: false, due: 10000), InvoicePaper.mm58, t, 'en');
        expect(l.allTexts, contains(title));
        expect(l.allTexts, isNot(contains(t.invMushak)));
        expect(l.ofKind('tax'), isEmpty);
        expect(l.ofKind('qr').length, 2); // thermal stacks: verify, then pay
        expect(l.allTexts, contains(t.invQrPay));
        expect(l.allTexts, contains(tpl == 'ecommerce' ? t.invCod : t.invDue));
      }
    });

    test('cancelled paper is stamped', () {
      final t = lookupAppLocalizations(const Locale('bn'));
      final l = layoutInvoice(_doc(cancelled: true), InvoicePaper.mm80, t, 'bn');
      expect(l.blocks.first.kind, 'cancelled');
      expect(l.blocks.first.texts.first, startsWith(t.invCancelled));
    });

    test('long invoices: thermal grows, A4 paginates', () {
      final t = lookupAppLocalizations(const Locale('en'));
      final short = layoutInvoice(_doc(lines: 3), InvoicePaper.mm80, t, 'en');
      final long = layoutInvoice(_doc(lines: 60), InvoicePaper.mm80, t, 'en');
      expect(long.height, greaterThan(short.height * 3));
      final a4 = layoutInvoice(_doc(lines: 60), InvoicePaper.a4, t, 'en');
      final pages = paginateInvoice(a4);
      expect(pages.length, greaterThanOrEqualTo(2));
      expect(pages.expand((p) => p).length, a4.blocks.length);
      expect(paginateInvoice(layoutInvoice(_doc(), InvoicePaper.a4, t, 'en')).length, 1);
    });
  });

  group('files', () {
    testWidgets('58 mm and 80 mm PDFs are roll-width; A4 is A4; PNG is dot-wide',
        (tester) async {
      final t = lookupAppLocalizations(const Locale('bn'));
      await tester.runAsync(() async {
        final p58 = await buildInvoicePdf(layoutInvoice(_doc(), InvoicePaper.mm58, t, 'bn'), t);
        final s58 = latin1.decode(p58);
        expect(s58.startsWith('%PDF-1.4'), isTrue);
        expect(s58, contains('/MediaBox [0 0 164.41 '));
        expect(s58, contains('/Width 384 '));
        final p80 = latin1.decode(
            await buildInvoicePdf(layoutInvoice(_doc(), InvoicePaper.mm80, t, 'bn'), t));
        expect(p80, contains('/MediaBox [0 0 226.77 '));
        expect(p80, contains('/Width 576 '));
        final a4 = latin1.decode(await buildInvoicePdf(
            layoutInvoice(_doc(lines: 60), InvoicePaper.a4, t, 'bn'), t,
            number: 'S-0041'));
        expect(a4, contains('/MediaBox [0 0 595.28 841.89]'));
        expect(RegExp(r'/Count (\d+)').firstMatch(a4)!.group(1), isNot('1'));
        final png = await buildInvoicePng(layoutInvoice(_doc(), InvoicePaper.mm58, t, 'bn'), t);
        expect(png.sublist(0, 4), Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]));
        // PNG IHDR width = 384
        expect(ByteData.sublistView(png, 16, 20).getUint32(0), 384);
      });
    });
  });

  group('screens', () {
    testWidgets('invoice screen: paper + language switch, share buttons, 48 dp', (tester) async {
      final t = await _pump(tester, InvoiceScreen(initial: fakeSaleInvoice()), _InvApi());
      expect(find.byKey(const ValueKey('inv-share-pdf')), findsOneWidget);
      expect(find.byKey(const ValueKey('inv-share-png')), findsOneWidget);
      // settings say 80 mm + bn
      expect(find.byKey(const ValueKey('inv-paper-80-bn')), findsOneWidget);
      await tester.tap(find.text(t.invPaperA4));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inv-paper-a4-bn')), findsOneWidget);
      expect(find.byKey(const ValueKey('inv-share-png')), findsNothing); // thermal only
      await tester.tap(find.text(t.invLangEn));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inv-paper-a4-en')), findsOneWidget);
      final h = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      h.dispose();
    });

    testWidgets('how-to-print sheet is honest about Bluetooth', (tester) async {
      final t = await _pump(tester, InvoiceScreen(initial: fakeSaleInvoice()), _InvApi());
      await tester.tap(find.byTooltip(t.invPrintHowTitle));
      await tester.pumpAndSettle();
      expect(find.text(t.invPrintHowBody), findsOneWidget);
    });

    testWidgets('hub lists service invoices and shop sales; empty state has a button',
        (tester) async {
      final t = await _pump(tester, const InvoicesScreen(businessId: 1), _InvApi());
      expect(find.textContaining('ABC Traders Ltd'), findsOneWidget);
      expect(find.textContaining('Karim Mia'), findsOneWidget);
      expect(find.byKey(const ValueKey('inv-new')), findsOneWidget);
      final e = await _pump(
          tester, const InvoicesScreen(businessId: 1), FakeApi(mode: FakeMode.empty, lang: 'en'));
      expect(find.text(e.invHubEmptyTitle), findsOneWidget);
      expect(find.text(t.invHubNew), findsOneWidget);
    });

    testWidgets('settings: VAT on needs a BIN before saving', (tester) async {
      final api = _InvApi();
      final t = await _pump(tester, const InvoiceSettingsScreen(businessId: 1), api);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-vat-exclusive')), 200,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-vat-exclusive')));
      await tester.pumpAndSettle();
      final bin = find.widgetWithText(TextField, t.invSetBin);
      await tester.scrollUntilVisible(bin, 200, scrollable: list);
      await tester.enterText(bin, '');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-set-save')), 300,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-set-save')));
      await tester.pumpAndSettle();
      expect(api.posts.containsKey('/business/invoice/settings'), isFalse);
      expect(find.text(t.invSetFixFields), findsOneWidget);
      await tester.scrollUntilVisible(bin, -200, scrollable: list);
      await tester.enterText(bin, '000123456-0101');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-set-save')), 300,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-set-save')));
      await tester.pumpAndSettle();
      expect(api.posts['/business/invoice/settings']!['vat_mode'], 'exclusive');
      expect(api.posts['/business/invoice/settings']!['vat_bp'], 1500);
      expect(api.posts['/business/invoice/settings']!['bin'], '000123456-0101');
    });

    testWidgets('new service invoice: name needed', (tester) async {
      final t = await _pump(tester, const NewInvoiceScreen(businessId: 1), _InvApi());
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-create')), 300,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-create')));
      await tester.pump();
      expect(find.text(t.invNeedClient), findsOneWidget);
    });

    testWidgets('new service invoice posts lines in poisha (Bangla digits typed)',
        (tester) async {
      final api = _InvApi();
      await _pump(tester, const NewInvoiceScreen(businessId: 1), api);
      final list = find.byType(Scrollable).first;
      await tester.enterText(find.byKey(const ValueKey('inv-client-name')), 'ABC Ltd');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-line-desc-0')), 200,
          scrollable: list);
      await tester.enterText(find.byKey(const ValueKey('inv-line-desc-0')), 'Consultation');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-line-unit-0')), 200,
          scrollable: list);
      await tester.enterText(
          find.byKey(const ValueKey('inv-line-unit-0')), '\u09EB\u09E6\u09E6\u09E6');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-create')), 300,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-create')));
      await tester.pumpAndSettle();
      final body = api.posts['/business/invoices']!;
      expect((body['buyer'] as Map)['name'], 'ABC Ltd');
      expect(body['lines'], [
        {'desc': 'Consultation', 'qty': 1, 'unit': 500000}
      ]);
      // opens the paper
      expect(find.byKey(const ValueKey('inv-share-pdf')), findsOneWidget);
    });
  });
}
