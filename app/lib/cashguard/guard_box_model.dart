// cashguard — the Guard Box person model (YOLOX-Nano, Apache-2.0, ~3.6 MB):
// downloaded on first use from its OFFICIAL release URL, accepted only with
// the pinned SHA-256 (the same file + hash the Shop Box uses,
// edge/shopbox/shopbox/model_fetch.py), then run by the native channel
// "com.assisto/guardbox" (GuardBoxChannel.kt, onnxruntime-android).
// LAZY + CRASH-GUARDED: nothing happens until the owner starts Guard Box;
// any failure (no channel yet, no network, bad hash) returns null and the
// Guard Box honestly runs as "motion only".
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../shop_motion.dart'
    show
        NightConfirm,
        kNightClaheClip,
        kNightClaheTiles,
        kNightGammaTarget,
        kNightLumaMax,
        kNightPre,
        kNightSpreadMax,
        kPersonScoreDay,
        kPersonScoreNight;
import 'guard_box_engine.dart' show PersonDetect;

const kGuardModelUrl =
    'https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx';
const kGuardModelSha256 = 'c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d';
const _maxBytes = 20 * 1024 * 1024;
const _channel = MethodChannel('com.assisto/guardbox');

bool modelBytesOk(List<int> bytes) => c.sha256.convert(bytes).toString() == kGuardModelSha256;

/// The verified model file path, downloading it once. Null on any failure.
Future<String?> ensureGuardModel({http.Client? client}) async {
  try {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/models');
    final f = File('${dir.path}/yolox_nano.onnx');
    if (await f.exists() && modelBytesOk(await f.readAsBytes())) return f.path;
    final cl = client ?? http.Client();
    final r = await cl.get(Uri.parse(kGuardModelUrl)).timeout(const Duration(minutes: 2));
    if (r.statusCode != 200 || r.bodyBytes.length > _maxBytes || !modelBytesOk(r.bodyBytes)) {
      return null;
    }
    await dir.create(recursive: true);
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(r.bodyBytes, flush: true);
    await tmp.rename(f.path);
    return f.path;
  } catch (_) {
    return null;
  }
}

/// cctvacc: night mode for the person check, applied natively on the photo
/// (grey / IR or dark -> [kPersonScoreNight]); the same rule and values as the
/// Shop Box (edge/shopbox/shopbox/night.py; asserted in cctv_gate_parity_test).
/// cctvacc2: a night photo is also ENHANCED natively before the model
/// (nightPre: clahe / gamma / none — the same maths as night.py enhance).
const kGuardNightArgs = <String, Object>{
  'thrNight': kPersonScoreNight,
  'nightSpread': kNightSpreadMax,
  'nightLuma': kNightLumaMax,
  'nightPre': kNightPre,
  'claheClip': kNightClaheClip,
  'claheTiles': kNightClaheTiles,
  'gammaTarget': kNightGammaTarget,
};

bool _nightPending = false;

/// cctvacc2: true right after a check whose NIGHT person still waits for its
/// second frame ([kNightConfirm]); the caller checks one more frame soon
/// (phone: a second photo; Guard Box: the next frame does it by itself).
bool get guardNightPending => _nightPending;

/// A [PersonDetect] backed by the native channel, or null (motion only).
Future<PersonDetect?> guardPersonDetector({double threshold = kPersonScoreDay}) async {
  try {
    final ok = await _channel.invokeMethod<bool>('available');
    if (ok != true) return null;
  } catch (_) {
    return null; // channel not registered on this build
  }
  final path = await ensureGuardModel();
  if (path == null) return null;
  final confirm = NightConfirm();
  return (Uint8List jpeg) async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>(
          'detect', {'model': path, 'jpeg': jpeg, 'thr': threshold, ...kGuardNightArgs});
      if (r == null || r['ok'] != true) return null;
      final boxes = [
        for (final b in (r['boxes'] as List? ?? const []))
          if (b is List && b.length >= 5) [for (final v in b) (v as num).toDouble()]
      ];
      final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final ok = confirm.check(boxes.isNotEmpty, night: r['night'] == true, now: now);
      _nightPending = confirm.pending;
      return ok ? boxes : <List<double>>[];
    } catch (_) {
      return null;
    }
  };
}

Future<void> closeGuardDetector() async {
  try {
    await _channel.invokeMethod<bool>('close');
  } catch (_) {}
}
