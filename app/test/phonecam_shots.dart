// cctvphone: gallery states for test/screenshots_test.dart — an old phone
// as an Assisto camera (camera-phone screens + the owner's pairing sheet).
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:assisto/phonecam/phone_camera_screen.dart';
import 'package:assisto/phonecam/phonecam_pair_sheet.dart';
import 'package:assisto/crypto/e2e.dart' show IdentityKeyPair;
import 'package:assisto/phonecam/phonecam_clips.dart' show PhoneCamClipSource;
import 'package:assisto/phonecam/phonecam_full_video.dart';
import 'package:assisto/phonecam/phonecam_timeline_screen.dart';
import 'package:assisto/screens/watchman/cash_guard_clip.dart';

import 'package:assisto/screens/watchman/watchman_screen.dart' show PhoneCamHealthPill;

import 'cashguard_fakes.dart' show FakeCashGuard;

String _cam(String lang) => lang == 'bn' ? 'সামনের দরজা' : 'Front door';
String _site(String lang) => lang == 'bn' ? 'আমাদের বাসা' : 'Our home';

Future<Map<String, dynamic>> pcFakePair() async => {
      'code': '12-HK7P4Q',
      'link': 'https://lifeassisto.com/pc/12-HK7P4Q',
      'valid_s': 742,
      'included': 2,
      'used': 1,
      'extra_needs_credits': false,
      'extra_camera_credits': 250,
      'cameras': const [],
    };

final Map<String, Widget Function(String)> phonecamShots = {
  'pc_pair_code': (_) => const PhoneCameraScreen(preview: PhoneCamPreview(paired: false)),
  'pc_ready': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(camera: _cam(l), site: _site(l), clips: 4, clipMb: 38)),
  'pc_running': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(
          running: true, camera: _cam(l), site: _site(l), alerts: 3, clips: 4, clipMb: 38)),
  'pc_running_warn': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(
          running: true,
          camera: _cam(l),
          site: _site(l),
          model: false,
          audio: true,
          warnings: const ['unplugged', 'hot'])),
  'pc_pair_sheet': (_) => const Scaffold(body: PhoneCamPairSheet(load: pcFakePair)),
  // gap-cctv: the Raspberry Pi / Linux Guard Box steps, open
  'gcv_linux_steps': (_) => const Scaffold(
      body: SingleChildScrollView(
          padding: EdgeInsets.all(16), child: GuardBoxLinuxSteps(initiallyExpanded: true))),
  'pc_health_pills': (_) => const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PhoneCamHealthPill(health: {'level': 86, 'charging': true, 'temp_c': 33.0}),
            SizedBox(height: 8),
            PhoneCamHealthPill(health: {'level': 41, 'charging': false, 'temp_c': 47.5}),
            SizedBox(height: 8),
            PhoneCamHealthPill(health: {'level': 90, 'charging': true, 'dark': true}),
          ]),
        ),
      ),
  // cctvplay: remote playback of the phone camera's alert clips
  'pcp_full_idle': (_) => _pcpPanel(_pcpState('none')),
  'pcp_full_offline': (_) => _pcpPanel(_pcpState('none', online: false)),
  'pcp_full_missing': (_) => _pcpPanel(_pcpState('missing')),
  'pcp_full_ready': (_) => _pcpPanel(_pcpState('ready')),
  'pcr_timeline': (_) => PhoneCamTimelineScreen(
      cameraId: 3, cameraName: 'Front door', source: _PcrSrc(on: true), now: _pcrNow),
  'pcr_timeline_off': (_) =>
      PhoneCamTimelineScreen(cameraId: 3, cameraName: '', source: _PcrSrc(on: false), now: _pcrNow),
  'pcr_camera_recording': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(
          running: true, camera: _cam(l), site: _site(l), alerts: 2, clips: 3, clipMb: 4, rec: 'recording')),
  'pcr_camera_setup': (l) => PhoneCameraScreen(
      preview: PhoneCamPreview(camera: _cam(l), site: _site(l), clips: 3, clipMb: 4, rec: 'hot')),
  'pcp_sheet_nopreview': (_) => Scaffold(
      body: CashClipSheet(
          source: FakeCashGuard(),
          eventId: 1,
          owner: false,
          phoneSource: _PcpSrc(_pcpState('none')),
          previewStatus: 'none')),
};

// cctvplay
Map<String, dynamic> _pcpState(String status, {bool online = true}) => {
      'status': status,
      'camera_online': online,
      'clip_s': 10,
      'keep_h': 24,
      'est_mb': 1.5,
      'budget': {'cap_mb': 300, 'used_mb': 120.0, 'left_mb': 180.0, 'enforced': false, 'paused': false},
    };

Widget _pcpPanel(Map<String, dynamic> s) => Scaffold(
    body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: PhoneCamFullVideo(source: _PcpSrc(s), eventId: 1, initial: s)));

class _PcpSrc implements PhoneCamClipSource {
  final Map<String, dynamic> s;
  _PcpSrc(this.s);
  @override
  Future<Map<String, dynamic>> fullState(int eventId) async => s;
  @override
  Future<Map<String, dynamic>> requestFull(int eventId) async => {...s, 'status': 'requested'};
  @override
  Future<Uint8List> download(String url) async => Uint8List(0);
  @override
  Future<List<IdentityKeyPair>> myKeys() async => const [];
}

final DateTime _pcrNow = DateTime(2026, 11, 9, 15, 40);

class _PcrSrc implements PhoneCamRecSource {
  final bool on;
  _PcrSrc({required this.on});
  @override
  Future<Map<String, dynamic>> recording(int cameraId) async {
    final hs = _pcrNow.millisecondsSinceEpoch ~/ 1000 ~/ 3600 * 3600;
    return {
      'camera_id': cameraId,
      'can_change': true,
      'settings': {'on': on, 'cap_mb': 2000},
      'cap_choices_mb': [1000, 2000, 4000, 8000],
      'timeline': on
          ? {
              'spans': [
                [hs - 3 * 3600, hs - 2 * 3600 + 900],
                [hs - 3600 + 300, hs + 2340]
              ],
              'alerts': [hs - 3 * 3600 + 1200, hs - 1800, hs + 600],
              'used_mb': 412,
              'cap_mb': 2000,
              'state': 'recording',
              'reason': ''
            }
          : {'spans': [], 'alerts': [], 'state': 'off', 'reason': ''},
      'camera_online': true,
      'segment_s': 60,
      'est_mb': 5.0,
      'keep_h': 720,
      'budget': {'cap_mb': 600, 'left_mb': 455.0, 'used_mb': 145.0, 'paused': false},
      'views': {},
    };
  }

  @override
  Future<Map<String, dynamic>> setRecording(int cameraId, Map<String, dynamic> body) => recording(cameraId);
  @override
  Future<Map<String, dynamic>> clipState(int cameraId, String key) async => {'status': 'none'};
  @override
  Future<Map<String, dynamic>> requestClip(int cameraId, int t) async => {'status': 'requested'};
  @override
  Future<Uint8List> download(String url) async => Uint8List(0);
  @override
  Future<List<IdentityKeyPair>> myKeys() async => const [];
}
