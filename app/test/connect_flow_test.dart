// connect-flow — My Circle CONNECT FLOW (owner order 25 Oct), with TWO
// simulated accounts (A = sender, B = recipient) on ONE fake server:
//  1. A sends a request -> the chat opens at once with the banner "Request
//     sent — they can reply after accepting"; 3 texts go, the 4th is blocked
//     (limit note instead of the composer); a link never leaves the phone.
//  2. B's Requests box shows the decrypted preview; the request chat has
//     Accept / Decline / Block / Report; Accept -> "You are now connected".
//  3. A sees the accept live: the same line, the composer, call buttons.
//  4. "X accepted your request — say hi" opens THAT chat.
//  5. Every My Circle contact / contact info shows Message, Audio call and
//     Video call (calls only for accepted contacts).
import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/connect_flow.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/messenger/contact_info_screen.dart';
import 'package:assisto/screens/messenger/m3_add_to_circle_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/m3_circle_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

late AppLocalizations en;
late AppLocalizations bn;
final _e2e = SoftwareE2E();

/// The shared server: A (user 1) owns edge 10, B (user 2) owns edge 20.
class _Server {
  _Server(this.aKey, this.bKey);
  final IdentityKeyPair aKey;
  final IdentityKeyPair bKey;
  String state = 'pending';
  String? connectedAt;
  final msgs = <Map<String, dynamic>>[];
  static const limit = 3;

  Map<String, dynamic> edgeOf(int me) => {
        'state': state,
        'direction': me == 1 ? 'outgoing' : 'incoming',
        if (state != 'accepted' && me == 1)
          'request': {
            'limit': limit,
            'sent': msgs.length,
            'can_send': msgs.length < limit,
          },
        'connected_at': connectedAt,
      };

  Map<String, dynamic> memberOf(int me) => {
        'id': me == 1 ? 10 : 20,
        'name': me == 1 ? 'Nadia Rahman' : 'Amina Akter',
        'relation': 'friend',
        'peer_user_id': me == 1 ? 2 : 1,
        'public_key': (me == 1 ? bKey : aKey).publicKeyB64,
        ...edgeOf(me),
      };

  List<Map<String, dynamic>> thread(int me) => [
        for (final m in msgs)
          {...m, 'mine': me == 1, if (me == 1) 'status': 'sent'},
      ];

  void seed(List<String> texts) {
    for (final t in texts) {
      final ct = _e2e.encrypt(
          self: aKey, recipientPublicKey: bKey.publicKey, plaintext: t);
      msgs.add({
        'id': 100 + msgs.length,
        'sender_id': 1,
        'content_type': 'text',
        'created_at': DateTime(2026, 10, 25, 9, msgs.length).toIso8601String(),
        ...ct.toEnvelopeFields(),
      });
    }
  }
}

class _Api extends ApiClient {
  _Api(this.s, this.uid) {
    token = 'test-$uid';
  }
  final _Server s;
  final int uid;
  final calls = <(String, String, Map<String, dynamic>)>[];

  int get _edge => uid == 1 ? 10 : 20;

  List<Map<String, dynamic>> posts(String path) => [
        for (final c in calls)
          if (c.$1 == 'POST' && c.$2 == path) c.$3
      ];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(('GET', path, const {}));
    final p = path.split('?').first;
    if (p == '/circle/keys/peer/$_edge') {
      return {'public_key': (uid == 1 ? s.bKey : s.aKey).publicKeyB64};
    }
    if (p == '/circle/$_edge/messages') {
      return {'results': s.thread(uid), 'edge': s.edgeOf(uid)};
    }
    if (p == '/circle/requests' && uid == 2 && s.state == 'pending') {
      final last = s.msgs.isEmpty ? null : s.msgs.last;
      return {
        'results': [
          {
            'id': 20, 'direction': 'incoming', 'display_name': 'Amina Akter',
            'phone': '', 'not_in_contacts': true, 'msg_count': s.msgs.length,
            if (last != null) 'at': last['created_at'],
            if (last != null)
              'last': {...last, 'mine': false,
                       'peer_public_key': s.aKey.publicKeyB64},
            'member': s.memberOf(2),
            'actions': ['accept', 'decline', 'block'],
          }
        ]
      };
    }
    return {'results': <dynamic>[]};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    calls.add(('POST', path, body));
    if (path == '/messenger/contacts/lookup') {
      return {
        'ok': true, 'found': true, 'phone': '+8801711000777',
        'user': {'id': 2, 'name': 'Nadia Rahman', 'circle': {'state': 'none'}},
      };
    }
    if (path == '/circle/request') return s.memberOf(1);
    if (path == '/circle/$_edge/messages') {
      if (s.state != 'accepted' && uid == 1 && s.msgs.length >= _Server.limit) {
        throw ApiException('You can send more after they accept.', 403);
      }
      final id = 100 + s.msgs.length;
      s.msgs.add({
        ...body,
        'id': id,
        'sender_id': uid,
        'created_at': DateTime.now().toIso8601String(),
      });
      return {'id': id, 'ok': true};
    }
    if (path == '/circle/request/20/act' && body['event'] == 'accept') {
      s.state = 'accepted';
      s.connectedAt = DateTime.now().toUtc().toIso8601String();
      return s.memberOf(2);
    }
    return {'ok': true};
  }
}

Future<void> _host(WidgetTester tester, ApiClient api, Widget screen,
    {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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
      home: screen,
    ),
  ));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _type(WidgetTester tester, String text) async {
  // a toast (SnackBar) may cover the composer: let it go first
  ScaffoldMessenger.of(tester.element(find.byType(TextField).last))
      .removeCurrentSnackBar();
  await tester.pump();
  await tester.enterText(find.byType(TextField).last, text);
  await tester.tap(find.byIcon(Icons.send_rounded));
  await _settle(tester);
}

void main() {
  late IdentityKeyPair aId;
  late IdentityKeyPair bId;

  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('bn');
    en = await AppLocalizations.delegate.load(const Locale('en'));
    bn = await AppLocalizations.delegate.load(const Locale('bn'));
    bId = _e2e.generateIdentity();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    IdentityVault.instance.resetForTests();
    Outbox.instance.stop();
    RealtimeChannel.instance.states.value = const {};
    ConnectFlow.callOverride = null;
  });

  Future<_Server> server(WidgetTester tester) async {
    // A's identity is the phone's own (the add flow opens the chat with it)
    aId = (await tester.runAsync(() => IdentityVault.instance.get()))!;
    return _Server(aId, bId);
  }

  testWidgets('A: request -> chat opens with banner -> 3 texts -> 4th blocked',
      (tester) async {
    final s = await server(tester);
    final api = _Api(s, 1);
    await _host(tester, api,
        const M3AddToCircleScreen(initialNumber: '01711-000777'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('m3-rel-friend')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('m3-send')));
    await _settle(tester);
    expect(api.posts('/circle/request').single['to_user_id'], 2);
    // the thread is open at once — no "Request sent" dead end, no search
    expect(find.byType(CircleChatScreen), findsOneWidget);
    expect(find.text(en.connRequestSentBanner), findsOneWidget);
    expect(find.byIcon(Icons.call_rounded), findsNothing);
    expect(find.byIcon(Icons.videocam_rounded), findsNothing);
    expect(find.byTooltip(en.circleAttach), findsNothing); // text only

    // a link never leaves the phone before accept
    await _type(tester, 'see www.example.com');
    expect(api.posts('/circle/10/messages'), isEmpty);
    expect(find.text(en.connNoLinksYet), findsOneWidget);

    for (final m in ['Assalamu alaikum', 'This is Amina', 'From school']) {
      await _type(tester, m);
    }
    expect(api.posts('/circle/10/messages').length, 3);
    expect(s.msgs.length, 3);
    // every message went out E2E (ciphertext only)
    for (final b in api.posts('/circle/10/messages')) {
      expect('$b'.contains('Amina'), isFalse);
      expect(b['content_type'], 'text');
    }
    // the 4th is blocked: the limit note replaces the composer
    expect(find.byKey(const Key('mr1-limit')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await _dispose(tester);
  });

  testWidgets('B: Requests box preview -> Accept -> "You are now connected"',
      (tester) async {
    final s = await server(tester);
    s.seed(['Assalamu alaikum', 'This is Amina', 'From school']);
    final api = _Api(s, 2);
    await _host(tester, api, Scaffold(body: M3RequestsBanner(identity: bId)));
    await _settle(tester);
    expect(find.text('Amina Akter'), findsOneWidget);
    expect(find.text('From school'), findsOneWidget); // decrypted on device
    await tester.tap(find.byKey(const Key('mr1-req-20')));
    await _settle(tester);
    expect(find.byType(CircleChatScreen), findsOneWidget);
    for (final k in ['mr1-accept', 'mr1-delete', 'mr1-block', 'mr1-report']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.text(en.connDecline), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // read-only until accept
    expect(find.text('This is Amina'), findsOneWidget);
    await tester.tap(find.byKey(const Key('mr1-accept')));
    await _settle(tester);
    expect(api.posts('/circle/request/20/act').single['event'], 'accept');
    expect(find.byKey(const Key('conn-connected-line')), findsOneWidget);
    expect(find.text(en.connConnectedLine), findsOneWidget);
    // the pending messages are a normal conversation now
    expect(find.text('Assalamu alaikum'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.call_rounded), findsOneWidget);
    await _type(tester, 'Walaikum assalam');
    expect(api.posts('/circle/20/messages').length, 1);
    await _dispose(tester);
  });

  testWidgets('A: sees the accept live — line, composer, calls',
      (tester) async {
    final s = await server(tester);
    s.seed(['Assalamu alaikum', 'This is Amina', 'From school']);
    final api = _Api(s, 1);
    await _host(tester, api,
        CircleChatScreen(member: s.memberOf(1), identity: aId));
    await _settle(tester);
    expect(find.byKey(const Key('mr1-limit')), findsOneWidget);
    // B accepts on the other phone
    await _Api(s, 2).postJson('/circle/request/20/act', {'event': 'accept'});
    await tester.pump(const Duration(seconds: 8)); // the chat's 7 s poll
    await _settle(tester);
    expect(find.byKey(const Key('conn-connected-line')), findsOneWidget);
    expect(find.byKey(const Key('mr1-limit')), findsNothing);
    expect(find.text(en.connRequestSentBanner), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.call_rounded), findsOneWidget);
    expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
    await _type(tester, 'a 4th text now works');
    expect(s.msgs.length, 4);
    await _dispose(tester);
  });

  test('the accepted push opens THAT chat; a plain request push does not', () {
    final accepted = PushPayload.fromData({
      'kind': 'message_request', 'event': 'accepted', 'chat_kind': 'member',
      'chat_id': '10', 'sender_id': '2', 'route': 'circle/chat',
      'title': 'Nadia Rahman accepted your request — say hi',
    });
    expect(MsgPushHandler.chatOf(accepted), (kind: 'member', id: 10));
    expect(accepted.isKnownKind, isTrue);
    expect(PushRouting.targetFor(accepted)?.chatNavRoute, 'messages');
    final request = PushPayload.fromData({
      'kind': 'message_request', 'chat_kind': 'member', 'chat_id': '20',
      'sender_id': '1', 'route': 'circle/requests',
    });
    expect(MsgPushHandler.chatOf(request), isNull);
  });

  test('the link rule matches the server', () {
    for (final t in ['http://x.y', 'see https://a.b/c', 'WWW.example.com']) {
      expect(preAcceptHasLink(t), isTrue, reason: t);
    }
    for (final t in ['hello', 'আমি আসছি', 'w w w', 'httpx']) {
      expect(preAcceptHasLink(t), isFalse, reason: t);
    }
  });

  group('contact / member / profile: Message, Audio call, Video call', () {
    final accepted = {
      'id': 10, 'name': 'Nadia Rahman', 'state': 'accepted',
      'peer_user_id': 2, 'public_key': '',
    };

    Widget opener(Map<String, dynamic> m) => Builder(
        builder: (ctx) => Scaffold(
            body: Center(
                child: TextButton(
                    onPressed: () => showConnectSheet(ctx, m),
                    child: const Text('open')))));

    testWidgets('member sheet: three actions, calls go to the call screen',
        (tester) async {
      final s = await server(tester);
      final placed = <String>[];
      ConnectFlow.callOverride = (_, m, kind) async => placed.add('${m['id']}:$kind');
      await _host(tester, _Api(s, 1), opener(accepted));
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.byKey(const Key('conn-sheet')), findsOneWidget);
      expect(find.text(en.c1Message), findsOneWidget);
      expect(find.text(en.connAudioCall), findsOneWidget);
      expect(find.text(en.connVideoCall), findsOneWidget);
      await tester.tap(find.byKey(const Key('conn-audio')));
      await _settle(tester);
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('conn-video')));
      await _settle(tester);
      expect(placed, ['10:voice', '10:video']);
      await tester.tap(find.text('open'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('conn-message')));
      await _settle(tester);
      expect(find.byType(CircleChatScreen), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('not accepted yet: Message only (calls after accept)',
        (tester) async {
      final s = await server(tester);
      await _host(tester, _Api(s, 1),
          opener({...accepted, 'state': 'pending'}));
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.byKey(const Key('conn-message')), findsOneWidget);
      expect(find.byKey(const Key('conn-audio')), findsNothing);
      expect(find.byKey(const Key('conn-video')), findsNothing);
      expect(find.text(en.mr1CallsAfterAccept), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('contact info shows the actions (bn)', (tester) async {
      final s = await server(tester);
      final placed = <String>[];
      ConnectFlow.callOverride = (_, m, kind) async => placed.add(kind);
      await _host(tester, _Api(s, 1), ContactInfoScreen(member: accepted),
          lang: 'bn');
      await _settle(tester);
      expect(find.byKey(const Key('conn-actions')), findsOneWidget);
      expect(find.text(bn.connAudioCall), findsOneWidget);
      expect(find.text(bn.connVideoCall), findsOneWidget);
      await tester.tap(find.byKey(const Key('conn-video')));
      await _settle(tester);
      expect(placed, ['video']);
      await _dispose(tester);
    });
  });

  test('bn strings are Bangla (no Latin letters)', () {
    for (final v in [
      bn.connRequestSentBanner, bn.connConnectedLine, bn.connNoLinksYet,
      bn.connAudioCall, bn.connVideoCall, bn.connDecline,
      bn.connDeclineTitle, bn.connDeclinedToast, bn.connDeclineBody('রহিম'),
    ]) {
      expect(RegExp(r'[A-Za-z0-9]').hasMatch(v), isFalse, reason: v);
    }
  });
}
