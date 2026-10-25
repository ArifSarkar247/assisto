// md2 — My Circle media follow-ups:
//  * forward photo / voice / document to a GROUP (and group -> 1:1,
//    group -> group) reusing the SAME blob: every new recipient's E2E
//    envelope carries the same descriptor (ref, key, nonce, sha);
//  * no send-to-poll flicker: a sent text / finished media send keeps its
//    bubble until the server copy (same client_msg_id / id) is listed, then
//    swaps in place — the bubble is on screen in EVERY frame, exactly once;
//  * chat-list + notification previews: "📷 Photo", "🎤 Voice message",
//    "📄 <document name>" (bn + en); hidden previews never show a name.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_preview.dart';
import 'package:assisto/messaging/echo_reconcile.dart';
import 'package:assisto/messaging/forward.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_outbox.dart';
import 'package:assisto/messaging/media/media_store.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();
final _third = _e2e.generateIdentity();

class _Api extends ApiClient {
  _Api() {
    token = 'test';
  }
  final Map<String, Object> replies = {};
  final calls = <(String, String, Map<String, dynamic>)>[];

  Map<String, dynamic> _answer(String path) {
    final r = replies[path] ?? replies[path.split('?').first] ?? const {};
    if (r is Map<String, dynamic> Function()) return r();
    return Map<String, dynamic>.from(r as Map);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(('GET', path, const {}));
    return _answer(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(('POST', path, body));
    final r = replies['POST $path'];
    if (r is Map<String, dynamic> Function(Map<String, dynamic>)) return r(body);
    return _answer(path);
  }

  List<Map<String, dynamic>> posts(String path) => [
        for (final c in calls)
          if (c.$1 == 'POST' && c.$2 == path) c.$3
      ];
}

class _MemStore implements MediaJobStore {
  List<Map<String, dynamic>> rows = [];
  @override
  Future<List<Map<String, dynamic>>> load() async =>
      rows.map((r) => Map<String, dynamic>.from(r)).toList();
  @override
  Future<void> save(List<Map<String, dynamic>> r) async => rows = r;
}

MediaDescriptor _doc(String ref, {String name = 'Rent receipt.pdf'}) => MediaDescriptor(
    kind: 'document',
    ref: ref,
    key: Uint8List.fromList(List.generate(32, (i) => i + 1)),
    nonce: Uint8List.fromList(List.generate(12, (i) => 40 + i)),
    sha256: 'a' * 64,
    size: 4096,
    plainSize: 4000,
    mime: 'application/pdf',
    name: name);

Map<String, dynamic> _fromPeer(int id, String text, {DateTime? at}) => {
      'id': id,
      'sender_id': 2,
      'mine': false,
      'content_type': 'text',
      'created_at': (at ?? DateTime.now().subtract(const Duration(minutes: 5)))
          .toUtc()
          .toIso8601String(),
      ..._e2e
          .encrypt(self: _peer, recipientPublicKey: _me.publicKey, plaintext: text)
          .toEnvelopeFields(),
    };

Future<void> _host(WidgetTester tester, _Api api, Widget screen) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  final app = AppState()..api = api;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: screen,
    ),
  ));
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

/// Pump [total] in [step] frames; [check] runs after EVERY frame.
Future<void> _frames(WidgetTester tester, Duration total, void Function(int) check,
    {Duration step = const Duration(milliseconds: 100), void Function(Duration)? at}) async {
  var t = Duration.zero;
  var i = 0;
  while (t < total) {
    await tester.pump(step);
    t += step;
    at?.call(t);
    check(i++);
  }
}

Map<String, dynamic> _member5() => {
      'id': 5,
      'name': 'Abul Kashem',
      'relation': 'friend',
      'state': 'accepted',
      'public_key': _peer.publicKeyB64,
    };

const _group7 = {'id': 7, 'name': 'Family', 'my_member_id': 1};

Map<String, dynamic> _roster7() => {
      'results': [
        {'id': 1, 'user_id': 1, 'name': 'Me', 'is_self': true, 'public_key': _me.publicKeyB64},
        {'id': 2, 'user_id': 2, 'name': 'Abul', 'public_key': _peer.publicKeyB64},
      ]
    };

late AppLocalizations en;
late AppLocalizations bn;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Outbox.instance.stop();
  });

  group('SentEchoes (pure)', () {
    test('held until the server id or client_msg_id is listed', () {
      final s = SentEchoes();
      s.track('901', 'local-1');
      s.track('local-2', 'local-2');
      expect(s.awaiting(ids: {'1'}, cmids: {}), {'901', 'local-2'});
      // server copy of local-2 arrives (different id, same client_msg_id)
      expect(s.awaiting(ids: {'1', '950'}, cmids: {'local-2'}), {'901'});
      expect(s.awaiting(ids: {'1', '901', '950'}, cmids: {'local-2'}), isEmpty);
    });

    test('expires so a lost copy never pins a bubble forever', () {
      final s = SentEchoes(ttl: const Duration(minutes: 2));
      final t0 = DateTime(2026, 10, 22, 10);
      s.track('x', 'x', now: t0);
      expect(s.awaiting(ids: {}, cmids: {}, now: t0.add(const Duration(minutes: 1))), {'x'});
      expect(s.awaiting(ids: {}, cmids: {}, now: t0.add(const Duration(minutes: 3))), isEmpty);
    });

    test('client_msg_ids only from my rows', () {
      expect(
          fetchedClientIds([
            {'id': 1, 'client_msg_id': 'a'},
            {'id': 2, 'client_msg_id': ''},
            {'id': 3},
          ]),
          {'a'});
    });
  });

  group('forward to a group reuses the same blob', () {
    test('every member gets the SAME descriptor; I am skipped; flagged', () {
      final d = _doc('b' * 32);
      final env = buildGroupForwardEnvelope(
        roster: [
          {'id': 1, 'is_self': true, 'public_key': _me.publicKeyB64},
          {'id': 2, 'public_key': _peer.publicKeyB64},
          {'id': 3, 'public_key': _third.publicKeyB64},
          {'id': 4, 'public_key': ''}, // keyless: asked silently, not refused
        ],
        me: _me,
        e2e: _e2e,
        payload: ForwardPayload(
            plaintext: d.encode(), contentType: 'document', blobRef: d.ref, hops: 2),
        clientMsgId: 'fwd-1',
      )!;
      expect(env['blob_ref'], d.ref);
      expect(env['content_type'], 'document');
      expect(env['forwarded'], true);
      expect(env['forward_hops'], 2);
      expect(env['recipient_ids'], [2, 3]);
      expect(env.containsKey('text'), isFalse);
      expect(jsonEncode(env).contains('Rent receipt'), isFalse); // name is sealed
      for (final (id, who) in [('2', _peer), ('3', _third)]) {
        final b = (env['per_recipient'] as Map)[id] as Map;
        final pt = _e2e.decrypt(
            self: who,
            senderPublicKey: _me.publicKey,
            ct: Ciphertext(
                scheme: _e2e.scheme,
                ciphertextB64: '${b['ciphertext']}',
                nonceB64: '${b['nonce']}',
                senderKeyId: _me.keyId));
        final got = MediaDescriptor.tryParse(pt!)!;
        expect(got.encode(), d.encode()); // same ref, key, nonce, sha, name
      }
    });

    test('nobody keyed yet -> null (the sender waits, never a key error)', () {
      expect(
          buildGroupForwardEnvelope(
              roster: [
                {'id': 2, 'public_key': ''}
              ],
              me: _me,
              e2e: _e2e,
              payload: const ForwardPayload(plaintext: 'hi'),
              clientMsgId: 'x'),
          isNull);
    });

    test('1:1 -> group posts once to the group with the same blob_ref', () async {
      final api = _Api();
      api.replies['/circle/groups/8/members'] = {
        'results': [
          {'id': 11, 'user_id': 1, 'is_self': true, 'public_key': _me.publicKeyB64},
          {'id': 12, 'user_id': 3, 'public_key': _third.publicKeyB64},
        ]
      };
      api.replies['/circle/groups/8/messages'] = {'id': 77, 'ok': true};
      final d = _doc('c' * 32);
      final sid = await forwardToGroup(api, _me, 8,
          ForwardPayload(plaintext: d.encode(), contentType: 'document', blobRef: d.ref),
          e2e: _e2e, clientMsgId: 'fwd-9', wait: Duration.zero);
      expect(sid, '77');
      final p = api.posts('/circle/groups/8/messages').single;
      expect((p['blob_ref'], p['client_msg_id'], p['forwarded']), (d.ref, 'fwd-9', true));
      expect(api.calls.where((c) => c.$2.contains('/circle/media/blobs')), isEmpty,
          reason: 'never re-uploaded');
    });
  });

  group('previews (bn + en)', () {
    test('chat list: photo caption / document name / voice label', () {
      final d = _doc('d' * 32, name: 'ভাড়ার রসিদ.pdf');
      Map<String, dynamic> row(String ct, String plain) => {
            'last': {
              'id': 1,
              'content_type': ct,
              'mine': false,
              'peer_public_key': _peer.publicKeyB64,
              ..._e2e
                  .encrypt(self: _peer, recipientPublicKey: _me.publicKey, plaintext: plain)
                  .toEnvelopeFields(),
            }
          };
      final doc = ChatPreview.fromRow(row('document', d.encode()), identity: _me, e2e: _e2e);
      expect((doc.kind, doc.text), (PreviewKind.media, 'ভাড়ার রসিদ.pdf'));
      final voice = ChatPreview.fromRow(
          row('voice', MediaDescriptor(
                  kind: 'voice', ref: 'e' * 32, key: Uint8List(32), nonce: Uint8List(12),
                  sha256: 'f' * 64, size: 10, plainSize: 10)
              .encode()),
          identity: _me,
          e2e: _e2e);
      expect((voice.kind, voice.text), (PreviewKind.media, ''));
      // keys not loaded: still a media row (label), never the descriptor
      final nokey = ChatPreview.fromRow(row('document', d.encode()), identity: null);
      expect((nokey.kind, nokey.text), (PreviewKind.media, ''));
    });

    test('notification lines carry the kind label in both languages', () {
      final d = _doc('d' * 32);
      for (final t in [en, bn]) {
        expect(mediaNotifText(t, 'photo'), '\u{1F4F7} ${t.circlePhoto}');
        expect(mediaNotifText(t, 'voice'), '\u{1F3A4} ${t.msgrVoiceMessage}');
        expect(mediaNotifText(t, 'document', plaintext: d.encode()),
            '\u{1F4C4} Rent receipt.pdf');
        expect(mediaNotifText(t, 'document'), '\u{1F4C4} ${t.circleAttachDocument}');
      }
      expect(en.msgrVoiceMessage, 'Voice message');
      expect(bn.msgrVoiceMessage, isNot(en.msgrVoiceMessage));
    });

    test('hidden previews never show the document name', () {
      final d = _doc('d' * 32);
      final pull = {
        'chat': {'kind': 'member', 'id': 5, 'title': 'Abul'},
        'messages': [
          {'id': 1, 'content_type': 'document', 'mine': false, 'sender_name': 'Abul',
            'created_at': DateTime.now().toIso8601String()},
        ],
        'unseen': 1,
      };
      for (final t in [en, bn]) {
        final shown = buildMsgNotifModel(pull,
            decrypt: (_) => d.encode(), hide: false, t: t, lang: 'en');
        expect(shown.lines.single.text, '\u{1F4C4} Rent receipt.pdf');
        final hidden = buildMsgNotifModel(pull,
            decrypt: (_) => d.encode(), hide: true, t: t, lang: 'en');
        expect(hidden.lines.single.text.contains('Rent receipt'), isFalse);
        expect(hidden.lines.single.text.contains('\u{1F4C4}'), isFalse);
      }
    });
  });

  group('no send-to-poll flicker', () {
    testWidgets('1:1 text: on screen in every frame across the poll boundary',
        (tester) async {
      final api = _Api();
      var serverHas = false;
      String? cmid;
      api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
      api.replies['/circle/5/messages'] = () => <String, dynamic>{
            'results': [
              _fromPeer(1, 'hello from Abul'),
              if (serverHas)
                {
                  'id': 900,
                  'sender_id': 1,
                  'mine': true,
                  'status': 'delivered',
                  'content_type': 'text',
                  'client_msg_id': cmid,
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                  ..._e2e
                      .encrypt(self: _me, recipientPublicKey: _peer.publicKey,
                          plaintext: 'see you at 5')
                      .toEnvelopeFields(),
                },
            ],
          };
      // the send succeeds but the server returns NO id (older server): the
      // swap must work by client_msg_id alone
      api.replies['POST /circle/5/messages'] = (Map<String, dynamic> b) {
        cmid = '${b['client_msg_id']}';
        return <String, dynamic>{'ok': true};
      };
      await _host(tester, api, CircleChatScreen(member: _member5(), identity: _me));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'see you at 5');
      await tester.tap(find.byIcon(Icons.send_rounded));
      // first poll (7 s) does NOT have it yet; at 10 s the server copy lands;
      // the 14 s poll swaps it in. Present EXACTLY once in every frame.
      await _frames(tester, const Duration(seconds: 18), (i) {
        expect(find.text('see you at 5', findRichText: true), findsOneWidget,
            reason: 'frame $i');
      }, at: (t) {
        if (t >= const Duration(seconds: 10)) serverHas = true;
      });
      expect(cmid, isNotNull);
      final polls = api.calls.where((c) => c.$1 == 'GET' && c.$2.startsWith('/circle/5/messages')).length;
      expect(polls, greaterThanOrEqualTo(3));
      await _dispose(tester);
    });

    testWidgets('group text: on screen in every frame across the poll boundary',
        (tester) async {
      final api = _Api();
      var serverHas = false;
      String? cmid;
      api.replies['/circle/groups/7/members'] = _roster7();
      api.replies['/circle/groups/7/messages'] = () => <String, dynamic>{
            'results': [
              {..._fromPeer(1, 'group hello'), 'per_recipient': null},
              if (serverHas)
                {
                  'id': 901,
                  'sender_id': 1,
                  'mine': true,
                  'status': 'sent',
                  'content_type': 'text',
                  'client_msg_id': cmid,
                  'sender_key_id': _me.keyId,
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                  'per_recipient': {
                    '2': () {
                      final c = _e2e.encrypt(
                          self: _me, recipientPublicKey: _peer.publicKey,
                          plaintext: 'bring the papers');
                      return {'ciphertext': c.ciphertextB64, 'nonce': c.nonceB64};
                    }(),
                  },
                },
            ],
          };
      api.replies['POST /circle/groups/7/messages'] = (Map<String, dynamic> b) {
        cmid = '${b['client_msg_id']}';
        return <String, dynamic>{'id': 901, 'ok': true};
      };
      await _host(tester, api, CircleGroupChatScreen(group: _group7, identity: _me));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'bring the papers');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await _frames(tester, const Duration(seconds: 20), (i) {
        expect(find.text('bring the papers', findRichText: true), findsOneWidget,
            reason: 'frame $i');
      }, at: (t) {
        if (t >= const Duration(seconds: 10)) serverHas = true;
      });
      expect(api.posts('/circle/groups/7/messages').single['client_msg_id'], cmid);
      await _dispose(tester);
    });

    Future<MediaOutbox> mediaSetup() async {
      final dir = Directory.systemTemp.createTempSync('md2_media');
      MediaDirs.override = dir.path;
      MediaPrefs.metered = () async => true; // no auto-download of documents
      final mo = MediaOutbox(store: _MemStore());
      mo.identity = () async => _me;
      MediaOutbox.instance = mo;
      return mo;
    }

    MediaJob job(String kind, int chat, String ckind) => MediaJob(
        id: 'local-md2-$ckind',
        chatKind: ckind,
        chatId: chat,
        kind: 'document',
        srcPath: '/nope',
        name: 'Rent receipt.pdf',
        mime: 'application/pdf',
        plainSize: 4000,
        at: DateTime.now(),
        keyB64: base64Encode(List.generate(32, (i) => i + 1)),
        nonceB64: base64Encode(List.generate(12, (i) => 40 + i)),
        sha: 'a' * 64,
        cipherSize: 4096,
        ref: 'f' * 32);

    testWidgets('group media: finished send stays until the server copy (every frame)',
        (tester) async {
      final mo = await mediaSetup();
      final api = _Api();
      var serverHas = false;
      var peerMore = false; // a peer message lands while the copy is not listed
      final j = job('document', 7, 'group');
      api.replies['/circle/groups/7/members'] = _roster7();
      api.replies['/circle/groups/7/messages'] = () => <String, dynamic>{
            'results': [
              {..._fromPeer(1, 'group hello'), 'per_recipient': null},
              if (peerMore) {..._fromPeer(2, 'one more thing'), 'per_recipient': null},
              if (serverHas)
                {
                  'id': 902,
                  'sender_id': 1,
                  'mine': true,
                  'status': 'sent',
                  'content_type': 'document',
                  'blob_ref': j.ref,
                  'client_msg_id': j.id,
                  'sender_key_id': _me.keyId,
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                  'per_recipient': {
                    '2': () {
                      final c = _e2e.encrypt(
                          self: _me, recipientPublicKey: _peer.publicKey,
                          plaintext: j.descriptor().encode());
                      return {'ciphertext': c.ciphertextB64, 'nonce': c.nonceB64};
                    }(),
                  },
                },
            ],
          };
      await _host(tester, api, CircleGroupChatScreen(group: _group7, identity: _me));
      await tester.pump(const Duration(milliseconds: 300));
      await mo.store.save([j.toJson()]);
      mo.changes.value++;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Rent receipt.pdf'), findsOneWidget); // the sending bubble
      var finished = false;
      await _frames(tester, const Duration(seconds: 20), (i) {
        expect(find.text('Rent receipt.pdf'), findsOneWidget, reason: 'frame $i');
      }, at: (t) {
        if (!finished && t >= const Duration(seconds: 1)) {
          finished = true;
          mo.finishSent(j, '902'); // upload done: job leaves the queue
        }
        if (t >= const Duration(seconds: 3)) peerMore = true;
        if (t >= const Duration(seconds: 10)) serverHas = true;
      });
      expect(mo.recentlySent[j.id]?.serverId, '902');
      expect(await mo.all(), isEmpty);
      await _dispose(tester);
    });

    testWidgets('1:1 media: finished send stays until the server copy (every frame)',
        (tester) async {
      final mo = await mediaSetup();
      final api = _Api();
      var serverHas = false;
      final j = job('document', 5, 'member');
      api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
      api.replies['/circle/5/messages'] = () => <String, dynamic>{
            'results': [
              _fromPeer(1, 'hello from Abul'),
              if (serverHas)
                {
                  'id': 903,
                  'sender_id': 1,
                  'mine': true,
                  'status': 'sent',
                  'content_type': 'document',
                  'blob_ref': j.ref,
                  'client_msg_id': j.id,
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                  ..._e2e
                      .encrypt(self: _me, recipientPublicKey: _peer.publicKey,
                          plaintext: j.descriptor().encode())
                      .toEnvelopeFields(),
                },
            ],
          };
      await _host(tester, api, CircleChatScreen(member: _member5(), identity: _me));
      await tester.pump(const Duration(milliseconds: 300));
      await mo.store.save([j.toJson()]);
      mo.changes.value++;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Rent receipt.pdf'), findsOneWidget);
      var finished = false;
      await _frames(tester, const Duration(seconds: 18), (i) {
        expect(find.text('Rent receipt.pdf'), findsOneWidget, reason: 'frame $i');
      }, at: (t) {
        if (!finished && t >= const Duration(seconds: 1)) {
          finished = true;
          mo.finishSent(j, '903');
        }
        if (t >= const Duration(seconds: 10)) serverHas = true;
      });
      await _dispose(tester);
    });
  });

  testWidgets('group -> group forward of a document: same blob, Forwarded label',
      (tester) async {
    final api = _Api();
    final d = _doc('9' * 32);
    final peerDoc = _e2e.encrypt(
        self: _peer, recipientPublicKey: _me.publicKey, plaintext: d.encode());
    api.replies['/circle/groups/7/members'] = _roster7();
    api.replies['/circle/groups/7/messages'] = {
      'results': [
        {
          'id': 5,
          'sender_id': 2,
          'mine': false,
          'content_type': 'document',
          'blob_ref': d.ref,
          'forwarded': true,
          'forward_hops': 1,
          'sender_key_id': _peer.keyId,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'per_recipient': {
            '1': {'ciphertext': peerDoc.ciphertextB64, 'nonce': peerDoc.nonceB64}
          },
        }
      ]
    };
    api.replies['/circle/members'] = {'results': <Map<String, dynamic>>[]};
    api.replies['/circle/groups'] = {
      'results': [
        {'id': 7, 'name': 'Family'},
        {'id': 8, 'name': 'Office'},
      ]
    };
    api.replies['/circle/groups/8/members'] = {
      'results': [
        {'id': 21, 'user_id': 1, 'is_self': true, 'public_key': _me.publicKeyB64},
        {'id': 22, 'user_id': 3, 'public_key': _third.publicKeyB64},
      ]
    };
    api.replies['/circle/groups/8/messages'] = {'id': 501, 'ok': true};
    await _host(tester, api, CircleGroupChatScreen(group: _group7, identity: _me));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(en.circleForwarded), findsOneWidget); // label in groups
    await tester.longPress(find.text('Rent receipt.pdf'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('md2-group-forward')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(en.c3ForwardTo), findsOneWidget);
    await tester.tap(find.byKey(const Key('md2-fwd-group-8')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final p = api.posts('/circle/groups/8/messages').single;
    expect((p['content_type'], p['blob_ref'], p['forwarded'], p['forward_hops']),
        ('document', d.ref, true, 2));
    final b = (p['per_recipient'] as Map)['22'] as Map;
    final pt = _e2e.decrypt(
        self: _third,
        senderPublicKey: _me.publicKey,
        ct: Ciphertext(
            scheme: _e2e.scheme,
            ciphertextB64: '${b['ciphertext']}',
            nonceB64: '${b['nonce']}',
            senderKeyId: _me.keyId));
    final got = MediaDescriptor.tryParse(pt!)!;
    expect(got.encode(), d.encode()); // same blob + key: no re-upload
    expect(api.calls.where((c) => c.$2.contains('/circle/media/blobs')), isEmpty);
    expect(find.text(en.c3Forwarded('Office')), findsOneWidget);
    await _dispose(tester);
  });
}
