// sosat — shared loader / metrics for the labelled sensor-trace harnesses.
import 'dart:io';

const kTraceDir = 'test/fixtures/sensor_traces';

class Sample {
  final int t;
  final double x, y, z;
  const Sample(this.t, this.x, this.y, this.z);
}

class Trace {
  final String name;
  final Map<String, String> meta;
  final List<Sample> samples;
  Trace(this.name, this.meta, this.samples);

  String get label => meta['label'] ?? '';
  String get detector => meta['detector'] ?? '';
  String get source =>
      (meta['source'] ?? '').startsWith('recorded') ? 'recorded' : 'synthetic';
  int get durationMs => samples.isEmpty ? 0 : samples.last.t - samples.first.t;
  int intMeta(String k, int d) => int.tryParse(meta[k] ?? '') ?? d;
}

List<Trace> loadTraces(String detector) {
  final dir = Directory(kTraceDir);
  final out = <Trace>[];
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.csv')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final meta = <String, String>{};
    final samples = <Sample>[];
    for (final line in f.readAsLinesSync()) {
      if (line.startsWith('#')) {
        final kv = line.substring(1).trim();
        final i = kv.indexOf('=');
        if (i > 0) meta[kv.substring(0, i).trim()] = kv.substring(i + 1).trim();
        continue;
      }
      final p = line.split(',');
      if (p.length < 4) continue;
      final t = int.tryParse(p[0]);
      if (t == null) continue; // header row
      samples.add(Sample(t, double.parse(p[1]), double.parse(p[2]), double.parse(p[3])));
    }
    if (meta['detector'] != detector) continue;
    final name = f.uri.pathSegments.last.replaceAll('.csv', '');
    out.add(Trace(name, meta, samples));
  }
  return out;
}

class Metrics {
  int tp = 0, fp = 0, fn = 0, tn = 0;
  double negativeHours = 0;

  static Metrics of(List<Trace> ts, Map<String, bool> fired,
      {required String positive}) {
    final m = Metrics();
    for (final t in ts) {
      final f = fired[t.name] ?? false;
      final pos = t.label == positive;
      if (pos && f) m.tp++;
      if (pos && !f) m.fn++;
      if (!pos && f) m.fp++;
      if (!pos && !f) m.tn++;
      if (!pos) m.negativeHours += t.durationMs / 3600000.0;
    }
    return m;
  }

  double get precision => tp + fp == 0 ? 0 : tp / (tp + fp);
  double get recall => tp + fn == 0 ? 0 : tp / (tp + fn);

  String summary() => 'TP=$tp FP=$fp FN=$fn TN=$tn '
      'precision=${precision.toStringAsFixed(2)} recall=${recall.toStringAsFixed(2)} '
      'false_alarms_per_hour_of_negative_traces='
      '${negativeHours == 0 ? "n/a" : (fp / negativeHours).toStringAsFixed(1)}';
}
