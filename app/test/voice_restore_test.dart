// Voice + home-thread restore regressions (owner priority build, a1 review):
//  * a very short HOLD must never leave the mic listening,
//  * the shared SpeechToText singleton: a 2nd screen re-claims status/error,
//  * permission denied -> honest message, no listening,
//  * the bn/EN chip is one app-wide choice and persists,
//  * restore: 404/403 forgets the saved thread once; offline keeps it.
// ignore_for_file: deprecated_member_use_from_same_package, deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/voice_input.dart';

import 'fake_api.dart';

class FakeSpeech extends SpeechToText {
  FakeSpeech({this.initOk = true}) : super.withMethodChannel();
  bool initOk;
  bool inited = false;
  Completer<bool>? initGate;
  int listens = 0;
  int stops = 0;

  @override
  bool get isAvailable => inited;

  @override
  Future<bool> initialize(
      {SpeechErrorListener? onError,
      SpeechStatusListener? onStatus,
      debugLogging = false,
      Duration finalTimeout = const Duration(milliseconds: 2000),
      List<SpeechConfigOption>? options}) async {
    if (inited) return true; // the real plugin ignores later callbacks too
    errorListener = onError;
    statusListener = onStatus;
    final ok = initGate != null ? await initGate!.future : initOk;
    inited = ok;
    return ok;
  }

  @override
  Future<List<LocaleName>> locales() async =>
      [LocaleName('bn_BD', 'Bangla'), LocaleName('en_US', 'English')];

  @override
  Future listen(
      {SpeechResultListener? onResult,
      Duration? listenFor,
      Duration? pauseFor,
      String? localeId,
      SpeechSoundLevelChange? onSoundLevelChange,
      cancelOnError = false,
      partialResults = true,
      onDevice = false,
      ListenMode listenMode = ListenMode.confirmation,
      sampleRate = 0,
      SpeechListenOptions? listenOptions}) async {
    listens++;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> cancel() async {}
}

Future<BuildContext> _ctx(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })),
  ));
  return ctx;
}

class _RestoreApi extends FakeApi {
  final Object? error;
  _RestoreApi(this.error) : super(lang: 'en');
  @override
  Future<List<Map<String, dynamic>>> chatMessages(String sessionId) async {
    if (error != null) throw error!;
    return super.chatMessages(sessionId);
  }
}

Future<void> _pumpThread(WidgetTester tester, ApiClient api) async {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '',
      autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
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
      home: const Scaffold(body: AgentThreadScreen()),
    ),
  ));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VoiceDictation.debugReset();
  });

  group('voice', () {
    testWidgets('very short hold: released before engine ready -> never listens',
        (tester) async {
      final ctx = await _ctx(tester);
      final eng = FakeSpeech()..initGate = Completer<bool>();
      final v = VoiceDictation(
          mode: 'en', engine: eng, askReason: (_) async => true);
      final input = TextEditingController();
      final f = v.start(ctx, input); // onLongPressStart
      await tester.pump();
      await v.stop(); // onLongPressEnd, engine still initializing
      eng.initGate!.complete(true);
      await f;
      expect(eng.listens, 0);
      expect(v.listening, isFalse);
      // a later tap works normally
      await v.toggle(ctx, input);
      expect(eng.listens, 1);
      expect(v.listening, isTrue);
      await v.toggle(ctx, input);
      expect(v.listening, isFalse);
      v.dispose();
    });

    testWidgets('normal hold listens, release stops', (tester) async {
      final ctx = await _ctx(tester);
      final eng = FakeSpeech();
      final v = VoiceDictation(mode: 'bn', engine: eng, askReason: (_) async => true);
      await v.start(ctx, TextEditingController());
      expect(v.listening, isTrue);
      await v.stop();
      expect(v.listening, isFalse);
      expect(eng.stops, 1);
      v.dispose();
    });

    testWidgets('shared engine: second screen re-claims status/error listeners',
        (tester) async {
      final ctx = await _ctx(tester);
      final eng = FakeSpeech();
      final home = VoiceDictation(mode: 'en', engine: eng, askReason: (_) async => true);
      await home.start(ctx, TextEditingController());
      await home.stop();
      final ai = VoiceDictation(mode: 'en', engine: eng, askReason: (_) async => true);
      await ai.start(ctx, TextEditingController());
      expect(ai.listening, isTrue);
      eng.statusListener!('done'); // engine auto-stopped after the pause
      expect(ai.listening, isFalse, reason: 'mic must not stay pulsing');
      await ai.start(ctx, TextEditingController());
      eng.errorListener!(SpeechRecognitionError('error_no_match', false));
      expect(ai.listening, isFalse);
      ai.dispose();
      expect(eng.statusListener, isNull);
      home.dispose();
    });

    testWidgets('permission denied / declined: no listening, honest message',
        (tester) async {
      final ctx = await _ctx(tester);
      final eng = FakeSpeech(initOk: false);
      final declined = VoiceDictation(
          mode: 'en', engine: eng, askReason: (_) async => false,
          micDenied: () async => true);
      await declined.start(ctx, TextEditingController());
      expect(eng.listens, 0);
      expect(declined.listening, isFalse);
      final v = VoiceDictation(mode: 'en', engine: eng,
          askReason: (_) async => true, micDenied: () async => true);
      await v.start(ctx, TextEditingController());
      await tester.pump();
      expect(eng.listens, 0);
      expect(v.listening, isFalse);
      expect(find.byType(SnackBar), findsOneWidget);
      // the honest "mic permission" message (not the generic one)
      final t = AppLocalizations.of(ctx);
      expect(find.text(t.voiceNoPermission), findsOneWidget);
      declined.dispose();
      v.dispose();
    });

    testWidgets('Settings -> Voice mode is persisted (no chip)', (tester) async {
      await VoiceDictation.saveMode('en');
      final c = VoiceDictation(engine: FakeSpeech());
      await c.loadMode();
      expect(c.mode, 'en');
      await VoiceDictation.saveMode('nonsense'); // ignored
      expect(await VoiceDictation.savedMode(), 'en');
      c.dispose();
    });
  });

  group('home thread restore', () {
    test('forgetsSession: only "gone" statuses', () {
      expect(AgentThreadScreen.forgetsSession(ApiException('x', 404)), isTrue);
      expect(AgentThreadScreen.forgetsSession(ApiException('x', 403)), isTrue);
      expect(AgentThreadScreen.forgetsSession(ApiException('x', 503)), isFalse);
      expect(AgentThreadScreen.forgetsSession(ApiException('x')), isFalse);
      expect(AgentThreadScreen.forgetsSession(Exception('offline')), isFalse);
    });

    testWidgets('deleted session (404) -> fresh start, key cleared',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {AgentThreadScreen.sessionKey: '99'});
      await _pumpThread(tester, _RestoreApi(ApiException('gone', 404)));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AgentThreadScreen.sessionKey), '');
      expect(find.text('Reminder set.'), findsNothing);
    });

    testWidgets('offline -> saved session kept for the next start',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {AgentThreadScreen.sessionKey: '11'});
      await _pumpThread(tester, _RestoreApi(ApiException('offline', 503)));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AgentThreadScreen.sessionKey), '11');
    });

    testWidgets('existing session restores its messages', (tester) async {
      SharedPreferences.setMockInitialValues(
          {AgentThreadScreen.sessionKey: '11'});
      await _pumpThread(tester, _RestoreApi(null));
      expect(find.text('Reminder set.'), findsOneWidget);
    });
  });
}
