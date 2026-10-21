// Priority 7-8: family / SOS (up to the countdown, then cancel) and My Circle
// (a real E2E message both ways between the two seeded users + call screen).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/screens/circle_call_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

void registerFamilyCircleFlows() {
  realityFlow('13_family', 'Family & safety', 'Family members (seeded) load from server', (f) async {
    await f.home();
    await f.step('open Family', () async {
      await f.openFeature(f.t.moduleFamily, 'family');
      await f.shot('family');
      f.expectHttp('GET', '/family');
      await f.waitFor(find.textContaining('Ammu'), what: 'seeded member "Ammu"');
    });
  });

  realityFlow('14_sos_countdown', 'Family & safety', 'SOS: countdown shows, Cancel stops it (nothing sent)', (f) async {
    await f.home();
    final mark = f.httpMark;
    await f.step('open Emergency', () async {
      await f.openFeature(f.t.moduleEmergency, 'emergency');
      await f.shot('emergency');
      f.expectHttp('GET', '/emergency', since: mark);
    });
    await f.step('tap SOS -> countdown', () async {
      await f.tap(find.text(f.t.emergencySosBigButton), settleSeconds: 1);
      await f.waitFor(find.text(f.t.sosCancel), seconds: 6, what: 'countdown Cancel');
      await f.shot('countdown');
    });
    await f.step('Cancel -> "SOS cancelled", no SOS request sent', () async {
      final before = f.httpMark;
      await f.tap(find.text(f.t.sosCancel), settleSeconds: 2);
      await f.waitFor(find.text(f.t.emergencySosCancelled), seconds: 5);
      await f.shot('cancelled');
      final fired = f.h.recorder.hits.skip(before).where((x) => x.path.contains('sos'));
      if (fired.isNotEmpty) throw TestFailure('SOS was sent after Cancel: ${fired.map((x) => x.path)}');
      f.note('a real SOS (call + SMS to family) must be tested on a phone (checklist)');
    });
  });

  realityFlow('15_circle_message', 'My Circle', 'My Circle: E2E message A->B and B->A between seeded users', (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final idB = e2e.generateIdentity();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    await f.step('user B (the other phone) publishes its key', () async {
      await f.net(() => apiB.postJson('/circle/keys',
          {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme}));
    });
    await f.step('open My Circle; seeded friend B is connected', () async {
      await f.openRoute('circle');
      await f.shot('circle');
      f.expectHttp('GET', '/circle/members');
      await f.waitFor(find.text(Seed.nameB), what: 'connected member B');
    });
    final textA = 'Hello Karim a$_tag';
    await f.step('A opens the chat and sends a message', () async {
      await f.tap(find.text(Seed.nameB), settleSeconds: 3);
      await f.shot('chat');
      if (find.text(f.t.circleKeyMissing).evaluate().isNotEmpty) {
        throw TestFailure('chat says the peer key is missing');
      }
      await f.enter(textA, label: f.t.circleMessageHint);
      await f.tap(find.byIcon(Icons.send), settleSeconds: 3);
      await f.shot('sent');
      f.expectHttp('POST', '/circle/');
    });
    await f.step('B receives it and can decrypt it', () async {
      await f.eventually('B decrypts "$textA"', () async {
        final members = await apiB.getJson('/circle/members');
        final rows = ((members['results'] ?? members['members'] ?? []) as List).cast<Map<String, dynamic>>();
        final edge = rows.firstWhere((m) => '${m['name']}'.contains('Rahim'), orElse: () => {});
        if (edge.isEmpty || '${edge['public_key'] ?? ''}'.isEmpty) return false;
        final peer = base64Decode('${edge['public_key']}');
        final r = await apiB.getJson('/circle/${edge['id']}/messages');
        for (final m in (r['results'] as List).cast<Map<String, dynamic>>()) {
          if (m['mine'] == true) continue;
          final pt = e2e.decrypt(self: idB, senderPublicKey: peer,
              ct: Ciphertext(ciphertextB64: '${m['ciphertext']}', nonceB64: '${m['nonce']}',
                  senderKeyId: '${m['sender_key_id'] ?? ''}', scheme: '${m['scheme'] ?? e2e.scheme}'));
          if (pt != null && pt.contains(textA)) return true;
        }
        return false;
      }, seconds: 25);
    });
    final textB = 'Reply from Karim b$_tag';
    await f.step('B replies; A sees it in the open chat', () async {
      await f.net(() async {
        final members = await apiB.getJson('/circle/members');
        final rows = ((members['results'] ?? members['members'] ?? []) as List).cast<Map<String, dynamic>>();
        final edge = rows.firstWhere((m) => '${m['name']}'.contains('Rahim'));
        final ct = e2e.encrypt(self: idB, recipientPublicKey: base64Decode('${edge['public_key']}'),
            plaintext: textB);
        await apiB.postJson('/circle/${edge['id']}/messages',
            {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': 'reality-$_tag'});
      });
      await f.waitFor(find.textContaining(textB), seconds: 25, what: "B's reply in A's chat");
      await f.shot('reply-received');
    });
    // keep `api` referenced for symmetry with other flows (A-side checks)
    expect(api.token, isNotNull);
  }, timeout: const Duration(minutes: 5));

  realityFlow('16_circle_call', 'My Circle', 'My Circle: call screen opens and ends cleanly', (f) async {
    await f.home();
    await f.step('open chat with B -> voice call', () async {
      await f.openRoute('circle');
      await f.tap(find.text(Seed.nameB), settleSeconds: 3);
      await f.tap(find.byTooltip(f.t.circleVoiceCall), settleSeconds: 5);
      await f.shot('call-screen');
      await f.waitFor(find.byType(CircleCallScreen), what: 'call screen');
      f.expectHttp('POST', '/circle/');
      f.needsKey('TURN_STATIC_SECRET (coturn) + a second real phone with FCM for a connected call');
    });
    await f.step('hang up returns to the chat', () async {
      final hang = find.byIcon(Icons.call_end);
      if (hang.evaluate().isNotEmpty) {
        await f.tap(hang, settleSeconds: 3);
      } else {
        await f.back();
      }
      await f.shot('after-hangup');
      expect(find.byType(CircleCallScreen), findsNothing);
    });
  });
}
