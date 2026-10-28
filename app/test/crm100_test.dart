// crm100 — CRM to Silicon-Valley standard (owner FINAL ORDER 27 Oct;
// BEST_IN_CLASS_BN.md: "no single customer history page; no quote-accept
// page; can't send from CRM").
//
//  * one customer history page: summary + every source in one timeline,
//    filters, honest empty, offline saved copy / no copy, bn digits;
//  * merged customer list: search, empty, pick → one card per customer;
//  * send sheet: three ways, cost shown first, honest blocked reasons,
//    Assisto SMS only after the confirm;
//  * quote builder: catalog picker, totals, floor hint, below-min error, the
//    body never carries a client price unless typed; quote list states;
//  * bn + en, dark, 200 % font, TalkBack 48 dp.
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/crm/crm100_api.dart';
import 'package:assisto/screens/crm/crm_bulk_send_screen.dart';
import 'package:assisto/screens/crm/crm_send_sheet.dart';
import 'package:assisto/screens/crm/customer_history_screen.dart';
import 'package:assisto/screens/crm/customer_list_screen.dart';
import 'package:assisto/screens/crm/shop_quote_screens.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';
import 'fake_crm100.dart';

class _Api extends FakeApi {
  _Api({super.lang = 'en'});
  bool offline = false;
  bool empty = false;
  String blocked = '';
  final gets = <String>[];
  final posts = <String, List<Map<String, dynamic>>>{};

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (offline && path.startsWith('/crm/')) throw const SocketException('offline');
    if (empty) {
      final e = fakeCrm100Get(path, empty: true);
      if (e != null) return e;
    }
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.putIfAbsent(path.split('?').first, () => []).add(body);
    if (offline && path.startsWith('/crm/')) throw const SocketException('offline');
    if (path.startsWith('/crm/send/preview') && blocked.isNotEmpty) {
      return crm100Preview(blocked: blocked);
    }
    return super.postJson(path, body);
  }
}

Widget _app(Widget child, {String lang = 'en', bool dark = false, double scale = 1}) =>
    MaterialApp(
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
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    );

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, _Api api,
    {String lang = 'en', bool dark = false, double scale = 1,
    Map<String, Object>? prefs}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
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
      value: s, child: _app(screen, lang: lang, dark: dark, scale: scale)));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

Future<void> _talkBack(WidgetTester tester) async {
  final h = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  h.dispose();
}

const _target = CustomerTarget(phone: '01712345678');

void main() {
  group('one customer history page', () {
    testWidgets('summary + every source in one timeline (en)', (tester) async {
      final api = _Api();
      final t = await _pump(tester, const CustomerHistoryScreen(target: _target), api);
      expect(find.text('Karim Mia'), findsWidgets);
      expect(find.text(t.c100StatDue), findsOneWidget);
      expect(find.text('৳850'), findsOneWidget);
      expect(find.text(t.c100OrdersValue('3', '1')), findsOneWidget);
      expect(find.text(t.c100StatCod), findsOneWidget);
      expect(find.text(t.c100StatReturned), findsOneWidget);
      expect(find.text(t.c100StatPayCheck), findsOneWidget);
      expect(find.text(t.c100ActMessage), findsOneWidget);
      expect(find.text(t.c100ActQuote), findsOneWidget);
      // the timeline is lazy: scroll through it
      await tester.scrollUntilVisible(find.text(t.c100KhataGave), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.scrollUntilVisible(find.text(t.c100Sale), 300,
          scrollable: find.byType(Scrollable).first);
      expect(api.gets.first, startsWith('/crm/customers/history/?phone=01712345678'));
    });

    testWidgets('Bangla: Bangla digits and no English words', (tester) async {
      final api = _Api(lang: 'bn');
      final t = await _pump(tester, const CustomerHistoryScreen(target: _target), api,
          lang: 'bn');
      expect(find.text('৳৮৫০'), findsOneWidget);
      expect(find.text(t.c100OrdersValue('৩', '১')), findsOneWidget);
      expect(find.text('০১৭১২৩৪৫৬৭৮'), findsOneWidget);
    });

    testWidgets('filter chip asks the server for that kind only', (tester) async {
      final api = _Api();
      final t = await _pump(tester, const CustomerHistoryScreen(target: _target), api);
      final chip = find.widgetWithText(ChoiceChip, t.c100FOrders);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(api.gets.last, contains('kinds=order%2Cquote'));
    });

    testWidgets('honest empty state for a new number', (tester) async {
      final api = _Api()..empty = true;
      final t = await _pump(tester, const CustomerHistoryScreen(target: _target), api);
      expect(find.text(t.c100EmptyTitle), findsOneWidget);
      expect(find.text(t.c100NoSources), findsOneWidget);
      expect(find.text(t.c100StatDue), findsNothing); // no invented numbers
    });

    testWidgets('offline: the saved copy opens, clearly marked', (tester) async {
      final api = _Api();
      await _pump(tester, const CustomerHistoryScreen(target: _target), api);
      final saved = (await SharedPreferences.getInstance()).getString('crm100_history_v1');
      expect(saved, isNotNull);
      final off = _Api()..offline = true;
      // a NEW screen (fresh state), as after an app restart
      final t = await _pump(tester, CustomerHistoryScreen(key: UniqueKey(), target: _target),
          off, prefs: {'crm100_history_v1': saved!});
      expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget); // saved-copy banner
      expect(find.text(t.c100OfflineTitle), findsNothing); // not the error page
      expect(find.text('৳850'), findsOneWidget);
      expect(find.text(t.c100ActAddCrm), findsNothing);
    });

    testWidgets('offline with no saved copy says so and offers retry', (tester) async {
      final api = _Api()..offline = true;
      final t = await _pump(tester, const CustomerHistoryScreen(target: _target), api);
      expect(find.text(t.c100OfflineTitle), findsOneWidget);
      expect(find.text(t.c100OfflineNoCopy), findsOneWidget);
      expect(find.text(t.retry), findsOneWidget);
    });

    testWidgets('dark + 200% font: no overflow; TalkBack 48 dp', (tester) async {
      final api = _Api();
      await _pump(tester, const CustomerHistoryScreen(target: _target), api,
          dark: true, scale: 2.0);
      expect(tester.takeException(), isNull);
      await _talkBack(tester);
    });

    testWidgets('describeItem: every kind has words, never a raw code', (tester) async {
      final api = _Api();
      await _pump(tester, const CustomerHistoryScreen(target: _target), api);
      final ctx = tester.element(find.byType(CustomerHistoryScreen));
      final t = AppLocalizations.of(ctx);
      for (final it in crm100Items()) {
        final v = describeItem(ctx, t, it);
        expect(v.title, isNot(it['kind']));
        expect(v.title.isNotEmpty, isTrue);
      }
      final ord = describeItem(ctx, t, crm100Items()[3]);
      expect(ord.subtitle, contains(t.c100PayToCheck));
      expect(ord.subtitle, contains(t.c100PayCod));
      expect(describeItem(ctx, t, crm100Items()[4]).bad, isTrue); // returned
    });
  });

  group('customer list', () {
    testWidgets('one row per person, due in red, search hits the server', (tester) async {
      final api = _Api();
      final t = await _pump(tester, const CustomerListScreen(), api);
      expect(find.text('Karim Mia'), findsOneWidget);
      expect(find.text('Rahela Begum'), findsOneWidget);
      expect(find.text(t.c100CountLine('3')), findsOneWidget);
      expect(find.text('৳850'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'kar');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(api.gets.last, contains('q=kar'));
    });

    testWidgets('empty list is honest', (tester) async {
      final api = _Api()..empty = true;
      final t = await _pump(tester, const CustomerListScreen(), api);
      expect(find.text(t.c100NoCustomersTitle), findsOneWidget);
    });

    testWidgets('pick two → one card per customer, nothing sent', (tester) async {
      final api = _Api();
      final t = await _pump(tester, const CustomerListScreen(), api);
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text(t.c100Picked('2')), findsOneWidget);
      await tester.tap(find.text(t.c100MessageEach));
      await tester.pumpAndSettle();
      expect(find.byType(CrmBulkSendScreen), findsOneWidget);
      await tester.tap(find.text(t.c100BulkMakeCards));
      await tester.pumpAndSettle();
      final sent = api.posts['/crm/send/bulk']!.single;
      expect((sent['targets'] as List).length, 2);
      expect('${sent['text']}', contains('{name}'));
      expect(find.textContaining('Karim Mia, new stock'), findsOneWidget);
      expect(find.textContaining('Rahela Begum, new stock'), findsOneWidget);
      expect(api.posts['/crm/send/sms'], isNull);
      expect(find.text(t.c100TallyWaiting('2')), findsOneWidget);
    });
  });

  group('send from CRM', () {
    Future<AppLocalizations> open(WidgetTester tester, _Api api, {String lang = 'en'}) async {
      final t = await _pump(
          tester,
          Builder(
              builder: (c) => Scaffold(
                  body: Center(
                      child: FilledButton(
                          onPressed: () => CrmSendSheet.show(c,
                              target: _target, name: 'Karim Mia', initialText: 'Hello'),
                          child: const Text('open'))))),
          api,
          lang: lang);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('three ways, the cost first, send only after confirm', (tester) async {
      final api = _Api();
      final t = await open(tester, api);
      expect(find.text(t.c100NeverAuto), findsOneWidget);
      await tester.tap(find.text(t.c100ChooseHow));
      await tester.pumpAndSettle();
      expect(find.text(t.c100WayWa), findsOneWidget);
      expect(find.text(t.c100WaySms), findsOneWidget);
      expect(find.text(t.c100WayAssistoCost('1', '40', '1')), findsOneWidget);
      expect(api.posts['/crm/send/sms'], isNull);
      await tester.tap(find.text(t.c100WayAssisto));
      await tester.pumpAndSettle();
      expect(find.text(t.c100SmsConfirmBody('Karim Mia', '1', '40')), findsOneWidget);
      await tester.tap(find.text(t.cancel).last);
      await tester.pumpAndSettle();
      expect(api.posts['/crm/send/sms'], isNull);
      await tester.tap(find.text(t.c100WayAssisto));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.c100SmsSend));
      await tester.pumpAndSettle();
      expect(api.posts['/crm/send/sms']!.single['credits'], 1);
      expect(find.text(t.c100SmsSent('1', '39')), findsOneWidget);
    });

    for (final (why, text) in [
      ('quiet_hours', (AppLocalizations t) => t.c100SmsQuiet),
      ('opted_out', (AppLocalizations t) => t.c100SmsOptedOut),
      ('sms_not_configured', (AppLocalizations t) => t.c100SmsNoGateway),
      ('owner_only', (AppLocalizations t) => t.c100SmsOwnerOnly),
    ]) {
      testWidgets('blocked $why is explained, never hidden', (tester) async {
        final api = _Api()..blocked = why;
        final t = await open(tester, api);
        await tester.tap(find.text(t.c100ChooseHow));
        await tester.pumpAndSettle();
        expect(find.text(text(t)), findsOneWidget);
        await tester.tap(find.text(t.c100WayAssisto));
        await tester.pumpAndSettle();
        expect(find.text(t.c100SmsConfirmTitle), findsNothing); // disabled
      });
    }

    testWidgets('a WhatsApp app that will not open is said honestly', (tester) async {
      final api = _Api();
      final t = await open(tester, api);
      await tester.tap(find.text(t.c100ChooseHow));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.c100WayWa));
      await tester.pumpAndSettle();
      // the test binding has no WhatsApp: whichever way the launcher answers,
      // the sheet says what really happened, and only an opened app is logged
      final opened = find.text(t.c100OpenedWa).evaluate().isNotEmpty;
      if (opened) {
        expect(api.posts['/crm/send/log']!.single['channel'], 'whatsapp_link');
      } else {
        expect(find.text(t.c100CantOpen), findsOneWidget);
        expect(api.posts['/crm/send/log'], isNull);
      }
    });

    testWidgets('offline preview is honest (bn)', (tester) async {
      final api = _Api(lang: 'bn')..offline = true;
      final t = await open(tester, api, lang: 'bn');
      await tester.tap(find.text(t.c100ChooseHow));
      await tester.pumpAndSettle();
      expect(find.text(t.c100Offline), findsOneWidget);
    });
  });

  group('price quotes', () {
    testWidgets('builder: catalog pick, totals, floor hint, no client price', (tester) async {
      final api = _Api();
      final t = await _pump(
          tester,
          const ShopQuoteBuilderScreen(customerName: 'Karim Mia', customerPhone: '01712345678'),
          api);
      await tester.tap(find.text(t.c100AddProduct));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Red saree'));
      await tester.pumpAndSettle();
      expect(find.text(t.c100Lowest('৳1,200')), findsOneWidget);
      await tester.tap(find.byTooltip(t.c100QtyMore));
      await tester.pumpAndSettle();
      expect(find.text('৳3,000'), findsWidgets);
      expect(find.text(t.c100MaxDiscount('৳600')), findsOneWidget);
      // a typed price below the floor is flagged before the server says no
      await tester.enterText(find.widgetWithText(TextField, t.c100UnitPrice), '1000');
      await tester.pumpAndSettle();
      expect(find.text(t.c100BelowMin), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, t.c100UnitPrice), '');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(t.c100MakeLink), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text(t.c100MakeLink));
      await tester.pumpAndSettle();
      final body = api.posts['/crm/shop-quotes/']!.single;
      final line = (body['items'] as List).single as Map;
      expect(line['qty'], 2);
      expect(line.containsKey('unit_price'), isFalse);
      expect(body['valid_days'], 3);
      expect(body['payment'], 'cod');
      // the share sheet opens with the link
      expect(find.text('https://lifeassisto.com/q/abc.sig'), findsOneWidget);
      expect(find.text(t.c100ShareToCustomer), findsOneWidget);
    });

    testWidgets('builder with nothing picked says so', (tester) async {
      final api = _Api();
      final t = await _pump(tester, const ShopQuoteBuilderScreen(), api);
      await tester.scrollUntilVisible(find.text(t.c100MakeLink), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text(t.c100MakeLink));
      await tester.pumpAndSettle();
      expect(find.text(t.c100PickProduct), findsOneWidget);
      expect(api.posts['/crm/shop-quotes/'], isNull);
    });

    testWidgets('list shows honest states (bn)', (tester) async {
      final api = _Api(lang: 'bn');
      final t = await _pump(tester, const ShopQuoteListScreen(), api, lang: 'bn');
      expect(find.text(t.c100QsViewed), findsOneWidget);
      expect(find.text(t.c100QsAccepted), findsOneWidget);
      expect(find.text(t.c100QsExpired), findsOneWidget);
      expect(find.text(t.c100OrderMade('৫২')), findsOneWidget);
      expect(find.text('৳৩,০০০'), findsWidgets);
    });

    testWidgets('empty quote list invites the first quote; TalkBack', (tester) async {
      final api = _Api()..empty = true;
      final t = await _pump(tester, const ShopQuoteListScreen(), api);
      expect(find.text(t.c100NoQuotesTitle), findsOneWidget);
      await _talkBack(tester);
    });
  });

  test('CustomerTarget picks the strongest key', () {
    expect(CustomerTarget.fromRow({'phone_key': '017', 'party_id': 1}).phone, '017');
    expect(CustomerTarget.fromRow({'phone_key': '', 'party_id': 1}).party, 1);
    expect(CustomerTarget.fromRow({'lead_id': 8}).lead, 8);
    expect(const CustomerTarget(party: 3).cacheKey, 'k:3');
  });

  test('ApiException body detail is what the sheet shows', () {
    final e = ApiException('x', 409, null, 'opted_out', {'detail': 'STOP'});
    expect(e.body!['detail'], 'STOP');
  });
}
