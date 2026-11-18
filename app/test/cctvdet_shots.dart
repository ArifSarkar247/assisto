// cctvdet: gallery states (screenshots_test.dart, a11y + dead-button sweeps)
// for the CCTV zone detections — gate / post zones drawn on the picture,
// the zone settings sheet, and alerts with the measured accuracy line.
import 'package:flutter/material.dart';

import 'package:assisto/screens/watchman/watchman_alerts.dart';
import 'package:assisto/screens/watchman/watchman_zones.dart';
import 'package:assisto/screens/watchman/zone_options_sheet.dart';

import 'cctv1_fakes.dart';

const _lower = [
  [0.3, 0.5],
  [0.7, 0.5],
  [0.7, 1.0],
  [0.3, 1.0]
];

class FakeWatchmanDet extends FakeWatchman {
  /// gap-cctv: the server answers in the user's language — the Bangla shots
  /// get the Bangla texts (as core/logic/cctv_detect.py sends them).
  final String lang;
  FakeWatchmanDet({this.lang = 'en'}) : super('data');
  bool get _bn => lang == 'bn';

  @override
  Future<Map<String, dynamic>> zones(int cameraId) async => {
        'camera': cameraId,
        'zone_config': {
          'v': 2,
          'zones': [
            {
              'id': 'z1',
              'type': 'gate',
              'label': 'Main shutter',
              'points': _lower,
              'opts': {'watch_open': true, 'open_min': 10, 'closed_at': 1762700000.0, 'dwell_s': 120}
            },
            {
              'id': 'z2',
              'type': 'post',
              'label': 'Cash counter',
              'points': [
                [0.05, 0.1],
                [0.28, 0.1],
                [0.28, 0.45],
                [0.05, 0.45]
              ],
              'schedule': {
                'days': [0, 1, 2, 3, 4, 5, 6],
                'start': '10:00',
                'end': '21:00'
              },
              'opts': {'absent_min': 5}
            },
          ],
          'schedule': {
            'days': [0, 1, 2, 3, 4, 5, 6],
            'start': '22:00',
            'end': '06:00'
          },
          'sensitivity': 'medium',
          'quiet_hours': null,
        },
        'tuning': {'person_conf': 0.45, 'motion_mult': 1.0, 'cooldown_s': 180, 'correct': 0, 'wrong': 0},
      };

  @override
  Future<Map<String, dynamic>> events(int siteId) async => {
        'role': 'owner',
        'held_today': 0,
        'events': [
          {
            'id': 301, 'type': 'gate_person', 'confidence': 0.75, 'count': 1, 'status': 'open',
            'verdict': null, 'camera': 11, 'camera_name': 'Shop front', 'snapshot_url': '',
            'label': 'suspicious_please_check', 'last_at': '2026-11-09T23:40:00+06:00',
            'created': '2026-11-09T23:40:00+06:00',
            'clip': {'status': 'ready', 'expires_at': '2026-11-10T23:40:00+06:00', 'size': 520000},
            'detect': {
              'title': _bn ? 'শাটার / গেটে কেউ আছে' : 'Someone is at the shutter / gate', 'detail': _bn ? 'প্রধান শাটার' : 'Main shutter', 'zone': 'z1',
              'measured': null, 'measured_text': _bn ? 'এই ধরনের সতর্কতার নির্ভুলতা এখনো মাপা হয়নি' : 'Accuracy of this alert type is not measured yet',
              'review_only': false, 'source': 'edge',
              'desc': _bn ? 'গাঢ় জ্যাকেট পরা একজন ব্যাগ হাতে শাটারের পাশে দাঁড়িয়ে আছেন।' : 'One person in a dark jacket stands by the shutter, holding a bag.', 'desc_src': 'ai'
            }
          },
          {
            'id': 302, 'type': 'post_empty', 'confidence': 0.7, 'count': 1, 'status': 'open',
            'verdict': null, 'camera': 12, 'camera_name': 'Counter', 'snapshot_url': '',
            'label': 'suspicious_please_check', 'last_at': '2026-11-09T15:12:00+06:00',
            'created': '2026-11-09T15:12:00+06:00',
            'detect': {
              'title': _bn ? 'কাউন্টার / পোস্ট ফাঁকা পড়ে আছে' : 'The counter / post has been left empty',
              'detail': _bn ? 'ক্যাশ কাউন্টার · ৫ মিনিট ধরে' : 'Cash counter · for 5 min',
              'zone': 'z2', 'measured': {'p': 0.93, 'r': 0.9, 'n': 400},
              'measured_text': _bn ? 'পরীক্ষায় এই ধরনের সতর্কতা ৯৩% বার ঠিক ছিল (৪০০টি নমুনা)' : 'In tests this alert type was right 93% of the time (400 samples)',
              'review_only': false, 'source': 'edge',
              'desc': _bn ? 'কাউন্টার ফাঁকা — কাউন্টার (ক্যাশ কাউন্টার), ১৫:১২' : 'The counter is empty — Counter (Cash counter), 15:12', 'desc_src': 'template'
            }
          },
        ],
      };
}

final Map<String, Widget Function(String)> cctvdetShots = {
  'cdet_zones': (_) => WatchmanZonesScreen(source: FakeWatchmanDet(), camera: FakeWatchman.cameraRow()),
  'cdet_zone_gate': (_) => Scaffold(
      body: ZoneOptionsBody(
          type: 'gate',
          name: 'Shutter / gate',
          label: 'Main shutter',
          schedule: null,
          opts: const {'watch_open': true, 'open_min': 10, 'dwell_s': 120})),
  'cdet_zone_post': (_) => Scaffold(
      body: ZoneOptionsBody(
          type: 'post',
          name: 'Counter / post',
          label: 'Cash counter',
          schedule: const {
            'days': [0, 1, 2, 3, 4, 5, 6],
            'start': '10:00',
            'end': '21:00'
          },
          opts: const {'absent_min': 5})),
  'cdet_alerts': (l) => WatchmanAlertsScreen(source: FakeWatchmanDet(lang: l), siteId: 1, owner: true),
  // stage 2: parking zones, the vehicle line, crowd count
  'cdet_zone_no_parking': (_) => Scaffold(
      body: ZoneOptionsBody(
          type: 'no_parking', name: 'No parking', label: 'Gate front', schedule: null,
          opts: const {'wrong_s': 120})),
  'cdet_zone_line': (_) => Scaffold(
      body: ZoneOptionsBody(
          type: 'entry_line', name: 'Entry line', label: 'Main gate', schedule: null,
          opts: const {'vehicles': true, 'notify': false})),
  'cdet_zone_queue': (_) => Scaffold(
      body: ZoneOptionsBody(
          type: 'restricted', name: 'Restricted area', label: 'Bill counter queue', schedule: null,
          opts: const {'crowd_n': 5})),
  'cdet_alerts_vehicle': (l) => WatchmanAlertsScreen(source: FakeWatchmanVeh(lang: l), siteId: 1, owner: true),
};

class FakeWatchmanVeh extends FakeWatchman {
  final String lang; // gap-cctv: Bangla shots get the server's Bangla texts
  FakeWatchmanVeh({this.lang = 'en'}) : super('data');
  bool get _bn => lang == 'bn';

  @override
  Future<Map<String, dynamic>> events(int siteId) async => {
        'role': 'owner',
        'held_today': 0,
        'events': [
          {
            'id': 401, 'type': 'vehicle_in_out', 'confidence': 0.7, 'count': 1, 'status': 'open',
            'verdict': null, 'camera': 21, 'camera_name': 'Parking gate', 'snapshot_url': '',
            'label': 'suspicious_please_check', 'last_at': '2026-11-10T08:15:00+06:00',
            'created': '2026-11-10T08:15:00+06:00',
            'detect': {
              'title': _bn ? 'একটি গাড়ি ঢুকেছে / বেরিয়েছে' : 'A vehicle came in / went out',
              'detail': _bn ? 'প্রধান গেট · গাড়ি · ঢুকেছে · প্লেট: ঢাকা মেট্রো-গ ১২-৩৪৫৬' : 'Main gate · car · in · Plate: DHAKA METRO-GA 12-3456',
              'zone': 'l1', 'measured': null, 'measured_text': _bn ? 'এই ধরনের সতর্কতার নির্ভুলতা এখনো মাপা হয়নি' : 'Accuracy of this alert type is not measured yet',
              'review_only': false, 'source': 'edge',
              'plate': {'bn': 'ঢাকা মেট্রো-গ ১২-৩৪৫৬', 'en': 'DHAKA METRO-GA 12-3456', 'number': '12-3456',
                        'partial': false, 'source': 'ai'},
              'desc': _bn ? 'একটি সাদা গাড়ি গেট দিয়ে ঢুকছে।' : 'A white car enters through the gate.', 'desc_src': 'ai'
            }
          },
          {
            'id': 402, 'type': 'crowd', 'confidence': 0.7, 'count': 1, 'status': 'open',
            'verdict': null, 'camera': 22, 'camera_name': 'Bill counter', 'snapshot_url': '',
            'label': 'suspicious_please_check', 'last_at': '2026-11-10T13:05:00+06:00',
            'created': '2026-11-10T13:05:00+06:00',
            'detect': {
              'title': _bn ? 'ভিড় / লম্বা লাইন' : 'A crowd / long queue',
              'detail': _bn ? 'বিল কাউন্টারের লাইন · ৭ জন' : 'Bill counter queue · 7 people', 'zone': 'q',
              'measured': null, 'measured_text': _bn ? 'এই ধরনের সতর্কতার নির্ভুলতা এখনো মাপা হয়নি' : 'Accuracy of this alert type is not measured yet',
              'review_only': false, 'source': 'edge', 'desc': null, 'desc_src': null
            }
          },
        ],
      };
}
