import 'dart:convert';
import 'dart:typed_data';

import 'e2e.dart';

/// e2e-recover — open a 1:1 envelope with EVERY key this phone has:
/// my key ring (current + earlier private keys) x the peer's keys (live +
/// history). The box is symmetric, so the same pair key opens the peer's
/// messages AND my own sent ones (owner bug 24 Oct: after a reinstall both
/// showed "cannot be decrypted").
///
/// One X25519 per (my key, peer key) pair is cached (LRU), so a 500-message
/// history costs a few scalar multiplications, not 500.
class RingDecrypt {
  RingDecrypt._();

  static final SoftwareE2E _e2e = SoftwareE2E();
  static final Map<String, Uint8List> _pairKeys = <String, Uint8List>{};
  static const _cacheMax = 64;

  static Uint8List _pair(IdentityKeyPair me, Uint8List peer) {
    final id = '${me.keyId}|${base64Encode(peer)}';
    final have = _pairKeys.remove(id);
    if (have != null) {
      _pairKeys[id] = have; // LRU touch
      return have;
    }
    final k = _e2e.pairKey(me, peer);
    _pairKeys[id] = k;
    if (_pairKeys.length > _cacheMax) _pairKeys.remove(_pairKeys.keys.first);
    return k;
  }

  /// The plaintext, or null when no key of this phone opens it. The key
  /// whose id matches [ct.senderKeyId] (my own sent message) or [myKeyId]
  /// (a replacement copy addressed to one of my keys) is tried first.
  static String? open({
    required List<IdentityKeyPair> ring,
    required List<Uint8List> peerKeys,
    required Ciphertext ct,
    String? myKeyId,
  }) {
    if (ring.isEmpty || peerKeys.isEmpty) return null;
    final hint = myKeyId ?? ct.senderKeyId;
    final mine = [
      ...ring.where((k) => k.keyId == hint),
      ...ring.where((k) => k.keyId != hint),
    ];
    for (final me in mine) {
      for (final peer in peerKeys) {
        if (peer.length != 32) continue;
        try {
          final pt = _e2e.openWithKey(_pair(me, peer), ct);
          if (pt != null) return pt;
        } catch (_) {}
      }
    }
    return null;
  }

  /// A relayed 1:1 envelope: the ORIGINAL ciphertext first (my ring x the
  /// peer's keys), then the peer's re-shared replacement `copy` for one of
  /// my keys (e2e-recover). Null when neither opens on this phone.
  static String? openEnvelope(
    Map<String, dynamic> env, {
    required List<IdentityKeyPair> ring,
    required List<Uint8List> peerKeys,
  }) {
    String? pt;
    final cipher = '${env['ciphertext'] ?? ''}';
    if (cipher.isNotEmpty) {
      pt = open(
        ring: ring,
        peerKeys: peerKeys,
        ct: Ciphertext(
          scheme: '${env['scheme'] ?? kFallbackScheme}',
          ciphertextB64: cipher,
          nonceB64: '${env['nonce'] ?? ''}',
          senderKeyId: '${env['sender_key_id'] ?? ''}',
        ),
      );
    }
    final copy = env['copy'];
    if (pt == null && copy is Map && '${copy['ciphertext'] ?? ''}'.isNotEmpty) {
      pt = open(
        ring: ring,
        peerKeys: peerKeys,
        myKeyId: '${copy['key_id'] ?? ''}',
        ct: Ciphertext(
          scheme: '${copy['scheme'] ?? kFallbackScheme}',
          ciphertextB64: '${copy['ciphertext'] ?? ''}',
          nonceB64: '${copy['nonce'] ?? ''}',
          senderKeyId: '${copy['sender_key_id'] ?? ''}',
        ),
      );
    }
    return pt;
  }

  /// Distinct non-empty keys, order kept (live key first).
  static List<Uint8List> keys(Iterable<Uint8List?> ks) {
    final out = <Uint8List>[];
    final seen = <String>{};
    for (final k in ks) {
      if (k == null || k.length != 32) continue;
      if (seen.add(base64Encode(k))) out.add(k);
    }
    return out;
  }

  /// TESTS: drop cached pair keys.
  static void resetForTests() => _pairKeys.clear();
}
