// salesbar — AI sales assistant honest Meta states: no silent dead end while
// Assisto's Meta app is not set up (note + working "website chat" button),
// the App Review limit while review is pending, the comment-reply switch is
// OFF + disabled with the reason until Meta grants comments, and every new
// send error (rate limit, comment rules, STOP, 7-day window) reads as a plain
// sentence. bn + en, 200% text, no overflow.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/bizagent/agent_g1_screens.dart';
import 'package:assisto/screens/business/bizagent/seller_activity_screen.dart';
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
    {String lang = 'en', double scale = 1.0}) async {
  await tester.binding.setSurfaceSize(const Size(360, 7000));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(FakeApi(mode: FakeMode.data, lang: lang), lang),
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
    sbOwnChannels = true;
    sbReview = 'approved';
    sbCommentsGranted = false;
    sbSendError = null;
    sbAuditEmpty = false;
  });

  group('setup: Meta state', () {
    for (final lang in const ['en', 'bn']) {
      testWidgets('$lang: Meta app not set up → reason + working website-chat button',
          (tester) async {
        sbOwnChannels = false;
        final t = await _pump(tester, const SellerSetupScreen(), lang: lang);
        expect(find.text(t.sbMetaNotReady), findsOneWidget);
        expect(find.text(t.baConnectX(t.baChMessenger)), findsNothing);
        final btn = find.byKey(const Key('sbOpenWebsiteChat'));
        expect(btn, findsOneWidget);
        await tester.ensureVisible(btn);
        await tester.tap(btn);
        await _settle(tester);
        expect(find.byType(AgentBehaviourScreen), findsOneWidget);   // not a dead end
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('review pending → honest tester-only limit, connect still offered',
        (tester) async {
      sbReview = 'submitted';
      final t = await _pump(tester, const SellerSetupScreen());
      expect(find.text(t.sbMetaReviewPending), findsOneWidget);
      expect(find.byKey(const Key('sbOpenWebsiteChat')), findsNothing);
      expect(find.byType(OutlinedButton), findsWidgets);
    });

    testWidgets('approved → no review note', (tester) async {
      final t = await _pump(tester, const SellerSetupScreen());
      expect(find.text(t.sbMetaReviewPending), findsNothing);
      expect(find.text(t.sbMetaNotReady), findsNothing);
    });

    testWidgets('bn 200% text: no overflow', (tester) async {
      sbOwnChannels = false;
      await _pump(tester, const SellerSetupScreen(), lang: 'bn', scale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('behaviour: comment replies behind Meta permission', () {
    SwitchListTile commentSwitch(WidgetTester tester, AppLocalizations t) =>
        tester.widget<SwitchListTile>(find.ancestor(
            of: find.text(t.g1CommentTitle), matching: find.byType(SwitchListTile)));

    testWidgets('not granted → OFF + disabled + reason', (tester) async {
      final t = await _pump(tester, const AgentBehaviourScreen());
      final sw = commentSwitch(tester, t);
      expect(sw.value, isFalse);
      expect(sw.onChanged, isNull);
      expect(find.text(t.sbCommentsWaitMeta), findsOneWidget);
    });

    testWidgets('granted → switch works, no reason line', (tester) async {
      sbCommentsGranted = true;
      final t = await _pump(tester, const AgentBehaviourScreen());
      final sw = commentSwitch(tester, t);
      expect(sw.value, isTrue);
      expect(sw.onChanged, isNotNull);
      expect(find.text(t.sbCommentsWaitMeta), findsNothing);
    });
  });

  group('chat: Meta-policy send errors read as sentences', () {
    for (final lang in const ['en', 'bn']) {
      for (final code in const [
        'rate_limited',
        'comment_perm_pending',
        'comment_too_old',
        'comment_already_replied',
        'opted_out',
        'outside_7d_window',
      ]) {
        testWidgets('$lang: $code', (tester) async {
          sbSendError = code;
          final t = await _pump(tester, const SellerChatScreen(threadId: 7), lang: lang);
          final expected = {
            'rate_limited': t.sbRateLimited,
            'comment_perm_pending': t.sbCommentPermPending,
            'comment_too_old': t.sbCommentTooOld,
            'comment_already_replied': t.sbCommentAlreadyReplied,
            'opted_out': t.sbOptedOut,
            'outside_7d_window': t.sbWindowClosed7d,
          }[code]!;
          final box = find.byType(TextField).last;
          await tester.enterText(box, 'hello');
          await tester.pump();
          await tester.tap(find.byIcon(Icons.send_rounded));
          await _settle(tester);
          expect(find.text(expected), findsOneWidget);
          expect(find.textContaining(code), findsNothing);       // never a raw code
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('activity log', () {
    for (final lang in const ['en', 'bn']) {
      testWidgets('$lang: plain labels, unknown actions hidden, chat rows open the chat',
          (tester) async {
        final t = await _pump(tester, const SellerActivityScreen(), lang: lang);
        expect(find.text(t.sbActSettings), findsOneWidget);
        expect(find.text(t.sbActOptOut), findsOneWidget);
        expect(find.text(t.sbActTakeover), findsOneWidget);
        expect(find.text(t.sbActCommentHeld), findsOneWidget);
        expect(find.textContaining('some_future_action'), findsNothing);
        if (lang == 'bn') {
          final ascii = RegExp(r'[0-9]');
          for (final w in tester.widgetList<Text>(find.byType(Text))) {
            expect(ascii.hasMatch(w.data ?? ''), isFalse, reason: w.data);
          }
        }
        await tester.tap(find.text(t.sbActTakeover));
        await _settle(tester);
        expect(find.byType(SellerChatScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('empty: benefit + how-to + working setup button', (tester) async {
      sbAuditEmpty = true;
      final t = await _pump(tester, const SellerActivityScreen());
      expect(find.text(t.sbActivityEmptyTitle), findsOneWidget);
      expect(find.textContaining(t.sbActivityEmptyBenefit), findsOneWidget);
      expect(find.textContaining(t.sbActivityEmptyHow), findsOneWidget);
      await tester.tap(find.text(t.baSetupTitle));
      await _settle(tester);
      expect(find.byType(SellerSetupScreen), findsOneWidget);
    });

    testWidgets('bn 200% text: no overflow', (tester) async {
      await _pump(tester, const SellerActivityScreen(), lang: 'bn', scale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });
}
