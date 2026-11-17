// gap-bizai (17 Nov) — Business AI gaps a shop owner would notice:
//  * P0: a customer who said STOP gets no path from the CRM (the free
//    WhatsApp / phone-SMS buttons used to stay one tap away); bulk says who
//    was left out;
//  * daily summary: a chase row opens THAT customer's tagada, one button
//    reminds all of them, "will run out" opens the stock list;
//  * win-back: the owner can write the message in their own words, and the
//    ladder says honestly how many get it in the app (only Assisto users).
// bn + en, 200% font.
import 'package:assisto/bizai/biz_daily_screen.dart';
import 'package:assisto/bizai/winback_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/crm/crm100_api.dart';
import 'package:assisto/screens/crm/crm_bulk_send_screen.dart';
import 'package:assisto/screens/crm/crm_home_screen.dart';
import 'package:assisto/screens/crm/crm_send_sheet.dart';
import 'package:assisto/screens/mktengine/mkt_engine_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bizai2_shots.dart' show FakeWinbackReach, fakeDaily;
import 'fake_api.dart';
import 'fake_crm100.dart';
import 'mktengine_fakes.dart';

class _StopApi extends FakeApi {
  _StopApi({super.lang = 'en'});
  final posts = <String, List<Map<String, dynamic>>>{};

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.putIfAbsent(path.split('?').first, () => []).add(body);
    if (path.startsWith('/crm/send/preview')) {
      return {
        ...crm100Preview(blocked: 'opted_out'),
        'wa_url': '',
        'sms_uri': '',
        'opted_out': true,
      };
    }
    if (path.startsWith('/crm/send/bulk')) {
      return {
        'bulk_id': 'b1',
        'cards': [
          {
            'name': 'Rahela Begum',
            'phone': '01811111111',
            'target': {'phone': '01811111111'},
            'text': 'Rahela Begum, new stock has arrived.',
            'phone_ok': true,
            'wa_url': 'https://wa.me/8801811111111',
            'sms_uri': 'sms:+8801811111111',
            'sms': crm100Preview()['sms'],
          }
        ],
        'skipped': [
          {'target': {'phone': '01712345678'}, 'name': 'Karim Mia', 'reason': 'opted_out'},
          {'target': {'party': 999}, 'reason': 'not_found'},
        ],
        'opted_out': 1,
        'truncated': false,
      };
    }
    return super.postJson(path, body);
  }
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0}) => MaterialApp(
      key: UniqueKey(),
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    );

Future<AppLocalizations> _pumpApi(WidgetTester tester, Widget screen, FakeApi api,
    {String lang = 'en', bool settle = true}) async {
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
  await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(value: s, child: _app(screen, lang: lang)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await _settle(tester, 20);
  }
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  group('P0 STOP in the CRM', () {
    testWidgets('send sheet: STOP customer = note, no WhatsApp / SMS path', (tester) async {
      final api = _StopApi();
      final t = await _pumpApi(
          tester,
          Builder(
              builder: (c) => Scaffold(
                  body: Center(
                      child: FilledButton(
                          onPressed: () => CrmSendSheet.show(c,
                              target: const CustomerTarget(phone: '01712345678'),
                              name: 'Karim Mia',
                              initialText: 'Hello'),
                          child: const Text('open'))))),
          api);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.c100ChooseHow));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gbz-send-optedout')), findsOneWidget);
      await tester.tap(find.text(t.c100WayWa));
      await tester.pumpAndSettle();
      expect(api.posts['/crm/send/log'], isNull); // nothing opened or logged
    });

    testWidgets('bulk: who said STOP is left out and the count is shown', (tester) async {
      final api = _StopApi();
      final t = await _pumpApi(
          tester,
          const CrmBulkSendScreen(customers: [
            {'key': '01712345678', 'phone': '01712345678', 'name': 'Karim Mia'},
            {'key': '01811111111', 'phone': '01811111111', 'name': 'Rahela Begum'},
          ]),
          api);
      await tester.tap(find.text(t.c100BulkMakeCards));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rahela Begum, new stock'), findsOneWidget);
      expect(find.textContaining('Karim Mia, new stock'), findsNothing);
      expect(find.text(t.gbzBulkStopped('1')), findsOneWidget);
      expect(find.text(t.gbzBulkNotFound('1')), findsOneWidget);
    });
  });

  group('daily summary is actionable', () {
    testWidgets('a chase row opens that customer\'s tagada; one button for all',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      final opened = <List<Map<String, dynamic>>>[];
      int? productsFor = -1;
      await tester.pumpWidget(_app(BizDailyScreen(
        businessId: 7,
        load: () async => {...fakeDaily(), 'business_id': 7, 'shop': 'Rahim Store'},
        setOn: (on) async => {'enabled': on},
        openTagada: (biz, parties) {
          expect(biz['id'], 7);
          opened.add(parties);
        },
        openProducts: (id) => productsFor = id,
      )));
      await _settle(tester);
      final t = AppLocalizations.of(tester.element(find.byType(BizDailyScreen)));
      await tester.tap(find.byKey(const ValueKey('gbz-chase-1')));
      await _settle(tester);
      expect(opened.single.single['id'], 1);
      expect(opened.single.single['balance_poisha'], 100000);
      expect(find.text(t.gbzChaseSendOne), findsOneWidget); // one name → "Send the reminder"
      await tester.tap(find.byKey(const ValueKey('bizai2-chase-open')));
      await _settle(tester);
      expect(opened.length, 2);
      final stockBtn = find.byKey(const ValueKey('gbz-stock-open'));
      await tester.scrollUntilVisible(stockBtn, 200);
      await tester.ensureVisible(stockBtn);
      await _settle(tester);
      await tester.tap(stockBtn);
      await _settle(tester);
      expect(productsFor, 7);
    });

    testWidgets('Bangla, 200% font: no overflow on the new rows', (tester) async {
      await tester.pumpWidget(_app(
          BizDailyScreen(
              load: () async => fakeDaily(bn: true), setOn: (on) async => {'enabled': on},
              openTagada: (_, __) {}),
          lang: 'bn',
          scale: 2.0));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('bizai2-chase-open')), 200);
      expect(find.text('তাগাদা পাঠান'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('win-back in the owner\'s words', () {
    testWidgets('edit → own text shown, placeholders kept for the server', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      final f = FakeWinbackReach();
      await tester.pumpWidget(_app(Scaffold(body: WinbackScreen(source: f))));
      await _settle(tester);
      final t = AppLocalizations.of(tester.element(find.byType(WinbackScreen)));
      // honest reach: 2 of 4 use Assisto
      await tester.scrollUntilVisible(find.byKey(const ValueKey('gbz-wb-reach-wb30')), 200);
      expect(find.text(t.gbzWbReach('2', '4')), findsOneWidget);
      final edit = find.byKey(const ValueKey('gbz-wb-edit-wb30'));
      await tester.scrollUntilVisible(edit, 200);
      await tester.ensureVisible(edit);
      await _settle(tester);
      await tester.tap(edit);
      await _settle(tester);
      final field = find.byKey(const ValueKey('gbz-wb-edit-field'));
      expect(tester.widget<TextField>(field).controller!.text, contains(t.bizaiPhName));
      await tester.enterText(field, '${t.bizaiPhName}, come by ${t.bizaiPhShop} this week!');
      await tester.tap(find.byKey(const ValueKey('gbz-wb-edit-save')));
      await _settle(tester);
      expect(find.text('${t.bizaiPhName}, come by ${t.bizaiPhShop} this week!'), findsOneWidget);
      final approve = find.byKey(const ValueKey('bizai-ladder-approve'));
      await tester.scrollUntilVisible(approve, 200);
      await tester.ensureVisible(approve);
      await _settle(tester);
      await tester.tap(approve);
      await _settle(tester);
      final drafts = f.lastApprove!['drafts'] as Map;
      expect((drafts['wb30'] as Map)['en'], '{name}, come by {shop} this week!');
      expect(find.byKey(const ValueKey('gbz-wb-others')), findsOneWidget);
    });
  });

  group('CRM: four daily tabs + More', () {
    testWidgets('four tabs; every other tool opens from More with its title', (tester) async {
      final t = await _pumpApi(tester, const CrmHomeScreen(previewOrg: 1), FakeApi(),
          settle: false);
      expect(find.byType(Tab), findsNWidgets(4));
      await tester.tap(find.byKey(const ValueKey('gbz-crm-more')));
      await _settle(tester, 20);
      expect(find.text(t.gbzCrmMoreSub), findsOneWidget);
      for (final l in [t.crmTabCompanies, t.crmTabReports, t.crmAutomation, t.crmAfterSale]) {
        expect(find.text(l), findsOneWidget);
      }
      await tester.tap(find.text(t.crmTabReports));
      await _settle(tester, 20);
      expect(find.widgetWithText(AppBar, t.crmTabReports), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Prochar: post at the best time', () {
    testWidgets('a post has "remind me" → the server reminder, the answer shown',
        (tester) async {
      final ids = <String>[];
      await _pumpApi(
          tester,
          MktEngineScreen(
              source: FakeMkt('data', false),
              remindPost: (id) async {
                ids.add(id);
                return {'detail': "I'll remind you today, 8 pm — the text and link are in the reminder."};
              }),
          FakeApi(),
          settle: false);
      final btn = find.byKey(const ValueKey('gbz-remind-post1'));
      await tester.scrollUntilVisible(btn, 200, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(btn);
      await _settle(tester);
      await tester.tap(btn);
      await _settle(tester);
      expect(ids, ['post1']);
      expect(find.textContaining("I'll remind you today, 8 pm"), findsOneWidget);
    });
  });
}
