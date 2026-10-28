// cashguard — ASSISTO GUARD BOX: an old Android phone on the shop's Wi-Fi
// watches a shop IP camera and sends only event snapshots + sealed clips.
//
// Pure Dart (no Flutter widgets, no plugins) so every rule is unit-tested and
// timed on CI. The screen (guard_box_screen.dart) wires in the real frame
// fetcher (the camera's HTTP snapshot URL over the LAN), the JPEG decoder
// (dart:ui) and the optional native person model; tests inject fakes.
//
//   fetch JPEG (~2 fps) -> decode small grey -> motion inside the CASH polygon
//   (debounced) [-> person model on that frame, when available] -> cooldown
//   -> POST shop/ingest (signals + ONE snapshot + clip_ref)
//   -> ring of recent JPEGs -> 2 s later: "ACG1" clip -> sealed for the
//   owner's X25519 keys (same envelope as the Shop Box, clip.py) -> POST
//   shop/clips (ciphertext only).
//
// HONEST LIMITS (v1, behind the server flag guard_box_mode, OFF):
//   * frames come from the camera's HTTP snapshot (ONVIF GetSnapshotUri /
//     Hikvision ISAPI picture / Dahua snapshot.cgi). RTSP-only cameras (e.g.
//     TP-Link Tapo) still need the Shop Box PC — RTSP decoding on the phone
//     needs a new native decoder (.phaseB/proposals/cashguard.md);
//   * without the native person model it is MOTION in the cash zone (the
//     signals say detector "motion_only"); the server treats that as a
//     zone-breach "possible", never as a person.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/e2e.dart';
import 'clip_crypto.dart' show kClipAad, kClipScheme;

/// A small greyscale frame (luminance, row-major).
class GrayFrame {
  final int width, height;
  final Uint8List y;
  const GrayFrame(this.width, this.height, this.y);
}

typedef FrameFetch = Future<Uint8List?> Function();
typedef FrameDecode = Future<GrayFrame?> Function(Uint8List jpeg);

/// Normalised person boxes [x1, y1, x2, y2, score], or null = no model.
typedef PersonDetect = Future<List<List<double>>?> Function(Uint8List jpeg);

// ---------------------------------------------------------------- geometry
bool pointInPolygon(double x, double y, List<List<double>> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final xi = poly[i][0], yi = poly[i][1], xj = poly[j][0], yj = poly[j][1];
    if ((yi > y) != (yj > y)) {
      final xc = (xj - xi) * (y - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi;
      if (x < xc) inside = !inside;
    }
  }
  return inside;
}

/// A 3x3 grid inside the box: at least 2 points in the polygon.
bool boxInZone(List<double> b, List<List<double>> poly) {
  if (poly.length < 3 || b.length < 4) return false;
  var hits = 0;
  for (final fx in const [0.15, 0.5, 0.85]) {
    for (final fy in const [0.15, 0.5, 0.85]) {
      if (pointInPolygon(b[0] + (b[2] - b[0]) * fx, b[1] + (b[3] - b[1]) * fy, poly)) hits++;
    }
  }
  return hits >= 2;
}

// ---------------------------------------------------------------- motion
class ZoneMotionResult {
  final bool any;
  final bool inZone;
  final bool reset;
  const ZoneMotionResult(this.any, this.inZone, {this.reset = false});
}

/// Cheap grid motion (old phones): running background per cell, a cell moved
/// when |cell - bg| > [cellThreshold]; a frame-wide jump (lights, exposure)
/// resets and reports nothing; [confirm] consecutive frames needed.
class ZoneMotion {
  final int gridW, gridH;
  final double cellThreshold, zoneFrac, resetFrac, learn;
  final int confirm;
  List<List<double>> zone;
  Float64List? _bg;
  int _streak = 0;
  ZoneMotion({
    this.gridW = 32,
    this.gridH = 24,
    this.cellThreshold = 18,
    this.zoneFrac = 0.08,
    this.resetFrac = 0.6,
    this.learn = 0.08,
    this.confirm = 2,
    this.zone = const [],
  });

  Float64List grid(GrayFrame f) {
    final out = Float64List(gridW * gridH);
    final cw = f.width / gridW, ch = f.height / gridH;
    for (var gy = 0; gy < gridH; gy++) {
      for (var gx = 0; gx < gridW; gx++) {
        var sum = 0, n = 0;
        for (var iy = 0; iy < 2; iy++) {
          final py = (gy * ch + (iy + 0.5) * ch / 2).floor().clamp(0, f.height - 1);
          for (var ix = 0; ix < 2; ix++) {
            final px = (gx * cw + (ix + 0.5) * cw / 2).floor().clamp(0, f.width - 1);
            final i = py * f.width + px;
            if (i < f.y.length) {
              sum += f.y[i];
              n++;
            }
          }
        }
        out[gy * gridW + gx] = n == 0 ? 0 : sum / n;
      }
    }
    return out;
  }

  ZoneMotionResult feed(GrayFrame f) {
    final g = grid(f);
    final bg = _bg;
    if (bg == null) {
      _bg = g;
      return const ZoneMotionResult(false, false);
    }
    var changed = 0, zc = 0, zm = 0;
    for (var i = 0; i < g.length; i++) {
      final moved = (g[i] - bg[i]).abs() > cellThreshold;
      if (moved) changed++;
      if (zone.length >= 3) {
        final cx = ((i % gridW) + 0.5) / gridW, cy = ((i ~/ gridW) + 0.5) / gridH;
        if (pointInPolygon(cx, cy, zone)) {
          zc++;
          if (moved) zm++;
        }
      }
      bg[i] = bg[i] + (g[i] - bg[i]) * learn;
    }
    if (changed / g.length >= resetFrac) {
      _bg = g;
      _streak = 0;
      return const ZoneMotionResult(false, false, reset: true);
    }
    final inNow = zc > 0 && zm / zc >= zoneFrac;
    _streak = inNow ? _streak + 1 : 0;
    return ZoneMotionResult(changed > 0, _streak >= confirm);
  }
}

// ---------------------------------------------------------------- clip
class JpegRing {
  final double seconds;
  final List<(double, Uint8List)> _q = [];
  JpegRing(this.seconds);

  void add(double ts, Uint8List jpeg) {
    _q.add((ts, jpeg));
    while (_q.isNotEmpty && ts - _q.first.$1 > seconds) {
      _q.removeAt(0);
    }
  }

  List<(double, Uint8List)> since(double t0) => [for (final f in _q) if (f.$1 >= t0) f];
}

/// The "ACG1" container (same bytes as edge/shopbox/shopbox/clip.py).
Uint8List encodeContainer(List<(double, Uint8List)> frames, double fps) {
  final t0 = frames.first.$1;
  double r3(double v) => (v * 1000).roundToDouble() / 1000;
  final head = utf8.encode(jsonEncode({
    'v': 1,
    'fps': fps,
    'n': frames.length,
    't0': r3(t0),
    'ts': [for (final f in frames) r3(f.$1 - t0)],
  }));
  final b = BytesBuilder(copy: false);
  void u32(int v) => b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  b.add(const [0x41, 0x43, 0x47, 0x31]);
  u32(head.length);
  b.add(head);
  for (final f in frames) {
    u32(f.$2.length);
    b.add(f.$2);
  }
  return b.toBytes();
}

/// Seal [plain] for [recipients] ({uid, key_id, pub}): a fresh content key
/// and a fresh ephemeral X25519 identity per clip; each recipient's wrap is
/// a normal [SoftwareE2E.encrypt] of base64(K) to their public key.
({Uint8List ct, Map<String, dynamic> meta}) sealClip(
    Uint8List plain, List<Map<String, dynamic>> recipients, double fps, double durationS,
    {Random? rng}) {
  final r = rng ?? Random.secure();
  Uint8List rnd(int n) => Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  final k = rnd(32), nonce = rnd(12);
  final ct = ChaCha20Poly1305.encrypt(k, nonce, plain, aad: utf8.encode(kClipAad));
  final e2e = SoftwareE2E(r);
  final eph = e2e.generateIdentity();
  final wraps = <String, dynamic>{};
  for (final rec in recipients) {
    try {
      final pub = base64Decode((rec['pub'] ?? '').toString());
      if (pub.length != 32) continue;
      final w = e2e.encrypt(self: eph, recipientPublicKey: pub, plaintext: base64Encode(k));
      wraps['${(rec['uid'] as num).toInt()}'] = {
        'key_id': (rec['key_id'] ?? '').toString(),
        'nonce': w.nonceB64,
        'ct': w.ciphertextB64,
      };
    } catch (_) {
      // a bad key never blocks the others
    }
  }
  return (
    ct: ct,
    meta: {
      'v': 1,
      'alg': 'chacha20poly1305',
      'scheme': kClipScheme,
      'format': 'acg1',
      'aad': kClipAad,
      'nonce': base64Encode(nonce),
      'eph_pub': eph.publicKeyB64,
      'eph_key_id': eph.keyId,
      'wraps': wraps,
      'frames': 0,
      'duration_s': double.parse(durationS.toStringAsFixed(2)),
      'fps': fps,
    }
  );
}

// ---------------------------------------------------------------- device
/// What the Guard Box needs from the server (device token auth).
abstract class GuardDevice {
  Future<(int, Map<String, dynamic>)> ingest(String type, Map<String, dynamic> signals,
      {Uint8List? snapshot, String? clipRef});
  Future<(int, Map<String, dynamic>)> uploadClip(String clipRef, Map<String, dynamic> meta, Uint8List blob);
}

class GuardStats {
  int frames = 0;
  int fetchFails = 0;
  int events = 0;
  int clipsSent = 0;
  int clipsDropped = 0;
  double avgFrameMs = 0; // fetch + decode + motion (+ model)
  String detector = 'motion_only';
  String lastError = '';

  Map<String, Object> toJson() => {
        'frames': frames,
        'fetch_fails': fetchFails,
        'events': events,
        'clips_sent': clipsSent,
        'clips_dropped': clipsDropped,
        'avg_frame_ms': double.parse(avgFrameMs.toStringAsFixed(1)),
        'detector': detector,
      };
}

class GuardBoxEngine {
  final GuardDevice device;
  final FrameFetch fetch;
  final FrameDecode decode;
  final PersonDetect? detect;
  final double Function() clock; // seconds
  final Random? rng;
  final ZoneMotion motion;
  final JpegRing ring = JpegRing(4);
  final GuardStats stats = GuardStats();
  List<Map<String, dynamic>> recipients = const [];
  double cooldownS;
  double preS = 2, postS = 2, clipFps = 2;
  double _lastEventAt = -1e9;
  final List<_Job> _jobs = [];

  GuardBoxEngine({
    required this.device,
    required this.fetch,
    required this.decode,
    this.detect,
    double Function()? clock,
    this.rng,
    this.cooldownS = 180,
    List<List<double>> cashZone = const [],
  })  : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch / 1000.0),
        motion = ZoneMotion(zone: cashZone);

  /// Server config (shop/config): the camera's cash polygon + clip recipients.
  void applyConfig(Map<String, dynamic> cfg) {
    final clip = cfg['clip'];
    if (clip is Map) {
      recipients = clip['enabled'] == true
          ? [for (final r in (clip['recipients'] as List? ?? const [])) if (r is Map) r.cast<String, dynamic>()]
          : const [];
    }
    for (final c in (cfg['cameras'] as List? ?? const [])) {
      if (c is! Map) continue;
      final zones = ((c['zones'] as Map?)?['zones'] as List?) ?? ((c['zone_config'] as Map?)?['zones'] as List?) ?? const [];
      for (final z in zones) {
        if (z is Map && z['type'] == 'cash') {
          motion.zone = [
            for (final p in (z['points'] as List? ?? const []))
              if (p is List && p.length >= 2) [(p[0] as num).toDouble(), (p[1] as num).toDouble()]
          ];
        }
      }
      final cd = (c['tuning'] as Map?)?['cooldown_s'];
      if (cd is num) cooldownS = cd.toDouble();
    }
  }

  bool get hasZone => motion.zone.length >= 3;

  /// One cycle. Returns true when an alert was sent.
  Future<bool> tick() async {
    final t0 = DateTime.now();
    final now = clock();
    Uint8List? jpeg;
    try {
      jpeg = await fetch();
    } catch (e) {
      stats.lastError = e.runtimeType.toString();
    }
    if (jpeg == null) {
      stats.fetchFails++;
      return false;
    }
    ring.add(now, jpeg);
    await _feedJobs(now, jpeg);
    final g = await decode(jpeg);
    if (g == null) return false;
    final m = motion.feed(g);
    stats.frames++;
    var sent = false;
    if (m.inZone && hasZone && now - _lastEventAt >= cooldownS) {
      List<List<double>>? people;
      if (detect != null) {
        try {
          people = await detect!(jpeg);
        } catch (_) {
          people = null;
        }
      }
      stats.detector = people == null ? 'motion_only' : 'yolox_nano';
      final personInZone = people != null && people.any((b) => boxInZone(b, motion.zone));
      if (people == null || personInZone) {
        sent = await _alert(now, jpeg, personInZone);
      }
    }
    final ms = DateTime.now().difference(t0).inMicroseconds / 1000.0;
    stats.avgFrameMs = stats.frames <= 1 ? ms : stats.avgFrameMs * 0.9 + ms * 0.1;
    return sent;
  }

  Future<bool> _alert(double now, Uint8List jpeg, bool person) async {
    final ref = _ref();
    final wantClip = recipients.isNotEmpty;
    final type = person ? 'hand_in_cash_zone' : 'motion';
    final signals = person
        ? {'detector': 'yolox_nano', 'motion_in_zone': true, 'source': 'guard_box'}
        : {'detector': 'motion_only', 'motion_in_zone': true, 'zone_breach': true, 'source': 'guard_box'};
    final (status, body) = await device.ingest(type, signals,
        snapshot: jpeg, clipRef: wantClip ? ref : null);
    if (status < 200 || status >= 300) {
      stats.lastError = 'ingest_$status';
      return false;
    }
    _lastEventAt = now;
    stats.events++;
    if (wantClip && body['raised'] == true && body['clip_wanted'] != false) {
      _jobs.add(_Job(ref, now + postS, ring.since(now - preS)));
    }
    return body['raised'] == true;
  }

  Future<void> _feedJobs(double now, Uint8List jpeg) async {
    final done = <_Job>[];
    for (final j in _jobs) {
      if (now <= j.until) j.frames.add((now, jpeg));
      if (now >= j.until) done.add(j);
    }
    for (final j in done) {
      _jobs.remove(j);
      await _sendClip(j);
    }
  }

  Future<void> _sendClip(_Job j) async {
    final frames = j.frames;
    if (frames.length < 3 || recipients.isEmpty) {
      stats.clipsDropped++;
      return;
    }
    final dur = frames.last.$1 - frames.first.$1 + 1 / clipFps;
    if (dur < 2.5 || dur > 5.5) {
      stats.clipsDropped++;
      return;
    }
    final plain = encodeContainer(frames, clipFps);
    final sealed = sealClip(plain, recipients, clipFps, dur, rng: rng);
    sealed.meta['frames'] = frames.length;
    if ((sealed.meta['wraps'] as Map).isEmpty) {
      stats.clipsDropped++;
      return;
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final (st, _) = await device.uploadClip(j.ref, sealed.meta, sealed.ct);
      if (st == 201 || st == 200) {
        stats.clipsSent++;
        return;
      }
      if (st != 404 && st != 0 && st < 500) break;
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
    stats.clipsDropped++;
  }

  String _ref() {
    final r = rng ?? Random.secure();
    return List<String>.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

class _Job {
  final String ref;
  final double until;
  final List<(double, Uint8List)> frames;
  _Job(this.ref, this.until, List<(double, Uint8List)> pre) : frames = [...pre];
}
