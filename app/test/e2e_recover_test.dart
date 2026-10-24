// e2e-recover (owner launch-blocker 24 Oct): after a reinstall every older
// 1:1 message — incoming AND my own sent — showed "This message cannot be
// decrypted on this device". Two simulated accounts on a fake server:
//   A and B exchange messages -> A "reinstalls" (fresh SecretStore) ->
//   (a) restore with the Security PIN: the SAME key id comes back, old +
//       new messages open on both sides, B sees no key change;
//   (b) skip restore: a new key -> B's phone re-shares the history to it ->
//       A opens old messages (incoming + own sent), new messages work.
// Plus: scrypt RFC 7914 vectors, the key ring never drops a key, wrong-PIN
// counting / lockout, the restore gate runs BEFORE a key is generated, the
// local plaintext cache, and the chat screen never renders the raw error.
import 'dart:convert';
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/history_reshare.dart';
import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/crypto/key_backup.dart';
import 'package:assisto/crypto/plain_cache.dart';
import 'package:assisto/crypto/ring_decrypt.dart';
import 'package:assisto/crypto/scrypt.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/e2_restore_screen.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:assisto/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

/// An app sandbox in memory (a reinstall = a new instance).
class _Mem extends SecretStore {
  _Mem() : super();
  final Map<String, String> m = {};
  @override
  Future<String?> read(String name) async => m[name];
  @override
  Future<bool> write(String name, String value) async {
    m[name] = value;
    return true;
  }

  @override
  Future<void> delete(String name) async => m.remove(name);
}

/// Mirrors the backend contract (core/views_e2e_recover.py + e2_keys).
/// User 1 = A (chat id 5 for B), user 2 = B (chat id 6 for A).
class _Server {
  final Map<int, Map<String, dynamic>> keys = {};
  final List<Map<String, dynamic>> msgs = [];
  final Map<String, Map<String, dynamic>> copies = {};
  final Map<String, Map<String, dynamic>> requests = {};
  final Map<int, Map<String, dynamic>> backups = {};
  final Map<int, int> wrong = {};
  final List<String> calls = [];
  int _id = 100;

  static int peerOf(int uid) => uid == 1 ? 2 : 1;
  static int chatOf(int uid) => uid == 1 ? 5 : 6;

  Map<String, dynamic> _keyDict(int uid) {
    final k = keys[uid];
    if (k == null) return {'public_key': '', 'key_id': '', 'history': []};
    return {
      'user_id': uid,
      'public_key': k['public_key'],
      'key_id': k['key_id'],
      'history': [
        for (final h in (k['history'] as List)) Map<String, dynamic>.from(h)
      ],
    };
  }

  Future<Map<String, dynamic>> get(int uid, String path) async {
    calls.add('GET $path');
    final p = path.split('?').first;
    if (p == '/circle/keys/peer/${chatOf(uid)}') return _keyDict(peerOf(uid));
    if (p == '/circle/${chatOf(uid)}/messages') {
      if (path.contains('before=')) return {'results': [], 'has_more': false};
      return {
        'has_more': false,
        'results': [
          for (final m in msgs)
            {
              ...m,
              'mine': m['sender_id'] == uid,
              if (copies['${m['id']}|$uid'] != null)
                'copy': copies['${m['id']}|$uid'],
            }
        ],
      };
    }
    if (p == '/circle/e2/resend') {
      final out = <Map<String, dynamic>>[];
      for (final r in requests.values) {
        if (r['target'] != uid || r['done'] == true) continue;
        final cur = keys[r['requester']];
        if (cur == null || cur['key_id'] != r['key_id']) continue;
        out.add({
          'id': r['id'],
          'chat_id': chatOf(uid),
          'user_id': r['requester'],
          'key_id': r['key_id'],
          'public_key': cur['public_key'],
          'whole': r['whole'],
          'message_ids': r['ids'],
          'since': DateTime(2026, 1, 1).toIso8601String(),
        });
      }
      return {'results': out};
    }
    if (p == '/e2/backup') {
      final b = backups[uid];
      if (b == null) return {'exists': false, 'slots': []};
      return {
        'exists': true,
        'attempts_left': 5 - (wrong[uid] ?? 0),
        'slots': [
          {
            'slot': 0,
            'salt': b['salt'],
            'kdf': b['kdf'],
            'key_ids': b['key_ids'],
            'current_key_id': b['current_key_id'],
          }
        ],
      };
    }
    throw StateError('unknown GET $path');
  }

  String _hash(String authB64) =>
      _hex(Sha256.hash(utf8.encode('assisto-e2kb-v1|$authB64')));

  Future<Map<String, dynamic>> post(
      int uid, String path, Map<String, dynamic> body) async {
    calls.add('POST $path');
    if (path == '/circle/keys') {
      final cur = keys[uid];
      final pub = body['public_key'];
      if (cur != null && cur['public_key'] != pub) {
        keys[uid] = {
          'public_key': pub,
          'key_id': body['key_id'],
          'history': [
            {'public_key': cur['public_key'], 'key_id': cur['key_id']},
            ...(cur['history'] as List),
          ],
        };
        // key change -> the contact's phone is asked to re-share
        final peer = peerOf(uid);
        requests['$uid|$peer|${body['key_id']}'] = {
          'id': requests.length + 1,
          'requester': uid,
          'target': peer,
          'key_id': body['key_id'],
          'whole': true,
          'ids': <int>[],
        };
        return {'ok': true, 'changed': true};
      }
      keys[uid] = {
        'public_key': pub,
        'key_id': body['key_id'],
        'history': cur?['history'] ?? [],
      };
      return {'ok': true, 'changed': false};
    }
    if (path == '/circle/${chatOf(uid)}/e2/copies') {
      final peer = peerOf(uid);
      if (body['for_key_id'] != keys[peer]?['key_id']) {
        throw BackupHttpError(409, {'stale': true});
      }
      var stored = 0;
      for (final c in (body['copies'] as List)) {
        final m = Map<String, dynamic>.from(c as Map);
        expect(m.containsKey('text'), isFalse);
        expect(m.containsKey('plaintext'), isFalse);
        copies['${m['message_id']}|$peer'] = {
          'ciphertext': m['ciphertext'],
          'nonce': m['nonce'],
          'sender_key_id': m['sender_key_id'],
          'scheme': m['scheme'],
          'key_id': body['for_key_id'],
        };
        stored++;
      }
      if (body['done'] == true) {
        for (final r in requests.values) {
          if (r['requester'] == peer && r['target'] == uid) r['done'] = true;
        }
      }
      return {'ok': true, 'stored': stored};
    }
    if (path == '/circle/${chatOf(uid)}/e2/resend') {
      final peer = peerOf(uid);
      final kid = keys[uid]!['key_id'];
      final k = '$uid|$peer|$kid';
      final r = requests[k] ??= {
        'id': requests.length + 1,
        'requester': uid,
        'target': peer,
        'key_id': kid,
        'whole': false,
        'ids': <int>[],
      };
      r['done'] = false;
      (r['ids'] as List).addAll((body['message_ids'] as List).cast<int>());
      return {'ok': true, 'queued': true};
    }
    if (path == '/e2/backup') {
      for (final f in ['pin', 'private_key', 'plaintext']) {
        expect(body.containsKey(f), isFalse);
      }
      backups[uid] = {
        ...body,
        'auth_hash': _hash('${body['auth_key']}'),
      }..remove('auth_key');
      return {'ok': true};
    }
    if (path == '/e2/backup/open') {
      final b = backups[uid];
      if (b == null) throw BackupHttpError(404, {'exists': false});
      if ((wrong[uid] ?? 0) >= 5) {
        throw BackupHttpError(429, {'locked': true, 'attempts_left': 0});
      }
      for (final p in (body['proofs'] as List)) {
        if (_hash('${(p as Map)['auth_key']}') == b['auth_hash']) {
          wrong[uid] = 0;
          return {
            'ok': true,
            'slots': [
              {'slot': 0, 'blob': b['blob'], 'nonce': b['nonce']}
            ],
          };
        }
      }
      wrong[uid] = (wrong[uid] ?? 0) + 1;
      throw BackupHttpError(403, {'attempts_left': 5 - wrong[uid]!});
    }
    throw StateError('unknown POST $path');
  }
}

const _fastKdf = KdfParams(1024, 8, 1);
final _e2e = SoftwareE2E();

/// One phone of one account. [reinstall] = a fresh app sandbox.
class _Phone {
  _Phone(this.server, this.uid) {
    reinstall();
  }
  final _Server server;
  final int uid;
  late _Mem store;
  late IdentityVault vault;
  late KeyBackupService kb;
  late HistoryReshare hr;
  final List<String> events = [];

  void reinstall({String? restorePin}) {
    events.clear();
    store = _Mem();
    vault = IdentityVault(store: store);
    kb = KeyBackupService(
        vault: vault,
        store: store,
        params: _fastKdf,
        derive: (pin, salt, k) async =>
            deriveBackupKeys(pin, salt, k.n, k.r, k.p));
    kb.get = (p) => server.get(uid, p);
    kb.post = (p, b) => server.post(uid, p, b);
    kb.presenter = (meta) async {
      // the restore screen: it runs BEFORE any key exists on this phone
      events.add('restore-screen ring=${(await vault.ring()).length} '
          'slot=${store.m.containsKey(IdentityVault.slot)}');
      if (restorePin != null) await kb.restore(restorePin, meta: meta);
    };
    vault.beforeCreate = kb.gate;
    vault.onNewKey = (_) => events.add('new-key');
    hr = HistoryReshare(vault: vault);
    hr.get = (p) => server.get(uid, p);
    hr.post = (p, b) => server.post(uid, p, b);
  }

  Future<IdentityKeyPair> publish() async {
    final id = await vault.get();
    await server.post(uid, '/circle/keys',
        {'public_key': id.publicKeyB64, 'key_id': id.keyId, 'scheme': _e2e.scheme});
    return id;
  }

  Future<void> send(String text) async {
    final me = await vault.get();
    final peer = base64Decode(
        server.keys[_Server.peerOf(uid)]!['public_key'] as String);
    final ct = _e2e.encrypt(
        self: me, recipientPublicKey: Uint8List.fromList(peer), plaintext: text);
    server.msgs.add({
      'id': server._id++,
      'sender_id': uid,
      'content_type': 'text',
      'created_at': DateTime(2026, 10, 20).toIso8601String(),
      ...ct.toEnvelopeFields(),
    });
  }

  /// What this phone's chat shows (null = cannot open), oldest first.
  Future<List<String?>> read() async {
    final ring = await vault.ring();
    final k = await server.get(uid, '/circle/keys/peer/${_Server.chatOf(uid)}');
    final peers = RingDecrypt.keys([
      _b(k['public_key']),
      for (final h in (k['history'] as List)) _b((h as Map)['public_key']),
    ]);
    final r = await server.get(uid, '/circle/${_Server.chatOf(uid)}/messages?limit=50');
    return [
      for (final env in (r['results'] as List))
        RingDecrypt.openEnvelope(Map<String, dynamic>.from(env as Map),
            ring: ring, peerKeys: peers)
    ];
  }

  static Uint8List? _b(Object? s) {
    final v = '${s ?? ''}';
    if (v.isEmpty) return null;
    return Uint8List.fromList(base64Decode(v));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RingDecrypt.resetForTests();
    PlainCache.instance.resetForTests();
  });

  group('scrypt (RFC 7914 §12 vectors)', () {
    test('vector 1 and 2', () {
      expect(
          _hex(Scrypt.derive(const [], const [], n: 16, r: 1, p: 1)),
          '77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442'
          'fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906');
      expect(
          _hex(Scrypt.derive(utf8.encode('password'), utf8.encode('NaCl'),
              n: 1024, r: 8, p: 16)),
          'fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162'
          '2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640');
    });

    test('enc and auth keys differ; backup params are strong', () {
      final ks = deriveBackupKeys('482915', Uint8List(16), 1024, 8, 1);
      expect(_hex(ks[0]), isNot(_hex(ks[1])));
      expect(KdfParams.standard.n, 1 << 15);
      expect(KdfParams.standard.r, 8);
    });
  });

  group('key ring', () {
    test('a re-key never drops the old key; unreadable slot keeps ring key',
        () async {
      final s = _Mem();
      final v = IdentityVault(store: s);
      final first = await v.get();
      expect((await v.ring()).map((k) => k.keyId), [first.keyId]);
      // the current slot becomes unreadable: the ring still has the key
      s.m[IdentityVault.slot] = '{broken';
      final v2 = IdentityVault(store: s);
      final again = await v2.get();
      expect(again.keyId, first.keyId); // no key change for peers
      // a different key adopted from a backup joins the ring, current stays
      final other = _e2e.generateIdentity();
      await v2.adoptRing([other]);
      final ring = await IdentityVault(store: s).ring();
      expect(ring.first.keyId, first.keyId);
      expect(ring.map((k) => k.keyId), contains(other.keyId));
    });

    test('my own sent message opens with my OLD key from the ring', () {
      final old = _e2e.generateIdentity(), now = _e2e.generateIdentity();
      final peer = _e2e.generateIdentity();
      final ct = _e2e.encrypt(
          self: old, recipientPublicKey: peer.publicKey, plaintext: 'mine');
      expect(
          RingDecrypt.open(ring: [now], peerKeys: [peer.publicKey], ct: ct),
          isNull);
      expect(
          RingDecrypt.open(
              ring: [now, old], peerKeys: [peer.publicKey], ct: ct),
          'mine');
    });
  });

  group('two accounts, A reinstalls', () {
    late _Server server;
    late _Phone a, b;

    Future<IdentityKeyPair> setupChat({bool backup = true}) async {
      server = _Server();
      a = _Phone(server, 1);
      b = _Phone(server, 2);
      final ka = await a.publish();
      await b.publish();
      await a.send('hello Shanto');
      await b.send('hi Arif');
      await a.send('see you');
      if (backup) expect(await a.kb.backupWithPin('482915'), isTrue);
      expect(await a.read(), ['hello Shanto', 'hi Arif', 'see you']);
      expect(await b.read(), ['hello Shanto', 'hi Arif', 'see you']);
      return ka;
    }

    test('(a) restore with PIN: same key id, old + new messages on both sides',
        () async {
      final before = await setupChat();
      final blob = '${server.backups[1]!['blob']}';
      expect(blob, isNot(contains('hello')));
      expect(server.backups[1]!.containsKey('auth_key'), isFalse);

      a.reinstall(restorePin: '482915');
      final after = await a.publish();
      // the restore screen came BEFORE any key was generated
      expect(a.events.first, 'restore-screen ring=0 slot=false');
      expect(a.events, isNot(contains('new-key')));
      expect(after.keyId, before.keyId);
      expect(server.requests, isEmpty); // B sees no key change
      await b.send('after reinstall');
      await a.send('me too');
      expect(await a.read(),
          ['hello Shanto', 'hi Arif', 'see you', 'after reinstall', 'me too']);
      expect(await b.read(),
          ['hello Shanto', 'hi Arif', 'see you', 'after reinstall', 'me too']);
    });

    test('wrong PIN is counted; 5 wrong -> locked (even the right PIN)',
        () async {
      await setupChat();
      a.reinstall();
      final r1 = await a.kb.restore('000000');
      expect(r1.outcome, RestoreOutcome.wrongPin);
      expect(r1.attemptsLeft, 4);
      for (var i = 0; i < 4; i++) {
        await a.kb.restore('11111$i');
      }
      final r = await a.kb.restore('482915');
      expect(r.outcome, RestoreOutcome.locked);
      expect(await a.vault.ring(), isEmpty); // nothing restored
    });

    test('(b) skip restore: new key, B re-shares history, A opens it all',
        () async {
      final before = await setupChat(backup: false);
      a.reinstall(); // no backup -> no restore screen, a NEW key
      final after = await a.publish();
      expect(after.keyId, isNot(before.keyId));
      expect(a.events, contains('new-key'));
      // without help nothing old opens — not even A's own sent messages
      expect(await a.read(), [null, null, null]);

      // B's phone opens the app: serves the key-change request
      final n = await b.hr.serve(force: true);
      expect(n, 3);
      // originals untouched
      expect(server.msgs.every((m) => !m.containsKey('copy')), isTrue);
      expect(await a.read(), ['hello Shanto', 'hi Arif', 'see you']);
      // idempotent: nothing pending, serving again uploads nothing new
      expect(await b.hr.serve(force: true), 0);

      // new messages after the reinstall always work, both ways
      await b.send('welcome back');
      await a.send('thanks');
      expect((await a.read()).sublist(3), ['welcome back', 'thanks']);
      expect((await b.read()).sublist(3), ['welcome back', 'thanks']);
    });

    test('resend request: A asks for exactly the messages it cannot open',
        () async {
      await setupChat(backup: false);
      a.reinstall();
      await a.publish();
      server.requests.clear(); // e.g. an older server: no key-change request
      final ids = ['${server.msgs[1]['id']}'];
      expect(await a.hr.ask(5, ids), isTrue);
      expect(await a.hr.ask(5, ids), isFalse); // rate-limited: already asked
      expect(await b.hr.serve(force: true), 1);
      final got = await a.read();
      expect(got[1], 'hi Arif');
      expect(got[0], isNull); // not asked for (yet)
    });

    test('backup after re-key + PIN change keeps every key', () async {
      final first = await setupChat();
      // a later re-key on the same phone: the ring keeps the first key
      final second = _e2e.generateIdentity();
      await a.vault.adoptRing([second]);
      expect(await a.kb.backupNow(), isTrue);
      a.reinstall(restorePin: '482915');
      await a.vault.get();
      final ring2 = await a.vault.ring();
      expect(ring2.map((k) => k.keyId), containsAll([first.keyId, second.keyId]));
      expect(ring2.first.keyId, first.keyId);
    });
  });

  group('plaintext cache', () {
    test('survives a restart, capped, per account', () async {
      final s = _Mem();
      final c = PlainCache(store: s);
      await c.warm(1);
      c.put('10', 'hello');
      c.put('local-1', 'never cached'); // not a server id
      await c.persist();
      final c2 = PlainCache(store: s);
      await c2.warm(1);
      expect(c2.get('10'), 'hello');
      expect(c2.get('local-1'), isNull);
      final other = PlainCache(store: s);
      await other.warm(2);
      expect(other.get('10'), isNull);
      for (var i = 0; i < PlainCache.maxEntries + 5; i++) {
        c2.put('${1000 + i}', 'x');
      }
      expect(c2.length, PlainCache.maxEntries);
      expect(c2.get('10'), isNull); // oldest dropped first
    });
  });

  group('restore screen', () {
    testWidgets('bn: wrong PIN shows Bangla digits; Skip pops false',
        (tester) async {
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      final svc = _WrongPinService();
      bool? popped;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('bn'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
            builder: (ctx) => TextButton(
                onPressed: () async {
                  popped = await Navigator.of(ctx).push<bool>(
                      MaterialPageRoute(
                          builder: (_) => E2RestoreScreen(service: svc)));
                },
                child: const Text('open'))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(bn.e2rRestoreTitle), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.byKey(const Key('e2r-restore')));
      await tester.pumpAndSettle();
      expect(svc.tried, ['123456']);
      expect(find.text(bn.e2rWrongPin('৪')), findsOneWidget);
      await tester.tap(find.byKey(const Key('e2r-skip')));
      await tester.pumpAndSettle();
      expect(popped, isFalse);
    });
  });

  group('chat screen', () {
    late AppLocalizations t;
    setUpAll(() async {
      t = await AppLocalizations.delegate.load(const Locale('en'));
    });
    setUp(() => Outbox.instance.stop());

    testWidgets(
        'new key: copies open, own sent opens, unopenable = one grey line '
        '+ resend request; never the raw error', (tester) async {
      final oldMe = _e2e.generateIdentity();
      final newMe = _e2e.generateIdentity();
      final peer = _e2e.generateIdentity();
      Map<String, dynamic> env(int id, IdentityKeyPair from, Uint8List to,
              String text, {bool mine = false, Map<String, dynamic>? copy}) =>
          {
            'id': id,
            'sender_id': mine ? 1 : 2,
            'mine': mine,
            'content_type': 'text',
            'created_at': DateTime(2026, 10, 1, 9, id).toIso8601String(),
            ..._e2e
                .encrypt(self: from, recipientPublicKey: to, plaintext: text)
                .toEnvelopeFields(),
            if (copy != null) 'copy': copy,
          };
      Map<String, dynamic> copyOf(String text) {
        final c = _e2e.encrypt(
            self: peer, recipientPublicKey: newMe.publicKey, plaintext: text);
        return {...c.toEnvelopeFields(), 'key_id': newMe.keyId};
      }

      final api = _Api();
      api.replies['/circle/5/messages'] = {
        'results': [
          // old, re-shared by the peer's phone
          env(1, peer, oldMe.publicKey, 'old from peer',
              copy: copyOf('old from peer')),
          env(2, oldMe, peer.publicKey, 'old mine',
              mine: true, copy: copyOf('old mine')),
          // old, not re-shared yet
          env(3, peer, oldMe.publicKey, 'still waiting'),
          // new, after the reinstall
          env(4, peer, newMe.publicKey, 'new from peer'),
          env(5, newMe, peer.publicKey, 'new mine', mine: true),
        ],
      };
      api.replies['/circle/keys/peer/5'] = {'public_key': peer.publicKeyB64};
      HistoryReshare.instance.resetForTests();
      HistoryReshare.instance.post = api.postJson;

      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: AppState()..api = api,
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: CircleChatScreen(member: const {
            'id': 5,
            'name': 'T Shanto',
            'relation': 'friend',
            'state': 'accepted',
          }, identity: newMe),
        ),
      ));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      for (final s in [
        'old from peer',
        'old mine',
        'new from peer',
        'new mine',
      ]) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('still waiting'), findsNothing);
      expect(find.text(t.e2rWaiting('T Shanto')), findsOneWidget);
      expect(find.text(t.e2CantDecryptHere), findsNothing);
      expect(find.textContaining('decrypt'), findsNothing);
      // the phone asked the peer to re-share exactly message 3
      final asks = api.posts('/circle/5/e2/resend');
      expect(asks, isNotEmpty);
      expect(asks.last['message_ids'], [3]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      HistoryReshare.instance.resetForTests();
    });
  });
}

class _WrongPinService extends KeyBackupService {
  final List<String> tried = [];
  @override
  Future<RestoreResult> restore(String pin,
      {Map<String, dynamic>? meta, bool adoptOnly = false}) async {
    tried.add(pin);
    return const RestoreResult(RestoreOutcome.wrongPin, attemptsLeft: 4);
  }
}

class _Api extends ApiClient {
  _Api() {
    token = 'test';
  }
  final Map<String, Object> replies = {};
  final calls = <(String, String, Map<String, dynamic>)>[];

  Map<String, dynamic> _answer(String path) {
    final r = replies[path] ?? replies[path.split('?').first] ?? const {};
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
    return _answer(path);
  }

  List<Map<String, dynamic>> posts(String path) => [
        for (final c in calls)
          if (c.$1 == 'POST' && c.$2 == path) c.$3
      ];
}
