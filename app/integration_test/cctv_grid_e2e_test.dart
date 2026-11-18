// cctv-accuracy — Wi-Fi LIVE GRID measured ON A 2 GB EMULATOR
// (.github/workflows/cctv-grid.yml). The real grid screen + the real Dart
// RTSP client + the real native MediaCodec decoder slots play 4 and then 9
// test cameras (mediamtx on the CI runner: a 1280x720 main stream and a
// 640x360 sub stream per camera). Built as a PROFILE APK and started with
// `am start` (no VM service), like perf2gb. Every 10 s the screen's own
// meter prints one line:
//   GRID_E2E {"phase":..,"t_s":..,"mb_min":..,"rss_mb":..,"tiles":[{q,st,fps,kb_min,bytes}]}
// and the end prints GRID_E2E_DONE {...}. tools/e2e/cctv_grid_summary.py
// turns those + the host's dumpsys meminfo samples into the proof table.
//
// Phases (about 12.5 minutes in one app process, no restart):
//   grid4   4 cameras, 2 x 2, 5 min   -> every tile on SUB, ~6 fps
//   grid9   9 cameras, 3 x 3, 5 min   -> every tile on SUB, ~3 fps
//   scroll  9 cameras, 2 columns: the rows below the screen must be OFF
//           and their data must not grow; scrolled down, they come back
//   big     camera 1 opened big       -> MAIN stream, grid tiles OFF
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:assisto/ipcam/lan_grid_logic.dart';
import 'package:assisto/ipcam/lan_grid_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';

const _host = String.fromEnvironment('GRID_HOST', defaultValue: '10.0.2.2:18554');
const _phaseS = int.fromEnvironment('GRID_PHASE_S', defaultValue: 300);

List<LanCam> _cams(int n) => [
      for (var i = 1; i <= n; i++)
        LanCam('Cam $i', 'rtsp://viewer:viewpw@$_host/cam${i}_sub', 'rtsp://viewer:viewpw@$_host/cam${i}_main')
    ];

String _phase = 'start';
final _summary = <String, Object?>{};

void _line(Map<String, Object?> stats) =>
    // ignore: avoid_print
    print('GRID_E2E ${jsonEncode({'phase': _phase, ...stats})}');

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );

Future<void> _run(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
}

void main() {
  final b = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  b.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('cctv grid: 4 and 9 test cameras on a 2 GB phone', (tester) async {
    final t0 = DateTime.now();
    for (final (name, n, cols) in [('grid4', 4, 2), ('grid9', 9, 3)]) {
      _phase = name;
      final key = GlobalKey<LanGridScreenState>();
      await tester.pumpWidget(_app(LanGridScreen(key: key, cams: _cams(n), cols: cols, onStats: _line)));
      await _run(tester, Duration(seconds: _phaseS));
      _summary[name] = [for (var i = 0; i < n; i++) key.currentState!.debugQuality(i).name];
    }

    // scroll: 9 cameras in 2 columns -> the last rows start below the screen
    _phase = 'scroll';
    final key = GlobalKey<LanGridScreenState>();
    await tester.pumpWidget(_app(LanGridScreen(key: key, cams: _cams(9), cols: 2, onStats: _line)));
    await _run(tester, const Duration(seconds: 40));
    final st = key.currentState!;
    final q1 = [for (var i = 0; i < 9; i++) st.debugQuality(i).name];
    final bytesA = st.debugBytes();
    await _run(tester, const Duration(seconds: 30));
    final bytesB = st.debugBytes();
    _summary['scroll_top'] = {
      'quality': q1,
      'bytes_30s': [for (var i = 0; i < 9; i++) bytesB[i] - bytesA[i]],
    };
    await tester.drag(find.byType(GridView), const Offset(0, -2000));
    await _run(tester, const Duration(seconds: 25));
    _summary['scroll_bottom'] = {'quality': [for (var i = 0; i < 9; i++) st.debugQuality(i).name]};

    // big: camera 9 (on screen now) opened big -> main stream
    _phase = 'big';
    await tester.tap(find.byKey(const ValueKey('lvg-tile-grid8')));
    await _run(tester, const Duration(seconds: 60));
    final big = tester.widget<LanBigView>(find.byType(LanBigView));
    _summary['big'] = {
      'quality': big.feed.quality.name,
      'frames': big.feed.frames,
      'kb_min': big.feed.meter.kbPerMin(DateTime.now()).round(),
      'fps': double.parse(big.feed.meter.fps(DateTime.now()).toStringAsFixed(1)),
      'grid_while_big': [for (var i = 0; i < 9; i++) st.debugQuality(i).name],
    };
    _summary['minutes'] = (DateTime.now().difference(t0).inSeconds / 60).toStringAsFixed(1);
    // ignore: avoid_print
    print('GRID_E2E_DONE ${jsonEncode(_summary)}');
    await tester.pumpWidget(const SizedBox());
    await _run(tester, const Duration(seconds: 3));
  }, timeout: const Timeout(Duration(minutes: 25)));
}
