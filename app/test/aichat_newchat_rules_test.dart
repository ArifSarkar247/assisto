// aifinal (owner AI chat history order 4 Nov 00:33): Assisto AI opens a NEW
// chat on a cold start or after the user left for another app screen; a
// short trip outside the app keeps the same chat.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/screens/home_v2/assisto_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

final _nav = GlobalKey<NavigatorState>();

Widget _app(Widget home, {String lang = 'en'}) {
  final s = AppState();
  s.api = FakeApi(mode: FakeMode.data, lang: lang);
  s.user = AppUser(
      id: 1, name: 'Rahim', phone: '01700000000', email: '', autonomyLevel: 2,
      language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      navigatorKey: _nav,
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: home,
    ),
  );
}

AgentThreadScreen _thread(WidgetTester t) =>
    t.widget<AgentThreadScreen>(find.byType(AgentThreadScreen));

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'home_session_id': '5'}));

  testWidgets('cold start (screen opened) = a NEW chat, never the old one', (t) async {
    await t.pumpWidget(_app(const AssistoChatScreen()));
    await _settle(t);
    expect(_thread(t).fresh, isTrue);
    expect(_thread(t).sessionId, isNull);
    // starters in the app language + labelled New chat + side panel
    final l10n = AppLocalizations.of(t.element(find.byType(AssistoChatScreen)));
    expect(find.text(l10n.aiStarter1), findsOneWidget);
    expect(find.text(l10n.newChat), findsWidgets);
  });

  testWidgets('left for another app screen and came back = NEW chat', (t) async {
    await t.pumpWidget(_app(const AssistoChatScreen(sessionId: '5')));
    await _settle(t);
    expect(_thread(t).sessionId, '5');
    _nav.currentState!.push(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('My Circle'))));
    await t.pumpAndSettle();
    _nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(_thread(t).sessionId, isNull);
    expect(_thread(t).fresh, isTrue);
  });

  testWidgets('exception: a short trip outside the app keeps the same chat', (t) async {
    await t.pumpWidget(_app(const AssistoChatScreen(sessionId: '5')));
    await _settle(t);
    final before = _thread(t).key;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(t);
    expect(_thread(t).key, before);
    expect(_thread(t).sessionId, '5');
    // a dialog (e.g. a confirm) over the chat is not "leaving" either
    showDialog<void>(context: _nav.currentContext!, builder: (_) => const AlertDialog());
    await t.pumpAndSettle();
    _nav.currentState!.pop();
    await t.pumpAndSettle();
    expect(_thread(t).sessionId, '5');
  });
}
