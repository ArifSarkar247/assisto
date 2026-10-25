// Owner order after build 146: the sidebar no longer carries "New chat" or a
// growing chat list. ONE entry "Assisto AI" opens the chats page (New chat on
// top, every home + AI chat below; search / pin / rename / delete). The home
// "Assisto AI" quick shortcut opens the same page. Also: the voice language is
// automatic — no BN/EN chip on the chat inputs; the override is in Settings.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/state.dart';
import 'package:assisto/models.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/home_screen.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/screens/assisto_chats_screen.dart';
import 'package:assisto/widgets/settings_voice.dart';
import 'package:assisto/widgets/voice_input.dart';

import 'fake_api.dart';

const _screen = Size(360, 800);

AppState _stub(FakeApi api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1,
      name: 'Arif',
      phone: '01700000000',
      email: '',
      autonomyLevel: 2,
      language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Future<void> _pump(WidgetTester tester, AppState app, Widget home) async {
  await tester.binding.setSurfaceSize(_screen);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<Updater>(create: (_) => Updater()),
    ],
    child: MediaQuery(
      data: const MediaQueryData(size: _screen),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('en'),
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
    ),
  ));
  await _settle(tester);
}

// Bounded settle (home has spinners / pollers, so no pumpAndSettle).
Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

AppLocalizations _t(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

Future<void> _openDrawerToChats(WidgetTester tester) async {
  tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
  await _settle(tester);
  await tester.tap(find.byKey(const ValueKey('drawer_assisto_ai')));
  await _settle(tester);
  expect(find.byType(AssistoChatsScreen), findsOneWidget);
}

Future<void> _menu(WidgetTester tester, int id, String item) async {
  await tester.tap(find.byKey(ValueKey('chat_menu_$id')));
  await _settle(tester, 5);
  await tester.tap(find.text(item).last);
  await _settle(tester, 5);
}

double _y(WidgetTester tester, int id) =>
    tester.getTopLeft(find.byKey(ValueKey('chat_row_$id'))).dy;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('drawer -> Assisto AI -> chats page: full user flow',
      (tester) async {
    final api = FakeApi(mode: FakeMode.data, lang: 'en');
    await _pump(tester, _stub(api), const HomeScreen());
    final t = _t(tester);

    // Sidebar: ONE Assisto AI entry, no New-chat button, no chat list.
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await _settle(tester);
    expect(find.byKey(const ValueKey('drawer_assisto_ai')), findsOneWidget);
    expect(find.text(t.sidebarNewAiChat), findsNothing);
    expect(find.text('Call mom tomorrow morning'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('drawer_assisto_ai')));
    await _settle(tester);
    expect(find.byType(AssistoChatsScreen), findsOneWidget);

    // All chats (home + ai), pinned first then newest.
    for (final id in [11, 12, 13, 14, 15]) {
      expect(find.byKey(ValueKey('chat_row_$id')), findsOneWidget);
    }
    expect(_y(tester, 11), lessThan(_y(tester, 12)));
    expect(_y(tester, 12), lessThan(_y(tester, 13)));
    expect(_y(tester, 14), lessThan(_y(tester, 15)));
    expect(find.textContaining(t.p1ChatsSourceHome), findsWidgets);
    expect(find.byKey(const ValueKey('chats_new_chat')), findsOneWidget);

    // Search.
    await tester.enterText(find.byKey(const ValueKey('chats_search')), 'bill');
    await _settle(tester, 5);
    expect(find.byKey(const ValueKey('chat_row_14')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat_row_11')), findsNothing);
    expect(api.chatCalls, contains('list:bill'));
    await tester.enterText(find.byKey(const ValueKey('chats_search')), 'zzzz');
    await _settle(tester, 5);
    expect(find.text(t.aichatNoSearchResults), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('chats_search')), '');
    await _settle(tester, 5);
    expect(find.byKey(const ValueKey('chat_row_15')), findsOneWidget);

    // Pin chat 13 -> it moves above 12 (into the Pinned group).
    await _menu(tester, 13, t.aichatPin);
    expect(api.chatCalls, contains('update:13::true'));
    expect(_y(tester, 13), lessThan(_y(tester, 12)));
    expect(find.text(t.p1ChatsPinned), findsOneWidget);

    // Rename chat 15.
    await _menu(tester, 15, t.aichatRename);
    await tester.enterText(
        find.byKey(const ValueKey('chat_rename_field')), 'Cover letter');
    await tester.tap(find.text(t.aichatSave));
    await _settle(tester, 5);
    expect(find.text('Cover letter'), findsOneWidget);
    expect(api.chatCalls, contains('update:15:Cover letter:'));

    // Delete chat 12 (with confirmation).
    await _menu(tester, 12, t.aichatDelete);
    expect(find.text(t.aichatDeleteConfirm), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, t.aichatDelete));
    await _settle(tester, 5);
    expect(find.byKey(const ValueKey('chat_row_12')), findsNothing);
    expect(api.chatCalls, contains('delete:12'));

    // An AI chat opens AiChatScreen on that session; back returns here.
    await tester.tap(find.byKey(const ValueKey('chat_row_13')));
    await _settle(tester);
    expect(find.byType(AiChatScreen), findsOneWidget);
    expect(
        tester
            .widget<AiChatScreen>(find.byType(AiChatScreen))
            .initialSession?['id'],
        13);
    await tester.pageBack();
    await _settle(tester);
    expect(find.byType(AiChatScreen), findsNothing);
    expect(find.byType(AssistoChatsScreen), findsOneWidget);

    // A home chat reopens ON HOME.
    await tester.tap(find.byKey(const ValueKey('chat_row_11')));
    await _settle(tester);
    expect(find.byType(AssistoChatsScreen), findsNothing);
    expect(
        tester
            .widget<AgentThreadScreen>(find.byType(AgentThreadScreen))
            .sessionId,
        '11');

    // New chat -> a fresh home chat.
    await _openDrawerToChats(tester);
    await tester.tap(find.byKey(const ValueKey('chats_new_chat')));
    await _settle(tester);
    expect(find.byType(AssistoChatsScreen), findsNothing);
    final thread =
        tester.widget<AgentThreadScreen>(find.byType(AgentThreadScreen));
    expect(thread.sessionId, isNull);
    expect(thread.fresh, isTrue);

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('home "Assisto AI" shortcut opens the same chats page',
      (tester) async {
    final api = FakeApi(mode: FakeMode.data, lang: 'en');
    await _pump(tester, _stub(api), const HomeScreen());
    final t = _t(tester);
    final shortcut = find.text(t.aichatTitle);
    expect(shortcut, findsWidgets);
    await tester.tap(shortcut.first);
    await _settle(tester);
    expect(find.byType(AssistoChatsScreen), findsOneWidget);
    // Home rows still reopen on home (via HomeChatLink — no explicit hooks).
    await tester.tap(find.byKey(const ValueKey('chat_row_14')));
    await _settle(tester);
    expect(find.byType(AssistoChatsScreen), findsNothing);
    expect(
        tester
            .widget<AgentThreadScreen>(find.byType(AgentThreadScreen))
            .sessionId,
        '14');
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('chats page without a home falls back to AiChatScreen',
      (tester) async {
    final api = FakeApi(mode: FakeMode.data, lang: 'en');
    await _pump(tester, _stub(api), const AssistoChatsScreen());
    await tester.tap(find.byKey(const ValueKey('chats_new_chat')));
    await _settle(tester);
    expect(find.byType(AiChatScreen), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('chats page: load failure shows retry, empty shows guidance',
      (tester) async {
    await _pump(tester, _stub(FakeApi(mode: FakeMode.fail, lang: 'en')),
        const AssistoChatsScreen());
    final t = _t(tester);
    expect(find.text(t.aichatRetry), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, _stub(FakeApi(mode: FakeMode.empty, lang: 'en')),
        const AssistoChatsScreen());
    expect(find.text(t.aichatNoChats), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('chat inputs have no BN/EN chip; mic stays', (tester) async {
    final api = FakeApi(mode: FakeMode.data, lang: 'en');
    final voice = VoiceDictation();
    await _pump(
        tester,
        _stub(api),
        Scaffold(
            body:
                VoiceMicButton(voice: voice, input: TextEditingController())));
    final t = _t(tester);
    expect(find.text(t.voiceChipBn), findsNothing);
    expect(find.text(t.voiceChipEn), findsNothing);
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    expect(voice.mode, 'auto');
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Settings -> Voice: Auto default, override is saved',
      (tester) async {
    final api = FakeApi(mode: FakeMode.data, lang: 'en');
    await _pump(
        tester,
        _stub(api),
        const Scaffold(
            body: SingleChildScrollView(child: SettingsVoiceSection())));
    final t = _t(tester);
    expect(find.text(t.p1VoiceAuto), findsOneWidget);
    expect(await VoiceDictation.savedMode(), 'auto');
    await tester.tap(find.byKey(const ValueKey('voice_mode_en')));
    await _settle(tester, 3);
    expect(await VoiceDictation.savedMode(), 'en');
    final d = VoiceDictation();
    await d.loadMode();
    expect(d.mode, 'en');
    await tester.tap(find.byKey(const ValueKey('voice_mode_auto')));
    await _settle(tester, 3);
    expect(await VoiceDictation.savedMode(), 'auto');
    await tester.binding.setSurfaceSize(null);
  });
}
