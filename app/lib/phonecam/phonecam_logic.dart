import 'dart:typed_data';

/// cctvphone — an old Android phone as an Assisto camera. PURE rules (no
/// Flutter, no plugins, no I/O) so every decision is unit-tested:
///   * pairing-code parsing (mirrors backend core/logic/phonecam.py),
///   * the rolling on-phone clip store (size cap, oldest deleted first),
///   * "lens covered / dark" detection from the motion grid,
///   * what an alert is when a person model is or is not available,
///   * the health report sent with the heartbeat.

const kPairAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const kPairTailLen = 6;
const kPairLinkBase = 'https://lifeassisto.com/pc/';

/// Typed or scanned text -> "<site>-<TAIL>" or null. Accepts the full App
/// Link, spaces, lower case and a missing dash (same as the server).
String? normalizePairCode(String? raw) {
  var s = (raw ?? '').trim();
  final i = s.indexOf(kPairLinkBase);
  if (i >= 0) s = s.substring(i + kPairLinkBase.length);
  // an App Link route name arrives as "/pc/<code>"
  if (s.startsWith('/pc/')) s = s.substring(4);
  s = s.split('?').first.split('#').first;
  s = s.replaceAll('/', '').replaceAll(' ', '').toUpperCase();
  String site, tail;
  final d = s.indexOf('-');
  if (d >= 0) {
    site = s.substring(0, d);
    tail = s.substring(d + 1).replaceAll('-', '');
  } else {
    var k = 0;
    while (k < s.length && s.codeUnitAt(k) >= 48 && s.codeUnitAt(k) <= 57) {
      k++;
    }
    site = s.substring(0, k);
    tail = s.substring(k);
  }
  if (site.isEmpty || site.length > 9 || int.tryParse(site) == null) return null;
  if (tail.length != kPairTailLen) return null;
  for (final c in tail.split('')) {
    if (!kPairAlphabet.contains(c)) return null;
  }
  return '${int.parse(site)}-$tail';
}

/// The code from an App Link route name ("/pc/12-ABCDEF" or the full URL),
/// or null when the link is not ours.
String? pairCodeFromLink(String? name) {
  if (name == null) return null;
  final n = name.trim();
  if (!(n.startsWith('/pc/') || n.startsWith(kPairLinkBase))) return null;
  return normalizePairCode(n);
}

// --------------------------------------------------------------- clip store
class ClipFile {
  final String path;
  final int bytes;
  final DateTime modified;
  const ClipFile(this.path, this.bytes, this.modified);
}

/// Default size cap for the on-phone clips (owner can pick another).
const kClipCapChoicesMb = [200, 500, 1000, 2000];
const kClipCapDefaultMb = 500;

/// Which clips to delete so the total fits [capBytes] after adding
/// [incomingBytes] — oldest first. Never deletes everything for a single
/// clip bigger than the cap (that clip is then simply kept alone).
List<ClipFile> clipsToDelete(List<ClipFile> clips, int capBytes, {int incomingBytes = 0}) {
  final sorted = [...clips]..sort((a, b) => a.modified.compareTo(b.modified));
  var total = sorted.fold<int>(0, (s, c) => s + c.bytes) + incomingBytes;
  final out = <ClipFile>[];
  for (final c in sorted) {
    if (total <= capBytes) break;
    out.add(c);
    total -= c.bytes;
  }
  return out;
}

int clipsTotalBytes(List<ClipFile> clips) => clips.fold<int>(0, (s, c) => s + c.bytes);

// --------------------------------------------------------------- dark / covered
/// "Lens covered or room dark": the average brightness of the motion grid
/// stays below [threshold] (0..255) for [hold]. A light switched back on
/// clears it at once.
class DarkMonitor {
  final double threshold;
  final Duration hold;
  DateTime? _since;
  bool dark = false;
  DarkMonitor({this.threshold = 14, this.hold = const Duration(minutes: 1)});

  static double meanOf(Float64List grid) {
    if (grid.isEmpty) return 255;
    var s = 0.0;
    for (final v in grid) {
      s += v;
    }
    return s / grid.length;
  }

  bool feed(double mean, DateTime now) {
    if (mean >= threshold) {
      _since = null;
      dark = false;
      return dark;
    }
    _since ??= now;
    dark = now.difference(_since!) >= hold;
    return dark;
  }
}

// --------------------------------------------------------------- alerts
/// What the camera phone posts to shop/ingest for one confirmed motion.
///   * person model available: a person box -> `person_detected` (with the
///     best score as `conf`); no person -> nothing (a curtain, a cat, a
///     shadow is not an alert).
///   * no model on this phone: `motion` with an honest "motion only" label —
///     the server keeps it a low-confidence "possible" while armed.
({String type, Map<String, dynamic> signals})? phoneAlert(
    {required bool modelAvailable, List<List<double>>? boxes}) {
  if (!modelAvailable) {
    return (
      type: 'motion',
      signals: {
        'detector': 'android_frame_diff',
        'person_check': 'unavailable',
        'source': 'phone_camera',
        'multiple_frames': true,
      }
    );
  }
  if (boxes == null || boxes.isEmpty) return null;
  var best = 0.0;
  for (final b in boxes) {
    if (b.length >= 5 && b[4] > best) best = b[4];
  }
  return (
    type: 'person_detected',
    signals: {
      'detector': 'yolox_nano_phone',
      'conf': double.parse(best.toStringAsFixed(2)),
      'persons': boxes.length,
      'source': 'phone_camera',
    }
  );
}

/// The heartbeat's health report; unknown values are left out.
Map<String, dynamic> healthReport(Map? battery, {required bool dark}) {
  final out = <String, dynamic>{'dark': dark};
  if (battery != null) {
    final l = battery['level'];
    final c = battery['charging'];
    final t = battery['temp_c'];
    if (l is num) out['level'] = l.round();
    if (c is bool) out['charging'] = c;
    if (t is num) out['temp_c'] = double.parse(t.toStringAsFixed(1));
  }
  return out;
}

/// Warnings to show ON the camera phone itself (same thresholds as the
/// server's pushes): unplugged, battery < 20 %, ≥ 45 °C, dark.
List<String> localWarnings(Map<String, dynamic> h) {
  final out = <String>[];
  if (h['charging'] == false) {
    out.add('unplugged');
    final l = h['level'];
    if (l is int && l < 20) out.add('low_battery');
  }
  final t = h['temp_c'];
  if (t is num && t >= 45) out.add('hot');
  if (h['dark'] == true) out.add('dark');
  return out;
}
