// qcircle (quality push 9 Nov) — My Circle quiet hours: messages still
// arrive, silently, inside the user's window; calls / SOS untouched.
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/media/album.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/photo_album_view.dart';
import 'package:assisto/messaging/msg_prefs.dart';
import 'package:assisto/messaging/msg_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'md1_media_test.dart' show FakeServer;

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

MediaDescriptor _desc(int i, int n) => MediaDescriptor(
    kind: 'photo', ref: '$i'.padLeft(32, 'q'), key: Uint8List(32)..[0] = 1,
    nonce: Uint8List(12), sha256: 'e' * 64, size: 1000, plainSize: 968,
    mime: 'image/jpeg', width: 400, height: 300, thumb: null, caption: '',
    album: AlbumRef(id: 'a', index: i, count: n));

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
        if (lang == 'en') {
          expect(find.textContaining('22:00'), findsOneWidget);
        }
        if (lang == 'bn') {
          // Bangla digits only, no ASCII digit leaks
          final sub = tester
              .widgetList<Text>(find.descendant(of: win, matching: find.byType(Text)))
              .map((w) => w.data ?? '')
              .join(' ');
          expect(RegExp(r'[0-9]').hasMatch(sub), isFalse, reason: sub);
          expect(sub, contains('২২:০০'));
          expect(sub, contains('০৭:০০'));
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('album: long-press acts on the pressed photo (owner limit fixed)', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('qct');
      MediaDirs.override = dir.path;
      MediaPrefs.metered = () async => true; // no auto download
      MediaCache.instance = MediaCache(transport: FakeServer());
    });
    tearDown(() async {
      MediaDirs.override = null;
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('each tile reports its own index; single photo has no tile handler',
        (tester) async {
      final got = <int>[];
      final items = [
        for (var i = 0; i < 4; i++) AlbumItem(id: '$i', desc: _desc(i, 4))
      ];
      await tester.pumpWidget(_wrap(Scaffold(
          body: Center(
              child: PhotoAlbumView(
                  items: items,
                  size: const Size(260, 260),
                  onLongPressItem: got.add)))));
      await tester.pump();
      for (final i in [2, 0, 3]) {
        await tester.longPress(find.byKey(ValueKey('qc-album-lp-$i')));
        await tester.pump();
      }
      expect(got, [2, 0, 3]);

      await tester.pumpWidget(_wrap(Scaffold(
          body: Center(
              child: PhotoAlbumView(
                  items: [AlbumItem(id: 'x', desc: _desc(0, 1))],
                  size: const Size(260, 260),
                  onLongPressItem: got.add)))));
      await tester.pump();
      expect(find.byKey(const ValueKey('qc-album-lp-0')), findsNothing);
    });

    test('both chat screens wire the per-photo long-press', () {
      expect(File('lib/screens/circle_chat_screen.dart').readAsStringSync(),
          contains('onLongPressAlbumItem:'));
      expect(File('lib/screens/circle_group_chat_screen.dart').readAsStringSync(),
          contains('onLongPressItem:'));
    });
  });
}
