// m3-circle — owner order "My Circle must work like WhatsApp", PROVEN on the
// CI emulator against the throw-away seeded Django (seed_reality):
//
//   A = Reality Rahim (the phone under test, 01700000001) — driven via the UI
//   C = Reality Nadia (the "second phone", registered as 01711000777, NOT
//       connected to A at seed time) — driven via an independent API client,
//       exactly like the existing family_circle_flow uses user B.
//
//   home chat "circle" -> My Circle add opens (the old "no match")
//   My Circle FAB -> New chat -> Add to My Circle -> "+880 1711-000777"
//   -> Friend -> Send -> success                       (A, UI)
//   C sees the request, adds A back typing "880-1700-000001" (= accept)
//   A <-> C real E2E messages both ways
//   voice + video calls to the NEW contact: C answers with its own WebRTC
//   peer -> both connected -> media flows (C hears A; on video C decodes A's
//   camera) -> A hangs up                             (circle17)
//
// Screenshot at every step. TURN relay + FCM ring with the app closed need
// two real phones: owner checklist (does not lower the grade, owner order).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/api_call_signaling.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/calls/call_runtime.dart';
import 'package:assisto/calls/webrtc_media.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/messenger/m3_add_to_circle_screen.dart';
import 'package:assisto/screens/messenger/messenger_home_screen.dart';

import '../support/harness.dart';

const _phoneC = String.fromEnvironment('REALITY_PHONE_C', defaultValue: '01711000777');
const _nameC = 'Reality Nadia';
final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

class _QuietSounds implements CallSounds {
  @override
  Future<void> startRingback() async {}
  @override
  Future<void> stopRingback() async {}
  @override
  Future<void> playBusy() async {}
  @override
  Future<void> playDeclined() async {}
  @override
  Future<void> playEnded() async {}
  @override
  Future<void> stopAll() async {}
  @override
  Future<void> setProximity(bool on) async {}
}

void registerMyCircleAddFlows() {
  realityFlow('17_circle_add_whatsapp', 'My Circle',
      'My Circle like WhatsApp: add by number (any format), accept, message both ways, voice + video call',
      (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final idC = e2e.generateIdentity();
    late ApiClient apiC;

    await f.step('second phone (C, 01711000777) signs in + publishes its key', () async {
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
      await f.openHomeChat(); // home_v2: the chat has its own screen
      await f.enter('circle', label: f.t.inputHint);
      await f.tapSend(settleSeconds: 4);
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

    await f.step('Add to My Circle: "+880 1711-000777" -> found', () async {
      await f.tap(find.byKey(const Key('m3-new-add')), settleSeconds: 2);
      await f.waitFor(find.byKey(const Key('m3-number')));
      await f.tester.enterText(find.byKey(const Key('m3-number')), '+880 1711-000777');
      await f.pumpFor(const Duration(milliseconds: 400));
      await f.shot('number-typed');
      await f.tap(find.byKey(const Key('m3-find')), settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('m3-found')), what: 'found card');
      f.expectHttp('POST', '/messenger/contacts/lookup');
      f.expectVisible(find.text(_nameC), 'C by name');
      await f.shot('found');
    });

    // a1-circle: the reality driver RE-RUNS a flow after an emulator restart
    // on the SAME seeded DB (no re-seed). If the interrupted first attempt
    // already sent the request (or C already accepted), the found card shows
    // "Request sent" / "In your circle" instead of the relation picker — the
    // app is right, the old flow assumed a fresh DB. Continue from there.
    final already = find.byKey(const Key('m3-already')).evaluate().isNotEmpty;
    final pending = find.byKey(const Key('m3-pending')).evaluate().isNotEmpty;
    if (already || pending) {
      f.note('resumed after an interrupted attempt: A->C already '
          '${already ? 'connected' : 'requested'} (no re-seed); request step skipped');
    }

    if (!already && !pending)
    await f.step('relation Friend -> Send request -> chat opens with "Request sent"', () async {
      await f.tap(find.byKey(const Key('m3-rel-friend')), settleSeconds: 1);
      await f.shot('relation');
      await f.tap(find.byKey(const Key('m3-send')), settleSeconds: 3);
      f.expectHttp('POST', '/circle/request');
      // connect-flow (owner order 25 Oct, 5ba32e6): no dead-end success page
      // any more — the chat with C opens at once with the "Request sent —
      // they can reply after accepting" banner. The old success view
      // (m3-sent) is still shown when the server returns no member id.
      final banner = find.text(f.t.connRequestSentBanner);
      final sentView = find.byKey(const Key('m3-sent'));
      await f.waitFor(find.byWidgetPredicate((_) =>
              banner.evaluate().isNotEmpty || sentView.evaluate().isNotEmpty),
          what: 'chat with the "Request sent" banner (or the sent view)');
      await f.shot('request-sent');
      if (sentView.evaluate().isNotEmpty) {
        f.expectVisible(find.text(f.t.m3RequestSentTo(_nameC)), 'success text');
        await f.tap(find.byKey(const Key('m3-done')), settleSeconds: 2);
      } else {
        f.expectVisible(find.text(_nameC), 'chat header shows C');
      }
    });
    await f.backToHome();
    if (already || pending) await f.backToHome();

    if (!already)
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
      await f.tapSend(settleSeconds: 3);
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

    // circle17: C keeps its real-time channel open and ANSWERS like a phone.
    late PollRealtimeTransport rtC;
    final incomingC = <Map<String, dynamic>>[];
    StreamSubscription<RealtimeEvent>? subC;
    await f.step('C opens its real-time channel (the new contact can be called)', () async {
      rtC = PollRealtimeTransport.forApi(apiC);
      subC = rtC.events.listen((e) {
        if (e.topic == 'call.incoming') incomingC.add(e.payload);
      });
      await f.net(() => rtC.connect());
      rtC.setFast(true);
    });

    for (final (kind, tip) in [('voice', f.t.circleVoiceCall), ('video', f.t.circleVideo)]) {
      await f.step('$kind call to the new contact: C answers -> connected -> media flows -> hang up',
          () async {
        final mark = f.httpMark;
        final before = incomingC.length;
        await f.tap(find.byTooltip(tip), settleSeconds: 3);
        await f.waitFor(find.byType(CircleCallScreen), what: '$kind call screen');
        f.expectHttp('GET', '/rtc/turn', since: mark);
        await f.eventually('C\'s phone gets the call', () async => incomingC.length > before,
            seconds: 20);
        final callId = (incomingC.last['call_id'] as num).toInt();
        await f.shot('$kind-call');
        await f.net(() => apiC.postJson('/circle/calls/$callId/event', {'event': 'ringing'}));
        CallController? callC;
        await f.net(() async {
          final c = CallController(
            // one emulator camera (A's): C joins with its camera blocked —
            // the app's own camera-unavailable path
            media: WebRtcCallMedia(cameraBlocked: true),
            signaling: ApiCallSignaling(apiC, rtC),
            sounds: _QuietSounds(),
            video: kind == 'video',
            outgoing: false,
            callId: callId,
          );
          callC = c;
          unawaited(c.start());
        });
        await f.eventually('C reached ICE connected',
            () async => callC!.phase == CallPhase.connected, seconds: 40);
        await f.eventually('A is live', () async => CallRuntime.instance.currentCall?.isLive == true,
            seconds: 20);
        // media, not just signalling: C's inbound audio (and on video A's
        // decoded camera frames) must grow over 6 s
        final s1 = await f.net(() => callC!.media.stats());
        await f.pumpFor(const Duration(seconds: 6));
        final s2 = await f.net(() => callC!.media.stats());
        final p1 = s1.audioPacketsIn ?? 0, p2 = s2.audioPacketsIn ?? 0;
        if (p2 <= p1) throw TestFailure('$kind: C heard nothing from A over 6 s (packets $p1->$p2)');
        var line = '$kind: C audio in +${p2 - p1} pkts';
        final a = CallRuntime.instance.currentCall!;
        if (kind == 'video') {
          if (a.media.cameraUnavailable) {
            line += '; A has no camera on this emulator (video frames not measurable)';
          } else {
            final v1 = s1.videoFramesDecoded ?? 0, v2 = s2.videoFramesDecoded ?? 0;
            if (v2 <= 0 || v2 <= v1) {
              throw TestFailure('video: C decoded no frames from A\'s camera ($v1->$v2)');
            }
            line += ', C video decoded $v1->$v2';
          }
        }
        f.note(line);
        await f.shot('$kind-connected');
        await f.tap(find.byKey(const Key('call-hangup')), settleSeconds: 3);
        await f.eventually('C saw the end', () async => callC!.isEnded, seconds: 15);
        callC?.dispose();
        await f.shot('$kind-hung-up');
        // the ended screen (talk time) closes by itself; Close if it is still up
        final close = find.byKey(const Key('call-close'));
        if (close.evaluate().isNotEmpty) await f.tap(close, settleSeconds: 2);
        await f.eventually('back in the chat', () async =>
            find.byType(CircleCallScreen).evaluate().isEmpty, seconds: 20);
      });
    }
    await subC?.cancel();
    await rtC.close();
    // owner order (17 Nov): what only two REAL phones show is the owner's
    // checklist — it does not lower the grade
    f.ownerCheck('New contact call over TURN (Wi-Fi on one phone, mobile data on the other)');
    f.ownerCheck('New contact call with Assisto CLOSED on the other phone: it rings (FCM)');
  }, timeout: const Duration(minutes: 6));
}
