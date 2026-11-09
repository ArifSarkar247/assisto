// cctvplay — remote playback of the PHONE camera's alert clips (owner order
// 9 Nov 14:45, item 3). Server side: backend/core/phonecam_clips_views.py.
//
// Camera phone:
//   * every alert names its ~10 s clip with a random `clip_ref`; the MP4 stays
//     on this phone as before (clip_<ref>.mp4, size-capped, oldest first);
//   * PREVIEW: a few small JPEG frames cut from that MP4 (native
//     MediaMetadataRetriever), packed in our "ACG1" container and SEALED here
//     for the owner's + family viewers' public keys, uploaded (<= 600 KB);
//   * FULL VIDEO on request: the heartbeat names it; the MP4 is sealed the
//     same way (aad assisto-phonecam-video-v1) and uploaded (<= 8 MB) — or
//     "missing" when the size cap already rolled it over.
// Viewer: GET/POST shop/events/<id>/clip/full; the sealed MP4 is opened in an
// isolate with this phone's private key and played from a temp file that is
// deleted when the sheet closes. The server only ever holds ciphertext.
//
// Pure Dart except the two small HTTP helpers.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../cashguard/clip_crypto.dart';
import '../cashguard/guard_box_engine.dart' show encodeContainer, sealClip;
import '../config.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';
import '../shop_api.dart' show DeviceReply, ShopDeviceClient;

const String kVideoAad = 'assisto-phonecam-video-v1';
const String kVideoFormat = 'mp4';
const int kPhoneClipSeconds = 10;
const int kVideoMaxBytes = 8 * 1024 * 1024;

/// A fresh 32-hex-char clip reference (the server's clean_clip_ref accepts it).
String newClipRef([Random? rng]) {
  final r = rng ?? Random.secure();
  return List<String>.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String clipFileName(String ref) => 'clip_$ref.mp4';

/// The ref inside "clip_<ref>.mp4" or null (an older, unnamed clip).
String? refOfClipName(String name) {
  final m = RegExp(r'clip_([0-9a-f]{16,64})\.mp4$').firstMatch(name);
  return m?.group(1);
}

/// The heartbeat's "phonecam.clip" block.
class PhoneClipCfg {
  final bool enabled;
  final List<Map<String, dynamic>> recipients;
  final double fps;
  final int width;
  final int maxKb;
  final int leftToday;
  const PhoneClipCfg({
    this.enabled = false,
    this.recipients = const [],
    this.fps = 1.5,
    this.width = 320,
    this.maxKb = 600,
    this.leftToday = 0,
  });

  static PhoneClipCfg fromJson(Object? raw) {
    if (raw is! Map) return const PhoneClipCfg();
    return PhoneClipCfg(
      enabled: raw['enabled'] == true,
      recipients: [
        for (final r in (raw['recipients'] as List? ?? const []))
          if (r is Map) r.cast<String, dynamic>()
      ],
      fps: ((raw['fps'] as num?) ?? 1.5).toDouble(),
      width: ((raw['width'] as num?) ?? 320).toInt(),
      maxKb: ((raw['max_kb'] as num?) ?? 600).toInt(),
      leftToday: ((raw['left_today'] as num?) ?? 0).toInt(),
    );
  }

  /// Full videos can be sealed whenever someone has a key.
  bool get canSeal => recipients.isNotEmpty;
}

/// One heartbeat video request: {key, kind: event|segment, ref?|start?}.
class VideoRequest {
  final String key;
  final String kind;
  final String ref;
  final int start;
  const VideoRequest(this.key, this.kind, {this.ref = '', this.start = 0});

  static List<VideoRequest> listFrom(Object? raw) => [
        for (final r in (raw as List? ?? const []))
          if (r is Map && r['key'] is String)
            VideoRequest(r['key'] as String, (r['kind'] ?? 'event').toString(),
                ref: (r['ref'] ?? '').toString(), start: ((r['start'] as num?) ?? 0).toInt())
      ];
}

// ---------------------------------------------------------------- sealing
/// The sealed preview: [jpegs] spread evenly over [clipSeconds], dropped to
/// every other frame until it fits [maxKb]. Null when < 2 frames survive.
({Uint8List ct, Map<String, dynamic> meta})? buildPreview(
    List<Uint8List> jpegs, List<Map<String, dynamic>> recipients,
    {double clipSeconds = 10, int maxKb = 600, Random? rng}) {
  var frames = [...jpegs];
  if (frames.length < 2 || recipients.isEmpty) return null;
  while (frames.fold<int>(0, (s, f) => s + f.length) > maxKb * 1024 - 4096 && frames.length > 2) {
    frames = [for (var i = 0; i < frames.length; i += 2) frames[i]];
  }
  if (frames.fold<int>(0, (s, f) => s + f.length) > maxKb * 1024 - 4096) return null;
  final step = clipSeconds / frames.length;
  final fps = double.parse((frames.length / clipSeconds).toStringAsFixed(2));
  final plain = encodeContainer([for (var i = 0; i < frames.length; i++) (i * step, frames[i])], fps);
  final sealed = sealClip(plain, recipients, fps, clipSeconds, rng: rng);
  if ((sealed.meta['wraps'] as Map).isEmpty) return null;
  sealed.meta['frames'] = frames.length;
  return sealed;
}

/// Seal a whole MP4 (or a recording segment) for [recipients].
({Uint8List ct, Map<String, dynamic> meta}) sealVideo(
    Uint8List mp4, List<Map<String, dynamic>> recipients, double durationS,
    {Random? rng}) {
  final r = rng ?? Random.secure();
  Uint8List rnd(int n) => Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  final k = rnd(32), nonce = rnd(12);
  final ct = ChaCha20Poly1305.encrypt(k, nonce, mp4, aad: utf8.encode(kVideoAad));
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
      'format': kVideoFormat,
      'aad': kVideoAad,
      'nonce': base64Encode(nonce),
      'eph_pub': eph.publicKeyB64,
      'eph_key_id': eph.keyId,
      'wraps': wraps,
      'duration_s': double.parse(durationS.toStringAsFixed(2)),
    }
  );
}

/// Open a sealed MP4 with one of [keys]. Throws [ClipOpenError].
Uint8List openVideo({
  required Map<String, dynamic> meta,
  required Uint8List ciphertext,
  required List<IdentityKeyPair> keys,
}) {
  final key = unwrapClipKey(meta: meta, keys: keys);
  final Uint8List nonce;
  try {
    nonce = base64Decode(meta['nonce'] as String);
  } catch (_) {
    throw const ClipOpenError('bad_wrap');
  }
  final plain = ChaCha20Poly1305.decrypt(key, nonce, ciphertext,
      aad: utf8.encode((meta['aad'] ?? kVideoAad).toString()));
  if (plain == null) throw const ClipOpenError('bad_clip');
  return plain;
}

Future<Uint8List> openVideoInIsolate({
  required Map<String, dynamic> meta,
  required Uint8List ciphertext,
  required List<IdentityKeyPair> keys,
}) {
  final rawKeys = [for (final k in keys) (k.privateKey, k.publicKey, k.keyId)];
  final m = Map<String, dynamic>.from(meta);
  return Isolate.run(() => openVideo(
        meta: m,
        ciphertext: ciphertext,
        keys: [for (final r in rawKeys) IdentityKeyPair(r.$1, r.$2, r.$3)],
      ));
}

// ---------------------------------------------------------------- device HTTP
class PhoneCamClipDevice {
  static Map<String, String> _h(ShopDeviceClient d) => {
        'X-Shop-Token': d.token,
        if (d.cameraId != null) 'X-Shop-Camera': '${d.cameraId}',
        'Accept': 'application/json',
      };

  static Future<DeviceReply> _send(Future<http.Response> f, int timeoutS) async {
    try {
      final r = await f.timeout(Duration(seconds: timeoutS));
      Map<String, dynamic> b = {};
      try {
        final j = jsonDecode(r.body);
        if (j is Map<String, dynamic>) b = j;
      } catch (_) {}
      return DeviceReply(r.statusCode, b);
    } catch (_) {
      return const DeviceReply(0, {});
    }
  }

  /// POST shop/phonecam/video — one sealed full video for request [key].
  static Future<DeviceReply> uploadVideo(
      ShopDeviceClient d, String key, Map<String, dynamic> meta, Uint8List blob,
      {http.Client? client}) {
    final c = client ?? http.Client();
    final req = http.MultipartRequest('POST', AppConfig.api('/shop/phonecam/video'))
      ..headers.addAll(_h(d))
      ..fields['key'] = key
      ..fields['meta'] = jsonEncode(meta)
      ..files.add(http.MultipartFile.fromBytes('blob', blob, filename: 'video.bin'));
    return _send(c.send(req).then(http.Response.fromStream), 120);
  }

  /// item 4: POST shop/phonecam/timeline — what this phone has recorded
  /// ({spans, used_mb, cap_mb, state, reason, set_on?}).
  static Future<DeviceReply> timeline(ShopDeviceClient d, Map<String, dynamic> body,
      {http.Client? client}) {
    final c = client ?? http.Client();
    return _send(
        c.post(AppConfig.api('/shop/phonecam/timeline'),
            headers: {..._h(d), 'Content-Type': 'application/json'}, body: jsonEncode(body)),
        20);
  }

  /// The clip is no longer on this phone (rolled over / never recorded).
  static Future<DeviceReply> videoMissing(ShopDeviceClient d, String key,
      {String reason = 'rolled_over', http.Client? client}) {
    final c = client ?? http.Client();
    return _send(
        c.post(AppConfig.api('/shop/phonecam/video'),
            headers: {..._h(d), 'Content-Type': 'application/json'},
            body: jsonEncode({'key': key, 'missing': true, 'reason': reason})),
        20);
  }
}

// ---------------------------------------------------------------- viewer
/// Every server call the viewer's full-video panel makes (tests inject a fake).
abstract class PhoneCamClipSource {
  /// GET shop/events/<id>/clip/full — {status, camera_online, budget, est_mb,
  /// clip_s, keep_h, [url, meta, size, expires_at, sealed_for_you]}.
  Future<Map<String, dynamic>> fullState(int eventId);

  /// POST shop/events/<id>/clip/full — ask the camera phone.
  Future<Map<String, dynamic>> requestFull(int eventId);

  /// The sealed video from its signed link (no auth header).
  Future<Uint8List> download(String url);

  Future<List<IdentityKeyPair>> myKeys();
}

class ApiPhoneCamClipSource implements PhoneCamClipSource {
  final ApiClient api;
  ApiPhoneCamClipSource(this.api);

  @override
  Future<Map<String, dynamic>> fullState(int eventId) =>
      api.getJson('/shop/events/$eventId/clip/full');

  @override
  Future<Map<String, dynamic>> requestFull(int eventId) =>
      api.postJson('/shop/events/$eventId/clip/full', const {});

  @override
  Future<Uint8List> download(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) throw ApiException('Error ${r.statusCode}', r.statusCode);
    if (r.bodyBytes.length > kVideoMaxBytes + 4096) throw ApiException('Error 413', 413);
    return r.bodyBytes;
  }

  @override
  Future<List<IdentityKeyPair>> myKeys() => IdentityVault.instance.ring();
}
