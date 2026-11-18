// gap-circle (17 Nov gap sweep): group-chat basics a user expects —
//  * every text bubble shows its time (+ "edited");
//  * a reply shows the quoted original (it was sent but never shown);
//  * a message deleted for everyone says so (it was an empty bubble);
//  * long-press: star, edit (my text, 15 min), delete for me / everyone;
//  * edit re-seals the new text to every member (ciphertext only).
import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/group_msg_actions.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/screens/circle_call_history_screen.dart';
import 'package:assisto/screens/circle_group_chat_screen.dart';
import 'package:assisto/screens/circle_search_screen.dart';
import 'package:assisto/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();

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
    return _answer(path);
  }

  List<Map<String, dynamic>> posts(String path) => [
        for (final c in calls)
          if (c.$1 == 'POST' && c.$2 == path) c.$3
      ];
}

const _group7 = {'id': 7, 'name': 'Family', 'my_member_id': 1};

Map<String, dynamic> _roster7() => {
      'results': [
        {'id': 1, 'user_id': 1, 'name': 'Me', 'is_self': true, 'public_key': _me.publicKeyB64},
        {'id': 2, 'user_id': 2, 'name': 'Abul', 'public_key': _peer.publicKeyB64},
      ]
    };

String _ago(int min) =>
    DateTime.now().subtract(Duration(minutes: min)).toUtc().toIso8601String();

Map<String, dynamic> _fromPeer(int id, String text, {Object? replyTo}) => {
      'id': id,
      'sender_id': 2,
      'mine': false,
      'content_type': 'text',
      'created_at': _ago(5),
      'per_recipient': null,
      if (replyTo != null) 'reply_to': replyTo,
      ..._e2e
          .encrypt(self: _peer, recipientPublicKey: _me.publicKey, plaintext: text)
          .toEnvelopeFields(),
    };

Map<String, dynamic> _mine(int id, String text, {int ago = 2, String? editedAt}) {
  final ct = _e2e.encrypt(self: _me, recipientPublicKey: _peer.publicKey, plaintext: text);
  return {
    'id': id,
    'sender_id': 1,
    'mine': true,
    'content_type': 'text',
    'created_at': _ago(ago),
    'sender_key_id': _me.keyId,
    'edited_at': editedAt,
    'status': 'sent',
    'per_recipient': {
      '2': {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64}
    },
  };
}

List<Map<String, dynamic>> _thread() => [
      _fromPeer(101, 'Dinner at 8?'),
      _mine(102, 'Yes, see you', editedAt: _ago(1)),
      _fromPeer(103, 'Great', replyTo: 102),
      {
        'id': 104, 'sender_id': 2, 'mine': false, 'content_type': 'text',
        'created_at': _ago(3), 'deleted': 'everyone', 'per_recipient': null,
      },
      _mine(105, 'Old one', ago: 60),
    ];

Future<_Api> _open(WidgetTester tester, {String lang = 'en'}) async {
  final api = _Api();
  api.replies['/circle/groups/7/members'] = _roster7();
  api.replies['/circle/groups/7/messages'] = () => {'results': _thread()};
  await tester.binding.setSurfaceSize(const Size(400, 900));
  final app = AppState()..api = api;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: CircleGroupChatScreen(group: _group7, identity: _me),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 500));
  return api;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

late AppLocalizations en;

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Outbox.instance.stop();
  });

  group('rules (pure)', () {
    final now = DateTime.now();
    Map<String, dynamic> m(int ago, {bool mine = true, String ct = 'text', Object id = 9}) => {
          'id': id, 'mine': mine, 'content_type': ct,
          'created_at': now.subtract(Duration(minutes: ago)).toIso8601String(),
        };
    test('edit: only my server text inside 15 minutes', () {
      expect(groupCanEdit(m(3), now: now), isTrue);
      expect(groupCanEdit(m(16), now: now), isFalse);
      expect(groupCanEdit(m(3, mine: false), now: now), isFalse);
      expect(groupCanEdit(m(3, ct: 'photo'), now: now), isFalse);
      expect(groupCanEdit(m(3, id: 'local-1'), now: now), isFalse);
      expect(groupCanEdit({...m(3), 'view_once': true}, now: now), isFalse);
      expect(groupCanEdit({...m(3), 'deleted': 'everyone'}, now: now), isFalse);
      expect(groupCanEdit(m(3), now: now, isSpecial: true), isFalse);
    });
    test('delete for everyone: mine, inside the window', () {
      expect(groupCanDeleteEveryone(m(60), now: now), isTrue);
      expect(groupCanDeleteEveryone(m(60 * 24 * 3), now: now), isFalse);
      expect(groupCanDeleteEveryone(m(1, mine: false), now: now), isFalse);
      expect(groupCanDeleteEveryone(m(10), now: now, windowMin: 5), isFalse);
    });
    test('reply quote comes from this phone, never the server', () {
      final msgs = [
        {'id': 1, 'content_type': 'text'},
        {'id': 2, 'content_type': 'photo'},
        {'id': 3, 'deleted': 'everyone'},
      ];
      String? open(Map<String, dynamic> x) => x['id'] == 1 ? 'hello' : null;
      String? q(Object? r) => groupReplyQuote({'reply_to': r}, msgs, open,
          deletedText: 'DEL', mediaText: 'MEDIA');
      expect(q(1), 'hello');
      expect(q('2'), 'MEDIA');
      expect(q(3), 'DEL');
      expect(q(null), isNull);
      expect(q(99), isNull);
    });
  });

  testWidgets('time, edited, quote and deleted line on group bubbles', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('gapc-time-101')), findsOneWidget);
    expect(find.byKey(const ValueKey('gapc-time-102')), findsOneWidget);
    expect(find.byKey(const ValueKey('gapc-edited-102')), findsOneWidget);
    expect(find.byKey(const ValueKey('gapc-edited-101')), findsNothing);
    final quote = find.byKey(const ValueKey('gapc-quote-103'));
    expect(quote, findsOneWidget);
    expect(find.descendant(of: quote, matching: find.text('Yes, see you')), findsOneWidget);
    expect(find.byKey(const ValueKey('gapc-deleted-104')), findsOneWidget);
    expect(find.text(en.circleDeletedPlaceholder), findsOneWidget);
    // my own messages carry no sender name (they sit on the right)
    expect(find.byKey(const ValueKey('wa2-sender-101')), findsOneWidget);
    expect(find.byKey(const ValueKey('wa2-sender-102')), findsNothing);
    await _dispose(tester);
  });

  testWidgets('long-press menus: mine vs theirs', (tester) async {
    await _open(tester);
    await tester.longPress(find.text('Dinner at 8?', findRichText: true));
    await _settle(tester);
    expect(find.byKey(const Key('gapc-group-star')), findsOneWidget);
    expect(find.byKey(const Key('gapc-group-delete-me')), findsOneWidget);
    expect(find.byKey(const Key('gapc-group-edit')), findsNothing);
    expect(find.byKey(const Key('gapc-group-delete-everyone')), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await _settle(tester);
    await tester.longPress(find.text('Old one', findRichText: true));
    await _settle(tester);
    expect(find.byKey(const Key('gapc-group-edit')), findsNothing, reason: '60 min > edit window');
    expect(find.byKey(const Key('gapc-group-delete-everyone')), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('edit re-seals the new text to every member', (tester) async {
    final api = await _open(tester);
    await tester.longPress(find.byKey(const ValueKey('gapc-time-102')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('gapc-group-edit')));
    await _settle(tester);
    expect(find.byKey(const Key('gapc-edit-banner')), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Yes, see you at 8');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await _settle(tester);
    final p = api.posts('/circle/groups/7/messages/102/edit').single;
    expect(p.containsKey('text'), isFalse, reason: 'ciphertext only');
    final b = (p['per_recipient'] as Map)['2'] as Map;
    final pt = _e2e.decrypt(
        self: _peer,
        senderPublicKey: _me.publicKey,
        ct: Ciphertext(
            scheme: _e2e.scheme,
            ciphertextB64: '${b['ciphertext']}',
            nonceB64: '${b['nonce']}',
            senderKeyId: _me.keyId));
    expect(pt, 'Yes, see you at 8');
    expect(api.posts('/circle/groups/7/messages'), isEmpty, reason: 'an edit is not a new message');
    expect(find.byKey(const Key('gapc-edit-banner')), findsNothing);
    await _dispose(tester);
  });

  testWidgets('delete for everyone asks first, then sends scope everyone', (tester) async {
    final api = await _open(tester);
    await tester.longPress(find.text('Old one', findRichText: true));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('gapc-group-delete-everyone')));
    await _settle(tester);
    expect(api.posts('/circle/groups/7/messages/105/delete'), isEmpty);
    await tester.tap(find.byKey(const Key('gapc-delete-confirm')));
    await _settle(tester);
    expect(api.posts('/circle/groups/7/messages/105/delete').single['scope'], 'everyone');
    await _dispose(tester);
  });

  group('call history: remove from my log', () {
    Map<String, dynamic> calls() => {
          'calls': [
            {'id': 9, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
             'name': 'Shanto', 'member_id': 4, 'outcome': 'Missed call',
             'started_at': '2026-11-16T07:30:00Z'},
            {'id': 8, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
             'name': 'Shanto', 'member_id': 4, 'outcome': 'Missed call',
             'started_at': '2026-11-16T07:10:00Z'},
            {'id': 7, 'kind': 'voice', 'state': 'ended', 'outgoing': true,
             'name': 'Rina', 'member_id': 5, 'outcome': 'Outgoing',
             'duration': '01:05', 'started_at': '2026-11-15T09:00:00Z'},
          ],
          'groups': [
            {'id': 9, 'kind': 'voice', 'state': 'missed', 'outgoing': false,
             'name': 'Shanto', 'member_id': 4, 'outcome': 'Missed call',
             'started_at': '2026-11-16T07:30:00Z', 'count': 2, 'ids': [9, 8]},
            {'id': 7, 'kind': 'voice', 'state': 'ended', 'outgoing': true,
             'name': 'Rina', 'member_id': 5, 'outcome': 'Outgoing',
             'duration': '01:05', 'started_at': '2026-11-15T09:00:00Z'},
          ],
        };

    Future<_Api> host(WidgetTester tester) async {
      final api = _Api();
      api.replies['/circle/calls'] = calls;
      api.replies['/circle/calls/hide'] = {'ok': true};
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
          home: const CircleCallHistoryScreen(),
        ),
      ));
      await _settle(tester);
      return api;
    }

    testWidgets('long-press a grouped row removes every call in it', (tester) async {
      final api = await host(tester);
      expect(find.byKey(const ValueKey('call-log-row-9')), findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('call-log-row-9')));
      await _settle(tester);
      expect(find.text(en.gapcCallRemoveBody), findsOneWidget);
      await tester.tap(find.byKey(const Key('gapc-calls-confirm')));
      await _settle(tester);
      final ids = (api.posts('/circle/calls/hide').single['ids'] as List).toSet();
      expect(ids, {9, 8});
      expect(find.byKey(const ValueKey('call-log-row-9')), findsNothing);
      expect(find.byKey(const ValueKey('call-log-row-7')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('clear all asks first; cancel sends nothing', (tester) async {
      final api = await host(tester);
      await tester.tap(find.byKey(const Key('gapc-calls-menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('gapc-calls-clear')));
      await _settle(tester);
      await tester.tap(find.text(en.cancel));
      await _settle(tester);
      expect(api.posts('/circle/calls/hide'), isEmpty);
      await tester.tap(find.byKey(const Key('gapc-calls-menu')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('gapc-calls-clear')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('gapc-calls-confirm')));
      await _settle(tester);
      expect(api.posts('/circle/calls/hide').single, {'all': true});
      expect(find.byKey(const ValueKey('call-log-row-7')), findsNothing);
      await _dispose(tester);
    });
  });

  testWidgets('search across chats finds GROUP messages too (opened on this phone)',
      (tester) async {
    final api = _Api();
    final sealed = _e2e.encrypt(
        self: _peer, recipientPublicKey: _me.publicKey, plaintext: 'Rent is due Friday');
    api.replies['/circle/groups'] = {
      'results': [
        {'id': 7, 'name': 'Family', 'my_member_id': 1},
      ]
    };
    api.replies['/circle/groups/7/members'] = {
      'results': [
        {'member_id': 1, 'user_id': 1, 'name': 'Me', 'is_self': true, 'public_key': ''},
        {'member_id': 2, 'user_id': 2, 'name': 'Abul', 'public_key': _peer.publicKeyB64},
      ]
    };
    api.replies['/circle/groups/7/messages'] = {
      'results': [
        {
          'id': 301, 'sender_id': 2, 'mine': false, 'content_type': 'text',
          'created_at': _ago(10), 'sender_key_id': _peer.keyId,
          'per_recipient': {
            '1': {'ciphertext': sealed.ciphertextB64, 'nonce': sealed.nonceB64}
          },
        },
        {'id': 302, 'sender_id': 2, 'content_type': 'text', 'deleted': 'everyone',
         'created_at': _ago(9)},
      ]
    };
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
        home: CircleSearchScreen(members: const [], identity: _me, initialQuery: 'rent'),
      ),
    ));
    await _settle(tester);
    expect(find.byKey(const Key('e-msg-hit-0')), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Rent is due Friday'), findsOneWidget);
    expect(find.byKey(const Key('e-msg-hit-1')), findsNothing);
    await _dispose(tester);
  });
}
