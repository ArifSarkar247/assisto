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

/// A [PersonDetect] backed by the native channel, or null (motion only).
Future<PersonDetect?> guardPersonDetector({double threshold = 0.45}) async {
  try {
    final ok = await _channel.invokeMethod<bool>('available');
    if (ok != true) return null;
  } catch (_) {
    return null; // channel not registered on this build
  }
  final path = await ensureGuardModel();
  if (path == null) return null;
  return (Uint8List jpeg) async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>(
          'detect', {'model': path, 'jpeg': jpeg, 'thr': threshold});
      if (r == null || r['ok'] != true) return null;
      return [
        for (final b in (r['boxes'] as List? ?? const []))
          if (b is List && b.length >= 5) [for (final v in b) (v as num).toDouble()]
      ];
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
