import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../config.dart';

/// md1 — a refused / failed media HTTP call. [reason] is the server's code
/// (too_big | daily_quota | rate_limit | bad_kind | blob_missing |
/// media_after_accept) when it gave one; [detail] its bn/en sentence.
class MediaHttpError implements Exception {
  final int status;
  final String reason;
  final String detail;
  final Map<String, dynamic> body;
  const MediaHttpError(this.status, {this.reason = '', this.detail = '', this.body = const {}});

  /// Retrying cannot help (size cap, quota, kind, request not accepted).
  bool get permanent =>
      status == 413 || status == 400 || status == 403 ||
      (status == 429 && reason == 'daily_quota');

  @override
  String toString() => 'MediaHttpError($status $reason)';
}

/// Network seam for media upload / download / send (fake in tests).
abstract class MediaTransport {
  Future<Map<String, dynamic>> createBlob(String kind, int size, String sha256);
  Future<Map<String, dynamic>> blobStatus(String ref);
  Future<Map<String, dynamic>> putChunk(String ref, int offset, Uint8List bytes);
  Future<Map<String, dynamic>> finish(String ref);
  Future<void> cancelBlob(String ref);

  /// {url: signed path, size, sha256} — 404 when gone / not a participant.
  Future<Map<String, dynamic>> downloadUrl(String ref);

  /// Stream the signed URL into [sink]; reports received bytes.
  Future<void> download(String url, IOSink sink,
      {void Function(int got)? onBytes, bool Function()? cancelled});

  Future<Map<String, dynamic>> peerKey(int memberId);
  Future<List<Map<String, dynamic>>> groupRoster(int groupId);
  Future<Map<String, dynamic>> sendMember(int memberId, Map<String, dynamic> env);
  Future<Map<String, dynamic>> sendGroup(int groupId, Map<String, dynamic> env);
}

class HttpMediaTransport implements MediaTransport {
  HttpMediaTransport({http.Client? client, String? Function()? token})
      : _c = client ?? http.Client(),
        _token = token ?? (() => AppConfig.authToken);

  final http.Client _c;
  final String? Function() _token;
  static const _t = Duration(seconds: 30);

  Map<String, String> _h({bool json = true}) => {
        if (json) 'Content-Type': 'application/json',
        if ((_token() ?? '').isNotEmpty) 'Authorization': 'Token ${_token()}',
      };

  Map<String, dynamic> _parse(http.Response r) {
    Map<String, dynamic> body = const {};
    try {
      final j = r.body.isEmpty ? const {} : jsonDecode(r.body);
      if (j is Map) body = j.cast<String, dynamic>();
    } catch (_) {}
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    throw MediaHttpError(r.statusCode,
        reason: '${body['reason'] ?? ''}',
        detail: '${body['detail'] ?? ''}',
        body: body);
  }

  Future<Map<String, dynamic>> _get(String p) async =>
      _parse(await _c.get(AppConfig.api(p), headers: _h()).timeout(_t));

  Future<Map<String, dynamic>> _post(String p, [Map<String, dynamic>? b]) async =>
      _parse(await _c
          .post(AppConfig.api(p), headers: _h(), body: jsonEncode(b ?? const {}))
          .timeout(_t));

  @override
  Future<Map<String, dynamic>> createBlob(String kind, int size, String sha256) =>
      _post('/circle/media/blobs', {'kind': kind, 'size': size, 'sha256': sha256});

  @override
  Future<Map<String, dynamic>> blobStatus(String ref) => _get('/circle/media/blobs/$ref');

  @override
  Future<Map<String, dynamic>> putChunk(String ref, int offset, Uint8List bytes) async {
    final h = _h(json: false)..['Content-Type'] = 'application/octet-stream';
    final r = await _c
        .put(AppConfig.api('/circle/media/blobs/$ref?offset=$offset'),
            headers: h, body: bytes)
        .timeout(const Duration(seconds: 90));
    return _parse(r);
  }

  @override
  Future<Map<String, dynamic>> finish(String ref) =>
      _post('/circle/media/blobs/$ref/finish');

  @override
  Future<void> cancelBlob(String ref) async {
    try {
      await _c
          .delete(AppConfig.api('/circle/media/blobs/$ref'), headers: _h())
          .timeout(_t);
    } catch (_) {
      // best effort: the server's 24 h sweep removes an unsent upload anyway
    }
  }

  @override
  Future<Map<String, dynamic>> downloadUrl(String ref) =>
      _get('/circle/media/blobs/$ref/url');

  @override
  Future<void> download(String url, IOSink sink,
      {void Function(int got)? onBytes, bool Function()? cancelled}) async {
    final full = url.startsWith('http') ? url : '${AppConfig.apiBase}$url';
    final req = http.Request('GET', Uri.parse(full));
    final resp = await _c.send(req).timeout(_t);
    if (resp.statusCode != 200) {
      await resp.stream.drain<void>();
      throw MediaHttpError(resp.statusCode);
    }
    var got = 0;
    await for (final chunk in resp.stream.timeout(const Duration(seconds: 45))) {
      if (cancelled?.call() == true) throw const MediaHttpError(-1, reason: 'cancelled');
      sink.add(chunk);
      got += chunk.length;
      onBytes?.call(got);
    }
  }

  @override
  Future<Map<String, dynamic>> peerKey(int memberId) => _get('/circle/keys/peer/$memberId');

  @override
  Future<List<Map<String, dynamic>>> groupRoster(int groupId) async {
    final r = await _get('/circle/groups/$groupId/members');
    return ((r['results'] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  @override
  Future<Map<String, dynamic>> sendMember(int memberId, Map<String, dynamic> env) =>
      _post('/circle/$memberId/messages', env);

  @override
  Future<Map<String, dynamic>> sendGroup(int groupId, Map<String, dynamic> env) =>
      _post('/circle/groups/$groupId/messages', env);
}
