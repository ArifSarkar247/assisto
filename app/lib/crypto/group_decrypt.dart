import 'dart:convert';
import 'dart:typed_data';

import 'e2e.dart';
import 'ring_decrypt.dart';

/// e2e-groups — open a GROUP envelope with every key this phone has.
///
/// A group message is sealed PER MEMBER: `per_recipient` maps a member id
/// (CircleGroupMember id, the roster's `member_id`) to {ciphertext, nonce}
/// sealed between the sender's key and that member's key. So:
///   * someone else's message: MY entry x the sender's keys (live + history);
///   * my own sent message: ANY recipient's entry x that recipient's keys
///     (the box is symmetric);
///   * a replacement `copy` (re-shared to my current key by another member's
///     phone after my key changed): the copy x the uploader's keys.
/// [roster] rows are the server's `circle/groups/<id>/members` rows
/// ({member_id, user_id, public_key, key_history}). Never throws.
class GroupDecrypt {
  GroupDecrypt._();

  static Uint8List? _b64(Object? s) {
    final v = '${s ?? ''}';
    if (v.isEmpty) return null;
    try {
      final k = base64Decode(v);
      return k.length == 32 ? Uint8List.fromList(k) : null;
    } catch (_) {
      return null;
    }
  }

  /// Live key first, then the server's earlier keys of that row.
  static List<Uint8List> rowKeys(Map<String, dynamic>? row) {
    if (row == null) return const [];
    return RingDecrypt.keys([
      _b64(row['public_key']),
      for (final h in (row['key_history'] as List? ?? const []))
        _b64(h is Map ? h['public_key'] : h),
    ]);
  }

  static Map<String, dynamic>? _byUser(
      List<Map<String, dynamic>> roster, Object? uid) {
    final u = '${uid ?? ''}';
    if (u.isEmpty) return null;
    for (final r in roster) {
      if ('${r['user_id'] ?? ''}' == u) return r;
    }
    return null;
  }

  static Map<String, dynamic>? _byMember(
      List<Map<String, dynamic>> roster, String mid) {
    for (final r in roster) {
      if ('${r['member_id'] ?? r['id'] ?? ''}' == mid) return r;
    }
    return null;
  }

  /// The ORIGINAL ciphertext (my entry / any entry of my own message).
  static String? openOriginal(
    Map<String, dynamic> env, {
    required List<IdentityKeyPair> ring,
    required String myMemberId,
    required String myUserId,
    required List<Map<String, dynamic>> roster,
  }) {
    try {
      if (ring.isEmpty) return null;
      final scheme = '${env['scheme'] ?? kFallbackScheme}';
      final skid = '${env['sender_key_id'] ?? ''}';
      final per = (env['per_recipient'] as Map?)?.cast<String, dynamic>();
      final mine = env['mine'] == true ||
          (myUserId.isNotEmpty && '${env['sender_id'] ?? ''}' == myUserId);
      if (mine && per != null && per.isNotEmpty) {
        for (final e in per.entries) {
          if (e.value is! Map) continue;
          final keys = rowKeys(_byMember(roster, e.key));
          if (keys.isEmpty) continue;
          final b = (e.value as Map).cast<String, dynamic>();
          final pt = RingDecrypt.open(
              ring: ring,
              peerKeys: keys,
              ct: Ciphertext(
                  scheme: scheme,
                  ciphertextB64: '${b['ciphertext'] ?? ''}',
                  nonceB64: '${b['nonce'] ?? ''}',
                  senderKeyId: skid));
          if (pt != null) return pt;
        }
        return null;
      }
      Map<String, dynamic>? blob;
      if (per != null && per.isNotEmpty) {
        blob = (per[myMemberId] as Map?)?.cast<String, dynamic>();
      } else if ('${env['ciphertext'] ?? ''}'.isNotEmpty) {
        blob = {'ciphertext': env['ciphertext'], 'nonce': env['nonce']};
      }
      if (blob == null || '${blob['ciphertext'] ?? ''}'.isEmpty) return null;
      final keys = rowKeys(_byUser(roster, env['sender_id']));
      if (keys.isEmpty) return null;
      return RingDecrypt.open(
          ring: ring,
          peerKeys: keys,
          // someone else's message: never hint with THEIR key id
          myKeyId: '',
          ct: Ciphertext(
              scheme: scheme,
              ciphertextB64: '${blob['ciphertext']}',
              nonceB64: '${blob['nonce'] ?? ''}',
              senderKeyId: skid));
    } catch (_) {
      return null;
    }
  }

  /// The re-shared replacement `copy` for one of my keys, if any.
  static String? openCopy(
    Map<String, dynamic> env, {
    required List<IdentityKeyPair> ring,
    required List<Map<String, dynamic>> roster,
  }) {
    try {
      final copy = env['copy'];
      if (copy is! Map || '${copy['ciphertext'] ?? ''}'.isEmpty) return null;
      final keys = rowKeys(_byUser(roster, copy['by']));
      if (keys.isEmpty || ring.isEmpty) return null;
      return RingDecrypt.open(
          ring: ring,
          peerKeys: keys,
          myKeyId: '${copy['key_id'] ?? ''}',
          ct: Ciphertext(
              scheme: '${copy['scheme'] ?? kFallbackScheme}',
              ciphertextB64: '${copy['ciphertext']}',
              nonceB64: '${copy['nonce'] ?? ''}',
              senderKeyId: '${copy['sender_key_id'] ?? ''}'));
    } catch (_) {
      return null;
    }
  }

  /// The original first, then the copy. Null when neither opens here.
  static String? open(
    Map<String, dynamic> env, {
    required List<IdentityKeyPair> ring,
    required String myMemberId,
    required String myUserId,
    required List<Map<String, dynamic>> roster,
  }) =>
      openOriginal(env,
          ring: ring,
          myMemberId: myMemberId,
          myUserId: myUserId,
          roster: roster) ??
      openCopy(env, ring: ring, roster: roster);
}
