// offline1st — owner order 10 Nov 00:55: "without internet he cannot get in
// or see My Circle chats". The OFFLINE proof, two accounts, REAL airplane mode:
//
//   online : B sends A a message; A reads the chat and sends one (saved copy)
//   OFF    : airplane mode (host-side adb, see tools/reality/run_flows.sh)
//            -> the app is closed and opened again with NO network
//            -> Home is usable, the Offline strip shows, signed in
//            -> My Circle list + the chat history open from the phone
//            -> two messages written: queued with the clock
//   ON     : airplane mode off -> both delivered to B, in order, E2E
//
//   A = Reality Rahim (this app, driven through the UI)
//   B = Reality Karim (an independent API client = the second phone)
//
// Runs in .github/workflows/e2e.yml (REALITY_ONLY=e2e nightly, or
// REALITY_ONLY=offline for this flow alone) against the throw-away Django;
// test accounts only — never the live server.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/key_wiring.dart';
import 'package:assisto/messaging/outbox.dart';
import 'package:assisto/screens/circle_chat_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      return false;
    });

/// Can this phone open a TCP connection to the test backend right now?
Future<bool> _reachable() async {
  final u = Uri.parse(AppConfig.apiBase);
  try {
    final s = await Socket.connect(u.host, u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80),
        timeout: const Duration(seconds: 2));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Ask the CI host to switch airplane mode (adb) and wait for its ack.
Future<void> _airplane(RFlow f, bool on) async {
  final file = 'net_${on ? 'off' : 'on'}_$_tag';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_NET ${on ? 'off' : 'on'} $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) break;
  }
  // the network state itself is the proof, not the ack
  await f.eventually(on ? 'the backend is UNREACHABLE (airplane mode on)' : 'the backend is reachable again',
      () async => (await _reachable()) != on,
      seconds: on ? 30 : 90);
}

Future<void> _openChatWithB(RFlow f) async {
  await f.openRoute('circle');
  if (await f.appears(find.text(f.t.bbl2Title), seconds: 4)) {
    await f.tap(find.text('Later').hitTestable().last, settleSeconds: 2);
  }
  await f.waitFor(find.text(Seed.nameB), seconds: 20, what: 'B in the My Circle list');
  await f.tap(find.text(Seed.nameB).first, settleSeconds: 3);
  await f.waitFor(find.byType(CircleChatScreen), what: 'chat with B');
}

void registerOfflineFirstFlows() {
  realityFlow('e2e9_offline_first', 'E2E proof',
      'Offline first: airplane mode -> open app -> Home + My Circle chat history from the phone -> message queued (clock) -> online -> delivered to B in order (two accounts)',
      (f) async {
    if (const String.fromEnvironment('REALITY_SHOT_MODE') == 'inapp') {
      f.skip('real phones (Test Lab): no host adb to switch airplane mode');
    }
    if (!f.app.loggedIn) {
      await f.step('A signs in (test account)', () async {
        await f.net(() => f.app.login(identifier: Seed.phoneA, password: Seed.password));
        await f.pumpFor(const Duration(seconds: 3));
      });
    }
    await f.home();
    // what lib/main.dart's deferred init does (the harness pumps the app
    // directly): the outbox driver + key wiring for this session
    KeyWiring.instance.start(f.app);

    final e2e = SoftwareE2E();
    final idB = e2e.generateIdentity();
    final ApiClient apiB = await f.h.backend(userB: true);
    late Map<String, dynamic> edgeB; // B's edge to A (A's public key)
    final fromB = 'Offline proof from B $_tag';
    final q1 = 'Queued offline one $_tag';
    final q2 = 'Queued offline two $_tag';

    await f.step('online: B publishes a key and sends A a message', () async {
      await f.net(() async {
        await apiB.postJson('/circle/keys',
            {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      });
      // A's current key, as B's phone sees it
      await f.eventually('A has a published key', () async {
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        return '${edgeB['public_key'] ?? ''}'.isNotEmpty;
      });
      await f.net(() async {
        final ct = e2e.encrypt(
            self: idB,
            recipientPublicKey: base64Decode('${edgeB['public_key']}'),
            plaintext: fromB);
        await apiB.postJson('/circle/${edgeB['id']}/messages', {
          'content_type': 'text',
          'client_msg_id': 'b-offline-$_tag',
          ...ct.toEnvelopeFields(),
        });
      });
    });

    await f.step('online: A reads the chat (the phone keeps an encrypted copy)', () async {
      await _openChatWithB(f);
      await f.waitFor(_sees(fromB), seconds: 30, what: "B's message decrypted");
      await f.pumpFor(const Duration(seconds: 3)); // the copy is written
      await f.shot('online-chat');
    });

    await f.step('airplane mode ON (real network off)', () async {
      await _airplane(f, true);
    });

    await f.step('open the app with NO internet -> signed in, Home usable, Offline strip', () async {
      final t0 = DateTime.now();
      await f.h.boot(f.tester, settleSeconds: 0);
      await f.home();
      final ms = DateTime.now().difference(t0).inMilliseconds;
      f.note('offline cold open -> Home: $ms ms');
      if (!f.app.loggedIn) throw TestFailure('offline open showed the login screen');
      KeyWiring.instance.start(f.app);
      await f.waitFor(find.byKey(const Key('offline-strip')), seconds: 20, what: 'Offline strip');
      await f.shot('offline-home');
    });

    await f.step('offline: My Circle list + chat history open from the phone', () async {
      final t0 = DateTime.now();
      await _openChatWithB(f);
      await f.waitFor(_sees(fromB), seconds: 10, what: 'chat history offline');
      f.note('offline My Circle -> history: ${DateTime.now().difference(t0).inMilliseconds} ms');
      await f.shot('offline-chat-history');
    });

    await f.step('offline: two messages written -> queued with the clock', () async {
      for (final m in [q1, q2]) {
        await f.enter(m, label: f.t.circleMessageHint);
        // the "sends when online" snackbar covers the input bar for ~4 s
        await f.tapSend(settleSeconds: 6);
      }
      await f.waitFor(find.byKey(const ValueKey('tick-pending')), seconds: 10, what: 'clock icon');
      final q = await f.net(() => Outbox.instance.all());
      final texts = q.map((i) => i.text).toList();
      if (!texts.contains(q1) || !texts.contains(q2)) {
        throw TestFailure('not queued on the phone: $texts');
      }
      await f.shot('offline-queued');
    });

    await f.step('airplane mode OFF -> both delivered to B, in order, E2E', () async {
      await _airplane(f, false);
      await f.eventually('B decrypts both, in the order written', () async {
        final edge = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        final peer = base64Decode('${edge['public_key']}');
        final got = <String>[];
        final msgs = _rows(await apiB.getJson('/circle/${edge['id']}/messages?limit=50'))
            .where((m) => m['mine'] != true)
            .toList()
          ..sort((a, b) => (a['id'] as num).compareTo(b['id'] as num));
        for (final m in msgs) {
          final pt = e2e.decrypt(
              self: idB,
              senderPublicKey: peer,
              ct: Ciphertext(
                  ciphertextB64: '${m['ciphertext']}',
                  nonceB64: '${m['nonce']}',
                  senderKeyId: '${m['sender_key_id'] ?? ''}',
                  scheme: '${m['scheme'] ?? e2e.scheme}'));
          if (pt == q1 || pt == q2) got.add(pt!);
        }
        if (got.length > 2) throw TestFailure('duplicate delivery: $got');
        return got.length == 2 && got.first == q1;
      }, seconds: 120);
      await f.eventually('the outbox on the phone is empty',
          () async => (await Outbox.instance.all()).isEmpty, seconds: 30);
      // the strip leaves by itself once the server answers again
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (find.byKey(const Key('offline-strip')).evaluate().isNotEmpty &&
          DateTime.now().isBefore(end)) {
        await f.pumpFor(const Duration(milliseconds: 500));
      }
      if (find.byKey(const Key('offline-strip')).evaluate().isNotEmpty) {
        throw TestFailure('Offline strip still shown after reconnect');
      }
      await f.pumpFor(const Duration(seconds: 3));
      await f.shot('online-delivered');
    });
  }, timeout: const Duration(minutes: 9));
}
