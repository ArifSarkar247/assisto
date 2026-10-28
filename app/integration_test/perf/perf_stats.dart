// perf2gb: pure statistics over frame timings (unit-tested in
// test/perf2gb_stats_test.dart; no Flutter imports so it runs anywhere).

/// Frame budget at 60 Hz, in microseconds.
const int kFrameBudgetUs = 16667;

/// Nearest-rank percentile of [values] (0 for an empty list).
double percentile(List<num> values, double p) {
  if (values.isEmpty) return 0;
  final s = [...values]..sort();
  final rank = (p / 100 * s.length).ceil().clamp(1, s.length);
  return s[rank - 1].toDouble();
}

double _ms(num us) => (us / 1000 * 100).round() / 100;

/// Summary of one measured window. [buildUs] = UI thread (build/layout/
/// paint), [rasterUs] = raster thread, [totalUs] = vsync start to raster end.
/// A frame is janky when the UI or raster thread missed the 16.7 ms budget
/// (Flutter DevTools' definition).
Map<String, dynamic> frameStats({
  required List<int> buildUs,
  required List<int> rasterUs,
  required List<int> totalUs,
}) {
  final n = buildUs.length;
  var janky = 0, jankyUi = 0, missed = 0;
  for (var i = 0; i < n; i++) {
    final b = buildUs[i], r = i < rasterUs.length ? rasterUs[i] : 0;
    if (b > kFrameBudgetUs || r > kFrameBudgetUs) janky++;
    if (b > kFrameBudgetUs) jankyUi++;
    // a frame longer than 2 budgets is a visible stutter on a 60 Hz screen
    if ((i < totalUs.length ? totalUs[i] : 0) > 2 * kFrameBudgetUs) missed++;
  }
  final worst = [
    for (var i = 0; i < n; i++)
      buildUs[i] > (i < rasterUs.length ? rasterUs[i] : 0) ? buildUs[i] : rasterUs[i]
  ];
  double pct(int k) => n == 0 ? 0 : (k * 1000 / n).round() / 10;
  return {
    'frames': n,
    'build_ms_p50': _ms(percentile(buildUs, 50)),
    'build_ms_p90': _ms(percentile(buildUs, 90)),
    'build_ms_p99': _ms(percentile(buildUs, 99)),
    'raster_ms_p50': _ms(percentile(rasterUs, 50)),
    'raster_ms_p90': _ms(percentile(rasterUs, 90)),
    'raster_ms_p99': _ms(percentile(rasterUs, 99)),
    'frame_ms_p50': _ms(percentile(worst, 50)),
    'frame_ms_p90': _ms(percentile(worst, 90)),
    'frame_ms_p99': _ms(percentile(worst, 99)),
    'total_ms_p90': _ms(percentile(totalUs, 90)),
    'janky_pct': pct(janky),
    'janky_ui_pct': pct(jankyUi),
    'stutter_frames': missed,
  };
}
