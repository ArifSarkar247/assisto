// ai-reply-core (owner order 17 Nov, part H): My Circle AI reply, proven on
// the CI emulator against the seeded Django with the CI FAKE AI (answers are
// marked "(CI)"; settings_e2eproof). Opt-in: REALITY_ONLY=aireply (needs the
// e2e fakes + the `ai_reply` flag the e2e seed turns on for the run only).
//
//   A = Reality Rahim (this app, driven via the UI)
//   B = Reality Karim (the "second phone", an independent API client)
//
//   A: chat ⋮ → AI reply → Suggest. B writes → chips above A's composer →
//   one tap sends (no tag on B's side). A: Full auto. B writes → A's open
//   chat answers by itself → B's copy carries ai_reply + ai_label. B writes
//   about money → nothing is sent; A sees "AI held a message".
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/screens/circle_chat_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

void registerAiReplyFlows() {
  realityFlow('30_ai_reply', 'My Circle',
      'AI reply: Suggest chips (one tap sends), Full auto with the tag on the receiver, money message held',
      (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final idB = e2e.generateIdentity();
    final apiB = await f.h.backend(userB: true);
    late Map<String, dynamic> edgeB;

    Future<void> bSends(String text, String cmid) => f.net(() async {
          final ct = e2e.encrypt(self: idB,
              recipientPublicKey: base64Decode('${edgeB['public_key']}'), plaintext: text);
          await apiB.postJson('/circle/${edgeB['id']}/messages',
              {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': cmid});
        });

    Future<List<Map<String, dynamic>>> bInbox() async =>
        _rows(await apiB.getJson('/circle/${edgeB['id']}/messages'))
            .where((m) => m['mine'] != true)
            .toList();

    await f.step('B publishes its key', () async {
      await f.net(() async {
        await apiB.postJson('/circle/keys',
            {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      });
    });

    await f.step('A: chat ⋮ → AI reply → Suggest', () async {
      await f.openRoute('circle');
      await f.waitFor(find.text(Seed.nameB), what: 'B in the chat list');
      await f.tap(find.text(Seed.nameB), settleSeconds: 3);
      await f.waitFor(find.byType(CircleChatScreen), what: 'chat');
      await f.tap(find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.more_vert_rounded) /* itag-proof: reality guard */);
      await f.tap(find.text(f.t.aiReplyMenu), settleSeconds: 2);
      await f.waitFor(find.byKey(const Key('aireply-sheet')), what: 'AI reply sheet');
      await f.shot('ai-sheet');
      await f.tap(find.byKey(const Key('aireply-mode-suggest')), settleSeconds: 2);
      await f.tap(find.byKey(const Key('aireply-done')), settleSeconds: 2);
    });

    await f.step('B writes → chips → one tap sends (no AI tag)', () async {
      final before = (await f.net(bInbox)).length;
      await bSends('kemon acho? s$_tag', 'ai-s-$_tag');
      await f.waitFor(find.byKey(const Key('aireply-chip-0')), seconds: 30, what: 'AI chips');
      await f.shot('ai-chips');
      await f.tap(find.byKey(const Key('aireply-chip-0')), settleSeconds: 3);
      await f.eventually('B gets the tapped reply, untagged', () async {
        final rows = await bInbox();
        return rows.length > before && rows.last['ai_reply'] == false;
      }, seconds: 20);
    });

    await f.step('A: Full auto → B writes → A\'s phone answers, tagged on B', () async {
      await f.tap(find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.more_vert_rounded) /* itag-proof: reality guard */);
      await f.tap(find.text(f.t.aiReplyMenu), settleSeconds: 2);
      await f.tap(find.byKey(const Key('aireply-mode-auto')), settleSeconds: 2);
      await f.tap(find.byKey(const Key('aireply-done')), settleSeconds: 2);
      final before = (await f.net(bInbox)).length;
      await bSends('ki koro? a$_tag', 'ai-a-$_tag');
      await f.eventually('B gets an AI reply with the tag', () async {
        final rows = await bInbox();
        return rows.length > before && rows.last['ai_reply'] == true && rows.last['ai_label'] == true;
      }, seconds: 45);
      await f.pumpFor(const Duration(seconds: 8));
      await f.shot('ai-auto-tag');
    });

    await f.step('B asks for money → held, nothing sent, A sees the notice', () async {
      final before = (await f.net(bInbox)).length;
      await f.pumpFor(const Duration(seconds: 31)); // the 30-s per-chat limit
      await bSends('500 taka bkash koro m$_tag', 'ai-m-$_tag');
      await f.waitFor(find.byKey(const Key('aireply-mode-strip')), seconds: 30, what: 'held notice');
      await f.shot('ai-held');
      final after = (await f.net(bInbox)).length;
      if (after != before) throw TestFailure('AI answered a money message');
    });

    f.note('replies while the app is closed run in the FCM handler (unit-tested); '
        'the shade itself needs a real phone');
  }, timeout: const Duration(minutes: 6));
}
