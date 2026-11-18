// gap-aichat (owner order 17 Nov 10:10, feature gap sweep) — Assisto AI:
//  * a streamed answer cut at its length limit shows the honest hint +
//    Continue (48dp); the tap sends follow=continue (free on the server);
//  * a finished AI answer shows More detail (follow=more);
//  * after the free Continue limit the hint no longer promises "no credits";
//  * Regenerate keeps the new answer's meta (credit line) and, when it
//    fails, the old answer stays on screen;
//  * bn + en, 200% font + dark without overflow.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

class _Api extends FakeApi {
  _Api({String lang = 'en'}) : super(mode: FakeMode.data, lang: lang);

  Map<String, dynamic> meta = {'source': 'ai', 'credits': 2, 'balance': 48,
    'cut': true, 'continue_free': true};
  String answer = 'Step one is done.';
  final extras = <Map<String, Object?>>[];
  final texts = <String>[];
  Object? regenError;

  @override
  Future<Map<String, dynamic>> chatStatus() async =>
      {'ai_available': true, 'reason': null, 'free': []};

  @override
  Future<Map<String, dynamic>> chatCreateSession({String? title}) async =>
      {'id': 77, 'title': ''};

  @override
  Stream<Map<String, dynamic>> chatStream(String sessionId, String text,
      {String? clientId}) async* {
    extras.add(Map.of(chatExtra));
    texts.add(text);
    yield ApiClient.chatSseRecord('token', jsonEncode({'chunk': answer}));
    yield ApiClient.chatSseRecord('done', jsonEncode({
      'message_id': 90 + texts.length, 'cards': [], 'source': 'ai', 'text': answer,
      'meta': meta}));
  }

  @override
  Future<Map<String, dynamic>> chatRegenerate(String sessionId, {String? edit}) async {
    extras.add(Map.of(chatExtra));
    if (regenError != null) throw regenError!;
    return ApiClient.flattenChatReply({
      'message': {'id': 120, 'role': 'assistant', 'text': 'A new version.',
        'meta': {'source': 'ai', 'credits': 1, 'balance': 47}},
      'cards': [],
      'ai_used': true,
    });
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

Widget _app(AppState s, {String lang = 'en', double scale = 1, bool dark = false}) =>
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
        home: const Scaffold(body: AiChatScreen()),
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

Future<void> _ask(WidgetTester tester, String lang, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byTooltip(_tl(lang).aichatSend));
  await _settle(tester);
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] cut answer: hint + Continue sends follow=continue',
        (tester) async {
      await _phone(tester);
      final api = _Api(lang: lang);
      await tester.pumpWidget(_app(_stub(api, lang), lang: lang));
      await _settle(tester);
      await _ask(tester, lang, 'explain');
      final t = _tl(lang);
      expect(find.text(t.gapAichatCutHint), findsOneWidget);
      expect(find.byKey(const ValueKey('aichat_continue')), findsOneWidget);
      expect(find.byKey(const ValueKey('aichat_more')), findsNothing);
      expect(tester.getSize(find.byKey(const ValueKey('aichat_continue'))).height,
          greaterThanOrEqualTo(48));
      expect(api.extras.last.containsKey('follow'), isFalse);

      api.meta = {'source': 'ai', 'credits': 0, 'follow': 'continue'};
      api.answer = 'Step two is done.';
      await _tapKey(tester, 'aichat_continue');
      expect(api.texts.last, t.aiContinue);
      expect(api.extras.last['follow'], 'continue');
      // the continuation is finished -> no Continue, More detail instead
      expect(find.byKey(const ValueKey('aichat_continue')), findsNothing);
      expect(find.byKey(const ValueKey('aichat_more')), findsOneWidget);
      expect(find.text(t.aibarFreeAnswer), findsOneWidget);
    });

    testWidgets('[$lang] finished answer: More detail sends follow=more once',
        (tester) async {
      await _phone(tester);
      final api = _Api(lang: lang)
        ..meta = {'source': 'ai', 'credits': 2, 'balance': 48};
      await tester.pumpWidget(_app(_stub(api, lang), lang: lang));
      await _settle(tester);
      await _ask(tester, lang, 'hello');
      expect(find.byKey(const ValueKey('aichat_continue')), findsNothing);
      await _tapKey(tester, 'aichat_more');
      expect(api.texts.last, _tl(lang).aiMoreDetail);
      expect(api.extras.last['follow'], 'more');
      await _ask(tester, lang, 'next question');
      expect(api.extras.last.containsKey('follow'), isFalse); // one turn only
    });
  }

  testWidgets('after the free limit the hint does not promise no credits',
      (tester) async {
    await _phone(tester);
    final api = _Api()
      ..meta = {'source': 'ai', 'credits': 0, 'cut': true, 'continue_free': false};
    await tester.pumpWidget(_app(_stub(api, 'en')));
    await _settle(tester);
    await _ask(tester, 'en', 'explain');
    final t = _tl('en');
    expect(find.text(t.gapAichatCutHintPaid), findsOneWidget);
    expect(find.text(t.gapAichatCutHint), findsNothing);
  });

  testWidgets('regenerate: new answer shows its credit line', (tester) async {
    await _phone(tester);
    final api = _Api()..meta = {'source': 'ai', 'credits': 2, 'balance': 48};
    await tester.pumpWidget(_app(_stub(api, 'en')));
    await _settle(tester);
    await _ask(tester, 'en', 'hello');
    final t = _tl('en');
    final regen = find.text(t.aichatRegenerate);
    await tester.ensureVisible(regen);
    await tester.tap(regen);
    await _settle(tester);
    expect(find.text('A new version.'), findsOneWidget);
    expect(find.text('${t.aibarCreditUsedOne} · ${t.aibarCreditsLeft('47')}'),
        findsOneWidget);
  });

  testWidgets('regenerate fails: the old answer stays', (tester) async {
    await _phone(tester);
    final api = _Api()
      ..meta = {'source': 'ai', 'credits': 2, 'balance': 48}
      ..regenError = ApiException('server', 502);
    await tester.pumpWidget(_app(_stub(api, 'en')));
    await _settle(tester);
    await _ask(tester, 'en', 'hello');
    final regen = find.text(_tl('en').aichatRegenerate);
    await tester.ensureVisible(regen);
    await tester.tap(regen);
    await _settle(tester);
    expect(find.text('Step one is done.'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('200% font${dark ? ' + dark' : ''}: cut hint + Continue fit (bn)',
        (tester) async {
      await _phone(tester);
      final api = _Api(lang: 'bn');
      await tester.pumpWidget(_app(_stub(api, 'bn'), lang: 'bn', scale: 2, dark: dark));
      await _settle(tester);
      await _ask(tester, 'bn', 'ব্যাখ্যা করো');
      expect(find.byKey(const ValueKey('aichat_continue')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
