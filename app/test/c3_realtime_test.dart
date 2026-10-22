// c3-msg — RealtimeChannel (typing throttle, refcounted battery-friendly
// polling), presence labels (bn/en), bubble prefs, swipe-to-reply.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/msg_prefs.dart';
import 'package:assisto/messaging/msg_widgets.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTransport extends RealtimeTransport {
  final sent = <Map<String, dynamic>>[];
  int snaps = 0;
  bool lastOnline = false;
  Map<String, dynamic> next = {'chats': {}};
  @override
  Duration? get pollInterval => const Duration(seconds: 4);
  @override
  Future<Map<String, dynamic>> snapshot({required bool online}) async {
    snaps++;
    lastOnline = online;
    return next;
  }

  @override
  Future<void> send(Map<String, dynamic> event) async => sent.add(event);
}

void main() {
  final rt = RealtimeChannel.instance;
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
  });

  group('battery: polls only while a My Circle screen is visible', () {
    test('acquire / release / background', () async {
      final t = _FakeTransport()
        ..next = {
          'chats': {
            'member:5': {'online': true, 'last_seen': null, 'activity': 'typing', 'who': ''}
          }
        };
      rt.useTransport(t);
      expect(rt.polling, isFalse);
      rt.acquire();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rt.polling, isTrue);
      expect(t.snaps, 1);
      expect(t.lastOnline, isTrue); // the poll IS the presence heartbeat
      expect(rt.stateOf('member', 5).typing, isTrue);
      expect(rt.stateOf('member', 5).online, isTrue);
      rt.acquire();
      rt.release();
      expect(rt.polling, isTrue); // still one screen
      rt.setForeground(false);
      expect(rt.polling, isFalse);
      expect(t.sent.last, {'type': 'presence', 'state': 'away'});
      rt.setForeground(true);
      expect(rt.polling, isTrue);
      rt.release();
      expect(rt.polling, isFalse);
      expect(rt.refs, 0);
    });

    test('PollingTransport maps events onto the c3 endpoints', () async {
      final calls = <String>[];
      final p = PollingTransport(
          get: (path) async {
            calls.add('GET $path');
            return {'chats': {}};
          },
          post: (path, body) async {
            calls.add('POST $path ${body['state']}');
            return {};
          });
      await p.snapshot(online: true);
      await p.send({'type': 'typing', 'chat_kind': 'member', 'chat_id': 1, 'state': 'typing'});
      await p.send({'type': 'presence', 'state': 'away'});
      await p.send({'type': 'call.offer'}); // c2-calls' transport handles these
      expect(calls, [
        'GET /circle/rt/state?online=1',
        'POST /circle/rt/typing typing',
        'POST /circle/rt/presence away',
      ]);
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
          'last seen today at 10:14');
      expect(
          presenceLabel(en, RtChatState(online: false, lastSeen: DateTime(2026, 10, 21, 21, 3)),
              lang: 'en', now: now),
          'last seen yesterday at 21:03');
      expect(
          presenceLabel(en, RtChatState(lastSeen: DateTime(2026, 10, 12, 9, 0)), lang: 'en', now: now),
          startsWith('last seen Oct 12'));
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
      expect(await MsgPrefs.channelId(), 'messages'); // phone default sound
      await MsgPrefs.setSound('content://media/internal/audio/media/7', 'Chime');
      expect(await MsgPrefs.channelId(), 'messages_s1');
      await MsgPrefs.setSound('content://media/internal/audio/media/8', 'Bell');
      expect(await MsgPrefs.channelId(), 'messages_s2'); // new sound = new channel
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
