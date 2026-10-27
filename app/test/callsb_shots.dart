// callsB gallery states for test/screenshots_test.dart: group call grid
// (3 / 4 people, ringing, mute + speaking, video + a shared screen), the
// 1:1 video call while sharing / while the other side shares, the screen
// share consent sheet, the add-person sheet, the group chat's Join call
// banner and the "who to ring" picker. Fixture people: Rahim (me), Karim,
// Salma, Nadia — never the owner's name.
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/group/add_person_sheet.dart';
import 'package:assisto/calls/group/group_call.dart';
import 'package:assisto/calls/group/group_call_screen.dart';
import 'package:assisto/calls/group/group_chat_call.dart';
import 'package:assisto/calls/group/group_stage.dart';
import 'package:assisto/calls/screen_share.dart';
import 'package:assisto/api.dart' show ApiClient;
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';
import 'callsb_fakes.dart';

Widget _group(String l,
        {int people = 3,
        String kind = 'voice',
        Set<int> muted = const {},
        Set<int> speaking = const {},
        Set<int> ringing = const {},
        Set<int> screen = const {},
        String groupName = ''}) =>
    GroupCallScreen(
      roomId: 7,
      kind: kind,
      session: previewSession(
          lang: l,
          people: people,
          kind: kind,
          muted: muted,
          speaking: speaking,
          ringing: ringing,
          screen: screen,
          groupName: groupName),
    );

ScreenShareController _share({bool sharing = false}) {
  final s = ScreenShareController(
      media: FakeShareMedia(),
      service: FakeShareService(),
      links: () => const [],
      texts: () => ('', '', ''));
  if (sharing) s.state = ScreenShareState.sharing;
  return s;
}

Widget _video1to1(String l, {bool sharing = false, bool remoteScreen = false}) {
  final c = previewController(
      video: true, outgoing: true, phase: CallPhase.connected);
  c.remoteScreen = remoteScreen;
  return CircleCallScreen(
    member: {'id': 2, 'name': fixtureName(kKarim, l)},
    kind: 'video',
    controller: c,
    surface: FakeSurface(),
    previewShare: _share(sharing: sharing),
  );
}

List<Map<String, dynamic>> _contacts(String l) => [
      {'id': 102, 'name': fixtureName(kKarim, l), 'state': 'accepted'},
      {'id': 103, 'name': fixtureName(kSalma, l), 'state': 'accepted'},
      {'id': 104, 'name': fixtureName(kNadia, l), 'state': 'accepted'},
    ];

Widget _sheetHost(String l, Widget sheet) => Scaffold(
      appBar: AppBar(title: Text(l == 'bn' ? 'কল' : 'Call')),
      body: const SizedBox.expand(),
      bottomSheet: SizedBox(height: 520, child: sheet),
    );

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> callsbShots = {
  'callsb_group_voice_3': (l) =>
      _group(l, muted: {kSalma}, speaking: {kKarim}),
  'callsb_group_voice_4_ringing': (l) =>
      _group(l, people: 4, ringing: {kNadia}, speaking: {kMe}),
  'callsb_group_video_4': (l) => _group(l,
      people: 4,
      kind: 'video',
      screen: {kSalma},
      muted: {kNadia},
      groupName: l == 'bn' ? 'পরিবার' : 'Family'),
  'callsb_share_bar_1to1': (l) => _video1to1(l, sharing: true),
  'callsb_remote_sharing_1to1': (l) => _video1to1(l, remoteScreen: true),
  'callsb_share_consent': (l) => _sheetHost(
      l,
      Builder(
          builder: (ctx) => ScreenShareConsentSheet(
              onAnswer: (_) => Navigator.of(ctx).maybePop()))),
  'callsb_add_person': (l) => _sheetHost(
      l,
      AddPersonSheet(
        loadContacts: () async => _contacts(l),
        onAdd: (_) async => AddPersonResult.ok,
        inCallMemberIds: const {102},
        seatsLeft: 2,
      )),
  'callsb_join_banner': (l) => Scaffold(
        appBar: AppBar(title: Text(l == 'bn' ? 'পরিবার' : 'Family')),
        body: Column(children: [
          GroupCallJoinBanner(
            api: ApiClient(),
            groupId: 3,
            initial: {
              'room': roster(
                  members: [member(kKarim, lang: l), member(kSalma, lang: l)],
                  myState: '')
            },
          ),
          const Expanded(child: SizedBox.shrink()),
        ]),
      ),
  'callsb_group_picker': (l) => _sheetHost(
      l,
      GroupCallPicker(candidates: [
        for (final id in [kKarim, kSalma, kNadia])
          {'user_id': id, 'name': fixtureName(id, l)}
      ])),
};
