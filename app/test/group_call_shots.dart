// group-calls gallery states for test/screenshots_test.dart: an 8-person
// call (speaking border, mic off, ringing), a 4-person video call on mobile
// data, the Add person picker and the group chat's Join call bar.
import 'package:flutter/material.dart';

import 'package:assisto/calls/group_add_people_sheet.dart';
import 'package:assisto/calls/group_call_controller.dart';
import 'package:assisto/calls/group_call_join_bar.dart';
import 'package:assisto/screens/group_call_screen.dart';

import 'group_call_fakes.dart';

const _en = ['Me', 'Nadia', 'Babu', 'Chaya', 'Dipu', 'Eti', 'Fahim', 'Gita'];
const _bn = ['আমি', 'নাদিয়া', 'বাবু', 'ছায়া', 'দীপু', 'ইতি', 'ফাহিম', 'গীতা'];

Map<String, dynamic> _snap(String l, int n,
    {String kind = 'voice', int ringingFrom = 99}) {
  final names = l == 'bn' ? _bn : _en;
  return {
    'room_id': 1,
    'kind': kind,
    'live': true,
    'group_name': l == 'bn' ? 'পরিবার' : 'Family',
    'max': 8,
    'seats_taken': n,
    'free': 8 - n,
    'members': [
      for (var i = 0; i < n; i++)
        {
          'user_id': i + 1,
          'name': names[i],
          'state': i + 1 >= ringingFrom ? 'ringing' : 'joined',
          'is_me': i == 0,
          'muted': i == 2,
          'camera': kind == 'video',
        }
    ],
    'legs': const [],
  };
}

GroupCallController _ctl(Map<String, dynamic> snap, {bool mobile = false}) {
  final hub = Hub(kind: '${snap['kind']}');
  final c = GroupCallController(
      media: FakeGroupMedia(hub, 1),
      signaling: FakeGroupSignaling(hub, 1),
      roomId: 1,
      myId: 1,
      onMobileData: mobile);
  c.preview(snap);
  for (final t in c.tiles) {
    if (t.userId == 2) t.speaking = true;
    if (!t.isMe && t.inCall) t.connected = true;
  }
  return c;
}

Widget _grid8(String l) =>
    GroupCallScreen(roomId: 1, controller: _ctl(_snap(l, 8, ringingFrom: 7)));

Widget _video4(String l) => GroupCallScreen(
    roomId: 1, controller: _ctl(_snap(l, 4, kind: 'video'), mobile: true));

Widget _pick(String l) {
  final names = l == 'bn' ? _bn : _en;
  return Scaffold(
    body: GroupAddPeoplePanel(
      load: () async => [
        for (var i = 1; i < 6; i++)
          {'user_id': i + 1, 'name': names[i], 'in_call': i == 1}
      ],
      free: 6,
      onDone: (_) {},
      onClose: () {},
    ),
  );
}

Widget _joinBar(String l) => Scaffold(
      appBar: AppBar(title: Text(l == 'bn' ? 'পরিবার' : 'Family')),
      body: Builder(builder: (ctx) => Column(children: [
        GroupCallJoinBar(
          load: () async => {
            'room_id': 1,
            'kind': 'voice',
            'joined': 3,
            'free': 5,
            'my_state': 'declined'
          },
          every: const Duration(hours: 1),
          // the chat opens the group call screen; here: a visible echo
          onJoin: (room, kind) => ScaffoldMessenger.of(ctx)
              .showSnackBar(SnackBar(content: Text('$kind #$room'))),
        ),
        const Expanded(child: SizedBox()),
      ])),
    );

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> groupCallShots = {
  'gcall_grid_8': _grid8,
  'gcall_video_4_low_data': _video4,
  'gcall_add_person': _pick,
  'gcall_join_bar': _joinBar,
};
