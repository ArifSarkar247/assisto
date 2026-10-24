// e2e-groups: peer-assisted re-share for GROUP chats. Three simulated
// accounts on a fake server that mirrors core/views_e2e_groups.py:
//   A, B, C talk in a group -> A reinstalls (new key, no PIN restore) ->
//   B's and C's phones BOTH serve the key-change request at the same time
//   -> exactly ONE copy per message reaches A (first copy wins) -> A reads
//   every old group message (incoming + its own sent) -> new messages work.
// Plus the ask flow and the group chat screen (copy opens, unopenable = one
// grey waiting line + an automatic resend request, never the raw error).
import 'dart:convert';
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/group_decrypt.dart';
import 'package:assisto/crypto/history_reshare.dart';
import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/crypto/plain_cache.dart';
import 'package:assisto/crypto/ring_decrypt.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:assisto/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

const _gid = 7;
int _mid(int uid) => 70 + uid; // CircleGroupMember id of user uid

/// Users 1 = A, 2 = B, 3 = C, all active members of group 7.
class _Server {
  final Map<int, Map<String, dynamic>> keys = {};
  final List<Map<String, dynamic>> msgs = [];
  // '<message>|<for_user>' -> copy (one row, like the unique constraint)
  final Map<String, Map<String, dynamic>> copies = {};
  final Map<String, Map<String, dynamic>> requests = {};
  int duplicates = 0;
  int _id = 100;
  final members = <int>{1, 2, 3};

  bool received(Map<String, dynamic> m, int uid) =>
      m['sender_id'] == uid ||
      (m['per_recipient'] as Map).containsKey('${_mid(uid)}');

  List<int> missing(Map<String, dynamic> r) {
    final uid = r['requester'] as int;
    return [
      for (final m in msgs)
        if (received(m, uid) &&
            (r['whole'] == true || (r['ids'] as List).contains(m['id'])) &&
            copies['${m['id']}|$uid']?['key_id'] != r['key_id'])
          m['id'] as int
    ];
  }

  Future<Map<String, dynamic>> get(int uid, String path) async {
    await Future<void>.delayed(Duration.zero); // a real network hop
    final p = path.split('?').first;
    if (p == '/circle/groups/$_gid/members') {
      if (!members.contains(uid)) throw StateError('404');
      return {
        'results': [
          for (final u in members)
            {
              'member_id': _mid(u),
              'user_id': u,
              'is_self': u == uid,
              'public_key': u == uid ? '' : keys[u]?['public_key'] ?? '',
              'key_history': u == uid
                  ? []
                  : [
                      for (final h in (keys[u]?['history'] as List? ?? []))
                        (h as Map)['public_key']
                    ],
            }
        ]
      };
    }
    if (p == '/circle/groups/$_gid/messages') {
      if (!members.contains(uid)) throw StateError('404');
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
      final groups = <Map<String, dynamic>>[];
      for (final r in requests.values) {
        final req = r['requester'] as int;
        if (req == uid || r['done'] == true) continue;
        if ((r['served_by'] as List).contains(uid)) continue;
        if (keys[req]?['key_id'] != r['key_id']) continue;
        final can = [
          for (final id in missing(r))
            if (received(msgs.firstWhere((m) => m['id'] == id), uid)) id
        ];
        if (can.isEmpty) continue;
        groups.add({
          'kind': 'group',
          'group_id': _gid,
          'user_id': req,
          'member_id': _mid(req),
          'my_member_id': _mid(uid),
          'key_id': r['key_id'],
          'public_key': keys[req]!['public_key'],
          'message_ids': can,
          'since': DateTime(2026, 1, 1).toIso8601String(),
        });
      }
      return {'results': [], 'groups': groups};
    }
    throw StateError('unknown GET $path');
  }

  Future<Map<String, dynamic>> post(
      int uid, String path, Map<String, dynamic> body) async {
    await Future<void>.delayed(Duration.zero);
    if (path == '/circle/keys') {
      final cur = keys[uid];
      final pub = body['public_key'];
      final changed = cur != null && cur['public_key'] != pub;
      keys[uid] = {
        'public_key': pub,
        'key_id': body['key_id'],
        'history': [
          if (changed) {'public_key': cur['public_key'], 'key_id': cur['key_id']},
          ...(cur?['history'] as List? ?? []),
        ],
      };
      if (changed) {
        requests['$uid|${body['key_id']}'] = {
          'requester': uid,
          'key_id': body['key_id'],
          'whole': true,
          'ids': <int>[],
          'served_by': <int>[],
        };
      }
      return {'ok': true, 'changed': changed};
    }
    if (path == '/circle/groups/$_gid/e2/copies') {
      final target = body['for_user_id'] as int;
      if (!members.contains(uid) || !members.contains(target)) {
        throw StateError('404');
      }
      if (body['for_key_id'] != keys[target]?['key_id']) {
        throw StateError('409');
      }
      var stored = 0;
      for (final c in (body['copies'] as List)) {
        final m = Map<String, dynamic>.from(c as Map);
        expect(m.containsKey('text'), isFalse);
        expect(m.containsKey('plaintext'), isFalse);
        final msg = msgs.firstWhere((x) => x['id'] == m['message_id']);
        if (!received(msg, target) || !received(msg, uid)) continue;
        final k = '${m['message_id']}|$target';
        if (copies[k]?['key_id'] == body['for_key_id']) {
          duplicates++; // first copy wins
          continue;
        }
        copies[k] = {
          'ciphertext': m['ciphertext'],
          'nonce': m['nonce'],
          'sender_key_id': m['sender_key_id'],
          'scheme': m['scheme'],
          'key_id': body['for_key_id'],
          'by': uid,
        };
        stored++;
      }
      for (final r in requests.values) {
        if (r['requester'] != target || r['key_id'] != body['for_key_id']) {
          continue;
        }
        if (body['done'] == true) (r['served_by'] as List).add(uid);
        if (missing(r).isEmpty) r['done'] = true;
      }
      return {'ok': true, 'stored': stored};
    }
    if (path == '/circle/groups/$_gid/e2/resend') {
      final kid = keys[uid]!['key_id'];
      final r = requests['$uid|$kid'] ??= {
        'requester': uid,
        'key_id': kid,
        'whole': false,
        'ids': <int>[],
        'served_by': <int>[],
      };
      r['done'] = false;
      r['served_by'] = <int>[];
      (r['ids'] as List).addAll((body['message_ids'] as List).cast<int>());
      return {'ok': true, 'queued': true};
    }
    throw StateError('unknown POST $path');
  }
}

final _e2e = SoftwareE2E();

class _Phone {
  _Phone(this.server, this.uid) {
    reinstall();
  }
  final _Server server;
  final int uid;
  late IdentityVault vault;
  late HistoryReshare hr;

  void reinstall() {
    vault = IdentityVault(store: _Mem());
    hr = HistoryReshare(vault: vault);
    hr.get = (p) => server.get(uid, p);
    hr.post = (p, b) => server.post(uid, p, b);
  }

  Future<IdentityKeyPair> publish() async {
    final id = await vault.get();
    await server.post(uid, '/circle/keys',
        {'public_key': id.publicKeyB64, 'key_id': id.keyId});
    return id;
  }

  /// Sealed once per other member (per_recipient keyed by member id).
  Future<void> send(String text) async {
    final me = await vault.get();
    final per = <String, dynamic>{};
    for (final u in server.members.where((u) => u != uid)) {
      final pub = base64Decode(server.keys[u]!['public_key'] as String);
      final ct = _e2e.encrypt(
          self: me, recipientPublicKey: Uint8List.fromList(pub), plaintext: text);
      per['${_mid(u)}'] = {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64};
    }
    server.msgs.add({
      'id': server._id++,
      'sender_id': uid,
      'content_type': 'text',
      'created_at': DateTime(2026, 10, 20).toIso8601String(),
      'per_recipient': per,
      'recipient_ids': [for (final k in per.keys) int.parse(k)],
      'sender_key_id': me.keyId,
      'scheme': _e2e.scheme,
    });
  }

  /// What this phone's group chat shows (null = cannot open), oldest first.
  Future<List<String?>> read() async {
    final ring = await vault.ring();
    final mem = await server.get(uid, '/circle/groups/$_gid/members');
    final roster = [
      for (final r in (mem['results'] as List))
        Map<String, dynamic>.from(r as Map)
    ];
    final r = await server.get(uid, '/circle/groups/$_gid/messages?limit=50');
    return [
      for (final env in (r['results'] as List))
        GroupDecrypt.open(Map<String, dynamic>.from(env as Map),
            ring: ring,
            myMemberId: '${_mid(uid)}',
            myUserId: '$uid',
            roster: roster)
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RingDecrypt.resetForTests();
    PlainCache.instance.resetForTests();
  });

  group('three accounts, A reinstalls', () {
    late _Server server;
    late _Phone a, b, c;
    const old = ['hello all', 'hi from B', 'C here', 'A again'];

    Future<void> setupGroup() async {
      server = _Server();
      a = _Phone(server, 1);
      b = _Phone(server, 2);
      c = _Phone(server, 3);
      await a.publish();
      await b.publish();
      await c.publish();
      await a.send(old[0]);
      await b.send(old[1]);
      await c.send(old[2]);
      await a.send(old[3]);
      for (final p in [a, b, c]) {
        expect(await p.read(), old);
      }
    }

    test('B and C both re-share -> exactly one copy per message; A reads all',
        () async {
      await setupGroup();
      a.reinstall();
      await a.publish();
      // without help nothing old opens — not even A's own sent messages
      expect(await a.read(), [null, null, null, null]);
      // B still opens A's OLD messages (A's earlier key from the roster)
      expect(await b.read(), old);

      // B's and C's phones serve the key-change request AT THE SAME TIME
      final n = await Future.wait(
          [b.hr.serve(force: true), c.hr.serve(force: true)]);
      expect(n[0] + n[1], 4); // one stored copy per old message
      expect(server.duplicates, greaterThan(0)); // the loser was skipped
      final forA = server.copies.keys.where((k) => k.endsWith('|1')).toList();
      expect(forA.length, 4);
      expect(forA.toSet().length, 4);
      // originals untouched
      expect(server.msgs.every((m) => !m.containsKey('copy')), isTrue);
      expect(await a.read(), old);

      // nothing pending any more: serving again uploads nothing
      expect(await b.hr.serve(force: true), 0);
      expect(await c.hr.serve(force: true), 0);

      // new messages after the reinstall work for everyone
      await b.send('welcome back');
      await a.send('thanks');
      for (final p in [a, b, c]) {
        expect((await p.read()).sublist(4), ['welcome back', 'thanks']);
      }
    });

    test('a helper only re-shares what it received itself', () async {
      await setupGroup();
      // a message B -> C only (A was not a recipient)
      final me = await b.vault.get();
      final ct = _e2e.encrypt(
          self: me,
          recipientPublicKey: Uint8List.fromList(
              base64Decode(server.keys[3]!['public_key'] as String)),
          plaintext: 'not for A');
      server.msgs.add({
        'id': server._id++,
        'sender_id': 2,
        'content_type': 'text',
        'per_recipient': {
          '${_mid(3)}': {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64}
        },
        'sender_key_id': me.keyId,
        'scheme': _e2e.scheme,
      });
      a.reinstall();
      await a.publish();
      await b.hr.serve(force: true);
      expect(server.copies.keys.where((k) => k.endsWith('|1')).length, 4);
      expect(server.copies.containsKey('${server.msgs.last['id']}|1'), isFalse);
      expect((await a.read()).sublist(0, 4), old);
    });

    test('resend request: A asks; rate-limited; C serves', () async {
      await setupGroup();
      a.reinstall();
      await a.publish();
      server.requests.clear(); // e.g. an older server: no key-change request
      final ids = ['${server.msgs[1]['id']}'];
      expect(await a.hr.askGroup(_gid, ids), isTrue);
      expect(await a.hr.askGroup(_gid, ids), isFalse); // already asked
      expect(await c.hr.serve(force: true), 1);
      final got = await a.read();
      expect(got[1], 'hi from B');
      expect(got[0], isNull); // not asked for (yet)
    });
  });

  group('group chat screen', () {
    late AppLocalizations t;
    setUpAll(() async {
      t = await AppLocalizations.delegate.load(const Locale('en'));
    });
    setUp(() => Outbox.instance.stop());

    testWidgets(
        'new key: copies open, unopenable = one grey line + group resend '
        'request; never the raw error', (tester) async {
      final oldMe = _e2e.generateIdentity();
      final newMe = _e2e.generateIdentity();
      final peer = _e2e.generateIdentity();
      Map<String, dynamic> env(int id, String text,
          {Map<String, dynamic>? copy}) {
        final c = _e2e.encrypt(
            self: peer, recipientPublicKey: oldMe.publicKey, plaintext: text);
        return {
          'id': id,
          'sender_id': 2,
          'mine': false,
          'content_type': 'text',
          'created_at': DateTime(2026, 10, 1, 9, id).toIso8601String(),
          'per_recipient': {
            '1': {'ciphertext': c.ciphertextB64, 'nonce': c.nonceB64}
          },
          'sender_key_id': peer.keyId,
          'scheme': c.scheme,
          if (copy != null) 'copy': copy,
        };
      }

      final cp = _e2e.encrypt(
          self: peer, recipientPublicKey: newMe.publicKey, plaintext: 're-shared');
      final api = _Api();
      api.replies['/circle/groups/7/members'] = {
        'results': [
          {'id': 1, 'user_id': 1, 'name': 'Me', 'is_self': true, 'public_key': ''},
          {
            'id': 2,
            'user_id': 2,
            'name': 'Abul',
            'is_self': false,
            'public_key': peer.publicKeyB64,
          },
        ]
      };
      api.replies['/circle/groups/7/messages'] = {
        'results': [
          env(11, 're-shared', copy: {
            ...cp.toEnvelopeFields(),
            'sender_key_id': peer.keyId,
            'key_id': newMe.keyId,
            'by': 2,
          }),
          env(12, 'still waiting'),
        ],
      };
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
          home: CircleGroupChatScreen(
              group: const {'id': 7, 'name': 'Family', 'my_member_id': 1},
              identity: newMe),
        ),
      ));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('re-shared', findRichText: true), findsOneWidget);
      expect(find.text('still waiting', findRichText: true), findsNothing);
      expect(find.text(t.e2rWaiting('Abul')), findsOneWidget);
      expect(find.text(t.e2CantDecryptHere), findsNothing);
      expect(find.textContaining('decrypt'), findsNothing);
      // the ask waits until the key ring was tried (or 4 s)
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 100));
      final asks = api.posts('/circle/groups/7/e2/resend');
      expect(asks, isNotEmpty);
      expect(asks.last['message_ids'], [12]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      HistoryReshare.instance.resetForTests();
    });
  });
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
