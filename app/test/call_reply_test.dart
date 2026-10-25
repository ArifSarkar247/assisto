// call-reply: WhatsApp-style "Reply with message" on an incoming call.
//  * the in-app incoming screen shows Reply (bn/en) between Decline/Accept
//  * Reply = the normal decline (ring cleared, lock screen released, screen
//    closed) + the reply hand-off with the payload
//  * group / chat-less rings hide Reply
//  * the quick-reply sheet: 4 presets + "Write your own…"; a preset fills the
//    composer and goes through the chat's NORMAL send callback
//  * launch extras: the notification action "call_reply" (native ring or
//    Dart-drawn ring) declines + queues that chat with the sheet, and the
//    entry suppresses the app-open ad
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/ads/app_open_gate.dart' show AppEntry;
import 'package:assisto/calls/call_reply.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/push/push_service.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

final _payload = PushPayload({
  'kind': 'call',
  'call_id': '7',
  'chat_id': '3',
  'caller_name': 'Ayesha',
  'video': 'false',
  'ack_sig': 'abc',
});

final _group = PushPayload({
  'kind': 'call',
  'call_id': '8',
  'chat_id': '4',
  'chat_kind': 'group',
  'caller_name': 'Family',
  'video': 'false',
});

final _noChat = PushPayload({
  'kind': 'call',
  'call_id': '9',
  'chat_id': '',
  'caller_name': 'X',
});

void main() {
  const calls = MethodChannel('com.assisto/calls');
  const lock = MethodChannel('com.assisto/lockscreen');
  late List<MethodCall> native;

  setUp(() {
    native = [];
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(calls, (c) async {
      native.add(c);
      return true;
    });
    m.setMockMethodCallHandler(lock, (c) async {
      native.add(c);
      return null;
    });
  });
  tearDown(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(calls, null);
    m.setMockMethodCallHandler(lock, null);
  });

  group('logic', () {
    test('canReply: 1:1 ring with a chat only', () {
      expect(CallReply.canReply(_payload), isTrue);
      expect(CallReply.memberId(_payload), 3);
      expect(CallReply.canReply(_group), isFalse);
      expect(CallReply.canReply(_noChat), isFalse);
      expect(
          CallReply.canReply(PushPayload(
              {'kind': 'call', 'call_id': '1', 'chat_id': '5', 'group_id': '2'})),
          isFalse);
      expect(
          CallReply.canReply(
              PushPayload({'kind': 'missed_call', 'call_id': '1', 'chat_id': '5'})),
          isFalse);
      // the native action id is the same string
      expect(CallReply.action, 'call_reply');
    });

    test('Dart-drawn ring: Reply sits between Decline and Accept', () {
      final a = PushNotifier.detailsFor(_payload).android!.actions!;
      expect(a.map((x) => x.id).toList(),
          [PushNotifier.actionDecline, CallReply.action, PushNotifier.actionAccept]);
      final r = a[1];
      expect(r.showsUserInterface, isTrue); // opens the app (unlock first)
      expect(r.cancelNotification, isTrue);
      final g = PushNotifier.detailsFor(_group).android!.actions!;
      expect(g.map((x) => x.id), isNot(contains(CallReply.action)));
    });

    test('launch extra call_reply: decline + chat queued with the sheet',
        () async {
      PushService.instance.resetForTest();
      AppEntry.consumeSuppression();
      PushService.instance.localResponseForTest(NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: CallReply.action,
          payload: _payload.encode()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final pc = PushService.instance.pendingChatForTest;
      expect(pc, isNotNull);
      expect(pc!.kind, 'member');
      expect(pc.id, 3);
      expect(pc.quickReply, isTrue);
      // the ring is cleared (native Telecom call too)
      expect(
          native.any((c) =>
              c.method == 'cancelRing' &&
              (c.arguments as Map)['call_id'] == '7'),
          isTrue);
      // a call entry: no app-open ad
      expect(AppEntry.consumeSuppression(), isTrue);
      PushService.instance.resetForTest();
    });

    test('launch extra call_reply on a group ring: plain decline, no chat',
        () async {
      PushService.instance.resetForTest();
      PushService.instance.localResponseForTest(NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: CallReply.action,
          payload: _group.encode()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(PushService.instance.pendingChatForTest, isNull);
      expect(native.any((c) => c.method == 'cancelRing'), isTrue);
      PushService.instance.resetForTest();
    });
  });

  group('incoming screen', () {
    testWidgets('Reply button (en, 360px, big font)', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 720 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: _app(IncomingCallScreen(payload: _payload))));
      await tester.pump();
      expect(find.byKey(const Key('incoming-reply')), findsOneWidget);
      expect(find.text('Reply'), findsOneWidget);
      final sz = tester.getSize(find.descendant(
          of: find.byKey(const Key('incoming-reply')),
          matching: find.byType(InkWell)));
      expect(sz.width >= 48 && sz.height >= 48, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 62));
    });

    testWidgets('Reply button in Bangla', (tester) async {
      await tester.pumpWidget(_app(IncomingCallScreen(payload: _payload),
          locale: const Locale('bn')));
      await tester.pump();
      expect(find.text('উত্তর লিখুন'), findsOneWidget);
      expect(find.text('কেটে দিন'), findsOneWidget);
      await tester.pump(const Duration(seconds: 62));
    });

    testWidgets('group / chat-less ring: no Reply', (tester) async {
      await tester.pumpWidget(_app(IncomingCallScreen(payload: _group)));
      await tester.pump();
      expect(find.byKey(const Key('incoming-reply')), findsNothing);
      expect(find.byKey(const Key('incoming-decline')), findsOneWidget);
      await tester.pumpWidget(_app(IncomingCallScreen(payload: _noChat)));
      await tester.pump();
      expect(find.byKey(const Key('incoming-reply')), findsNothing);
      await tester.pump(const Duration(seconds: 62));
    });

    testWidgets('tap Reply: declines like Decline, then hands over',
        (tester) async {
      final handed = <PushPayload>[];
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Center(
              child: TextButton(
                  onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                      builder: (_) => IncomingCallScreen(
                          payload: _payload, onReply: handed.add))),
                  child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('incoming-reply')));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(handed.single.callId, '7');
      expect(
          native.any((c) =>
              c.method == 'cancelRing' &&
              (c.arguments as Map)['call_id'] == '7'),
          isTrue);
      expect(native.map((c) => c.method), contains('release'));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget); // ringing screen closed
    });
  });

  group('quick-reply sheet', () {
    Future<({TextEditingController input, List<String> sent, List<int> focus})>
        open(WidgetTester tester, Locale locale) async {
      final input = TextEditingController();
      final sent = <String>[];
      final focus = <int>[];
      await tester.pumpWidget(_app(
          Builder(
              builder: (ctx) => Scaffold(
                    body: Center(
                        child: TextButton(
                            onPressed: () => runCallQuickReply(ctx,
                                name: 'Ayesha',
                                input: input,
                                send: () async => sent.add(input.text),
                                focus: () => focus.add(1)),
                            child: const Text('go'))),
                  )),
          locale: locale));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return (input: input, sent: sent, focus: focus);
    }

    testWidgets('en: 4 presets + write your own; preset -> composer + send',
        (tester) async {
      final h = await open(tester, const Locale('en'));
      expect(find.byKey(const Key('call-reply-sheet')), findsOneWidget);
      expect(find.text('Reply with a message'), findsOneWidget);
      for (final s in const [
        "Can't talk now. What's up?",
        "I'll call you right back.",
        "I'll call you later.",
        "Can't talk now. Call me later?",
        'Write your own…',
      ]) {
        expect(find.text(s), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('call-reply-preset-1')));
      await tester.pumpAndSettle();
      expect(h.input.text, "I'll call you right back.");
      expect(h.sent, ["I'll call you right back."]);
      expect(h.focus, isEmpty);
      expect(find.byKey(const Key('call-reply-sheet')), findsNothing);
    });

    testWidgets('bn: presets in Bangla; write your own focuses the box',
        (tester) async {
      final h = await open(tester, const Locale('bn'));
      expect(find.text('মেসেজ দিয়ে উত্তর দিন'), findsOneWidget);
      expect(find.text('আমি পরে ফোন করব।'), findsOneWidget);
      expect(find.text('নিজে লিখুন…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('call-reply-own')));
      await tester.pumpAndSettle();
      expect(h.sent, isEmpty);
      expect(h.focus, [1]);
      expect(h.input.text, isEmpty);
    });

    testWidgets('dismissed: nothing sent', (tester) async {
      final h = await open(tester, const Locale('en'));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(h.sent, isEmpty);
      expect(h.focus, isEmpty);
    });
  });
}
