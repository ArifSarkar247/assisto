// gap-recovery (board rows 52 + 58) — "my phone was lost; I sign in on a new
// phone with the EMAIL code and my My Circle chats + keys come back".
//
// Opt-in group: e2e.yml group=start+recovery (REALITY_ONLY=start,recovery)
// against the throw-away settings_e2eproof backend with E2E_FAKE_EMAIL=1:
// the server's real email-code path runs and the SMTP hop is CAPTURED into
// the CI outbox (never a real mailbox). seed_recovery verified A's made-up
// address rahim@reality.test.
//
//   old phone (A, signed in by the start group):
//     My Circle key published + sealed key backup with a PIN (what Settings
//     -> Security -> "Back up my chat keys" does); B sends A an E2E message.
//   phone lost: sign out + wipe this phone's keys, new install id (= a new
//     phone); B sends a 2nd message to the OLD key meanwhile.
//   new phone: "Sign in with an email code" -> read the code from the test
//     mailbox -> a wrong code first (honest "N tries left") -> the mailed
//     code -> signed in -> "Is your old phone lost?" (sign the others out)
//     + "Restore your chat keys" (PIN) -> SAME key id back -> both of B's
//     messages open in My Circle. Server proof: the "new sign-in" alert went
//     out by push + email.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/crypto/key_backup.dart';
import 'package:assisto/crypto/key_service.dart';
import 'package:assisto/crypto/key_wiring.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:assisto/widgets/otp_code_input.dart';

import '../support/harness.dart';

const _addr = 'rahim@reality.test'; // seed_reality / seed_recovery (made up)
const _pin = '482916'; // CI-only sample PIN
final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r, [String k = 'results']) =>
    ((r[k] ?? r['members'] ?? r['rows'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

Future<double> _now(ApiClient api) async =>
    ((await api.getJson('/ci-e2e/outbox?kind=none'))['now'] as num).toDouble();

Future<List<Map<String, dynamic>>> _outbox(ApiClient api, String kind, double since,
        {String user = ''}) async =>
    _rows(await api.getJson(
        '/ci-e2e/outbox?since=$since&kind=$kind${user.isEmpty ? '' : '&user=$user'}'), 'rows');

void registerRecoveryFlows() {
  realityFlow('rec1_lost_phone_email_code', 'Account recovery',
      'Lost phone -> new phone signs in with the EMAIL code (read from the test mailbox) -> old phones signed out -> keys restored with the PIN -> My Circle history opens',
      (f) async {
    if (!f.app.loggedIn) throw SkipFlow('A is not signed in (the start group must run first)');
    KeyWiring.instance.start(f.app); // lib/main.dart does this 3 s after start
    final e2e = SoftwareE2E();
    final idB = e2e.generateIdentity();
    final apiB = await f.h.backend(userB: true); // reads the CI outbox throughout
    final since = await f.net(() => _now(apiB));
    late String oldKeyId;
    late Map<String, dynamic> edgeB; // B's edge to A
    final text1 = 'Before the loss r$_tag';
    final text2 = 'While you were away r$_tag';

    Future<void> bSends(String text) => f.net(() async {
          final ct = e2e.encrypt(
              self: idB,
              recipientPublicKey: base64Decode('${edgeB['public_key']}'),
              plaintext: text);
          await apiB.postJson('/circle/${edgeB['id']}/messages', {
            ...ct.toEnvelopeFields(),
            'content_type': 'text',
            'client_msg_id': 'rec-${text.hashCode}'
          });
        });

    await f.step('old phone: My Circle key published + key backup sealed with a PIN', () async {
      final id = await f.net(() => IdentityVault.instance.get());
      oldKeyId = id.keyId;
      final pub = await f.net(
          () => KeyService.instance.publish(f.app.api.postJson, reason: 'rec1'));
      if (pub != true) throw TestFailure('could not publish A\'s key');
      final ok = await f.net(() => KeyBackupService.instance.backupWithPin(_pin));
      if (ok != true) throw TestFailure('key backup was not saved');
      final meta = await f.net(() => ApiClient.detached(f.app.api.token!).getJson('/e2/backup'));
      if (meta['exists'] != true) throw TestFailure('server has no key backup: $meta');
      await f.net(() => apiB.postJson('/circle/keys',
          {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme}));
      await f.eventually('B sees A\'s published key', () async {
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'), orElse: () => {});
        return edgeB.isNotEmpty && '${edgeB['public_key'] ?? ''}' == id.publicKeyB64;
      }, seconds: 20);
      await bSends(text1);
      await f.shot('old-phone-backed-up');
    });

    await f.step('phone lost: sign out + wipe this phone like a new install', () async {
      await f.net(() => f.app.logout());
      await f.net(() async {
        for (final s in [IdentityVault.slot, IdentityVault.ringSlot, KeyBackupService.secretSlot]) {
          await SecretStore.instance.delete(s);
        }
      });
      IdentityVault.instance.resetForTests();
      AppConfig.deviceId = 'reality-new-phone-$_tag'; // a new phone = a new install id
      await bSends(text2); // to the OLD key, while A has no phone
      await f.pumpFor(const Duration(seconds: 3));
      await f.waitFor(find.byKey(const Key('login-with-email-code')), seconds: 25,
          what: '"Sign in with an email code" on the login screen');
      await f.shot('new-phone-login');
    });

    String code = '';
    await f.step('new phone: email code requested -> read it from the test mailbox', () async {
      await f.tap(find.byKey(const Key('login-with-email-code')), settleSeconds: 2);
      await f.tester.enterText(find.byKey(const Key('otp-id')), _addr);
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.tap(find.byKey(const Key('otp-send')), settleSeconds: 4);
      await f.waitFor(find.byType(OtpCodeInput), seconds: 25, what: 'code boxes');
      await f.shot('code-screen');
      await f.eventually('the code mail is in the test mailbox', () async {
        final rows = await _outbox(apiB, 'email', since);
        for (final r in rows.reversed) {
          if ('${r['to']}' != _addr) continue;
          final m = RegExp(r'\b(\d{6})\b').firstMatch('${r['text']}');
          if (m != null) {
            code = m.group(1)!;
            if ((r['html_bytes'] as num? ?? 0) > 100 * 1024) {
              throw TestFailure('code email is over 100 KB');
            }
            return true;
          }
        }
        return false;
      }, seconds: 30);
      f.note('code read from the captured mail (outbox kind=email)');
    });

    await f.step('a wrong code first -> honest error with tries left', () async {
      final wrong = code == '000000' ? '111111' : '000000';
      final box = find.descendant(of: find.byType(OtpCodeInput), matching: find.byType(TextField));
      await f.tester.enterText(box.first, wrong);
      await f.pumpFor(const Duration(seconds: 4));
      final err = await f.waitFor(find.byKey(const Key('otp-error')), what: 'wrong-code error');
      final txt = f.tester.widget<Text>(err).data ?? '';
      if (txt != f.t.recovOtpInvalid('4')) throw TestFailure('wrong-code text: "$txt"');
      await f.shot('wrong-code');
    });

    await f.step('the mailed code -> signed in on the new phone', () async {
      final box = find.descendant(of: find.byType(OtpCodeInput), matching: find.byType(TextField));
      await f.tester.enterText(box.first, code);
      await f.pumpFor(const Duration(seconds: 6));
      await f.eventually('signed in as A', () async => f.app.loggedIn, seconds: 25);
      f.expectHttp('POST', '/auth/otp/verify');
      f.expectHttp('POST', '/auth/otp/login');
      await f.shot('signed-in');
    });

    var restored = false, lostSeen = false;
    await f.step('"Is your old phone lost?" + "Restore chat keys" (PIN)', () async {
      final until = DateTime.now().add(const Duration(seconds: 70));
      while (DateTime.now().isBefore(until) && !(restored && lostSeen)) {
        if (find.byKey(const Key('lost-check')).evaluate().isNotEmpty) {
          lostSeen = true;
          await f.shot('lost-phone-check');
          await f.tap(find.byKey(const Key('lost-signout-all')), settleSeconds: 4);
          continue;
        }
        if (find.byKey(const Key('e2r-pin')).evaluate().isNotEmpty) {
          await f.shot('restore-keys');
          await f.tester.enterText(find.byKey(const Key('e2r-pin')), _pin);
          await f.pumpFor(const Duration(milliseconds: 500));
          await f.tap(find.byKey(const Key('e2r-restore')), settleSeconds: 8);
          await f.eventually('restore screen closed',
              () async => find.byKey(const Key('e2r-pin')).evaluate().isEmpty, seconds: 30);
          restored = true;
          continue;
        }
        await f.pumpFor(const Duration(seconds: 2));
      }
      if (!restored) throw TestFailure('the key-restore (PIN) screen never appeared');
      if (!lostSeen) f.note('no other A session was signed in (lost-phone check not needed)');
      for (var i = 0; i < 4; i++) {
        final skip = find.text(f.t.skip).hitTestable();
        if (skip.evaluate().isEmpty) break;
        await f.tap(skip, settleSeconds: 3);
      }
    });

    await f.step('same chat key is back (no key change for B)', () async {
      final id = await f.net(() => IdentityVault.instance.get());
      if (id.keyId != oldKeyId) {
        throw TestFailure('new key ${id.keyId} != old $oldKeyId (restore failed)');
      }
    });

    await f.step('My Circle: B is there and BOTH messages open (decrypted)', () async {
      await f.home();
      await f.openRoute('circle', settleSeconds: 4);
      if (await f.appears(find.byKey(const Key('bbl2-later')), seconds: 4)) {
        await f.tap(find.byKey(const Key('bbl2-later')), settleSeconds: 2);
      }
      await f.waitFor(find.text(Seed.nameB), seconds: 20, what: 'B in My Circle');
      await f.tap(find.text(Seed.nameB), settleSeconds: 4);
      await f.waitFor(find.byType(CircleChatScreen), what: 'chat with B');
      await f.waitFor(find.text(text1), seconds: 25, what: 'message sent before the loss');
      await f.waitFor(find.text(text2), seconds: 25, what: 'message sent while away');
      await f.shot('history-back');
    });

    await f.step('server: "new sign-in" alert went out (push + email)', () async {
      await f.eventually('new sign-in mail in the test mailbox', () async {
        final rows = await _outbox(apiB, 'email', since);
        return rows.any((r) =>
            '${r['to']}' == _addr && '${r['subject']}'.contains('New sign-in'));
      }, seconds: 30);
      final push = await f.net(() => _outbox(apiB, 'push', since));
      if (!push.any((r) => '${r['data']?['reason'] ?? ''}' == 'new_signin')) {
        throw TestFailure('no new-sign-in push in the outbox');
      }
    });
  }, timeout: const Duration(minutes: 7));
}
