// bubbles (owner 2 Nov, part B) — Messenger-style floating chat bubbles via
// the official Android Bubbles API. Kotlin is only compiled by the daily APK
// build, so this file pins (1) the attach decision (Dart mirror of
// BubbleHelper.shouldAttach), (2) the prefs the native side reads, (3) the
// native/manifest contract by source text, (4) the light bubble window and
// the settings UI (bn/en, 48dp, 200% font).
import 'dart:io';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/bubble_main.dart';
import 'package:assisto/messaging/bubble_policy.dart';
import 'package:assisto/messaging/msg_prefs.dart';
import 'package:assisto/messaging/msg_settings_section.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/a11y_prefs.dart';
import 'package:assisto/widgets/group_menu_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ch = MethodChannel('com.assisto/c3_messaging');

String _src(String p) => File(p).readAsStringSync();
const _kt = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/messaging';

void _mockNative({bool supported = true, List<MethodCall>? log}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ch, (call) async {
    log?.add(call);
    switch (call.method) {
      case 'bubblesSupported':
        return supported;
      case 'bubblesAllowed':
        return true;
      case 'openInApp':
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

AppState _state({bool signedIn = true, String lang = 'en'}) {
  final s = AppState()
    ..locale = Locale(lang)
    ..loading = false;
  if (signedIn) {
    s.api.token = 't';
    s.user = AppUser(
        id: 1, name: 'Rina', phone: '', email: '', autonomyLevel: 2, language: lang);
  }
  return s;
}

Widget _bubbleApp(AppState s,
        {Future<String?> Function()? take,
        Future<Widget> Function(AppState, String, int)? build}) =>
    ChangeNotifierProvider<AppState>.value(
      value: s,
      child: BubbleChatApp(a11y: A11yPrefs(), takeChat: take, buildChat: build),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('attach decision (mirror of BubbleHelper.shouldAttach)', () {
    bool d({
      int sdk = 33,
      String kind = 'member',
      int id = 12,
      bool? global,
      Set<String> off = const {},
      bool locked = false,
      bool hide = false,
      bool shortcut = true,
    }) =>
        BubblePolicy.shouldAttach(
            sdkInt: sdk,
            kind: kind,
            id: id,
            globalOn: global,
            offChats: off,
            locked: locked,
            hideContent: hide,
            hasShortcut: shortcut);

    test('default ON for every chat on Android 11+', () {
      expect(d(), isTrue);
      expect(d(kind: 'group', id: 3), isTrue);
      expect(d(sdk: 30), isTrue);
      expect(d(sdk: 36), isTrue);
    });
    test('Android 10 and below: normal notification only', () {
      expect(d(sdk: 29), isFalse);
      expect(d(sdk: 26), isFalse);
    });
    test('global switch and per-chat OFF list', () {
      expect(d(global: false), isFalse);
      expect(d(global: true), isTrue);
      expect(d(off: {'member:12'}), isFalse);
      expect(d(off: {'group:12'}), isTrue, reason: 'group 12 != member 12');
      expect(d(kind: 'group', id: 12, off: {'group:12'}), isFalse);
    });
    test('privacy: locked chat / hidden content / no shortcut never bubble', () {
      expect(d(locked: true), isFalse);
      expect(d(hide: true), isFalse);
      expect(d(shortcut: false), isFalse);
      expect(d(id: 0), isFalse);
    });
    test('chat keys match the native tag/shortcut scheme', () {
      expect(BubblePolicy.chatKey('member', 7), 'member:7');
      expect(BubblePolicy.chatKey('anything', 7), 'member:7');
      expect(BubblePolicy.chatKey('group', 7), 'group:7');
      expect(BubblePolicy.parse(' member:1, ,group:2 '), {'member:1', 'group:2'});
    });
  });

  group('prefs the native side reads', () {
    test('every chat ON by default; OFF list is a plain sorted string', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await MsgPrefs.bubblesOn(), isTrue);
      expect(await MsgPrefs.isBubbleChat('member', 5), isTrue);
      await MsgPrefs.setBubbleChat('member', 5, false);
      await MsgPrefs.setBubbleChat('group', 2, false);
      final p = await SharedPreferences.getInstance();
      expect(MsgPrefs.kBubbleOffChats, 'c3_bubble_off_chats');
      expect(p.getString('c3_bubble_off_chats'), 'group:2,member:5');
      expect(await MsgPrefs.bubbleOffChats(), hasLength(2));
      await MsgPrefs.clearBubbleOffChats();
      expect(await MsgPrefs.isBubbleChat('group', 2), isTrue);
      expect(await MsgPrefs.bubbleOffChats(), isEmpty);
    });
    test('old opt-in list does not turn anything off', () async {
      SharedPreferences.setMockInitialValues({'c3_bubble_chats': 'member:9'});
      expect(await MsgPrefs.isBubbleChat('member', 9), isTrue);
      expect(await MsgPrefs.isBubbleChat('member', 10), isTrue);
    });
  });

  group('native + manifest contract (source text; compiled by the APK build)', () {
    test('BubbleHelper mirrors the Dart rule with the same keys', () {
      final k = _src('$_kt/BubbleHelper.kt');
      for (final s in [
        'Build.VERSION_CODES.R',
        '"flutter.c3_bubbles_on"',
        '"flutter.c3_bubble_off_chats"',
        '"flutter.c3_msg_hide_content"',
        'hasShortcut = !n.shortcutId.isNullOrEmpty()',
        'getLargeIcon()',
        'createWithAdaptiveBitmap',
        'BubbleMetadata.Builder',
        'setLongLived(true)',
        'setPerson(person)',
        'PendingIntent.FLAG_MUTABLE',
      ]) {
        expect(k, contains(s), reason: s);
      }
      expect(k, isNot(contains('c3_bubble_chats"')),
          reason: 'old opt-in list must not gate bubbles any more');
    });
    test('bubble window runs the light entrypoint, never the full app', () {
      final a = _src('$_kt/BubbleActivity.kt');
      expect(a, contains('getDartEntrypointFunctionName(): String = "bubbleMain"'));
      expect(a, contains('inBubble = true'));
      expect(a, contains('onActivityResult'));
      final m = _src('lib/main.dart');
      expect(m, contains("@pragma('vm:entry-point')\nvoid bubbleMain()"));
      final c = _src('$_kt/C3MessagingChannel.kt');
      expect(c, contains('if (!inBubble) channel = ch'),
          reason: 'a bubble engine must not steal the main app channel');
      expect(c, contains('"attachBubble"'));
      expect(c, contains('"openInApp"'));
    });
    test('manifest: embeddable resizable document activity, no overlay perm', () {
      final y = _src('../.github/workflows/android.yml');
      final i = y.indexOf('messaging.BubbleActivity"');
      expect(i, greaterThan(0));
      final block = y.substring(i, y.indexOf('</activity>', i));
      expect(block, contains('android:allowEmbedded="true"'));
      expect(block, contains('android:resizeableActivity="true"'));
      expect(block, contains('android:documentLaunchMode="always"'));
      expect(block, contains('android:exported="false"'));
      expect(y, isNot(contains('android.permission.SYSTEM_ALERT_WINDOW"/>')));
    });
  });

  group('bubble window (light app)', () {
    setUp(() => _mockNative());

    testWidgets('opens exactly the asked chat', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(_bubbleApp(_state(),
          take: () async => 'group:3',
          build: (app, kind, id) async {
            asked.add('$kind:$id');
            return const Scaffold(body: Text('CHAT-SCREEN'));
          }));
      await tester.pumpAndSettle();
      expect(asked, ['group:3']);
      expect(find.text('CHAT-SCREEN'), findsOneWidget);
    });

    testWidgets('unknown chat → honest state + Open in Assisto (bn, 200%)',
        (tester) async {
      final log = <MethodCall>[];
      _mockNative(log: log);
      await tester.pumpWidget(_bubbleApp(_state(lang: 'bn'),
          take: () async => null));
      await tester.pumpAndSettle();
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.text(bn.bblCantOpen), findsOneWidget);
      expect(find.byKey(const Key('bbl-retry')), findsNothing,
          reason: 'nothing to retry without a chat');
      final open = find.byKey(const Key('bbl-open-app'));
      expect(tester.getSize(open).height, greaterThanOrEqualTo(48));
      await tester.tap(open);
      await tester.pump();
      expect(log.where((c) => c.method == 'openInApp'), hasLength(1));
    });

    testWidgets('load failure → Retry works', (tester) async {
      var n = 0;
      await tester.pumpWidget(_bubbleApp(_state(),
          take: () async => 'member:4',
          build: (app, kind, id) async {
            if (n++ == 0) throw StateError('offline');
            return const Scaffold(body: Text('CHAT-SCREEN'));
          }));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bbl-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('bbl-retry')));
      await tester.pumpAndSettle();
      expect(find.text('CHAT-SCREEN'), findsOneWidget);
    });

    testWidgets('signed out → sign-in line, no chat request', (tester) async {
      var built = 0;
      await tester.pumpWidget(_bubbleApp(_state(signedIn: false),
          take: () async => 'member:4',
          build: (a, k, i) async {
            built++;
            return const SizedBox();
          }));
      await tester.pumpAndSettle();
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(en.bblSignedOut), findsOneWidget);
      expect(built, 0);
    });

    for (final lang in ['en', 'bn']) {
      testWidgets('failed state fits at 200% font ($lang)', (tester) async {
        tester.view.physicalSize = const Size(720, 1100); // small bubble
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_wrap(
            BubbleChatHost(
                app: _state(lang: lang),
                takeChat: () async => 'member:1',
                buildChat: (a, k, i) async => throw StateError('x')),
            lang: lang,
            scale: 2));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('bbl-open-app')), findsOneWidget);
      });
    }
  });

  group('settings (My Circle → Settings → Notifications)', () {
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, null));

    testWidgets('global ON + "turn all back on" with Bangla digits', (tester) async {
      SharedPreferences.setMockInitialValues(
          {'c3_bubble_off_chats': 'group:2,member:5'});
      _mockNative();
      await tester.pumpWidget(_wrap(
          const Scaffold(body: SingleChildScrollView(child: MsgDeviceNotifSection())),
          lang: 'bn'));
      await tester.pumpAndSettle();
      final sw = tester.widget<SwitchListTile>(
          find.byKey(const Key('c3-bubbles-global')));
      expect(sw.value, isTrue);
      final all = find.byKey(const Key('bbl-all-on'));
      expect(all, findsOneWidget);
      expect(find.textContaining('২টি'), findsOneWidget);
      expect(tester.getSize(all).height, greaterThanOrEqualTo(48));
      await tester.tap(all);
      await tester.pumpAndSettle();
      expect(all, findsNothing);
      expect(await MsgPrefs.bubbleOffChats(), isEmpty);
    });

    testWidgets('Android 10 and below: honest line, no dead switch', (tester) async {
      SharedPreferences.setMockInitialValues({});
      _mockNative(supported: false);
      await tester.pumpWidget(_wrap(
          const Scaffold(body: SingleChildScrollView(child: MsgDeviceNotifSection()))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('c3-bubbles-global')), findsNothing);
      expect(find.byKey(const Key('bbl-unsupported')), findsOneWidget);
    });
  });

  group('group chat menu', () {
    for (final on in [true, false]) {
      testWidgets('per-chat bubble row (on=$on)', (tester) async {
        GroupMenuAction? got;
        await tester.pumpWidget(_wrap(Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async =>
                    got = await showGroupMenuSheet(c, isFavourite: false, bubbleOn: on),
                child: const Text('open'),
              ),
            ),
          ),
        )));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final en = await AppLocalizations.delegate.load(const Locale('en'));
        final label = on ? en.c3BubbleOff : en.c3BubbleOn;
        await tester.scrollUntilVisible(find.text(label), 100,
            scrollable: find.byType(Scrollable).last);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(got, GroupMenuAction.bubble);
      });
    }

    testWidgets('no row when the phone has no bubbles', (tester) async {
      await tester.pumpWidget(_wrap(Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () => showGroupMenuSheet(c, isFavourite: false),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(en.c3BubbleOn), findsNothing);
      expect(find.text(en.c3BubbleOff), findsNothing);
    });
  });
}
