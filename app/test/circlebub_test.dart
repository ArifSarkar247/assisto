// circlebub (owner My Circle order 3 Nov 16:30, parts A + B + C):
//  A) bubble position — save / restore / clamp (own in-call overlay) + the
//     system bubble's shortcut id + PendingIntent stay stable per chat;
//  B) bubble tap — the root cause (a bubbled chat's notification was
//     CANCELLED when its chat opened inside the bubble → Android removed the
//     bubble) + PendingIntent flags + manifest attributes + back collapses;
//  C) Assisto's own message pop: new channel, migration keeping mute /
//     vibrate, old channel deleted, soft in-app tick, sounds < 1 s.
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/audio/msg_open_tick.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/bubble_open_mark.dart';
import 'package:assisto/messaging/bubble_position.dart';
import 'package:assisto/messaging/in_call_bubbles.dart';
import 'package:assisto/messaging/msg_channel.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/messaging/msg_prefs.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _src(String p) => File(p).readAsStringSync();
const _kt = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/messaging';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

class _FakeAndroid extends Fake implements AndroidFlutterLocalNotificationsPlugin {
  _FakeAndroid(this.channels);
  final List<AndroidNotificationChannel> channels;
  final log = <String>[];

  @override
  Future<List<AndroidNotificationChannel>?> getNotificationChannels() async =>
      List.of(channels);

  @override
  Future<void> createNotificationChannel(AndroidNotificationChannel c) async {
    log.add('create:${c.id}');
    if (!channels.any((x) => x.id == c.id)) channels.add(c);
  }

  @override
  Future<void> deleteNotificationChannel(String id) async {
    log.add('delete:$id');
    channels.removeWhere((x) => x.id == id);
  }
}

class _NoPullBackend implements MsgBackend {
  int pulls = 0;
  @override
  Future<Map<String, dynamic>> pull(String kind, int id, {int limit = kMsgWindow}) async {
    pulls++;
    throw StateError('must not redraw');
  }

  @override
  Future<void> seen(String kind, int id) async {}
  @override
  Future<Map<String, dynamic>> send(String kind, int id, Map<String, dynamic> env) async => {};
  @override
  Future<List<Map<String, dynamic>>> groupRoster(int id) async => const [];
}

class _Sink implements MsgNotifSink {
  final shown = <MsgNotifModel>[];
  final cancelled = <String>[];
  @override
  Future<void> show(MsgNotifModel m, AppLocalizations t, {bool silent = false}) async =>
      shown.add(m);
  @override
  Future<void> cancel(String kind, int id) async => cancelled.add('$kind:$id');
}

/// Minimal RIFF/WAVE header reader (mono / bits / rate / seconds).
({int channels, int bits, int rate, double seconds}) _wav(String path) {
  final b = ByteData.sublistView(File(path).readAsBytesSync());
  expect(String.fromCharCodes(b.buffer.asUint8List(0, 4)), 'RIFF');
  expect(String.fromCharCodes(b.buffer.asUint8List(8, 4)), 'WAVE');
  var i = 12;
  int ch = 0, bits = 0, rate = 0, data = 0;
  while (i + 8 <= b.lengthInBytes) {
    final id = String.fromCharCodes(b.buffer.asUint8List(i, 4));
    final len = b.getUint32(i + 4, Endian.little);
    if (id == 'fmt ') {
      ch = b.getUint16(i + 10, Endian.little);
      rate = b.getUint32(i + 12, Endian.little);
      bits = b.getUint16(i + 22, Endian.little);
    } else if (id == 'data') {
      data = len;
    }
    i += 8 + len + (len.isOdd ? 1 : 0);
  }
  return (channels: ch, bits: bits, rate: rate, seconds: data / (rate * ch * bits / 8));
}

void main() {
  // ------------------------------------------------------------- part A
  group('A: bubble position — save / restore / clamp', () {
    const bubble = Size(70, 78);
    const pad = EdgeInsets.only(top: 24, bottom: 48);

    test('drop snaps to the nearer edge and keeps the height', () {
      const phone = Size(360, 780);
      final l = BubbleGeometry.fromDrop(const Offset(40, 300), phone, bubble, pad);
      expect(l.edge, BubbleEdge.left);
      final r = BubbleGeometry.fromDrop(const Offset(250, 300), phone, bubble, pad);
      expect(r.edge, BubbleEdge.right);
      // restore lands exactly where it was let go (y) on the snapped edge
      final at = BubbleGeometry.resolve(l, phone, bubble, pad);
      expect(at.dx, pad.left + BubbleGeometry.margin);
      expect(at.dy, closeTo(300, 0.01));
      final atR = BubbleGeometry.resolve(r, phone, bubble, pad);
      expect(atR.dx, phone.width - BubbleGeometry.margin - bubble.width);
    });

    test('always fully on screen: any size, rotation, notch, nav bar', () {
      for (final pos in const [
        BubblePos(edge: BubbleEdge.left, yFrac: 0),
        BubblePos(edge: BubbleEdge.right, yFrac: 1),
        BubblePos(edge: BubbleEdge.left, yFrac: 0.5),
      ]) {
        for (final screen in const [
          Size(320, 480), // small phone
          Size(360, 780),
          Size(780, 360), // landscape (rotation)
          Size(1280, 800), // tablet
          Size(80, 90), // absurdly small: still clamped, never negative
        ]) {
          final at = BubbleGeometry.resolve(pos, screen, bubble, pad);
          expect(at.dx, greaterThanOrEqualTo(0), reason: '$pos $screen');
          expect(at.dy, greaterThanOrEqualTo(pad.top), reason: '$pos $screen');
          if (screen.width >= bubble.width + 16 && screen.height >= 200) {
            expect(at.dx + bubble.width, lessThanOrEqualTo(screen.width));
            expect(at.dy + bubble.height,
                lessThanOrEqualTo(screen.height - pad.bottom));
          }
        }
      }
      // a drop far off screen is clamped back in
      final off = BubbleGeometry.fromDrop(const Offset(-500, 5000),
          const Size(360, 780), bubble, pad);
      expect(off.yFrac, 1.0);
      expect(off.edge, BubbleEdge.left);
    });

    test('rotation keeps the same relative height + edge', () {
      const portrait = Size(360, 780);
      const landscape = Size(780, 360);
      final p = BubbleGeometry.fromDrop(const Offset(300, 400), portrait, bubble, pad);
      final a = BubbleGeometry.resolve(p, landscape, bubble, pad);
      expect(a.dx, landscape.width - BubbleGeometry.margin - bubble.width);
      final usable = landscape.height - pad.top - pad.bottom - 2 * 8 - bubble.height;
      expect(a.dy, closeTo(pad.top + 8 + p.yFrac * usable, 0.01));
    });

    test('store: per chat, last-used fallback, default, cap, corrupt data',
        () async {
      SharedPreferences.setMockInitialValues({});
      expect(await BubblePositionStore.load('member:1'), BubblePos.fallback);
      const a = BubblePos(edge: BubbleEdge.left, yFrac: 0.7);
      const b = BubblePos(edge: BubbleEdge.right, yFrac: 0.3);
      await BubblePositionStore.save('member:1', a);
      await BubblePositionStore.save('group:2', b);
      expect(await BubblePositionStore.load('member:1'), a);
      expect(await BubblePositionStore.load('group:2'), b);
      // a chat never dragged starts where the user last put any bubble
      expect(await BubblePositionStore.load('member:99'), b);
      for (var i = 0; i < BubblePositionStore.maxChats + 10; i++) {
        await BubblePositionStore.save('member:${100 + i}', a);
      }
      final p = await SharedPreferences.getInstance();
      expect(p.getString(BubblePositionStore.kKey)!.length, lessThan(6000));
      expect(await BubblePositionStore.load('member:${100 + BubblePositionStore.maxChats + 9}'), a);
      await p.setString(BubblePositionStore.kKey, '{not json');
      expect(await BubblePositionStore.load('member:1'), BubblePos.fallback);
      expect(BubblePos.fromJson({'e': 'l', 'y': double.nan}), isNull);
      expect(BubblePos.fromJson({'e': 'l', 'y': 7})!.yFrac, 1.0);
    });

    testWidgets('overlay: drag → saved; restart / new message → same spot',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      Widget host(InCallBubbles bus) => _wrap(InCallBubbleHost(
            enabled: true,
            bus: bus,
            resolve: (k) async => (name: 'Rina', photo: '', photoV: ''),
            onOpen: (_) {},
            child: const Scaffold(body: ColoredBox(color: Colors.black)),
          ));
      final bus = InCallBubbles();
      await tester.pumpWidget(host(bus));
      bus.onMessage('member:1', msgId: '1');
      await tester.pumpAndSettle();
      final stack = find.byKey(const Key('bbl2-call-stack'));
      expect(tester.getCenter(stack).dx, greaterThan(180)); // default: right
      // drag to the left side, lower down
      final g = await tester.startGesture(tester.getCenter(stack));
      await g.moveBy(const Offset(-10, 0));
      await tester.pump();
      await g.moveTo(const Offset(60, 520));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(tester.getCenter(stack).dx, lessThan(100)); // snapped left
      final y = tester.getTopLeft(stack).dy;
      expect(y, greaterThan(400));
      final saved = await BubblePositionStore.load('member:1');
      expect(saved.edge, BubbleEdge.left);
      // "app restart": a brand-new host + bus, the same chat's message
      await tester.pumpWidget(const SizedBox());
      final bus2 = InCallBubbles();
      await tester.pumpWidget(host(bus2));
      bus2.onMessage('member:1', msgId: '2');
      await tester.pumpAndSettle();
      expect(tester.getCenter(stack).dx, lessThan(100));
      expect(tester.getTopLeft(stack).dy, closeTo(y, 1));
      // rotation: landscape → still inside the screen, still on the left
      tester.view.physicalSize = const Size(2340, 1080);
      await tester.pumpAndSettle();
      final r = tester.getRect(stack);
      expect(r.left, lessThan(100));
      expect(r.bottom, lessThanOrEqualTo(360));
      await tester.pumpWidget(const SizedBox());
    });

    test('system bubbles: shortcut id, LocusId, request code stable per chat', () {
      final h = _src('$_kt/BubbleHelper.kt');
      expect(h, contains('fun shortcutIdFor(kind: String, id: String) = "c3chat_'));
      expect(h, contains('fun requestCodeFor(kind: String, id: String): Int = shortcutIdFor(kind, id).hashCode()'));
      expect(h, contains('context, requestCodeFor(kind, id), bubbleIntent(context, kind, id), bubblePiFlags()'));
      expect(h, contains('.setShortcutId(scId)'));
      expect(h, contains('.setLocusId(LocusId(scId))'));
      // long-lived dynamic shortcut with a Person + LocusId
      expect(h, contains('.setLongLived(true)'));
      expect(h, contains('.setPerson(person)'));
      expect(h, contains('sm.pushDynamicShortcut(sc)'));
    });
  });

  // ------------------------------------------------------------- part B
  group('B: bubble tap opens the chat', () {
    test('root cause: a bubbled chat is never cancelled (Android removes the bubble)', () {
      final n = _src('lib/messaging/msg_notify.dart');
      final cancel = n.substring(n.indexOf('Future<void> cancel(String kind, int id) async {\n    try {'));
      final keep = cancel.indexOf('if (await MsgNative.clearChat(kind, id)) return;');
      final plug = cancel.indexOf('await _plugin.cancel(');
      expect(keep, greaterThan(0));
      expect(keep, lessThan(plug), reason: 'the bubble check must run BEFORE any cancel');
      final h = _src('$_kt/BubbleHelper.kt');
      final clear = h.substring(h.indexOf('fun clearChat('));
      expect(clear, contains('isShownAsBubble(n.flags)'));
      expect(clear, contains('.setSuppressNotification(true)'));
      expect(clear.substring(0, clear.indexOf('fun isShownAsBubble')),
          isNot(contains('nm.cancel(')));
      expect(h, contains('(flags and Notification.FLAG_BUBBLE) != 0'));
      final c = _src('$_kt/C3MessagingChannel.kt');
      expect(c, contains('"clearChat" -> result.success(BubbleHelper.clearChat('));
      // both chat screens clear through the bubble-aware sink
      expect(_src('lib/screens/circle_chat_screen.dart'),
          contains("FlnMsgSink().cancel('member', _memberId!)"));
      expect(_src('lib/screens/circle_group_chat_screen.dart'),
          contains("FlnMsgSink().cancel('group', _gid)"));
    });

    test('PendingIntent: MUTABLE on Android 12+, explicit, per-chat extra', () {
      final h = _src('$_kt/BubbleHelper.kt');
      final f = h.substring(h.indexOf('fun bubblePiFlags(): Int ='));
      expect(f, contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.S'));
      expect(f, contains('PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE'));
      expect(h, contains('Intent(context, BubbleActivity::class.java)'),
          reason: 'explicit: Android 14 forbids a mutable IMPLICIT intent');
      expect(h, contains('.putExtra(EXTRA_CHAT, chatKey(kind, id))'));
      expect(h, contains('PendingIntent.getActivity('));
      expect(h, isNot(contains('FLAG_IMMUTABLE')));
      // the bubble engine reads exactly that extra
      final c = _src('$_kt/C3MessagingChannel.kt');
      expect(c, contains('activity.intent?.getStringExtra(BubbleHelper.EXTRA_CHAT)'));
    });

    test('manifest: embeddable, resizeable, own document per chat, not exported', () {
      final y = _src('../.github/workflows/android.yml');
      final i = y.indexOf('messaging.BubbleActivity"');
      final block = y.substring(i, y.indexOf('</activity>', i));
      expect(block, contains('android:allowEmbedded="true"'));
      expect(block, contains('android:resizeableActivity="true"'));
      expect(block, contains('android:documentLaunchMode="always"'));
      expect(block, contains('android:exported="false"'));
      expect(block, contains('android:windowSoftInputMode="adjustResize"'));
    });

    test('engine: light Dart entry + back collapses instead of finishing', () {
      final a = _src('$_kt/BubbleActivity.kt');
      expect(a, contains('getDartEntrypointFunctionName(): String = "bubbleMain"'));
      final pop = a.substring(a.indexOf('override fun popSystemNavigator(): Boolean'));
      expect(pop, contains('findSpecial('));
      expect(pop, contains('"onBackPressed"'));
      expect(pop, contains('moveTaskToBack(true)'));
      expect(pop, contains('catch (t: Throwable)'));
      expect(_src('lib/main.dart'), contains("@pragma('vm:entry-point')\nvoid bubbleMain()"));
    });

    test('open-in-bubble mark: fresh, per chat, TTL-bounded', () {
      final now = DateTime(2026, 11, 3, 17);
      final raw = BubbleOpenMark.encode('member:12', now.add(BubbleOpenMark.ttl));
      expect(BubbleOpenMark.isOpenIn(raw, 'member:12', now), isTrue);
      expect(BubbleOpenMark.isOpenIn(raw, 'member:1', now), isFalse);
      expect(BubbleOpenMark.isOpenIn(raw, 'group:12', now), isFalse);
      expect(BubbleOpenMark.isOpenIn(raw, 'member:12', now.add(const Duration(minutes: 1))), isFalse);
      // a stuck far-future value never hides notifications
      final far = BubbleOpenMark.encode('member:12', now.add(const Duration(days: 2)));
      expect(BubbleOpenMark.isOpenIn(far, 'member:12', now), isFalse);
      expect(BubbleOpenMark.isOpenIn(null, 'member:12', now), isFalse);
      expect(BubbleOpenMark.isOpenIn('garbage', 'member:12', now), isFalse);
      // the native safety net mirrors it
      final n = _src('$_kt/MessageNotifier.kt');
      expect(n, contains('"flutter.c3_bubble_open_chat"'));
      expect(n, contains('left > 0L && left <= 45_000L'));
    });

    test('mark / clear round trip (SharedPreferences)', () async {
      SharedPreferences.setMockInitialValues({});
      await BubbleOpenMark.mark('member:12');
      expect(await BubbleOpenMark.isOpen('member:12'), isTrue);
      await BubbleOpenMark.clear('member:3'); // another chat: untouched
      expect(await BubbleOpenMark.isOpen('member:12'), isTrue);
      await BubbleOpenMark.clear('member:12');
      expect(await BubbleOpenMark.isOpen('member:12'), isFalse);
    });

    test('a new message for the chat open in its bubble is NOT redrawn', () async {
      SharedPreferences.setMockInitialValues({});
      final backend = _NoPullBackend();
      final sink = _Sink();
      final h = MsgPushHandler(
          backend: backend,
          identity: () async => null,
          sink: sink,
          bubbleOpen: (k) async => k == 'member:12');
      final p = PushPayload(const {'kind': 'message', 'chat_kind': 'member', 'chat_id': '12', 'lang': 'en'});
      expect(await h.onPush(p), isTrue); // handled: no native fallback
      expect(backend.pulls, 0);
      expect(sink.shown, isEmpty);
      expect(sink.cancelled, isEmpty);
      // another chat still draws (here: the fake backend throws → false)
      final other = PushPayload(const {'kind': 'message', 'chat_kind': 'member', 'chat_id': '13', 'lang': 'en'});
      expect(await h.onPush(other), isFalse);
      expect(backend.pulls, 1);
    });
  });

  // ------------------------------------------------------------- part C
  group('C: Assisto pop + channel migration', () {
    test('default message channel is the new one; picked sounds unchanged', () {
      expect(MsgChannel.id, isNot(MsgChannel.legacyId));
      expect(MsgPrefs.channelIdFor(null), MsgChannel.id);
      expect(MsgPrefs.channelIdFor(''), 'messages_silent');
      expect(MsgPrefs.channelIdFor('content://x'), startsWith('messages_'));
      final n = _src('$_kt/MessageNotifier.kt');
      expect(n, contains('const val CHANNEL_ID = "${MsgChannel.id}"'));
      expect(n, contains('const val LEGACY_CHANNEL_ID = "${MsgChannel.legacyId}"'));
      expect(n, contains('/raw/${MsgChannel.sound}'));
      expect(_src('$_kt/MsgTick.kt'), contains('/raw/${MsgChannel.tick}'));
    });

    test('plan: fresh install / migrate / already migrated', () {
      final fresh = MsgChannel.plan(const []);
      expect(fresh.create, isTrue);
      expect(fresh.carryFrom, isNull);
      expect(fresh.deleteLegacy, isFalse);
      const old = AndroidNotificationChannel('messages', 'Messages',
          importance: Importance.low, enableVibration: false);
      final mig = MsgChannel.plan(const [old]);
      expect(mig.create, isTrue);
      expect(mig.carryFrom, same(old));
      expect(mig.deleteLegacy, isTrue);
      final done = MsgChannel.plan([MsgChannel.channelFor(name: 'M', description: '')]);
      expect(done.create, isFalse);
      expect(done.deleteLegacy, isFalse);
    });

    test('carries mute / vibrate / sound-off; default = Assisto pop', () {
      final d = MsgChannel.channelFor(name: 'M', description: 'd');
      expect(d.importance, Importance.high);
      expect(d.enableVibration, isTrue);
      expect((d.sound as RawResourceAndroidNotificationSound).sound, 'assisto_pop');
      for (final imp in [Importance.none, Importance.min, Importance.low, Importance.defaultImportance]) {
        final c = MsgChannel.channelFor(
            name: 'M',
            description: 'd',
            old: AndroidNotificationChannel('messages', 'M', importance: imp, enableVibration: false));
        expect(c.importance, imp, reason: 'a muted channel stays muted');
        expect(c.enableVibration, isFalse);
      }
      final noSound = MsgChannel.channelFor(
          name: 'M', description: 'd',
          old: const AndroidNotificationChannel('messages', 'M', playSound: false));
      expect(noSound.playSound, isFalse);
      expect(noSound.sound, isNull);
    });

    test('ensure: create new FIRST with old choices, THEN delete old; once', () async {
      MsgChannel.resetForTest();
      final a = _FakeAndroid([
        const AndroidNotificationChannel('messages', 'Messages',
            importance: Importance.none, enableVibration: false),
        const AndroidNotificationChannel('calls', 'Calls'),
      ]);
      expect(await MsgChannel.ensure(a, name: 'Messages', description: 'd'), MsgChannel.id);
      expect(a.log, ['create:${MsgChannel.id}', 'delete:messages']);
      final made = a.channels.firstWhere((c) => c.id == MsgChannel.id);
      expect(made.importance, Importance.none);
      expect(made.enableVibration, isFalse);
      expect(a.channels.any((c) => c.id == 'messages'), isFalse);
      expect(a.channels.any((c) => c.id == 'calls'), isTrue, reason: 'calls untouched');
      a.log.clear();
      await MsgChannel.ensure(a, name: 'Messages', description: 'd');
      expect(a.log, isEmpty, reason: 'once per isolate');
      MsgChannel.resetForTest();
      await MsgChannel.ensure(a, name: 'Messages', description: 'd');
      expect(a.log, ['create:${MsgChannel.id}'], reason: 'never recreates the old id');
      MsgChannel.resetForTest();
    });

    test('native mirror: create before delete; reads importance + vibration', () {
      final n = _src('$_kt/MessageNotifier.kt');
      final m = n.substring(n.indexOf('fun migrateChannel('));
      expect(m.indexOf('nm.createNotificationChannel(ch)'),
          lessThan(m.indexOf('nm.deleteNotificationChannel(LEGACY_CHANNEL_ID)')));
      expect(n, contains('ChannelCarry(old.importance, old.shouldVibrate(), old.sound != null)'));
      expect(n, isNot(contains('NotificationChannel("messages"')),
          reason: 'the old id must never be recreated');
      // Dart never recreates it either
      final pn = _src('lib/push/push_notifier.dart');
      expect(pn, isNot(contains('AndroidNotificationChannel(PushChannels.messages')));
      expect(pn, contains('await MsgChannel.ensure(a,'));
    });

    test('our own sounds: mono 16-bit wav, pop < 1 s, tick shorter; kept', () {
      const raw = 'android_overlay/app/src/main/res/raw';
      final pop = _wav('$raw/assisto_pop.wav');
      final tick = _wav('$raw/assisto_tick.wav');
      for (final w in [pop, tick]) {
        expect(w.channels, 1);
        expect(w.bits, 16);
        expect(w.rate, 44100);
      }
      expect(pop.seconds, inExclusiveRange(0.1, 1.0));
      expect(tick.seconds, lessThan(pop.seconds));
      expect(File('tool/sounds/make_msg_sounds.py').existsSync(), isTrue);
      final keep = _src('$raw/assisto_keep.xml');
      expect(keep, contains('@raw/assisto_pop'));
      expect(keep, contains('@raw/assisto_tick'));
      // call ringtone + SOS sounds unchanged
      final pn = _src('lib/push/push_notifier.dart');
      expect(pn, contains("'content://settings/system/ringtone'"));
      expect(pn, contains('audioAttributesUsage: AudioAttributesUsage.alarm'));
    });

    test('soft tick: only for the open chat, never in a call or on Silent', () {
      expect(MsgOpenTick.shouldPlay(inCall: false, soundUri: null), isTrue);
      expect(MsgOpenTick.shouldPlay(inCall: false, soundUri: 'content://x'), isTrue);
      expect(MsgOpenTick.shouldPlay(inCall: true, soundUri: null), isFalse);
      expect(MsgOpenTick.shouldPlay(inCall: false, soundUri: ''), isFalse);
      final ps = _src('lib/push/push_service.dart');
      final i = ps.indexOf('if (MsgActiveChat.isOpen(chat.kind, chat.id)) {');
      expect(ps.substring(i, i + 300), contains('MsgOpenTick.play()'));
      final k = _src('$_kt/MsgTick.kt');
      expect(k, contains('USAGE_NOTIFICATION_COMMUNICATION_INSTANT'));
      expect(k, contains('RINGER_MODE_NORMAL'));
      expect(k, isNot(contains('setStreamVolume')));
    });
  });
}
