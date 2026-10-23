// b3-group gallery states for test/screenshots_test.dart: group call grid
// (voice / video, active speaker, ringing invitee), speaker view, screen
// share banner, consented recording (asked / waiting / recording / paused),
// honest end + rejoin, the group ring, the 1:1 call's new "More" options and
// recording prompt, and the encrypted recordings list.
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_recording.dart';
import 'package:assisto/calls/group_call.dart';
import 'package:assisto/push/group_incoming_screen.dart';
import 'package:assisto/screens/call_recordings_screen.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/group_call_screen.dart';

import 'b3_group_fakes.dart';
import 'c2_calls_fakes.dart';

List<String> _names(String l) => l == 'bn'
    ? const ['নাদিয়া', 'রাফি', 'মিতু', 'সুমন', 'লিমা', 'তানভীর', 'রুমা', 'জামাল']
    : const ['Nadia', 'Rafi', 'Mitu', 'Sumon', 'Lima', 'Tanvir', 'Ruma', 'Jamal'];

Map<String, dynamic> _rec(String status,
        {bool must = false, bool mine = false, int requester = 2}) =>
    {
      'id': 1,
      'status': status,
      'requester': mine ? 1 : requester,
      'accepted': [requester],
      'i_must_answer': must,
      'i_record': mine && status == 'recording',
    };

Widget _group(String l,
    {bool video = false,
    int people = 4,
    bool speakerView = false,
    bool sharing = false,
    Map<String, dynamic>? recording,
    bool host = true}) {
  final c = previewGroup(
      host: host,
      video: video,
      people: people,
      speakerView: speakerView,
      sharing: sharing,
      speaking: '2',
      recording: recording,
      names: _names(l),
      selfName: l == 'bn' ? 'আরিফ' : 'Arif');
  if (l == 'bn') c.groupName = 'পরিবার';
  return GroupCallScreen(controller: c);
}

Widget _ended(String l, GroupEndReason r) {
  final c = previewGroup(names: _names(l), selfName: l == 'bn' ? 'আরিফ' : 'Arif');
  if (l == 'bn') c.groupName = 'পরিবার';
  c.phase = GroupPhase.ended;
  c.endReason = r;
  return GroupCallScreen(controller: c);
}

Widget _oneToOne(String l,
    {bool sharing = false, bool remoteScreen = false, Map<String, dynamic>? rec}) {
  final c = previewController(
      video: false, outgoing: true, phase: CallPhase.connected);
  c.screenShareAvailable = true;
  c.screenSharing = sharing;
  c.remoteScreen = remoteScreen;
  final s = RecordingSession(send: (a) async => {}, engine: FakeRecorder());
  if (rec != null) s.consent = RecordingConsent.fromJson(rec);
  c.recording = s;
  return CircleCallScreen(
    member: {'id': 1, 'name': l == 'bn' ? 'নাদিয়া' : 'Nadia'},
    kind: 'voice',
    controller: c,
    surface: remoteScreen ? FakeSurface() : null,
  );
}

Widget _recordings(String l) {
  final v = MemoryVault();
  v.items = [
    SavedRecording(
        id: 'r1',
        title: l == 'bn' ? 'পরিবার' : 'Family',
        at: DateTime(2026, 10, 23, 20, 15),
        seconds: 754,
        people: _names(l).take(3).toList(),
        parts: const ['r1.0.enc', 'r1.1.enc']),
    SavedRecording(
        id: 'r2',
        title: l == 'bn' ? 'নাদিয়া' : 'Nadia',
        at: DateTime(2026, 10, 21, 9, 2),
        seconds: 95,
        people: [_names(l).first],
        parts: const ['r2.0.enc']),
  ];
  return CallRecordingsScreen(vault: v);
}

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> b3Shots = {
  'b3_group_voice_grid': (l) => _group(l),
  'b3_group_video_grid_3x3': (l) => _group(l, video: true, people: 7),
  'b3_group_speaker_view': (l) =>
      _group(l, video: true, people: 5, speakerView: true),
  'b3_group_member_view': (l) => _group(l, host: false, people: 3),
  'b3_group_screen_share': (l) => _group(l, video: true, sharing: true),
  'b3_group_record_ask': (l) =>
      _group(l, recording: _rec('pending', must: true)),
  'b3_group_record_waiting': (l) =>
      _group(l, recording: _rec('pending', mine: true)),
  'b3_group_recording_mine': (l) =>
      _group(l, recording: _rec('recording', mine: true)),
  'b3_group_recording_other': (l) =>
      _group(l, recording: _rec('recording')),
  'b3_group_recording_paused': (l) =>
      _group(l, people: 5, recording: _rec('paused', must: true)),
  'b3_group_ended_unavailable': (l) =>
      _ended(l, GroupEndReason.unavailable),
  'b3_group_ended_removed': (l) => _ended(l, GroupEndReason.removed),
  'b3_group_incoming': (l) => GroupIncomingScreen(ring: false, row: {
        'room': 'gc-1',
        'kind': 'video',
        'host_name': _names(l).first,
        'group_name': l == 'bn' ? 'পরিবার' : 'Family',
      }),
  'b3_call_sharing_screen': (l) => _oneToOne(l, sharing: true),
  'b3_call_remote_screen': (l) => _oneToOne(l, remoteScreen: true),
  'b3_call_record_ask': (l) => _oneToOne(l, rec: _rec('pending', must: true)),
  'b3_call_recording': (l) =>
      _oneToOne(l, rec: _rec('recording', mine: true)),
  'b3_call_recordings_list': (l) => _recordings(l),
};
