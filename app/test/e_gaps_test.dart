// e-gaps (owner order E) — My Circle gaps vs WhatsApp / Messenger /
// Telegram, PROVEN: voice-note speed, disappearing timer lines + this
// phone's copies wiped on expiry, view-once photos (opened once, file wiped,
// FLAG_SECURE only while viewing, no forward), chat lock (code + biometric
// seam, locked folder, notifications without name/text), group pin/archive
// and message search from the chat list.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_decor/chat_control.dart';
import 'package:assisto/messaging/chat_decor/system_line.dart';
import 'package:assisto/messaging/chat_lock.dart';
import 'package:assisto/messaging/disappear_sweep.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_outbox.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/media/voice_bubble.dart';
import 'package:assisto/messaging/media/voice_player.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/messaging/preview_cache.dart';
import 'package:assisto/messaging/unread_store.dart';
import 'package:assisto/messaging/view_once.dart';
import 'package:assisto/models.dart';
import 'package:assisto/photo_studio/ps_engines.dart' show SecureScreen;
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:assisto/widgets/circle_message_actions.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _en = lookupAppLocalizations(const Locale('en'));
final _bn = lookupAppLocalizations(const Locale('bn'));

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: Scaffold(body: child),
    );

class _RateVoice implements VoiceBackend, VoiceRateBackend {
  final calls = <String>[];
  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _done = StreamController<void>.broadcast();
  @override
  Future<void> play(String path) async => calls.add('play $path');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> seek(Duration d) async => calls.add('seek');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> setRate(double r) async => calls.add('rate $r');
  @override
  Stream<Duration> get position => _pos.stream;
  @override
  Stream<Duration> get duration => _dur.stream;
  @override
  Stream<void> get completed => _done.stream;
}

class _Secure implements SecureScreen {
  final calls = <String>[];
  @override
  Future<bool> enable() async {
    calls.add('on');
    return true;
  }

  @override
  Future<void> disable() async => calls.add('off');
}

// a real 1x1 PNG
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

MediaDescriptor _desc(String ref, {String kind = 'photo'}) => MediaDescriptor(
      kind: kind,
      ref: ref,
      key: Uint8List(32),
      nonce: Uint8List(12),
      sha256: 'a' * 64,
      size: 10,
      plainSize: _png.length,
      mime: 'image/png',
    );

void main() {
  late Directory tmp;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('egaps');
    MediaDirs.override = tmp.path;
    ViewOnceStore.instance.resetForTest();
    ChatLockStore.instance.resetForTest();
    DisappearSweep.instance.resetForTest();
    PreviewCache.instance.resetForTest();
    ChatLockSession.end();
  });
  tearDown(() {
    MediaDirs.override = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ------------------------------------------------------------ voice speed
  group('voice-note speed', () {
    test('1x -> 1.5x -> 2x -> 1x, labels', () {
      expect(nextVoiceRate(1.0), 1.5);
      expect(nextVoiceRate(1.5), 2.0);
      expect(nextVoiceRate(2.0), 1.0);
      expect(nextVoiceRate(3.3), 1.0);
      expect(voiceRateLabel(1.0), '1×');
      expect(voiceRateLabel(1.5), '1.5×');
      expect(voiceRateLabel(2.0), '2×');
    });

    testWidgets('pill appears while playing, tap really changes the speed (bn digits)',
        (tester) async {
      final fake = _RateVoice();
      VoicePlayer.backendFactory = () => fake;
      VoicePlayer.instance.rate.value = 1.0;
      await tester.pumpWidget(_app(
          const VoiceNoteBody(path: '/x/a.m4a', durationMs: 8000, wave: [3, 9], fg: Colors.black),
          locale: const Locale('bn')));
      expect(find.byKey(const Key('e-voice-rate')), findsNothing); // not before play
      await tester.tap(find.byKey(const Key('md1-voice-play')));
      await tester.pump();
      expect(fake.calls, ['play /x/a.m4a']); // 1x: no rate call
      expect(find.text('১×'), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-voice-rate')));
      await tester.pump();
      expect(fake.calls.last, 'rate 1.5');
      expect(find.text('১.৫×'), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-voice-rate')));
      await tester.pump();
      expect(fake.calls.last, 'rate 2.0');
      // pause -> resume keeps the chosen speed
      fake._pos.add(const Duration(seconds: 2));
      await tester.pump();
      await tester.tap(find.byKey(const Key('md1-voice-play')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('md1-voice-play')));
      await tester.pump();
      expect(fake.calls.sublist(fake.calls.length - 2), ['resume', 'rate 2.0']);
      await VoicePlayer.instance.stop();
      VoicePlayer.instance.rate.value = 1.0;
    });
  });

  // ------------------------------------------------------ disappearing
  group('disappearing messages', () {
    test('timer control round-trips and old versions get a readable line', () {
      final plain = encodeControl(
          const ChatControl.timer(86400, at: 5), describeTimer(_en, 86400, mine: false, actor: 'Rahim'));
      expect(plain.split('\n').first,
          'Rahim turned on disappearing messages. New messages will disappear after 24 hours.');
      final c = decodeControl(plain)!;
      expect(c.isTimer, isTrue);
      expect(c.sec, 86400);
      expect(c.at, 5);
      expect(ChatControl.fromJson({'t': 'timer', 'sec': -1}), isNull);
      expect(ChatControl.fromJson({'t': 'timer', 'sec': 99999999}), isNull);
    });

    test('system lines en/bn, mine/theirs, on/off', () {
      expect(describeControl(_en, const ChatControl.timer(604800), mine: true, actor: 'X'),
          'You turned on disappearing messages. New messages will disappear after 7 days.');
      expect(describeControl(_en, const ChatControl.timer(0), mine: false, actor: 'Rahim'),
          'Rahim turned off disappearing messages.');
      final bn = describeControl(_bn, const ChatControl.timer(86400), mine: false, actor: 'রহিম');
      expect(bn, contains('২৪ ঘণ্টা'));
      expect(bn, contains('রহিম'));
      expect(RegExp(r'[0-9]').hasMatch(bn), isFalse); // Bangla digits only
    });

    test('expiry rule: only messages sent after the timer started', () {
      final since = DateTime(2026, 10, 1, 10);
      final now = DateTime(2026, 10, 3, 10);
      expect(isExpired(DateTime(2026, 10, 1, 11), 86400, since, now: now), isTrue);
      expect(isExpired(DateTime(2026, 10, 2, 11), 86400, since, now: now), isFalse);
      expect(isExpired(DateTime(2026, 9, 30), 86400, since, now: now), isFalse); // older
      expect(isExpired(DateTime(2026, 10, 1, 11), 0, since, now: now), isFalse); // off
      expect(isExpired(DateTime(2026, 10, 1, 11), 86400, null, now: now), isFalse);
    });

    test("sweep wipes this phone's decrypted file + preview at expiry", () async {
      final d = _desc('ref1');
      final f = File('${tmp.path}/files/${MediaCache.fileName('ref1', d.ext)}')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png);
      await PreviewCache.instance.put('member:4', '77', 'secret plan');
      var now = DateTime(2026, 10, 1, 12);
      DisappearSweep.instance.clock = () => now;
      await DisappearSweep.instance
          .track('member:4', '77', DateTime(2026, 10, 2, 12), media: d);
      await DisappearSweep.instance.track('member:4', '77', DateTime(2026, 10, 2, 12)); // dedupe
      expect(await DisappearSweep.instance.pending(), 1);
      expect(await DisappearSweep.instance.sweep(), 0); // not yet
      expect(f.existsSync(), isTrue);
      now = DateTime(2026, 10, 2, 12, 1);
      expect(await DisappearSweep.instance.sweep(), 1);
      expect(f.existsSync(), isFalse);
      expect(await PreviewCache.instance.textFor('member:4', '77'), isNull);
      expect(await DisappearSweep.instance.pending(), 0);
      DisappearSweep.instance.clock = DateTime.now;
    });
  });

  // ------------------------------------------------------------ view once
  group('view-once photos', () {
    test('descriptor mark drops the thumbnail; job keeps the flag', () {
      final d = MediaDescriptor(
          kind: 'photo',
          ref: 'r',
          key: Uint8List(32),
          nonce: Uint8List(12),
          sha256: 'b' * 64,
          size: 1,
          plainSize: 1,
          thumb: Uint8List.fromList([1, 2, 3]));
      final vo = markViewOnce(d.encode());
      expect(descriptorIsViewOnce(vo), isTrue);
      expect(descriptorIsViewOnce(d.encode()), isFalse);
      expect(jsonDecode(vo)['thumb'], isNull);
      expect(MediaDescriptor.tryParse(vo), isNotNull); // still a valid photo
      final job = MediaJob(
          id: 'j1',
          chatKind: 'member',
          chatId: 3,
          kind: 'photo',
          srcPath: '/x',
          name: '',
          mime: 'image/jpeg',
          plainSize: 1,
          at: DateTime(2026),
          viewOnce: true);
      expect(MediaJob.fromJson(job.toJson())!.viewOnce, isTrue);
    });

    testWidgets('opens ONCE: file wiped, FLAG_SECURE on only while viewing, ack sent',
        (tester) async {
      final secure = _Secure();
      final acks = <String>[];
      final file = File('${tmp.path}/files/v1.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png);
      final deps = ViewOnceDeps(
          fetch: (_) async => file, ack: (id) async => acks.add(id), secure: secure);
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      late Future<bool> done;
      // real file I/O + storage run outside the fake clock
      await tester.runAsync(() async {
        done = openViewOnce(ctx, msgId: '501', desc: _desc('v1'), deps: deps);
        for (var i = 0; i < 40 && secure.calls.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('e-vo-image')), findsOneWidget);
      expect(file.existsSync(), isFalse); // plaintext only in memory
      expect(secure.calls, ['on']);
      expect(acks, ['501']);
      expect(await ViewOnceStore.instance.isOpened('501'), isTrue);
      expect(await ViewOnceStore.instance.owed(), 0);
      // no save / share / forward in the viewer
      expect(find.byIcon(Icons.share_outlined), findsNothing);
      expect(find.byIcon(Icons.save_alt_outlined), findsNothing);
      await tester.tap(find.byKey(const Key('e-vo-close')));
      await tester.pumpAndSettle();
      late bool doneOk;
      await tester.runAsync(() async => doneOk = await done);
      expect(doneOk, isTrue);
      expect(secure.calls, ['on', 'off']);
      // a second tap is refused, nothing fetched
      var fetched = false;
      final again = openViewOnce(ctx,
          msgId: '501',
          desc: _desc('v1'),
          deps: ViewOnceDeps(
              fetch: (_) async {
                fetched = true;
                return null;
              },
              ack: (_) async {},
              secure: secure));
      late bool againOk;
      await tester.runAsync(() async => againOk = await again);
      expect(againOk, isFalse);
      expect(fetched, isFalse);
      await tester.pump();
      expect(find.text('This view-once photo was already opened'), findsOneWidget);
    });

    test('an ack that fails offline is retried later', () async {
      await ViewOnceStore.instance.markOpened('9');
      expect(await ViewOnceStore.instance.flush((_) async => throw StateError('offline')), 0);
      expect(await ViewOnceStore.instance.owed(), 1);
      final sent = <String>[];
      expect(await ViewOnceStore.instance.flush((id) async => sent.add(id)), 1);
      expect(sent, ['9']);
      expect(await ViewOnceStore.instance.owed(), 0);
    });

    testWidgets('bubble: receiver tile opens; sender + opened tiles do not', (tester) async {
      var opened = 0;
      Widget bubble(CircleMessage m) => CircleBubble(msg: m, onOpenViewOnce: () => opened++);
      final at = DateTime(2026, 10, 24, 10);
      await tester.pumpWidget(_app(Column(children: [
        bubble(CircleMessage(
            id: '1', text: '', mine: false, at: at, contentType: 'photo',
            media: _desc('a'), viewOnce: true)),
        bubble(CircleMessage(
            id: '2', text: '', mine: true, at: at, contentType: 'photo', viewOnce: true)),
        bubble(CircleMessage(
            id: '3', text: '', mine: false, at: at, contentType: 'photo',
            viewOnce: true, viewOnceOpened: true)),
      ])));
      expect(find.text('View once · tap to open'), findsOneWidget);
      expect(find.text('View once · not opened yet'), findsOneWidget);
      expect(find.text('You opened this view-once photo'), findsOneWidget);
      expect(find.byKey(const Key('md1-photo-a')), findsNothing); // no image in chat
      await tester.tap(find.byKey(const ValueKey('e-vo-1')));
      await tester.tap(find.byKey(const ValueKey('e-vo-2')));
      await tester.tap(find.byKey(const ValueKey('e-vo-3')));
      expect(opened, 1);
    });

    testWidgets('long-press menu has no copy / forward / star / pin for view-once',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      unawaited(showCircleMessageActions(ctx,
          mine: false,
          canEdit: false,
          isStarred: false,
          isPinned: false,
          canDeleteEveryone: false,
          onReact: (_) {},
          protectedContent: true));
      await tester.pumpAndSettle();
      expect(find.text(_en.circleActionForward), findsNothing);
      expect(find.text(_en.copy), findsNothing);
      expect(find.text(_en.circleActionStar), findsNothing);
      expect(find.text(_en.circleActionReply), findsOneWidget);
      expect(find.text(_en.circleActionDeleteMe), findsOneWidget);
    });
  });

  // ------------------------------------------------------------ chat lock
  group('chat lock', () {
    test('code is stored hashed, verified, reset; fresh read for background', () async {
      final s = ChatLockStore.instance;
      expect(ChatLockStore.validCode('12'), isFalse);
      expect(ChatLockStore.validCode('1234'), isTrue);
      expect(ChatLockStore.validCode('12a4'), isFalse);
      await s.setCode('4321');
      expect(await s.verify('4321'), isTrue);
      expect(await s.verify('1111'), isFalse);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('e_chat_lock_v1')!.contains('4321'), isFalse); // never plain
      await s.lock('member:5');
      expect(s.isLockedSync('member:5'), isTrue);
      expect(await ChatLockStore.isLockedFresh('member:5'), isTrue);
      expect(await ChatLockStore.isLockedFresh('member:6'), isFalse);
      expect(await s.resetAll(), {'member:5'});
      expect(await s.hasCode(), isFalse);
      expect(s.isLockedSync('member:5'), isFalse);
    });

    testWidgets('first lock asks for a code; unlock needs it (wrong code refused)',
        (tester) async {
      ChatLockAuth.biometric = (_) async => null; // no fingerprint on this phone
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      var r = toggleChatLock(ctx, 'member:8');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('e-lock-new')), '2468');
      await tester.enterText(find.byKey(const Key('e-lock-confirm')), '2468');
      await tester.tap(find.byKey(const Key('e-lock-new-ok')));
      await tester.pumpAndSettle();
      expect(await r, isTrue);
      expect(ChatLockStore.instance.isLockedSync('member:8'), isTrue);
      ChatLockSession.end();
      // unlock: wrong code first
      r = toggleChatLock(ctx, 'member:8');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('e-lock-code')), '0000');
      await tester.tap(find.byKey(const Key('e-lock-code-ok')));
      await tester.pumpAndSettle();
      expect(find.text('Wrong code. Try again.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('e-lock-code')), '2468');
      await tester.tap(find.byKey(const Key('e-lock-code-ok')));
      await tester.pumpAndSettle();
      expect(await r, isFalse); // now unlocked
      expect(ChatLockStore.instance.isLockedSync('member:8'), isFalse);
    });

    testWidgets('biometric success opens without the code', (tester) async {
      await ChatLockStore.instance.setCode('1357');
      ChatLockAuth.biometric = (_) async => true;
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      final ok = ChatLockAuth.authenticate(ctx);
      await tester.pumpAndSettle();
      expect(await ok, isTrue);
      expect(find.byKey(const Key('e-lock-code')), findsNothing);
      expect(ChatLockSession.isOpen, isTrue);
    });

    testWidgets('forgot code: unlock all + clear their history', (tester) async {
      await ChatLockStore.instance.setCode('1357');
      await ChatLockStore.instance.lock('member:3');
      await ChatLockStore.instance.lock('group:4');
      ChatLockAuth.biometric = (_) async => null;
      final cleared = <String>[];
      ChatLockAuth.clearChat = (k) async => cleared.add(k);
      late BuildContext ctx;
      await tester.pumpWidget(_app(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      final ok = ChatLockAuth.authenticate(ctx);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forgot code?'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('e-lock-forgot-ok')));
      await tester.pumpAndSettle();
      expect(await ok, isFalse);
      expect(cleared.toSet(), {'member:3', 'group:4'});
      expect(await ChatLockStore.instance.locked(), isEmpty);
    });

    testWidgets('a locked chat opened from outside shows the lock first', (tester) async {
      await ChatLockStore.instance.setCode('1357');
      await ChatLockStore.instance.lock('member:2');
      ChatLockAuth.biometric = (_) async => false; // cancelled
      await tester.pumpWidget(_app(const ChatLockGate(
          chatKey: 'member:2', child: Text('SECRET CHAT'))));
      await tester.pumpAndSettle();
      // the code dialog is up; cancel it
      await tester.tap(find.text(_en.cancel));
      await tester.pumpAndSettle();
      expect(find.text('SECRET CHAT'), findsNothing);
      expect(find.text('This chat is locked'), findsOneWidget);
      ChatLockAuth.biometric = (_) async => true;
      await tester.tap(find.byKey(const Key('e-lock-gate-unlock')));
      await tester.pumpAndSettle();
      expect(find.text('SECRET CHAT'), findsOneWidget);
    });

    test('notification of a locked chat: no name, no text, no reply', () async {
      final e2e = SoftwareE2E();
      final me = e2e.generateIdentity();
      final peer = e2e.generateIdentity();
      final ct = e2e.encrypt(self: peer, recipientPublicKey: me.publicKey, plaintext: 'top secret');
      final pull = {
        'chat': {'kind': 'member', 'id': 12, 'title': 'Amina'},
        'me': {'id': 9, 'name': 'Me'},
        'unseen': 1,
        'messages': [
          {
            'id': 1, 'sender_id': 1, 'mine': false, 'sender_name': 'Amina',
            'content_type': 'text', 'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64,
            'sender_key_id': ct.senderKeyId, 'scheme': ct.scheme,
            'peer_public_key': base64Encode(peer.publicKey), 'deleted': '',
            'created_at': DateTime(2026, 10, 22).toUtc().toIso8601String(),
          }
        ],
      };
      final m = buildMsgNotifModel(pull,
          decrypt: e2eDecryptor(me, e2e: e2e), hide: false, t: _en, lang: 'en', locked: true);
      expect(m.title, 'Assisto');
      expect(m.locked, isTrue);
      expect(m.lines.single.text, 'New message');
      expect(m.lines.single.sender, 'Assisto');
      final d = msgNotificationDetails(m, _en, channelId: 'c');
      expect(d.android!.actions, isEmpty);
      expect(d.android!.shortcutId, isNull);
      final open = buildMsgNotifModel(pull,
          decrypt: e2eDecryptor(me, e2e: e2e), hide: false, t: _en, lang: 'en');
      expect(open.lines.single.text, 'top secret');
      expect(msgNotificationDetails(open, _en, channelId: 'c').android!.actions, hasLength(2));
    });
  });

  // ------------------------------------------------ chat list: lock / pin / search
  group('chat list', () {
    setUp(() {
      UnreadStore.instance.reset();
      RealtimeChannel.instance.resetForTest();
    });

    testWidgets('locked chat leaves the list into "Locked chats"; group pin + archive real',
        (tester) async {
      await ChatLockStore.instance.setCode('1357');
      await ChatLockStore.instance.lock('member:1');
      ChatLockAuth.biometric = (_) async => true;
      final api = _Api();
      await _pumpHub(tester, api);
      expect(find.text('Rahim'), findsNothing);
      expect(find.text('Karim'), findsOneWidget);
      expect(find.byKey(const Key('e-locked-banner')), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-locked-banner')));
      await _settle(tester);
      expect(find.text('Rahim'), findsOneWidget);
      expect(find.text('Karim'), findsNothing);
      await tester.tap(find.byKey(const Key('e-locked-back')));
      await _settle(tester);
      expect(ChatLockSession.isOpen, isFalse);
      expect(find.text('Rahim'), findsNothing);

      // group: pin (was 1:1 only) -> the server organise endpoint
      await tester.longPress(find.text('Family'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('e-org-pin')));
      await _settle(tester);
      expect(api.posts.last, '/circle/groups/7/organise');
      expect(api.bodies.last, {'pinned': true});
      await tester.longPress(find.text('Family'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('e-org-archive')));
      await _settle(tester);
      expect(api.bodies.last, {'archived': true});
      expect(find.text('Family'), findsNothing); // moved to Archived
      await _drain(tester);
    });

    testWidgets('typing in the list search offers a real message search', (tester) async {
      final api = _Api();
      await _pumpHub(tester, api);
      expect(find.byKey(const Key('e-search-messages')), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'dinner');
      await tester.pump();
      expect(find.text('Search messages for "dinner"'), findsOneWidget);
      await tester.tap(find.byKey(const Key('e-search-messages')));
      await _settle(tester);
      // the message search screen opened with the query, decrypted on device
      expect(find.byKey(const Key('e-msg-search-box')), findsOneWidget);
      expect(find.text('Dinner at 8 tonight?'), findsOneWidget);
      expect(api.gets, contains('/circle/1/messages'));
      await _drain(tester);
    });
  });
}

// ---------------------------------------------------------------- hub harness
final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _rahim = _e2e.generateIdentity();
final _karim = _e2e.generateIdentity();

Map<String, dynamic> _env(String text, IdentityKeyPair from, IdentityKeyPair to) {
  final ct = _e2e.encrypt(self: from, recipientPublicKey: to.publicKey, plaintext: text);
  return {
    'ciphertext': ct.ciphertextB64,
    'nonce': ct.nonceB64,
    'sender_key_id': ct.senderKeyId,
    'scheme': ct.scheme,
  };
}

class _Api extends ApiClient {
  _Api() {
    token = 't';
  }
  final posts = <String>[];
  final bodies = <Map<String, dynamic>>[];
  final gets = <String>[];
  bool groupArchived = false;

  List<Map<String, dynamic>> get rows => [
        {
          'id': '1',
          'kind': 'member',
          'member': {'id': 1, 'name': 'Rahim', 'public_key': base64Encode(_rahim.publicKey)},
          'unread': 0,
          'at': DateTime.now().toUtc().toIso8601String(),
          'last': {
            'id': 50, 'mine': false, 'content_type': 'text',
            'peer_public_key': base64Encode(_rahim.publicKey),
            ..._env('Are you coming?', _rahim, _me),
          },
        },
        {
          'id': '2',
          'kind': 'member',
          'member': {'id': 2, 'name': 'Karim', 'public_key': base64Encode(_karim.publicKey)},
          'unread': 0,
          'at': DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String(),
          'last': null,
        },
        {
          'id': 'g7',
          'kind': 'group',
          'is_group': true,
          'group_id': 7,
          'group': {'id': 7, 'name': 'Family', 'my_member_id': 3},
          'member': {'id': null, 'name': 'Family'},
          'unread': 0,
          'archived': groupArchived,
          'at': DateTime.now().subtract(const Duration(days: 3)).toUtc().toIso8601String(),
          'last': null,
        },
      ];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path == '/circle/chats') return {'results': rows};
    if (path == '/circle/1/messages') {
      return {
        'results': [
          {
            'id': 60, 'sender_id': 1, 'content_type': 'text', 'deleted': '',
            'created_at': DateTime(2026, 10, 20).toUtc().toIso8601String(),
            ..._env('Dinner at 8 tonight?', _rahim, _me),
          },
          {
            'id': 61, 'sender_id': 9, 'content_type': 'text', 'deleted': '',
            'created_at': DateTime(2026, 10, 20, 1).toUtc().toIso8601String(),
            ..._env('ok', _me, _rahim),
          },
        ]
      };
    }
    if (path.contains('/messages')) return {'results': const []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path);
    bodies.add(body);
    if (path == '/circle/groups/7/organise' && body.containsKey('archived')) {
      groupArchived = body['archived'] == true;
    }
    return {'ok': true};
  }

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

AppState _state(_Api api) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 9, name: 'Me', phone: '+8801700000000', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Future<void> _pumpHub(WidgetTester tester, _Api api) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: _state(api),
    child: _app(MsgrHubChatList(identity: _me, members: [
      {'id': 1, 'name': 'Rahim', 'public_key': base64Encode(_rahim.publicKey)},
    ])),
  ));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 20));
}
