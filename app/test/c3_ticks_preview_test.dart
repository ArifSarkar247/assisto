// c3-msg — ticks + chat-list preview (the "No messages yet" root cause).
import 'dart:convert';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_preview.dart';
import 'package:assisto/messaging/msg_ticks.dart';
import 'package:assisto/widgets/circle_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {Brightness b = Brightness.light}) => MaterialApp(
      theme: ThemeData(brightness: b),
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('bn')],
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  final e2e = SoftwareE2E();
  final me = e2e.generateIdentity();
  final peer = e2e.generateIdentity();

  Map<String, dynamic> env(String text,
      {required IdentityKeyPair from, required IdentityKeyPair to}) {
    final ct = e2e.encrypt(self: from, recipientPublicKey: to.publicKey, plaintext: text);
    return {
      'ciphertext': ct.ciphertextB64,
      'nonce': ct.nonceB64,
      'sender_key_id': ct.senderKeyId,
      'scheme': ct.scheme,
    };
  }

  group('tick states', () {
    test('server status → tick', () {
      expect(tickFrom('sent'), MsgTick.sent);
      expect(tickFrom('delivered'), MsgTick.delivered);
      expect(tickFrom('read'), MsgTick.read);
      expect(tickFrom(null), MsgTick.sent);
      expect(tickFrom('read', pending: true), MsgTick.pending);
      expect(tickFrom('sent', failed: true), MsgTick.failed);
    });

    test('a late poll never downgrades', () {
      expect(maxTick(MsgTick.read, MsgTick.sent), MsgTick.read);
      expect(maxTick(MsgTick.sent, MsgTick.delivered), MsgTick.delivered);
    });

    test('icons: ✓ / ✓✓ / ✓✓', () {
      expect(tickIcon(MsgTick.sent), Icons.done_rounded);
      expect(tickIcon(MsgTick.delivered), Icons.done_all_rounded);
      expect(tickIcon(MsgTick.read), Icons.done_all_rounded);
    });

    for (final b in Brightness.values) {
      testWidgets('my bubble renders sent → delivered → blue read (${b.name})',
          (tester) async {
        for (final s in ['sent', 'delivered', 'read']) {
          await tester.pumpWidget(_wrap(
              CircleBubble(
                  msg: CircleMessage(
                      id: '1', text: 'hi', mine: true, at: DateTime(2026, 10, 22, 10, 14),
                      status: s)),
              b: b));
          final want = s == 'sent' ? 'tick-sent' : (s == 'delivered' ? 'tick-delivered' : 'tick-read');
          expect(find.byKey(ValueKey(want)), findsOneWidget, reason: s);
        }
        final read = tester.widget<Icon>(find.byKey(const ValueKey('tick-read')));
        final ctx = tester.element(find.byKey(const ValueKey('tick-read')));
        expect(read.color, readTickColor(ctx, onMyBubble: true));
        // the blue differs from the delivered (muted) colour
        await tester.pumpWidget(_wrap(
            CircleBubble(
                msg: CircleMessage(
                    id: '1', text: 'hi', mine: true, at: DateTime(2026), status: 'delivered')),
            b: b));
        final dl = tester.widget<Icon>(find.byKey(const ValueKey('tick-delivered')));
        expect(dl.color, isNot(read.color));
      });
    }

    testWidgets('received bubble has no tick', (tester) async {
      await tester.pumpWidget(_wrap(CircleBubble(
          msg: CircleMessage(id: '2', text: 'yo', mine: false, at: DateTime(2026)))));
      expect(find.byKey(const ValueKey('tick-sent')), findsNothing);
    });
  });

  group('chat preview (decrypted on device)', () {
    test('ROOT CAUSE: last_text is empty but `last` decrypts → real text', () {
      final row = {
        'id': '12',
        'last_text': '',
        'unread': 3,
        'at': '2026-10-22T10:14:00Z',
        'member': {'name': 'Rahim', 'public_key': base64Encode(peer.publicKey)},
        'last': {
          'id': 9,
          'mine': false,
          'content_type': 'text',
          'peer_public_key': base64Encode(peer.publicKey),
          ...env('Assalamu alaikum', from: peer, to: me),
        },
      };
      final p = ChatPreview.fromRow(row, identity: me, e2e: e2e);
      expect(p.kind, PreviewKind.text);
      expect(p.text, 'Assalamu alaikum');
      expect(p.mine, isFalse);
      expect(p.tick, isNull);
      expect(ChatPreview.unreadOf(row), 3);
    });

    test('my own last message decrypts (symmetric ECDH) + carries the tick', () {
      final row = {
        'id': '12',
        'member': {'public_key': base64Encode(peer.publicKey)},
        'last': {
          'id': 10,
          'mine': true,
          'status': 'read',
          'content_type': 'text',
          'peer_public_key': base64Encode(peer.publicKey),
          ...env('see you', from: me, to: peer),
        },
      };
      final p = ChatPreview.fromRow(row, identity: me, e2e: e2e);
      expect(p.text, 'see you');
      expect(p.mine, isTrue);
      expect(p.tick, MsgTick.read);
    });

    test('group: sender name kept for the "Rahim: …" prefix', () {
      final row = {
        'id': 'g3',
        'kind': 'group',
        'is_group': true,
        'last': {
          'id': 11,
          'mine': false,
          'sender_name': 'Rahim',
          'content_type': 'text',
          'peer_public_key': base64Encode(peer.publicKey),
          ...env('meeting at 5', from: peer, to: me),
        },
      };
      final p = ChatPreview.fromRow(row, identity: me, e2e: e2e);
      expect(p.isGroup, isTrue);
      expect(p.senderName, 'Rahim');
      expect(p.text, 'meeting at 5');
    });

    test('never "empty" when a message exists — keys missing → encrypted', () {
      final row = {
        'last': {'id': 1, 'mine': false, 'content_type': 'text', 'ciphertext': 'x', 'nonce': 'y'},
      };
      expect(ChatPreview.fromRow(row, identity: null).kind, PreviewKind.encrypted);
      expect(ChatPreview.fromRow(row, identity: me).kind, PreviewKind.encrypted);
      // wrong key
      final other = e2e.generateIdentity();
      final bad = {
        'last': {
          'id': 2,
          'mine': false,
          'content_type': 'text',
          'peer_public_key': base64Encode(other.publicKey),
          ...env('secret', from: peer, to: me),
        },
      };
      expect(ChatPreview.fromRow(bad, identity: me, e2e: e2e).kind, PreviewKind.encrypted);
    });

    test('really empty / deleted / media', () {
      expect(ChatPreview.fromRow({'last': null}, identity: me).kind, PreviewKind.empty);
      expect(
          ChatPreview.fromRow({
            'last': {'id': 1, 'deleted': 'everyone', 'mine': false}
          }, identity: me).kind,
          PreviewKind.deleted);
      final media = ChatPreview.fromRow({
        'last': {'id': 1, 'content_type': 'photo', 'mine': true, 'status': 'delivered'}
      }, identity: me);
      expect(media.kind, PreviewKind.media);
      expect(media.tick, MsgTick.delivered);
    });

    test('manual "Mark as unread" counts as 1 until opened', () {
      expect(ChatPreview.unreadOf({'unread': 0, 'marked_unread': true}), 1);
      expect(ChatPreview.unreadOf({'unread': 0}), 0);
      expect(ChatPreview.unreadOf({'unread': 4, 'marked_unread': true}), 4);
    });
  });
}
