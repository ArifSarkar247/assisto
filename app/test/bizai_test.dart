// bizai (owner 4 Nov BUSINESS AI REAL IMPACT): the in-app shop chat (honest
// disclosure before the first message, "AI" label on AI replies only, talk
// to a person, photo/voice through seams), My shops (empty state with a
// button, link parsing), the seller's shop-link card and the Business-home
// outcome card (real BDT, empty = benefit + button, hidden on failure).
// bn + en, dark, 200% font.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/bizai/bizai_source.dart';
import 'package:assisto/bizai/cctv_accuracy_screen.dart';
import 'package:assisto/bizai/my_shops_screen.dart';
import 'package:assisto/bizai/outcome_card.dart';
import 'package:assisto/bizai/shop_chat_screen.dart';
import 'package:assisto/bizai/weekly_report_screen.dart';
import 'package:assisto/bizai/winback_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';

import 'bizai_fakes.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    MaterialApp(
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
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(body: home),
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('disclosure shows before the first message; AI label only on AI replies', (tester) async {
    final f = FakeBizai();
    await tester.pumpWidget(_app(ShopChatScreen(code: '12-ab34cd56', source: f)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bizai-disclosure')), findsOneWidget);
    expect(find.textContaining('not end-to-end'), findsOneWidget);
    expect(find.text('Before you chat'), findsOneWidget);
    expect(find.byKey(const ValueKey('bizai-ai-label')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('bizai-input')), 'Panjabi dam koto?');
    await tester.tap(find.byKey(const ValueKey('bizai-send')));
    await _settle(tester);
    expect(f.sent, ['Panjabi dam koto?']);
    expect(find.text('Panjabi: 1200 taka, in stock'), findsOneWidget);
    expect(find.byKey(const ValueKey('bizai-ai-label')), findsOneWidget); // only the AI reply
    // disclosure stays (short form) after the first message
    expect(find.byKey(const ValueKey('bizai-disclosure')), findsOneWidget);
    expect(find.text('Before you chat'), findsNothing);
    final h = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp("shop's AI assistant")), findsOneWidget);
    h.dispose();
  });

  testWidgets('talk to a person: button, then the person banner', (tester) async {
    final f = FakeBizai();
    await tester.pumpWidget(_app(ShopChatScreen(code: '12-ab34cd56', source: f)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bizai-person')));
    await _settle(tester);
    expect(f.person, isTrue);
    expect(find.text('A person from the shop will reply here.'), findsOneWidget);
    expect(find.byKey(const ValueKey('bizai-person')), findsNothing);
  });

  testWidgets('photo and voice go through the seams with their mime', (tester) async {
    final f = FakeBizai();
    await tester.pumpWidget(_app(ShopChatScreen(
        code: '12-ab34cd56', source: f,
        pickPhoto: (_) async => (path: '/tmp/p.jpg', mime: 'image/jpeg'),
        recordVoice: (_) async => (path: '/tmp/v.m4a', mime: 'audio/mp4'))));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bizai-photo')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bizai-voice')));
    await _settle(tester);
    expect(f.files, ['image:image/jpeg', 'audio:audio/mp4']);
    expect(find.text('Photo sent'), findsOneWidget);
  });

  testWidgets('chat off + offline are honest with a button', (tester) async {
    final f = FakeBizai()..chatOk = false;
    await tester.pumpWidget(_app(ShopChatScreen(code: '12-ab34cd56', source: f)));
    await _settle(tester);
    expect(find.text('This shop is not taking chats now'), findsOneWidget);
    expect(find.text('Go back'), findsOneWidget);
    final g = FakeBizai()..fail = true;
    await tester.pumpWidget(_app(ShopChatScreen(code: '12-ab34cd56', source: g)));
    await _settle(tester);
    expect(find.text('Could not open the shop'), findsOneWidget);
  });

  testWidgets('bn: strict Bangla text + digits, 200% font, dark', (tester) async {
    final f = FakeBizai();
    await tester.pumpWidget(_app(ShopChatScreen(code: '12-ab34cd56', source: f),
        lang: 'bn', scale: 2.0, dark: true));
    await _settle(tester);
    expect(find.text('চ্যাট করার আগে জেনে নিন'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('bizai-input')), 'dam?');
    await tester.tap(find.byKey(const ValueKey('bizai-send')));
    await _settle(tester);
    expect(find.textContaining('১২০০'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('shop link parsing', () {
    expect(shopCodeFrom('https://lifeassisto.com/shop/12-ab34cd56'), '12-ab34cd56');
    expect(shopCodeFrom(' 12-ab34cd56 '), '12-ab34cd56');
    expect(shopCodeFrom('https://lifeassisto.com/shop/12-ab34cd56?x=1'), '12-ab34cd56');
    expect(shopCodeFrom('hello'), isNull);
    expect(shopCodeFrom('12-zz'), isNull);
  });

  testWidgets('my shops: empty state = benefit + big button; bad link refused', (tester) async {
    final f = FakeBizai();
    await tester.pumpWidget(_app(MyShopsScreen(source: f)));
    await _settle(tester);
    expect(find.textContaining('the shop\'s AI answers in seconds'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bizai-open-link')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('bizai-link-input')), 'nope');
    await tester.tap(find.text('Open'));
    await _settle(tester);
    expect(find.text('That is not a shop link'), findsOneWidget);
  });

  testWidgets('my shops lists circle shops', (tester) async {
    final f = FakeBizai()
      ..shops = [
        {'code': '12-ab34cd56', 'shop': 'Rupa Fashion', 'last': '', 'circle': true, 'at': null}
      ];
    await tester.pumpWidget(_app(MyShopsScreen(source: f)));
    await _settle(tester);
    expect(find.text('Rupa Fashion'), findsOneWidget);
    expect(find.text('In your My Circle'), findsOneWidget);
  });

  testWidgets('outcome card: real BDT rows; empty = benefit + button; failure = hidden', (tester) async {
    final f = FakeBizai();
    await tester.pumpWidget(_app(OutcomeCard(source: f)));
    await _settle(tester);
    expect(find.text('This week Assisto did for you'), findsOneWidget);
    expect(find.text('৳4,000 this week'), findsOneWidget);
    expect(find.text('Orders the AI took'), findsOneWidget);
    expect(find.text('৳2,700'), findsOneWidget);
    expect(find.text('3 times'), findsOneWidget);
    final e = FakeBizai()..out = {'empty': true, 'total_bdt': '0', 'rows': []};
    await tester.pumpWidget(_app(OutcomeCard(source: e)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bizai-outcome-start')), findsOneWidget);
    final g = FakeBizai()..fail = true;
    await tester.pumpWidget(_app(OutcomeCard(source: g)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bizai-outcome-card')), findsNothing);
  });

  testWidgets('outcome card bn digits', (tester) async {
    await tester.pumpWidget(_app(OutcomeCard(source: FakeBizai()), lang: 'bn'));
    await _settle(tester);
    expect(find.text('এই সপ্তাহে ৳৪,০০০'), findsOneWidget);
  });

  testWidgets('shop link card: share + switches', (tester) async {
    final f = FakeBizai();
    await tester.pumpWidget(_app(SingleChildScrollView(child: ShopLinkCard(source: f))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('bizai-copy-link')), findsOneWidget);
    await tester.tap(find.text('Hold risky cash-on-delivery orders'));
    await _settle(tester);
    expect(f.link['cod_risk_guard'], isFalse);
  });

  testWidgets('win-back: segments, ladder audience, AI rewrite, one-tap approve + pause', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = FakeWinback();
    await tester.pumpWidget(_app(WinbackScreen(source: f)));
    await _settle(tester);
    expect(find.text('6 customers bought in the last 12 months'), findsOneWidget);
    expect(find.text('Silent 30+ days'), findsOneWidget);
    expect(find.textContaining('4 would get it now'), findsOneWidget);
    expect(find.textContaining("(customer's name)"), findsWidgets); // no raw {name}
    expect(find.textContaining('{name}'), findsNothing);
    await tester.tap(find.text('Rewrite with AI').first);
    await _settle(tester);
    expect(f.ai, 1);
    expect(find.textContaining('come back to (your shop) soon'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bizai-ladder-approve')));
    await _settle(tester);
    expect(f.on, isTrue);
    expect(((f.lastApprove!['drafts'] as Map)['wb30'] as Map)['en'],
        '{name}, come back to {shop} soon!');
    expect(find.text('Pause the win-back messages'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bizai-ladder-approve')));
    await _settle(tester);
    expect(f.on, isFalse);
  });

  testWidgets('win-back bn: Bangla digits', (tester) async {
    await tester.pumpWidget(_app(WinbackScreen(source: FakeWinback(bn: true)), lang: 'bn'));
    await _settle(tester);
    expect(find.text('গত ১২ মাসে ৬ জন গ্রাহক কিনেছেন'), findsOneWidget);
  });

  testWidgets('weekly report: lines, plan, posts that sold; empty = how-to', (tester) async {
    await tester.pumpWidget(_app(WeeklyReportScreen(load: () async => fakeWeekly())));
    await _settle(tester);
    expect(find.text('Sales this week: 12, total ৳18500.'), findsOneWidget);
    expect(find.text('Best time to post: 20:00.'), findsOneWidget);
    expect(find.text('Post: Panjabi'), findsOneWidget);
    expect(find.text('5 chats · 2 orders'), findsOneWidget);
    await tester.pumpWidget(_app(WeeklyReportScreen(load: () async => fakeWeekly(empty: true))));
    await _settle(tester);
    expect(find.textContaining('carries its own link and code'), findsOneWidget);
  });

  testWidgets('outcome card names the best post', (tester) async {
    final f = FakeBizai();
    f.out = {...f.out, 'best_post': {'title': 'Post: Panjabi', 'orders': 2, 'bdt': '2400.00'}};
    await tester.pumpWidget(_app(SingleChildScrollView(child: OutcomeCard(source: f))));
    await _settle(tester);
    expect(find.text('Best post: Post: Panjabi — 2 orders, \u09F32,400'), findsOneWidget);
  });

  testWidgets('cctv accuracy: measured, not-enough honesty, live test taps', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final f = FakeCctvAcc();
    await tester.pumpWidget(_app(CctvAccuracyScreen(siteId: 1, source: f)));
    await _settle(tester);
    expect(find.text('Right 80% · Catches 89% · 11 events'), findsOneWidget);
    expect(find.text('Not enough yet'), findsOneWidget);
    expect(find.text('3 alerts not reviewed yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bizai-cam-start')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('bizai-cam-mark-person')));
    await _settle(tester);
    expect(find.text('1 things marked'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bizai-cam-stop')));
    await _settle(tester);
    expect(f.calls, ['start', 'mark:person', 'stop']);
    expect(find.text('Results from 1 tests'), findsOneWidget);
    expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bizai-cam-missed')));
    await _settle(tester);
    expect(f.calls.last, 'missed');
  });
}
