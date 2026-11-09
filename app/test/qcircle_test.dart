// qcircle (quality push 9 Nov) — My Circle quiet hours: messages still
// arrive, silently, inside the user's window; calls / SOS untouched.
import 'dart:io';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/msg_prefs.dart';
import 'package:assisto/messaging/msg_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ch = MethodChannel('com.assisto/c3_messaging');

void _mockNative() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ch, (call) async {
    switch (call.method) {
      case 'bubblesSupported':
        return true;
      case 'bubblesAllowed':
        return true;
    }
    return null;
  });
}

Widget _wrap(Widget child, {String lang = 'en', double scale = 1}) =>
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: w!),
      home: child,
    );

DateTime _at(int h, int m) => DateTime(2026, 11, 9, h, m);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ch, null));

  group('quiet window (pure)', () {
    test('overnight 22:00 → 07:00 wraps midnight', () {
      const s = 22 * 60, e = 7 * 60;
      expect(MsgPrefs.inQuietWindow(_at(23, 30), s, e), isTrue);
      expect(MsgPrefs.inQuietWindow(_at(0, 0), s, e), isTrue);
      expect(MsgPrefs.inQuietWindow(_at(6, 59), s, e), isTrue);
      expect(MsgPrefs.inQuietWindow(_at(7, 0), s, e), isFalse);
      expect(MsgPrefs.inQuietWindow(_at(12, 0), s, e), isFalse);
      expect(MsgPrefs.inQuietWindow(_at(21, 59), s, e), isFalse);
      expect(MsgPrefs.inQuietWindow(_at(22, 0), s, e), isTrue);
    });
    test('same-day window 13:00 → 15:00', () {
      expect(MsgPrefs.inQuietWindow(_at(14, 0), 780, 900), isTrue);
      expect(MsgPrefs.inQuietWindow(_at(15, 0), 780, 900), isFalse);
      expect(MsgPrefs.inQuietWindow(_at(12, 59), 780, 900), isFalse);
    });
    test('start == end never silences', () {
      expect(MsgPrefs.inQuietWindow(_at(3, 0), 600, 600), isFalse);
    });
  });

  group('quietNow (prefs)', () {
    test('off by default — a fresh install is never silenced', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await MsgPrefs.quietOn(), isFalse);
      expect(await MsgPrefs.quietNow(_at(23, 0)), isFalse);
    });
    test('on + default window 22:00–07:00', () async {
      SharedPreferences.setMockInitialValues({});
      await MsgPrefs.setQuietOn(true);
      expect(await MsgPrefs.quietNow(_at(23, 0)), isTrue);
      expect(await MsgPrefs.quietNow(_at(10, 0)), isFalse);
    });
    test('custom window is stored and clamped', () async {
      SharedPreferences.setMockInitialValues({});
      await MsgPrefs.setQuietOn(true);
      await MsgPrefs.setQuietWindow(13 * 60, 2000);
      expect(await MsgPrefs.quietStart(), 780);
      expect(await MsgPrefs.quietEnd(), 1439);
      expect(await MsgPrefs.quietNow(_at(14, 0)), isTrue);
    });
  });

  test('the message sink silences inside quiet hours (source guard)', () {
    final src = File('lib/messaging/msg_notify.dart').readAsStringSync();
    expect(src, contains('MsgPrefs.quietNow()'));
    // calls / SOS are drawn by PushNotifier, never through the message sink
    final pn = File('lib/push/push_notifier.dart').readAsStringSync();
    expect(pn.contains('quietNow'), isFalse);
  });

  group('settings tile', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('switch shows the window ($lang, 200% font)', (tester) async {
        SharedPreferences.setMockInitialValues({});
        _mockNative();
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_wrap(
            const Scaffold(
                body: SingleChildScrollView(child: MsgDeviceNotifSection())),
            lang: lang,
            scale: 2));
        await tester.pumpAndSettle();
        final sw = find.byKey(const Key('qc-quiet-hours'));
        await tester.ensureVisible(sw);
        expect(tester.widget<SwitchListTile>(sw).value, isFalse);
        expect(find.byKey(const Key('qc-quiet-window')), findsNothing);
        expect(tester.getSize(sw).height, greaterThanOrEqualTo(48));
        await tester.tap(sw);
        await tester.pumpAndSettle();
        expect(await MsgPrefs.quietOn(), isTrue);
        final win = find.byKey(const Key('qc-quiet-window'));
        expect(win, findsOneWidget);
        expect(tester.getSize(win).height, greaterThanOrEqualTo(48));
        if (lang == 'bn') {
          // Bangla digits only, no ASCII digit leaks
          final sub = tester
              .widgetList<Text>(find.descendant(of: win, matching: find.byType(Text)))
              .map((w) => w.data ?? '')
              .join(' ');
          expect(RegExp(r'[0-9]').hasMatch(sub), isFalse, reason: sub);
          expect(sub, contains('১০'));
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
