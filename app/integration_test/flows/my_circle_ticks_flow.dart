// c3-msg — WhatsApp-standard ticks, chat-list preview, unread badge,
// presence/typing and the notification inline-reply path, PROVEN on the CI
// emulator against the seeded Django:
//
//   A = Reality Rahim (this app, driven via the UI)
//   B = Reality Karim (the "second phone", an independent API client)
//
//   A sends → ✓ sent;  B's device syncs → ✓✓ delivered;  B opens → blue ✓✓
//   B types → A's header says "typing…";  B goes online → "online"
//   B sends → A's chat list shows the DECRYPTED preview + unread badge (never
//   "No messages yet");  A opens → badge 0 and B sees A's read tick
//   A's inline reply (the notification handler, real crypto + real HTTP) →
//   B decrypts it.
// Screenshot at every step. The Android notification shade itself (tapping
// Reply in the shade, bubbles) needs a real phone — noted honestly.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/screens/circle_chat_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

void registerMyCircleTicksFlows() {
  realityFlow('19_circle_ticks', 'My Circle',
      'Ticks sent → delivered → read, typing/online in the header, decrypted chat-list preview, unread badge clears, inline reply',
      (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final idB = e2e.generateIdentity();
    final apiA = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    late Map<String, dynamic> edgeB; // B's edge to A
    Future<String> lastMineStatusA() async {
      final edgeA = _rows(await apiA.getJson('/circle/members'))
          .firstWhere((m) => '${m['name']}' == Seed.nameB);
      final rows = _rows(await apiA.getJson('/circle/${edgeA['id']}/messages'))
          .where((m) => m['mine'] == true)
          .toList();
      return rows.isEmpty ? '' : '${rows.last['status']}';
    }

    await f.step('B publishes its key; both allow online/last seen for My Circle', () async {
      await f.net(() async {
        await apiB.postJson('/circle/keys',
            {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
        for (final c in [apiA, apiB]) {
          await c.postJson('/circle/privacy', {
            'visibility': {'last_seen': 'everyone', 'active_status': 'everyone'},
            'read_receipts': true,
            'typing': true,
          });
        }
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      });
    });

    final textA = 'Tick test a$_tag';
    await f.step('A sends → ✓ (sent)', () async {
      await f.openRoute('circle');
      await f.waitFor(find.text(Seed.nameB), what: 'B in the chat list');
      await f.tap(find.text(Seed.nameB), settleSeconds: 3);
      await f.waitFor(find.byType(CircleChatScreen), what: 'chat');
      await f.enter(textA, label: f.t.circleMessageHint);
      await f.tap(find.byIcon(Icons.send), settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('tick-sent')), seconds: 20, what: 'single tick');
      f.expectHttp('POST', '/circle/');
      await f.eventually('server: A\'s last message is "sent"',
          () async => await lastMineStatusA() == 'sent', seconds: 10);
      await f.shot('tick-sent');
    });

    await f.step('B\'s device fetches → ✓✓ delivered on A', () async {
      await f.net(() => apiB.postJson('/circle/receipts/sync'));
      await f.eventually('server: delivered',
          () async => await lastMineStatusA() == 'delivered', seconds: 10);
      await f.waitFor(find.byKey(const ValueKey('tick-delivered')), seconds: 25,
          what: 'double grey tick (A polls every 7 s)');
      await f.shot('tick-delivered');
    });

    await f.step('B opens the chat → blue ✓✓ read on A', () async {
      await f.net(() => apiB.postJson('/circle/${edgeB['id']}/seen'));
      await f.eventually('server: read',
          () async => await lastMineStatusA() == 'read', seconds: 10);
      await f.waitFor(find.byKey(const ValueKey('tick-read')), seconds: 25, what: 'blue double tick');
      await f.shot('tick-read');
    });

    await f.step('B types → "typing…" in A\'s header; then "online"', () async {
      await f.net(() => apiB.postJson('/circle/rt/typing',
          {'chat_kind': 'member', 'chat_id': edgeB['id'], 'state': 'typing'}));
      await f.waitFor(find.text(f.t.c3Typing), seconds: 15, what: 'typing… in the header');
      await f.shot('header-typing');
      await f.net(() => apiB.postJson('/circle/rt/typing',
          {'chat_kind': 'member', 'chat_id': edgeB['id'], 'state': 'stop'}));
      await f.net(() => apiB.postJson('/circle/rt/presence', {'state': 'online'}));
      await f.waitFor(find.text(f.t.c3Online), seconds: 15, what: 'online in the header');
      await f.shot('header-online');
    });

    final textB = 'Preview check b$_tag';
    await f.step('back on the list: B sends → decrypted preview + unread badge', () async {
      await f.back();
      await f.net(() async {
        final ct = e2e.encrypt(self: idB,
            recipientPublicKey: base64Decode('${edgeB['public_key']}'), plaintext: textB);
        await apiB.postJson('/circle/${edgeB['id']}/messages',
            {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': 'c3-$_tag'});
      });
      // pull-to-refresh is NOT required in WhatsApp; we reopen the hub tab to
      // reload like a user returning to it
      await f.backToHome();
      await f.openRoute('circle', settleSeconds: 4);
      await f.waitFor(find.text(textB), seconds: 20, what: 'decrypted preview');
      if (find.text(f.t.msgrNoMessagesYet).evaluate().isNotEmpty) {
        throw TestFailure('"No messages yet" shown while messages exist');
      }
      f.expectVisible(find.byKey(const Key('c3-tab-badge')), 'My Circle tab badge');
      await f.shot('list-preview-unread');
    });

    await f.step('A opens the chat → badge 0; B sees A\'s read tick', () async {
      await f.tap(find.text(Seed.nameB), settleSeconds: 4);
      f.expectHttp('POST', '/circle/');
      await f.back();
      await f.pumpFor(const Duration(seconds: 2));
      await f.shot('list-after-open');
      await f.eventually('B sees its message as read', () async {
        final rows = _rows(await apiB.getJson('/circle/${edgeB['id']}/messages'));
        final mine = rows.where((m) => m['mine'] == true).toList();
        return mine.isNotEmpty && mine.last['status'] == 'read';
      }, seconds: 20);
      await f.eventually('A\'s server unread count is 0', () async {
        final rows = _rows(await apiA.getJson('/circle/chats'));
        final r = rows.firstWhere((x) => '${(x['member'] as Map?)?['name']}' == Seed.nameB,
            orElse: () => {});
        return r.isNotEmpty && (r['unread'] ?? 0) == 0;
      }, seconds: 15);
    });

    final reply = 'Inline reply r$_tag';
    await f.step('notification inline reply (handler, real crypto + HTTP) → B decrypts', () async {
      final ok = await f.net(() async {
        final edgeA = _rows(await apiA.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}' == Seed.nameB);
        final h = MsgPushHandler(
          backend: HttpMsgBackend(apiA.token!, lang: 'en'),
          identity: loadStoredIdentity,
          sink: FlnMsgSink(),
        );
        return h.reply('member', edgeA['id'] as int, reply, lang: 'en');
      });
      if (ok != true) throw TestFailure('inline reply handler failed');
      await f.eventually('B decrypts the inline reply', () async {
        final rows = _rows(await apiB.getJson('/circle/${edgeB['id']}/messages'));
        final peer = base64Decode('${edgeB['public_key']}');
        for (final m in rows.where((m) => m['mine'] != true)) {
          final pt = e2e.decrypt(self: idB, senderPublicKey: peer,
              ct: Ciphertext(ciphertextB64: '${m['ciphertext']}', nonceB64: '${m['nonce']}',
                  senderKeyId: '${m['sender_key_id'] ?? ''}', scheme: '${m['scheme'] ?? e2e.scheme}'));
          if (pt == reply) return true;
        }
        return false;
      }, seconds: 20);
    });

    f.note('the Android shade (tap Reply / Mark as read in the notification), '
        'MessagingStyle rendering and bubbles need a real phone; the same handler '
        'code path is exercised here');
  }, timeout: const Duration(minutes: 6));
}
