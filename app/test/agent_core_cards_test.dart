// agentcore (18 Nov): the agent's proactive cards ("For you") and the user's
// audit trail ("What the agent did") — fake server, no network. A loan due
// tomorrow -> card with the proposed reminder -> Approve / Not now; nothing
// happens without the tap; honest empty / error states; bn digits, dark,
// 200% text with no overflow, 48 dp targets.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/agent_core/agent_core_screen.dart';
import 'package:assisto/screens/agent_core/agent_nudges.dart';
import 'package:assisto/theme.dart';

import 'agent_core_fakes.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
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
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360 * 3, 1800 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Widget _screen(FakeAgentNudges n, {bool bn = false}) =>
    AgentCoreScreen(source: FakeAgentCore('data', bn: bn), nudgeSource: n);

void main() {
  testWidgets('card shows the checked numbers and waits for the tap', (tester) async {
    _phone(tester);
    final n = FakeAgentNudges();
    await tester.pumpWidget(_app(_screen(n)));
    await _settle(tester);
    expect(find.text('For you'), findsOneWidget);
    expect(find.text('Loan repayment due: Karim Bhai'), findsOneWidget);
    expect(find.text('৳1,500 — due in 1 day(s)'), findsOneWidget);
    expect(find.byKey(const ValueKey('ac_nudge_checked_5')), findsOneWidget);
    expect(find.textContaining('Set a reminder?'), findsOneWidget);
    expect(find.byKey(const ValueKey('ac_nudge_approve_41')), findsOneWidget);
    expect(find.byKey(const ValueKey('ac_nudge_reject_41')), findsOneWidget);
    expect(n.calls.where((c) => c.startsWith('decide')), isEmpty); // nothing automatic
  });

  testWidgets('Approve -> reminder set line; activity opens', (tester) async {
    _phone(tester);
    final n = FakeAgentNudges();
    await tester.pumpWidget(_app(_screen(n)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ac_nudge_approve_41')));
    await _settle(tester);
    expect(n.calls, contains('decide:41:approve'));
    expect(find.byKey(const ValueKey('ac_nudge_approve_41')), findsNothing);
    expect(find.textContaining('Reminder set'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ac_nudge_activity_41')));
    await _settle(tester);
    expect(find.text('What the agent did'), findsWidgets);
    expect(find.text('You approved'), findsOneWidget);
  });

  testWidgets('Not now -> nothing was done', (tester) async {
    _phone(tester);
    final n = FakeAgentNudges();
    await tester.pumpWidget(_app(_screen(n)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ac_nudge_reject_41')));
    await _settle(tester);
    expect(n.calls, contains('decide:41:reject'));
    expect(find.text('You said not now — nothing was done.'), findsOneWidget);
  });

  testWidgets('hide calls dismiss', (tester) async {
    _phone(tester);
    final n = FakeAgentNudges();
    await tester.pumpWidget(_app(_screen(n)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('ac_nudge_hide_5')));
    await _settle(tester);
    expect(n.calls, contains('dismiss:5'));
  });

  testWidgets('empty and error states are honest', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_screen(FakeAgentNudges(mode: 'empty'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ac_nudges_empty')), findsOneWidget);
    await tester.pumpWidget(_app(_screen(FakeAgentNudges(mode: 'error'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ac_nudges_error')), findsOneWidget);
    await tester.pumpWidget(_app(AgentActivityScreen(source: FakeAgentNudges(mode: 'empty'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ac_activity_empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('ac_activity_start')), findsOneWidget);
  });

  testWidgets('expired / approved states never show the buttons', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(_screen(FakeAgentNudges(status: 'expired'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ac_nudge_approve_41')), findsNothing);
    expect(find.text('The time passed — nothing was done.'), findsOneWidget);
  });

  for (final v in [
    (lang: 'bn', scale: 2.0, dark: false),
    (lang: 'en', scale: 2.0, dark: true),
    (lang: 'bn', scale: 1.0, dark: true),
  ]) {
    testWidgets('a11y ${v.lang} x${v.scale} dark=${v.dark}: no overflow, 48 dp', (tester) async {
      _phone(tester);
      final h = tester.ensureSemantics();
      await tester.pumpWidget(
          _app(_screen(FakeAgentNudges(bn: v.lang == 'bn'), bn: v.lang == 'bn'),
              lang: v.lang, scale: v.scale, dark: v.dark));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      if (v.lang == 'bn') {
        expect(find.text('আপনার জন্য'), findsOneWidget);
        expect(find.textContaining('আর ১৪ ঘণ্টা'), findsOneWidget); // Bangla digits
      }
      await tester.pumpWidget(_app(AgentActivityScreen(source: FakeAgentNudges(bn: v.lang == 'bn')),
          lang: v.lang, scale: v.scale, dark: v.dark));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      h.dispose();
    });
  }
}
