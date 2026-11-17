// gap-cctv: gallery shots of the screens this lane added (bn + en, light +
// dark come from screenshots_test.dart). Made-up sample data only.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/cctv_clips_screen.dart';
import 'package:assisto/screens/watchman/cctv_playback_screen.dart';
import 'package:assisto/screens/watchman/old_phone_hub.dart';

/// A fixed hour on today / yesterday (local), so "Today" / "Yesterday" never
/// flip near midnight.
String _at(int daysBack, int hour) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysBack, hour).toUtc().toIso8601String();
}

class GapFakeClips implements CctvClipsSource {
  final bool empty;
  final bool fail;
  final List<int?> asked = [];
  GapFakeClips({this.empty = false, this.fail = false});

  @override
  Future<Map<String, dynamic>> clips(int siteId, {int? cameraId}) async {
    asked.add(cameraId);
    if (fail) throw StateError('offline');
    final all = empty
        ? <Map<String, dynamic>>[]
        : [
            {'id': 501, 'camera': 11, 'camera_name': 'Front door', 'created': _at(0, 10),
             'snapshot_url': '', 'clip': {'status': 'ready'}},
            {'id': 502, 'camera': 12, 'camera_name': 'Cash counter', 'created': _at(0, 9),
             'snapshot_url': '', 'clip': {'status': 'ready'}},
            {'id': 503, 'camera': 11, 'camera_name': 'Front door', 'created': _at(1, 18),
             'snapshot_url': '', 'clip': {'status': 'ready'}},
          ];
    return {
      'site': siteId,
      'role': 'owner',
      'clips': [for (final c in all) if (cameraId == null || c['camera'] == cameraId) c],
      'cameras': [
        {'id': 11, 'name': 'Front door', 'keep_days': 1, 'cloud_playback': true},
        {'id': 12, 'name': 'Cash counter', 'keep_days': 30, 'cloud_playback': false},
      ],
      'default_hours': 24,
      'premium_days': 30,
      'upsell': true,
    };
  }
}

/// gap-cctv3: a fixed "now" (17 Nov 2026 14:30 local) for the timeline.
DateTime gapNow() => DateTime(2026, 11, 17, 14, 30);

/// gap-cctv3: the Imou playback answer, like the real cloud (made-up host).
class GapFakePlayback implements CctvPlaybackSource {
  final Object? fail;
  final bool sdkOnly;
  final List<(int, int, int)> asked = [];
  GapFakePlayback({this.fail, this.sdkOnly = false});

  @override
  Future<Map<String, dynamic>> playback(int cameraId, int startEpoch, int endEpoch) async {
    asked.add((cameraId, startEpoch, endEpoch));
    final f = fail;
    if (f != null) throw f;
    final d = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000);
    String at(int m) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:00';
    final recs = [
      {'begin': at(5), 'end': at(20)},
      {'begin': at(41), 'end': at(52)},
    ];
    if (sdkOnly) return {'url': '', 'proto': 'sdk_only', 'expires_s': 0, 'records': recs};
    return {'url': 'https://cmgw-sample.example/record/playback.m3u8', 'proto': 'hls',
            'expires_s': 600, 'source': 'sd', 'records': recs, 'camera_id': cameraId};
  }
}

final Map<String, Widget Function(String)> gapCctvShots = {
  'gcv_playback': (_) => CctvPlaybackScreen(
      cameraId: 11, cameraName: 'Front door', source: GapFakePlayback(), clock: gapNow),
  'gcv_past_clips': (_) => CctvClipsScreen(
      source: GapFakeClips(), siteId: 1, siteName: 'Mirpur shop', owner: true),
  'gcv_past_clips_empty': (_) =>
      CctvClipsScreen(source: GapFakeClips(empty: true), siteId: 1, owner: true),
  'gcv_old_phone_hub': (_) =>
      const Scaffold(body: OldPhoneHubSheet(siteId: 1, guardBoxOn: true)),
};
