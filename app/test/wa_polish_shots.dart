// wa-polish gallery states for test/screenshots_test.dart: the WhatsApp-level
// chat + call polish (go-to-latest button with a new-message count, the
// visible "Not sent · Tap to retry" line, "Call ended · 04:07").
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/widgets/chat_jump_to_latest.dart';
import 'package:assisto/widgets/circle_bubble.dart';

import 'c2_calls_fakes.dart';

class _ChatDemo extends StatefulWidget {
  const _ChatDemo({required this.bn});
  final bool bn;
  @override
  State<_ChatDemo> createState() => _ChatDemoState();
}

class _ChatDemoState extends State<_ChatDemo> {
  final _scroll = ScrollController();
  final _incoming = <String>['in-0'];
  String _failedStatus = 'failed'; // tap retry -> sent (like the real resend)

  @override
  void initState() {
    super.initState();
    // scrolled up, then two messages arrive -> the button shows "2"
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(600);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _incoming.addAll(['in-1', 'in-2']));
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final bn = widget.bn;
    final at = DateTime(2026, 10, 25, 18, 2);
    final msgs = <CircleMessage>[
      for (var i = 0; i < 14; i++)
        CircleMessage(
          id: 'h$i',
          text: bn
              ? (i.isEven ? 'কাল দোকানে আসবে?' : 'হ্যাঁ, সকালে আসব')
              : (i.isEven ? 'Coming to the shop tomorrow?' : 'Yes, in the morning'),
          mine: i.isOdd,
          at: at,
          status: 'read',
        ),
      CircleMessage(
        id: 'f1',
        text: bn ? 'দাম কত হবে?' : 'What will the price be?',
        mine: true,
        at: at,
        status: _failedStatus,
      ),
    ].reversed.toList();
    return Scaffold(
      appBar: AppBar(title: Text(bn ? 'আবুল কাশেম' : 'Abul Kashem')),
      body: Stack(children: [
        Positioned.fill(
          child: ListView.builder(
            controller: _scroll,
            reverse: true,
            itemCount: msgs.length,
            itemBuilder: (_, i) => CircleBubble(
                msg: msgs[i],
                onRetry: () => setState(() => _failedStatus = 'sent')),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: ChatJumpToLatest(controller: _scroll, incomingIds: _incoming),
        ),
      ]),
    );
  }
}

class _FailedDemo extends StatefulWidget {
  const _FailedDemo({required this.bn});
  final bool bn;
  @override
  State<_FailedDemo> createState() => _FailedDemoState();
}

class _FailedDemoState extends State<_FailedDemo> {
  String _status = 'failed'; // tap retry -> sent (like the real resend)

  @override
  Widget build(BuildContext context) {
    final bn = widget.bn;
    final at = DateTime(2026, 10, 25, 18, 2);
    return Scaffold(
      appBar: AppBar(title: Text(bn ? 'আবুল কাশেম' : 'Abul Kashem')),
      body: ListView(children: [
        CircleBubble(
            msg: CircleMessage(
                id: 'a', text: bn ? 'নতুন মাল এসেছে' : 'New stock arrived',
                mine: false, at: at)),
        CircleBubble(
            msg: CircleMessage(
                id: 'f1', text: bn ? 'দাম কত হবে?' : 'What will the price be?',
                mine: true, at: at, status: _status),
            onRetry: () => setState(() => _status = 'sent')),
      ]),
    );
  }
}

Widget _ended(String l) {
  final c = previewController(
      video: false,
      outgoing: true,
      phase: CallPhase.ended,
      reason: CallEndReason.hangup);
  c.connectedAt = DateTime(2026, 10, 22, 10, 0, 0);
  c.endedAt = DateTime(2026, 10, 22, 10, 4, 7);
  return CircleCallScreen(
    member: {'id': 1, 'name': l == 'bn' ? 'নাদিয়া' : 'Nadia'},
    kind: 'voice',
    outgoing: true,
    controller: c,
  );
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> waPolishShots = {
  'wa_chat_jump_latest': (l) => _ChatDemo(bn: l == 'bn'),
  'wa_chat_failed_retry': (l) => _FailedDemo(bn: l == 'bn'),
  'wa_call_ended_summary': _ended,
};
