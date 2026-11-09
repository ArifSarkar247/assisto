// aileft: the HOME chat streams its answer (POST /agent/stream, the Assisto
// AI protocol) and Send becomes Stop while it types out. Stop freezes the
// text where it is and tells the server how much was shown (POST
// /chat/stop) — the server charges only that share. A stream that cannot
// start falls back to POST /agent with the SAME client id.
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
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

class _StreamApi extends FakeApi {
  _StreamApi(this.answer, {this.streamWorks = true, String lang = 'en'})
      : super(mode: FakeMode.data, lang: lang);
  final String answer;
  final bool streamWorks;
  final streamIds = <String?>[];
  final agentIds = <String?>[];
  final stops = <List<Object>>[];

  @override
  Stream<Map<String, dynamic>> agentStream(String text,
      {String? sessionId, String? clientId}) async* {
    streamIds.add(clientId);
    if (!streamWorks) throw ApiException('no stream', 400);
    for (var i = 0; i < answer.length; i += 120) {
      final end = i + 120 > answer.length ? answer.length : i + 120;
      yield ApiClient.chatSseRecord(
          'token', jsonEncode({'chunk': answer.substring(i, end)}));
    }
    yield ApiClient.chatSseRecord('done', jsonEncode({
      'reply': answer, 'text': answer, 'cards': [], 'session_id': '9',
      'message_id': 91, 'ai_used': true, 'credits': 4, 'balance': 40,
    }));
  }

  @override
  Future<Map<String, dynamic>> agent(String text,
      {String? sessionId, String? clientId}) async {
    agentIds.add(clientId);
    return {'reply': answer, 'cards': [], 'session_id': '9', 'message_id': 92,
      'ai_used': true, 'credits': 4, 'balance': 40};
  }

  @override
  Future<Map<String, dynamic>> chatStop(String clientId, int shownChars) async {
    stops.add([clientId, shownChars]);
    return {'stopped': true, 'credits': 0, 'refunded': 4, 'balance': 44};
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

Widget _app(AppState s, {String lang = 'en'}) => ChangeNotifierProvider<AppState>.value(
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
        home: const Scaffold(body: AgentThreadScreen(debugSeed: [])),
      ),
    );

AppLocalizations _tl(String lang) => lookupAppLocalizations(Locale(lang));

Future<void> _pumpFor(WidgetTester tester, int ms) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _type(WidgetTester tester, String lang, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byTooltip(_tl(lang).send));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('home answer streams in and finishes as one answer bubble', (tester) async {
    final api = _StreamApi('Dhaka has many good schools. ' * 8);
    await tester.pumpWidget(_app(_stub(api, 'en')));
    await tester.pump();
    await _type(tester, 'en', 'best schools in Dhaka?');
    await _pumpFor(tester, 2500);
    expect(api.streamIds.length, 1);
    expect(api.agentIds, isEmpty);                        // no second answer
    expect(find.textContaining('Dhaka has many good schools.'), findsWidgets);
    expect(find.byKey(const ValueKey('home-stop')), findsNothing);
    expect(find.byKey(const ValueKey('aibar_credit_line')), findsOneWidget);
  });

  testWidgets('Stop freezes the text and reports how much was shown', (tester) async {
    final long = List.generate(300, (i) => 'word$i').join(' ');   // ~2.3k chars
    final api = _StreamApi(long);
    await tester.pumpWidget(_app(_stub(api, 'en')));
    await tester.pump();
    await _type(tester, 'en', 'write a long essay');
    await _pumpFor(tester, 150);
    final stop = find.byKey(const ValueKey('home-stop'));
    expect(stop, findsOneWidget);
    expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
    await tester.tap(stop);
    await _pumpFor(tester, 500);
    expect(api.stops.length, 1);
    expect(api.stops.first.first, api.streamIds.first);  // the same turn
    final shown = api.stops.first.last as int;
    expect(shown, greaterThan(0));
    expect(shown, lessThan(long.length));
    expect(find.byKey(const ValueKey('aileft_stopped_line')), findsOneWidget);
    expect(find.byTooltip(_tl('en').send), findsOneWidget);  // Send is back
    // nothing more is typed after Stop
    await _pumpFor(tester, 2000);
    expect(find.textContaining('word299'), findsNothing);
  });

  testWidgets('a stream that cannot start falls back with the same client id',
      (tester) async {
    final api = _StreamApi('Fallback answer.', streamWorks: false);
    await tester.pumpWidget(_app(_stub(api, 'bn'), lang: 'bn'));
    await tester.pump();
    await _type(tester, 'bn', 'ঢাকার আবহাওয়া');
    await _pumpFor(tester, 1000);
    expect(api.agentIds, api.streamIds);
    expect(find.textContaining('Fallback answer.'), findsOneWidget);
  });
}
