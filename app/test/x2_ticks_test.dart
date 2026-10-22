// x2-ticks — WhatsApp-standard ticks on the device:
//   * background-isolate delivered ack with the STORED token + offline queue,
//   * silent msg_sync pings draw nothing but still ack,
//   * live receipt.update → tick (never downgrades), msg.new → instant ack,
//   * blue ✓✓ only when the chat is open AND visible (not covered),
//   * unmistakable tick colours on the new outgoing bubble (WCAG-checked),
//   * avatar cache keys (stable across signed-URL rotation, new on change).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/avatar_cache.dart';
import 'package:assisto/messaging/msg_ticks.dart';
import 'package:assisto/messaging/msg_widgets.dart';
import 'package:assisto/messaging/receipt_ack.dart';
import 'package:assisto/messaging/receipt_bus.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:assisto/widgets/msgr_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

Widget _wrap(Widget child, {Brightness b = Brightness.light, String lang = 'en'}) =>
    MaterialApp(
      theme: ThemeData(brightness: b),
      locale: Locale(lang),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('bn')],
      home: Scaffold(body: Center(child: child)),
    );

RealtimeEvent _ev(String topic, Map<String, dynamic> p) =>
    RealtimeEvent(1, topic, p, DateTime.now());

void main() {
  group('ReceiptAck (background isolate)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('acks with the STORED token, by message id', () async {
      final seen = <http.Request>[];
      final c = MockClient((r) async {
        seen.add(r);
        return http.Response('{"ok":true}', 200);
      });
      final ok = await ReceiptAck(token: () async => 'tok-b', client: c)
          .delivered([42]);
      expect(ok, isTrue);
      expect(seen.single.url.path, endsWith('/circle/receipts'));
      expect(seen.single.headers['Authorization'], 'Token tok-b');
      expect(jsonDecode(seen.single.body), {'delivered': [42]});
      expect(await ReceiptAck.queued(), isEmpty);
    });

    test('offline → queued → flushed with the next ack', () async {
      var online = false;
      final bodies = <dynamic>[];
      final c = MockClient((r) async {
        if (!online) throw http.ClientException('offline');
        bodies.add(jsonDecode(r.body));
        return http.Response('{}', 200);
      });
      final a = ReceiptAck(token: () async => 't', client: c);
      expect(await a.delivered([1]), isFalse);
      expect(await a.delivered([2]), isFalse);
      expect(await ReceiptAck.queued(), [1, 2]);
      online = true;
      expect(await a.delivered([3]), isTrue);
      expect(bodies.single, {'delivered': [1, 2, 3]});
      expect(await ReceiptAck.queued(), isEmpty);
    });

    test('server error keeps the queue; no token keeps the queue', () async {
      final c = MockClient((r) async => http.Response('no', 503));
      expect(await ReceiptAck(token: () async => 't', client: c).delivered([7]),
          isFalse);
      expect(await ReceiptAck(token: () async => null, client: c).delivered([8]),
          isFalse);
      expect(await ReceiptAck.queued(), [7, 8]);
      final ok = MockClient((r) async => http.Response('{}', 200));
      expect(await ReceiptAck(token: () async => 't', client: ok).flush(), isTrue);
      expect(await ReceiptAck.queued(), isEmpty);
    });

    test('queue is capped (newest kept)', () async {
      final c = MockClient((r) async => throw http.ClientException('x'));
      final a = ReceiptAck(token: () async => 't', client: c);
      await a.delivered(List.generate(ReceiptAck.maxQueue + 20, (i) => i + 1));
      final q = await ReceiptAck.queued();
      expect(q.length, ReceiptAck.maxQueue);
      expect(q.last, ReceiptAck.maxQueue + 20);
    });

    test('push handler: message acks + draws; msg_sync acks + syncs, draws nothing',
        () async {
      final paths = <String>[];
      final c = MockClient((r) async {
        paths.add(r.url.path);
        return http.Response('{}', 200);
      });
      final a = ReceiptAck(token: () async => 't', client: c);
      expect(
          await ackPushDelivery(
              {'kind': 'message', 'message_id': '5', 'chat_id': '3'}, ack: a),
          isFalse);
      expect(paths, [endsWith('/circle/receipts')]);
      paths.clear();
      expect(
          await ackPushDelivery(
              {'kind': 'msg_sync', 'message_id': '6', 'silent': '1'}, ack: a),
          isTrue);
      expect(paths, [endsWith('/circle/receipts'), endsWith('/circle/receipts/sync')]);
      paths.clear();
      expect(await ackPushDelivery({'kind': 'call', 'call_id': '1'}, ack: a),
          isFalse);
      expect(paths, isEmpty);
    });
  });

  group('ReceiptBus (live ticks)', () {
    tearDown(() => ReceiptBus.instance.reset());

    test('receipt.update → updates; msg.new → instant delivered ack', () async {
      final acked = <int>[];
      final fakeAck = _RecAck(acked);
      ReceiptBus.instance.attach(const Stream.empty(), ack: () => fakeAck);
      final got = <ReceiptUpdate>[];
      final news = <String>[];
      final s1 = ReceiptBus.instance.updates.listen(got.add);
      final s2 = ReceiptBus.instance.newMessages.listen(news.add);
      ReceiptBus.instance.onEvent(_ev('receipt.update', {
        'chat': 'member:4',
        'statuses': {'10': 'delivered', '11': 'read'}
      }));
      ReceiptBus.instance
          .onEvent(_ev('msg.new', {'chat': 'member:9', 'message_id': 77}));
      await Future<void>.delayed(Duration.zero);
      expect(got.single.chat, 'member:4');
      expect(got.single.statuses, {'10': 'delivered', '11': 'read'});
      expect(acked, [77]);
      expect(news, ['member:9']);
      await s1.cancel();
      await s2.cancel();
    });

    test('expect() switches the shared loop to fast, relax() back', () {
      final calls = <bool>[];
      ReceiptBus.instance.attach(const Stream.empty(), setFast: calls.add);
      ReceiptBus.instance.expect();
      ReceiptBus.instance.expect(); // extends, no second setFast(true)
      expect(ReceiptBus.instance.boosted, isTrue);
      ReceiptBus.instance.relax();
      expect(calls, [true, false]);
    });

    test('mergeStatus never downgrades', () {
      expect(mergeStatus('sent', 'delivered'), 'delivered');
      expect(mergeStatus('delivered', 'read'), 'read');
      expect(mergeStatus('read', 'delivered'), 'read');
      expect(mergeStatus('read', 'sent'), 'read');
      expect(mergeStatus('failed', 'read'), 'failed');
    });
  });

  group('tick colours on the new outgoing bubble', () {
    for (final b in Brightness.values) {
      testWidgets('✓ grey, ✓✓ grey, ✓✓ bright blue — WCAG (${b.name})',
          (tester) async {
        final colors = <String, Color?>{};
        Color? bubble;
        for (final s in ['sent', 'delivered', 'read']) {
          await tester.pumpWidget(_wrap(
              CircleBubble(
                  msg: CircleMessage(
                      id: '1', text: 'hi', mine: true, at: DateTime(2026, 10, 22, 13, 42),
                      status: s)),
              b: b));
          final key = ValueKey('tick-${s == 'read' ? 'read' : (s == 'delivered' ? 'delivered' : 'sent')}');
          colors[s] = tester.widget<Icon>(find.byKey(key)).color;
          final box = tester
              .widgetList<Container>(find.descendant(
                  of: find.byType(CircleBubble), matching: find.byType(Container)))
              .map((c) => c.decoration)
              .whereType<BoxDecoration>()
              .firstWhere((d) => d.color != null && d.borderRadius != null);
          bubble = box.color;
        }
        final dark = b == Brightness.dark;
        expect(bubble, dark ? MsgPalette.outDark : MsgPalette.outLight);
        expect(colors['sent'], colors['delivered']);
        expect(colors['read'], dark ? MsgPalette.readDark : MsgPalette.readLight);
        expect(colors['read'], isNot(colors['delivered']));
        // non-text contrast ≥ 3:1 for every tick, text ≥ 4.5:1
        for (final c in colors.values) {
          expect(contrast(c!, bubble!), greaterThanOrEqualTo(3.0));
        }
        expect(contrast(MsgPalette.outText(tester.element(find.byType(CircleBubble))),
                bubble!),
            greaterThanOrEqualTo(4.5));
        // the blue is far from the grey (distinct hue, not just lighter)
        final hb = HSVColor.fromColor(colors['read']!);
        expect(hb.saturation, greaterThan(0.6));
        expect(HSVColor.fromColor(colors['delivered']!).saturation, lessThan(0.25));
      });
    }

    testWidgets('read ticks on plain surfaces are readable too', (tester) async {
      expect(contrast(MsgPalette.readLight, Colors.white), greaterThanOrEqualTo(3.0));
      expect(contrast(MsgPalette.readDark, const Color(0xFF121212)),
          greaterThanOrEqualTo(3.0));
    });
  });

  group('Message info (honest receipts state, local time)', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('receipts off → "Read receipts are off" ($lang)', (tester) async {
        await tester.pumpWidget(_wrap(
            MessageInfoView(
                load: () async => {
                      'id': 1,
                      'group': false,
                      'status': 'delivered',
                      'my_read_receipts': true,
                      'recipients': [
                        {
                          'user_id': 20,
                          'name': 'T Shanto',
                          'delivered_at': '2026-10-22T07:42:03Z',
                          'seen_at': null,
                          'seen_hidden': false,
                          'receipts_off': true,
                        }
                      ]
                    }),
            lang: lang));
        await tester.pumpAndSettle();
        final t = lookupAppLocalizations(Locale(lang));
        expect(find.text(t.c3InfoReadHidden), findsOneWidget);
        expect(find.text(t.c3InfoPending), findsNothing);
      });
    }
  });

  group('avatar cache keys', () {
    test('stable across the hourly signed-link rotation, new on a new photo', () {
      final a = avatarStableKey('/api/v1/m/avatars/u20_x.jpg?e=1&s=a');
      final b = avatarStableKey('/api/v1/m/avatars/u20_x.jpg?e=2&s=b');
      final c = avatarStableKey('/api/v1/m/avatars/u20_y.jpg?e=2&s=b');
      expect(a, b);
      expect(a, isNot(c));
      expect(a, startsWith('http'));
      expect(avatarStableKey('anything', photoV: 'abc'), 'v:abc');
      expect(CachedAvatarImage('/api/v1/m/a.jpg?e=1', photoV: 'v1'),
          CachedAvatarImage('/api/v1/m/a.jpg?e=9', photoV: 'v1'));
      expect(CachedAvatarImage('/api/v1/m/a.jpg?e=1', photoV: 'v1'),
          isNot(CachedAvatarImage('/api/v1/m/b.jpg?e=1', photoV: 'v2')));
    });

    test('bytes: memory → disk-less network once, then cached', () async {
      var hits = 0;
      final cache = AvatarCache(
          client: MockClient((r) async {
            hits++;
            return http.Response.bytes([1, 2, 3], 200);
          }),
          dir: () async => null);
      final k = avatarStableKey('https://example.com/a.jpg', photoV: 'v1');
      expect(await cache.bytes('https://example.com/a.jpg', k), [1, 2, 3]);
      expect(await cache.bytes('https://example.com/a.jpg?rot=2', k), [1, 2, 3]);
      expect(hits, 1);
      // the contact changed the photo → new key → one new fetch
      await cache.bytes('https://example.com/b.jpg',
          avatarStableKey('https://example.com/b.jpg', photoV: 'v2'));
      expect(hits, 2);
    });

    testWidgets('MsgrAvatar: no photo → initial; base64 photo → image',
        (tester) async {
      await tester.pumpWidget(_wrap(const MsgrAvatar(name: 'Shanto')));
      expect(find.text('S'), findsOneWidget);
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      await tester.pumpWidget(_wrap(const MsgrAvatar(name: 'Shanto', photoUrl: png)));
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('proof crypto contract (tools/ticks_proof/ticks_proof.py)', () {
    Uint8List hex(String h) => Uint8List.fromList([
          for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)
        ]);
    test('the Python proof envelope decrypts with SoftwareE2E', () {
      final aPriv = hex('a8${'11' * 30}51');
      final bPriv = hex('b0${'22' * 30}62');
      final aPub = X25519.scalarMultBase(aPriv);
      final b = IdentityKeyPair(bPriv, X25519.scalarMultBase(bPriv), 'b');
      expect(base64Encode(aPub), 'UheCaXSOOo04jNyQoiNU0TlrRxLpuwNUS0X7CXXMExU=');
      final pt = SoftwareE2E().decrypt(
          self: b,
          senderPublicKey: aPub,
          ct: const Ciphertext(
              scheme: 'x25519-xchacha-fallback-v1',
              ciphertextB64: '8Si1Xh0CeqEMNU+5lX6dwFBfDLZvlYlQcbJXIlABiWzpCA==',
              nonceB64: 'AAECAwQFBgcICQoL',
              senderKeyId: '81bbb43463df'));
      expect(pt, 'ticks-proof \u2713\u2713');
    });
  });

  group('chat screen: read only when open AND visible', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      RealtimeChannel.instance.resetForTest();
    });
    tearDown(() => ReceiptBus.instance.reset());

    testWidgets('covered chat is not read; uncovered → seen; live ticks',
        (tester) async {
      final e2e = SoftwareE2E();
      final me = e2e.generateIdentity();
      final peer = e2e.generateIdentity();
      Map<String, dynamic> msg(int id, bool mine, String text, String status) {
        final ct = e2e.encrypt(
            self: mine ? me : peer,
            recipientPublicKey: mine ? peer.publicKey : me.publicKey,
            plaintext: text);
        return {
          'id': id, 'sender_id': mine ? 1 : 2, 'mine': mine,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'content_type': 'text', if (mine) 'status': status,
          ...ct.toEnvelopeFields(),
        };
      }

      final api = _ChatApi([msg(1, false, 'hello', ''), msg(2, true, 'hi', 'sent')]);
      final app = AppState()
        ..api = api
        ..loading = false
        ..user = AppUser(id: 1, name: 'Owner', autonomyLevel: 2, language: 'en');
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          navigatorKey: nav,
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('bn')],
          home: CircleChatScreen(
              member: {'id': 4, 'name': 'Shanto', 'public_key': base64Encode(peer.publicKey)},
              identity: me),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.seen, 1, reason: 'open + visible → seen');
      expect(find.byKey(const ValueKey('tick-sent')), findsOneWidget);

      // live receipt.update → blue ✓✓ without a reload
      ReceiptBus.instance.onEvent(_ev('receipt.update', {
        'chat': 'member:4',
        'statuses': {'2': 'read'}
      }));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('tick-read')), findsOneWidget);
      // a late "delivered" never downgrades
      ReceiptBus.instance.onEvent(_ev('receipt.update', {
        'chat': 'member:4',
        'statuses': {'2': 'delivered'}
      }));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('tick-read')), findsOneWidget);

      // cover the chat with another screen, then a message arrives
      nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('other'))));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      api.rows.add(msg(3, false, 'are you there?', ''));
      ReceiptBus.instance
          .onEvent(_ev('msg.new', {'chat': 'member:4', 'message_id': 3}));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(api.seen, 1, reason: 'covered → NOT read');

      // uncover → seen within the 1 s visibility tick
      nav.currentState!.pop();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(api.seen, 2, reason: 'visible again → read');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}

class _RecAck extends ReceiptAck {
  _RecAck(this.out) : super(token: () async => 't');
  final List<int> out;
  @override
  Future<bool> delivered(Iterable<int> ids, {bool sync = false}) async {
    out.addAll(ids);
    return true;
  }
}

class _ChatApi extends ApiClient {
  _ChatApi(this.rows) {
    token = 'test-token';
  }
  final List<Map<String, dynamic>> rows;
  int seen = 0;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    // e2-keys pages the history (`?limit=` / `?before=`): match the path only.
    if (path.split('?').first == '/circle/4/messages') {
      return {'results': List.of(rows), 'has_more': false};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path == '/circle/4/seen') seen++;
    return {'ok': true};
  }
}
