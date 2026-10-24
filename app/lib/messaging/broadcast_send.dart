import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../api.dart';
import '../crypto/e2e.dart';
import '../services/error_report.dart';
import 'outbox.dart';

/// f6 — the REAL broadcast send (it was a showpiece: the compose screen was
/// opened without a sender, so every broadcast ended in "action failed").
///
/// A broadcast is N separate private 1:1 messages: the text is sealed ONCE
/// PER RECIPIENT with that member's own key (the same envelope the 1:1 chat
/// posts to `/circle/<id>/messages`) — recipients never see each other and
/// the server never links them. A member whose phone has not published a key
/// yet gets the message through the persistent outbox (it goes out by itself
/// once their key appears), exactly like a 1:1 chat send.
class BroadcastResult {
  final int sent; // sealed + accepted by the server now
  final int queued; // waiting in the outbox for the member's key
  final int failed;
  const BroadcastResult(this.sent, this.queued, this.failed);
  int get delivered => sent + queued;
}

int _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;

Future<BroadcastResult> sendBroadcastText(
  ApiClient api,
  IdentityKeyPair me,
  List<int> recipientIds,
  String text, {
  List<Map<String, dynamic>> members = const [],
  E2E? e2e,
  Outbox? outbox,
}) async {
  final engine = e2e ?? SoftwareE2E();
  final box = outbox ?? Outbox.instance;
  final keyOf = {
    for (final m in members) _int(m['id']): '${m['public_key'] ?? ''}',
  };
  var sent = 0, queued = 0, failed = 0;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  for (final id in recipientIds) {
    final cmid = 'bc-$stamp-$id';
    try {
      var b64 = keyOf[id] ?? '';
      if (b64.isEmpty) {
        try {
          b64 = '${(await api.getJson('/circle/keys/peer/$id'))['public_key'] ?? ''}';
        } catch (e) {
          reportNonFatal('f6_broadcast_peer_key', e); // -> outbox below
        }
      }
      if (b64.isEmpty) {
        await box.add(OutboxItem(
            id: cmid, chatId: id, text: text, at: DateTime.now()));
        unawaited(box.kick(onlyChat: id));
        queued++;
        continue;
      }
      final ct = engine.encrypt(
          self: me,
          recipientPublicKey: Uint8List.fromList(base64Decode(b64)),
          plaintext: text);
      await api.postJson('/circle/$id/messages', {
        'content_type': 'text',
        'client_msg_id': cmid,
        ...ct.toEnvelopeFields(),
      });
      sent++;
    } catch (e) {
      reportNonFatal('f6_broadcast_send', e);
      failed++;
    }
  }
  return BroadcastResult(sent, queued, failed);
}
