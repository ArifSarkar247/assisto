// c2-calls gallery states for test/screenshots_test.dart: every phase of a
// REAL call (frozen controllers, fake video surface) + the honest outcomes.
import 'package:flutter/material.dart';

import 'package:assisto/calls/call_avatar.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import 'c2_calls_fakes.dart';
import 'x1_calls_fixtures.dart';

const _x1Photo = '/api/v1/m/avatars/x1-demo.png?e=1&s=demo';

Widget _x1(String l, CallPhase p,
    {bool outgoing = true, CallEndReason r = CallEndReason.none}) {
  CallPhotoCache.instance.seed(_x1Photo, x1TestPhoto);
  return CircleCallScreen(
    member: {
      'id': 5,
      'name': l == 'bn' ? 'টি শান্ত বিডি' : 'T Shanto BD',
      'photo': _x1Photo,
    },
    kind: 'voice',
    outgoing: outgoing,
    controller: previewController(
        video: false, outgoing: outgoing, phase: p, reason: r),
  );
}

Map<String, dynamic> _m(String l) =>
    {'id': 1, 'name': l == 'bn' ? 'নাদিয়া' : 'Nadia', 'relation': 'friend'};

Widget _call(String l, CallPhase p,
        {bool video = false,
        bool outgoing = true,
        CallEndReason r = CallEndReason.none,
        bool turn = true,
        CallQuality q = CallQuality.good,
        bool remoteCamera = true}) =>
    CircleCallScreen(
      member: _m(l),
      kind: video ? 'video' : 'voice',
      outgoing: outgoing,
      controller: previewController(
          video: video,
          outgoing: outgoing,
          phase: p,
          reason: r,
          turn: turn,
          quality: q,
          remoteCamera: remoteCamera),
      surface: video ? FakeSurface() : null,
    );

/// name -> builder(lang). Wired into screenshots_test.dart `specs`.
final Map<String, Widget Function(String)> c2Shots = {
  'c2_call_calling': (l) => _call(l, CallPhase.calling),
  'c2_call_ringing_no_relay': (l) => _call(l, CallPhase.ringing, turn: false),
  'c2_call_connecting': (l) => _call(l, CallPhase.accepted),
  'c2_call_connected_voice': (l) => _call(l, CallPhase.connected),
  'c2_call_reconnecting': (l) =>
      _call(l, CallPhase.reconnecting, q: CallQuality.poor),
  'c2_call_video_connected': (l) =>
      _call(l, CallPhase.connected, video: true, q: CallQuality.fair),
  'c2_call_video_remote_cam_off': (l) => _call(l, CallPhase.connected,
      video: true, remoteCamera: false),
  'c2_call_busy': (l) => _call(l, CallPhase.ended, r: CallEndReason.busy),
  'c2_call_no_answer': (l) =>
      _call(l, CallPhase.ended, r: CallEndReason.noAnswer),
  'c2_call_declined': (l) =>
      _call(l, CallPhase.ended, r: CallEndReason.declined),
  'c2_call_offline': (l) => _call(l, CallPhase.ended, r: CallEndReason.offline),
  'c2_call_failed': (l) => _call(l, CallPhase.ended, r: CallEndReason.failed),
  'c2_call_permission': (l) =>
      _call(l, CallPhase.ended, r: CallEndReason.mediaDenied),
  // x1-calls: "Couldn't connect — check internet" + Call again, BOTH sides
  'x1_call_connect_failed': (l) =>
      _x1(l, CallPhase.ended, r: CallEndReason.connectFailed),
  'x1_call_connect_failed_callee': (l) => _x1(l, CallPhase.ended,
      outgoing: false, r: CallEndReason.connectFailed),
  'x1_call_photo_ringing': (l) => _x1(l, CallPhase.ringing),
  'x1_call_photo_connected': (l) => _x1(l, CallPhase.connected),
  'x1_call_incoming_photo': (l) {
    CallPhotoCache.instance.seed(_x1Photo, x1TestPhoto);
    return IncomingCallScreen(
        payload: PushPayload.fromData({
      'kind': 'call',
      'call_id': '43',
      'caller_name': l == 'bn' ? 'টি শান্ত বিডি' : 'T Shanto BD',
      'caller_photo': _x1Photo,
      'video': 'false',
      'chat_id': '5',
      'lang': l,
    }));
  },
  'c2_call_incoming_video': (l) => IncomingCallScreen(
      payload: PushPayload.fromData({
        'kind': 'call',
        'call_id': '42',
        'caller_name': l == 'bn' ? 'নাদিয়া' : 'Nadia',
        'video': 'true',
        'chat_id': '1',
        'lang': l,
      })),
};
