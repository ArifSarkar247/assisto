// callsbar gallery states for test/screenshots_test.dart: a video call on a
// weak network (low-data chip, my video paused, their video paused), the
// call-ended summary with data used + the one-tap rating, the honest group
// call sheet and the low-data setting.
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_data_prefs.dart';
import 'package:assisto/calls/group_call_sheet.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';

String _n(String l) => l == 'bn' ? 'নাদিয়া' : 'Nadia';

Widget _weak(String l) {
  final c = previewController(
      video: true, outgoing: true, phase: CallPhase.connected,
      quality: CallQuality.poor);
  c.lowData = true;
  c.netPolicy.videoPaused = true;
  c.remoteVideoPausedNet = true;
  return CircleCallScreen(
      member: {'id': 1, 'name': _n(l)},
      kind: 'video',
      controller: c,
      surface: FakeSurface());
}

Widget _endedRate(String l) {
  final c = previewController(
      video: false,
      outgoing: true,
      phase: CallPhase.ended,
      reason: CallEndReason.hangup);
  c.connectedAt = DateTime(2026, 11, 2, 10, 0, 0);
  c.endedAt = DateTime(2026, 11, 2, 10, 4, 7);
  c.dataBytes = (1.4 * 1024 * 1024).round();
  return CircleCallScreen(
      member: {'id': 1, 'name': _n(l)},
      kind: 'voice',
      controller: c,
      previewAskRating: true);
}

Widget _group(String l) => Scaffold(
      body: GroupCallSheet(
        groupName: l == 'bn' ? 'পরিবার' : 'Family',
        members: [
          {'user_id': 1, 'name': 'Me', 'is_self': true},
          {'user_id': 2, 'name': _n(l), 'circle_member_id': 21},
          {'user_id': 3, 'name': l == 'bn' ? 'বাবু' : 'Babu',
            'circle_member_id': 22},
          {'user_id': 4, 'name': l == 'bn' ? 'ছায়া' : 'Chaya',
            'circle_member_id': null},
        ],
        onCall: (_, __) {},
      ),
    );

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> callsbarShots = {
  'cbar_call_weak_net': _weak,
  'cbar_call_ended_rating': _endedRate,
  'cbar_group_call_sheet': _group,
  'cbar_set_low_data': (l) => const Scaffold(body: SafeArea(child: CallLowDataTile())),
};
