// e2-keys: chat screens — (item 2) the FIRST frame of a chat already shows
// the latest message (reversed list, no visible scroll), the "N unread
// messages" divider case, groups the same; (item 1) no snackbar for a
// keyless peer — the message waits in the outbox (clock) and is sent when
// the peer's background publish lands; security-code-changed note;
// honest "can't decrypt on this device" bubble.
import 'dart:async';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/key_service.dart';
import 'package:assisto/l10n/app_localizations.dart';
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

class _Api extends ApiClient {
  _Api() {
    token = 'test';
  }
  final Map<String, Object> replies = {};
  final calls = <(String, String, Map<String, dynamic>)>[];
  final List<String> gets = [];

  Map<String, dynamic> _answer(String path) {
    final r = replies[path] ?? replies[path.split('?').first] ?? const {};
    if (r is Map<String, dynamic> Function()) return r();
    return Map<String, dynamic>.from(r as Map);
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(('GET', path, const {}));
    gets.add(path);
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

Map<String, dynamic> _fromPeer(int id, String text,
    {bool unseen = false, IdentityKeyPair? sender, DateTime? at}) {
  final ct = _e2e.encrypt(
      self: sender ?? _peer, recipientPublicKey: _me.publicKey, plaintext: text);
  return {
    'id': id,
    'sender_id': 2,
    'mine': false,
    'content_type': 'text',
    'created_at':
        (at ?? DateTime(2026, 10, 1).add(Duration(minutes: id))).toIso8601String(),
    if (unseen) 'unseen': true,
    ...ct.toEnvelopeFields(),
  };
}

late AppLocalizations t;

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

/// Pump single frames until the message list first exists.
Future<void> _untilList(WidgetTester tester, Key listKey) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byKey(listKey).evaluate().isNotEmpty) return;
  }
  fail('list never appeared');
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

ScrollPosition _pos(WidgetTester tester, Key k) =>
    tester.widget<ListView>(find.byKey(k)).controller!.position;

Map<String, dynamic> _member({String pub = ''}) => {
      'id': 5,
      'name': 'Abul Kashem',
      'relation': 'friend',
      'state': 'accepted',
      'public_key': pub,
    };

void main() {
  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Outbox.instance.stop();
  });

  testWidgets('1:1 FIRST frame shows the latest message, no scroll',
      (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {
      'results': [for (var i = 1; i <= 60; i++) _fromPeer(i, 'message $i')],
      'has_more': true,
    };
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    await _host(tester, api,
        CircleChatScreen(member: _member(pub: _peer.publicKeyB64), identity: _me));
    await _untilList(tester, const Key('e2-chat-list'));
    // The very first frame of the list: latest message visible, offset 0.
    expect(find.text('message 60').hitTestable(), findsOneWidget);
    expect(find.text('message 1'), findsNothing);
    expect(_pos(tester, const Key('e2-chat-list')).pixels, 0);
    // asked for a PAGE, not the whole history
    expect(api.gets.any((g) => g.startsWith('/circle/5/messages?limit=')), isTrue);
    // ...and it stays there (no programmatic animate-to-bottom later)
    await tester.pump(const Duration(milliseconds: 500));
    expect(_pos(tester, const Key('e2-chat-list')).pixels, 0);
    expect(find.byKey(const Key('e2-unread-divider')), findsNothing);
    await _dispose(tester);
  });

  testWidgets('1:1 opens at the first unread with "N unread messages"',
      (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {
      'results': [
        for (var i = 1; i <= 50; i++)
          _fromPeer(i, 'message $i', unseen: i > 20),
      ],
    };
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    await _host(tester, api,
        CircleChatScreen(member: _member(pub: _peer.publicKeyB64), identity: _me));
    await _untilList(tester, const Key('e2-chat-list'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final divider = find.byKey(const Key('e2-unread-divider'));
    expect(divider.hitTestable(), findsOneWidget);
    expect(find.text(t.e2UnreadDivider(30)), findsOneWidget);
    // the first unread message is right below the divider, on screen
    expect(find.text('message 21').hitTestable(), findsOneWidget);
    final dy = tester.getTopLeft(divider).dy;
    expect(dy, lessThan(400)); // near the top, not scrolled past
    await _dispose(tester);
  });

  testWidgets('older messages load on scroll-up (paged, position kept)',
      (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {
      'results': [for (var i = 51; i <= 100; i++) _fromPeer(i, 'message $i')],
      'has_more': true,
    };
    api.replies['/circle/5/messages?limit=50&before=51'] = {
      'results': [for (var i = 1; i <= 50; i++) _fromPeer(i, 'message $i')],
      'has_more': false,
    };
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    await _host(tester, api,
        CircleChatScreen(member: _member(pub: _peer.publicKeyB64), identity: _me));
    await _untilList(tester, const Key('e2-chat-list'));
    final list = find.byKey(const Key('e2-chat-list'));
    for (var i = 0; i < 12; i++) {
      await tester.drag(list, const Offset(0, 600));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.gets, contains('/circle/5/messages?limit=50&before=51'));
    final before = _pos(tester, const Key('e2-chat-list')).pixels;
    await tester.pump(const Duration(milliseconds: 200));
    expect(_pos(tester, const Key('e2-chat-list')).pixels, before);
    await _dispose(tester);
  });

  testWidgets('keyless peer: NO snackbar, clock bubble, sent after publish',
      (tester) async {
    final api = _Api();
    var peerKey = '';
    api.replies['/circle/keys/peer/5'] =
        () => <String, dynamic>{'public_key': peerKey, 'pending': peerKey.isEmpty};
    // the server copy appears once the outbox has POSTed it
    api.replies['/circle/5/messages'] = () => <String, dynamic>{
          'results': [
            for (final (i, b) in api.posts('/circle/5/messages').indexed)
              {
                ...b,
                'id': 100 + i,
                'sender_id': 1,
                'mine': true,
                'status': 'sent',
                'created_at': DateTime.now().toIso8601String(),
              }
          ]
        };
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'hi Abul');
    await tester.tap(find.byIcon(Icons.send));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text(t.circleKeyMissing), findsNothing);
    expect(find.text('hi Abul'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsWidgets); // clock
    expect(api.posts('/circle/5/messages'), isEmpty);
    final q = await Outbox.instance.forChat('member', 5);
    expect(q.single.text, 'hi Abul');

    // B's phone publishes in the background -> key.published -> flush.
    final events = StreamController<Map<String, dynamic>>.broadcast();
    Outbox.instance.start(
        transport: FnOutboxTransport(get: api.getJson, post: api.postJson),
        identity: () async => _me,
        keyEvents: events.stream);
    peerKey = _peer.publicKeyB64;
    events.add({'chat': 'member:5'});
    KeyService.instance.keyEvents.add({'chat': 'member:5'});
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final sent = api.posts('/circle/5/messages');
    expect(sent.length, 1);
    expect(sent.single['client_msg_id'], q.single.id);
    expect(sent.single.containsKey('text'), isFalse);
    expect(await Outbox.instance.all(), isEmpty);
    expect(find.text('hi Abul'), findsOneWidget); // no flicker / no dup
    Outbox.instance.stop();
    await events.close();
    await _dispose(tester);
  });

  testWidgets('queued message survives a restart (shown with clock)',
      (tester) async {
    await Outbox.instance.add(OutboxItem(
        id: 'local-1', chatId: 5, text: 'from before', at: DateTime.now()));
    final api = _Api();
    api.replies['/circle/5/messages'] = {'results': <Map<String, dynamic>>[]};
    api.replies['/circle/keys/peer/5'] = {'public_key': ''};
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('from before'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsWidgets);
    await _dispose(tester);
  });

  testWidgets('key change -> security note; old-key message is honest',
      (tester) async {
    final oldPeer = _e2e.generateIdentity();
    // this device saw the OLD key before
    await PeerKeyBook.instance.observe('member:5', oldPeer.publicKeyB64);
    final stranger = _e2e.generateIdentity();
    final api = _Api();
    api.replies['/circle/5/messages'] = {
      'results': [
        _fromPeer(1, 'old phone text', sender: oldPeer),
        _fromPeer(2, 'lost text', sender: stranger),
        _fromPeer(3, 'new phone text'),
      ],
    };
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    await _host(tester, api,
        CircleChatScreen(member: _member(pub: oldPeer.publicKeyB64), identity: _me));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('e2-security-note')), findsOneWidget);
    expect(find.text(t.e2SecurityCodeChanged('Abul Kashem')), findsOneWidget);
    expect(find.text('new phone text'), findsOneWidget);
    expect(find.text('old phone text'), findsOneWidget); // history key kept
    expect(find.text(t.e2CantDecryptHere), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('group FIRST frame shows the latest message, reversed',
      (tester) async {
    final api = _Api();
    api.replies['/circle/groups/7/members'] = {
      'results': [
        {'id': 1, 'user_id': 1, 'name': 'Me', 'is_self': true, 'public_key': ''},
        {
          'id': 2,
          'user_id': 2,
          'name': 'Abul',
          'is_self': false,
          'public_key': _peer.publicKeyB64
        },
      ]
    };
    api.replies['/circle/groups/7/messages'] = {
      'results': [
        for (var i = 1; i <= 40; i++)
          {
            ..._fromPeer(i, 'group msg $i'),
            'per_recipient': null,
          }
      ],
      'has_more': true,
    };
    await _host(
        tester,
        api,
        CircleGroupChatScreen(
            group: const {'id': 7, 'name': 'Family', 'my_member_id': 1},
            identity: _me));
    await _untilList(tester, const Key('e2-group-list'));
    expect(find.text('group msg 40', findRichText: true).hitTestable(),
        findsOneWidget);
    expect(find.text('group msg 1', findRichText: true), findsNothing);
    expect(_pos(tester, const Key('e2-group-list')).pixels, 0);
    await _dispose(tester);
  });

  testWidgets('group with unread opens at the divider', (tester) async {
    final api = _Api();
    api.replies['/circle/groups/7/members'] = {
      'results': [
        {'id': 1, 'user_id': 1, 'name': 'Me', 'is_self': true, 'public_key': ''},
        {'id': 2, 'user_id': 2, 'name': 'Abul', 'public_key': _peer.publicKeyB64},
      ]
    };
    api.replies['/circle/groups/7/messages'] = {
      'results': [
        for (var i = 1; i <= 40; i++)
          {..._fromPeer(i, 'group msg $i', unseen: i > 10), 'per_recipient': null}
      ],
    };
    await _host(
        tester,
        api,
        CircleGroupChatScreen(
            group: const {'id': 7, 'name': 'Family', 'my_member_id': 1},
            identity: _me));
    await _untilList(tester, const Key('e2-group-list'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const Key('e2-unread-divider')).hitTestable(),
        findsOneWidget);
    expect(find.text(t.e2UnreadDivider(30)), findsOneWidget);
    expect(find.text('group msg 11', findRichText: true).hitTestable(),
        findsOneWidget);
    await _dispose(tester);
  });
}
