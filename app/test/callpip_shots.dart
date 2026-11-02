// callpip gallery states for test/screenshots_test.dart (owner bug 2 Nov:
// video disappeared on Back / Home / another app):
//  * the Android PiP window over ANOTHER app — a layout SIMULATION (the real
//    window is drawn by Android; its three buttons are native RemoteActions):
//    their video large, my camera small, mute / camera / end;
//  * PiP while their camera is paused (they left their app): avatar, never a
//    frozen frame;
//  * the full call screen saying "<name> left the app for a moment";
//  * inside Assisto: the draggable mini video tile and the green bar (voice).
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_mini_bar.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';
import 'calls_a_shots.dart' show CallsADemo;

Map<String, dynamic> _m(String l) =>
    {'id': 1, 'name': l == 'bn' ? 'নাদিয়া' : 'Nadia', 'relation': 'friend'};

/// Another app (a neutral feed) with Assisto's PiP window in the corner.
class PipSimulation extends StatelessWidget {
  const PipSimulation(
      {super.key, required this.lang, this.away = false, this.controls = true});
  final String lang;
  final bool away;
  final bool controls;

  @override
  Widget build(BuildContext context) {
    final bn = lang == 'bn';
    final c = previewController(
        video: true,
        outgoing: true,
        phase: CallPhase.connected,
        remoteCamera: !away);
    c.remoteAway = away;
    final name = '${_m(lang)['name']}';
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      bn
                          ? 'অন্য অ্যাপ (যেমন Facebook) — PiP নমুনা ছবি'
                          : 'Another app (e.g. Facebook) — PiP simulation',
                      style: const TextStyle(
                          color: Color(0xFF3A3B3C),
                          fontWeight: FontWeight.w600)),
                ),
                for (var i = 0; i < 5; i++)
                  Container(
                    height: 120,
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8)),
                  ),
              ],
            ),
            Positioned(
              right: 12,
              bottom: 24,
              width: 150,
              height: 267, // 9:16
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CallPipLayout(
                        controller: c, surface: FakeSurface(), name: name),
                    if (controls)
                      // what Android draws when the window is tapped: the
                      // three RemoteActions (mute / camera / end)
                      ColoredBox(
                        color: const Color(0x66000000),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: const [
                                Icon(Icons.mic_rounded,
                                    color: Colors.white, size: 26),
                                Icon(Icons.videocam_rounded,
                                    color: Colors.white, size: 26),
                                Icon(Icons.call_end_rounded,
                                    color: Colors.white, size: 26),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _peerAway(String l) {
  final c = previewController(
      video: true,
      outgoing: true,
      phase: CallPhase.connected,
      remoteCamera: false);
  c.remoteAway = true;
  return CircleCallScreen(
      member: _m(l), kind: 'video', controller: c, surface: FakeSurface());
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> callpipShots = {
  'callpip_pip_window': (l) => PipSimulation(lang: l),
  'callpip_pip_window_plain': (l) => PipSimulation(lang: l, controls: false),
  'callpip_pip_peer_away': (l) =>
      PipSimulation(lang: l, away: true, controls: false),
  'callpip_call_peer_away': _peerAway,
  'callpip_pip_off_hint': (l) => CircleCallScreen(
      member: _m(l),
      kind: 'video',
      controller: previewController(
          video: true, outgoing: true, phase: CallPhase.connected),
      surface: FakeSurface(),
      previewPipOff: true),
  'callpip_mini_tile_video': (l) => CallsADemo(lang: l),
  'callpip_call_bar_voice': (l) => CallsADemo(lang: l, video: false),
};
