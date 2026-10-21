// m1-messenger: one test per client method of messenger_chat_api /
// messenger_group_api / messenger_setapi / famacct_api — the REAL ApiClient
// against a mocked HTTP layer (http.runWithClient), checking method, path,
// body and the parsed result; plus config path normalisation, honest errors
// and the device-side group export builder.
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/famacct_api.dart';
import 'package:assisto/messenger_chat_api.dart';
import 'package:assisto/messenger_group_api.dart';
import 'package:assisto/messenger_setapi.dart';
import 'package:assisto/widgets/group_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Seen {
  String method = '';
  String path = '';
  String query = '';
  Map<String, dynamic>? body;
}

/// Run [call] on a real ApiClient whose HTTP client answers [reply].
Future<(Map<String, dynamic>, _Seen)> _run(
  Future<Map<String, dynamic>> Function(ApiClient api) call, {
  Map<String, dynamic> reply = const {'ok': true},
  int status = 200,
}) async {
  final seen = _Seen();
  final mock = MockClient((req) async {
    seen.method = req.method;
    seen.path = req.url.path;
    seen.query = req.url.query;
    seen.body = req.body.isEmpty
        ? null
        : (jsonDecode(req.body) as Map).cast<String, dynamic>();
    return http.Response(jsonEncode(reply), status,
        headers: {'content-type': 'application/json'});
  });
  final out = await http.runWithClient(() async {
    final api = ApiClient(token: 't');
    return call(api);
  }, () => mock);
  return (out, seen);
}

typedef _Case = ({
  String name,
  Future<Map<String, dynamic>> Function(ApiClient) call,
  String method,
  String path,
  Map<String, dynamic>? body,
  Map<String, dynamic> reply,
});

void main() {
  const p = '/api/v1';
  final cases = <_Case>[
    // ---------------- 1:1 chat ----------------
    (name: 'contactInfo', call: (a) => a.contactInfo(5), method: 'GET',
        path: '$p/circle/5/info', body: null,
        reply: {'id': 5, 'media_count': 2, 'groups_in_common': []}),
    (name: 'setChatMute', call: (a) => a.setChatMute(5, '2099-01-01T00:00:00Z'),
        method: 'POST', path: '$p/circle/5/controls',
        body: {'muted_until': '2099-01-01T00:00:00Z'},
        reply: {'ok': true, 'muted_until': '2099-01-01T00:00:00Z'}),
    (name: 'setChatMute(unmute)', call: (a) => a.setChatMute(5, null),
        method: 'POST', path: '$p/circle/5/controls',
        body: {'muted_until': null}, reply: {'ok': true, 'muted_until': null}),
    (name: 'setDisappearing', call: (a) => a.setDisappearing(5, 86400),
        method: 'POST', path: '$p/messenger/chat/5/settings',
        body: {'disappearing_sec': 86400},
        reply: {'ok': true, 'disappearing_sec': 86400}),
    (name: 'setChatTheme', call: (a) => a.setChatTheme(5, theme: 'dark'),
        method: 'POST', path: '$p/messenger/chat/5/settings',
        body: {'theme': 'dark'}, reply: {'ok': true, 'theme': 'dark'}),
    (name: 'setFavourite', call: (a) => a.setFavourite(5, true),
        method: 'POST', path: '$p/circle/5/controls',
        body: {'favourite': true}, reply: {'ok': true, 'favourite': true}),
    (name: 'clearChat', call: (a) => a.clearChat(5), method: 'POST',
        path: '$p/circle/5/clear', body: null,
        reply: {'ok': true, 'cleared_at': '2026-10-21T00:00:00Z'}),
    (name: 'blockContact', call: (a) => a.blockContact(5), method: 'POST',
        path: '$p/circle/5/controls', body: {'blocked': true},
        reply: {'ok': true, 'blocked': true}),
    (name: 'chatLists', call: (a) => a.chatLists(), method: 'GET',
        path: '$p/messenger/lists', body: null, reply: {'lists': []}),
    // ---------------- group ⋮ ----------------
    (name: 'groupSetMute', call: (a) => a.groupSetMute('7', '8h'),
        method: 'POST', path: '$p/circle/groups/7/mute',
        body: {'duration': '8h'},
        reply: {'ok': true, 'muted': true, 'mute': '8h'}),
    (name: 'groupSetDisappearing', call: (a) => a.groupSetDisappearing('7', '24h'),
        method: 'POST', path: '$p/circle/groups/7/disappearing',
        body: {'ttl': '24h'}, reply: {'ok': true, 'disappearing_sec': 86400}),
    (name: 'groupSetTheme', call: (a) => a.groupSetTheme('7', color: 'ocean'),
        method: 'POST', path: '$p/circle/groups/7/theme',
        body: {'color': 'ocean'}, reply: {'ok': true, 'theme': 'ocean'}),
    (name: 'groupSetFavourite', call: (a) => a.groupSetFavourite('7', true),
        method: 'POST', path: '$p/circle/groups/7/favourite',
        body: {'on': true}, reply: {'ok': true, 'favourite': true}),
    (name: 'groupClear', call: (a) => a.groupClear('7'), method: 'POST',
        path: '$p/circle/groups/7/clear', body: null, reply: {'ok': true}),
    (name: 'groupExport', call: (a) => a.groupExport('7'), method: 'GET',
        path: '$p/circle/groups/7/export', body: null,
        reply: {'url': '/api/v1/m/msg_exports/x.json?e=1&s=2',
            'message_count': 3, 'encrypted': true}),
    (name: 'groupAiTask', call: (a) => a.groupAiTask('7', 'translate',
            messages: ['hi'], targetLang: 'bn'),
        method: 'POST', path: '$p/circle/groups/7/ai/translate',
        body: {'messages': ['hi'], 'target_lang': 'bn'},
        reply: {'allowed': false, 'reason': 'no_key', 'message': 'AI off'}),
    (name: 'groupCallLink', call: (a) => a.groupCallLink('7'), method: 'POST',
        path: '$p/messenger/call-link', body: {'kind': 'voice'},
        reply: {'url': 'https://x/y'}),
    (name: 'communitySetNotifications',
        call: (a) => a.communitySetNotifications('3', true), method: 'POST',
        path: '$p/community/3/notifications', body: {'muted': true},
        reply: {'ok': true, 'notifications_muted': true}),
    (name: 'communityLeave', call: (a) => a.communityLeave('3'),
        method: 'POST', path: '$p/community/3/leave', body: null,
        reply: {'allowed': false, 'left': false,
            'reason': 'promote_before_leaving'}),
    // ---------------- settings ----------------
    (name: 'twoStepStatus', call: (a) => a.twoStepStatus(), method: 'GET',
        path: '$p/circle/account/two-step', body: null,
        reply: {'enabled': true, 'locked': false}),
    (name: 'twoStepSet', call: (a) => a.twoStepSet(
            enabled: true, pin: '123456', currentPin: '111111'),
        method: 'POST', path: '$p/circle/account/two-step',
        body: {'enabled': true, 'pin': '123456', 'current_pin': '111111'},
        reply: {'ok': true, 'enabled': true}),
    (name: 'twoStepVerify', call: (a) => a.twoStepVerify('123456'),
        method: 'POST', path: '$p/circle/account/two-step/verify',
        body: {'pin': '123456'}, reply: {'ok': true}),
    (name: 'changeNumberStatus', call: (a) => a.changeNumberStatus(),
        method: 'GET', path: '$p/circle/account/change-number', body: null,
        reply: {'sms_enabled': false, 'two_step_required': true}),
    (name: 'changeNumberRequest', call: (a) => a.changeNumberRequest(' 0171 '),
        method: 'POST', path: '$p/circle/account/change-number/request',
        body: {'new_phone': '0171'}, reply: {'ok': true, 'sent': true}),
    (name: 'changeNumberConfirm', call: (a) => a.changeNumberConfirm(
            newPhone: '0171', code: '424242', pin: '123456'),
        method: 'POST', path: '$p/circle/account/change-number/confirm',
        body: {'new_phone': '0171', 'code': '424242', 'pin': '123456'},
        reply: {'ok': true, 'phone': '0171'}),
    (name: 'blockedList', call: (a) => a.blockedList(), method: 'GET',
        path: '$p/circle/blocked', body: null,
        reply: {'blocked': [{'id': 1, 'name': 'B'}]}),
    (name: 'unblock', call: (a) => a.unblock(1), method: 'POST',
        path: '$p/circle/1/controls', body: {'blocked': false},
        reply: {'ok': true}),
    (name: 'messageRequests', call: (a) => a.messageRequests(), method: 'GET',
        path: '$p/circle/message-requests', body: null,
        reply: {'requests': [{'id': 9, 'ciphertext': 'Q1Q='}]}),
    (name: 'messageRequestAct', call: (a) => a.messageRequestAct('9', 'report',
            reason: 'spam', alsoBlock: true),
        method: 'POST', path: '$p/circle/message-requests/9',
        body: {'action': 'report', 'reason': 'spam', 'also_block': true},
        reply: {'ok': true, 'blocked': true}),
    (name: 'messagePrivacy', call: (a) => a.messagePrivacy(), method: 'GET',
        path: '$p/circle/settings/message-privacy', body: null,
        reply: {'who_can_message': 'my_circle', 'phone_hidden': true}),
    (name: 'setMessagePrivacy', call: (a) => a.setMessagePrivacy(
            {'who_can_message': 'everyone'}),
        method: 'POST', path: '$p/circle/settings/message-privacy',
        body: {'who_can_message': 'everyone'}, reply: {'ok': true}),
    (name: 'notificationPrefs', call: (a) => a.notificationPrefs(),
        method: 'GET', path: '$p/circle/settings/notifications', body: null,
        reply: {'messages': true, 'groups': false}),
    (name: 'setNotificationPrefs', call: (a) => a.setNotificationPrefs(
            {'groups': false}),
        method: 'POST', path: '$p/circle/settings/notifications',
        body: {'groups': false}, reply: {'ok': true, 'groups': false}),
    (name: 'callPrefs', call: (a) => a.callPrefs(), method: 'GET',
        path: '$p/circle/settings/calls', body: null,
        reply: {'incoming_calls': true, 'silence_unknown': false}),
    (name: 'setCallPrefs', call: (a) => a.setCallPrefs({'incoming_calls': false}),
        method: 'POST', path: '$p/circle/settings/calls',
        body: {'incoming_calls': false}, reply: {'ok': true}),
    (name: 'storageUsage', call: (a) => a.storageUsage(), method: 'GET',
        path: '$p/circle/settings/storage', body: null,
        reply: {'total_bytes': 5000, 'quota_bytes': 1 << 30,
            'backup_bytes': 0}),
    (name: 'setStoragePrefs', call: (a) => a.setStoragePrefs(
            {'auto_download': {'video': true}}),
        method: 'POST', path: '$p/circle/settings/storage',
        body: {'auto_download': {'video': true}}, reply: {'ok': true}),
    // ---------------- family accounting ----------------
    (name: 'famAcctSummary', call: (a) => a.famAcctSummary(month: '2026-10'),
        method: 'GET', path: '$p/family/accounting/summary', body: null,
        reply: {'total_poisha': 1000, 'settlements': []}),
    (name: 'famAcctExpenses', call: (a) => a.famAcctExpenses(), method: 'GET',
        path: '$p/family/accounting/expenses', body: null,
        reply: {'expenses': []}),
    (name: 'famAcctAddExpense', call: (a) => a.famAcctAddExpense(
            {'payer': 'self', 'total_poisha': 100, 'members': ['self']}),
        method: 'POST', path: '$p/family/accounting/expenses',
        body: {'payer': 'self', 'total_poisha': 100, 'members': ['self']},
        reply: {'id': 1}),
    (name: 'famAcctDeleteExpense', call: (a) => a.famAcctDeleteExpense(1),
        method: 'POST', path: '$p/family/accounting/expenses/delete',
        body: {'id': 1}, reply: {'ok': true}),
    (name: 'famAcctPool', call: (a) => a.famAcctPool(), method: 'GET',
        path: '$p/family/accounting/pool', body: null, reply: {'target': 0}),
    (name: 'famAcctSetPoolTarget', call: (a) => a.famAcctSetPoolTarget(500),
        method: 'POST', path: '$p/family/accounting/pool',
        body: {'target_poisha': 500}, reply: {'target': 500}),
    (name: 'famAcctContribute', call: (a) => a.famAcctContribute('self', 50),
        method: 'POST', path: '$p/family/accounting/pool/contribute',
        body: {'member': 'self', 'amount_poisha': 50}, reply: {'collected': 50}),
    (name: 'famAcctSettle', call: (a) => a.famAcctSettle(4, 'self', 300),
        method: 'POST', path: '$p/family/accounting/settle',
        body: {'from': 4, 'to': 'self', 'amount_poisha': 300},
        reply: {'ok': true, 'remaining': []}),
  ];

  for (final c in cases) {
    test('${c.name}: ${c.method} ${c.path}', () async {
      final (out, seen) = await _run(c.call, reply: c.reply);
      expect(seen.method, c.method);
      expect(seen.path, c.path);
      if (c.body != null) {
        expect(seen.body, c.body);
      } else if (c.method == 'POST') {
        expect(seen.body ?? const {}, isEmpty);
      }
      expect(out, c.reply); // parsed back verbatim
    });
  }

  test('groupExport sends the media flag as a query', () async {
    final (_, seen) = await _run((a) => a.groupExport('7', withMedia: true));
    expect(seen.query, 'media=true');
  });

  test('a refusal surfaces as ApiException (no silent fallback)', () async {
    expect(
      () => _run((a) => a.twoStepSet(enabled: false),
          reply: {'detail': 'current_pin_required'}, status: 403),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 403)
          .having((e) => e.message, 'message', 'current_pin_required')),
    );
    expect(
      () => _run((a) => a.changeNumberRequest('01799999999'),
          reply: {'detail': 'SMS not configured', 'code': 'sms_not_configured'},
          status: 503),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 503)),
    );
  });

  test('AppConfig.api adds a missing leading slash', () {
    expect(AppConfig.api('messenger/lists').path, '/api/v1/messenger/lists');
    expect(AppConfig.api('/circle/chats').path, '/api/v1/circle/chats');
  });

  group('buildGroupExportText', () {
    const labels = GroupExportLabels(
        header: 'Exported', unreadable: '[locked]', deleted: '[deleted]',
        media: '[media]', you: 'You');
    final data = {
      'group': {'name': 'Family'},
      'exported_at': '2026-10-21T10:00:00Z',
      'messages': [
        {'sender_id': 2, 'sender_name': 'Bilal', 'type': 'text',
          'at': '2026-10-21T09:00:00Z',
          'envelope': {'ciphertext': 'A', 'nonce': 'N'}},
        {'sender_id': 1, 'sender_name': 'Amina', 'type': 'text',
          'at': '2026-10-21T09:01:00Z',
          'envelope': {'ciphertext': 'B', 'nonce': 'N', 'peer_member_id': '4'}},
        {'sender_id': 2, 'sender_name': 'Bilal', 'type': 'text',
          'at': '2026-10-21T09:02:00Z', 'envelope': null},
        {'sender_id': 2, 'sender_name': 'Bilal', 'type': 'image',
          'at': '2026-10-21T09:03:00Z'},
        {'sender_id': 2, 'sender_name': 'Bilal', 'type': 'text',
          'deleted': true, 'at': '2026-10-21T09:04:00Z'},
      ],
    };
    test('decrypts on device, labels the rest honestly', () {
      final txt = buildGroupExportText(data,
          myUserId: 1,
          labels: labels,
          decrypt: (env, sid, kid) =>
              env['ciphertext'] == 'A' ? 'hello' : (env['peer_member_id'] == '4' ? 'mine' : null));
      final lines = txt.trim().split('\n');
      expect(lines.first, 'Family');
      expect(txt, contains('Bilal: hello'));
      expect(txt, contains('You: mine'));
      expect(txt, contains('Bilal: [locked]'));
      expect(txt, contains('Bilal: [media]'));
      expect(txt, contains('Bilal: [deleted]'));
    });
    test('safe file name', () {
      expect(exportFileName('A/B: c'), 'A B  c.txt');
      expect(exportFileName(''), 'group.txt');
    });
  });
}
