// calls-a gallery states for test/screenshots_test.dart: "use Assisto during
// a call" — the green return-to-call bar over a My Circle chat, and a
// minimized VIDEO call's floating window (remote video / camera off).
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_mini_bar.dart';
import 'package:assisto/calls/call_runtime.dart';

import 'c2_calls_fakes.dart';

Map<String, dynamic> _m(String l) =>
    {'id': 1, 'name': l == 'bn' ? 'নাদিয়া' : 'Nadia', 'relation': 'friend'};

/// A stand-in My Circle chat (Rahim's phone) with a minimized call on top.
class CallsADemo extends StatefulWidget {
  const CallsADemo(
      {super.key, required this.lang, this.video = true, this.remoteCam = true});
  final String lang;
  final bool video;
  final bool remoteCam;
  @override
  State<CallsADemo> createState() => _CallsADemoState();
}

class _CallsADemoState extends State<CallsADemo> {
  late final CallController c;

  @override
  void initState() {
    super.initState();
    c = previewController(
        video: widget.video,
        outgoing: false,
        phase: CallPhase.connected,
        remoteCamera: widget.remoteCam);
    CallRuntime.instance.ongoing.value = OngoingCall(
        controller: c,
        surface: widget.video ? FakeSurface() : null,
        member: _m(widget.lang),
        kind: widget.video ? 'video' : 'voice');
  }

  @override
  void dispose() {
    CallRuntime.instance.ongoing.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bn = widget.lang == 'bn';
    final msgs = bn
        ? ['আজ বিকেলে দেখা হবে?', 'হ্যাঁ, ৫টায়', 'কলে আছি, পরে লিখছি']
        : ['See you this evening?', 'Yes, at 5', 'On a call, will text later'];
    return CallMiniBarHost(
      child: Scaffold(
        appBar: AppBar(title: Text(bn ? 'নাদিয়া' : 'Nadia')),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (var i = 0; i < msgs.length; i++)
                    Align(
                      alignment:
                          i.isOdd ? Alignment.centerRight : Alignment.centerLeft,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(msgs[i]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: bn ? 'মেসেজ লিখুন' : 'Message',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> callsAShots = {
  'callsa_bar_voice_chat': (l) => CallsADemo(lang: l, video: false),
  'callsa_float_video_chat': (l) => CallsADemo(lang: l),
  'callsa_float_video_cam_off': (l) => CallsADemo(lang: l, remoteCam: false),
};
