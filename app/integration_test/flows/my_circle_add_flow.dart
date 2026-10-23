// m3-circle — owner order "My Circle must work like WhatsApp", PROVEN on the
// CI emulator against the throw-away seeded Django (seed_reality):
//
//   A = Reality Rahim (the phone under test, 01700000001) — driven via the UI
//   C = Reality Nadia (the "second phone", registered as 01865052200, NOT
//       connected to A at seed time) — driven via an independent API client,
//       exactly like the existing family_circle_flow uses user B.
//
//   home chat "circle" -> My Circle add opens (the old "no match")
//   My Circle FAB -> New chat -> Add to My Circle -> "+880 1865-052200"
//   -> Friend -> Send -> success                       (A, UI)
//   C sees the request, adds A back typing "880-1700-000001" (= accept)
//   A <-> C real E2E messages both ways
//   voice + video call screens open and hang up (call records via the relay)
//
// Screenshot at every step. Real audio/video media is NOT provable here (no
// second device with mic/camera, TURN optional) — the flow notes that.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/messenger/m3_add_to_circle_screen.dart';
import 'package:assisto/screens/messenger/messenger_home_screen.dart';

import '../support/harness.dart';

const _phoneC = String.fromEnvironment('REALITY_PHONE_C', defaultValue: '01865052200');
const _nameC = 'Reality Nadia';
final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

void registerMyCircleAddFlows() {
  realityFlow('17_circle_add_whatsapp', 'My Circle',
      'My Circle like WhatsApp: add by number (any format), accept, message both ways, voice + video call',
      (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final idC = e2e.generateIdentity();
    late ApiClient apiC;

    await f.step('second phone (C, 01865052200) signs in + publishes its key', () async {
      apiC = await f.net(() async {
        final c = ApiClient();
        final res = await c.login(identifier: _phoneC, password: Seed.password);
        c.token = res.token;
        c.lang = 'en';
        await c.postJson('/circle/keys',
            {'public_key': idC.publicKeyB64, 'key_id': idC.keyId, 'scheme': e2e.scheme});
        return c;
      });
    });

    await f.step('home chat "circle" opens My Circle add (was "no match")', () async {
      await f.enter('circle', label: f.t.inputHint);
      await f.tap(find.byIcon(Icons.arrow_upward), settleSeconds: 4);
      await f.waitFor(find.byType(M3AddToCircleScreen), seconds: 10,
          what: 'Add to My Circle screen');
      await f.shot('chat-circle-opens-add');
      await f.backToHome();
    });

    await f.step('My Circle home -> FAB -> New chat (4 actions on top)', () async {
      await f.openRoute('circle');
      await f.waitFor(find.byType(MessengerHomeScreen), what: 'My Circle home');
      await f.shot('my-circle-home');
      await f.tap(find.byKey(const Key('m3-fab')), settleSeconds: 3);
      for (final k in ['m3-new-add', 'm3-new-group', 'm3-new-community', 'm3-new-invite']) {
        f.expectVisible(find.byKey(Key(k)), k);
      }
      await f.shot('new-chat');
    });

    await f.step('Add to My Circle: "+880 1865-052200" -> found', () async {
      await f.tap(find.byKey(const Key('m3-new-add')), settleSeconds: 2);
      await f.waitFor(find.byKey(const Key('m3-number')));
      await f.tester.enterText(find.byKey(const Key('m3-number')), '+880 1865-052200');
      await f.pumpFor(const Duration(milliseconds: 400));
      await f.shot('number-typed');
      await f.tap(find.byKey(const Key('m3-find')), settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('m3-found')), what: 'found card');
      f.expectHttp('POST', '/messenger/contacts/lookup');
      f.expectVisible(find.text(_nameC), 'C by name');
      await f.shot('found');
    });

    await f.step('relation Friend -> Send request -> clear success', () async {
      await f.tap(find.byKey(const Key('m3-rel-friend')), settleSeconds: 1);
      await f.shot('relation');
      await f.tap(find.byKey(const Key('m3-send')), settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('m3-sent')), what: 'success view');
      f.expectHttp('POST', '/circle/request');
      f.expectVisible(find.text(f.t.m3RequestSentTo(_nameC)), 'success text');
      await f.shot('request-sent');
      await f.tap(find.byKey(const Key('m3-done')), settleSeconds: 2);
    });

    await f.step('C sees the request (incoming, Accept/Decline) and adds A back '
        'typing "880-1700-000001" (= accept)', () async {
      await f.eventually('C has an incoming request from A', () async {
        final reqs = _rows(await apiC.getJson('/circle/requests'));
        return reqs.any((r) => r['direction'] == 'incoming' &&
            '${r['display_name']}'.contains('Rahim') &&
            (r['actions'] as List).contains('accept'));
      });
      final res = await f.net(() async {
        final look = await apiC.postJson('/messenger/contacts/lookup', {'phone': '880-1700-000001'});
        final uid = (look['user'] as Map)['id'];
        return apiC.postJson('/circle/request', {'to_user_id': uid, 'relation': 'friend'});
      });
      if (res['state'] != 'accepted') {
        throw TestFailure('adding back did not accept: $res');
      }
    });

    await f.step('A: C is now in My Circle', () async {
      await f.backToHome();
      await f.openRoute('circle', settleSeconds: 4);
      await f.waitFor(find.text(_nameC), seconds: 20, what: 'C in the chat list');
      await f.shot('connected');
    });

    final textA = 'Hi Nadia from Rahim a$_tag';
    await f.step('A sends a message; C receives and decrypts it', () async {
      await f.tap(find.text(_nameC), settleSeconds: 3);
      if (find.text(f.t.circleKeyMissing).evaluate().isNotEmpty) {
        throw TestFailure('chat says the peer key is missing');
      }
      await f.enter(textA, label: f.t.circleMessageHint);
      await f.tap(find.byIcon(Icons.send), settleSeconds: 3);
      await f.shot('a-sent');
      await f.eventually('C decrypts "$textA"', () async {
        final edge = _rows(await apiC.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'), orElse: () => {});
        if (edge.isEmpty || '${edge['public_key'] ?? ''}'.isEmpty) return false;
        final peer = base64Decode('${edge['public_key']}');
        final r = await apiC.getJson('/circle/${edge['id']}/messages');
        for (final m in _rows(r)) {
          if (m['mine'] == true) continue;
          final pt = e2e.decrypt(self: idC, senderPublicKey: peer,
              ct: Ciphertext(ciphertextB64: '${m['ciphertext']}', nonceB64: '${m['nonce']}',
                  senderKeyId: '${m['sender_key_id'] ?? ''}', scheme: '${m['scheme'] ?? e2e.scheme}'));
          if (pt != null && pt.contains(textA)) return true;
        }
        return false;
      }, seconds: 25);
    });

    final textC = 'Reply from Nadia c$_tag';
    await f.step('C replies; A sees it in the open chat', () async {
      await f.net(() async {
        final edge = _rows(await apiC.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        final ct = e2e.encrypt(self: idC,
            recipientPublicKey: base64Decode('${edge['public_key']}'), plaintext: textC);
        await apiC.postJson('/circle/${edge['id']}/messages',
            {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': 'm3-$_tag'});
      });
      await f.waitFor(find.textContaining(textC), seconds: 25, what: "C's reply in A's chat");
      await f.shot('reply-received');
    });

    for (final (kind, tip) in [('voice', f.t.circleVoiceCall), ('video', f.t.circleVideo)]) {
      await f.step('$kind call: screen opens, call placed, hang up', () async {
        final mark = f.httpMark;
        await f.tap(find.byTooltip(tip), settleSeconds: 5);
        await f.waitFor(find.byType(CircleCallScreen), what: '$kind call screen');
        await f.shot('$kind-call');
        f.expectHttp('GET', '/rtc/turn', since: mark);
        // The call screen has no AppBar back button. Live/ringing shows the
        // red hang-up; a call that already ended (no answer on the emulator)
        // shows Close instead — tap whichever the user would see.
        final hang = find.byKey(const Key('call-hangup'));
        final close = find.byKey(const Key('call-close'));
        if (hang.evaluate().isNotEmpty) {
          await f.tap(hang, settleSeconds: 3);
        } else if (close.evaluate().isNotEmpty) {
          await f.tap(close, settleSeconds: 3);
        } else {
          throw TestFailure('$kind call screen shows neither hang-up nor Close');
        }
        await f.shot('$kind-hung-up');
        expect(find.byType(CircleCallScreen), findsNothing);
      });
    }
    f.note('real audio/video media needs two physical phones (flutter_webrtc media '
        'seam + TURN); CI proves the call records, ring payload (backend test) and screens');
    f.needsKey('TURN_STATIC_SECRET (coturn) + FCM on two real phones for a connected call');
  }, timeout: const Duration(minutes: 6));
}
