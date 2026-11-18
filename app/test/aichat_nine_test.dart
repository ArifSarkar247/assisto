// aichat-nine (board row 1): Assisto AI shows the server's REAL stream —
// guarded sentences appear while the model is still writing — and the final
// `done` text (consult line, money note, a cut tidied to a full sentence)
// always replaces the preview. bn + en.
import 'dart:async';
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

  final ctl = StreamController<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> chatStatus() async =>
      {'ai_available': true, 'reason': null, 'free': []};

  @override
  Future<Map<String, dynamic>> chatCreateSession({String? title}) async =>
      {'id': 78, 'title': ''};

  @override
  Stream<Map<String, dynamic>> chatStream(String sessionId, String text,
          {String? clientId}) =>
      ctl.stream;
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

Widget _app(AppState s, String lang) => ChangeNotifierProvider<AppState>.value(
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
        home: const Scaffold(body: AiChatScreen()),
      ),
    );

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      if (w is SelectableText) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      return false;
    });

Future<void> _settle(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] streamed sentences show at once; the final text replaces the preview',
        (tester) async {
      tester.view.physicalSize = const Size(400 * 3, 860 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final api = _Api(lang: lang);
      await tester.pumpWidget(_app(_stub(api, lang), lang));
      await _settle(tester);
      final first = lang == 'bn' ? 'সংক্ষেপে: আজই শুরু করা যায়।' : 'In short: you can start today.';
      final rest = lang == 'bn' ? '\n১. জায়গা বাছাই করুন।' : '\n1. Pick the spot.';
      final note = lang == 'bn' ? 'টাকার অঙ্কগুলো সাধারণ ধারণা।' : 'The amounts are estimates.';
      await tester.enterText(find.byType(TextField), 'plan');
      await tester.pump();
      await tester.tap(find.byTooltip(lookupAppLocalizations(Locale(lang)).aichatSend));
      await _settle(tester, 3);
      api.ctl.add(ApiClient.chatSseRecord('token', jsonEncode({'chunk': first})));
      await _settle(tester, 3);
      expect(_sees(first), findsWidgets);                 // first words while streaming
      expect(_sees(rest.trim()), findsNothing);
      api.ctl.add(ApiClient.chatSseRecord('token', jsonEncode({'chunk': rest})));
      await _settle(tester, 3);
      expect(_sees(rest.trim()), findsWidgets);
      // the saved answer differs from the preview (a note the server added
      // after the model finished): the done text wins
      api.ctl.add(ApiClient.chatSseRecord('done', jsonEncode({
        'message_id': 501, 'cards': [], 'source': 'ai',
        'text': '$first$rest\n\n$note', 'meta': {'source': 'ai', 'credits': 1, 'balance': 9}})));
      await api.ctl.close();
      await _settle(tester);
      expect(_sees(note), findsWidgets);
      expect(_sees(first), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
