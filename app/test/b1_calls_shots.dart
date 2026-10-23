// b1-calls gallery states for test/screenshots_test.dart: voice <-> video
// switch (request / prompt / switching), mic + camera badges, quality text,
// honest notices, the audio route, and the in-app minimized-call bar.
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_mini_bar.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';

Map<String, dynamic> _m(String l) =>
    {'id': 1, 'name': l == 'bn' ? 'নাদিয়া' : 'Nadia', 'relation': 'friend'};

Widget _call(
  String l, {
  bool video = false,
  bool videoNow = false,
  CallPhase p = CallPhase.connected,
  CallQuality q = CallQuality.good,
  bool remoteMic = true,
  bool remoteCamera = true,
  bool cameraOn = true,
  bool muted = false,
  VideoUpgrade upgrade = VideoUpgrade.none,
  CallNotice notice = CallNotice.none,
  AudioRoute? route,
}) {
  final c = previewController(
      video: video,
      outgoing: true,
      phase: p,
      quality: q,
      muted: muted,
      remoteCamera: remoteCamera,
      remoteMic: remoteMic,
      videoNow: videoNow,
      cameraOn: cameraOn,
      upgrade: upgrade,
      notice: notice,
      route: route);
  return CircleCallScreen(
    member: _m(l),
    kind: video ? 'video' : 'voice',
    controller: c,
    surface: (video || videoNow) ? FakeSurface() : null,
  );
}

/// The mini bar over a stand-in app screen (sets / clears the runtime's
/// minimized call around its own lifetime).
class B1MiniBarDemo extends StatefulWidget {
  const B1MiniBarDemo({super.key, required this.lang});
  final String lang;
  @override
  State<B1MiniBarDemo> createState() => _B1MiniBarDemoState();
}

class _B1MiniBarDemoState extends State<B1MiniBarDemo> {
  late final CallController c;

  @override
  void initState() {
    super.initState();
    c = previewController(
        video: false, outgoing: true, phase: CallPhase.connected);
    CallRuntime.instance.ongoing.value =
        OngoingCall(controller: c, member: _m(widget.lang), kind: 'voice');
  }

  @override
  void dispose() {
    CallRuntime.instance.ongoing.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallMiniBarHost(
        child: Scaffold(
          appBar: AppBar(title: Text(widget.lang == 'bn' ? 'আমার সার্কেল' : 'My Circle')),
          body: ListView(
            children: [
              for (final n in widget.lang == 'bn'
                  ? ['আম্মু', 'রাফি', 'নাদিয়া']
                  : ['Mom', 'Rafi', 'Nadia'])
                ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person)),
                    title: Text(n)),
            ],
          ),
        ),
      );
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> b1Shots = {
  'b1_call_voice_controls': (l) => _call(l),
  'b1_call_video_prompt': (l) =>
      _call(l, upgrade: VideoUpgrade.incoming),
  'b1_call_video_waiting': (l) =>
      _call(l, upgrade: VideoUpgrade.requesting),
  'b1_call_video_switching': (l) =>
      _call(l, upgrade: VideoUpgrade.switching),
  'b1_call_video_upgraded': (l) => _call(l, videoNow: true),
  'b1_call_video_remote_muted_cam_off': (l) => _call(l,
      video: true, remoteMic: false, remoteCamera: false),
  'b1_call_video_self_cam_off': (l) =>
      _call(l, video: true, cameraOn: false, muted: true),
  'b1_call_notice_declined': (l) =>
      _call(l, notice: CallNotice.videoDeclined),
  'b1_call_notice_premium': (l) => _call(l, notice: CallNotice.videoPremium),
  'b1_call_notice_camera': (l) =>
      _call(l, video: true, cameraOn: false, notice: CallNotice.cameraBlocked),
  'b1_call_quality_poor': (l) => _call(l, q: CallQuality.poor),
  'b1_call_route_bluetooth': (l) => _call(l, route: AudioRoute.bluetooth),
  'b1_call_reconnecting': (l) =>
      _call(l, p: CallPhase.reconnecting, q: CallQuality.poor),
  'b1_call_mini_bar': (l) => B1MiniBarDemo(lang: l),
};
