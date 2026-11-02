// cctvactivity (W10 activity brain + visitor log): the Activity screen against
// a fake server — the day in numbers, visitors next to sales, open/close
// confirm, watchman hours, camera health, the visitor log search (AI vs
// labelled automatic text), the time-lapse built from real JPEG bytes in pure
// Dart, empty states with a benefit + how-to, a working retry, read-only
// viewers, Bangla digits, 200% text + dark with no overflow.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/cctvx/timelapse_gif.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/watchman/activity_screen.dart';
import 'package:assisto/theme.dart';

import 'cctvactivity_fakes.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
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
      builder: (ctx, child) =>
          MediaQuery(data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: home,
    );

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text(label));
}

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 7000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

ActivityScreen _screen(FakeActivity f, {bool owner = true, int tab = 0}) => ActivityScreen(
    source: f, siteId: 7, siteName: 'Rahim Store', owner: owner, initialTab: tab, today: DateTime(2026, 11, 2, 23));

void main() {
  testWidgets('summary: lines, visitors next to sales, watchman hours, health', (tester) async {
    _tall(tester);
    final f = FakeActivity('data');
    await tester.pumpWidget(_app(_screen(f)));
    await _settle(tester);
    expect(find.textContaining('Visitors: 46 (estimate)'), findsOneWidget);
    expect(find.text('46 visitors · 13 sales · conversion 28.3%'), findsOneWidget);
    expect(find.textContaining('Busiest: 10:00–11:00, 18:00–19:00'), findsOneWidget);
    expect(find.textContaining('Estimate from person alerts'), findsOneWidget);
    expect(find.textContaining('Seen 6 h · not seen 1 h · camera offline 1 h'), findsOneWidget);
    expect(find.textContaining('00:00–01:00 · Not seen'), findsOneWidget);
    expect(find.textContaining('01:00–02:00 · Camera offline'), findsOneWidget);
    expect(find.text('Offline 12 min'), findsOneWidget);
    expect(find.text('No photo this day'), findsOneWidget);
    expect(find.textContaining('every morning at 8:00'), findsOneWidget);
    // next day is not offered on "today"
    final next = tester.widget<IconButton>(find.byKey(const ValueKey('cact-next')));
    expect(next.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('cact-prev')));
    await _settle(tester);
    expect(f.loads, 2);
  });

  testWidgets('owner confirms the camera times in one tap', (tester) async {
    _tall(tester);
    final f = FakeActivity('data');
    await tester.pumpWidget(_app(_screen(f)));
    await _settle(tester);
    expect(find.text('Opened 09:12 · Closed 21:40'), findsOneWidget);
    expect(find.textContaining('first and last person'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cact-oc-ok')));
    await _settle(tester);
    expect(f.confirms.single, {'date': '2026-11-02', 'open': '09:12', 'close': '21:40'});
    expect(find.text('Confirmed by you'), findsOneWidget);
    expect(find.byKey(const ValueKey('cact-oc-ok')), findsNothing);
  });

  testWidgets('settings sheet saves the watchman check', (tester) async {
    _tall(tester);
    final f = FakeActivity('empty');
    await tester.pumpWidget(_app(_screen(f)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('cact-wm-on')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cact-wm-on')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('cact-set-wm')));
    await _settle(tester);
    expect(find.text('Watchman cameras'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('cact-set-save')));
    await tester.tap(find.byKey(const ValueKey('cact-set-save')));
    await _settle(tester);
    expect(f.saved.single['wm_on'], true);
    expect(f.saved.single['wm_start'], '22:00');
    expect(f.saved.single.containsKey('cameras'), isFalse);
  });

  testWidgets('empty day: benefit + how-to on every tab, never a dead end', (tester) async {
    _tall(tester);
    final f = FakeActivity('empty');
    await tester.pumpWidget(_app(_screen(f)));
    await _settle(tester);
    expect(find.text('No visitors counted yet'), findsOneWidget);
    expect(find.textContaining('Draw an entry line'), findsOneWidget);
    expect(find.text('No movement was seen on the shop cameras this day.'), findsOneWidget);
    await _tab(tester, 'Visitor log');
    await _settle(tester);
    expect(find.text('No visitors in the log'), findsOneWidget);
    expect(find.textContaining("schedule 'Always'"), findsOneWidget);
    await _tab(tester, 'Time-lapse');
    await _settle(tester);
    expect(find.text('No photos for a time-lapse'), findsOneWidget);
  });

  testWidgets('load error has a working retry', (tester) async {
    _tall(tester);
    final f = FakeActivity('fail');
    await tester.pumpWidget(_app(_screen(f)));
    await _settle(tester);
    expect(find.text('Try again'), findsWidgets);
    await tester.tap(find.text('Try again').first);
    await _settle(tester);
    expect(f.loads, 2);
  });

  testWidgets('visitor log: search by words, AI vs automatic text labels, clear', (tester) async {
    _tall(tester);
    final f = FakeActivity('data');
    await tester.pumpWidget(_app(_screen(f, tab: 1)));
    await _settle(tester);
    expect(find.text('AI description'), findsOneWidget);
    expect(find.text('Automatic text (not AI)'), findsOneWidget);
    expect(find.textContaining('No face recognition'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('cact-vis-q')), 'red shirt');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(find.textContaining('red shirt'), findsWidgets);
    expect(find.text('Automatic text (not AI)'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('cact-vis-q')), 'bicycle');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(find.text('Nothing matches “bicycle”.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Clear search'));
    await _settle(tester);
    expect(find.text('AI description'), findsOneWidget);
    // time-of-day filter goes to the server
    await tester.tap(find.text('Night 10–6'));
    await _settle(tester);
    expect(f.queries.last, '|22:00|06:00|1');
  });

  testWidgets('time-lapse tab: photo count, honest note, make button', (tester) async {
    _tall(tester);
    final f = FakeActivity('data');
    await tester.pumpWidget(_app(_screen(f, tab: 2)));
    await _settle(tester);
    expect(find.textContaining('24 stored photos'), findsOneWidget);
    expect(find.text('A photo sequence, not full video.'), findsOneWidget);
    expect(find.byKey(const ValueKey('cact-tl-make')), findsOneWidget);
    expect(find.byKey(const ValueKey('cact-tl-share')), findsNothing);
  });

  testWidgets('family viewer: read-only, no settings, no confirm', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(_screen(FakeActivity('viewer'), owner: false)));
    await _settle(tester);
    expect(find.byKey(const ValueKey('cact-settings')), findsNothing);
    expect(find.byKey(const ValueKey('cact-oc-ok')), findsNothing);
    expect(find.byKey(const ValueKey('cact-oc-change')), findsNothing);
    expect(find.textContaining('only the owner can change'), findsOneWidget);
  });

  testWidgets('Bangla: Bangla digits, no ASCII digits in the numbers', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_app(_screen(FakeActivity('data', lang: 'bn')), lang: 'bn'));
    await _settle(tester);
    expect(find.text('৪৬ জন আগন্তুক · ১৩টি বিক্রি · কনভার্সন ২৮.৩%'), findsOneWidget);
    expect(find.text('খুলেছে ০৯:১২ · বন্ধ ২১:৪০'), findsOneWidget);
    expect(find.text('১২ মিনিট বন্ধ'), findsOneWidget);
    expect(find.textContaining('০০:০০–০১:০০'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('200% text ${dark ? 'dark' : 'light'}: no overflow on all tabs', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_screen(FakeActivity('data', lang: 'bn')), lang: 'bn', scale: 2.0, dark: dark));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await _tab(tester, 'ভিজিটর লগ');
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await _tab(tester, 'টাইম-ল্যাপ্স');
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('টাইম-ল্যাপ্স বানান'), findsOneWidget);
    });
  }

  test('time-lapse GIF is built on the phone from real JPEG bytes', () {
    expect(timelapseDelayCs(60), 50);
    expect(timelapseDelayCs(3), 200);
    expect(timelapseDelayCs(1000), 10);
    expect(spreadFrames(List.generate(10, (i) => i), 3), [0, 5, 9]);
    final frames = <Uint8List>[for (var i = 0; i < 4; i++) testJpeg(i), Uint8List.fromList([1, 2, 3])];
    final gif = buildTimelapseGif({'frames': frames, 'labels': ['08:00', '08:30', '09:00', '09:30', 'x']});
    expect(gif, isNotNull);
    expect(String.fromCharCodes(gif!.sublist(0, 6)), 'GIF89a');
    expect(buildTimelapseGif({'frames': <Uint8List>[Uint8List.fromList([0, 1])], 'labels': <String>[]}), isNull);
  });
}
