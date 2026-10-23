/// Photo Studio — the on-device AI model: manifest, resumable download,
/// sha256 check, offline reuse (p2-photo).
///
/// The model (Real-ESRGAN realesr-general-x4v3, BSD-3-Clause, ~4.9 MB) is
/// NEVER bundled in the APK. The first time the user turns on "AI restore" in
/// Photo Studio it is downloaded from OUR server
/// (GET /api/v1/photo-studio/model/<name>, HTTP Range), verified against the
/// manifest's sha256 and kept in app storage — after that it works offline.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// ===================================================================== sha256
/// Streaming SHA-256 (FIPS 180-4), pure Dart — avoids a new package.
class Sha256 {
  Sha256() {
    _h.setAll(0, _init);
  }
  static const _init = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  final _h = Uint32List(8);
  final _w = Uint32List(64);
  final _buf = Uint8List(64);
  int _bufLen = 0;
  int _total = 0;
  bool _done = false;

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

  void add(List<int> data) {
    if (_done) throw StateError('Sha256 already closed');
    _total += data.length;
    var i = 0;
    if (_bufLen > 0) {
      while (_bufLen < 64 && i < data.length) {
        _buf[_bufLen++] = data[i++];
      }
      if (_bufLen == 64) {
        _block(_buf, 0);
        _bufLen = 0;
      }
    }
    final src = data is Uint8List ? data : Uint8List.fromList(data);
    while (i + 64 <= src.length) {
      _block(src, i);
      i += 64;
    }
    while (i < src.length) {
      _buf[_bufLen++] = src[i++];
    }
  }

  void _block(Uint8List b, int o) {
    final w = _w;
    for (var t = 0; t < 16; t++) {
      final j = o + t * 4;
      w[t] = (b[j] << 24) | (b[j + 1] << 16) | (b[j + 2] << 8) | b[j + 3];
    }
    for (var t = 16; t < 64; t++) {
      final x = w[t - 15], y = w[t - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }
    var a = _h[0], bb = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (h + s1 + ch + _k[t] + w[t]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & bb) ^ (a & c) ^ (bb & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = bb;
      bb = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + bb) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }

  /// Finish and return the lowercase hex digest.
  String close() {
    if (_done) throw StateError('Sha256 already closed');
    final bits = _total * 8;
    final pad = <int>[0x80];
    final rem = (_bufLen + 1) % 64;
    final zeros = rem <= 56 ? 56 - rem : 120 - rem;
    pad.addAll(List.filled(zeros, 0));
    for (var i = 7; i >= 0; i--) {
      pad.add((bits >> (i * 8)) & 0xff);
    }
    final saveTotal = _total;
    add(pad);
    _total = saveTotal;
    _done = true;
    final sb = StringBuffer();
    for (final v in _h) {
      sb.write(v.toRadixString(16).padLeft(8, '0'));
    }
    return sb.toString();
  }

  static String ofBytes(List<int> data) => (Sha256()..add(data)).close();

  static Future<String> ofFile(File f) async {
    final h = Sha256();
    await for (final chunk in f.openRead()) {
      h.add(chunk);
    }
    return h.close();
  }
}

// =================================================================== manifest
class AiModelFile {
  const AiModelFile(
      {required this.name, required this.sha256, required this.size, required this.url,
       this.role = 'upscale'});
  final String name;
  final String sha256;
  final int size;
  final String url;

  /// d1-photo: 'upscale' (Real-ESRGAN) or 'segment' (U²-Net-p background
  /// mask). A manifest without roles (older server) means 'upscale'.
  final String role;
}

class AiModelInfo {
  const AiModelInfo({
    this.available = false,
    this.reason = 'model_pending',
    this.version = '',
    this.scale = 4,
    this.tile = 144,
    this.pad = 8,
    this.file,
    this.segment,
    this.segSide = 320,
  });
  final bool available;
  final String reason;
  final String version;
  final int scale, tile, pad;

  /// The upscaler (role 'upscale'). [tile] is its FIXED square input side
  /// (144 = 128 useful + 2*8 pad) — the ONNX file accepts nothing else.
  final AiModelFile? file;

  /// d1-photo: optional background-mask model (role 'segment', fixed
  /// [segSide] x [segSide] input). null = background blur is hidden.
  final AiModelFile? segment;
  final int segSide;

  bool get usable => available && file != null;
  bool get segmentUsable => available && segment != null;

  /// Every model file name this manifest lists (the downloader keeps these).
  Set<String> get names => {if (file != null) file!.name, if (segment != null) segment!.name};
  static const none = AiModelInfo();

  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\.onnx$');

  factory AiModelInfo.fromJson(Object? raw) {
    if (raw is! Map) return none;
    int i(Object? v, int d) => v is num ? v.toInt() : int.tryParse('$v') ?? d;
    AiModelFile? file, segment;
    final files = raw['files'];
    if (files is List) {
      for (final f in files) {
        if (f is! Map) continue;
        final name = '${f['name'] ?? ''}';
        final sha = '${f['sha256'] ?? ''}'.toLowerCase();
        final url = '${f['url'] ?? ''}';
        final size = i(f['size'], 0);
        final role = '${f['role'] ?? 'upscale'}';
        if (_name.hasMatch(name) && _sha.hasMatch(sha) && size > 0 &&
            (url.startsWith('https://') || url.startsWith('http://'))) {
          final m = AiModelFile(name: name, sha256: sha, size: size, url: url, role: role);
          if (role == 'upscale') {
            file ??= m;
          } else if (role == 'segment') {
            segment ??= m;
          }
        }
      }
    }
    return AiModelInfo(
      available: raw['available'] == true && file != null,
      reason: '${raw['reason'] ?? ''}',
      version: '${raw['version'] ?? ''}',
      scale: i(raw['scale'], 4).clamp(1, 8),
      tile: i(raw['tile'], 144).clamp(16, 1024),
      pad: i(raw['pad'], 8).clamp(0, 64),
      file: file,
      segment: segment,
      segSide: i(raw['seg_side'], 320).clamp(64, 1024),
    );
  }
}

// =================================================================== download
/// One HTTP GET (optionally from a byte offset). Seam for tests.
class RangeResponse {
  RangeResponse(this.status, this.body, {this.contentRange = '', this.length});
  final int status;
  final Stream<List<int>> body;
  final String contentRange;
  final int? length;
}

abstract class RangeHttp {
  Future<RangeResponse> get(String url, {int from = 0, String? ifRange});
}

class IoRangeHttp implements RangeHttp {
  IoRangeHttp({HttpClient? client}) : _c = client ?? HttpClient();
  final HttpClient _c;
  @override
  Future<RangeResponse> get(String url, {int from = 0, String? ifRange}) async {
    final rq = await _c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (from > 0) {
      rq.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      if (ifRange != null) rq.headers.set(HttpHeaders.ifRangeHeader, ifRange);
    }
    final rs = await rq.close().timeout(const Duration(seconds: 30));
    return RangeResponse(rs.statusCode, rs.timeout(const Duration(seconds: 30)),
        contentRange: rs.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        length: rs.contentLength >= 0 ? rs.contentLength : null);
  }
}

class ModelDownloadFailed implements Exception {
  const ModelDownloadFailed(this.reason);
  final String reason;
  @override
  String toString() => 'ModelDownloadFailed($reason)';
}

/// Downloads the model file into [dir] (app support storage):
///  * `<name>.part` grows while downloading; an interrupted download RESUMES
///    from its length (Range: bytes=N-, If-Range: "<sha256>");
///  * a 200 answer to a Range request (server restarted / other version)
///    starts the file over; 416 means the part is already complete;
///  * the finished file is checked against the manifest sha256 BEFORE it is
///    renamed to `<name>` — a bad file is deleted, never used;
///  * `<name>.ok` records the verified sha256, so later opens are offline and
///    instant (size + marker check, no re-hash).
class ModelDownloader {
  ModelDownloader({required this.http, required this.dir, this.maxAttempts = 3});
  final RangeHttp http;
  final Directory dir;
  final int maxAttempts;

  /// d1-photo: names of the OTHER current model files (e.g. the background
  /// mask model next to the upscaler) — never deleted as "old versions".
  Set<String> keep = const {};

  File _final(AiModelFile f) => File('${dir.path}/${f.name}');
  File _part(AiModelFile f) => File('${dir.path}/${f.name}.part');
  File _ok(AiModelFile f) => File('${dir.path}/${f.name}.ok');

  /// Path of an already verified copy, or null (no network used).
  Future<String?> cached(AiModelFile f) async {
    try {
      final file = _final(f), ok = _ok(f);
      if (!await file.exists() || !await ok.exists()) return null;
      if (await file.length() != f.size) return null;
      if ((await ok.readAsString()).trim() != f.sha256) return null;
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Ensure the verified file exists; returns its path. [onProgress] gets
  /// (bytes so far, total).
  Future<String> ensure(AiModelFile f, {void Function(int, int)? onProgress}) async {
    final hit = await cached(f);
    if (hit != null) return hit;
    await dir.create(recursive: true);
    // an older version of the model is removed (only one kept)
    try {
      await for (final e in dir.list()) {
        final n = e.path.split('/').last;
        if (e is File && n.endsWith('.onnx') && n != f.name && !keep.contains(n)) {
          await e.delete();
        }
        if (e is File && n.endsWith('.onnx.ok') && n != '${f.name}.ok' &&
            !keep.contains(n.substring(0, n.length - 3))) {
          await e.delete();
        }
      }
    } catch (_) {}
    Object? last;
    var restartedForHash = false;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await _fetch(f, onProgress);
        final part = _part(f);
        final sha = await Sha256.ofFile(part);
        if (sha != f.sha256) {
          await part.delete();
          if (restartedForHash) throw const ModelDownloadFailed('sha256');
          restartedForHash = true;
          continue;
        }
        final dst = _final(f);
        if (await dst.exists()) await dst.delete();
        await part.rename(dst.path);
        await _ok(f).writeAsString(f.sha256, flush: true);
        return dst.path;
      } on ModelDownloadFailed {
        rethrow;
      } catch (e) {
        last = e; // network drop: the .part stays, next attempt resumes
      }
    }
    throw ModelDownloadFailed('network: $last');
  }

  Future<void> _fetch(AiModelFile f, void Function(int, int)? onProgress) async {
    final part = _part(f);
    var have = await part.exists() ? await part.length() : 0;
    if (have > f.size) {
      await part.delete();
      have = 0;
    }
    if (have == f.size) return; // complete: verify
    final rs = await http.get(f.url, from: have, ifRange: '"${f.sha256}"');
    IOSink sink;
    if (rs.status == 206 && have > 0) {
      // must continue exactly where we stopped
      final m = RegExp(r'bytes (\d+)-').firstMatch(rs.contentRange);
      if (m == null || int.parse(m.group(1)!) != have) {
        await rs.body.drain<void>();
        await part.delete();
        throw const FormatException('bad Content-Range');
      }
      sink = part.openWrite(mode: FileMode.append);
    } else if (rs.status == 200 || (rs.status == 206 && have == 0)) {
      have = 0;
      sink = part.openWrite(mode: FileMode.write);
    } else if (rs.status == 416) {
      await rs.body.drain<void>();
      // the server says our part already covers the file -> verify it;
      // if it is wrong the hash check restarts from zero
      return;
    } else {
      await rs.body.drain<void>();
      throw ModelDownloadFailed('http ${rs.status}');
    }
    try {
      await for (final chunk in rs.body) {
        sink.add(chunk);
        have += chunk.length;
        if (have > f.size) throw const ModelDownloadFailed('too large');
        onProgress?.call(have, f.size);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (have < f.size) throw const SocketException('connection closed early');
  }
}
