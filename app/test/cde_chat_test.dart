// cde-chat (owner order 6 D + E): REAL synced chat themes and Messenger-style
// nicknames.
//   * the control-message codec (+ old-version fallback line, cardFallback)
//   * every theme's text/bubble contrast (WCAG AA 4.5:1)
//   * DecorStore: newest server stamp wins, survives an app restart
//   * a theme change RECEIVED from the other phone repaints the chat at once,
//     shows "X changed the theme to Y", and is still there after a restart
//   * nicknames received: header shows the nickname, system lines, remove
//   * setting a nickname here: server copy first, then the E2E control
//     message the other phone decrypts
//   * the chat list and the call screen use the nickname
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_decor/chat_control.dart';
import 'package:assisto/messaging/chat_decor/chat_themes.dart';
import 'package:assisto/messaging/chat_decor/decor_sheets.dart';
import 'package:assisto/messaging/chat_decor/decor_store.dart';
import 'package:assisto/messaging/chat_decor/system_line.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/p3/assisto_card.dart' show cardFallback;
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';
import 'package:assisto/widgets/paywall_sheet.dart';

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

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];

  List<Map<String, dynamic>> posts(String path) => [
        for (final c in calls)
          if (c.$1 == 'POST' && c.$2 == path) c.$3
      ];
}

int _id = 1;
Map<String, dynamic> _env(String text,
    {bool mine = false, DateTime? at, String ct = 'text'}) {
  final ct0 = _e2e.encrypt(
      self: mine ? _me : _peer,
      recipientPublicKey: mine ? _peer.publicKey : _me.publicKey,
      plaintext: text);
  final id = _id++;
  return {
    'id': id,
    'sender_id': mine ? 1 : 2,
    'mine': mine,
    'content_type': ct,
    'created_at': (at ?? DateTime(2026, 10, 1, 9).add(Duration(minutes: id)))
        .toIso8601String(),
    ...ct0.toEnvelopeFields(),
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

Future<void> _settle(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Map<String, dynamic> _member({int id = 5}) => {
      'id': id,
      'name': 'Abul Kashem',
      'relation': 'friend',
      'state': 'accepted',
      'public_key': _peer.publicKeyB64,
    };

String _ctl(ChatControl c, [String line = 'Abul Kashem did something']) =>
    encodeControl(c, line);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  setUpAll(() async {
    t = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DecorStore.instance.reset();
    Outbox.instance.stop();
  });

  group('codec', () {
    test('theme + nickname controls round-trip; readable fallback first', () {
      final p = _ctl(const ChatControl.theme('love', at: 1700));
      expect(isControlText(p), isTrue);
      expect(controlFallback(p), 'Abul Kashem did something');
      expect(cardFallback(p), 'Abul Kashem did something'); // previews / notifs
      final c = decodeControl(p)!;
      expect((c.isTheme, c.themeId, c.at), (true, 'love', 1700));
      final n = decodeControl(_ctl(const ChatControl.nick(who: 'recipient', name: 'Shona', at: 9)))!;
      expect((n.isNick, n.who, n.name, n.removed), (true, 'recipient', 'Shona', false));
      final g = decodeControl(_ctl(const ChatControl.nick(uid: 42, name: '', at: 9)))!;
      expect((g.uid, g.removed), (42, true));
      expect(decodeControl('just text'), isNull);
    });

    test('photo theme rides inside the md1 descriptor', () {
      final d = jsonEncode({'md1': 1, 'kind': 'photo', 'ref': 'r1'});
      final w = withControl(d, const ChatControl.theme('custom', at: 5));
      expect(controlInDescriptor(w)!.themeId, 'custom');
      expect(controlInDescriptor(d), isNull);
    });

    test('system lines for every 1:1 case (receiver point of view)', () {
      String line(ChatControl c, bool mine) =>
          describeControl(t, c, mine: mine, actor: 'Rahim', peerName: 'Rahim');
      expect(line(const ChatControl.theme('love'), false), 'Rahim changed the theme to Love');
      expect(line(const ChatControl.theme('eid'), true), 'You changed the theme to Eid Mubarak');
      expect(line(const ChatControl.nick(who: 'recipient', name: 'Bhaiya'), true),
          'You set the nickname for Rahim to Bhaiya');
      expect(line(const ChatControl.nick(who: 'recipient', name: 'Shona'), false),
          'Rahim set your nickname to Shona');
      expect(line(const ChatControl.nick(who: 'sender', name: 'Raju'), false),
          'Rahim set their nickname to Raju');
      expect(line(const ChatControl.nick(who: 'sender', name: 'Raju'), true),
          'You set your nickname to Raju');
      expect(line(const ChatControl.nick(who: 'recipient', name: ''), false),
          'Rahim removed your nickname');
      expect(line(const ChatControl.nick(who: 'sender', name: ''), false),
          'Rahim removed their nickname');
      expect(line(const ChatControl.nick(who: 'recipient', name: ''), true),
          'You removed the nickname for Rahim');
      // group: a third person
      expect(
          describeControl(t, const ChatControl.nick(uid: 9, name: 'Boss'),
              mine: false, actor: 'Rahim', myUid: 1, senderUid: 2, nameOf: (_) => 'Karim'),
          'Rahim set the nickname for Karim to Boss');
      // the line an old app version / a notification shows
      expect(
          controlFallbackLine(t, const ChatControl.nick(who: 'recipient', name: 'Shona'),
              myName: 'Arif'),
          'Arif set your nickname to Shona');
    });
  });

  test('every theme: bubble text ≥ 4.5:1 on both sides, 6 quick reactions', () {
    for (final d in [...kChatThemes, kPhotoTheme]) {
      expect(_contrast(d.outText, d.outBubble), greaterThanOrEqualTo(4.5), reason: '${d.id} out');
      expect(_contrast(d.inText, d.inBubble.withValues(alpha: 1)),
          greaterThanOrEqualTo(4.5), reason: '${d.id} in');
      expect(d.reactions.length, 6, reason: d.id);
    }
    expect(kChatThemes.length, inInclusiveRange(8, 10));
    expect(kChatThemes.where((d) => d.free).map((d) => d.id).toSet(),
        {'love', 'sunset', 'calm'});
    for (final d in kChatThemes) {
      expect(chatThemeLabel(t, d.id), isNot(t.cdeThemeClassic), reason: d.id);
    }
  });

  group('DecorStore', () {
    test('newest server stamp wins, in any order', () async {
      final s = DecorStore.instance;
      await s.applyTheme('member:5', 'love', 200);
      expect(await s.applyTheme('member:5', 'calm', 100), isFalse); // older
      expect(s.get('member:5').themeId, 'love');
      expect(await s.applyTheme('member:5', 'eid', 300), isTrue);
      await s.applyNick('member:5', 'peer', 'Bhaiya', 50);
      await s.applyNick('member:5', 'peer', '', 40); // older removal ignored
      expect(s.peerName('member:5', 'Abul'), 'Bhaiya');
      await s.applyNick('member:5', 'peer', '', 60);
      expect(s.peerName('member:5', 'Abul'), 'Abul');
    });

    test('survives an app restart (SharedPreferences)', () async {
      await DecorStore.instance.applyTheme('member:5', 'moonlight', 10);
      await DecorStore.instance.applyNick('member:5', 'me', 'Shona', 11);
      DecorStore.instance.reset(); // the process dies; prefs stay
      final st = await DecorStore.instance.ensure('member:5');
      expect(st.themeId, 'moonlight');
      expect(st.nick('me'), 'Shona');
    });
  });

  testWidgets('a theme sent by the other phone repaints the chat at once and after restart',
      (tester) async {
    final api = _Api();
    final msgs = <Map<String, dynamic>>[_env('hello')];
    api.replies['/circle/5/messages'] = () => <String, dynamic>{'results': msgs};
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    api.replies['/circle/decor/member/5'] = {
      'theme': {'id': 'classic', 'at_ms': 0}, 'nick_peer': '', 'nick_me': '',
      'nick_at': {'peer': 0, 'me': 0}, 'premium': false,
    };
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await _settle(tester);
    expect(find.byKey(const ValueKey('cde-wallpaper-love')), findsNothing);
    // the peer picks "Love": their control message arrives on the next poll
    msgs.add(_env(_ctl(const ChatControl.theme('love', at: 1000), 'Abul Kashem changed the theme to Love')));
    await tester.pump(const Duration(seconds: 8));
    await _settle(tester);
    expect(find.byKey(const ValueKey('cde-wallpaper-love')), findsOneWidget);
    expect(find.text('Abul Kashem changed the theme to Love'), findsOneWidget);
    expect(find.byKey(const Key('cde-system-line')), findsOneWidget);
    // the raw control text is never shown as a bubble
    expect(find.textContaining('CC1:'), findsNothing);
    await _dispose(tester);

    // restart: memory gone, the control is no longer in the loaded history
    DecorStore.instance.reset();
    msgs
      ..clear()
      ..add(_env('later message'));
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await _settle(tester);
    expect(find.byKey(const ValueKey('cde-wallpaper-love')), findsOneWidget,
        reason: 'the theme persists on the phone (and the stale server copy is older)');
    await _dispose(tester);
  });

  testWidgets('nicknames from the other phone: header, system lines, remove', (tester) async {
    final api = _Api();
    final msgs = <Map<String, dynamic>>[
      _env(_ctl(const ChatControl.nick(who: 'sender', name: 'Bhaiya', at: 10))),
      _env(_ctl(const ChatControl.nick(who: 'recipient', name: 'Shona', at: 11))),
    ];
    api.replies['/circle/5/messages'] = () => <String, dynamic>{'results': msgs};
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await _settle(tester);
    expect(find.text('Abul Kashem set their nickname to Bhaiya'), findsOneWidget);
    expect(find.text('Abul Kashem set your nickname to Shona'), findsOneWidget);
    // the header shows the nickname now
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Bhaiya')), findsOneWidget);
    expect(DecorStore.instance.get('member:5').nick('me'), 'Shona');
    // they remove it
    msgs.add(_env(_ctl(const ChatControl.nick(who: 'sender', name: '', at: 12))));
    await tester.pump(const Duration(seconds: 8));
    await _settle(tester);
    expect(find.text('Abul Kashem removed their nickname'), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Abul Kashem')),
        findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('I set a nickname: server copy first, then an E2E control the peer decrypts',
      (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {'results': [_env('hi')]};
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    api.replies['/circle/decor/member/5'] = () => <String, dynamic>{
          'ok': true,
          'theme': {'id': 'classic', 'at_ms': 0},
          'nick_peer': api.posts('/circle/decor/member/5').isEmpty ? '' : 'Bhai',
          'nick_me': '',
          'nick_at': {'peer': 500, 'me': 0},
          'premium': false,
          'at_ms': 500,
        };
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await _settle(tester);
    await tester.tap(find.text(t.cdeNickTitle));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('cde-nick-row-peer')));
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('cde-nick-field')), 'Bhai');
    await tester.tap(find.byKey(const Key('cde-nick-save')));
    await _settle(tester, 30);
    final decor = api.posts('/circle/decor/member/5');
    expect(decor.single['nick'], {'who': 'peer', 'name': 'Bhai'});
    final sent = api.posts('/circle/5/messages');
    expect(sent, hasLength(1));
    // the other phone decrypts it into the same change
    final pt = _e2e.decrypt(
        self: _peer,
        senderPublicKey: _me.publicKey,
        ct: Ciphertext(
            scheme: '${sent.single['scheme']}',
            ciphertextB64: '${sent.single['ciphertext']}',
            nonceB64: '${sent.single['nonce']}',
            senderKeyId: '${sent.single['sender_key_id'] ?? ''}'))!;
    final c = decodeControl(pt)!;
    expect((c.who, c.name, c.at), ('recipient', 'Bhai', 500));
    // the server sees ciphertext only
    expect(jsonEncode(sent.single).contains('Bhai'), isFalse);
    expect(find.text('You set the nickname for Abul Kashem to Bhai'), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Bhai')), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('a Premium theme on a Free plan opens the plans sheet, sends nothing',
      (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {'results': [_env('hi')]};
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    api.replies['/circle/decor/member/5'] = {
      'theme': {'id': 'classic', 'at_ms': 0}, 'premium': false,
    };
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await _settle(tester);
    await tester.tap(find.text(t.msgrChatTheme));
    await tester.pump(const Duration(seconds: 4)); // the AI offer lookup times out
    await _settle(tester);
    expect(find.byKey(const Key('cde-theme-sheet')), findsOneWidget);
    // the AI entry is hidden (no provider), "my photo" is offered with a lock
    await tester.ensureVisible(find.byKey(const Key('cde-theme-midnight')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('cde-theme-midnight')));
    await _settle(tester);
    expect(api.posts('/circle/decor/member/5'), isEmpty);
    expect(api.posts('/circle/5/messages'), isEmpty);
    expect(find.byType(PaywallSheet, skipOffstage: false), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('theme sheet: Free shows locks + photo row, AI hidden without a provider;'
      ' Premium with a provider shows the AI entry', (tester) async {
    Future<void> sheet(Widget w) async {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Scaffold(body: w),
      ));
      await tester.pump();
      // the sheet scrolls: bring its last rows in
      await tester.drag(find.byKey(const Key('cde-theme-sheet')), const Offset(0, -900));
      await tester.pump();
    }

    await sheet(const ChatThemeSheet(currentId: 'love', premium: false));
    expect(find.byKey(const Key('cde-theme-photo')), findsOneWidget);
    expect(find.byKey(const Key('cde-theme-ai')), findsNothing);
    expect(find.byIcon(Icons.lock_outline_rounded), findsWidgets); // premium tiles + photo
    expect(find.text(t.cdeThemeInUse), findsNothing);
    await sheet(const ChatThemeSheet(
        currentId: 'eid', premium: true, aiAvailable: true, aiCredits: '20'));
    expect(find.byKey(const Key('cde-theme-ai')), findsOneWidget);
    expect(find.text(t.cdeThemeAiHint('20')), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded, skipOffstage: false), findsNothing);
  });

  testWidgets('a free theme: server copy, repaint here, E2E control out', (tester) async {
    final api = _Api();
    api.replies['/circle/5/messages'] = {'results': [_env('hi')]};
    api.replies['/circle/keys/peer/5'] = {'public_key': _peer.publicKeyB64};
    api.replies['/circle/decor/member/5'] = () => <String, dynamic>{
          'ok': true,
          'theme': {'id': api.posts('/circle/decor/member/5').isEmpty ? 'classic' : 'calm',
                    'at_ms': api.posts('/circle/decor/member/5').isEmpty ? 0 : 777},
          'premium': false,
          'at_ms': 777,
        };
    await _host(tester, api, CircleChatScreen(member: _member(), identity: _me));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await _settle(tester);
    await tester.tap(find.text(t.msgrChatTheme));
    await tester.pump(const Duration(seconds: 4));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const Key('cde-theme-calm')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('cde-theme-calm')));
    await _settle(tester, 30);
    expect(api.posts('/circle/decor/member/5').single, {'theme': 'calm'});
    expect(api.posts('/circle/5/messages'), hasLength(1));
    expect(find.byKey(const ValueKey('cde-wallpaper-calm')), findsOneWidget);
    expect(find.text('You changed the theme to Calm sea'), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('the chat list shows the nickname (server row) instead of the name',
      (tester) async {
    final api = _Api();
    api.replies['/circle/chats'] = {
      'results': [
        {
          'id': '5',
          'kind': 'member',
          'member': {..._member(), 'nickname': 'Bhaiya', 'nickname_at': 5},
          'last': {
            'id': 9,
            'mine': false,
            'content_type': 'text',
            'peer_public_key': _peer.publicKeyB64,
            'sender_name': 'Abul Kashem',
            ..._env(_ctl(const ChatControl.theme('love', at: 3))),
          },
          'unread': 0,
          'at': DateTime(2026, 10, 1).toIso8601String(),
        }
      ]
    };
    await _host(tester, api,
        Scaffold(body: MsgrHubChatList(identity: _me, members: const [])));
    await _settle(tester, 30);
    expect(find.text('Bhaiya'), findsOneWidget);
    expect(find.text('Abul Kashem'), findsNothing);
    // the last message (a theme change) previews as a localised line
    expect(find.text('Abul Kashem changed the theme to Love'), findsOneWidget);
    await _dispose(tester);
  });
}
