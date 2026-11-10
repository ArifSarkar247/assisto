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
  FakeWatchmanDet() : super('data');

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
              'title': 'Someone is at the shutter / gate', 'detail': 'Main shutter', 'zone': 'z1',
              'measured': null, 'measured_text': 'Accuracy of this alert type is not measured yet',
              'review_only': false, 'source': 'edge',
              'desc': 'One person in a dark jacket stands by the shutter, holding a bag.', 'desc_src': 'ai'
            }
          },
          {
            'id': 302, 'type': 'post_empty', 'confidence': 0.7, 'count': 1, 'status': 'open',
            'verdict': null, 'camera': 12, 'camera_name': 'Counter', 'snapshot_url': '',
            'label': 'suspicious_please_check', 'last_at': '2026-11-09T15:12:00+06:00',
            'created': '2026-11-09T15:12:00+06:00',
            'detect': {
              'title': 'The counter / post has been left empty', 'detail': 'Cash counter · for 5 min',
              'zone': 'z2', 'measured': {'p': 0.93, 'r': 0.9, 'n': 400},
              'measured_text': 'In tests this alert type was right 93% of the time (400 samples)',
              'review_only': false, 'source': 'edge',
              'desc': 'The counter is empty — Counter (Cash counter), 15:12', 'desc_src': 'template'
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
  'cdet_alerts': (_) => WatchmanAlertsScreen(source: FakeWatchmanDet(), siteId: 1, owner: true),
};
