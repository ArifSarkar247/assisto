// gap-cctv3: Imou recording playback in Past clips — day timeline, hour →
// low-data HLS, honest "needs an SD card or Imou cloud plan", error states.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/video_ctl.dart';
import 'package:assisto/screens/watchman/cctv_clips_screen.dart';
import 'package:assisto/screens/watchman/cctv_playback_screen.dart';
import 'package:assisto/theme.dart';

import 'cctvguard_fakes.dart' show FakeNetCtl;
import 'gap_cctv_shots.dart' show GapFakeClips, GapFakePlayback, gapNow;

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    MaterialApp(
      key: UniqueKey(),
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _phone(WidgetTester tester, {double height = 2000}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

late AppLocalizations en;
late AppLocalizations bn;

Widget _screen(GapFakePlayback src, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    _app(CctvPlaybackScreen(cameraId: 7, cameraName: 'Gate', source: src, clock: gapNow),
        lang: lang, scale: scale, dark: dark);

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });

  late VideoNetFactory oldNet;
  late List<Uri> played;
  setUp(() {
    oldNet = VideoCtls.networkFactory;
    played = [];
    VideoCtls.networkFactory = (u) async {
      played.add(u);
      return FakeNetCtl();
    };
  });
  tearDown(() => VideoCtls.networkFactory = oldNet);

  testWidgets('tap an hour: asks the server for exactly that hour, plays HLS muted, lists records',
      (tester) async {
    _phone(tester);
    final src = GapFakePlayback();
    await tester.pumpWidget(_screen(src));
    await _settle(tester);
    expect(find.text(en.gcvPbLowData), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-10')));
    await _settle(tester, 12);
    final start = DateTime(2026, 11, 17, 10).millisecondsSinceEpoch ~/ 1000;
    expect(src.asked.single, (7, start, start + 3600));
    expect(played.single.toString(), startsWith('https://'));
    expect(find.byKey(const ValueKey('gcv-pb-player')), findsOneWidget);
    expect(find.text(en.gcvPbFromSd), findsOneWidget);
    expect(find.text('10:05 – 10:20'), findsOneWidget);
  });

  testWidgets('the future is never offered; the current hour ends at "now"', (tester) async {
    _phone(tester);
    final src = GapFakePlayback();
    await tester.pumpWidget(_screen(src));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-20')));
    await _settle(tester);
    expect(src.asked, isEmpty, reason: '20:00 is after "now" (14:30)');
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-14')));
    await _settle(tester, 12);
    final s = DateTime(2026, 11, 17, 14).millisecondsSinceEpoch ~/ 1000;
    expect(src.asked.single, (7, s, s + 30 * 60));
  });

  testWidgets('yesterday: the whole day is offered', (tester) async {
    _phone(tester);
    final src = GapFakePlayback();
    await tester.pumpWidget(_screen(src));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-day-1')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-22')));
    await _settle(tester, 12);
    final s = DateTime(2026, 11, 16, 22).millisecondsSinceEpoch ~/ 1000;
    expect(src.asked.single, (7, s, s + 3600));
  });

  testWidgets('no recording: the honest SD card / Imou cloud plan line, hour marked empty',
      (tester) async {
    _phone(tester);
    await tester.pumpWidget(_screen(GapFakePlayback(fail:
        ApiException('No video', 502, null, 'vendor_no_stream'))));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-9')));
    await _settle(tester, 12);
    expect(find.text(en.gcvPbNoRecording), findsOneWidget);
    expect(find.text(en.wmRetry), findsNothing, reason: 'retrying will not make a recording');
  });

  testWidgets('firmware that cannot stream: records listed + "watch in Imou Life"', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_screen(GapFakePlayback(sdkOnly: true)));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-10')));
    await _settle(tester, 12);
    expect(find.text(en.gcvPbSdkOnly), findsOneWidget);
    expect(find.text(en.gcvPbRecordsTitle), findsOneWidget);
    expect(played, isEmpty);
  });

  for (final c in [
    ('vendor_not_configured', 'notConfigured'),
    ('vendor_revoked', 'revoked'),
    ('vendor_network', 'network'),
  ]) {
    testWidgets('error ${c.$1} has a plain message', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
          _screen(GapFakePlayback(fail: ApiException('x', 502, null, c.$1))));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-9')));
      await _settle(tester, 12);
      expect(find.byKey(ValueKey('gcv-pb-problem-${c.$2}')), findsOneWidget);
    });
  }

  testWidgets('network trouble offers Retry; the player failing offers Retry', (tester) async {
    _phone(tester);
    final src = GapFakePlayback(fail: ApiException('x', 502, null, 'vendor_network'));
    await tester.pumpWidget(_screen(src));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-9')));
    await _settle(tester, 12);
    await tester.tap(find.text(en.wmRetry));
    await _settle(tester, 12);
    expect(src.asked.length, 2);
    VideoCtls.networkFactory = (u) async => FakeNetCtl(fail: 'codec');
    await tester.pumpWidget(_screen(GapFakePlayback()));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-10')));
    await _settle(tester, 12);
    expect(find.byKey(const ValueKey('gcv-pb-play-error')), findsOneWidget);
  });

  testWidgets('Past clips links to the recordings of a camera that can play them',
      (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(CctvClipsScreen(
        source: GapFakeClips(), siteId: 1, owner: true, playback: GapFakePlayback())));
    await _settle(tester);
    expect(find.byKey(const ValueKey('gcv-clips-rec-11')), findsOneWidget);
    expect(find.byKey(const ValueKey('gcv-clips-rec-12')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('gcv-clips-rec-11')));
    await _settle(tester, 12);
    expect(find.byKey(const ValueKey('gcv-pb-timeline')), findsOneWidget);
  });

  testWidgets('Bangla digits on the timeline; hour cells are >= 48 dp', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_screen(GapFakePlayback(), lang: 'bn'));
    await _settle(tester);
    expect(find.text('১০'), findsOneWidget);
    final sz = tester.getSize(find.byKey(const ValueKey('gcv-pb-hour-10')));
    expect(sz.height, greaterThanOrEqualTo(48));
    expect(sz.width, greaterThanOrEqualTo(48));
  });

  for (final lang in ['bn', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('playback at 200% text — $lang ${dark ? 'dark' : 'light'}', (tester) async {
        _phone(tester, height: 900);
        await tester.pumpWidget(_screen(GapFakePlayback(), lang: lang, scale: 2.0, dark: dark));
        await _settle(tester);
        // the outer list builds lazily at 200%: drag it until the hour exists
        await tester.dragUntilVisible(find.byKey(const ValueKey('gcv-pb-hour-10')),
            find.byType(ListView).first, const Offset(0, -200));
        await _settle(tester);
        await tester.tap(find.byKey(const ValueKey('gcv-pb-hour-10')));
        await _settle(tester, 12);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
