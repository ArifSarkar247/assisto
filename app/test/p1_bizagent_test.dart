// p1-bizagent — widget tests: agent home (plan, honest states, buy hidden
// until the gateway is live), seller setup (channels, catalog check,
// delivery, connect sheet), approval queue (approve / edited / reject) and the
// chat screen (handover switch, AI label, seller composer). bn + en.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/bizagent/approvals_screen.dart';
import 'package:assisto/screens/business/bizagent/seller_agent_screen.dart';
import 'package:assisto/screens/business/bizagent/seller_inbox_screen.dart';
import 'package:assisto/screens/business/bizagent/seller_setup_screen.dart';
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
  await tester.binding.setSurfaceSize(const Size(360, 1800));
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
  });

  testWidgets('agent home: plan, replies left, approvals, buy hidden (gateway off)',
      (tester) async {
    final t = await _pump(tester, const SellerAgentScreen());
    expect(find.text(t.baRepliesLeft(63, 100)), findsOneWidget);
    expect(find.text(t.baApprovalsPending(2)), findsOneWidget);
    expect(find.text(t.baBuyNotReady), findsNothing); // plan active → no note
    expect(find.textContaining('৳1490'), findsNothing); // not purchasable → no buy
    expect(find.text(t.baMetaPendingNote), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agent home first run: no channel → honest note + trial', (tester) async {
    p1Connected = false;
    final t = await _pump(tester, const SellerAgentScreen(), lang: 'bn');
    expect(find.text(t.baNoChannelNote), findsOneWidget);
    expect(find.text(t.baMetaPendingNote), findsOneWidget);
    expect(find.text(t.baBuyNotReady), findsOneWidget);
    // bn label shows Bangla digits (৭ দিন / ১০০টি) — tap by its icon
    await tester.tap(find.byIcon(Icons.rocket_launch_rounded));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.any((e) => e.key == '/bizagent/plan/trial'), isTrue);
  });

  testWidgets('AI switch posts the setting', (tester) async {
    await _pump(tester, const SellerAgentScreen());
    await tester.tap(find.byType(Switch).first);
    await tester.pump(const Duration(milliseconds: 200));
    final post = p1Posts.firstWhere((e) => e.key == '/bizagent/settings');
    expect(post.value['ai_enabled'], isFalse);
  });

  testWidgets('setup: channels with honest error, catalog check, save', (tester) async {
    final t = await _pump(tester, const SellerSetupScreen());
    expect(find.text(t.baConnected), findsWidgets);
    expect(find.text(t.baConnectError('(#100) Invalid OAuth access token')), findsOneWidget);
    expect(find.text(t.baCatalogLine(24, 23, 20)), findsOneWidget);
    expect(find.textContaining('Scarf'), findsOneWidget);
    await tester.tap(find.text(t.baSaveSettings));
    await tester.pump(const Duration(milliseconds: 200));
    final post = p1Posts.firstWhere((e) => e.key == '/bizagent/settings');
    expect(post.value['delivery_inside'], '60');
    expect(post.value['hours'], {'start': '10:00', 'end': '22:00'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('connect sheet validates and sends the token', (tester) async {
    final t = await _pump(tester, const SellerSetupScreen());
    await tester.tap(find.text(t.baConnectX(t.baChMessenger)));
    await tester.pumpAndSettle();
    expect(find.text(t.baStepsPage), findsOneWidget);
    await tester.tap(find.text(t.baConnectCheck));
    await tester.pump();
    expect(find.text(t.baConnectFieldsErr), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, t.baPageId), '1234567');
    await tester.enterText(find.widgetWithText(TextField, t.baAccessToken), 'TOKEN');
    await tester.tap(find.text(t.baConnectCheck));
    await tester.pumpAndSettle();
    final post = p1Posts.firstWhere((e) => e.key == '/bizagent/channels');
    expect(post.value, {'kind': 'messenger', 'external_id': '1234567', 'token': 'TOKEN'});
  });

  testWidgets('approvals: flagged numbers shown; approve, edit, reject', (tester) async {
    final t = await _pump(tester, const ApprovalsScreen());
    expect(find.text(t.baNumbersNotInCatalog('900')), findsOneWidget);
    expect(find.text(t.baRiskRefund), findsOneWidget);
    // approve the second as is
    await tester.tap(find.text(t.baApprove).last);
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/approvals/12/approve');
    expect(p1Posts.last.value.containsKey('text'), isFalse);
    // edit the first → "send edited"
    await tester.enterText(find.byType(TextField).first, 'The panjabi is ৳1200.');
    await tester.pump();
    await tester.tap(find.text(t.baSendEdited));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/approvals/11/approve');
    expect(p1Posts.last.value['text'], 'The panjabi is ৳1200.');
    await tester.tap(find.text(t.baReject).first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/approvals/11/reject');
  });

  testWidgets('approvals empty state', (tester) async {
    final t = await _pump(tester, const ApprovalsScreen(), mode: FakeMode.empty);
    expect(find.text(t.baApprovalsEmptyTitle), findsOneWidget);
  });

  testWidgets('chat: AI label, order draft, handover switch, seller send', (tester) async {
    final t = await _pump(tester, const SellerChatScreen(threadId: 5));
    expect(find.text(t.baByAi), findsWidgets);
    expect(find.textContaining('Mirpur 10'), findsWidgets);
    // g1: the per-chat toggle "Let AI reply / I will reply" replaced the switch
    expect(find.text(t.g1LetAiReply), findsOneWidget);
    await tester.tap(find.text(t.g1IWillReply));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/threads/5/mode');
    expect(p1Posts.last.value['mode'], 'human');
    await tester.enterText(find.byType(TextField), 'Ami dekhchi');
    await tester.pump(); // Send enables once there is text
    await tester.tap(find.byTooltip(t.baSend));
    await tester.pump(const Duration(milliseconds: 200));
    expect(p1Posts.last.key, '/bizagent/threads/5/send');
  });

  testWidgets('inbox lists chats; bn + dark render without overflow', (tester) async {
    final t = await _pump(tester, const SellerInboxScreen(), lang: 'bn', dark: true);
    expect(find.textContaining(t.baHandoverOnShort), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // Strict bn: no ASCII digit may be rendered on any p1 screen in Bangla
  // (counts, amounts, flagged numbers, times, chat text, text fields).
  for (final entry in <String, Widget Function()>{
    'agent home': () => const SellerAgentScreen(),
    'setup': () => const SellerSetupScreen(),
    'approvals': () => const ApprovalsScreen(),
    'inbox': () => const SellerInboxScreen(),
    'chat': () => const SellerChatScreen(threadId: 5),
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
        if (ascii.hasMatch(w.controller.text)) bad.add(w.controller.text);
      }
      expect(bad, isEmpty, reason: 'ASCII digits in bn UI: $bad');
    });
  }
  testWidgets('bn first run: no ASCII digits on agent home', (tester) async {
    p1Connected = false;
    await _pump(tester, const SellerAgentScreen(), lang: 'bn');
    final bad = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
        .where((s) => RegExp(r'[0-9]').hasMatch(s))
        .toList();
    expect(bad, isEmpty, reason: 'ASCII digits in bn UI: $bad');
  });

  testWidgets('load failure is honest with retry', (tester) async {
    final t = await _pump(tester, const SellerAgentScreen(), mode: FakeMode.fail);
    expect(find.text(t.bizLoadFailed), findsOneWidget);
    expect(find.text(t.bizRetry), findsOneWidget);
  });
}
