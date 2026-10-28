// perf2gb: the frame statistics the 2 GB CI run reports.
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/perf/perf_stats.dart';

void main() {
  test('nearest-rank percentiles', () {
    final v = [for (var i = 1; i <= 100; i++) i];
    expect(percentile(v, 50), 50);
    expect(percentile(v, 90), 90);
    expect(percentile(v, 99), 99);
    expect(percentile([7], 90), 7);
    expect(percentile([], 90), 0);
  });

  test('janky = UI or raster over the 16.7 ms budget', () {
    final s = frameStats(
      buildUs: [5000, 20000, 5000, 5000],
      rasterUs: [5000, 5000, 30000, 5000],
      totalUs: [10000, 25000, 40000, 10000],
    );
    expect(s['frames'], 4);
    expect(s['janky_pct'], 50.0);
    expect(s['janky_ui_pct'], 25.0);
    expect(s['stutter_frames'], 1);
    expect(s['frame_ms_p99'], 30.0);
    expect(s['build_ms_p50'], 5.0);
  });

  test('empty window is all zeros, never a crash', () {
    final s = frameStats(buildUs: [], rasterUs: [], totalUs: []);
    expect(s['frames'], 0);
    expect(s['janky_pct'], 0);
  });
}
