// g1-bizagent — widget tests for the advanced agent seller screens:
// behaviour (who replies 24/7 / outside hours / off, resume timeout, quiet
// hours, bundle, honest "vision not connected", website widget snippet),
// answers (rules vs AI share, learned FAQ needs approval, has-price flag,
// learn button), report (revenue by agent, AI cost, profit) and the chat
// (per-chat toggle "Let AI reply / I will reply", rule-answer label,
// customer photo label, payment screenshot → owner verifies, TEST courier
// note). bn + en, light + dark, strict Bangla digits.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/bizagent/agent_g1_screens.dart';
import 'package:assisto/screens/business/bizagent/seller_inbox_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'p1_bizagent_fakes.dart';

AppState _state(FakeApi api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Me', phone: '', email: 'me@example.invalid',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Future<AppLocalizations> _pump(WidgetTester tester, Widget home,
    {String lang = 'en', FakeMode mode = FakeMode.data, bool dark = false}) async {
  await tester.binding.setSurfaceSize(const Size(360, 6000));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(FakeApi(mode: mode, lang: lang), lang),
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      home: home,
    ),
  ));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return AppLocalizations.of(tester.element(find.byType(home.runtimeType)));
}

void main() {
  setUp(() {
    p1Posts.clear();
    p1Connected = true;
    g1VisionReady = false;
  });

  testWidgets('behaviour: 24/7 default, mode switch posts, honest key notes, snippet',
      (tester) async {
    final t = await _pump(tester, const AgentBehaviourScreen());
    expect(find.text(t.g1ModeAlways), findsOneWidget);
    expect(find.text(t.g1VisionNotReady), findsOneWidget);   // no vision key on the server
    expect(find.text(t.g1VoiceNotReady), findsOneWidget);
    expect(find.text(t.g1ResumeSub(15)), findsOneWidget);
    expect(find.textContaining('data-key="w_demoKey123"'), findsOneWidget);
    await tester.tap(find.text(t.g1ModeOutside));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/settings');
    expect(p1Posts.last.value, {'ai_mode': 'outside_hours'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('behaviour: resume timeout + bundle rule are sent as numbers', (tester) async {
    final t = await _pump(tester, const AgentBehaviourScreen());
    await tester.enterText(find.widgetWithText(TextField, t.g1ResumeLabel), '5');
    await tester.tap(find.text(t.g1Save).first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.value, {'resume_minutes': 5});
    await tester.enterText(find.widgetWithText(TextField, t.g1BundleQty), '3');
    await tester.enterText(find.widgetWithText(TextField, t.g1BundlePct), '10');
    await tester.ensureVisible(find.text(t.g1Save).at(1));
    await tester.tap(find.text(t.g1Save).at(1));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.value, {
      'bundle_rules': [
        {'min_qty': 3, 'off_pct': 10.0}
      ]
    });
  });

  testWidgets('vision connected → no "not connected" note', (tester) async {
    g1VisionReady = true;
    final t = await _pump(tester, const AgentBehaviourScreen());
    expect(find.text(t.g1VisionNotReady), findsNothing);
    expect(find.text(t.g1VisionSub(6)), findsOneWidget);
  });

  testWidgets('answers: rule share, learned FAQ needs approval, price flag, learn',
      (tester) async {
    final t = await _pump(tester, const AgentAnswersScreen());
    expect(find.text(t.g1RuleShare('78.4')), findsOneWidget);
    expect(find.text(t.g1RuleCounts(512, 141)), findsOneWidget);
    expect(find.text(t.g1FaqSuggested), findsNWidgets(2));
    expect(find.text(t.g1FaqHasPrice), findsOneWidget);
    await tester.tap(find.text(t.g1Approve).first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/faqs/2');
    expect(p1Posts.last.value, {'status': 'approved'});
    await tester.tap(find.text(t.g1FaqLearn));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.any((e) => e.key == '/bizagent/faqs/learn'), isTrue);
  });

  testWidgets('answers empty state', (tester) async {
    final t = await _pump(tester, const AgentAnswersScreen(), mode: FakeMode.empty);
    expect(find.text(t.g1FaqEmpty), findsOneWidget);
  });

  testWidgets('report: revenue by agent, AI cost, profit', (tester) async {
    final t = await _pump(tester, const AgentReportScreen());
    expect(find.text(t.g1ReportByAgent), findsOneWidget);
    expect(find.text('৳31640'), findsOneWidget);
    expect(find.text('৳214'), findsOneWidget);
    expect(find.text('৳8906'), findsOneWidget);
  });

  testWidgets('chat: per-chat toggle, rule label, photo, payment verify, test courier',
      (tester) async {
    final t = await _pump(tester, const SellerChatScreen(threadId: 7));
    expect(find.text(t.g1ByRule), findsWidgets);
    expect(find.text(t.g1PhotoFromCustomer), findsNWidgets(2));
    expect(find.text(t.g1PaymentPendingTitle('41')), findsOneWidget);
    expect(find.text(t.g1CourierTestNote('41', 'TEST-STEADFAST-41')), findsOneWidget);
    await tester.tap(find.text(t.g1IWillReply));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/threads/7/mode');
    expect(p1Posts.last.value, {'mode': 'human'});
    await tester.tap(find.text(t.g1PaymentVerify));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/orders/41/payment');
    expect(p1Posts.last.value, {'status': 'verified'});
  });

  testWidgets('dark + bn render without overflow', (tester) async {
    for (final w in [
      const AgentBehaviourScreen(),
      const AgentAnswersScreen(),
      const AgentReportScreen(),
      const SellerChatScreen(threadId: 7),
    ]) {
      await _pump(tester, w, lang: 'bn', dark: true);
      expect(tester.takeException(), isNull);
    }
  });

  // Strict bn: no ASCII digit in any visible text (the website code snippet
  // is code and stays as is).
  for (final entry in <String, Widget Function()>{
    'behaviour': () => const AgentBehaviourScreen(),
    'answers': () => const AgentAnswersScreen(),
    'report': () => const AgentReportScreen(),
    'chat image→order': () => const SellerChatScreen(threadId: 7),
  }.entries) {
    testWidgets('bn: no ASCII digits on ${entry.key}', (tester) async {
      await _pump(tester, entry.value(), lang: 'bn');
      final ascii = RegExp(r'[0-9]');
      final bad = <String>[];
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        final s = w.data ?? w.textSpan?.toPlainText() ?? '';
        if (ascii.hasMatch(s)) bad.add(s);
      }
      for (final w in tester.widgetList<EditableText>(find.byType(EditableText))) {
        final s = w.controller.text;
        if (ascii.hasMatch(s) && !s.contains('<script')) bad.add(s);
      }
      expect(bad, isEmpty, reason: 'ASCII digits in bn UI: $bad');
    });
  }

  testWidgets('load failure is honest with retry', (tester) async {
    final t = await _pump(tester, const AgentReportScreen(), mode: FakeMode.fail);
    expect(find.text(t.bizLoadFailed), findsOneWidget);
  });
}
