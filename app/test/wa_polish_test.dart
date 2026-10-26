// wa-polish (owner 25 Oct: "My Circle + calls UX to WhatsApp level"):
//  1. chat: round "go to latest" button + count of messages that arrived
//     while scrolled up (1:1 + group use the same widget)
//  2. chat: a failed message says "Not sent · Tap to retry" (was long-press only)
//  3. call log: All / Missed filter
//  4. call screen: a call that connected ends with its talk time, frozen
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/chat_jump_to_latest.dart';
import 'package:assisto/widgets/circle_bubble.dart';

import 'c2_calls_fakes.dart';

Widget _app(Widget home, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

/// A reversed chat list (offset 0 = newest) + the jump button, like the
/// real chat screens.
class _JumpHarness extends StatefulWidget {
  const _JumpHarness({required this.incoming});
  final ValueNotifier<List<String>> incoming;
  @override
  State<_JumpHarness> createState() => _JumpHarnessState();
}

class _JumpHarnessState extends State<_JumpHarness> {
  final _scroll = ScrollController();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: ValueListenableBuilder<List<String>>(
          valueListenable: widget.incoming,
          builder: (_, ids, __) => Stack(children: [
            Positioned.fill(
              child: ListView.builder(
                controller: _scroll,
                reverse: true,
                itemCount: 200,
                itemBuilder: (_, i) =>
                    SizedBox(height: 60, child: Text('row $i')),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: ChatJumpToLatest(controller: _scroll, incomingIds: ids),
            ),
          ]),
        ),
      );
}

class _CallsApi extends ApiClient {
  _CallsApi() {
    token = 't';
  }
  @override
  Future<Map<String, dynamic>> getJson(String path) async => {
        'calls': [
          {'id': 3, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
           'name': 'Shanto', 'outcome': 'Voice · Missed call',
           'started_at': '2026-10-22T07:30:00Z'},
          {'id': 2, 'kind': 'video', 'state': 'ended', 'outgoing': true,
           'name': 'Ammu', 'duration': '01:05',
           'started_at': '2026-10-21T07:30:00Z'},
          {'id': 1, 'kind': 'voice', 'state': 'missed', 'outgoing': true,
           'name': 'Karim', 'outcome': 'No answer',
           'started_at': '2026-10-20T07:30:00Z'},
        ],
      };
}

void main() {
  // the call log marks missed calls seen (CircleBadges -> Settings)
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('go to latest', () {
    testWidgets('hidden at the newest message, shows when scrolled up, '
        'counts only NEW incoming, tap returns to the newest', (tester) async {
      final ids = ValueNotifier<List<String>>(['1', '2']);
      await tester.pumpWidget(_app(_JumpHarness(incoming: ids)));
      final btn = find.byKey(const Key('wa-jump-latest'));
      double opacity() => tester
          .widget<AnimatedOpacity>(find.ancestor(
              of: btn, matching: find.byType(AnimatedOpacity)))
          .opacity;
      expect(opacity(), 0);

      await tester.drag(find.byType(ListView), const Offset(0, 1200));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      expect(find.byKey(const Key('wa-jump-latest-count')), findsNothing,
          reason: 'old messages are not "new"');

      ids.value = ['1', '2', '3', '4'];
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wa-jump-latest-count')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // semantic label says how many + what it does (48 dp target)
      expect(tester.getSize(btn).width, greaterThanOrEqualTo(48));
      expect(find.bySemanticsLabel(RegExp('2 new messages')), findsOneWidget);

      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsOneWidget);
      expect(opacity(), 0);
      expect(find.byKey(const Key('wa-jump-latest-count')), findsNothing);
    });

    testWidgets('Bangla digits in the count', (tester) async {
      final ids = ValueNotifier<List<String>>([]);
      await tester.pumpWidget(_app(_JumpHarness(incoming: ids), lang: 'bn'));
      await tester.drag(find.byType(ListView), const Offset(0, 1200));
      await tester.pumpAndSettle();
      ids.value = ['a', 'b', 'c'];
      await tester.pumpAndSettle();
      expect(find.text('৩'), findsOneWidget);
      expect(find.text('3'), findsNothing);
    });
  });

  group('failed send', () {
    CircleMessage msg(String status, {bool mine = true}) => CircleMessage(
        id: 'm1', text: 'hello', mine: mine, at: DateTime(2026, 10, 25, 9),
        status: status);

    testWidgets('failed: visible "Not sent · Tap to retry", tap retries',
        (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      var retried = 0;
      await tester.pumpWidget(_app(Scaffold(
          body: CircleBubble(msg: msg('failed'), onRetry: () => retried++))));
      expect(find.text(t.waNotSentRetry), findsOneWidget);
      final line = find.byKey(const ValueKey('wa-retry-m1'));
      expect(tester.getSize(line).height, greaterThanOrEqualTo(48));
      await tester.tap(line);
      expect(retried, 1);
    });

    testWidgets('no retry line on a sent message, a received one, or without '
        'a handler', (tester) async {
      final t = lookupAppLocalizations(const Locale('en'));
      for (final b in [
        CircleBubble(msg: msg('sent'), onRetry: () {}),
        CircleBubble(msg: msg('failed', mine: false), onRetry: () {}),
        CircleBubble(msg: msg('failed')),
      ]) {
        await tester.pumpWidget(_app(Scaffold(body: b)));
        expect(find.text(t.waNotSentRetry), findsNothing);
      }
    });

    testWidgets('Bangla retry line fits at 360 dp (no overflow)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(
          Scaffold(body: CircleBubble(msg: msg('failed'), onRetry: () {})),
          lang: 'bn'));
      expect(tester.takeException(), isNull);
      expect(find.text(lookupAppLocalizations(const Locale('bn')).waNotSentRetry),
          findsOneWidget);
    });
  });

  group('call log filter', () {
    test('only an incoming call can be missed', () {
      expect(isMissedCallRow({'state': 'missed', 'outgoing': false}), isTrue);
      expect(isMissedCallRow({'state': 'canceled'}), isTrue);
      expect(isMissedCallRow({'state': 'missed', 'outgoing': true}), isFalse);
      expect(isMissedCallRow({'state': 'ended', 'outgoing': false}), isFalse);
    });

    testWidgets('All / Missed chips filter the log', (tester) async {
      final s = AppState()
        ..api = _CallsApi()
        ..user = AppUser(
            id: 1, name: 'A', phone: '01712345678', email: '',
            autonomyLevel: 2, language: 'en')
        ..loading = false;
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: s, child: _app(const CircleCallHistoryScreen())));
      await tester.pumpAndSettle();
      expect(find.text('Shanto'), findsOneWidget);
      expect(find.text('Ammu'), findsOneWidget);
      expect(find.text('Karim'), findsOneWidget);

      await tester.tap(find.byKey(const Key('call-filter-missed')));
      await tester.pumpAndSettle();
      expect(find.text('Shanto'), findsOneWidget);
      expect(find.text('Ammu'), findsNothing);
      expect(find.text('Karim'), findsNothing,
          reason: 'an outgoing no-answer is not a missed call');
      // call back still one tap away on a missed row
      expect(find.byTooltip(lookupAppLocalizations(const Locale('en'))
          .circleCallBackVoice), findsOneWidget);

      await tester.tap(find.byKey(const Key('call-filter-all')));
      await tester.pumpAndSettle();
      expect(find.text('Karim'), findsOneWidget);
    });
  });

  group('call ended summary', () {
    test('talk time freezes when the call ends', () async {
      var clock = DateTime(2026, 10, 25, 10);
      final c = CallController(
        media: FakeCallMedia(),
        signaling: FakeSignaling(),
        sounds: FakeSounds(),
        video: false,
        outgoing: true,
        memberId: 1,
        callId: 42,
        now: () => clock,
      );
      expect(c.talkTime, isNull);
      c.connectedAt = clock;
      c.phase = CallPhase.connected;
      clock = clock.add(const Duration(minutes: 4, seconds: 7));
      await c.hangup();
      expect(c.isEnded, isTrue);
      clock = clock.add(const Duration(minutes: 10));
      expect(c.talkTime, const Duration(minutes: 4, seconds: 7));
    });

    Future<void> pump(WidgetTester tester, CallController c,
            {String lang = 'en'}) async {
      await tester.pumpWidget(_app(
          CircleCallScreen(
            key: ObjectKey(c),
            member: const {'id': 7, 'name': 'Nadia'},
            kind: 'voice',
            outgoing: true,
            controller: c,
          ),
          lang: lang));
      await tester.pump();
    }

    testWidgets('"Call ended · 04:07" after a real call; plain reasons '
        'otherwise; Bangla digits', (tester) async {
      final en = lookupAppLocalizations(const Locale('en'));
      CallController ended(CallEndReason r, {bool talked = true}) {
        final c = previewController(
            video: false, outgoing: true, phase: CallPhase.ended, reason: r);
        if (talked) {
          c.connectedAt = DateTime(2026, 10, 22, 10, 0, 0);
          c.endedAt = DateTime(2026, 10, 22, 10, 4, 7);
        }
        return c;
      }

      await pump(tester, ended(CallEndReason.hangup));
      expect(find.text(en.waCallEndedAfter('04:07')), findsOneWidget);

      await pump(tester, ended(CallEndReason.hangup, talked: false));
      expect(find.text(en.circleCallEnded), findsOneWidget);

      // an honest failure reason is never hidden behind the timer
      await pump(tester, ended(CallEndReason.lost));
      expect(find.text(en.c2CallLost), findsOneWidget);

      await pump(tester, ended(CallEndReason.hangup), lang: 'bn');
      final bn = lookupAppLocalizations(const Locale('bn'));
      expect(find.text(bn.waCallEndedAfter('০৪:০৭')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
