// wa-polish2: WhatsApp-level My Circle polish, part 2 — bubble grouping,
// the composer mic (hold to record / slide to cancel / tap = hands-free),
// the voice-note bubble (stand-in waveform, unplayed dot, speed) and the
// Call info screen from a call-log row.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/bubble_grouping.dart';
import 'package:assisto/messaging/date_separators.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/voice_bubble.dart';
import 'package:assisto/messaging/media/voice_hold_mic.dart';
import 'package:assisto/messaging/media/voice_played.dart';
import 'package:assisto/messaging/media/voice_player.dart';
import 'package:assisto/messaging/media/voice_recorder_sheet.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_call_info_screen.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_bubble.dart';

Widget _app(Widget home, {String lang = 'en', ThemeData? theme}) => MaterialApp(
      locale: Locale(lang),
      theme: theme ?? AssistoTheme.light,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

class _Rec implements RecorderBackend {
  final amp = StreamController<double>.broadcast();
  String path = '';
  final calls = <String>[];
  @override
  Future<void> start(String p) async {
    path = p;
    calls.add('start');
    File(p).writeAsBytesSync(List.filled(4000, 7));
  }

  @override
  Future<String?> stop() async {
    calls.add('stop');
    return path;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');
  @override
  Stream<double> amplitude() => amp.stream;
  @override
  Future<void> dispose() async {}
}

class _Voice implements VoiceBackend {
  final calls = <String>[];
  final _s = StreamController<Duration>.broadcast();
  final _v = StreamController<void>.broadcast();
  @override
  Future<void> play(String path) async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async {}
  @override
  Future<void> seek(Duration d) async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<Duration> get position => _s.stream;
  @override
  Stream<Duration> get duration => _s.stream;
  @override
  Stream<void> get completed => _v.stream;
}

/// A composer like the chat screens': box + mic/send swap + the strip.
class _Composer extends StatefulWidget {
  const _Composer({required this.drafts, required this.taps});
  final List<MediaDraft> drafts;
  final List<String> taps;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _input = TextEditingController();
  final _hold = VoiceHoldController();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Row(children: [
            Expanded(
              child: Stack(children: [
                TextField(controller: _input),
                ListenableBuilder(
                  listenable: _hold,
                  builder: (_, __) => _hold.active
                      ? Positioned.fill(child: VoiceHoldStrip(controller: _hold))
                      : const SizedBox.shrink(),
                ),
              ]),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (_, v, __) => v.text.trim().isEmpty
                  ? VoiceHoldMic(
                      controller: _hold,
                      onTap: () => widget.taps.add('tap'),
                      onDraft: (d) async => widget.drafts.add(d),
                    )
                  : IconButton.filled(
                      tooltip: 'Send',
                      onPressed: () {},
                      icon: const Icon(Icons.send_rounded)),
            ),
          ]),
        ),
      );
}

class _CallsApi extends ApiClient {
  _CallsApi() {
    token = 't';
  }
  @override
  Future<Map<String, dynamic>> getJson(String path) async => {
        'calls': [
          {'id': 9, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
           'name': 'Shanto', 'member_id': 4, 'outcome': 'Missed call',
           'started_at': '2026-10-22T07:30:00Z'},
          {'id': 8, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
           'name': 'Shanto', 'member_id': 4, 'outcome': 'Missed call',
           'started_at': '2026-10-22T07:10:00Z'},
        ],
        'groups': [
          {'id': 9, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
           'name': 'Shanto', 'member_id': 4, 'outcome': 'Missed call',
           'started_at': '2026-10-22T07:30:00Z', 'count': 2, 'ids': [9, 8]},
        ],
      };
}

void main() {
  late Directory dir;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('wa2t');
    MediaDirs.override = dir.path;
    VoicePlayedStore.instance.resetForTest();
    voiceMicGranted = () async => true;
  });
  tearDown(() async {
    MediaDirs.override = null;
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  group('bubble grouping (pure)', () {
    final t0 = DateTime(2026, 10, 25, 20, 0);
    test('same sender within the gap = one run; else a new run', () {
      expect(
          sameBubbleRun(
              olderSender: 'me', olderAt: t0, sender: 'me',
              at: t0.add(const Duration(minutes: 2))),
          isTrue);
      expect(
          sameBubbleRun(
              olderSender: 'me', olderAt: t0, sender: 'me',
              at: t0.add(const Duration(minutes: 4))),
          isFalse,
          reason: 'a few minutes later starts a new run');
      expect(
          sameBubbleRun(olderSender: 'me', olderAt: t0, sender: 'peer', at: t0),
          isFalse);
      expect(
          sameBubbleRun(olderSender: null, olderAt: t0, sender: 'me', at: t0),
          isFalse,
          reason: 'a system line / call chip breaks a run');
    });

    test('newest-first rows: a date chip between two messages breaks the run',
        () {
      final y = DateTime(2026, 10, 24, 23, 59);
      final items = <(String, DateTime)>[
        ('peer', y),
        ('peer', DateTime(2026, 10, 25, 0, 0)), // next day, 1 min later
        ('peer', DateTime(2026, 10, 25, 0, 1)),
      ].reversed.toList(); // newest first like the reversed chat list
      final rows = insertDateSeparators<(String, DateTime)>(items, (r) => r.$2,
          newestFirst: true, toLocal: (d) => d);
      bool cont(int i) => continuesOlderRow<(String, DateTime)>(rows, i,
          senderOf: (r) => r.$1, atOf: (r) => r.$2);
      // rows: [00:01, 00:00, chip(25th), 23:59, chip(24th)]
      expect(rows[0], isA<ChatItemRow>());
      expect(cont(0), isTrue, reason: '00:01 continues 00:00');
      expect(cont(1), isFalse, reason: 'the date chip sits above 00:00');
      expect(cont(2), isFalse);
      expect(cont(rows.length - 1), isFalse);
    });

    test('tail only on the first bubble of a run (sender side, top)', () {
      final first = bubbleRadius(mine: true, continued: false);
      final next = bubbleRadius(mine: true, continued: true);
      expect(first.topRight.x, lessThan(first.topLeft.x));
      expect(next.topRight, next.topLeft);
      final inFirst = bubbleRadius(mine: false, continued: false);
      expect(inFirst.topLeft.x, lessThan(inFirst.topRight.x));
    });
  });

  group('bubble grouping (widget)', () {
    testWidgets('a continued bubble sits tight under the first', (tester) async {
      final at = DateTime(2026, 10, 25, 20);
      await tester.pumpWidget(_app(Scaffold(
        body: Column(children: [
          CircleBubble(
              key: const Key('b1'),
              msg: CircleMessage(id: '1', text: 'one', mine: false, at: at)),
          CircleBubble(
              key: const Key('b2'),
              continued: true,
              msg: CircleMessage(id: '2', text: 'two', mine: false, at: at)),
          CircleBubble(
              key: const Key('b3'),
              msg: CircleMessage(id: '3', text: 'three', mine: true, at: at)),
        ]),
      )));
      Rect box(String k) => tester.getRect(find.byKey(Key(k)));
      final gapRun = tester.getRect(find.text('two')).top -
          tester.getRect(find.text('one')).bottom;
      final gapNew = tester.getRect(find.text('three')).top -
          tester.getRect(find.text('two')).bottom;
      expect(gapNew - gapRun, greaterThanOrEqualTo(Gap.xs),
          reason: 'a new run gets air above it, a run sits tight');
      expect(box('b2').height, lessThan(box('b1').height),
          reason: 'the continued bubble has the smaller top margin');
      BorderRadius radiusOf(String k) {
        final c = tester
            .widgetList<Container>(find.descendant(
                of: find.byKey(Key(k)), matching: find.byType(Container)))
            .firstWhere((c) => c.decoration is BoxDecoration &&
                (c.decoration as BoxDecoration).borderRadius != null);
        return (c.decoration as BoxDecoration).borderRadius as BorderRadius;
      }
      expect(radiusOf('b1').topLeft, Radius.zero,
          reason: 'tail on the first bubble of a run');
      expect(radiusOf('b2').topLeft, const Radius.circular(Radii.lg));
      expect(radiusOf('b3').topRight, Radius.zero);
      expect(tester.takeException(), isNull);
    });
  });

  group('composer mic', () {
    testWidgets('empty box = Mic; typing swaps it for Send', (tester) async {
      await tester.pumpWidget(_app(_Composer(drafts: [], taps: [])));
      expect(find.byKey(const Key('wa2-mic')), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsNothing);
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      expect(find.byKey(const Key('wa2-mic')), findsNothing);
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);
      // 48 dp target
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      final s = tester.getSize(find.byKey(const Key('wa2-mic')));
      expect(s.width, greaterThanOrEqualTo(48));
      expect(s.height, greaterThanOrEqualTo(48));
    });

    testWidgets('tap opens hands-free (no recording)', (tester) async {
      final rec = _Rec();
      recorderFactory = () => rec;
      final taps = <String>[];
      await tester.pumpWidget(_app(_Composer(drafts: [], taps: taps)));
      await tester.tap(find.byKey(const Key('wa2-mic')));
      await tester.pump();
      expect(taps, ['tap']);
      expect(rec.calls, isEmpty);
    });

    testWidgets('hold records (strip + time), release sends a voice draft',
        (tester) async {
      final rec = _Rec();
      recorderFactory = () => rec;
      final drafts = <MediaDraft>[];
      await tester.pumpWidget(_app(_Composer(drafts: drafts, taps: [])));
      final g = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('wa2-mic'))));
      await tester.pump(const Duration(milliseconds: 600)); // long press
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1200)));
      await tester.pump(const Duration(milliseconds: 250));
      expect(rec.calls, ['start']);
      expect(find.byKey(const Key('wa2-rec-strip')), findsOneWidget);
      expect(find.text('Slide to cancel'), findsOneWidget);
      rec.amp.add(-10);
      await g.up();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(rec.calls, ['start', 'stop']);
      expect(drafts, hasLength(1));
      expect(drafts.single.kind, 'voice');
      expect(drafts.single.mime, 'audio/mp4');
      expect(drafts.single.durationMs, greaterThanOrEqualTo(1000));
      expect(find.byKey(const Key('wa2-rec-strip')), findsNothing);
    });

    testWidgets('slide left cancels: nothing sent, file gone', (tester) async {
      final rec = _Rec();
      recorderFactory = () => rec;
      final drafts = <MediaDraft>[];
      await tester.pumpWidget(_app(_Composer(drafts: drafts, taps: [])));
      final g = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('wa2-mic'))));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(-25, 0));
        await tester.pump();
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(rec.calls, ['start', 'cancel']);
      expect(drafts, isEmpty);
      expect(File(rec.path).existsSync(), isFalse);
      expect(find.text('Voice message discarded'), findsOneWidget);
    });

    testWidgets('a quick hold (< 1 s) is "too short", nothing sent',
        (tester) async {
      final rec = _Rec();
      recorderFactory = () => rec;
      final drafts = <MediaDraft>[];
      await tester.pumpWidget(_app(_Composer(drafts: drafts, taps: [])));
      final g = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('wa2-mic'))));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await g.up();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(drafts, isEmpty);
      expect(find.textContaining('Too short'), findsOneWidget);
    });

    testWidgets('no mic permission yet: explain first, never records',
        (tester) async {
      voiceMicGranted = () async => false;
      final rec = _Rec();
      recorderFactory = () => rec;
      await tester.pumpWidget(_app(_Composer(drafts: [], taps: [])));
      final g = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('wa2-mic'))));
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pumpAndSettle();
      // (the explain-then-ask dialog is the md1 flow; here the plugin is
      // absent, so it answers "no" — the point: nothing is recorded)
      expect(rec.calls, isEmpty);
      expect(find.byKey(const Key('wa2-rec-strip')), findsNothing);
    });

    testWidgets('Bangla strip: Bangla digits, fits 360 dp', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = VoiceHoldController();
      await tester.pumpWidget(_app(
          Scaffold(body: Center(child: SizedBox(width: 240, child: VoiceHoldStrip(controller: c)))),
          lang: 'bn'));
      expect(find.text('বাতিল করতে বাঁয়ে সরান'), findsOneWidget);
      expect(find.text('০:০০'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('voice-note bubble', () {
    test('seeded stand-in wave is stable, speech-like, in range', () {
      final a = seededWave(42), b = seededWave(42), c = seededWave(43);
      expect(a, b);
      expect(a, isNot(c));
      expect(a, hasLength(32));
      expect(a.every((v) => v >= 2 && v <= 31), isTrue);
      expect(a.toSet().length, greaterThan(4), reason: 'not a flat line');
    });

    testWidgets('unplayed dot on a received note; speed pill once playing',
        (tester) async {
      final fake = _Voice();
      VoicePlayer.backendFactory = () => fake;
      var played = false;
      await tester.pumpWidget(_app(StatefulBuilder(
        builder: (_, set) => Scaffold(
          body: VoiceNoteBody(
            path: '/x/a.m4a',
            durationMs: 8000,
            wave: const [],
            fg: Colors.black,
            unplayed: !played,
            onPlayed: (ok) => set(() => played = ok),
          ),
        ),
      )));
      expect(find.byKey(const Key('wa2-voice-unplayed')), findsOneWidget);
      expect(find.byKey(const Key('e-voice-rate')), findsNothing);
      await tester.tap(find.byKey(const Key('md1-voice-play')));
      await tester.pump();
      expect(find.byKey(const Key('wa2-voice-unplayed')), findsNothing);
      expect(find.byKey(const Key('e-voice-rate')), findsOneWidget);
      expect(find.text('1×'), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-voice-rate')));
      await tester.pump();
      expect(find.text('1.5×'), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-voice-rate')));
      await tester.pump();
      expect(find.text('2×'), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-voice-rate')));
      await tester.pump();
      await VoicePlayer.instance.stop();
    });

    test('played store remembers refs across loads', () async {
      final s = VoicePlayedStore.instance;
      await s.ensureLoaded();
      expect(s.isPlayed('r1'), isFalse);
      await s.mark('r1');
      expect(s.isPlayed('r1'), isTrue);
      s.resetForTest();
      await s.ensureLoaded();
      expect(s.isPlayed('r1'), isTrue, reason: 'persisted on this phone');
    });
  });

  group('call info', () {
    final rows = <Map<String, dynamic>>[
      {'id': 9, 'kind': 'video', 'state': 'missed', 'outgoing': false,
       'name': 'Shanto', 'member_id': 4, 'outcome': 'Missed call',
       'started_at': '2026-10-25T07:30:00Z'},
      {'id': 8, 'kind': 'voice', 'state': 'ended', 'outgoing': true,
       'name': 'Shanto', 'member_id': 4, 'duration_sec': 247,
       'duration': '04:07', 'started_at': '2026-10-25T07:00:00Z'},
    ];

    test('entries come from the row ids; facts from each row', () {
      final byId = {for (final r in rows) '${r['id']}': r};
      final group = {...rows.first, 'ids': [9, 8], 'count': 2};
      expect(callInfoEntries(group, byId).map((e) => e['id']), [9, 8]);
      expect(callInfoEntries({'id': 1}, byId).single['id'], 1);
      final m = callInfoOf(rows[0]);
      expect(m.missed && m.video && !m.outgoing, isTrue);
      final o = callInfoOf(rows[1]);
      expect(o.outgoing && !o.missed && o.talkSec == 247, isTrue);
      expect(callTalkLabel(247), '4:07');
      expect(callTalkLabel(3723), '1:02:03');
      expect(callInfoOf({'duration': '০১:০৫'}).talkSec, 65);
    });

    testWidgets('shows each call + Message / Voice / Video actions',
        (tester) async {
      final calls = <String>[];
      var messaged = false;
      await tester.pumpWidget(_app(CircleCallInfoScreen(
        call: rows.first,
        entries: rows,
        onCall: calls.add,
        onMessage: () => messaged = true,
      )));
      expect(find.text('Call info'), findsOneWidget);
      expect(find.text('Missed · Video call'), findsOneWidget);
      expect(find.text('Outgoing · Voice call'), findsOneWidget);
      expect(find.text('4:07'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wa2-call-info-voice')));
      await tester.tap(find.byKey(const Key('wa2-call-info-video')));
      await tester.tap(find.byKey(const Key('wa2-call-info-message')));
      expect(calls, ['voice', 'video']);
      expect(messaged, isTrue);
      final s = tester.getSize(find.byKey(const Key('wa2-call-info-voice')));
      expect(s.height, greaterThanOrEqualTo(48));
    });

    testWidgets('tapping a (grouped) log row opens Call info with each call',
        (tester) async {
      final s = AppState()
        ..api = _CallsApi()
        ..user = AppUser(
            id: 1, name: 'A', phone: '01712345678', email: '',
            autonomyLevel: 2, language: 'en')
        ..loading = false;
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: s, child: _app(const CircleCallHistoryScreen())));
      await tester.pumpAndSettle();
      expect(find.text('Shanto (2)'), findsOneWidget);
      await tester.tap(find.text('Shanto (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Call info'), findsOneWidget);
      expect(find.byKey(const ValueKey('wa2-call-entry-9')), findsOneWidget);
      expect(find.byKey(const ValueKey('wa2-call-entry-8')), findsOneWidget);
      expect(find.text('Missed · Voice call'), findsNWidgets(2));
    });

    testWidgets('Bangla: Bangla digits, no overflow at 360 dp, dark',
        (tester) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          CircleCallInfoScreen(call: rows.first, entries: rows),
          lang: 'bn',
          theme: AssistoTheme.dark));
      expect(find.text('কলের তথ্য'), findsOneWidget);
      expect(find.text('মিসড · ভিডিও কল'), findsOneWidget);
      expect(find.text('৪:০৭'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
