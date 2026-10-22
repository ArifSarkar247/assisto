// c3-msg — RealtimeChannel (typing throttle, refcounted battery-friendly
// polling), presence labels (bn/en), bubble prefs, swipe-to-reply.
import 'dart:async';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/msg_prefs.dart';
import 'package:assisto/messaging/msg_widgets.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTransport implements RealtimeTransport {
  final sent = <(String, Map<String, dynamic>)>[];
  final ctl = StreamController<RealtimeEvent>.broadcast();
  int snaps = 0;
  bool lastOnline = false;
  bool hb = false;
  Map<String, dynamic> next = {'chats': {}};
  @override
  Future<Map<String, dynamic>> snapshot({required bool online}) async {
    snaps++;
    lastOnline = online;
    return next;
  }

  @override
  Future<void> send(String topic, Map<String, dynamic> payload) async =>
      sent.add((topic, payload));

  @override
  Stream<RealtimeEvent> get events => ctl.stream;

  @override
  set heartbeat(bool on) => hb = on;

  @override
  void close() {}
}

RealtimeEvent _ev(int seq, String topic, Map<String, dynamic> p) =>
    RealtimeEvent(seq, topic, p, DateTime.now());

void main() {
  final rt = RealtimeChannel.instance;
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
  });
  setUp(rt.resetForTest);

  group('typing throttle', () {
    test('one "typing" per 3 s per chat; stop/change goes out at once', () {
      final t = _FakeTransport();
      rt.useTransport(t);
      var now = DateTime(2026, 10, 22, 10);
      rt.now = () => now;
      expect(rt.typing('member', 1, 'typing'), isTrue);
      now = now.add(const Duration(milliseconds: 800));
      expect(rt.typing('member', 1, 'typing'), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(rt.typing('member', 1, 'typing'), isFalse);
      now = now.add(const Duration(milliseconds: 1300));
      expect(rt.typing('member', 1, 'typing'), isTrue); // > 3 s
      expect(rt.typing('member', 1, 'recording'), isTrue); // state change
      expect(rt.typing('member', 1, 'stop'), isTrue);
      expect(rt.typing('member', 1, 'stop'), isFalse); // already stopped
      expect(rt.typing('member', 2, 'typing'), isTrue); // other chat
    });

    test('stop before any typing sends nothing', () {
      final t = _FakeTransport();
      rt.useTransport(t);
      expect(rt.typing('group', 3, 'stop'), isFalse);
      expect(t.sent, isEmpty);
    });

    test('typing goes out on the shared queue as typing.set', () async {
      final t = _FakeTransport();
      rt.useTransport(t);
      rt.typing('group', 3, 'recording');
      await Future<void>.delayed(Duration.zero);
      expect(t.sent.single.$1, 'typing.set');
      expect(t.sent.single.$2,
          {'chat_kind': 'group', 'chat_id': 3, 'state': 'recording'});
    });
  });

  group('battery: ONE shared loop, heartbeat only while My Circle is visible', () {
    test('acquire / release / background', () async {
      final t = _FakeTransport()
        ..next = {
          'chats': {
            'member:5': {'online': true, 'last_seen': null, 'activity': 'typing', 'who': ''}
          }
        };
      rt.useTransport(t);
      expect(t.hb, isFalse);
      rt.acquire();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.hb, isTrue); // the shared poll carries online=1
      expect(t.snaps, 1); // one snapshot when the screen appears
      expect(t.lastOnline, isTrue);
      expect(rt.stateOf('member', 5).typing, isTrue);
      expect(rt.stateOf('member', 5).online, isTrue);
      rt.acquire();
      rt.release();
      expect(t.hb, isTrue); // still one screen
      expect(t.snaps, 1); // no second loop, no periodic snapshot
      rt.setForeground(false);
      expect(t.hb, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(t.sent.last.$1, 'presence.set');
      expect(t.sent.last.$2, {'state': 'away'});
      rt.setForeground(true);
      expect(t.hb, isTrue);
      rt.release();
      expect(t.hb, isFalse);
      expect(rt.refs, 0);
    });

    test('live presence.update / typing.update from the shared loop', () async {
      final t = _FakeTransport();
      rt.useTransport(t);
      rt.acquire();
      await Future<void>.delayed(Duration.zero);
      final until = DateTime.now().add(const Duration(seconds: 60));
      t.ctl.add(_ev(1, 'presence.update', {
        'chat': 'member:5',
        'online': true,
        'last_seen': '2026-10-22T10:14:00Z',
        'until': until.toUtc().toIso8601String(),
      }));
      await Future<void>.delayed(Duration.zero);
      expect(rt.stateOf('member', 5).online, isTrue);
      expect(rt.stateOf('member', 5).lastSeen, isNotNull);
      expect(rt.expiryArmed, isTrue); // re-check once when "online" lapses
      t.ctl.add(_ev(2, 'typing.update',
          {'chat': 'group:3', 'activity': 'typing', 'who': 'Rahim', 'ttl_s': 1}));
      await Future<void>.delayed(Duration.zero);
      expect(rt.stateOf('group', 3).typing, isTrue);
      expect(rt.stateOf('group', 3).who, 'Rahim');
      // the typing line clears itself after ttl_s without a stop event
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(rt.stateOf('group', 3).active, isFalse);
      t.ctl.add(_ev(3, 'presence.update',
          {'chat': 'member:5', 'online': false, 'last_seen': '2026-10-22T10:20:00Z'}));
      await Future<void>.delayed(Duration.zero);
      expect(rt.stateOf('member', 5).online, isFalse);
      expect(rt.expiryArmed, isFalse);
      rt.release();
    });

    test('SharedPollTransport rides PollRealtimeTransport (one loop)', () async {
      final paths = <String>[];
      final poll = PollRealtimeTransport(
        get: (p) async {
          paths.add(p);
          if (p.startsWith('/rt/events') && paths.length > 1) {
            return {
              'events': [
                {'seq': 9, 'topic': 'typing.update', 'payload': {'chat': 'member:1', 'activity': 'typing'}},
                {'seq': 10, 'topic': 'call.state', 'payload': {}},
              ],
              'seq': 10
            };
          }
          return {'events': [], 'seq': 8, 'chats': {}};
        },
        post: (p, b) async {
          paths.add('POST $p ${b['topic']}');
          return {'ok': true};
        },
        idleInterval: const Duration(milliseconds: 5),
      );
      final a = SharedPollTransport(poll, get: (p) async {
        paths.add(p);
        return {'chats': {}};
      });
      final got = <String>[];
      a.events.listen((e) => got.add(e.topic));
      a.heartbeat = true;
      await poll.connect();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await a.snapshot(online: true);
      await a.send('presence.set', {'state': 'away'});
      await poll.close();
      expect(paths.first, '/rt/events?after=0&online=1');
      expect(got, ['typing.update'], reason: 'call.* is not for presence');
      expect(paths, contains('/circle/rt/state?online=1'));
      expect(paths, contains('POST /rt/send presence.set'));
      expect(paths.where((p) => p.startsWith('/circle/rt/typing') ||
          p.startsWith('/circle/rt/presence')), isEmpty);
    });
  });

  group('presence label', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final bn = lookupAppLocalizations(const Locale('bn'));
    final now = DateTime(2026, 10, 22, 18, 0);

    test('priority: recording > typing > online > last seen', () {
      expect(presenceLabel(en, const RtChatState(activity: 'recording', online: true), lang: 'en', now: now),
          'recording audio…');
      expect(presenceLabel(en, const RtChatState(activity: 'typing', online: true), lang: 'en', now: now),
          'typing…');
      expect(presenceLabel(en, const RtChatState(online: true), lang: 'en', now: now), 'online');
      expect(
          presenceLabel(en, RtChatState(online: false, lastSeen: DateTime(2026, 10, 22, 10, 14)),
              lang: 'en', now: now),
          'last seen today at 10:14 am');
      expect(
          presenceLabel(en, RtChatState(online: false, lastSeen: DateTime(2026, 10, 21, 21, 3)),
              lang: 'en', now: now),
          'last seen yesterday at 9:03 pm');
      expect(
          presenceLabel(en, RtChatState(lastSeen: DateTime(2026, 10, 12, 9, 0)), lang: 'en', now: now),
          'last seen 12 Oct at 9:00 am');
    });

    test('hidden by privacy → nothing', () {
      expect(presenceLabel(en, const RtChatState(), lang: 'en', now: now), isNull);
    });

    test('groups: "Rahim is typing…"; no presence line otherwise', () {
      expect(presenceLabel(en, const RtChatState(activity: 'typing', who: 'Rahim'), lang: 'en', isGroup: true),
          'Rahim is typing…');
      expect(presenceLabel(en, const RtChatState(online: true), lang: 'en', isGroup: true), isNull);
    });

    test('Bangla', () {
      expect(presenceLabel(bn, const RtChatState(online: true), lang: 'bn', now: now), bn.c3Online);
      final ls = presenceLabel(bn, RtChatState(lastSeen: DateTime(2026, 10, 22, 10, 14)), lang: 'bn', now: now)!;
      expect(ls, isNot(contains('last seen')));
    });
  });

  group('bubble + notification prefs', () {
    test('per-chat bubble list + global switch + hide content + sound channel', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await MsgPrefs.bubblesOn(), isTrue);
      expect(await MsgPrefs.isBubbleChat('member', 12), isFalse);
      await MsgPrefs.setBubbleChat('member', 12, true);
      await MsgPrefs.setBubbleChat('group', 3, true);
      expect(await MsgPrefs.isBubbleChat('member', 12), isTrue);
      final p = await SharedPreferences.getInstance();
      // the native BubbleHelper reads this exact plain string
      expect(p.getString(MsgPrefs.kBubbleChats), 'group:3,member:12');
      await MsgPrefs.setBubbleChat('member', 12, false);
      expect(await MsgPrefs.isBubbleChat('member', 12), isFalse);
      await MsgPrefs.setBubblesOn(false);
      expect(await MsgPrefs.bubblesOn(), isFalse);
      expect(await MsgPrefs.hideContent(), isFalse);
      await MsgPrefs.setHideContent(true);
      expect(await MsgPrefs.hideContent(), isTrue);
      // ONE message sound, on c2-calls' shared keys (snd_msg_uri/_title)
      expect(MsgPrefs.kSoundUri, 'snd_msg_uri');
      expect(MsgPrefs.kSoundTitle, 'snd_msg_title');
      expect(await MsgPrefs.channelId(), 'messages'); // absent = phone default
      await p.setString('snd_msg_uri', 'content://media/internal/audio/media/7');
      final c1 = await MsgPrefs.channelId();
      expect(c1, startsWith('messages_'));
      await MsgPrefs.setSound('content://media/internal/audio/media/8', 'Bell');
      expect(p.getString('snd_msg_title'), 'Bell');
      final c2 = await MsgPrefs.channelId();
      expect(c2, allOf(startsWith('messages_'), isNot(c1))); // new sound = new channel
      await MsgPrefs.setSound('', '');
      expect(await MsgPrefs.channelId(), 'messages_silent'); // '' = silent
      await MsgPrefs.setSound(null, '');
      expect(p.containsKey('snd_msg_uri'), isFalse);
      expect(await MsgPrefs.channelId(), 'messages');
    });
  });

  group('swipe to reply', () {
    Future<int> swipe(WidgetTester tester, {required bool mine, required double dx}) async {
      var replies = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SwipeToReply(
            mine: mine,
            onReply: () => replies++,
            child: const SizedBox(width: 300, height: 60, child: Text('bubble')),
          ),
        ),
      ));
      await tester.drag(find.text('bubble'), Offset(dx, 0));
      await tester.pumpAndSettle();
      return replies;
    }

    testWidgets('received: swipe RIGHT replies, left does not', (tester) async {
      expect(await swipe(tester, mine: false, dx: 120), 1);
      expect(await swipe(tester, mine: false, dx: -120), 0);
    });

    testWidgets('mine: swipe LEFT replies; a short swipe does not', (tester) async {
      expect(await swipe(tester, mine: true, dx: -120), 1);
      expect(await swipe(tester, mine: true, dx: -30), 0);
    });
  });
}
