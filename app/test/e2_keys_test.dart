// e2-keys (owner order 22 Oct, item 1): key publish triggers + backoff,
// the persistent outbox (persist / flush on key arrival, incl. a restart),
// security-code change detection, the accept hook.
import 'dart:async';
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/key_service.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTransport implements OutboxTransport {
  String key = '';
  final sent = <(int, Map<String, dynamic>)>[];
  int keyAsks = 0;
  bool failSend = false;

  @override
  Future<Map<String, dynamic>> peerKey(int memberId) async {
    keyAsks++;
    return {'public_key': key, 'key_id': key.isEmpty ? '' : 'kB'};
  }

  @override
  Future<Map<String, dynamic>> send(int memberId, Map<String, dynamic> env) async {
    if (failSend) throw StateError('offline');
    sent.add((memberId, env));
    return {'id': sent.length, 'ok': true};
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('KeyService publish', () {
    test('publishes the PUBLIC key only, creating the identity once', () async {
      final store = MemoryIdentityStore();
      final svc = KeyService(store: store, sleep: (_) async {});
      final posts = <Map<String, dynamic>>[];
      final ok = await svc.publish((p, b) async {
        expect(p, '/circle/keys');
        posts.add(b);
        return {'ok': true};
      }, reason: 'start');
      expect(ok, isTrue);
      expect(posts.single.keys.toSet(), {'public_key', 'key_id', 'scheme'});
      expect(posts.single['public_key'], store.id!.publicKeyB64);
      final again = await svc.identity();
      expect(again.keyId, store.id!.keyId); // never a second identity
    });

    test('retries with exponential backoff, then succeeds (logged)', () async {
      final slept = <Duration>[];
      final svc = KeyService(
          store: MemoryIdentityStore(),
          sleep: (d) async => slept.add(d),
          log: KeyLog());
      var n = 0;
      final ok = await svc.publish((p, b) async {
        n++;
        if (n < 4) throw StateError('offline');
        return {};
      }, reason: 'start');
      expect(ok, isTrue);
      expect(n, 4);
      expect(slept, KeyService.defaultBackoff.sublist(0, 3));
      expect(svc.log.entries.where((e) => e.contains('publish failed')).length, 3);
      expect(svc.log.entries.last, contains('published reason=start attempt=4'));
    });

    test('gives up honestly after the backoff (never silent)', () async {
      final svc = KeyService(
          store: MemoryIdentityStore(),
          sleep: (_) async {},
          backoff: const [Duration(seconds: 1), Duration(seconds: 2)]);
      final ok = await svc.publish((p, b) async => throw StateError('x'),
          reason: 'request');
      expect(ok, isFalse);
      expect(svc.log.entries.last, contains('gave up'));
    });

    test('concurrent triggers share ONE publish loop', () async {
      final svc = KeyService(store: MemoryIdentityStore(), sleep: (_) async {});
      final gate = Completer<Map<String, dynamic>>();
      var calls = 0;
      Future<Map<String, dynamic>> post(String p, Map<String, dynamic> b) {
        calls++;
        return gate.future;
      }

      final a = svc.publish(post, reason: 'start');
      final b = svc.onRequestAccepted(post);
      gate.complete({});
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(calls, 1);
    });

    test('attach: publishes at start, again after logout -> login', () async {
      final svc = KeyService(store: MemoryIdentityStore(), sleep: (_) async {});
      final reasons = <String>[];
      var ready = false;
      Object? uid;
      VoidCallback? cb;
      svc.attach(
        isReady: () => ready,
        userId: () => uid,
        post: () => (p, b) async {
          reasons.add('${svc.log.entries.length}');
          return {};
        },
        listen: (c) => cb = c,
      );
      expect(reasons, isEmpty); // not logged in yet
      ready = true;
      uid = 7;
      cb!();
      await Future<void>.delayed(Duration.zero);
      expect(reasons.length, 1);
      cb!(); // same user, a rebuild -> no re-publish
      await Future<void>.delayed(Duration.zero);
      expect(reasons.length, 1);
      ready = false; // logout
      cb!();
      ready = true;
      uid = 8; // login as someone else
      cb!();
      await Future<void>.delayed(Duration.zero);
      expect(reasons.length, 2);
      expect(svc.log.entries.any((e) => e.contains('reason=login')), isTrue);
      expect(svc.log.entries.any((e) => e.contains('reason=start')), isTrue);
    });

    test('ApiClient fires onRequestAccepted on any accept path', () async {
      var fired = 0;
      ApiClient.onRequestAccepted = () => fired++;
      addTearDown(() => ApiClient.onRequestAccepted = null);
      await http.runWithClient(() async {
        final api = ApiClient(token: 't');
        await api.postJson('/circle/request/5/act', {'event': 'accept'});
        await api.postJson('/messenger/request/9/act', {'event': 'accept'});
        await api.postJson('/circle/invite/redeem', {'token': 'x'});
        await api.postJson('/circle/request/5/act', {'event': 'decline'});
        await api.postJson('/circle/5/messages', {'event': 'accept'});
      }, () => MockClient((r) async => http.Response('{}', 200)));
      expect(fired, 3);
    });

    test('realtime key.published feeds keyEvents', () async {
      final svc = KeyService(store: MemoryIdentityStore());
      final got = <Map<String, dynamic>>[];
      final sub = svc.keyEvents.stream.listen(got.add);
      svc.onRealtime('presence.update', {'chat': 'member:1'});
      svc.onRealtime('key.published', {'chat': 'member:5', 'changed': false});
      await Future<void>.delayed(Duration.zero);
      expect(got.single['chat'], 'member:5');
      await sub.cancel();
    });
  });

  group('Outbox', () {
    final me = SoftwareE2E().generateIdentity();
    final peer = SoftwareE2E().generateIdentity();

    OutboxItem item(String id, {int chat = 5, String text = 'hello'}) =>
        OutboxItem(id: id, chatId: chat, text: text, at: DateTime.now());

    test('persists across a restart (new instance, same storage)', () async {
      await Outbox().add(item('local-1'));
      await Outbox().add(item('local-2', text: 'second'));
      final restarted = Outbox();
      final q = await restarted.forChat('member', 5);
      expect(q.map((i) => i.id), ['local-1', 'local-2']);
      expect(q[1].text, 'second');
    });

    test('keeps waiting without a key, flushes once the key arrives', () async {
      final ob = Outbox();
      await ob.add(item('local-1'));
      final t = _FakeTransport();
      var r = await ob.flush(transport: t, identity: () async => me);
      expect(r.sent, isEmpty);
      expect(r.waiting, 1);
      expect(t.keyAsks, 1); // = the server queues a silent key_request
      expect((await ob.all()).length, 1);

      t.key = peer.publicKeyB64; // B's phone published in the background
      r = await Outbox().flush(transport: t, identity: () async => me);
      expect(r.sent, ['local-1']);
      expect(t.sent.single.$1, 5);
      final env = t.sent.single.$2;
      expect(env['client_msg_id'], 'local-1'); // server dedupes on this
      expect(env.containsKey('text'), isFalse); // never plaintext
      final pt = SoftwareE2E().decrypt(
          self: peer,
          senderPublicKey: me.publicKey,
          ct: Ciphertext(
              scheme: '${env['scheme']}',
              ciphertextB64: '${env['ciphertext']}',
              nonceB64: '${env['nonce']}',
              senderKeyId: '${env['sender_key_id']}'));
      expect(pt, 'hello');
      expect(await ob.all(), isEmpty);
    });

    test('network failure keeps the item and its order', () async {
      final ob = Outbox();
      await ob.add(item('a'));
      await ob.add(item('b'));
      final t = _FakeTransport()
        ..key = peer.publicKeyB64
        ..failSend = true;
      final r = await ob.flush(transport: t, identity: () async => me);
      expect(r.sent, isEmpty);
      expect((await ob.all()).map((i) => i.id), ['a', 'b']);
    });

    test('a key.published event flushes that chat', () async {
      final ob = Outbox();
      await ob.add(item('local-9', chat: 12));
      final t = _FakeTransport();
      final events = StreamController<Map<String, dynamic>>.broadcast();
      ob.start(transport: t, identity: () async => me, keyEvents: events.stream);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.sent, isEmpty);
      t.key = peer.publicKeyB64;
      events.add({'chat': 'member:12', 'changed': false});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(t.sent.single.$2['client_msg_id'], 'local-9');
      expect(await ob.all(), isEmpty);
      ob.stop();
      await events.close();
    });
  });

  group('PeerKeyBook', () {
    test('first key is no change; a different key adds a note + history',
        () async {
      final b = PeerKeyBook.instance;
      expect(await b.observe('member:3', 'AAAA'), isFalse);
      expect(await b.observe('member:3', 'AAAA'), isFalse);
      expect(await b.notes('member:3'), isEmpty);
      expect(await b.observe('member:3', 'BBBB'), isTrue);
      expect((await b.notes('member:3')).length, 1);
      expect(await b.history('member:3'), ['AAAA']);
      expect(await b.notes('member:4'), isEmpty);
    });
  });

  test('envelope is base64 json-safe', () {
    final e = SoftwareE2E();
    final a = e.generateIdentity(), b = e.generateIdentity();
    final ct = e.encrypt(self: a, recipientPublicKey: b.publicKey, plaintext: 'x');
    expect(jsonEncode(ct.toEnvelopeFields()), isNotEmpty);
    expect(Uint8List.fromList(base64Decode(b.publicKeyB64)), b.publicKey);
  });
}
