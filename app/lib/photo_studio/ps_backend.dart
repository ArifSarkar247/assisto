import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../config.dart';
import 'ps_models.dart';

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
  Future<PsReply> createJob(Map<String, dynamic> body) async =>
      _r(await api.postJsonRaw('/photo-studio/jobs', body));

  @override
  Future<PsReply> job(int id) async {
    try {
      return PsReply(200, await api.getJson('/photo-studio/jobs/$id'));
    } on ApiException catch (e) {
      return PsReply(e.status, const {});
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
