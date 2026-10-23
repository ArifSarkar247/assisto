// P3 — widgets: Assisto cards (reminder accept, shared list ticks), the AI
// sheet's cost-before-run + one-time consent notice + honest out-of-credits
// paywall, ask without chat content, the scam "Why?" sheet, and the stories
// viewer decrypting only my copy.
import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/p3/assisto_card.dart';
import 'package:assisto/p3/assisto_card_view.dart';
import 'package:assisto/p3/assisto_intent.dart';
import 'package:assisto/p3/assisto_sheet.dart';
import 'package:assisto/p3/scam_banner.dart';
import 'package:assisto/p3/scam_guard.dart';
import 'package:assisto/p3/story_crypto.dart';
import 'package:assisto/screens/circle_status_viewer_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiClient {
  _Api({this.runReply});
  final Map<String, dynamic>? runReply;
  final List<Map<String, dynamic>> runs = [];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/circle/assisto/quote') {
      return {
        'actions': {
          'summarize': {'credits': 1, 'needs_consent': true},
          'translate': {'credits': 1, 'needs_consent': true},
          'ask': {'credits': 1, 'needs_consent': false},
        },
        'balance': 7,
        'ai_available': true,
        'max_messages': 80,
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    runs.add(body);
    return runReply ??
        {'ok': true, 'result': '• Rahim brings rice', 'charged': 1, 'balance': 6, '_status': 200};
  }
}

Widget _app(ApiClient api, Widget home) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(id: 1, name: 'Arif', phone: '', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: Scaffold(body: home),
    ),
  );
}

AssistoChatPort _port(List<String> sent, {List<Map<String, String>>? unread}) => AssistoChatPort(
      isGroup: true,
      chatName: 'Family',
      myName: 'Arif',
      memberNames: const ['Rahim', 'Nadia'],
      unread: () => unread ?? const [
            {'from': 'Rahim', 'text': 'I will bring rice'},
            {'from': 'Nadia', 'text': 'Dinner at 8?'},
          ],
      recent: () => const [],
      draft: () => '',
      setDraft: (_) {},
      lastIncoming: () => 'Dinner at 8?',
      send: (pt) async {
        sent.add(pt);
        return true;
      },
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reminder card: others accept with one tap (never silently)', (tester) async {
    final card = reminderCard(
        title: 'Pay electricity bill', at: DateTime(2026, 10, 24, 9), forEveryone: true, by: 'Rahim');
    AssistoCard? accepted;
    await tester.pumpWidget(_app(
        _Api(),
        AssistoCardView(
          card: card,
          mine: false,
          senderName: 'Rahim',
          ledger: CardLedger.fold(const []),
          onAddReminder: (c) async => accepted = c,
        )));
    expect(find.text('Pay electricity bill'), findsOneWidget);
    expect(find.text('For everyone · from Rahim'), findsOneWidget);
    await tester.tap(find.text('Add to my reminders'));
    expect(accepted?.id, card.id);
    // after my ack event the card shows it is in my reminders
    await tester.pumpWidget(_app(
        _Api(),
        AssistoCardView(
          card: card,
          mine: false,
          senderName: 'Rahim',
          ledger: CardLedger.fold([CardEvent(ackCard(card.id, 'Arif'), '', true, DateTime.now())]),
          onAddReminder: (c) async {},
        )));
    expect(find.text('Add to my reminders'), findsNothing);
    expect(find.text('In your reminders'), findsOneWidget);
    expect(find.text('Added by: Arif'), findsOneWidget);
  });

  testWidgets('shopping list card: tick sends an event, ledger shows progress', (tester) async {
    final list = listCard('Bazar', ['Rice', 'Oil', 'Eggs']);
    final ticks = <String>[];
    await tester.pumpWidget(_app(
        _Api(),
        AssistoCardView(
          card: list,
          mine: true,
          senderName: '',
          ledger: CardLedger.fold([
            CardEvent(tickCard(list.id, 1, true, 'Nadia'), 'Nadia', false, DateTime.now()),
          ]),
          onTick: (c, i, on) => ticks.add('$i:$on'),
        )));
    expect(find.text('1 of 3 done'), findsOneWidget);
    expect(find.text('by Nadia'), findsOneWidget);
    await tester.tap(find.text('Rice'));
    await tester.tap(find.text('Oil'));
    expect(ticks, ['0:true', '1:false']);
  });

  testWidgets('summarize: cost shown first, consent notice once, then share card', (tester) async {
    final api = _Api();
    final sent = <String>[];
    await tester.pumpWidget(_app(
        api, AssistoAiSheet(port: _port(sent), action: AssistoAction.summarize)));
    await tester.pumpAndSettle();
    expect(find.textContaining('These 2 unread messages will be sent to Assisto AI'), findsOneWidget);
    expect(find.text('Run · uses 1 credit(s)'), findsOneWidget);
    expect(find.text('You have 7 credits'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('p3-ai-run')));
    await tester.pumpAndSettle();
    // the one-time notice
    expect(find.byKey(const ValueKey('p3-consent')), findsOneWidget);
    expect(find.textContaining('This sends these messages to Assisto AI'), findsOneWidget);
    expect(api.runs, isEmpty, reason: 'nothing leaves before the user agrees');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(api.runs.single['consent'], isTrue);
    expect((api.runs.single['messages'] as List).length, 2);
    expect(find.text('• Rahim brings rice'), findsOneWidget);
    expect(find.textContaining('1 credit(s) used'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('p3-ai-share')));
    await tester.pumpAndSettle();
    final c = decodeCard(sent.single)!;
    expect(c.type, CardType.summary);
    expect(c.str('text'), '• Rahim brings rice');
    expect(cardFallback(sent.single), startsWith('Assisto summary'));
    // the second time there is no dialog (remembered on this phone)
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kP3ConsentKey), isTrue);
  });

  testWidgets('out of credits: honest message + Get credits, nothing charged', (tester) async {
    SharedPreferences.setMockInitialValues({kP3ConsentKey: true});
    final api = _Api(runReply: {'ok': false, 'error': 'credits', 'balance': 0, '_status': 402});
    await tester.pumpWidget(_app(
        api, AssistoAiSheet(port: _port([]), action: AssistoAction.summarize)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p3-ai-run')));
    await tester.pumpAndSettle();
    expect(find.text("You're out of credits for this."), findsOneWidget);
    expect(find.text('Nothing was charged.'), findsOneWidget);
    expect(find.byKey(const ValueKey('p3-get-credits')), findsOneWidget);
  });

  testWidgets('ask sends only the question (no consent dialog, no chat text)', (tester) async {
    final api = _Api(runReply: {'ok': true, 'result': 'Visit the NID office.', 'charged': 1, '_status': 200});
    await tester.pumpWidget(_app(
        api,
        AssistoAiSheet(
            port: _port([]),
            action: AssistoAction.ask,
            intent: const AssistoIntent(AssistoAction.ask, rest: 'How to renew NID?'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('p3-ai-run')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p3-consent')), findsNothing);
    expect(api.runs.single['question'], 'How to renew NID?');
    expect(api.runs.single.containsKey('messages'), isFalse);
    expect(api.runs.single['consent'], isFalse);
  });

  testWidgets('scam banner explains Why? (on-device)', (tester) async {
    final v = checkScam('bhai otp ta dao please');
    await tester.pumpWidget(_app(_Api(), ScamWarningBanner(verdict: v)));
    expect(find.text('Asks for an OTP or PIN'), findsOneWidget);
    await tester.tap(find.text('Why?'));
    await tester.pumpAndSettle();
    expect(find.text('Why Assisto warned you'), findsOneWidget);
    expect(find.textContaining('only on your phone'), findsOneWidget);
  });

  testWidgets('story viewer opens only my sealed copy', (tester) async {
    final e2e = SoftwareE2E();
    final me = e2e.generateIdentity();
    final author = e2e.generateIdentity();
    final per = sealForAudience(e2e: e2e, me: author, myUserId: 5, audience: [
      {'peer_user_id': 1, 'public_key': me.publicKeyB64},
    ], plaintext: StoryContent.encodeText('Reached Sylhet!', 1));
    final mine = (per['1'] as Map).cast<String, dynamic>();
    await tester.pumpWidget(_app(
        _Api(),
        CircleStatusViewerScreen(
          identity: me,
          authorId: 5,
          authorName: 'Rahim',
          authorKey: author.publicKey,
          preloaded: [
            {'id': 1, ...mine, 'scheme': kFallbackScheme, 'sender_key_id': author.keyId, 'kind': 'text',
              'created_at': DateTime.now().toIso8601String()},
            {'id': 2, 'ciphertext': 'AAAA', 'nonce': 'AAAA', 'kind': 'text',
              'created_at': DateTime.now().toIso8601String()},
          ],
        )));
    await tester.pumpAndSettle();
    expect(find.text('Reached Sylhet!'), findsOneWidget);
  });
}
