// lpaudio: IELTS recorded listening flow — exam mode runs like the real
// computer-delivered test (question time -> recording once, no pause -> check
// time -> next part by itself -> done), practice mode plays / pauses / replays,
// a part without audio shows an honest "not ready" card (never the script).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/lp2/lp_listen.dart';
import 'package:assisto/theme.dart';

class _FakeEngine implements LpAudioEngine {
  final loads = <String>[];
  int plays = 0, pauses = 0;
  final _pos = StreamController<Duration>.broadcast();
  final _done = StreamController<void>.broadcast();
  @override
  Future<void> load(String src) async => loads.add(src);
  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> restart() async => plays++;
  @override
  Stream<Duration> get position => _pos.stream;
  @override
  Stream<void> get completed => _done.stream;
  void finish() => _done.add(null);
  void at(int s) => _pos.add(Duration(seconds: s));
  @override
  Future<void> dispose() async {}
}

List<Map<String, dynamic>> _parts({bool audio = true}) => [
      for (var i = 1; i <= 4; i++)
        {
          'n': i,
          'audio_url': audio ? 'https://lifeassisto.com/api/v1/m/lp/p$i.m4a?sig=x' : null,
          'duration_sec': 300.0,
          'accents': i == 3 ? ['en-US'] : ['en-GB'],
          'preview_sec': 30,
          'check_sec': i == 4 ? 120 : 30,
          'questions': [
            for (var q = 1; q <= 10; q++) {'n': (i - 1) * 10 + q, 'type': 'gap', 'prompt': 'Q'}
          ],
        }
    ];

class _Host extends StatefulWidget {
  final List<Map<String, dynamic>> parts;
  final bool replay;
  final List<bool> running;
  const _Host(this.parts, this.replay, this.running);
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int part = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView(children: [
          Text('showing $part', key: const Key('showing')),
          LpListenPanel(
            parts: widget.parts,
            part: part,
            replay: widget.replay,
            onPart: (i) => setState(() => part = i),
            onRunning: widget.running.add,
          ),
        ]),
      );
}

Widget _app(Widget child, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

Future<void> _secs(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(seconds: 1));
  }
  await _settle(t);
}

/// Stream events + async gaps land, then one more frame.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump();
}

void main() {
  late _FakeEngine eng;
  setUp(() {
    eng = _FakeEngine();
    debugLpEngine = () => eng;
  });
  tearDown(() => debugLpEngine = null);

  testWidgets('exam mode: question time -> once -> check time -> next part by itself -> done', (t) async {
    final running = <bool>[];
    await t.pumpWidget(_app(_Host(_parts(), false, running)));
    expect(find.text('Exam mode: the recording plays once.'), findsOneWidget);
    expect(find.text('About 20 minutes of recording'), findsOneWidget);
    expect(find.byKey(const Key('lp2-play')), findsNothing); // no pause button in the exam
    await t.tap(find.byKey(const Key('lp2-listen-start')));
    await _settle(t);
    expect(running, [true]);
    expect(eng.loads.single, contains('p1.m4a'));        // buffers during the question time
    expect(find.text('Read questions 1–10'), findsOneWidget);
    expect(find.text('00:30'), findsOneWidget);
    expect(eng.plays, 0);
    await _secs(t, 30);
    expect(eng.plays, 1);                                // the recording starts by itself
    expect(find.text('Playing…'), findsOneWidget);
    eng.at(150);
    await _settle(t);
    expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.5, 0.01));
    eng.finish();
    await _settle(t);
    expect(find.text('Check your answers'), findsOneWidget);
    await _secs(t, 30);
    expect(find.text('showing 1'), findsOneWidget);       // part 2 opened by itself
    expect(eng.loads.last, contains('p2.m4a'));
    expect(find.text('Part 2 of 4'), findsOneWidget);
    for (var p = 2; p <= 4; p++) {
      await _secs(t, 30);
      eng.finish();
      await _settle(t);
      await _secs(t, p == 4 ? 120 : 30);
    }
    expect(eng.plays, 4);                                 // each recording played exactly once
    expect(find.textContaining('Listening finished.'), findsOneWidget);
    expect(running, [true, false]);
  });

  testWidgets('exam mode: a part without audio -> honest not-ready card, no start', (t) async {
    final parts = _parts();
    parts[2]['audio_url'] = null;
    await t.pumpWidget(_app(_Host(parts, false, [])));
    expect(find.byKey(const Key('lp2-audio-missing')), findsOneWidget);
    expect(find.byKey(const Key('lp2-listen-start')), findsNothing);
  });

  testWidgets('practice mode: play, pause, replay, next part', (t) async {
    await t.pumpWidget(_app(_Host(_parts(), true, [])));
    expect(find.text('Practice mode: you can replay.'), findsOneWidget);
    await t.tap(find.byKey(const Key('lp2-play')));
    await _settle(t);
    expect(eng.plays, 1);
    await t.tap(find.byKey(const Key('lp2-play')));
    await _settle(t);
    expect(eng.pauses, 1);
    await t.tap(find.byKey(const Key('lp2-play')));
    await _settle(t);
    eng.finish();
    await _settle(t);
    await t.tap(find.byKey(const Key('lp2-listen-next')));
    await _settle(t);
    expect(find.text('showing 1'), findsOneWidget);
    await t.tap(find.byKey(const Key('lp2-play')));
    await _settle(t);
    expect(eng.loads.last, contains('p2.m4a'));
  });

  testWidgets('Bangla: Bangla digits and accent names', (t) async {
    await t.pumpWidget(_app(_Host(_parts(), false, []), lang: 'bn'));
    expect(find.text('পার্ট ১ / ৪'), findsOneWidget);
    expect(find.textContaining('ব্রিটিশ ইংরেজি'), findsOneWidget);
    await t.tap(find.byKey(const Key('lp2-listen-start')));
    await _settle(t);
    expect(find.text('১–১০ নম্বর প্রশ্ন পড়ে নিন'), findsOneWidget);
    expect(find.text('০০:৩০'), findsOneWidget);
  });
}
