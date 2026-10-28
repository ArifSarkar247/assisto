// aivoice — AI assistant + voice (board group 6). Every new state, bn + en:
//  * honest no-key banner (GET chat/status) / paused / AI on / unknown,
//  * streamed + non-streamed replies are no longer EMPTY (SSE chunk key,
//    flat send shape, growable cards),
//  * read aloud: Listen / Stop reading, no Bangla voice, no TTS engine,
//  * offline copy of the last opened chat,
//  * voice conversation loop (pure state machine) + its status bar,
//  * Bangla voice help sheet (+ the "How to fix" action on voice errors),
//  * Assisto Voice keep-listening rule, 200% font, dark, 48dp, TalkBack.
// ignore_for_file: deprecated_member_use_from_same_package, deprecated_member_use
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/screens/voice_assistant_screen.dart';
import 'package:assisto/screens/voice_assistant_settings_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/voice/reply_speaker.dart';
import 'package:assisto/voice/va_wake.dart';
import 'package:assisto/voice/voice_loop.dart';
import 'package:assisto/widgets/voice_help_sheet.dart';
import 'package:assisto/widgets/voice_input.dart';

import 'fake_api.dart';

const _voiceCh = MethodChannel('com.assisto/voice');

class _ChatApi extends FakeApi {
  _ChatApi({String lang = 'en'}) : super(mode: FakeMode.data, lang: lang);

  Map<String, dynamic>? status = {
    'ai_available': false,
    'reason': 'no_key',
    'free': ['own_data', 'app_help', 'phone_commands', 'voice_input'],
  };
  bool statusThrows = false;
  bool messagesFail = false;
  bool streamFails = false;
  int sends = 0;

  bool get _bn => lang == 'bn';

  @override
  Future<Map<String, dynamic>> chatStatus() async {
    if (statusThrows) throw Exception('offline');
    return status ?? {};
  }

  @override
  Future<List<Map<String, dynamic>>> chatMessages(String sessionId) async {
    if (messagesFail) throw Exception('offline');
    return [
      {'id': 1, 'role': 'user', 'text': _bn ? 'আজ কত খরচ হলো?' : 'How much did I spend today?', 'meta': {}},
      {'id': 2, 'role': 'assistant', 'text': _bn ? 'আজ মোট ৳৮৫০ খরচ হয়েছে।' : 'You spent ৳850 today.', 'meta': {'source': 'brain'}},
    ];
  }

  @override
  Future<Map<String, dynamic>> chatCreateSession({String? title}) async =>
      {'id': 77, 'title': ''};

  @override
  Stream<Map<String, dynamic>> chatStream(String sessionId, String text) async* {
    sends++;
    if (streamFails) throw Exception('no stream');
    // the SERVER's real token shape (chunk + text) — parsed by the app's own
    // record parser, so this proves the "empty reply" bug stays fixed.
    yield ApiClient.chatSseRecord('token', jsonEncode({'chunk': 'Your ', 'text': 'Your '}));
    yield ApiClient.chatSseRecord('token', jsonEncode({'chunk': 'answer.', 'text': 'answer.'}));
    yield ApiClient.chatSseRecord('done', jsonEncode({
      'message_id': 90, 'cards': [], 'source': 'brain', 'text': 'Your answer.'}));
  }

  @override
  Future<Map<String, dynamic>> chatSend(String sessionId, String text) async =>
      ApiClient.flattenChatReply({
        'message': {'id': 91, 'role': 'assistant', 'text': 'Sent answer.',
          'meta': {'source': 'brain', 'cards': []}},
        'cards': [],
        'ai_used': false,
      });
}

AppState _stub(FakeApi api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '', autonomyLevel: 2,
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
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: w!),
        home: child,
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

void _mockVoice(Future<Object?> Function(MethodCall c)? h) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_voiceCh, h);
}

const _session = {'id': 9, 'title': 'Spending'};

class _FakeSpeech extends SpeechToText {
  _FakeSpeech({this.initOk = true}) : super.withMethodChannel();
  bool initOk;
  bool inited = false;
  @override
  bool get isAvailable => inited;
  @override
  Future<bool> initialize(
      {SpeechErrorListener? onError,
      SpeechStatusListener? onStatus,
      debugLogging = false,
      Duration finalTimeout = const Duration(milliseconds: 2000),
      List<SpeechConfigOption>? options}) async {
    errorListener = onError;
    statusListener = onStatus;
    inited = initOk;
    return initOk;
  }

  @override
  Future<List<LocaleName>> locales() async => [LocaleName('en_US', 'English')];
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
      SpeechListenOptions? listenOptions}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    ReplySpeaker.debugReset();
    VoiceDictation.debugReset();
    _mockVoice(null);
  });

  // ------------------------------------------------------------ pure parts
  group('ReplySpeaker text', () {
    test('language: Bangla script wins, English otherwise', () {
      expect(ReplySpeaker.langOf('আজ মোট ৳৮৫০ খরচ হয়েছে।'), 'bn');
      expect(ReplySpeaker.langOf('আপনার Netflix বিল কাল'), 'bn');
      expect(ReplySpeaker.langOf('You spent 850 taka today.'), 'en');
      expect(ReplySpeaker.langOf('৮৫০'), 'bn');
    });

    test('speakable drops code, links, markdown and emoji', () {
      final s = ReplySpeaker.speakable(
          '**Done** ✅\n- see https://x.com/a\n```dart\nprint(1);\n```\n# Next');
      expect(s.contains('```'), isFalse);
      expect(s.contains('print'), isFalse);
      expect(s.contains('http'), isFalse);
      expect(s.contains('*'), isFalse);
      expect(s.contains('#'), isFalse);
      expect(s.contains('✅'), isFalse);
      expect(s, contains('Done'));
      expect(s, contains('Next'));
    });

    test('long answers are capped on a sentence end', () {
      final long = List.filled(400, 'এটা একটা বাক্য।').join(' ');
      final s = ReplySpeaker.speakable(long);
      expect(s.length, lessThanOrEqualTo(ReplySpeaker.maxChars));
      expect(s.endsWith('।'), isTrue);
    });
  });

  group('ReplySpeaker playback', () {
    test('tracks the message being read and clears it when done', () async {
      final gate = Completer<String?>();
      String? lang;
      final sp = ReplySpeaker(
          speak: (t, l) {
            lang = l;
            return gate.future;
          },
          stop: () async {});
      final f = sp.speak('m1', 'আজ মোট খরচ ৳৮৫০।');
      await Future<void>.delayed(Duration.zero);
      expect(sp.isSpeaking('m1'), isTrue);
      expect(lang, 'bn');
      gate.complete('ok');
      expect(await f, 'ok');
      expect(sp.speakingKey, isNull);
    });

    test('stop while reading -> stopped, engine told to stop', () async {
      final gate = Completer<String?>();
      var stops = 0;
      final sp = ReplySpeaker(speak: (t, l) => gate.future, stop: () async => stops++);
      final f = sp.speak('m1', 'Hello there.');
      await Future<void>.delayed(Duration.zero);
      await sp.stop();
      gate.complete('ok');
      expect(await f, 'stopped');
      expect(sp.speakingKey, isNull);
      expect(stops, greaterThanOrEqualTo(2)); // before speaking + the stop
    });

    test('engine error -> no_engine, nothing empty is spoken', () async {
      final sp = ReplySpeaker(
          speak: (t, l) async => throw Exception('x'), stop: () async {});
      expect(await sp.speak('a', 'Hi.'), 'no_engine');
      expect(await sp.speak('b', '```x```'), 'empty');
    });
  });

  group('VoiceLoop', () {
    test('listen -> ask -> say -> listen, ends after two silences', () async {
      final heard = ['what did I spend', 'and yesterday', '', ''];
      final asked = <String>[], said = <String>[];
      final phases = <LoopPhase>[];
      late VoiceLoop loop;
      loop = VoiceLoop(
        hear: () async => heard.removeAt(0),
        ask: (q) async {
          asked.add(q);
          return 'answer to $q';
        },
        say: (a) async => said.add(a),
        cancel: () async {},
      )..addListener(() => phases.add(loop.phase));
      await loop.start();
      expect(asked, ['what did I spend', 'and yesterday']);
      expect(said, ['answer to what did I spend', 'answer to and yesterday']);
      expect(loop.turns, 2);
      expect(loop.endReason, 'silence');
      expect(loop.phase, LoopPhase.off);
      expect(phases, containsAllInOrder([
        LoopPhase.listening, LoopPhase.thinking, LoopPhase.speaking,
        LoopPhase.listening, LoopPhase.off]));
    });

    test('mic unavailable -> ends with mic, nothing sent', () async {
      var asks = 0;
      final loop = VoiceLoop(
          hear: () async => null,
          ask: (q) async {
            asks++;
            return 'x';
          },
          say: (a) async {},
          cancel: () async {});
      await loop.start();
      expect(loop.endReason, 'mic');
      expect(asks, 0);
    });

    test('failed answer -> ends with error (never reads a fake reply)', () async {
      var says = 0;
      final loop = VoiceLoop(
          hear: () async => 'hello',
          ask: (q) async => null,
          say: (a) async => says++,
          cancel: () async {});
      await loop.start();
      expect(loop.endReason, 'error');
      expect(says, 0);
    });

    test('End while speaking -> user, cancel runs, no next listen', () async {
      final speaking = Completer<void>();
      var hears = 0, cancels = 0;
      late VoiceLoop loop;
      loop = VoiceLoop(
          hear: () async {
            hears++;
            return 'hi';
          },
          ask: (q) async => 'ok',
          say: (a) => speaking.future,
          cancel: () async => cancels++);
      final run = loop.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(loop.phase, LoopPhase.speaking);
      await loop.stop();
      speaking.complete();
      await run;
      expect(loop.endReason, 'user');
      expect(cancels, 1);
      expect(hears, 1);
      expect(loop.active, isFalse);
    });
  });

  group('chat reply shapes (the empty-reply bug)', () {
    test('SSE token with chunk, text-only, and done with text', () {
      expect(ApiClient.chatSseRecord('token', '{"chunk":"Hi","text":"Hi"}'),
          {'kind': 'token', 'chunk': 'Hi'});
      // an older server sent only "text" -> it is still read
      expect(ApiClient.chatSseRecord('token', '{"text":"Hi"}')['chunk'], 'Hi');
      final d = ApiClient.chatSseRecord(
          'done', '{"message_id":5,"cards":[],"source":"brain","text":"Full"}');
      expect(d['kind'], 'done');
      expect(d['message_id'], 5);
      expect(d['text'], 'Full');
      expect(d['source'], 'brain');
    });

    test('send / regenerate {message:{...}} is flattened', () {
      final r = ApiClient.flattenChatReply({
        'message': {'id': 3, 'role': 'assistant', 'text': 'Answer',
          'meta': {'source': 'brain'}},
        'cards': [{'type': 'reminder'}],
        'ai_used': false,
      });
      expect(r['id'], 3);
      expect(r['text'], 'Answer');
      expect(r['source'], 'brain');
      expect((r['cards'] as List).length, 1);
      // an already-flat reply is unchanged
      expect(ApiClient.flattenChatReply({'id': 1, 'text': 'x'}),
          {'id': 1, 'text': 'x'});
    });
  });

  test('Assisto Voice keep-listening rule', () {
    bool c({bool on = true, bool mounted = true, bool idle = true,
            bool needsTap = false, bool fg = true}) =>
        VoiceAssistantScreen.shouldContinue(
            on: on, mounted: mounted, idle: idle, needsTap: needsTap,
            foreground: fg);
    expect(c(), isTrue);
    expect(c(on: false), isFalse); // default off
    expect(c(fg: false), isFalse); // handed over to the dialer / another app
    expect(c(needsTap: true), isFalse); // a choice or a danger card waits
    expect(c(idle: false), isFalse);
    expect(c(mounted: false), isFalse);
    expect(VaWake.continueKey, 'va_continue_v1');
  });

  test('Bangla locale resolution bn_BD -> bn_IN -> bn', () {
    expect(VoiceDictation.resolveLocale(['en_US', 'bn_IN'], 'bn'), 'bn_IN');
    expect(VoiceDictation.resolveLocale(['bn-BD', 'bn-IN'], 'bn'), 'bn-BD');
    expect(VoiceDictation.resolveLocale(['en_US', 'bn'], 'bn'), 'bn');
    expect(VoiceDictation.resolveLocale(['en_US'], 'bn'), isNull);
    expect(VoiceDictation.pickLocale(['en_US'], 'auto')!.lang, 'en');
  });

  // ------------------------------------------------------------ widgets
  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] no-key banner on the welcome screen', (tester) async {
      await _phone(tester);
      final t = _tl(lang);
      await tester.pumpWidget(_app(_stub(_ChatApi(lang: lang), lang),
          const AiChatScreen(), lang: lang));
      await _settle(tester);
      expect(find.byKey(const ValueKey('aichat_nokey_card')), findsOneWidget);
      expect(find.text(t.aivNoKeyTitle), findsOneWidget);
      expect(find.text(t.aivNoKeyBody), findsOneWidget);
      for (final s in [t.aivFreeOwnData, t.aivFreeAppHelp,
        t.aivFreePhoneCommands, t.aivFreeVoiceInput]) {
        expect(find.text(s), findsOneWidget);
      }
      final other = _tl(lang == 'bn' ? 'en' : 'bn');
      expect(find.text(other.aivNoKeyTitle), findsNothing); // strict bn / en
      // the conversation button: labelled, 48dp
      final conv = find.byKey(const ValueKey('aichat_conv_start'));
      expect(find.byTooltip(t.aivConvStart), findsOneWidget);
      expect(tester.getSize(conv).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });

    testWidgets('[$lang] thread: offline-answer chip, no-key strip, Listen',
        (tester) async {
      await _phone(tester);
      final t = _tl(lang);
      await tester.pumpWidget(_app(_stub(_ChatApi(lang: lang), lang),
          const AiChatScreen(initialSession: _session), lang: lang));
      await _settle(tester);
      expect(find.byKey(const ValueKey('aichat_nokey_strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('aichat_nokey_card')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('aichat_nokey_strip')));
      await _settle(tester, 3);
      expect(find.byKey(const ValueKey('aichat_nokey_card')), findsOneWidget);
      expect(find.text(t.aichatOfflineAnswer), findsOneWidget);
      final listen = find.byKey(const ValueKey('aichat_listen'));
      expect(listen, findsOneWidget);
      expect(find.text(t.aivListen), findsOneWidget);
      expect(tester.getSize(listen).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('paused (key present, cap reached) -> honest paused banner',
      (tester) async {
    await _phone(tester);
    final api = _ChatApi()..status = {'ai_available': false, 'reason': 'paused', 'free': ['own_data']};
    await tester.pumpWidget(_app(_stub(api, 'en'), const AiChatScreen()));
    await _settle(tester);
    final t = _tl('en');
    expect(find.text(t.aivPausedTitle), findsOneWidget);
    expect(find.text(t.aivNoKeyTitle), findsNothing);
    expect(find.text(t.aivFreeOwnData), findsOneWidget);
    expect(find.text(t.aivFreeAppHelp), findsNothing);
  });

  testWidgets('AI on, or status unknown -> no banner (never guessed)',
      (tester) async {
    await _phone(tester);
    final on = _ChatApi()..status = {'ai_available': true, 'reason': null, 'free': []};
    await tester.pumpWidget(_app(_stub(on, 'en'), const AiChatScreen()));
    await _settle(tester);
    expect(find.byKey(const ValueKey('aichat_nokey_card')), findsNothing);

    final unknown = _ChatApi()..statusThrows = true;
    await tester.pumpWidget(_app(_stub(unknown, 'en'),
        const AiChatScreen(key: ValueKey('second'))));
    await _settle(tester);
    expect(find.byKey(const ValueKey('aichat_nokey_card')), findsNothing);
  });

  testWidgets('a streamed reply shows its words (was EMPTY) + Listen',
      (tester) async {
    await _phone(tester);
    final api = _ChatApi();
    await tester.pumpWidget(_app(_stub(api, 'en'), const AiChatScreen()));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'what did I spend?');
    await tester.tap(find.byTooltip(_tl('en').aichatSend));
    await _settle(tester);
    expect(api.sends, 1);
    expect(find.text('Your answer.'), findsOneWidget);
    expect(find.byKey(const ValueKey('aichat_listen')), findsOneWidget);
    expect(find.byKey(const ValueKey('aichat_nokey_strip')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no stream -> non-streamed reply is shown (was a failure)',
      (tester) async {
    await _phone(tester);
    final api = _ChatApi()..streamFails = true;
    await tester.pumpWidget(_app(_stub(api, 'en'), const AiChatScreen()));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byTooltip(_tl('en').aichatSend));
    await _settle(tester);
    expect(find.text('Sent answer.'), findsOneWidget);
    expect(find.text(_tl('en').aichatSendFailed), findsNothing);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] Listen: no TTS engine -> honest message',
        (tester) async {
      await _phone(tester);
      // no native half (older build): every call is MissingPluginException
      _mockVoice((c) async => throw MissingPluginException());
      await tester.pumpWidget(_app(_stub(_ChatApi(lang: lang), lang),
          const AiChatScreen(initialSession: _session), lang: lang));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('aichat_listen')));
      await _settle(tester, 4);
      expect(find.text(_tl(lang).aivTtsNoEngine), findsOneWidget);
    });

    testWidgets('[$lang] Listen: no Bangla voice -> install hint (once)',
        (tester) async {
      await _phone(tester);
      final calls = <String>[];
      _mockVoice((c) async {
        calls.add(c.method);
        if (c.method == 'speak') return 'no_voice';
        if (c.method == 'openTtsSettings') return true;
        return null;
      });
      await tester.pumpWidget(_app(_stub(_ChatApi(lang: lang), lang),
          const AiChatScreen(initialSession: _session), lang: lang));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('aichat_listen')));
      await _settle(tester, 4);
      final t = _tl(lang);
      expect(find.text(t.vaNoTtsVoice), findsOneWidget);
      await tester.tap(find.text(t.vaInstall));
      await _settle(tester, 4);
      expect(calls, contains('openTtsSettings'));
      expect(calls.where((m) => m == 'speak').length, 1);
    });
  }

  testWidgets('Listen -> Stop reading while speaking -> stops the engine',
      (tester) async {
    await _phone(tester);
    final gate = Completer<Object?>();
    final calls = <String>[];
    _mockVoice((c) async {
      calls.add(c.method);
      if (c.method == 'speak') return gate.future;
      return null;
    });
    await tester.pumpWidget(_app(_stub(_ChatApi(), 'en'),
        const AiChatScreen(initialSession: _session)));
    await _settle(tester);
    final t = _tl('en');
    await tester.tap(find.byKey(const ValueKey('aichat_listen')));
    await _settle(tester, 3);
    expect(find.text(t.aivStopReading), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('aichat_listen')));
    await _settle(tester, 3);
    expect(find.text(t.aivListen), findsOneWidget);
    expect(calls.where((m) => m == 'stopSpeaking').length, greaterThanOrEqualTo(2));
    gate.complete('ok');
    await _settle(tester, 2);
  });

  testWidgets('offline: the last opened chat is shown from this phone',
      (tester) async {
    await _phone(tester);
    final api = _ChatApi();
    await tester.pumpWidget(_app(_stub(api, 'en'),
        const AiChatScreen(initialSession: _session)));
    await _settle(tester);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => k.contains('aichat_cache_v1_9')), isTrue);

    api.messagesFail = true;
    await tester.pumpWidget(_app(_stub(api, 'en'),
        const AiChatScreen(key: ValueKey('again'), initialSession: _session)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('aichat_offline_strip')), findsOneWidget);
    expect(find.text(_tl('en').aivOfflineCopy), findsOneWidget);
    expect(find.text('You spent ৳850 today.'), findsOneWidget);
    expect(find.text(_tl('en').aichatLoadFailed), findsNothing);
  });

  testWidgets('offline with no copy -> the honest load error', (tester) async {
    await _phone(tester);
    final api = _ChatApi()..messagesFail = true;
    await tester.pumpWidget(_app(_stub(api, 'en'),
        const AiChatScreen(initialSession: _session)));
    await _settle(tester);
    expect(find.text(_tl('en').aichatLoadFailed), findsOneWidget);
    expect(find.byKey(const ValueKey('aichat_offline_strip')), findsNothing);
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] conversation bar: each phase + End (48dp)',
        (tester) async {
      await _phone(tester);
      final t = _tl(lang);
      for (final (phase, label) in [
        (LoopPhase.listening, t.aivConvListening),
        (LoopPhase.thinking, t.aivConvThinking),
        (LoopPhase.speaking, t.aivConvSpeaking),
      ]) {
        await tester.pumpWidget(_app(_stub(_ChatApi(lang: lang), lang),
            AiChatScreen(key: ValueKey(phase), debugLoopPhase: phase),
            lang: lang));
        await _settle(tester, 4);
        expect(find.byKey(const ValueKey('aichat_conv_bar')), findsOneWidget);
        expect(find.text(label), findsOneWidget);
        final end = find.byKey(const ValueKey('aichat_conv_end'));
        expect(find.text(t.aivConvEnd), findsOneWidget);
        expect(tester.getSize(end).height, greaterThanOrEqualTo(48));
      }
    });
  }

  testWidgets('bn + 200% font + dark: banner, strip, bar — nothing overflows',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(_stub(_ChatApi(lang: 'bn'), 'bn'),
        const AiChatScreen(), lang: 'bn', scale: 2, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('aichat_nokey_card')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text(_tl('bn').aivNoKeyTitle), findsOneWidget);
    await tester.pumpWidget(_app(_stub(_ChatApi(lang: 'bn'), 'bn'),
        const AiChatScreen(key: ValueKey('t'), initialSession: _session,
            debugLoopPhase: LoopPhase.listening),
        lang: 'bn', scale: 2, dark: true));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    // the thread opens at its newest message; the strip is row 0 above it
    final strip = find.byKey(const ValueKey('aichat_nokey_strip'));
    await tester.scrollUntilVisible(strip, -200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(strip); // built in the cache area -> on screen
    await _settle(tester, 3);
    await tester.tap(strip);
    await _settle(tester, 3);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('aichat_nokey_card')), findsOneWidget);
    expect(find.text(_tl('bn').aivConvListening), findsOneWidget);
  });

  testWidgets('TalkBack: conversation bar is a live region, banner title a header',
      (tester) async {
    await _phone(tester);
    final h = tester.ensureSemantics();
    await tester.pumpWidget(_app(_stub(_ChatApi(), 'en'),
        const AiChatScreen(debugLoopPhase: LoopPhase.thinking)));
    await _settle(tester);
    final t = _tl('en');
    expect(
        tester.getSemantics(find.text(t.aivConvThinking)),
        containsSemantics(label: t.aivConvThinking, isLiveRegion: true));
    expect(tester.getSemantics(find.text(t.aivNoKeyTitle)),
        containsSemantics(label: t.aivNoKeyTitle, isHeader: true));
    h.dispose();
  });

  // ------------------------------------------------------------ help sheet
  for (final lang in ['en', 'bn']) {
    testWidgets('[$lang] Bangla voice help sheet: steps + buttons, 200% font',
        (tester) async {
      await _phone(tester);
      final calls = <String>[];
      _mockVoice((c) async {
        calls.add(c.method);
        return false; // the phone opened nothing
      });
      await tester.pumpWidget(_app(_stub(_ChatApi(lang: lang), lang),
          const Scaffold(body: VoiceHelpSheet()), lang: lang, scale: 2));
      await _settle(tester, 3);
      final t = _tl(lang);
      expect(tester.takeException(), isNull);
      expect(find.text(t.aivHelpTitle), findsOneWidget);
      for (final s in [t.aivHelpStep1, t.aivHelpStep2, t.aivHelpColorOs,
        t.aivHelpMiui, t.aivHelpSamsung, t.aivHelpTts]) {
        expect(find.text(s), findsOneWidget);
      }
      final open = find.byKey(const ValueKey('voice_help_open_input'));
      await tester.ensureVisible(open);
      expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
      await tester.tap(open);
      await _settle(tester, 3);
      expect(calls, contains('openVoiceInputSettings'));
      expect(find.text(t.vaSettingsOpenFailed), findsOneWidget);
    });
  }

  testWidgets('no speech service -> message with "How to fix" -> help sheet',
      (tester) async {
    await _phone(tester);
    final v = VoiceDictation(
        engine: _FakeSpeech(initOk: false),
        askReason: (_) async => true,
        micDenied: () async => false);
    final input = TextEditingController();
    late BuildContext ctx;
    await tester.pumpWidget(_app(_stub(_ChatApi(), 'en'),
        Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    }))));
    await _settle(tester, 2);
    await v.start(ctx, input);
    await _settle(tester, 3);
    final t = _tl('en');
    expect(find.text(t.micEnableSpeech), findsOneWidget);
    expect(v.lastStartListened, isFalse);
    await tester.tap(find.text(t.aivVoiceHelp));
    await _settle(tester, 6);
    expect(find.byKey(const ValueKey('voice_help_sheet')), findsOneWidget);
    v.dispose();
    input.dispose();
  });

  testWidgets('Settings > Voice: keep-listening switch saves, help opens',
      (tester) async {
    await _phone(tester);
    await tester.pumpWidget(_app(_stub(_ChatApi(), 'en'),
        const VoiceAssistantSettingsScreen(debugStatic: true)));
    await _settle(tester);
    final sw = find.byKey(const ValueKey('va_continue_switch'));
    await tester.scrollUntilVisible(sw, 200,
        scrollable: find.byType(Scrollable).first);
    await _settle(tester, 2);
    expect(find.text(_tl('en').vaContinueTitle), findsOneWidget);
    await tester.tap(sw);
    await _settle(tester, 3);
    expect(await Settings.getBool(VaWake.continueKey, false), isTrue);
    final help = find.byKey(const ValueKey('va_bangla_help'));
    await tester.scrollUntilVisible(help, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(help);
    await _settle(tester, 6);
    expect(find.byKey(const ValueKey('voice_help_sheet')), findsOneWidget);
  });
}
