// amarket (flag assisto_market): Assisto Market v1, app side with a fake
// server. Tabs, empty states with a button, posting a need, the buyer's
// ranked offers (cheapest always shown + marked, the plain-language reason),
// accept -> chat opens, the seller's sealed offer form, seller apply, deals
// (chat / delivered / rate / report), offline + retry, bn + en, dark, 200%.
import 'dart:io' show SocketException;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/connect_flow.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/market/market_need_form.dart';
import 'package:assisto/screens/market/market_need_screen.dart';
import 'package:assisto/screens/market/market_screen.dart';
import 'package:assisto/screens/market/market_widgets.dart';
import 'package:assisto/theme.dart';

import 'market_fake.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
      key: UniqueKey(),
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

class _OfflineSource extends FakeMarketSource {
  bool fail = true;
  @override
  Future<Map<String, dynamic>> overview() async {
    if (fail) throw const SocketException('offline');
    return super.overview();
  }
}

void main() {
  tearDown(() => ConnectFlow.chatOverride = null);

  test('flag is registered OFF and owns the market route; push opens it', () {
    expect(kFeatureDefaults['assisto_market'], isFalse);
    expect(kRouteFeature['market'], 'assisto_market');
    expect(PushRouting.kindMap['market'], 'market');
    expect(PushChannels.byKind['market'], PushChannels.alerts);
  });

  testWidgets('needs tab: data, Bangla digits, COD note', (tester) async {
    final src = FakeMarketSource();
    await tester.pumpWidget(_app(MarketScreen(source: src), lang: 'bn'));
    await _settle(tester);
    expect(find.text('Miniket rice'), findsOneWidget);
    expect(find.textContaining('৪০'), findsWidgets); // total quantity in Bangla digits
    expect(find.text('শুধু ক্যাশ অন ডেলিভারি। কোনো ফি নেই।'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state has a benefit line and a working button', (tester) async {
    final src = FakeMarketSource(empty: true);
    await tester.pumpWidget(_app(MarketScreen(source: src)));
    await _settle(tester);
    expect(find.byKey(const Key('amk-needs-empty')), findsOneWidget);
    await tester.tap(find.text('Post a need'));
    await _settle(tester);
    expect(find.byType(MarketNeedForm), findsOneWidget);
  });

  testWidgets('offline shows retry, retry loads', (tester) async {
    final src = _OfflineSource();
    await tester.pumpWidget(_app(MarketScreen(source: src)));
    await _settle(tester);
    expect(find.text('No internet. Check the connection and try again.'), findsOneWidget);
    src.fail = false;
    await tester.tap(find.text('Try again'));
    await _settle(tester);
    expect(find.text('Miniket rice'), findsOneWidget);
  });

  testWidgets('post a need: validation, then the body sent', (tester) async {
    final src = FakeMarketSource();
    final ov = await src.overview();
    await tester.pumpWidget(_app(MarketNeedForm(source: src, catalogue: ov)));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const Key('amk-f-submit')));
    await tester.tap(find.byKey(const Key('amk-f-submit')));
    await _settle(tester);
    expect(find.byKey(const Key('amk-f-error')), findsOneWidget);
    expect(src.lastNeedBody, isNull);

    await tester.tap(find.byKey(const Key('amk-f-cat')));
    await _settle(tester);
    await tester.tap(find.text('Groceries & food').last);
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('amk-f-title')), 'Miniket rice');
    await tester.enterText(find.byKey(const Key('amk-f-qty')), '25');
    await tester.ensureVisible(find.byKey(const Key('amk-f-area')));
    await tester.tap(find.byKey(const Key('amk-f-area')));
    await _settle(tester);
    await tester.tap(find.text('Mirpur').last);
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const Key('amk-f-group')));
    await tester.tap(find.byKey(const Key('amk-f-group')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const Key('amk-f-submit')));
    await tester.tap(find.byKey(const Key('amk-f-submit')));
    await _settle(tester);
    expect(src.lastNeedBody, isNotNull);
    expect(src.lastNeedBody!['category'], 'grocery');
    expect(src.lastNeedBody!['quantity'], 25);
    expect(src.lastNeedBody!['area'], 'mirpur');
    expect(src.lastNeedBody!['group_open'], isTrue);
    expect(src.lastNeedBody!['deadline_hours'], 72);
  });

  testWidgets('buyer: all offers shown, cheapest marked, accept opens chat', (tester) async {
    final src = FakeMarketSource();
    Map<String, dynamic>? opened;
    ConnectFlow.chatOverride = (ctx, m) async => opened = m;
    await tester.pumpWidget(_app(MarketNeedScreen(source: src, needId: 7)));
    await _settle(tester);
    expect(find.byKey(const Key('amk-summary')), findsOneWidget);
    expect(find.byKey(const Key('amk-bid-11')), findsOneWidget);
    expect(find.byKey(const Key('amk-bid-12')), findsOneWidget);
    expect(find.text('Lowest price'), findsWidgets);
    expect(find.text('Suggested'), findsOneWidget);
    expect(find.textContaining('Karim Traders'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('amk-accept-12')));
    await tester.tap(find.byKey(const Key('amk-accept-12')));
    await _settle(tester);
    expect(find.byKey(const Key('amk-accept-sheet')), findsOneWidget);
    expect(find.textContaining('cash on delivery'), findsWidgets);
    await tester.tap(find.byKey(const Key('amk-accept-yes')));
    await _settle(tester);
    expect(src.calls, contains('accept:7'));
    expect(src.calls, contains('chat:21'));
    expect(opened?['name'], 'Rahim Store');
  });

  testWidgets('seller: sealed offer form sends price, hours, notes', (tester) async {
    final src = FakeMarketSource();
    await tester.pumpWidget(_app(MarketNeedScreen(source: src, needId: 9)));
    await _settle(tester);
    expect(find.byKey(const Key('amk-summary')), findsNothing); // never sees rivals
    expect(find.textContaining('Sealed'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('amk-b-price')), '76');
    await tester.enterText(find.byKey(const Key('amk-b-hours')), '24');
    await _settle(tester);
    expect(find.textContaining('৳3,040'), findsOneWidget); // 76 x 40 kg
    await tester.ensureVisible(find.byKey(const Key('amk-b-send')));
    await tester.tap(find.byKey(const Key('amk-b-send')));
    await _settle(tester);
    expect(src.calls, contains('bid:9'));
  });

  testWidgets('seller tab: no business -> open Business; never applied -> apply', (tester) async {
    final src = FakeMarketSource(sellerStatus: null);
    await tester.pumpWidget(_app(MarketScreen(source: src, initialTab: 2)));
    await _settle(tester);
    expect(find.byKey(const Key('amk-sell-apply')), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('amk-apply-area')));
    await _settle(tester);
    await tester.tap(find.text('Mirpur').last);
    await _settle(tester);
    await tester.tap(find.text('Groceries & food'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('amk-apply-send')));
    await _settle(tester);
    expect(src.calls, contains('apply:mirpur:grocery'));
    expect(find.textContaining('Waiting for the owner'), findsOneWidget);

    final nobiz = FakeMarketSource(sellerStatus: null, hasBusiness: false);
    await tester.pumpWidget(_app(MarketScreen(source: nobiz, initialTab: 2)));
    await _settle(tester);
    expect(find.byKey(const Key('amk-sell-nobiz')), findsOneWidget);
    expect(find.text('Turn on Business'), findsOneWidget);
  });

  testWidgets('deals: COD badge, chat, rate, report', (tester) async {
    final src = FakeMarketSource();
    ConnectFlow.chatOverride = (ctx, m) async {};
    await tester.pumpWidget(_app(MarketScreen(source: src, initialTab: 3)));
    await _settle(tester);
    expect(find.text('Cash on delivery'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('amk-chat-21')));
    await _settle(tester);
    expect(src.calls, contains('chat:21'));
    await tester.ensureVisible(find.text('Rate the seller'));
    await tester.tap(find.text('Rate the seller'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('amk-star-5')));
    await _settle(tester);
    expect(src.calls, contains('deal:rate:22:5'));
    await tester.ensureVisible(find.text('Report / block').first);
    await tester.tap(find.text('Report / block').first);
    await _settle(tester);
    await tester.tap(find.text('Scam or fraud'));
    await _settle(tester);
    expect(src.calls, contains('report:seller:5:scam_fraud'));
  });

  for (final dark in [false, true]) {
    testWidgets('200% text, ${dark ? 'dark' : 'light'}, Bangla: no overflow', (tester) async {
      tester.view.physicalSize = const Size(720, 1520);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      for (final w in <Widget>[
        MarketScreen(source: FakeMarketSource()),
        MarketScreen(source: FakeMarketSource(), initialTab: 3),
        MarketNeedScreen(source: FakeMarketSource(), needId: 7),
        MarketNeedScreen(source: FakeMarketSource(), needId: 9),
      ]) {
        await tester.pumpWidget(_app(w, lang: 'bn', scale: 2.0, dark: dark));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('taka helper uses Bangla digits in Bangla', (tester) async {
    late String bn;
    await tester.pumpWidget(_app(Builder(builder: (ctx) {
      bn = mkTaka(ctx, 123456700);
      return const SizedBox();
    }), lang: 'bn'));
    expect(bn, '৳১,২৩৪,৫৬৭');
  });
}
