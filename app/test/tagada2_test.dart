// tagada2 — tagada send order + SMS balance + My Dues (owner order part B).
//
//  * send screen follows the SERVER's per-customer route: Assisto (free) for
//    a verified Assisto user, WhatsApp / own SIM (free) otherwise, Assisto SMS
//    only from balance (else "Low balance — buy SMS"); one reminder a day;
//    blocked customers show only "Not reachable";
//  * SMS balance: plan SMS + pack SMS, packs buyable only when on sale;
//  * My Dues (customer): data / empty / unverified / error, pay steps,
//    block needs a confirm, chat send;
//  * bn + en, TalkBack 48 dp, dark.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/business/khata_chat_screen.dart';
import 'package:assisto/screens/business/sms_balance_screen.dart';
import 'package:assisto/screens/business/tagada_send_screen.dart';
import 'package:assisto/screens/my_dues_screen.dart';
import 'package:assisto/screens/my_dues_shop_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_khata.dart' show fmtPair;
import 'tagada2_fakes.dart';

const _biz = {'id': 1, 'name': 'Rahim Store', 'role': 'owner'};

Widget _app(Widget child, {String lang = 'en', bool dark = false}) =>
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
      home: child,
    );

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, Tg2Api api,
    {String lang = 'en', bool dark = false}) async {
  SharedPreferences.setMockInitialValues({});
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
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

Future<void> _talkBack(WidgetTester tester) async {
  final h = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  h.dispose();
}

Map<String, dynamic> _party(int id, String name, String phone) =>
    {'id': id, 'name': name, 'phone': phone, 'balance_poisha': 150000};

void main() {
  group('send order on the tagada screen', () {
    testWidgets('Assisto user → free in-app send; it goes through the server',
        (tester) async {
      final api = Tg2Api()
        ..reminders = [tg2Rem(1, 'Karim Store', '01712345678', assisto: true)];
      final t = await _pump(tester,
          TagadaSendScreen(business: _biz, parties: [_party(1, 'Karim Store', '01712345678')]),
          api);
      expect(find.text(t.tg2SendAssistoFree), findsOneWidget);
      expect(find.text(t.tg2RouteAssistoNote('Karim Store')), findsOneWidget);
      // never a paid SMS when a free route exists
      expect(find.byKey(const ValueKey('tg2-gw-1')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('tg2-assisto-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tg2-assisto-1')));
      await tester.pumpAndSettle();
      final sent = api.posts['/business/khata/tagada/send/1']!.single;
      expect(sent['channel'], 'assisto');
      expect(sent['business'], 1);
      expect(find.text(t.tg2SentAssisto), findsOneWidget);
    });

    testWidgets('not on Assisto → WhatsApp / own SIM free + invite; WhatsApp claims first',
        (tester) async {
      final api = Tg2Api()..reminders = [tg2Rem(2, 'Salma', '01812345678')];
      final t = await _pump(tester,
          TagadaSendScreen(business: _biz, parties: [_party(2, 'Salma', '01812345678')]),
          api);
      expect(find.text(t.tg2RouteShareNote), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-own-2')), findsOneWidget);
      expect(find.text(t.tg2InviteFree), findsOneWidget);
      expect(find.text(t.tg2GatewayBtn('2')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('tg2-wa-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tg2-wa-2')));
      // the screen then opens WhatsApp (a platform call the test can't
      // finish), so pump a little instead of settling.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(api.posts['/business/khata/tagada/send/2']!.single['channel'], 'whatsapp');
    });

    testWidgets('reminded today → disabled; blocked → only "Not reachable"',
        (tester) async {
      final api = Tg2Api()
        ..reminders = [
          tg2Rem(3, 'Rina', '01912345678', today: true),
          tg2Rem(4, 'Babu', '01612345678', reachable: false),
        ];
      final t = await _pump(
          tester,
          TagadaSendScreen(business: _biz, parties: [
            _party(3, 'Rina', '01912345678'),
            _party(4, 'Babu', '01612345678'),
          ]),
          api);
      expect(find.text(t.tg2AlreadyToday), findsOneWidget);
      final wa = tester.widget<FilledButton>(find.descendant(
          of: find.byKey(const ValueKey('ldg-row-3')),
          matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(wa.onPressed, isNull);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('tg2-unreach-4')), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('tg2-unreach-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-wa-4')), findsNothing);
    });

    testWidgets('not enough SMS balance → "Low balance — buy SMS", never a send',
        (tester) async {
      final api = Tg2Api()
        ..wallet = tg2Wallet(allowance: 1, low: true)
        ..reminders = [tg2Rem(5, 'Moni', '01512345678', parts: 2)];
      final t = await _pump(tester,
          TagadaSendScreen(business: _biz, parties: [_party(5, 'Moni', '01512345678')]),
          api);
      expect(find.byKey(const ValueKey('tg2-buy-5')), findsOneWidget);
      expect(find.text(t.tg2LowBalanceBuy), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-gw-5')), findsNothing);
      expect(find.text(t.tg2SmsBalanceLine('1', '0')), findsOneWidget);
      expect(api.posts['/business/khata/tagada/send/5'], isNull);
    });

    testWidgets('gateway SMS asks first with parts + what is left (bn digits)',
        (tester) async {
      final api = Tg2Api(lang: 'bn')
        ..wallet = tg2Wallet(allowance: 10, pack: 5)
        ..reminders = [tg2Rem(6, 'Kamal', '01312345678', parts: 2)];
      final t = await _pump(tester,
          TagadaSendScreen(business: _biz, parties: [_party(6, 'Kamal', '01312345678')]),
          api, lang: 'bn');
      await tester.ensureVisible(find.byKey(const ValueKey('tg2-gw-6')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tg2-gw-6')));
      await tester.pumpAndSettle();
      expect(find.text(t.tg2SmsConfirmBody('Kamal', '২', '১৩')), findsOneWidget);
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(api.posts['/business/khata/tagada/send/6'], isNull);
      await tester.tap(find.byKey(const ValueKey('tg2-gw-6')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.ldgSmsSendNow));
      await tester.pumpAndSettle();
      expect(api.posts['/business/khata/tagada/send/6']!.single['channel'], 'gateway_sms');
    });
  });

  group('SMS balance', () {
    Map<String, dynamic> bal({bool sale = false, int left = 30, int pack = 0}) => {
          'allowance_total': 30, 'allowance_left': left, 'allowance_month': '2026-10',
          'pack_left': pack, 'parts_left': left + pack, 'low': left + pack < 10,
          'low_threshold': 10, 'ready': true, 'packs_on_sale': sale,
          'packs': [
            {'sku': 'smspack_100', 'parts': 100, 'price_bdt': 149, 'on_sale': sale,
             'play_product_id': 'assisto_sms_100'},
          ],
        };

    testWidgets('packs not yet on sale → honest coming soon, no Buy', (tester) async {
      final api = Tg2Api()..balance = bal();
      final t = await _pump(tester, const SmsBalanceScreen(businessId: 1), api);
      expect(find.text(t.tg2BalTotal('30')), findsOneWidget);
      expect(find.text(t.tg2BalAllowance('30', '30')), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-bal-soon')), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-buy-smspack_100')), findsNothing);
      await _talkBack(tester);
    });

    testWidgets('on sale → Buy; empty balance says it never sends without (dark)',
        (tester) async {
      final api = Tg2Api()..balance = bal(sale: true, left: 0);
      final t = await _pump(tester, const SmsBalanceScreen(businessId: 1), api,
          dark: true);
      expect(find.byKey(const ValueKey('tg2-buy-smspack_100')), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-bal-empty')), findsOneWidget);
      expect(find.text(t.tg2BalEmpty), findsOneWidget);
    });
  });

  group('My Dues (customer)', () {
    Map<String, dynamic> shopRow() => {
          'business_id': 7, 'shop_name': 'Rahim Store', 'balance_poisha': 150000,
          'balance_display': fmtPair(150000), 'status': tg2Pr('বাকি', 'Due'),
          'owes': true, 'last_entry_at': '2026-10-20T10:00:00+06:00',
          'unread': 2, 'muted': false, 'blocked': false,
        };

    testWidgets('lists shops with total and unread', (tester) async {
      final api = Tg2Api()
        ..dues = {
          'verified': true, 'phone_masked': '01712***678',
          'shops': [shopRow()], 'total_display': fmtPair(150000),
        };
      final t = await _pump(tester, const MyDuesScreen(), api);
      expect(find.byKey(const ValueKey('tg2-dues-7')), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-dues-total')), findsOneWidget);
      expect(find.text(t.tg2DuesUnread('2')), findsOneWidget);
      await _talkBack(tester);
    });

    testWidgets('empty, unverified and error states (bn)', (tester) async {
      var api = Tg2Api(lang: 'bn')
        ..dues = {'verified': true, 'shops': const [], 'phone_masked': ''};
      var t = await _pump(tester, const MyDuesScreen(), api, lang: 'bn');
      expect(find.byKey(const ValueKey('tg2-dues-empty')), findsOneWidget);
      expect(find.text(t.tg2DuesEmptyTitle), findsOneWidget);

      api = Tg2Api(lang: 'bn')..dues = {'verified': false, 'shops': const []};
      t = await _pump(tester, const MyDuesScreen(key: ValueKey('u')), api, lang: 'bn');
      expect(find.text(t.tg2DuesUnverifiedTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('tg2-dues-verify')), findsOneWidget);
      expect(find.text(t.tg2VerifyButton), findsOneWidget);

      api = Tg2Api(lang: 'bn')..failDues = true;
      t = await _pump(tester, const MyDuesScreen(key: ValueKey('f')), api, lang: 'bn');
      expect(find.text(t.retry), findsOneWidget);
    });

    testWidgets('shop: pay steps, block asks first, then saves', (tester) async {
      final api = Tg2Api()
        ..shop = {
          'shop': {'id': 7, 'name': 'Rahim Store'},
          'balance_poisha': 150000, 'balance_display': fmtPair(150000),
          'status': tg2Pr('বাকি', 'Due'),
          'entries': [
            {'at': '2026-10-20T10:00:00+06:00', 'kind': 'due',
             'amount_display': fmtPair(200000), 'note': 'rice'},
            {'at': '2026-10-22T10:00:00+06:00', 'kind': 'paid',
             'amount_display': fmtPair(50000), 'note': ''},
          ],
          'pay': {'methods': [
            {'provider': 'bkash', 'number': '01711111111', 'kind': 'personal'},
            {'provider': 'nagad', 'number': '01722222222', 'kind': 'merchant'},
          ]},
          'muted': false, 'blocked': false,
        };
      final t = await _pump(
          tester, const MyDuesShopScreen(businessId: 7, shopName: 'Rahim Store'), api);
      expect(find.byKey(const ValueKey('tg2-pay-bkash')), findsOneWidget);
      expect(find.text(t.tg2PayStepSendMoney), findsOneWidget);
      expect(find.text(t.tg2PayStepMerchantPay), findsOneWidget);
      await tester.scrollUntilVisible(find.text(t.tg2EntryDue), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(t.tg2EntryDue), findsOneWidget);
      await tester.scrollUntilVisible(find.text(t.tg2EntryPaid), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(t.tg2EntryPaid), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('tg2-block')), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const ValueKey('tg2-block')));
      await tester.pumpAndSettle();
      expect(find.text(t.tg2BlockConfirmTitle('Rahim Store')), findsOneWidget);
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(api.posts['/me/dues/7/prefs'], isNull);
      await tester.tap(find.byKey(const ValueKey('tg2-block')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tg2-block-confirm')));
      await tester.pumpAndSettle();
      expect(api.posts['/me/dues/7/prefs']!.single, {'blocked': true});
    });

    testWidgets('chat with the shop sends and shows the message', (tester) async {
      final api = Tg2Api();
      final t = await _pump(
          tester,
          const KhataChatScreen(
              side: ChatSide.customer, businessId: 7, title: 'Rahim Store'),
          api);
      expect(find.text(t.tg2ChatEmpty), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('tg2-chat-input')), 'Paid 500 today');
      await tester.tap(find.byKey(const ValueKey('tg2-chat-send')));
      await tester.pumpAndSettle();
      expect(api.posts['/me/dues/7/chat']!.single['text'], 'Paid 500 today');
      expect(find.text('Paid 500 today'), findsOneWidget);
    });
  });

  test('shop push open:chat carries the ids for the khata chat', () {
    final p = PushPayload.fromData({'kind': 'dues', 'route': 'business/khata',
      'open': 'chat', 'business_id': '1', 'party_id': '9', 'party_name': 'Salma'});
    final kc = PushRouting.khataChatOf(p)!;
    expect((kc.businessId, kc.partyId, kc.name), (1, 9, 'Salma'));
    expect(PushRouting.khataChatOf(PushPayload.fromData(
        {'kind': 'dues', 'route': 'business/khata', 'open': 'chat'})), isNull);
    expect(PushRouting.targetFor(p)?.chatNavRoute, 'khata');
  });

  test('push kind dues opens My Dues', () {
    final p = PushPayload.fromData({'kind': 'dues', 'route': 'my_dues', 'business_id': '7'});
    expect(p.channel, PushChannels.reminders);
    expect(PushRouting.targetFor(p)?.chatNavRoute, 'my_dues');
    final q = PushPayload.fromData({'kind': 'dues'});
    expect(PushRouting.targetFor(q)?.chatNavRoute, 'my_dues');
  });
}
