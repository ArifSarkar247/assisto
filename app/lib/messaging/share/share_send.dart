import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../api.dart';
import '../../crypto/e2e.dart';
import '../../crypto/key_service.dart';
import '../../services/error_report.dart';
import '../forward.dart' show ForwardPayload, buildGroupForwardEnvelope;

/// mc-media2 — sending a location / contact card and pushing LIVE location
/// updates. Everything is sealed on this phone with the normal per-recipient
/// E2E (1:1: the peer's key; group: one copy per member with a key); the
/// server only relays ciphertext.
///
/// Thrown when nobody in the chat has a key yet (the caller shows the honest
/// "couldn't send" message; nothing is half-sent).
class ShareNoKeyError implements Exception {
  const ShareNoKeyError();
  @override
  String toString() => 'no recipient keys';
}

Future<Uint8List?> _peerKey(ApiClient api, int memberId) async {
  try {
    final b64 = '${(await api.getJson('/circle/keys/peer/$memberId'))['public_key'] ?? ''}';
    if (b64.isEmpty) return null;
    return Uint8List.fromList(base64Decode(b64));
  } catch (e) {
    reportNonFatal('mc2_peer_key', e);
    return null;
  }
}

Future<List<Map<String, dynamic>>> _roster(ApiClient api, int groupId) async {
  final mem = await api.getJson('/circle/groups/$groupId/members');
  return ((mem['results'] ?? mem['members'] ?? const []) as List)
      .whereType<Map>()
      .map((m) => m.cast<String, dynamic>())
      .toList();
}

/// PURE: the group fan-out for a share (no forward label).
Map<String, dynamic>? buildGroupShareEnvelope({
  required List<Map<String, dynamic>> roster,
  required IdentityKeyPair me,
  required E2E e2e,
  required String contentType,
  required String plaintext,
  required String clientMsgId,
}) {
  final env = buildGroupForwardEnvelope(
      roster: roster,
      me: me,
      e2e: e2e,
      payload: ForwardPayload(plaintext: plaintext, contentType: contentType, hops: 0),
      clientMsgId: clientMsgId);
  if (env == null) return null;
  env.remove('forwarded');
  env.remove('forward_hops');
  return env;
}

/// Send a share message. Returns the server message id.
Future<String> sendShare(
  ApiClient api, {
  required String chatKind, // member | group
  required int chatId,
  required String contentType, // location | contact
  required String plaintext,
  IdentityKeyPair? me,
  E2E? e2e,
  String? clientMsgId,
  Duration keyWait = const Duration(seconds: 3),
}) async {
  final engine = e2e ?? SoftwareE2E();
  final self = me ?? await KeyService.instance.identity();
  final cmid = clientMsgId ?? 'mc2-${DateTime.now().microsecondsSinceEpoch}';
  if (chatKind == 'group') {
    Map<String, dynamic>? env;
    for (var i = 0; i < 3 && env == null; i++) {
      if (i > 0) await Future<void>.delayed(keyWait);
      env = buildGroupShareEnvelope(
          roster: await _roster(api, chatId),
          me: self,
          e2e: engine,
          contentType: contentType,
          plaintext: plaintext,
          clientMsgId: cmid);
    }
    if (env == null) throw const ShareNoKeyError();
    final r = await api.postJson('/circle/groups/$chatId/messages', env);
    return '${r['id'] ?? ''}';
  }
  final peer = await _peerKey(api, chatId);
  if (peer == null) throw const ShareNoKeyError();
  final ct = engine.encrypt(self: self, recipientPublicKey: peer, plaintext: plaintext);
  final r = await api.postJson('/circle/$chatId/messages', {
    'content_type': contentType,
    'client_msg_id': cmid,
    ...ct.toEnvelopeFields(),
  });
  return '${r['id'] ?? ''}';
}

/// Replace a live location message's ciphertext with [plaintext] (newest
/// point / stopped). Throws [ApiException] (404/403/409 = the message can't
/// be updated any more: deleted, left, past 8 h).
Future<void> pushLiveUpdate(
  ApiClient api, {
  required String chatKind,
  required int chatId,
  required String messageId,
  required String plaintext,
  IdentityKeyPair? me,
  E2E? e2e,
}) async {
  final engine = e2e ?? SoftwareE2E();
  final self = me ?? await KeyService.instance.identity();
  if (chatKind == 'group') {
    final env = buildGroupShareEnvelope(
        roster: await _roster(api, chatId),
        me: self,
        e2e: engine,
        contentType: 'location',
        plaintext: plaintext,
        clientMsgId: 'live');
    if (env == null) throw const ShareNoKeyError();
    await api.postJson('/circle/live/$messageId', {
      'per_recipient': env['per_recipient'],
      'recipient_ids': env['recipient_ids'],
      'scheme': env['scheme'],
      'sender_key_id': env['sender_key_id'],
    });
    return;
  }
  final peer = await _peerKey(api, chatId);
  if (peer == null) throw const ShareNoKeyError();
  final ct = engine.encrypt(self: self, recipientPublicKey: peer, plaintext: plaintext);
  await api.postJson('/circle/live/$messageId', ct.toEnvelopeFields());
}
