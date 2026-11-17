// cctvdet: the zone detections inside the Android Guard Box engine and the
// phone camera glue (PhoneZoneWatch) — fake device, fake clock, no plugins.
import 'dart:typed_data';

import 'package:assisto/cashguard/guard_box_engine.dart';
import 'package:assisto/cctv/detect_rules.dart';
import 'package:assisto/cctv/phone_zone_watch.dart';
import 'package:flutter_test/flutter_test.dart';

class _Dev implements GuardDevice {
  final List<Map<String, dynamic>> ingests = [];
  @override
  Future<(int, Map<String, dynamic>)> ingest(String type, Map<String, dynamic> signals,
      {Uint8List? snapshot, String? clipRef}) async {
    ingests.add({'type': type, 'signals': signals});
    return (201, <String, dynamic>{'raised': true});
  }

  @override
  Future<(int, Map<String, dynamic>)> uploadClip(String clipRef, Map<String, dynamic> meta, Uint8List blob) async =>
      (201, <String, dynamic>{});
}

GrayFrame _textured(int seed) {
  const w = 64, h = 48;
  final y = Uint8List(w * h);
  for (var i = 0; i < y.length; i++) {
    y[i] = 40 + ((i * 37 + seed) % 160);
  }
  return GrayFrame(w, h, y);
}

const _lower = [
  [0.3, 0.5],
  [0.7, 0.5],
  [0.7, 1.0],
  [0.3, 1.0]
];

void main() {
  test('Guard Box: a person at the gate zone -> gate_person with zone signals', () async {
    final dev = _Dev();
    var t = 1000.0;
    final eng = GuardBoxEngine(
      device: dev,
      fetch: () async => Uint8List.fromList([0xff, 0xd8, 1, 0xff, 0xd9]),
      decode: (_) async => _textured(1),
      detect: (_) async => [
        [0.4, 0.6, 0.6, 0.95, 0.85]
      ],
      clock: () => t,
    );
    eng.applyConfig({
      'cameras': [
        {
          'id': 3,
          'zones': {
            'zones': [
              {'id': 'g1', 'type': 'gate', 'points': _lower, 'label': 'Shutter'},
              {
                'id': 'p1',
                'type': 'post',
                'points': _lower,
                'schedule': {
                  'days': [0, 1, 2, 3, 4, 5, 6],
                  'start': '00:00',
                  'end': '00:00'
                }
              }
            ],
            'schedule': null
          }
        }
      ]
    });
    expect(eng.zrules.zones.length, 2);
    for (var i = 0; i < 3; i++) {
      await eng.tick();
      t += 3;
    }
    final g = dev.ingests.where((e) => e['type'] == kDetGatePerson).toList();
    expect(g.length, 1);
    final s = g.first['signals'] as Map;
    expect(s['zone'], 'g1');
    expect(s['zone_label'], 'Shutter');
    expect(s['person'], isTrue);
    expect(s['device'], 'guard_box');
    // the person stands in the post zone -> never "post empty"
    expect(dev.ingests.where((e) => e['type'] == kDetPostEmpty), isEmpty);
  });

  test('Guard Box: a covered lens for a minute -> one camera_health "covered"', () async {
    final dev = _Dev();
    var t = 0.0;
    final flat = GrayFrame(64, 48, Uint8List(64 * 48)..fillRange(0, 64 * 48, 128));
    final eng = GuardBoxEngine(
      device: dev,
      fetch: () async => Uint8List.fromList([0xff, 0xd8, 1, 0xff, 0xd9]),
      decode: (_) async => flat,
      clock: () => t,
    );
    for (var i = 0; i < 5; i++) {
      await eng.tick();
      t += 30;
    }
    final h = dev.ingests.where((e) => e['type'] == kDetCameraHealth).toList();
    expect(h.length, 1);
    expect((h.first['signals'] as Map)['kind'], 'covered');
  });

  test('rotateGrid turns clockwise like the alert photo', () {
    // 3 x 2 grid: row0 = 0 1 2, row1 = 3 4 5
    final g = Float64List.fromList([0, 1, 2, 3, 4, 5]);
    final (r90, w90, h90) = rotateGrid(g, 3, 2, 90);
    expect((w90, h90), (2, 3));
    expect(r90.toList(), [3, 0, 4, 1, 5, 2]);
    final (r180, _, _) = rotateGrid(g, 3, 2, 180);
    expect(r180.toList(), [5, 4, 3, 2, 1, 0]);
    final (r270, w270, h270) = rotateGrid(g, 3, 2, 270);
    expect((w270, h270), (2, 3));
    expect(r270.toList(), [2, 5, 1, 4, 0, 3]);
  });

  test('PhoneZoneWatch: zones from shop/config, boxes -> detections, per-zone cooldown', () {
    var now = DateTime(2026, 11, 9, 23, 0);
    final w = PhoneZoneWatch(now: () => now);
    expect(w.active, isFalse);
    w.applyConfig({
      'cameras': [
        {
          'zones': {
            'zones': [
              {'id': 'g1', 'type': 'gate', 'points': _lower}
            ],
            'schedule': {
              'days': [0, 1, 2, 3, 4, 5, 6],
              'start': '22:00',
              'end': '06:00'
            }
          }
        }
      ]
    });
    expect(w.active, isTrue);
    final box = [
      [0.4, 0.6, 0.6, 0.95, 0.9]
    ];
    expect(w.onBoxes(box), isEmpty);
    now = now.add(const Duration(seconds: 5));
    final d = w.onBoxes(box);
    expect(d.single['type'], kDetGatePerson);
    final s = w.signals(d.single, model: true);
    expect(s['detector'], 'yolox_nano_phone');
    expect(s['device'], 'phone_camera');
    // a new visit inside the cooldown is held back (no alert storm)
    now = now.add(const Duration(seconds: 60));
    expect(w.onBoxes(const []), isEmpty);
    now = now.add(const Duration(seconds: 5));
    w.onBoxes(box);
    now = now.add(const Duration(seconds: 5));
    expect(w.onBoxes(box), isEmpty);
    // by day the camera is not on guard -> nothing
    final day = PhoneZoneWatch(now: () => DateTime(2026, 11, 9, 12, 0));
    day.applyConfig({
      'cameras': [
        {
          'zones': {
            'zones': [
              {'id': 'g1', 'type': 'gate', 'points': _lower}
            ],
            'schedule': {
              'days': [0, 1, 2, 3, 4, 5, 6],
              'start': '22:00',
              'end': '06:00'
            }
          }
        }
      ]
    });
    day.onBoxes(box);
    expect(day.onBoxes(box), isEmpty);
  });
}
