// a1-circle — owner bug report on build 202:
//   1. one chat-list row per person (dedupe) + same-name disambiguation +
//      "Hasn't opened Assisto yet · Invite";
//   2. the chat-list preview decrypts after the peer's KEY CHANGE (server
//      key history, this phone's PeerKeyBook, the local preview cache),
//      incl. my own outgoing last message;
//   3. the chat header status ("last seen today at 10:05 pm") is never cut
//      at 360 dp, bn + en, long name;
//   4. call events INSIDE the chat (chips, red missed, tap = call back).
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/key_service.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/call_events.dart';
import 'package:assisto/messaging/chat_header.dart';
import 'package:assisto/messaging/chat_list_dedupe.dart';
import 'package:assisto/messaging/chat_preview.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/messaging/preview_cache.dart';
import 'package:assisto/messaging/unread_store.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _oldPeer = _e2e.generateIdentity();
final _newPeer = _e2e.generateIdentity();
final _other = _e2e.generateIdentity();

Map<String, dynamic> _env(String text, IdentityKeyPair from, IdentityKeyPair to) {
  final ct = _e2e.encrypt(self: from, recipientPublicKey: to.publicKey, plaintext: text);
  return {
    'ciphertext': ct.ciphertextB64,
    'nonce': ct.nonceB64,
    'sender_key_id': ct.senderKeyId,
    'scheme': ct.scheme,
  };
}

String _iso(Duration ago) => DateTime.now().subtract(ago).toUtc().toIso8601String();

class _Api extends ApiClient {
  _Api(this.rows, {this.replies = const {}}) {
    token = 't';
  }
  final List<Map<String, dynamic>> rows;
  final Map<String, Map<String, dynamic>> replies;
  final gets = <String>[];

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    gets.add(path);
    if (path == '/circle/chats') return {'results': rows};
    final r = replies[path] ?? replies[path.split('?').first];
    if (r != null) return Map<String, dynamic>.from(r);
    if (path.contains('/messages')) return {'results': const []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

AppState _state(ApiClient api, String lang) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 9, name: 'Me', phone: '+8801700000000', email: '', autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  return s;
}

Widget _app(ApiClient api, Widget home, {String lang = 'en'}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(api, lang),
      child: MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        home: home,
      ),
    );

Future<void> _pumpList(WidgetTester tester, _Api api, {String lang = 'en'}) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(
      api, Scaffold(body: MsgrHubChatList(identity: _me, members: const [])),
      lang: lang));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 20));
}

Map<String, dynamic> _row(String id, int peerUser, String name,
        {Map<String, dynamic>? last,
        String? at,
        int unread = 0,
        bool hasApp = true,
        String pub = '',
        bool sameName = false,
        String tail = '',
        String? request}) =>
    {
      'id': id,
      'kind': 'member',
      'member': {
        'id': int.parse(id),
        'name': name,
        'peer_user_id': peerUser,
        'public_key': pub,
        'same_name': sameName,
        if (tail.isNotEmpty) 'phone_tail': tail,
      },
      'last_text': '',
      'last': last,
      'unread': unread,
      'at': at,
      'peer_has_app': hasApp,
      'request': request,
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreviewCache.instance.resetForTest();
    UnreadStore.instance.reset();
    RealtimeChannel.instance.resetForTest();
    Outbox.instance.stop();
  });

  // ---------------------------------------------------------------- #1
  group('one row per person', () {
    test('dedupeChatRows: same peer user across edges / request threads', () {
      final rows = [
        _row('1', 77, 'Abul Kashem', at: _iso(const Duration(hours: 3)), unread: 4,
            request: 'outgoing'),
        _row('2', 77, 'Abul Kashem', at: _iso(const Duration(minutes: 1)), unread: 1),
        _row('3', 78, 'Rahim', at: _iso(const Duration(days: 1))),
        {'id': 'g1', 'kind': 'group', 'is_group': true, 'member': {'id': null}},
        _row('4', 77, 'Abul Kashem'), // no activity at all
      ];
      final out = dedupeChatRows(rows);
      expect(out.map((r) => r['id']), ['2', '3', 'g1']);
      expect(out.first['unread'], 4); // the max, never a double count
    });

    testWidgets('duplicated payload draws ONE row for the person', (tester) async {
      final last = {
        'id': 9,
        'mine': false,
        'content_type': 'text',
        'peer_public_key': _newPeer.publicKeyB64,
        ..._env('see you at 8', _newPeer, _me),
      };
      final api = _Api([
        _row('2', 77, 'Abul Kashem',
            last: last, at: _iso(const Duration(minutes: 2)), pub: _newPeer.publicKeyB64),
        _row('3', 77, 'Abul Kashem', at: null), // the circle edge, no messages
      ]);
      await _pumpList(tester, api);
      expect(find.text('Abul Kashem'), findsOneWidget);
      expect(find.text('see you at 8'), findsOneWidget);
      expect(find.text('No messages yet'), findsNothing);
      await _drain(tester);
    });

    testWidgets('same name, two DIFFERENT people: two rows + "…888" hint + '
        'honest not-on-Assisto line with a real Invite', (tester) async {
      final api = _Api([
        _row('2', 18, 'Abul Kashem',
            last: {
              'id': 9,
              'mine': false,
              'content_type': 'text',
              'peer_public_key': _newPeer.publicKeyB64,
              ..._env('hello', _newPeer, _me),
            },
            at: _iso(const Duration(minutes: 2)),
            sameName: true,
            tail: '200'),
        _row('9', 23, 'Abul Kashem', hasApp: false, sameName: true, tail: '888'),
      ]);
      await _pumpList(tester, api);
      expect(find.text('Abul Kashem'), findsNWidgets(2));
      expect(find.text('…200'), findsOneWidget);
      expect(find.text('…888'), findsOneWidget);
      expect(find.text("Hasn't opened Assisto yet"), findsOneWidget);
      expect(find.byKey(const Key('a1-invite')), findsOneWidget);
      expect(find.text('No messages yet'), findsNothing);
      await _drain(tester);
    });

    testWidgets('bn: the tail uses Bangla digits', (tester) async {
      final api = _Api([
        _row('2', 18, 'Abul Kashem', tail: '200'),
        _row('9', 23, 'Abul Kashem', tail: '888'),
      ]);
      await _pumpList(tester, api, lang: 'bn');
      expect(find.text('…৮৮৮'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _drain(tester);
    });

    test('unique names: no hint', () {
      final rows = [_row('1', 1, 'A', tail: '111'), _row('2', 2, 'B', tail: '222')];
      final dup = sameNameKeys(rows);
      expect(sameNameHint(rows[0], dup), '');
    });
  });

  // ---------------------------------------------------------------- #2
  group('preview after a key change', () {
    Map<String, dynamic> rowWith(Map<String, dynamic> last) => _row(
        '2', 18, 'Abul Kashem',
        last: last, at: _iso(const Duration(minutes: 1)), pub: _newPeer.publicKeyB64);

    test('incoming message sent under the OLD key: server history decrypts it', () {
      final r = rowWith({
        'id': 54,
        'mine': false,
        'content_type': 'text',
        'peer_public_key': _newPeer.publicKeyB64,
        'peer_key_history': [
          {'public_key': _oldPeer.publicKeyB64, 'key_id': _oldPeer.keyId}
        ],
        ..._env('Dinner at 8?', _oldPeer, _me),
      });
      final pv = ChatPreview.fromRow(r, identity: _me);
      expect(pv.kind, PreviewKind.text);
      expect(pv.text, 'Dinner at 8?');
    });

    test('my OWN last message (encrypted to the old key) decrypts too', () {
      final r = rowWith({
        'id': 55,
        'mine': true,
        'status': 'read',
        'content_type': 'text',
        'peer_public_key': _newPeer.publicKeyB64,
        ..._env('On my way', _me, _oldPeer),
      });
      // no server history: this phone's PeerKeyBook history supplies it
      final pv = ChatPreview.fromRow(r,
          identity: _me, extraPeerKeys: [_oldPeer.publicKey]);
      expect(pv.text, 'On my way');
      expect(pv.mine, isTrue);
    });

    test('no key works: the cached plaintext of THAT message, else the lock', () {
      final last = {
        'id': 56,
        'mine': false,
        'content_type': 'text',
        'peer_public_key': _newPeer.publicKeyB64,
        ..._env('secret', _other, _me),
      };
      expect(ChatPreview.fromRow(rowWith(last), identity: _me).kind,
          PreviewKind.encrypted);
      final pv = ChatPreview.fromRow(rowWith(last),
          identity: _me, cachedText: 'secret');
      expect(pv.kind, PreviewKind.text);
      expect(pv.text, 'secret');
    });

    testWidgets('list: PeerKeyBook remembers the old key → after the change '
        'the row still shows the text (never "Encrypted message")',
        (tester) async {
      // this phone saw the OLD key before (list load or chat open)
      await PeerKeyBook.instance.observe('member:2', _oldPeer.publicKeyB64);
      final api = _Api([
        rowWith({
          'id': 54,
          'mine': false,
          'content_type': 'text',
          'peer_public_key': _newPeer.publicKeyB64,
          ..._env('Dinner at 8?', _oldPeer, _me),
        })
      ]);
      await _pumpList(tester, api);
      expect(find.text('Dinner at 8?'), findsOneWidget);
      expect(find.text('Encrypted message'), findsNothing);
      await _drain(tester);
    });

    testWidgets('list: the preview cache written by the chat screen is used',
        (tester) async {
      await PreviewCache.instance.put('member:2', '57', 'cached text');
      PreviewCache.instance.resetForTest(); // a fresh app start reads prefs
      final api = _Api([
        rowWith({
          'id': 57,
          'mine': false,
          'content_type': 'text',
          'peer_public_key': _newPeer.publicKeyB64,
          ..._env('cached text', _other, _me),
        })
      ]);
      await _pumpList(tester, api);
      expect(find.text('cached text'), findsOneWidget);
      await _drain(tester);
    });
  });

  // ---------------------------------------------------------------- #3
  group('chat header at 360 dp', () {
    Future<void> header(WidgetTester tester, String lang, String name,
        String Function(AppLocalizations) status) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(
          _Api(const []),
          Builder(builder: (ctx) {
            final t = AppLocalizations.of(ctx);
            return Scaffold(
              appBar: AppBar(
                // the real chat has a back arrow: the narrowest title
                leading: IconButton(
                    onPressed: () {}, icon: const Icon(Icons.arrow_back)),
                titleSpacing: 0,
                title: ChatHeaderTitle(
                    name: name,
                    status: status(t),
                    avatar: HeaderInitialAvatar(name: name)),
                actions: [
                  IconButton(onPressed: () {}, icon: const Icon(Icons.videocam_outlined)),
                  IconButton(onPressed: () {}, icon: const Icon(Icons.call_outlined)),
                  IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
                ],
              ),
            );
          }),
          lang: lang));
      await tester.pump();
    }

    void expectFullyLaidOut(WidgetTester tester, String expected) {
      expect(tester.takeException(), isNull); // no overflow
      final p = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('t1-header-status')));
      expect(p.text.toPlainText(), expected);
      expect(p.didExceedMaxLines, isFalse, reason: 'status was cut: $expected');
      // and the text block sits inside the toolbar
      final r = tester.getRect(find.byKey(const Key('t1-header-status')));
      expect(r.bottom, lessThanOrEqualTo(kToolbarHeight + 1));
      expect(r.right, lessThanOrEqualTo(360));
    }

    for (final lang in ['en', 'bn']) {
      testWidgets('$lang: long name + longest last-seen line, never cut',
          (tester) async {
        final at = DateTime(2025, 12, 28, 22, 45);
        late String s;
        await header(
            tester,
            lang,
            lang == 'bn'
                ? 'Mohammad Abdullah Al Mamun Chowdhury'
                : 'Mohammad Abdullah Al Mamun Chowdhury',
            (t) => s = presenceLabel(t, RtChatState(online: false, lastSeen: at),
                    lang: lang, now: DateTime(2026, 10, 23, 9))!);
        expectFullyLaidOut(tester, s);
        // the NAME is the one that gives way
        final n = tester.renderObject<RenderParagraph>(
            find.byKey(const Key('t1-header-name')));
        expect(n.didExceedMaxLines, isTrue);
      });

      testWidgets('$lang: "last seen today at 10:05 pm" fully visible',
          (tester) async {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day, 0, 5);
        late String s;
        await header(tester, lang, 'Abul Kashem',
            (t) => s = presenceLabel(t, RtChatState(online: false, lastSeen: today),
                lang: lang)!);
        expectFullyLaidOut(tester, s);
      });
    }

    testWidgets('large system font (1.3x): still no clip', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      late String s;
      await header(tester, 'en', 'Abul Kashem',
          (t) => s = presenceLabel(
              t, RtChatState(online: false, lastSeen: DateTime(2025, 12, 28, 22, 45)),
              lang: 'en', now: DateTime(2026, 10, 23, 9))!);
      expect(tester.takeException(), isNull);
      final p = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('t1-header-status')));
      expect(p.text.toPlainText(), s);
      expect(p.didExceedMaxLines, isFalse);
    });
  });

  // ---------------------------------------------------------------- #4
  group('call events in the chat', () {
    Map<String, dynamic> ev(int id, String kind, bool out, String cat, int dur,
            DateTime at) =>
        {
          'id': id,
          'kind': kind,
          'outgoing': out,
          'category': cat,
          'duration_sec': dur,
          'started_at': at.toUtc().toIso8601String(),
        };

    test('parse: duplicates dropped, oldest first', () {
      final a = DateTime(2026, 10, 23, 10, 5);
      final l = parseCallEvents({
        'events': [
          ev(2, 'video', true, 'answered', 192, a.add(const Duration(hours: 1))),
          ev(1, 'voice', false, 'missed', 0, a),
          ev(1, 'voice', false, 'missed', 0, a),
        ]
      });
      expect(l.map((e) => e.id), [1, 2]);
    });

    testWidgets('labels en + bn', (tester) async {
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final bn = await AppLocalizations.delegate.load(const Locale('bn'));
      final at = DateTime(2026, 10, 23, 10, 5);
      CallEvent e(String kind, bool out, String cat, int d) => CallEvent(
          id: 1, kind: kind, outgoing: out, category: cat, durationSec: d, at: at);
      expect(callEventLabel(en, e('voice', false, 'missed', 0), 'en'), 'Missed voice call');
      expect(callEventLabel(en, e('video', true, 'answered', 192), 'en'), 'Video call · 3:12');
      expect(callEventLabel(en, e('voice', true, 'no_answer', 0), 'en'), 'Voice call · No answer');
      expect(callEventLabel(bn, e('voice', false, 'missed', 0), 'bn'), bn.a1CallMissedVoice);
      expect(callEventLabel(bn, e('voice', true, 'answered', 192), 'bn'),
          '${bn.a1CallVoice} · ৩:১২');
    });

    testWidgets('chips appear INSIDE the 1:1 chat by time; missed is red; '
        'tap calls back with the same kind', (tester) async {
      final base = DateTime.now().subtract(const Duration(hours: 1));
      final msg = _e2e.encrypt(
          self: _newPeer, recipientPublicKey: _me.publicKey, plaintext: 'are you free?');
      final api = _Api(const [], replies: {
        '/circle/5/messages': {
          'results': [
            {
              'id': 70,
              'sender_id': 2,
              'mine': false,
              'content_type': 'text',
              'created_at': base.toUtc().toIso8601String(),
              ...msg.toEnvelopeFields(),
            }
          ],
        },
        '/circle/keys/peer/5': {'public_key': _newPeer.publicKeyB64},
        '/circle/calls': {
          'member_id': 5,
          'events': [
            ev(11, 'voice', false, 'missed', 0, base.add(const Duration(minutes: 5))),
            ev(12, 'video', true, 'answered', 192, base.add(const Duration(minutes: 9))),
          ],
        },
      });
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(
          api,
          CircleChatScreen(member: {
            'id': 5,
            'name': 'Abul Kashem',
            'relation': 'friend',
            'state': 'accepted',
            'public_key': _newPeer.publicKeyB64,
          }, identity: _me)));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.gets, contains('/circle/calls?member=5'));
      expect(find.text('Missed voice call'), findsOneWidget);
      expect(find.text('Video call · 3:12'), findsOneWidget);
      expect(find.text('are you free?'), findsOneWidget);
      // by time: the message (oldest) is above the missed call, above the video
      final yMsg = tester.getTopLeft(find.text('are you free?')).dy;
      final yMissed = tester.getTopLeft(find.text('Missed voice call')).dy;
      final yVideo = tester.getTopLeft(find.text('Video call · 3:12')).dy;
      expect(yMsg < yMissed && yMissed < yVideo, isTrue);
      // red for missed
      final missedText = tester.widget<Text>(find.text('Missed voice call'));
      expect(missedText.style?.color, const Color(0xFFB91C1C));
      // tappable (call back) — calls are open for an accepted chat
      final chip = tester.widget<InkWell>(find.byKey(const ValueKey('a1-call-12')));
      expect(chip.onTap, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('chip: tap fires call back; null when calls are closed',
        (tester) async {
      var tapped = 0;
      final e = CallEvent(
          id: 3,
          kind: 'video',
          outgoing: false,
          category: 'missed',
          durationSec: 0,
          at: DateTime(2026, 10, 23, 10, 5));
      await tester.pumpWidget(_app(_Api(const []),
          Scaffold(body: CallEventChip(event: e, onCallBack: () => tapped++))));
      await tester.tap(find.byKey(const ValueKey('a1-call-3')));
      expect(tapped, 1);
      await tester.pumpWidget(_app(_Api(const []),
          Scaffold(body: CallEventChip(event: e))));
      expect(tester.widget<InkWell>(find.byKey(const ValueKey('a1-call-3'))).onTap,
          isNull);
    });
  });

  test('server key history JSON round-trips through candidateKeys', () {
    final r = {
      'member': {'public_key': _newPeer.publicKeyB64},
      'last': {
        'peer_public_key': _newPeer.publicKeyB64,
        'peer_key_history': [
          {'public_key': base64Encode(_oldPeer.publicKey)},
          {'public_key': _newPeer.publicKeyB64}, // dup ignored
        ],
      },
    };
    expect(ChatPreview.candidateKeys(r, const []).length, 2);
  });
}
