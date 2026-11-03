// invdesign — invoice designs by business type: every template × paper ×
// language (bn / en / both) fits the paper, each design prints its own facts
// (token box, ship-to + COD, IMEI + warranty end date, Mushak-6.3 columns that
// sum exactly, retainer/balance, hours), the honest NBR line, flag-off stays
// classic, logo shrinking, and the screens' new paths.
import 'dart:typed_data';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/invoice/invoice_design.dart';
import 'package:assisto/screens/business/invoice/invoice_doc.dart';
import 'package:assisto/screens/business/invoice/invoice_paper.dart';
import 'package:assisto/screens/business/invoice/invoice_screen.dart';
import 'package:assisto/screens/business/invoice/invoice_settings_screen.dart';
import 'package:assisto/screens/business/invoice/new_invoice_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_fonts.dart';
import 'fake_api.dart';
import 'fake_invoices.dart';

const _styled = InvoiceDesign(styled: true, accent: 'teal');

InvoiceDoc _d(String tpl) => InvoiceDoc.fromJson(fakeDesignInvoice(tpl));

class _Api extends FakeApi {
  _Api() : super(lang: 'en');
  final posts = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    final p = path.split('?').first;
    posts[p] = body;
    if (p == '/business/invoice/settings') return fakeInvoiceSettings();
    if (p == '/business/sales/41/invoice/details') {
      final inv = fakeDesignInvoice('electronics');
      return {
        ...inv,
        'template': body['template'],
        'lines': [
          for (var i = 0; i < (inv['lines'] as List).length; i++)
            {
              ...(inv['lines'] as List)[i] as Map<String, dynamic>,
              ...?((body['lines'] as Map?)?['$i'] as Map<String, dynamic>?),
            }
        ],
      };
    }
    if (p == '/business/invoices') {
      return {...fakeDesignInvoice('service'), 'buyer': body['buyer']};
    }
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
  final bn = lookupAppLocalizations(const Locale('bn'));
  final en = lookupAppLocalizations(const Locale('en'));

  group('every design fits every paper in bn / en / both', () {
    for (final lang in ['bn', 'en', 'both']) {
      for (final paper in InvoicePaper.values) {
        for (final tpl in invoiceTemplates) {
          test('$tpl ${paper.code} $lang', () {
            final l = layoutWithDesign(_d(tpl), paper, lang, design: _styled);
            expect(l.width, paper.widthPx);
            for (final b in l.blocks) {
              expect(b.usedWidth, lessThanOrEqualTo(l.contentWidth + 0.5),
                  reason: '${b.kind} ${b.texts} is wider than the paper');
            }
            final total = invMoney(_d(tpl).calc.total, lang);
            expect(l.allTexts, contains(total));
            if (lang == 'both') {
              expect(l.allTexts, contains('${bn.invTotal} / ${en.invTotal}'));
            }
          });
        }
      }
    }
  });

  group('each design prints its own facts', () {
    test('cafe: big token box, token not repeated in the meta rows', () {
      final l = layoutWithDesign(_d('cafe'), InvoicePaper.mm58, 'bn', design: _styled);
      expect(l.ofKind('token').single.texts, [bn.invXToken, '৪৭']);
      expect(l.ofKind('meta').expand((b) => b.texts), isNot(contains(bn.invXToken)));
      final classic = layoutWithDesign(_d('cafe'), InvoicePaper.mm58, 'bn');
      expect(classic.ofKind('token'), isEmpty);
      expect(classic.allTexts, contains(bn.invXToken));
    });

    test('e-commerce: ship-to box, delivery charge, COD box with the due amount', () {
      final l = layoutWithDesign(_d('ecommerce'), InvoicePaper.mm80, 'en', design: _styled);
      final ship = l.ofKind('ship').single.texts;
      expect(ship, containsAll(['Nusrat Jahan', 'House 12, Road 3, Sector 7, Uttara, Dhaka']));
      expect(ship.last, contains('DT021125ABC7'));
      expect(l.allTexts, contains(en.ivdShipping));
      expect(l.allTexts, contains(invMoney(12000, 'en')));
      expect(l.ofKind('cod').single.texts, [en.invCod, invMoney(247000, 'en')]);
      final paid = InvoiceDoc.fromJson({...fakeDesignInvoice('ecommerce'), 'paid': 247000, 'due': 0});
      final l2 = layoutWithDesign(paid, InvoicePaper.mm80, 'en', design: _styled);
      expect(l2.ofKind('cod').single.texts, [en.ivdPrepaid]);
    });

    test('electronics: serial/IMEI and warranty end date per line', () {
      final l = layoutWithDesign(_d('electronics'), InvoicePaper.a4, 'en', design: _styled);
      final first = l.ofKind('line').first.texts[1];
      expect(first, contains('356938035643809'));
      expect(first, contains(en.ivdWarrantyUntil('12', '02/11/2027')));
      expect(l.allTexts.any((s) => s.contains(en.ivdWarrantyUntil('6', '02/05/2027'))), isTrue);
      expect(l.allTexts, contains(en.invWarrantyKeep));
      // the serial is an identifier — kept in Latin digits on Bangla paper
      final b = layoutWithDesign(_d('electronics'), InvoicePaper.mm80, 'bn', design: _styled);
      expect(b.allTexts.any((s) => s.contains('356938035643809')), isTrue);
      expect(b.allTexts, contains(bn.ivdWarrantyUntil('১২', '০২/১১/২০২৭')));
    });

    test('VAT invoice: Mushak-6.3 columns sum exactly; honest NBR line', () {
      final d = _d('vat_invoice');
      final l = layoutWithDesign(d, InvoicePaper.a4, 'bn', design: _styled);
      final head = l.ofKind('thead').single.texts;
      expect(head, containsAll([bn.ivdColValue, bn.ivdColTotalIncl]));
      expect(head.length, 8);
      final tax = allocateLineTax(d.lines, d.calc);
      expect(tax.fold<int>(0, (a, x) => a + x.vat), d.calc.vat);
      expect(tax.fold<int>(0, (a, x) => a + x.total), d.calc.total);
      expect(l.allTexts, contains(bn.ivdNotNbr));
      expect(l.allTexts, contains(bn.invTitleTax));
      expect(l.allTexts, contains(bn.ivdXVehicle));
      // not VAT-ready: says so, no tax title
      final plain = InvoiceDoc.fromJson({
        ...fakeDesignInvoice('vat_invoice'),
        'calc': {'subtotal': 3800000, 'taxable': 3800000, 'total': 3800000, 'vat_mode': 'none'},
      });
      final p = layoutWithDesign(plain, InvoicePaper.mm80, 'en', design: _styled);
      expect(p.allTexts, contains(en.ivdNotVatRegistered));
      expect(p.allTexts, isNot(contains(en.invTitleTax)));
    });

    test('every tax paper carries the not-NBR line, classic too', () {
      final l = layoutWithDesign(InvoiceDoc.fromJson(fakeSaleInvoice()), InvoicePaper.mm58, 'en');
      expect(l.allTexts, contains(en.ivdNotNbr));
    });

    test('lawyer: retainer received and balance due', () {
      final l = layoutWithDesign(_d('lawyer'), InvoicePaper.a4, 'en', design: _styled);
      expect(l.allTexts, contains(en.ivdRetainerPaid));
      expect(l.allTexts, contains(en.ivdBalanceDue));
      expect(l.allTexts, contains('Title Suit 221/2026'));
      expect(l.allTexts, contains(en.ivdXMatter));
    });

    test('service: hours x rate with fractional hours', () {
      final d = _d('service');
      expect(d.byHours, isTrue);
      expect(d.lines.first.qtyText('en'), '2.5');
      expect(d.lines.first.qtyText('bn'), '২.৫');
      final l = layoutWithDesign(d, InvoicePaper.a4, 'en', design: _styled);
      expect(l.ofKind('thead').single.texts, containsAll([en.ivdHours, en.ivdRatePerHour]));
      expect(l.allTexts, contains(invMoney(375000, 'en')));
    });

    test('accent colours exist for every key and fall back to the brand', () {
      for (final k in invoiceAccents) {
        expect(PrintInk.accents.containsKey(k), isTrue, reason: k);
      }
      expect(PrintInk.accent('nope'), PrintInk.brand);
    });
  });

  group('helpers', () {
    test('addMonths clamps to the month end', () {
      expect(addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
      expect(addMonths(DateTime(2027, 11, 30), 3), DateTime(2028, 2, 29));
      expect(addMonths(DateTime(2026, 11, 2), 12), DateTime(2027, 11, 2));
    });

    test('line tax spread always sums to the totals', () {
      for (final amounts in [
        [1, 1, 1],
        [100, 333, 7],
        [0, 0, 5],
        [999999, 1, 2, 3],
      ]) {
        final lines = [for (final a in amounts) InvoiceLine('x', 1, a, a)];
        const c = InvoiceCalc(taxable: 12345, sd: 77, vat: 1863, vatMode: 'exclusive');
        final s = allocateLineTax(lines, c);
        expect(s.fold<int>(0, (a, x) => a + x.value), 12345);
        expect(s.fold<int>(0, (a, x) => a + x.sd), 77);
        expect(s.fold<int>(0, (a, x) => a + x.vat), 1863);
      }
    });

    test('typed hours accept Bangla digits and halves', () {
      expect(typedHours('১.৫'), 1.5);
      expect(typedHours('2'), 2);
      expect(typedHours('0'), isNull);
      expect(typedHours('x'), isNull);
    });

    test('a big logo is shrunk to <= 256 px and <= 48 KB', () {
      final big = img.Image(width: 1200, height: 600);
      for (var y = 0; y < 600; y++) {
        for (var x = 0; x < 1200; x++) {
          big.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x * y) % 256);
        }
      }
      final out = shrinkLogo(Uint8List.fromList(img.encodePng(big)));
      expect(out, isNotNull);
      expect(out!.length, lessThanOrEqualTo(logoMaxBytes));
      final back = img.decodeImage(out)!;
      expect(back.width, 256);
      expect(shrinkLogo(Uint8List.fromList(const [1, 2, 3])), isNull);
    });
  });

  group('screens (switch on)', () {
    setUp(() => FeatureFlags.instance.debugOverride = {invoiceDesignsFlag: true});
    tearDown(() => FeatureFlags.instance.debugOverride = null);

    testWidgets('preview: design chips, both languages, details sheet saves IMEI', (tester) async {
      final api = _Api();
      final t = await _pump(
          tester, InvoiceScreen(initial: fakeDesignInvoice('electronics'), paper: InvoicePaper.a4), api);
      await tester.tap(find.text(t.ivdLangBoth));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inv-paper-a4-both')), findsOneWidget);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-details')), 200, scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-details')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ivd-serial-1')), 'SN-CHG-77');
      await tester.enterText(find.byKey(const ValueKey('ivd-warranty-1')), '১২');
      await tester.ensureVisible(find.byKey(const ValueKey('ivd-save')));
      await tester.tap(find.byKey(const ValueKey('ivd-save')));
      await tester.pumpAndSettle();
      final body = api.posts['/business/sales/41/invoice/details']!;
      expect(body['template'], 'electronics');
      expect((body['lines'] as Map)['1'], {'serial': 'SN-CHG-77', 'warranty_m': 12});
      // switch the design on the preview
      await tester.ensureVisible(find.byKey(const ValueKey('inv-design-cafe')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inv-design-cafe')));
      await tester.pumpAndSettle();
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('inv-design-cafe')));
      expect(chip.selected, isTrue);
    });

    testWidgets('settings: accent + bilingual are saved', (tester) async {
      final api = _Api();
      final t = await _pump(tester, const InvoiceSettingsScreen(businessId: 1), api);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.byKey(const ValueKey('ivd-accent-maroon')), 200,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('ivd-accent-maroon')));
      await tester.scrollUntilVisible(find.text(t.ivdLangBoth), 200, scrollable: list);
      await tester.tap(find.text(t.ivdLangBoth));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-set-save')), 300,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-set-save')));
      await tester.pumpAndSettle();
      final body = api.posts['/business/invoice/settings']!;
      expect(body['accent'], 'maroon');
      expect(body['lang'], 'both');
      expect(body['logo'], '');
    });

    testWidgets('new invoice: bill by hours sends fractional hours', (tester) async {
      final api = _Api();
      await _pump(tester, const NewInvoiceScreen(businessId: 1), api);
      final list = find.byType(Scrollable).first;
      await tester.enterText(find.byKey(const ValueKey('inv-client-name')), 'Green Grocers');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('ivd-by-hours')), 200,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('ivd-by-hours')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('inv-line-desc-0')), 'Website maintenance');
      await tester.enterText(find.byKey(const ValueKey('inv-line-qty-0')), '2.5');
      await tester.enterText(find.byKey(const ValueKey('inv-line-unit-0')), '1500');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('inv-create')), 300,
          scrollable: list);
      await tester.tap(find.byKey(const ValueKey('inv-create')));
      await tester.pumpAndSettle();
      final body = api.posts['/business/invoices']!;
      expect(body['by_hours'], isTrue);
      expect((body['lines'] as List).first['qty'], 2.5);
      expect((body['lines'] as List).first['unit'], 150000);
    });
  });

  group('screens (switch off = classic)', () {
    testWidgets('no design chips, no both, no details button', (tester) async {
      FeatureFlags.instance.debugOverride = {invoiceDesignsFlag: false};
      addTearDown(() => FeatureFlags.instance.debugOverride = null);
      final t = await _pump(tester, InvoiceScreen(initial: fakeSaleInvoice()), _Api());
      expect(find.text(t.ivdLangBoth), findsNothing);
      expect(find.byKey(const ValueKey('inv-design-cafe')), findsNothing);
      expect(find.byKey(const ValueKey('inv-details')), findsNothing);
    });
  });
}
