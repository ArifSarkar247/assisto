// sales2 — live seller inbox quality: inbox filters (Needs reply / AI
// handled / Handed to you / All / Unread) with counts, channel labels, the
// first-run empty state (benefit + button + how-to), error state with
// retry, ONE handoff card at the top of a chat with one-tap Take over /
// Give back to AI, and catalog quick replies that FILL the composer (the
// seller still taps Send). bn + en, 200% text without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
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
    {String lang = 'en', FakeMode mode = FakeMode.data, double scale = 1.0,
    Size size = const Size(360, 6000)}) async {
  await tester.binding.setSurfaceSize(size);
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
      theme: AssistoTheme.light,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: home,
    ),
  ));
  await _settle(tester);
  return AppLocalizations.of(tester.element(find.byType(home.runtimeType)));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    p1Posts.clear();
    p1Connected = true;
    s2HandoffOpen = true;
    s2Handover = false;
  });

  group('inbox', () {
    for (final lang in const ['en', 'bn']) {
      testWidgets('$lang: owner filters with counts + channel labels', (tester) async {
        final t = await _pump(tester, const SellerInboxScreen(), lang: lang);
        String n(String s) => lang == 'bn' ? s.replaceAll('1', '১').replaceAll('3', '৩') : s;
        expect(find.text(n(t.bv2FilterAll(3))), findsOneWidget);
        expect(find.text(n(t.s2FilterNeedsReply(1))), findsOneWidget);
        expect(find.text(n(t.s2FilterAiHandled(1))), findsOneWidget);
        expect(find.text(n(t.s2FilterHandedOver(1))), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNWidgets(5));
        expect(find.text(t.baChWhatsapp), findsOneWidget);
        // "AI handled" narrows the list to the agent's chat
        await tester.ensureVisible(find.text(n(t.s2FilterAiHandled(1))));
        await tester.tap(find.text(n(t.s2FilterAiHandled(1))));
        await _settle(tester);
        expect(find.text(t.bv2StatusAgent), findsOneWidget);
        expect(find.text(t.bv2StatusOwner), findsNothing);
        expect(find.text(t.bv2StatusAttention), findsNothing);
        // "Handed to you" → only the owner's chat
        await tester.ensureVisible(find.text(n(t.s2FilterHandedOver(1))));
        await tester.tap(find.text(n(t.s2FilterHandedOver(1))));
        await _settle(tester);
        expect(find.text(t.bv2StatusOwner), findsOneWidget);
        expect(find.text(t.bv2StatusAgent), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('search has a one-tap clear button', (tester) async {
      final t = await _pump(tester, const SellerInboxScreen());
      expect(find.byTooltip(t.s2ClearSearch), findsNothing);
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(find.byTooltip(t.s2ClearSearch), findsOneWidget);
      await tester.tap(find.byTooltip(t.s2ClearSearch));
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(find.byTooltip(t.s2ClearSearch), findsNothing);
    });

    testWidgets('empty first run: benefit + Connect button + how-to → setup', (tester) async {
      p1Connected = false;
      final t = await _pump(tester, const SellerInboxScreen(), mode: FakeMode.empty);
      expect(find.text(t.s2InboxEmptyTitle), findsOneWidget);
      expect(find.textContaining(t.s2InboxEmptyBenefit), findsOneWidget);
      expect(find.textContaining(t.s2InboxEmptyHow), findsOneWidget);
      // the button is live (opens the channel setup screen — no dead end)
      final btn = find.ancestor(of: find.text(t.s2InboxConnect), matching: find.byType(FilledButton));
      expect(tester.widget<FilledButton>(btn).onPressed, isNotNull);
    });

    testWidgets('load failure → honest error with Retry', (tester) async {
      final t = await _pump(tester, const SellerInboxScreen(), mode: FakeMode.fail);
      expect(find.text(t.bizLoadFailed), findsOneWidget);
      expect(find.widgetWithText(FilledButton, t.bizRetry), findsOneWidget);
      await tester.tap(find.text(t.bizRetry));
      await _settle(tester);
      expect(find.text(t.bizLoadFailed), findsOneWidget); // still offline, still honest
      expect(tester.takeException(), isNull);
    });

    testWidgets('200% text: no overflow on the inbox', (tester) async {
      await _pump(tester, const SellerInboxScreen(), lang: 'bn', scale: 2.0,
          size: const Size(360, 740));
      expect(tester.takeException(), isNull);
    });
  });

  group('chat', () {
    testWidgets('ONE handoff card at the top, not repeated per message', (tester) async {
      final t = await _pump(tester, const SellerChatScreen(threadId: 9));
      expect(find.byKey(const ValueKey('s2-handoff-card')), findsOneWidget);
      expect(find.text(t.s2HandoffTitle), findsOneWidget);
      expect(find.text('Why: complaint / unhappy customer · Mood: unhappy'), findsOneWidget);
      expect(find.text(t.baRiskComplaint), findsOneWidget);
      expect(find.text(t.s2HandoffDraftWaiting), findsOneWidget);
      // the handoff card replaces the mode header (never both)
      expect(find.byType(SegmentedButton<String>), findsNothing);
      // above the messages
      final cardY = tester.getTopLeft(find.byKey(const ValueKey('s2-handoff-card'))).dy;
      final msgY = tester.getTopLeft(find.text('Why has the parcel not come yet?').first).dy;
      expect(cardY, lessThan(msgY));
    });

    testWidgets('Take over → mode human; Give back to AI → mode ai, card goes',
        (tester) async {
      final t = await _pump(tester, const SellerChatScreen(threadId: 9));
      await tester.ensureVisible(find.byKey(const ValueKey('s2-take-over')));
      await tester.tap(find.byKey(const ValueKey('s2-take-over')));
      await _settle(tester);
      expect(p1Posts.last.key, '/bizagent/threads/9/mode');
      expect(p1Posts.last.value, {'mode': 'human'});
      // now the seller is replying: Take over is gone, Give back stays
      expect(find.byKey(const ValueKey('s2-take-over')), findsNothing);
      expect(find.text(t.baHandoverOn), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('s2-give-back')));
      await tester.tap(find.byKey(const ValueKey('s2-give-back')));
      await _settle(tester);
      expect(p1Posts.last.key, '/bizagent/threads/9/mode');
      expect(p1Posts.last.value, {'mode': 'ai'});
      expect(find.byKey(const ValueKey('s2-handoff-card')), findsNothing);
      expect(find.byType(SegmentedButton<String>), findsOneWidget);
    });

    testWidgets('quick reply chip fills the composer, never sends', (tester) async {
      final t = await _pump(tester, const SellerChatScreen(threadId: 9));
      expect(find.byKey(const ValueKey('s2-quick-replies')), findsOneWidget);
      expect(find.text(t.s2QrProduct('Cotton panjabi', '1200')), findsOneWidget);
      expect(find.text(t.s2QrProductOut('Jamdani saree')), findsOneWidget);
      expect(find.text(t.s2QrDelivery), findsOneWidget);
      final before = p1Posts.length;
      await tester.ensureVisible(find.text(t.s2QrProduct('Cotton panjabi', '1200')));
      await tester.tap(find.text(t.s2QrProduct('Cotton panjabi', '1200')));
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(const ValueKey('s2-composer')));
      expect(field.controller!.text, startsWith('Cotton panjabi — ৳1200, in stock.'));
      expect(p1Posts.length, before); // nothing was sent
      // Send is live now (it was disabled with an empty box)
      final send = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send_rounded));
      expect(send.onPressed, isNotNull);
      await tester.ensureVisible(find.text(t.s2QrDelivery));
      await tester.tap(find.text(t.s2QrDelivery));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('s2-composer'))).controller!.text,
          'Delivery charge: inside Dhaka ৳60, outside Dhaka ৳120.');
    });

    testWidgets('send disabled until there is text', (tester) async {
      await _pump(tester, const SellerChatScreen(threadId: 9));
      final send = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send_rounded));
      expect(send.onPressed, isNull);
    });

    testWidgets('chat load failure → Retry', (tester) async {
      final t = await _pump(tester, const SellerChatScreen(threadId: 9), mode: FakeMode.fail);
      expect(find.text(t.bizLoadFailed), findsOneWidget);
      expect(find.text(t.bizRetry), findsOneWidget);
      expect(find.byKey(const ValueKey('s2-quick-replies')), findsNothing);
    });

    for (final lang in const ['en', 'bn']) {
      testWidgets('$lang 200% text, small phone: handoff chat has no overflow',
          (tester) async {
        await _pump(tester, const SellerChatScreen(threadId: 9), lang: lang, scale: 2.0,
            size: const Size(360, 740));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('s2-composer')), findsOneWidget);
      });
    }

    testWidgets('bn: no ASCII digits on the handoff chat', (tester) async {
      await _pump(tester, const SellerChatScreen(threadId: 9), lang: 'bn');
      final bad = <String>[];
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        final s = w.data ?? w.textSpan?.toPlainText() ?? '';
        if (RegExp(r'[0-9]').hasMatch(s)) bad.add(s);
      }
      expect(bad, isEmpty, reason: 'ASCII digits in bn UI: $bad');
    });
  });
}
