// aibar (2 Nov, launch group 6) — AI chat + home chat production states:
//  * a message that did not go out keeps its text in the bubble with the
//    honest reason + a 48dp "Send again"; the resend carries the SAME
//    client id (the server answers / charges / logs it once);
//  * the stream path falls back to /send with the same id; a 409
//    "in progress" is waited for, not shown as a failure;
//  * 429 shows the server's own bn/en sentence;
//  * every keyed-AI answer shows the credits really taken + balance after;
//  * bn + en, Bangla digits, 200% font, dark mode, 48dp.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/ai_turn_meta.dart';

import 'fake_api.dart';

final _cidRe = RegExp(r'^[A-Za-z0-9_\-:.]{8,64}$');

class _Api extends FakeApi {
  _Api({String lang = 'en'}) : super(mode: FakeMode.data, lang: lang);

  /// queued outcomes for the next calls: an Object to throw, or null = ok
  final List<Object?> sendScript = [];
  final List<Object?> agentScript = [];
  final sendIds = <String?>[];
  final streamIds = <String?>[];
  final agentIds = <String?>[];
  bool streamFails = true;
  Map<String, dynamic> meta = {'source': 'ai', 'credits': 2, 'balance': 48};

  @override
  Future<Map<String, dynamic>> chatStatus() async =>
      {'ai_available': true, 'reason': null, 'free': []};

  @override
  Future<Map<String, dynamic>> chatCreateSession({String? title}) async =>
      {'id': 77, 'title': ''};

  @override
  Stream<Map<String, dynamic>> chatStream(String sessionId, String text,
      {String? clientId}) async* {
    streamIds.add(clientId);
    if (streamFails) throw Exception('stream dropped');
    yield ApiClient.chatSseRecord('token', jsonEncode({'chunk': 'Streamed answer.'}));
    yield ApiClient.chatSseRecord('done', jsonEncode({
      'message_id': 90, 'cards': [], 'source': 'ai', 'text': 'Streamed answer.',
      'meta': meta}));
  }

  @override
  Future<Map<String, dynamic>> chatSend(String sessionId, String text,
      {String? clientId}) async {
    sendIds.add(clientId);
    if (sendScript.isNotEmpty) {
      final next = sendScript.removeAt(0);
      if (next != null) throw next;
    }
    return ApiClient.flattenChatReply({
      'message': {'id': 91, 'role': 'assistant', 'text': 'Sent answer.', 'meta': meta},
      'cards': [],
      'ai_used': true,
    });
  }

  @override
  Future<Map<String, dynamic>> agent(String text,
      {String? sessionId, String? clientId}) async {
    agentIds.add(clientId);
    if (agentScript.isNotEmpty) {
      final next = agentScript.removeAt(0);
      if (next != null) throw next;
    }
    return {'reply': 'Paris is the capital of France.', 'cards': [], 'session_id': '5',
      'message_id': 70, 'ai_used': true, 'credits': 1, 'balance': 1234};
  }
}

AppState _stub(ApiClient api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Rahim', phone: '01700000000', email: '', autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(AppState s, Widget child,
        {String lang = 'en', double scale = 1, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: s,
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
        darkTheme: AssistoTheme.dark,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        builder: (ctx, w) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: w!),
        home: Scaffold(body: child),
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

AppLocalizations _tl(String lang) => lookupAppLocalizations(Locale(lang));

Future<void> _phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400 * 3, 860 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> _aiSend(WidgetTester tester, String lang, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byTooltip(_tl(lang).aichatSend));
  await _settle(tester);
}

Future<void> _homeSend(WidgetTester tester, String lang, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byTooltip(_tl(lang).send));
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pure helpers', () {
    test('client ids are unique and match the server pattern', () {
      final a = newChatClientId(), b = newChatClientId();
      expect(a == b, isFalse);
      expect(_cidRe.hasMatch(a), isTrue);
    });

    test('not-sent reasons: 429 server sentence, 5xx our server, else offline', () {
      final t = _tl('bn');
      expect(notSentText(t, ApiException('একটু ধীরে — ৩০ সেকেন্ড পরে', 429)),
          'একটু ধীরে — ৩০ সেকেন্ড পরে');
      expect(notSentText(t, ApiException('x', 502)), t.aibarNotSentServer);
      expect(notSentText(t, Exception('socket')), t.aibarNotSentOffline);
      expect(isTurnInProgress(ApiException('x', 409, null, 'in_progress')), isTrue);
      expect(isRateLimited(ApiException('x', 429)), isTrue);
    });

    test('credit line only on keyed-AI answers', () {
      expect(AiCreditLine.shows({'source': 'ai', 'credits': 2}), isTrue);
      expect(AiCreditLine.shows({'source': 'brain', 'credits': 0}), isFalse);
      expect(AiCreditLine.shows({'source': 'crisis', 'credits': 0}), isFalse);
      expect(AiCreditLine.shows(const {}), isFalse);
    });
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] credit line: credits used + balance, Bangla digits',
        (tester) async {
      await tester.pumpWidget(_app(
          _stub(_Api(lang: lang), lang),
          const Column(children: [
            AiCreditLine({'source': 'ai', 'credits': 2, 'balance': 1480}),
            AiCreditLine({'source': 'ai', 'credits': 0, 'free_quota': true}),
            AiCreditLine({'source': 'ai', 'credits': 0, 'text_cut': true}),
          ]),
          lang: lang));
      final t = _tl(lang);
      final two = lang == 'bn' ? '২' : '2';
      final bal = lang == 'bn' ? '১,৪৮০' : '1,480';
      expect(find.text('${t.aibarCreditsUsed(two)} · ${t.aibarCreditsLeft(bal)}'),
          findsOneWidget);
      expect(find.text(t.aibarFreeQuick), findsOneWidget);
      expect(find.text(t.aibarFreeAnswer), findsOneWidget);
      expect(find.text(t.aibarTextCut), findsOneWidget);
    });

    testWidgets('[$lang] AI chat: send fails -> text kept + Send again -> '
        'same client id, answer with credit line', (tester) async {
      await _phone(tester);
      final api = _Api(lang: lang)..sendScript.add(Exception('offline'));
      await tester.pumpWidget(
          _app(_stub(api, lang), const AiChatScreen(), lang: lang));
      await _settle(tester);
      await _aiSend(tester, lang, 'plan my week');
      final t = _tl(lang);
      expect(find.text('plan my week'), findsOneWidget);          // never lost
      expect(find.text(t.aibarNotSentOffline), findsOneWidget);
      expect(find.byKey(const ValueKey('aibar_send_again')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('aibar_send_again'))).height,
          greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const ValueKey('aibar_send_again')));
      await _settle(tester);
      expect(find.text('Sent answer.'), findsOneWidget);
      expect(find.byKey(const ValueKey('aibar_failed_row')), findsNothing);
      expect(find.byKey(const ValueKey('aibar_credit_line')), findsOneWidget);
      // stream try + /send try, then the retry's stream + /send: ONE id
      final ids = {...api.streamIds, ...api.sendIds};
      expect(ids.length, 1);
      expect(_cidRe.hasMatch(ids.first!), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('AI chat: streamed answer shows its credit line', (tester) async {
    await _phone(tester);
    final api = _Api()..streamFails = false;
    await tester.pumpWidget(_app(_stub(api, 'en'), const AiChatScreen()));
    await _settle(tester);
    await _aiSend(tester, 'en', 'hello');
    expect(find.text('Streamed answer.'), findsOneWidget);
    final t = _tl('en');
    expect(find.text('${t.aibarCreditsUsed('2')} · ${t.aibarCreditsLeft('48')}'),
        findsOneWidget);
    expect(api.sendIds, isEmpty);
  });

  testWidgets('AI chat: 409 in progress is waited for, not a failure',
      (tester) async {
    await _phone(tester);
    final api = _Api()
      ..sendScript.add(ApiException('busy', 409, null, 'in_progress'));
    await tester.pumpWidget(_app(_stub(api, 'en'), const AiChatScreen()));
    await _settle(tester);
    await _aiSend(tester, 'en', 'long question');
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(find.text('Sent answer.'), findsOneWidget);
    expect(find.byKey(const ValueKey('aibar_failed_row')), findsNothing);
    expect(api.sendIds.length, 2);
    expect(api.sendIds.toSet().length, 1);
  });

  testWidgets('AI chat: 429 shows the server sentence', (tester) async {
    await _phone(tester);
    final api = _Api(lang: 'bn')
      ..sendScript.add(ApiException('একটু ধীরে — ৪০ সেকেন্ড পরে আবার পাঠান', 429,
          null, 'rate_limited'));
    await tester.pumpWidget(_app(_stub(api, 'bn'), const AiChatScreen(), lang: 'bn'));
    await _settle(tester);
    await _aiSend(tester, 'bn', 'প্রশ্ন');
    expect(find.textContaining('৪০ সেকেন্ড'), findsOneWidget);
    expect(find.text(_tl('bn').aibarSendAgain), findsOneWidget);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] home chat: failed -> Send again with the same id -> '
        'answer + credit line', (tester) async {
      await _phone(tester);
      final api = _Api(lang: lang)..agentScript.add(ApiException('boom', 503));
      await tester.pumpWidget(_app(
          _stub(api, lang), const AgentThreadScreen(debugSeed: []), lang: lang));
      await _settle(tester);
      await _homeSend(tester, lang, 'capital of France?');
      final t = _tl(lang);
      expect(find.text('capital of France?'), findsOneWidget);
      expect(find.text(t.aibarNotSentServer), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('aibar_send_again')));
      await _settle(tester);
      expect(find.text('Paris is the capital of France.'), findsOneWidget);
      expect(find.byKey(const ValueKey('aibar_credit_line')), findsOneWidget);
      expect(api.agentIds.length, 2);
      expect(api.agentIds.toSet().length, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final dark in [false, true]) {
    testWidgets('200% font${dark ? ' + dark' : ''}: failed row + credit line fit',
        (tester) async {
      await _phone(tester);
      final api = _Api(lang: 'bn')..sendScript.add(Exception('offline'));
      await tester.pumpWidget(_app(_stub(api, 'bn'), const AiChatScreen(),
          lang: 'bn', scale: 2, dark: dark));
      await _settle(tester);
      await _aiSend(tester, 'bn', 'আমার সপ্তাহের পরিকল্পনা');
      expect(find.byKey(const ValueKey('aibar_failed_row')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('aibar_send_again')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('aibar_credit_line')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
