import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/key_service.dart';
import '../l10n/app_localizations.dart';
import '../services/error_report.dart';
import 'outbox.dart';

/// md2 — WhatsApp forward from ANY My Circle chat to ANY chat: a 1:1 member
/// or a group (1:1 → group, group → 1:1, group → group).
///
/// Media is NEVER re-uploaded: the forward is a new E2E message whose
/// plaintext is the SAME media descriptor (blob ref, file key, nonce,
/// sha256…), sealed again for each new recipient; the server links the blob
/// to the new chat through the message's blob_ref (core/circle_blobs).
class ForwardTarget {
  final String kind; // member | group
  final int id;
  final String name;
  final String publicKey; // members only ('' = not published yet)
  const ForwardTarget(
      {required this.kind, required this.id, required this.name, this.publicKey = ''});
  bool get isGroup => kind == 'group';
}

/// What is forwarded: the text, or a media descriptor (encoded) + its blob.
class ForwardPayload {
  final String plaintext;
  final String contentType; // text | photo | voice | document
  final String? blobRef;
  final int hops; // the NEW hop count (source hops + 1)
  const ForwardPayload(
      {required this.plaintext, this.contentType = 'text', this.blobRef, this.hops = 1});
}

int _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;

/// Accepted members + the groups I may post in.
Future<List<ForwardTarget>> loadForwardTargets(ApiClient api) async {
  final out = <ForwardTarget>[];
  Object? err;
  try {
    final r = await api.getJson('/circle/members');
    for (final x in ((r['results'] ?? r['members'] ?? const []) as List).whereType<Map>()) {
      // e2-keys: every accepted member — a keyless one gets the forward
      // through the outbox, never a dead end.
      if ('${x['state'] ?? 'accepted'}' != 'accepted') continue;
      out.add(ForwardTarget(
          kind: 'member',
          id: _int(x['id']),
          name: '${x['name'] ?? ''}',
          publicKey: '${x['public_key'] ?? ''}'));
    }
  } catch (e) {
    err = e;
  }
  try {
    final r = await api.getJson('/circle/groups');
    for (final g in ((r['results'] ?? r['groups'] ?? const []) as List).whereType<Map>()) {
      if (g['announcements_only'] == true && '${g['my_role'] ?? 'member'}' != 'admin') {
        continue; // could not post there
      }
      out.add(ForwardTarget(kind: 'group', id: _int(g['id']), name: '${g['name'] ?? ''}'));
    }
  } catch (e) {
    err ??= e;
  }
  if (out.isEmpty && err != null) throw err;
  return out;
}

/// The "Forward to…" sheet: people first, then groups. null = cancelled.
Future<ForwardTarget?> pickForwardTarget(
    BuildContext context, List<ForwardTarget> targets) {
  final t = AppLocalizations.of(context);
  final people = targets.where((x) => !x.isGroup).toList();
  final groups = targets.where((x) => x.isGroup).toList();
  Widget tile(BuildContext ctx, ForwardTarget x) => ListTile(
        key: Key('md2-fwd-${x.kind}-${x.id}'),
        leading: CircleAvatar(
            child: x.isGroup
                ? const Icon(Icons.groups_outlined)
                : Text(x.name.isEmpty ? '?' : x.name.characters.first.toUpperCase())),
        title: Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.pop(ctx, x),
      );
  Widget header(BuildContext ctx, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(s,
            style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
      );
  return showModalBottomSheet<ForwardTarget>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(t.c3ForwardTo, style: Theme.of(ctx).textTheme.titleMedium)),
          if (people.isNotEmpty) header(ctx, t.contactsTitle),
          for (final x in people) tile(ctx, x),
          if (groups.isNotEmpty) header(ctx, t.msgrChipGroups),
          for (final x in groups) tile(ctx, x),
        ]),
      ),
    ),
  );
}

/// PURE: the group envelope for a forward — the payload sealed once per
/// recipient with a key (per_recipient fan-out, like every group send).
/// null = nobody in the roster has a key yet.
Map<String, dynamic>? buildGroupForwardEnvelope({
  required List<Map<String, dynamic>> roster,
  required IdentityKeyPair me,
  required E2E e2e,
  required ForwardPayload payload,
  required String clientMsgId,
  String? myMemberId,
}) {
  final per = <String, dynamic>{};
  final ids = <int>[];
  for (final m in roster) {
    if (m['is_self'] == true) continue;
    final id = _int(m['id'] ?? m['member_id']);
    if (id == 0 || (myMemberId != null && '$id' == myMemberId)) continue;
    final pk = '${m['public_key'] ?? ''}';
    if (pk.isEmpty || pk == me.publicKeyB64) continue;
    try {
      final ct = e2e.encrypt(
          self: me,
          recipientPublicKey: Uint8List.fromList(base64Decode(pk)),
          plaintext: payload.plaintext);
      per['$id'] = {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64};
      ids.add(id);
    } catch (e) {
      reportNonFatal('md2_fwd_group_key', e); // that member is asked silently
    }
  }
  if (per.isEmpty) return null;
  return {
    'content_type': payload.contentType,
    if (payload.blobRef != null && payload.blobRef!.isNotEmpty) 'blob_ref': payload.blobRef,
    'recipient_ids': ids,
    'per_recipient': per,
    'sender_key_id': me.keyId,
    'scheme': e2e.scheme,
    'client_msg_id': clientMsgId,
    'forwarded': true,
    'forward_hops': payload.hops,
  };
}

/// Forward into a group. Keys are re-read; keyless members are asked
/// silently and waited for briefly (never a key error). Returns the server
/// message id; throws when it could not be sent (caller: showActionFailed).
Future<String> forwardToGroup(ApiClient api, IdentityKeyPair me, int groupId,
    ForwardPayload payload,
    {E2E? e2e, String? clientMsgId, Duration wait = const Duration(seconds: 3)}) async {
  final engine = e2e ?? SoftwareE2E();
  final cmid = clientMsgId ?? 'fwd-${DateTime.now().microsecondsSinceEpoch}';
  Map<String, dynamic>? env;
  for (var i = 0; i < 4; i++) {
    final mem = await api.getJson('/circle/groups/$groupId/members');
    final roster = ((mem['results'] ?? mem['members'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    env = buildGroupForwardEnvelope(
        roster: roster, me: me, e2e: engine, payload: payload, clientMsgId: cmid);
    if (env != null) break;
    for (final m in roster.where((m) => m['is_self'] != true && '${m['public_key'] ?? ''}'.isEmpty)) {
      if (m['user_id'] == null) continue;
      unawaited(api.postJson('/circle/keys/request', {'user_id': m['user_id']}).then((_) {},
          onError: (Object e) => reportNonFatal('md2_fwd_key_request', e)));
    }
    KeyService.instance.log.add('md2 fwd group $groupId: waiting for keys');
    if (i < 3) await Future<void>.delayed(wait);
  }
  if (env == null) throw StateError('no recipient keys');
  final r = await api.postJson('/circle/groups/$groupId/messages', env);
  return '${r['id'] ?? ''}';
}

/// Forward to a 1:1 member: sealed for their key, or (no key published
/// yet) queued in the persistent outbox and sent by itself later.
Future<void> forwardToMember(ApiClient api, IdentityKeyPair me, ForwardTarget target,
    ForwardPayload payload, {E2E? e2e, String? clientMsgId}) async {
  final engine = e2e ?? SoftwareE2E();
  final cmid = clientMsgId ?? 'fwd-${DateTime.now().microsecondsSinceEpoch}';
  var b64 = target.publicKey;
  if (b64.isEmpty) {
    try {
      b64 = '${(await api.getJson('/circle/keys/peer/${target.id}'))['public_key'] ?? ''}';
    } catch (e) {
      reportNonFatal('md2_fwd_peer_key', e); // -> outbox below
    }
  }
  if (b64.isEmpty) {
    await Outbox.instance.add(OutboxItem(
        id: cmid,
        chatId: target.id,
        text: payload.plaintext,
        at: DateTime.now(),
        forwarded: true,
        forwardHops: payload.hops,
        contentType: payload.contentType,
        blobRef: payload.blobRef));
    unawaited(Outbox.instance.kick(onlyChat: target.id));
    return;
  }
  final ct = engine.encrypt(
      self: me,
      recipientPublicKey: Uint8List.fromList(base64Decode(b64)),
      plaintext: payload.plaintext);
  await api.postJson('/circle/${target.id}/messages', {
    'content_type': payload.contentType,
    if (payload.blobRef != null && payload.blobRef!.isNotEmpty) 'blob_ref': payload.blobRef,
    'client_msg_id': cmid,
    'forwarded': true,
    'forward_hops': payload.hops,
    ...ct.toEnvelopeFields(),
  });
}
