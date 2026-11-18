// calls-quality: the freeze / gap measurement used by the two-emulator call
// quality cases (integration_test/support/call_quality_watch.dart).
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/call_quality_watch.dart';

void main() {
  test('max video gap = the longest time with no new decoded frame', () async {
    // frames: moving, then frozen for 6 ticks, then moving again
    final frames = [0, 1, 2, 3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
    var i = 0;
    final w = await watchQuality(() async {
      final f = frames[i < frames.length ? i : frames.length - 1];
      i++;
      return {
        'vin_frames': f, 'ain_packets': i * 5, 'vin_lost': 0, 'vin_recv': i * 10,
        'pair': {'rtt_ms': 300, 'local': {'type': 'relay'}, 'remote': {'type': 'relay'}},
      };
    }, const Duration(milliseconds: 950), every: const Duration(milliseconds: 50));
    expect(w['video_frames'], greaterThan(5));
    // 7 sample intervals without a new frame (~350 ms), never the whole window
    expect(w['video_max_gap_ms'] as int, inInclusiveRange(300, 700));
    expect(w['audio_max_gap_ms'] as int, lessThan(200));
    expect(w['rtt_median_ms'], 300);
    expect(isRelayed(w), isTrue);
    expect(qualityLine(w), contains('path relay'));
  });

  test('a frozen picture for the whole window is reported as a full-window gap', () async {
    final w = await watchQuality(() async => {'vin_frames': 7, 'ain_packets': 3},
        const Duration(milliseconds: 400), every: const Duration(milliseconds: 50));
    expect(w['video_frames'], 0);
    expect(w['video_max_gap_ms'] as int, greaterThanOrEqualTo(350));
    expect(isRelayed(w), isFalse);
  });
}
