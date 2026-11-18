import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'e2e.dart';
import 'identity_vault.dart';

/// circle-extras (board row 50) — LINK A SECOND PHONE by QR / 8-character
/// code, WhatsApp style (server side + full design: backend/core/
/// device_link.py).
///
///   MAIN phone  : start → shows QR + "ABCD-EFGH" → sees "Link Pixel 7?
///                 123 456" → seals its WHOLE key ring to the new phone's
///                 one-time key ON THE PHONE → approve.
///   NEW phone   : (sign-in page → "Link to my main phone") makes a one-time
///                 X25519 key, scans the QR or types the code → claim → shows
///                 the same 6 digits → polls → gets its OWN sign-in session +
///                 the sealed ring → opens it → the main phone's key becomes
///                 this phone's key → every message opens on both phones.
///
/// The server only relays bytes it cannot open. Pure + testable: the HTTP
/// calls are injected ([LinkGet] / [LinkPost]).
typedef LinkGet = Future<Map<String, dynamic>> Function(String path);

/// Must return the parsed body with `_status` (like ApiClient.postJsonRaw).
typedef LinkPost = Future<Map<String, dynamic>> Function(
    String path, Map<String, dynamic> body);

class DeviceLinkCrypto {
  DeviceLinkCrypto._();

  static const _info = 'assisto-devlink-v1';
  static const qrPrefix = 'assisto-link:1:';

  static Uint8List _key(Uint8List shared, Uint8List epk, Uint8List rpk) =>
      Hkdf.derive(shared,
          Uint8List.fromList([...utf8.encode(_info), ...epk, ...rpk]), 32);

  /// The ring JSON (same shape as the PIN backup): current first.
  static String ringJson(List<IdentityKeyPair> ring) => jsonEncode({
        'v': 1,
        'current': ring.isEmpty ? '' : ring.first.keyId,
        'keys': [for (final k in ring) jsonDecode(IdentityVault.encodeKey(k))],
      });

  /// Seal [ring] to the new phone's one-time public key.
  static Map<String, String> seal(List<IdentityKeyPair> ring, Uint8List newPhonePub,
      {Random? rng}) {
    final e2e = SoftwareE2E(rng);
    final eph = e2e.generateIdentity();
    final shared = X25519.scalarMult(eph.privateKey, newPhonePub);
    final key = _key(shared, eph.publicKey, newPhonePub);
    final r = rng ?? Random.secure();
    final nonce = Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
    final ct = ChaCha20Poly1305.encrypt(
        key, nonce, Uint8List.fromList(utf8.encode(ringJson(ring))),
        aad: utf8.encode(_info));
    return {
      'epk': base64Encode(eph.publicKey),
      'nonce': base64Encode(nonce),
      'ct': base64Encode(ct),
    };
  }

  /// (current, keys) or null on a wrong key / tamper.
  static (IdentityKeyPair, List<IdentityKeyPair>)? open(
      Map<String, dynamic> sealed, IdentityKeyPair mine) {
    try {
      final epk = base64Decode('${sealed['epk']}');
      final shared = X25519.scalarMult(mine.privateKey, epk);
      final key = _key(shared, epk, mine.publicKey);
      final pt = ChaCha20Poly1305.decrypt(key, base64Decode('${sealed['nonce']}'),
          base64Decode('${sealed['ct']}'),
          aad: utf8.encode(_info));
      if (pt == null) return null;
      final j = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      final keys = <IdentityKeyPair>[];
      for (final e in (j['keys'] as List? ?? const [])) {
        final k = IdentityVault.decodeKey(jsonEncode(e));
        if (k != null) keys.add(k);
      }
      if (keys.isEmpty) return null;
      final cur = keys.where((k) => k.keyId == '${j['current'] ?? ''}');
      return (cur.isEmpty ? keys.first : cur.first, keys);
    } catch (_) {
      return null;
    }
  }

  /// What the user typed or the camera read → what the server matches.
  static String normalise(String raw) {
    final s = raw.trim();
    if (s.startsWith(qrPrefix)) return s;
    final up = s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return up.length == 8 ? '${up.substring(0, 4)}-${up.substring(4)}' : s;
  }

  /// A scanned QR is ours (anything else: "This is not an Assisto link code").
  static bool isOurQr(String raw) => raw.trim().startsWith(qrPrefix);

  /// A typed code looks complete (8 letters/digits, dash optional).
  static bool codeComplete(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '').length == 8;

  /// The 6 digits BOTH screens show, computed on each phone from the new
  /// phone's one-time public key (never trusted from the server: a swapped
  /// key gives different digits). Mirrors backend device_link.verify_digits.
  static String verifyDigits(String pubB64) {
    final h = Sha256.hash(utf8.encode('assisto-link-verify:$pubB64'));
    var v = 0;
    for (var i = 0; i < 6; i++) {
      v = (v << 8) | h[i];
    }
    return (v % 1000000).toString().padLeft(6, '0');
  }

  /// "123456" → "123 456" (readable on both screens).
  static String spaced(String digits) => digits.length == 6
      ? '${digits.substring(0, 3)} ${digits.substring(3)}'
      : digits;
}

/// NEW-phone side state.
enum LinkClaimOutcome { waiting, approved, rejected, expired, failed }

class LinkClaim {
  LinkClaim(this.pair, this.poll, this.verify);
  final int pair;
  final String poll;
  final String verify;
}

class LinkResult {
  const LinkResult(this.outcome, {this.token, this.user, this.ringSize = 0, this.message});
  final LinkClaimOutcome outcome;
  final String? token;
  final Map<String, dynamic>? user;
  final int ringSize;
  final String? message;
}

/// The new phone's half of the protocol.
class NewPhoneLink {
  NewPhoneLink({required this.post, IdentityVault? vault, Random? rng})
      : _vault = vault ?? IdentityVault.instance,
        mine = SoftwareE2E(rng).generateIdentity();

  final LinkPost post;
  final IdentityVault _vault;

  /// One-time key (memory only; never stored, never sent except the PUBLIC half).
  final IdentityKeyPair mine;
  LinkClaim? claim;

  /// Claim a code / QR. Returns null + [error] (the server's own bn/en line).
  String? error;
  Future<LinkClaim?> claimCode(String raw, {String name = ''}) async {
    error = null;
    final r = await post('/e2/link/claim', {
      'code': DeviceLinkCrypto.normalise(raw),
      'eph_pub': mine.publicKeyB64,
      'platform': 'android',
      if (name.isNotEmpty) 'name': name,
    });
    final st = (r['_status'] as num?)?.toInt() ?? 0;
    if (st != 200 || r['pair'] == null) {
      error = '${r['detail'] ?? r['message'] ?? ''}';
      return null;
    }
    return claim = LinkClaim((r['pair'] as num).toInt(), '${r['poll']}',
        DeviceLinkCrypto.verifyDigits(mine.publicKeyB64));
  }

  /// One poll. On approval the ring is opened and ADOPTED (this phone's key
  /// becomes the main phone's) before the session is handed back.
  Future<LinkResult> pollOnce() async {
    final c = claim;
    if (c == null) return const LinkResult(LinkClaimOutcome.failed);
    Map<String, dynamic> r;
    try {
      r = await post('/e2/link/poll', {'pair': c.pair, 'poll': c.poll});
    } catch (_) {
      return const LinkResult(LinkClaimOutcome.waiting); // offline: keep trying
    }
    final st = (r['_status'] as num?)?.toInt() ?? 0;
    final state = '${r['state'] ?? ''}';
    if (st == 410 || state == 'expired') return const LinkResult(LinkClaimOutcome.expired);
    if (state == 'rejected') return const LinkResult(LinkClaimOutcome.rejected);
    if (state == 'waiting') return const LinkResult(LinkClaimOutcome.waiting);
    if (state != 'approved' || r['token'] == null || r['user'] is! Map) {
      return const LinkResult(LinkClaimOutcome.failed);
    }
    final sealed = r['sealed'];
    final opened = sealed is Map ? DeviceLinkCrypto.open(sealed.cast<String, dynamic>(), mine) : null;
    if (opened == null) return const LinkResult(LinkClaimOutcome.failed);
    final n = await _vault.adoptLinked(opened.$1, opened.$2);
    if (n == 0) return const LinkResult(LinkClaimOutcome.failed);
    return LinkResult(LinkClaimOutcome.approved,
        token: '${r['token']}',
        user: (r['user'] as Map).cast<String, dynamic>(),
        ringSize: n);
  }
}

/// MAIN-phone side.
class MainPhoneLink {
  MainPhoneLink({required this.get, required this.postJson, IdentityVault? vault})
      : _vault = vault ?? IdentityVault.instance;

  final LinkGet get;

  /// Throws on HTTP errors (ApiClient.postJson).
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) postJson;
  final IdentityVault _vault;

  Future<Map<String, dynamic>> start() => postJson('/e2/link/start', const {});

  Future<Map<String, dynamic>> status() => get('/e2/link/status');

  /// The 6 digits for the confirm dialog, computed HERE from the new
  /// phone's public key in [status] (null when not claimed yet).
  static String? verifyOf(Map<String, dynamic> status) {
    final pub = '${status['eph_pub'] ?? ''}';
    return pub.isEmpty ? null : DeviceLinkCrypto.verifyDigits(pub);
  }

  /// Seal this phone's whole ring to the new phone's one-time key (from the
  /// SAME status answer the user confirmed) and approve.
  Future<bool> approve(int pair, Map<String, dynamic> confirmed) async {
    final pub = '${confirmed['eph_pub'] ?? ''}';
    if (confirmed['state'] != 'claimed' || pub.isEmpty) return false;
    await _vault.get(); // make sure the current key is loaded first
    final ring = await _vault.ring();
    if (ring.isEmpty) return false;
    final sealed = DeviceLinkCrypto.seal(ring, base64Decode(pub));
    await postJson('/e2/link/approve', {'pair': pair, 'sealed': sealed});
    return true;
  }

  Future<void> reject(int pair) =>
      postJson('/e2/link/approve', {'pair': pair, 'reject': true});
}
