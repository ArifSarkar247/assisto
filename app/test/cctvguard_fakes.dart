// cctvguard: fakes for the cost-guard widgets (usage card, vendor live).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:assisto/api.dart';
import 'package:assisto/cctvguard/vendor_live_screen.dart';
import 'package:assisto/messaging/media/video_ctl.dart';

Map<String, dynamic> cgUsage({bool enforced = true, String level = 'notice', String lang = 'en'}) => {
      'month': '2026-11',
      'cameras': [
        {'camera': 11, 'name': lang == 'bn' ? 'সামনের দরজা' : 'Front door', 'live_min': 42,
         'relay_min': 9, 'relay_mb': 410.5, 'direct_mb': 1280.0, 'vendor_min': 0, 'vendor_est_mb': 0.0},
        {'camera': 12, 'name': lang == 'bn' ? 'ক্যাশ কাউন্টার' : 'Cash counter', 'live_min': 15,
         'relay_min': 0, 'relay_mb': 0.0, 'direct_mb': 0.0, 'vendor_min': 15, 'vendor_est_mb': 57.6},
      ],
      'relay_used_mb': 482.4,
      'relay_cap_mb': 600,
      'relay_pct': 80,
      'level': enforced ? level : 'off',
      'enforced': enforced,
      'per_camera_mb': 300,
      'message': enforced && level == 'notice'
          ? (lang == 'bn'
              ? 'এই ক্যামেরার রিলে-লাইভ সীমার ৮০% এই মাসে ব্যবহার হয়েছে। একই Wi-Fi-তে বা সরাসরি সংযোগে দেখলে সীমা খরচ হয় না।'
              : "80% of this camera's relay live allowance is used this month. Watching on the same Wi-Fi or a direct connection does not use it.")
          : '',
      'turn_measured_mb': 401.0,
      'vendor_is_estimate': true,
    };

class FakeVendorLive implements VendorLiveApi {
  final List<String> calls = [];
  ApiException? failWith;

  @override
  Future<Map<String, dynamic>> start(int cameraId, {required bool hd}) async {
    calls.add('start:$cameraId:${hd ? 'hd' : 'sd'}');
    final f = failWith;
    if (f != null) throw f;
    return {
      'id': 'v${calls.length}', 'url': 'https://x.easy4ipcloud.com/live.m3u8', 'hd': hd,
      'vendor': 'imou', 'idle_seconds': 300, 'max_seconds': 1800, 'kbps': hd ? 2048 : 512,
      'level': 'off', 'pct': 0, 'message': '', 'estimate': true,
    };
  }

  @override
  Future<Map<String, dynamic>> touch(int cameraId, String id) async {
    calls.add('touch:$id');
    return {'ok': true, 'left': 300};
  }

  @override
  Future<Map<String, dynamic>> end(int cameraId, String id, int seconds) async {
    calls.add('end:$id:$seconds');
    return {'ok': true, 'seconds': seconds, 'estimate': true};
  }
}

/// A player that "plays" at once (no plugin); its picture is a plain dark
/// panel with a camera icon — the gallery never shows invented footage.
class FakeNetCtl implements VideoCtl {
  final ValueNotifier<VideoCtlState> _s = ValueNotifier(const VideoCtlState());
  bool muted = false;
  bool disposed = false;
  final String fail;
  FakeNetCtl({this.fail = ''});

  @override
  ValueListenable<VideoCtlState> get state => _s;
  @override
  Future<void> init() async => _s.value = VideoCtlState(
      initialized: true, size: const Size(1280, 720), error: fail);
  @override
  Future<void> play() async => _s.value = _s.value.copyWith(playing: true);
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration d) async {}
  @override
  Future<void> setMuted(bool m) async => muted = m;
  @override
  Widget view() => Container(
        color: const Color(0xFF1E2A33),
        alignment: Alignment.center,
        child: const Icon(Icons.videocam_rounded, color: Colors.white54, size: 56),
      );
  @override
  Future<void> dispose() async => disposed = true;
}
