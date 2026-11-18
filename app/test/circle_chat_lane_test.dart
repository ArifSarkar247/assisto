// circle-chat (18 Nov): a group message queued OFFLINE is sealed with the
// roster the phone knew. If every member it was sealed for left meanwhile,
// the server answers 409 members_changed — the queue must drop that one
// message and keep sending the rest (it used to block the group forever).
import 'package:assisto/api.dart' show ApiException;
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _T implements OutboxTransport, GroupOutboxTransport {
  final posts = <String>[];
  final refuse = <String>{};

  @override
  Future<Map<String, dynamic>> peerKey(int memberId) async => {'public_key': ''};

  @override
  Future<Map<String, dynamic>> send(int memberId, Map<String, dynamic> env) async => {'id': 1};

  @override
  Future<Map<String, dynamic>> sendGroup(int groupId, Map<String, dynamic> env) async {
    final id = '${env['client_msg_id']}';
    if (refuse.contains(id)) {
      throw ApiException('members_changed', 409, null, 'members_changed');
    }
    posts.add(id);
    return {'id': posts.length};
  }
}

OutboxItem _g(String id, DateTime at) => OutboxItem(
    id: id,
    chatKind: 'group',
    chatId: 5,
    text: 'plain $id',
    at: at,
    envelope: {
      'recipient_ids': [11],
      'per_recipient': {
        '11': {'ciphertext': 'Y3Q=', 'nonce': 'bjE='}
      },
      'client_msg_id': id,
    });

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final me = SoftwareE2E().generateIdentity();

  test('isMembersChanged: only a 409 members_changed', () {
    expect(isMembersChanged(ApiException('x', 409, null, 'members_changed')), isTrue);
    expect(isMembersChanged(ApiException('x', 409, null, 'other')), isFalse);
    expect(isMembersChanged(ApiException('x', 500)), isFalse);
    expect(isMembersChanged(Exception('offline')), isFalse);
  });

  test('a queued message for members who all left is dropped; the rest still go, in order',
      () async {
    final ob = Outbox();
    await ob.add(_g('q1', DateTime(2026, 11, 18, 9, 1)));
    await ob.add(_g('q2', DateTime(2026, 11, 18, 9, 2)));
    await ob.add(_g('q3', DateTime(2026, 11, 18, 9, 3)));
    final t = _T()..refuse.add('q2');
    final r = await ob.flush(transport: t, identity: () async => me);
    expect(t.posts, ['q1', 'q3']);
    expect(r.waiting, 0);
    expect(await ob.all(), isEmpty);
  });
}
