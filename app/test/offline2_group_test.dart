// offline2: a GROUP message written offline waits in the (encrypted) outbox
// as a ready per-recipient envelope and is sent in order when the network is
// back — same client_msg_id (server dedupes), ciphertext only, never twice.
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/messaging/msg_ticks.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _T implements OutboxTransport, GroupOutboxTransport {
  bool down = false;
  final groupPosts = <(int, Map<String, dynamic>)>[];
  final memberPosts = <(int, Map<String, dynamic>)>[];
  String? key;

  @override
  Future<Map<String, dynamic>> peerKey(int memberId) async {
    if (down) throw Exception('offline');
    return {'public_key': key ?? ''};
  }

  @override
  Future<Map<String, dynamic>> send(int memberId, Map<String, dynamic> env) async {
    if (down) throw Exception('offline');
    memberPosts.add((memberId, env));
    return {'id': memberPosts.length};
  }

  @override
  Future<Map<String, dynamic>> sendGroup(int groupId, Map<String, dynamic> env) async {
    if (down) throw Exception('offline');
    groupPosts.add((groupId, env));
    return {'id': groupPosts.length};
  }
}

Map<String, dynamic> _env(String cmid) => {
      'recipient_ids': [11, 12],
      'per_recipient': {
        '11': {'ciphertext': 'Y3QxMQ==', 'nonce': 'bjE='},
        '12': {'ciphertext': 'Y3QxMg==', 'nonce': 'bjI='},
      },
      'sender_key_id': 'k1',
      'scheme': 'x25519-chacha20poly1305',
      'client_msg_id': cmid,
    };

OutboxItem _g(String id, int group, DateTime at) => OutboxItem(
    id: id, chatKind: 'group', chatId: group, text: 'plain $id', at: at, envelope: _env(id));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final me = SoftwareE2E().generateIdentity();

  test('envelope survives a restart (json round trip)', () async {
    await Outbox().add(_g('local-1', 4, DateTime(2026, 11, 10, 9)));
    final again = await Outbox().forChat('group', 4);
    expect(again.single.envelope!['client_msg_id'], 'local-1');
    expect(again.single.envelope!['per_recipient'], isA<Map>());
  });

  test('offline: nothing goes and the order is kept; online: sent in order, once', () async {
    final ob = Outbox();
    await ob.add(_g('local-2', 4, DateTime(2026, 11, 10, 9, 2)));
    await ob.add(_g('local-1', 4, DateTime(2026, 11, 10, 9, 1)));
    final t = _T()..down = true;
    var r = await ob.flush(transport: t, identity: () async => me);
    expect(r.sent, isEmpty);
    expect((await ob.all()).length, 2);

    t.down = false;
    r = await ob.flush(transport: t, identity: () async => me);
    expect(r.sent, ['local-1', 'local-2']);
    expect(t.groupPosts.map((p) => p.$1), [4, 4]);
    expect(t.groupPosts.map((p) => p.$2['client_msg_id']), ['local-1', 'local-2']);
    for (final p in t.groupPosts) {
      expect(p.$2.containsKey('text'), isFalse, reason: 'ciphertext only');
    }
    expect(await ob.all(), isEmpty);
    // a second flush sends nothing again (no duplicates)
    r = await ob.flush(transport: t, identity: () async => me);
    expect(r.sent, isEmpty);
    expect(t.groupPosts.length, 2);
  });

  test('a 1:1 chat flush (onlyChat) never sends group items; onlyGroup only that group', () async {
    final ob = Outbox();
    await ob.add(_g('g4', 4, DateTime(2026, 11, 10, 9)));
    await ob.add(_g('g9', 9, DateTime(2026, 11, 10, 9, 1)));
    final t = _T();
    await ob.flush(transport: t, identity: () async => me, onlyChat: 4);
    expect(t.groupPosts, isEmpty);
    await ob.flush(transport: t, identity: () async => me, onlyGroup: 9);
    expect(t.groupPosts.map((p) => p.$2['client_msg_id']), ['g9']);
    expect((await ob.all()).single.id, 'g4');
  });

  test('FnOutboxTransport posts a group envelope to the group endpoint', () async {
    final calls = <String>[];
    final t = FnOutboxTransport(
        get: (p) async => {},
        post: (p, b) async {
          calls.add(p);
          return {};
        });
    await t.sendGroup(7, _env('x'));
    expect(calls, ['/circle/groups/7/messages']);
  });

  test('a queued bubble shows the clock', () {
    expect(tickFrom('pending'), MsgTick.pending);
    expect(tickFrom('queued'), MsgTick.pending);
    expect(tickFrom('sent'), MsgTick.sent);
  });
}
