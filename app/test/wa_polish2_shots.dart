// wa-polish2 gallery states for test/screenshots_test.dart: WhatsApp bubble
// grouping, the composer mic + "slide to cancel" recording strip, voice
// notes (stand-in waveform, unplayed dot) and Call info.
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/voice_hold_mic.dart';
import 'package:assisto/screens/circle_call_info_screen.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/circle_bubble.dart';

String _n(bool bn, String en, String b) => bn ? b : en;

MediaDescriptor _voice(String ref, int ms, {List<int> wave = const []}) => MediaDescriptor(
    kind: 'voice',
    ref: ref,
    key: Uint8List(32),
    nonce: Uint8List(12),
    sha256: 'a' * 64,
    size: 52000,
    plainSize: 52000,
    mime: 'audio/mp4',
    name: 'voice.m4a',
    durationMs: ms,
    wave: wave);

class _Grouped extends StatefulWidget {
  const _Grouped({required this.bn, this.recording = false});
  final bool bn;
  final bool recording;
  @override
  State<_Grouped> createState() => _GroupedState();
}

class _GroupedState extends State<_Grouped> {
  final _hold = VoiceHoldController();
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.recording) {
      _hold.debugShow(elapsed: const Duration(seconds: 7), dragDx: -30);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bn = widget.bn;
    final t0 = DateTime(2026, 10, 25, 20, 1);
    final rows = <(CircleMessage, bool)>[
      (CircleMessage(id: '1', text: _n(bn, 'Are you home?', 'বাসায় আছো?'), mine: false, at: t0), false),
      (CircleMessage(id: '2', text: _n(bn, 'Mother is asking', 'আম্মা জিজ্ঞেস করছেন'), mine: false, at: t0), true),
      (CircleMessage(id: '3', text: _n(bn, 'Bring medicine on the way', 'আসার পথে ওষুধ নিয়ে এসো'), mine: false, at: t0), true),
      (CircleMessage(id: '4', text: _n(bn, 'Yes, coming in 10 minutes', 'হ্যাঁ, ১০ মিনিটে আসছি'), mine: true, at: t0, status: 'read'), false),
      (CircleMessage(id: '5', text: _n(bn, 'Which medicine?', 'কোন ওষুধ?'), mine: true, at: t0, status: 'read'), true),
      (CircleMessage(id: '6', text: '', mine: false, at: t0, contentType: 'voice', media: _voice('wa2-v1', 14000)), false),
      (CircleMessage(id: '7', text: '', mine: false, at: t0, contentType: 'voice',
          media: _voice('wa2-v2', 6000, wave: const [3, 8, 14, 22, 30, 24, 12, 6, 10, 18, 26, 20, 9, 4])), true),
    ];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(_n(bn, 'Nadia', 'নাদিয়া'))),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            children: [
              for (final r in rows) CircleBubble(msg: r.$1, continued: r.$2, onLongPress: () {}),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.sm),
            child: Row(children: [
              if (!widget.recording)
                IconButton(
                    onPressed: () {},
                    tooltip: _n(bn, 'Attach', 'সংযুক্ত'),
                    icon: const Icon(Icons.add_circle_outline_rounded))
              else
                const SizedBox(width: Gap.sm),
              Expanded(
                child: Stack(children: [
                  TextField(
                      controller: _input,
                      decoration: InputDecoration(hintText: _n(bn, 'Message', 'মেসেজ'))),
                  ListenableBuilder(
                    listenable: _hold,
                    builder: (_, __) => _hold.active
                        ? Positioned.fill(child: VoiceHoldStrip(controller: _hold))
                        : const SizedBox.shrink(),
                  ),
                ]),
              ),
              if (!widget.recording)
                IconButton(
                    onPressed: () {},
                    tooltip: 'Assisto',
                    icon: Icon(Icons.auto_awesome_rounded, color: scheme.onSurfaceVariant))
              else
                const SizedBox(width: Gap.xs),
              VoiceHoldMic(
                  controller: _hold,
                  onTap: () => ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('recorder'))),
                  onDraft: (_) async {}),
            ]),
          ),
        ),
      ]),
    );
  }
}

Widget _callInfo(String l) {
  final bn = l == 'bn';
  final now = DateTime.now().toUtc();
  final rows = <Map<String, dynamic>>[
    {'id': 31, 'kind': 'video', 'state': 'missed', 'outgoing': false,
     'name': _n(bn, 'Nadia', 'নাদিয়া'), 'relation': 'sister', 'member_id': 71,
     'outcome': _n(bn, 'Missed call', 'মিসড কল'),
     'started_at': now.subtract(const Duration(minutes: 12)).toIso8601String()},
    {'id': 30, 'kind': 'voice', 'state': 'ended', 'outgoing': true,
     'name': _n(bn, 'Nadia', 'নাদিয়া'), 'member_id': 71, 'duration_sec': 247,
     'started_at': now.subtract(const Duration(minutes: 40)).toIso8601String()},
    {'id': 29, 'kind': 'voice', 'state': 'ended', 'outgoing': false,
     'name': _n(bn, 'Nadia', 'নাদিয়া'), 'member_id': 71, 'duration_sec': 65,
     'started_at': now.subtract(const Duration(hours: 2)).toIso8601String()},
  ];
  // gallery demo: actions give visible feedback (dead-button sweep)
  return Builder(
      builder: (ctx) => CircleCallInfoScreen(
          call: rows.first,
          entries: rows,
          onCall: (kind) => ScaffoldMessenger.of(ctx)
              .showSnackBar(SnackBar(content: Text('call:$kind'))),
          onMessage: () => ScaffoldMessenger.of(ctx)
              .showSnackBar(const SnackBar(content: Text('message')))));
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> waPolish2Shots = {
  'wa2_chat_grouped': (l) => _Grouped(bn: l == 'bn'),
  'wa2_chat_recording': (l) => _Grouped(bn: l == 'bn', recording: true),
  'wa2_call_info': _callInfo,
};
