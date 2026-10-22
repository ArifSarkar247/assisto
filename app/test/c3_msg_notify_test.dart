// c3-msg — notification model builder (5-message window, hidden-content
// mode), MessagingStyle details (inline reply + mark read), and the inline
// reply / mark-read handler with a fake backend + real on-device crypto.
import 'dart:convert';
import 'dart:typed_data';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _amina = _e2e.generateIdentity();
final _chaya = _e2e.generateIdentity();
final _t = lookupAppLocalizations(const Locale('en'));

Map<String, dynamic> _msg(int id, String text,
    {bool mine = false, IdentityKeyPair? from, IdentityKeyPair? to, String name = 'Amina'}) {
  final f = from ?? (mine ? _me : _amina);
  final r = to ?? (mine ? _amina : _me);
  final ct = _e2e.encrypt(self: f, recipientPublicKey: r.publicKey, plaintext: text);
  return {
    'id': id,
    'sender_id': mine ? 9 : 1,
    'mine': mine,
    'sender_name': mine ? 'Me' : name,
    'content_type': 'text',
    'ciphertext': ct.ciphertextB64,
    'nonce': ct.nonceB64,
    'sender_key_id': ct.senderKeyId,
    'scheme': ct.scheme,
    'peer_public_key': base64Encode((mine ? r : f).publicKey),
    'deleted': '',
    'created_at': DateTime(2026, 10, 22, 10, id).toUtc().toIso8601String(),
  };
}

Map<String, dynamic> _pull(List<Map<String, dynamic>> msgs,
        {String kind = 'member', int unseen = 0, String title = 'Amina'}) =>
    {
      'chat': {
        'kind': kind,
        'id': 12,
        'title': title,
        'is_group': kind == 'group',
        'peer_public_key': base64Encode(_amina.publicKey),
      },
      'me': {'id': 9, 'name': 'Me'},
      'unseen': unseen == 0 ? msgs.where((m) => m['mine'] != true).length : unseen,
      'messages': msgs,
    };

class _Backend implements MsgBackend {
  Map<String, dynamic> pullResp;
  _Backend(this.pullResp);
  final sent = <Map<String, dynamic>>[];
  final seenCalls = <String>[];
  bool failSend = false;
  List<Map<String, dynamic>> roster = const [];

  @override
  Future<Map<String, dynamic>> pull(String kind, int id, {int limit = kMsgWindow}) async =>
      pullResp;
  @override
  Future<void> seen(String kind, int id) async => seenAdd('$kind:$id');
  void seenAdd(String k) => seenCalls.add(k);
  @override
  Future<Map<String, dynamic>> send(String kind, int id, Map<String, dynamic> env) async {
    if (failSend) throw StateError('offline');
    sent.add({'kind': kind, 'id': id, ...env});
    return {'ok': true};
  }

  @override
  Future<List<Map<String, dynamic>>> groupRoster(int id) async => roster;
}

class _Sink implements MsgNotifSink {
  final shown = <MsgNotifModel>[];
  final cancelled = <String>[];
  @override
  Future<void> show(MsgNotifModel m, AppLocalizations t, {bool silent = false}) async =>
      shown.add(m);
  @override
  Future<void> cancel(String kind, int id) async => cancelled.add('$kind:$id');
}

void main() {
  final dec = e2eDecryptor(_me, e2e: _e2e);

  group('model builder', () {
    test('latest 5 of 7, oldest → newest, decrypted on device', () {
      final msgs = [for (var i = 1; i <= 7; i++) _msg(i, 'm$i')];
      final m = buildMsgNotifModel(_pull(msgs), decrypt: dec, hide: false, t: _t, lang: 'en');
      expect(m.lines.map((l) => l.text).toList(), ['m3', 'm4', 'm5', 'm6', 'm7']);
      expect(m.unseen, 7);
      expect(m.lines.first.sender, 'Amina');
      expect(m.isGroup, isFalse);
      expect(m.tag, 'c3chat:member:12');
    });

    test('my inline reply shows as "You"', () {
      final m = buildMsgNotifModel(
          _pull([_msg(1, 'hi'), _msg(2, 'on my way', mine: true)]),
          decrypt: dec, hide: false, t: _t, lang: 'en');
      expect(m.lines.last.text, 'on my way');
      expect(m.lines.last.sender, 'You');
      expect(m.lines.last.mine, isTrue);
    });

    test('hidden-content mode: no text at all, just "N new messages"', () {
      final msgs = [for (var i = 1; i <= 3; i++) _msg(i, 'secret $i')];
      final m = buildMsgNotifModel(_pull(msgs), decrypt: dec, hide: true, t: _t, lang: 'en');
      expect(m.hidden, isTrue);
      expect(m.lines, hasLength(1));
      expect(m.lines.single.text, '3 new messages');
      expect(m.lines.any((l) => l.text.contains('secret')), isFalse);
    });

    test('undecryptable → "New message" (never ciphertext)', () {
      final bad = _msg(1, 'x', from: _chaya, to: _me)..['peer_public_key'] = base64Encode(_amina.publicKey);
      final m = buildMsgNotifModel(_pull([bad]), decrypt: dec, hide: false, t: _t, lang: 'en');
      expect(m.lines.single.text, 'New message');
    });

    test('group: conversation title + per-sender names', () {
      final m = buildMsgNotifModel(
          _pull([_msg(1, 'hello', name: 'Amina'), _msg(2, 'yo', from: _chaya, name: 'Chaya')],
              kind: 'group', title: 'Family'),
          decrypt: dec, hide: false, t: _t, lang: 'en');
      expect(m.isGroup, isTrue);
      expect(m.title, 'Family');
      expect(m.lines.map((l) => l.sender), ['Amina', 'Chaya']);
      expect(m.lines.last.text, 'yo');
    });

    test('nothing unseen → empty model (notification gets cleared)', () {
      final m = buildMsgNotifModel(_pull(const []), decrypt: dec, hide: false, t: _t, lang: 'en');
      expect(m.isEmpty, isTrue);
    });

    test('Bangla strings in bn', () {
      final bn = lookupAppLocalizations(const Locale('bn'));
      final m = buildMsgNotifModel(_pull([_msg(1, 'x'), _msg(2, 'y')]),
          decrypt: dec, hide: true, t: bn, lang: 'bn');
      expect(m.lines.single.text, isNot(contains('new messages')));
    });
  });

  group('Android details', () {
    test('MessagingStyle + inline reply input + mark read, grouped, private', () {
      final m = buildMsgNotifModel(_pull([_msg(1, 'hi')]), decrypt: dec, hide: false, t: _t, lang: 'en');
      final d = msgNotificationDetails(m, _t, channelId: 'messages').android!;
      expect(d.styleInformation, isA<MessagingStyleInformation>());
      final s = d.styleInformation as MessagingStyleInformation;
      expect(s.messages!.single.text, 'hi');
      expect(s.messages!.single.person!.name, 'Amina');
      expect(s.messages!.single.person!.icon, isA<DrawableResourceAndroidIcon>());
      expect(d.groupKey, kMsgGroupKey);
      expect(d.tag, 'c3chat:member:12');
      expect(d.shortcutId, 'c3chat_member_12');
      expect(d.visibility, NotificationVisibility.private);
      final reply = d.actions!.firstWhere((a) => a.id == kActionReply);
      expect(reply.inputs, isNotEmpty);
      expect(reply.showsUserInterface, isFalse); // works without opening the app
      expect(reply.cancelNotification, isFalse);
      expect(d.actions!.any((a) => a.id == kActionRead), isTrue);
    });

    test('payload carries ids only — no text', () {
      final m = buildMsgNotifModel(_pull([_msg(1, 'top secret')]), decrypt: dec, hide: false, t: _t, lang: 'en');
      expect(m.payload, isNot(contains('top secret')));
      final p = PushPayload.decode(m.payload)!;
      expect(MsgPushHandler.chatOf(p), (kind: 'member', id: 12));
      expect(m.notificationId, notifIdFor('member', 12));
    });
  });

  group('handler', () {
    MsgPushHandler handler(_Backend b, _Sink s, {bool hide = false}) => MsgPushHandler(
          backend: b,
          identity: () async => _me,
          sink: s,
          e2e: _e2e,
          hideContent: () async => hide,
          clientMsgId: () => 'cid-1',
        );

    final push = PushPayload({'kind': 'message', 'chat_kind': 'member', 'chat_id': '12', 'lang': 'en'});

    test('push → pull (delivered ack) → decrypt → show', () async {
      final b = _Backend(_pull([_msg(1, 'hello')]));
      final s = _Sink();
      expect(await handler(b, s).onPush(push), isTrue);
      expect(s.shown.single.lines.single.text, 'hello');
    });

    test('account-wide "Message preview" off (push preview=0) → hidden', () async {
      final b = _Backend(_pull([_msg(1, 'very private')]));
      final s = _Sink();
      final p0 = PushPayload({'kind': 'message', 'chat_kind': 'member', 'chat_id': '12', 'lang': 'en', 'preview': '0'});
      await handler(b, s).onPush(p0);
      expect(s.shown.single.hidden, isTrue);
      expect(s.shown.single.lines.single.text, isNot(contains('private')));
    });

        test('read elsewhere → cancel', () async {
      final b = _Backend(_pull(const []));
      final s = _Sink();
      await handler(b, s).onPush(push);
      expect(s.cancelled, ['member:12']);
      expect(s.shown, isEmpty);
    });

    test('inline reply 1:1: encrypted on device, sent, chat read, notif cleared', () async {
      final b = _Backend(_pull([_msg(1, 'coming?')]));
      final s = _Sink();
      expect(await handler(b, s).reply('member', 12, ' yes! ', lang: 'en'), isTrue);
      final env = b.sent.single;
      expect(env['id'], 12);
      expect(env['client_msg_id'], 'cid-1');
      expect(env.containsKey('text'), isFalse);
      expect(jsonEncode(env), isNot(contains('yes!')));
      // the recipient (Amina) can decrypt it with my public key
      final pt = _e2e.decrypt(
          self: _amina,
          senderPublicKey: _me.publicKey,
          ct: Ciphertext(
              scheme: '${env['scheme']}',
              ciphertextB64: '${env['ciphertext']}',
              nonceB64: '${env['nonce']}',
              senderKeyId: '${env['sender_key_id']}'));
      expect(pt, 'yes!');
      expect(b.seenCalls, ['member:12']);
      expect(s.cancelled, ['member:12']);
    });

    test('inline reply group: one ciphertext per recipient', () async {
      final b = _Backend(_pull([_msg(1, 'hi')], kind: 'group', title: 'Family'))
        ..roster = [
          {'member_id': 3, 'is_self': true, 'public_key': ''},
          {'member_id': 4, 'is_self': false, 'public_key': base64Encode(_amina.publicKey)},
          {'member_id': 5, 'is_self': false, 'public_key': base64Encode(_chaya.publicKey)},
        ];
      final s = _Sink();
      expect(await handler(b, s).reply('group', 7, 'ok', lang: 'en'), isTrue);
      final env = b.sent.single;
      expect((env['recipient_ids'] as List), [4, 5]);
      final per = (env['per_recipient'] as Map).cast<String, dynamic>();
      final forChaya = (per['5'] as Map).cast<String, dynamic>();
      expect(
          _e2e.decrypt(
              self: _chaya,
              senderPublicKey: Uint8List.fromList(_me.publicKey),
              ct: Ciphertext(
                  scheme: _e2e.scheme,
                  ciphertextB64: '${forChaya['ciphertext']}',
                  nonceB64: '${forChaya['nonce']}',
                  senderKeyId: _me.keyId)),
          'ok');
      expect(b.seenCalls, ['group:7']);
    });

    test('reply failure → notification redrawn with "Not sent"', () async {
      final b = _Backend(_pull([_msg(1, 'hi')]))..failSend = true;
      final s = _Sink();
      expect(await handler(b, s).reply('member', 12, 'yes', lang: 'en'), isFalse);
      expect(s.shown.single.lines.last.text, _t.c3NotifReplyFailed);
      expect(b.seenCalls, isEmpty);
    });

    test('empty reply does nothing; mark read → seen + cancel', () async {
      final b = _Backend(_pull([_msg(1, 'hi')]));
      final s = _Sink();
      final h = handler(b, s);
      expect(await h.reply('member', 12, '   '), isFalse);
      expect(b.sent, isEmpty);
      await h.markRead('member', 12);
      expect(b.seenCalls, ['member:12']);
      expect(s.cancelled, ['member:12']);
    });

    test('foreground suppression for the open chat', () {
      MsgActiveChat.current = 'member:12';
      expect(MsgActiveChat.isOpen('member', 12), isTrue);
      expect(MsgActiveChat.isOpen('group', 12), isFalse);
      MsgActiveChat.current = null;
    });
  });
}
