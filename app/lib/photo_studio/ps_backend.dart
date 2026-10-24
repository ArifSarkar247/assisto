import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../config.dart';
import '../growth/install_ping.dart';
import 'ps_models.dart';

/// photo-final: a stable device key for the server's free-enhance counters
/// (per account AND device, so a reinstall cannot reset them). Android:
/// SHA-256 of Settings.Secure.ANDROID_ID from the native channel (stable
/// across reinstalls of the same signed app; the raw id never leaves the
/// phone). Fallback: the per-install id. Never throws; '' when nothing works.
class PsDeviceKey {
  PsDeviceKey._();
  static const _ch = MethodChannel('com.assisto/photo_native');
  static String? _cached;

  static Future<String> get() async {
    final c = _cached;
    if (c != null) return c;
    var v = '';
    try {
      if (Platform.isAndroid) v = await _ch.invokeMethod<String>('deviceKey') ?? '';
    } catch (_) {}
    if (v.isEmpty) {
      try {
        v = await InstallPing.installId();
      } catch (_) {}
    }
    return _cached = v;
  }
}

/// Server seam for Photo Studio. [ApiPsBackend] talks to `/photo-studio/*`;
/// tests and the screenshot gallery use a fake.
abstract class PsBackend {
  Future<PsConfig> config();
  Future<SafetyVerdict> safety(Map<String, dynamic> body);
  Future<PsReply> entryAd({required bool shown});
  Future<PsReply> createJob(Map<String, dynamic> body);
  Future<PsReply> job(int id);
  Future<PsReply> ticket(int id);
  Future<PsReply> fundWithCredits(int id);
  Future<PsReply> run(int id, {String imageB64 = '', List<List<double>>? faceBoxes});
  Future<PsReply> unlock(int id, ExportKind kind);
  Future<Uint8List?> download(String url);

  /// d1-photo v2: "Report this AI image" (Google Play AI-content policy).
  Future<PsReply> report(int id, String reason, {String note = ''});
}

class ApiPsBackend implements PsBackend {
  ApiPsBackend(this.api);
  final ApiClient api;

  PsReply _r(Map<String, dynamic> j) {
    final st = j['_status'] is num ? (j['_status'] as num).toInt() : 200;
    return PsReply(st, Map<String, dynamic>.from(j)..remove('_status'));
  }

  @override
  Future<PsConfig> config() async =>
      PsConfig.fromJson(await api.getJson('/photo-studio/config'));

  @override
  Future<SafetyVerdict> safety(Map<String, dynamic> body) async =>
      SafetyVerdict.fromJson(await api.postJson('/photo-studio/safety', body));

  @override
  Future<PsReply> entryAd({required bool shown}) async =>
      _r(await api.postJsonRaw('/photo-studio/entry-ad', {'shown': shown}));

  @override
  Future<PsReply> createJob(Map<String, dynamic> body) async => _r(await api.postJsonRaw(
      '/photo-studio/jobs', {...body, 'device_id': await PsDeviceKey.get()}));

  @override
  Future<PsReply> job(int id) async {
    try {
      return PsReply(200, await api.getJson('/photo-studio/jobs/$id'));
    } on ApiException catch (e) {
      return PsReply(e.status ?? 500, const {});
    }
  }

  @override
  Future<PsReply> ticket(int id) async =>
      _r(await api.postJsonRaw('/photo-studio/jobs/$id/ad-ticket'));

  @override
  Future<PsReply> fundWithCredits(int id) async =>
      _r(await api.postJsonRaw('/photo-studio/jobs/$id/fund'));

  @override
  Future<PsReply> run(int id,
          {String imageB64 = '', List<List<double>>? faceBoxes}) async =>
      _r(await api.postJsonRaw('/photo-studio/jobs/$id/run', {
        'image_b64': imageB64,
        if (faceBoxes != null && faceBoxes.isNotEmpty) 'face_boxes': faceBoxes,
      }));

  @override
  Future<PsReply> unlock(int id, ExportKind kind) async =>
      _r(await api.postJsonRaw('/photo-studio/jobs/$id/unlock', {'kind': kind.wire}));

  @override
  Future<PsReply> report(int id, String reason, {String note = ''}) async =>
      _r(await api.postJsonRaw('/photo-studio/jobs/$id/report', {'reason': reason, 'note': note}));

  @override
  Future<Uint8List?> download(String url) async {
    try {
      final full = url.startsWith('http') ? url : '${AppConfig.apiBase}$url';
      final r = await http.get(Uri.parse(full));
      if (r.statusCode == 200) return r.bodyBytes;
    } catch (_) {}
    return null;
  }

  static String b64(Uint8List bytes) => base64Encode(bytes);
}
