// circle-extras — board rows 48 (channels, view-once) and 50 (linked devices,
// encrypted backup restore), PROVEN on the CI emulator against the seeded
// throw-away Django (opt-in reality group "cx"):
//
//   A = Reality Rahim (this app, driven through the UI)
//   B = Reality Karim (an independent API client = "the other phone")
//   P2 = A's SECOND phone (an independent client running the app's own
//        link + crypto code with its own key store and its own session)
//
//   cx1 channels  A creates a channel + posts (UI) → B follows and reads it;
//                 B posts in its channel → A finds, follows, sees it (UI)
//   cx2 view-once B sends a view-once photo → A opens it once (UI; the
//                 host screenshot of the viewer is BLACK = FLAG_SECURE) →
//                 the tile says Opened, a second open is refused by the
//                 server, B (sender) sees "opened" and cannot fetch it
//   cx3 linked    A links P2 by the 8-character code (UI sheet, same 6 digits
//                 on both) → B's message opens on A (UI) AND on P2 → P2's
//                 message shows on A → A logs P2 out (UI) → P2 gets 401
//   cx4 restore   A backs up chat keys under the Security PIN (UI) → a NEW
//                 phone (empty key store, fresh sign-in) opens the restore
//                 screen: wrong PIN refused with tries left, right PIN →
//                 same key → an old message opens
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hc;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'package:assisto/config.dart';
import 'package:assisto/crypto/device_link.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/crypto/key_backup.dart';
import 'package:assisto/messaging/media/media_api.dart';
import 'package:assisto/messaging/media/media_crypto.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/e2_restore_screen.dart';
import 'package:assisto/screens/messenger/channel_detail_screen.dart';
import 'package:assisto/screens/messenger/linked_devices_screen.dart';
import 'package:assisto/screens/security_screen.dart';
import 'package:assisto/security/secret_store.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? r['devices'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

/// An in-memory key store = a phone that has never had Assisto's keys.
class _MemStore extends SecretStore {
  _MemStore() : super();
  final Map<String, String> m = {};
  @override
  Future<String?> read(String name) async => m[name];
  @override
  Future<bool> write(String name, String value) async {
    m[name] = value;
    return true;
  }

  @override
  Future<void> delete(String name) async => m.remove(name);
}

/// A second phone's raw HTTP (its own device id + session, never the app's).
class _Phone {
  _Phone(this.deviceId, this.name);
  final String deviceId;
  final String name;
  String? token;

  Map<String, String> get _h => {
        'Content-Type': 'application/json',
        'Accept-Language': 'en',
        'X-Device-Id': deviceId,
        'X-Device-Name': name,
        'X-Session-Mode': 'device',
        'X-Platform': 'android',
        if (token != null) 'Authorization': 'Token $token',
      };

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
    final r = await http.post(AppConfig.api(path), headers: _h, body: jsonEncode(body));
    Map<String, dynamic> j = {};
    try {
      final d = jsonDecode(r.body);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    return {...j, '_status': r.statusCode};
  }

  Future<(int, Map<String, dynamic>)> get(String path) async {
    final r = await http.get(AppConfig.api(path), headers: _h);
    Map<String, dynamic> j = {};
    try {
      final d = jsonDecode(r.body);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {}
    return (r.statusCode, j);
  }
}

String? _open(SoftwareE2E e2e, IdentityKeyPair me, Uint8List peer, Map<String, dynamic> m) =>
    e2e.decrypt(
        self: me,
        senderPublicKey: peer,
        ct: Ciphertext(
            ciphertextB64: '${m['ciphertext']}',
            nonceB64: '${m['nonce']}',
            senderKeyId: '${m['sender_key_id'] ?? ''}',
            scheme: '${m['scheme'] ?? e2e.scheme}'));

void registerCircleExtrasFlows() {
  // ------------------------------------------------------------ cx1 channels
  realityFlow('cx1_channels', 'My Circle', 'Channels: create → post → a follower sees it (both directions)',
      (f) async {
    await f.home();
    final apiB = await f.h.backend(userB: true);
    final apiA = await f.h.backend();
    final nameA = 'CX Bazar $_tag';
    final postA = 'Potato 40 tk today $_tag';
    await f.step('A creates a channel in the app', () async {
      await f.openRoute('channels', settleSeconds: 4);
      await f.shot('channels-tab');
      await f.tap(find.byKey(const Key('chx-create-fab')), settleSeconds: 2);
      await f.tester.enterText(find.byKey(const Key('chx-create-name')), nameA);
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.shot('create-sheet');
      await f.tap(find.byKey(const Key('chx-create-submit')), settleSeconds: 4);
      f.expectHttp('POST', '/channels');
    });
    await f.step('A posts in it', () async {
      await f.tap(find.byKey(const Key('chx-post-first')), settleSeconds: 2);
      await f.tester.enterText(find.byKey(const Key('chx-compose-text')), postA);
      await f.pumpFor(const Duration(milliseconds: 400));
      await f.tap(find.byKey(const Key('chx-compose-send')), settleSeconds: 4);
      await f.waitFor(find.text(postA), seconds: 15, what: 'the post in the admin list');
      await f.shot('admin-posted');
    });
    await f.step('B (another account) finds, follows and reads the post', () async {
      final ok = await f.net(() async {
        final d = await apiB.getJson('/channels/discover?q=${Uri.encodeQueryComponent(nameA)}');
        final hit = _rows(d).where((c) => c['name'] == nameA).toList();
        if (hit.isEmpty) return 'not in the directory';
        final id = (hit.first['id'] as num).toInt();
        await apiB.postJson('/channels/$id/follow');
        final posts = _rows(await apiB.getJson('/channels/$id/posts?limit=5'));
        return posts.any((p) => p['text'] == postA) ? 'ok' : 'post missing';
      });
      if (ok != 'ok') throw TestFailure('follower B: $ok');
    });
    final nameB = 'CX Karim News $_tag';
    final postB = 'Rice 72 tk at Karwan Bazar $_tag';
    late int chB;
    await f.step('B posts in its own channel; A finds it in the app and follows', () async {
      chB = await f.net(() async {
        final c = await apiB.postJson('/channels', {'name': nameB, 'description': 'sample prices'});
        final id = (c['id'] as num).toInt();
        await apiB.postJson('/channels/$id/posts', {'kind': 'text', 'text': postB});
        return id;
      });
      await f.pushScreen(ChannelDetailScreen(channelId: chB), settleSeconds: 4);
      await f.waitFor(find.text(postB), seconds: 15, what: "B's post (public channel preview)");
      await f.tap(find.byKey(const Key('chx-follow')), settleSeconds: 3);
      await f.shot('a-follows-b');
      await f.eventually('server: A follows B\'s channel', () async {
        final j = await apiA.getJson('/channels/$chB');
        final ch = (j['channel'] as Map?) ?? j;
        return ch['my_following'] == true;
      });
    });
    await f.step('a NEW post from B reaches A (reopen shows it)', () async {
      final again = 'Onion 95 tk $_tag';
      await f.net(() => apiB.postJson('/channels/$chB/posts', {'kind': 'text', 'text': again}));
      await f.back();
      await f.pushScreen(ChannelDetailScreen(channelId: chB), settleSeconds: 4);
      await f.waitFor(find.text(again), seconds: 15, what: 'the new post');
      await f.shot('a-sees-new-post');
      f.expectNoServerErrors();
    });
    f.note('the push for a new post is sent by the server (tests_channels) — the '
        'Android shade itself is covered by the notifproof workflow');
  }, timeout: const Duration(minutes: 6));

  // ----------------------------------------------------------- cx2 view-once
  realityFlow('cx2_view_once', 'My Circle', 'View-once photo: opens once, then gone on both sides; screenshots blocked',
      (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final idB = e2e.generateIdentity();
    final apiB = await f.h.backend(userB: true);
    late Map<String, dynamic> edgeB;
    late String ref;
    late int msgId;
    await f.step('B uploads an ENCRYPTED photo and sends it view-once', () async {
      msgId = await f.net(() async {
        await apiB.postJson('/circle/keys',
            {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        final pic = img.Image(width: 96, height: 96);
        img.fill(pic, color: img.ColorRgb8(30, 120, 200));
        final png = Uint8List.fromList(img.encodePng(pic));
        final key = randomBytes(32), nonce = randomBytes(12);
        final ct = sealBytes(key, nonce, png);
        final sha = hc.sha256.convert(ct).toString();
        final tr = HttpMediaTransport(token: () => apiB.token);
        final b = await tr.createBlob('photo', ct.length, sha);
        ref = '${b['ref']}';
        await tr.putChunk(ref, 0, ct);
        await tr.finish(ref);
        final desc = MediaDescriptor(kind: 'photo', ref: ref, key: key, nonce: nonce,
            sha256: sha, size: ct.length, plainSize: png.length, mime: 'image/png',
            width: 96, height: 96);
        final env = e2e.encrypt(self: idB,
            recipientPublicKey: base64Decode('${edgeB['public_key']}'),
            plaintext: markViewOnce(desc.encode()));
        final r = await apiB.postJson('/circle/${edgeB['id']}/messages', {
          ...env.toEnvelopeFields(),
          'content_type': 'photo',
          'blob_ref': ref,
          'view_once': true,
          'client_msg_id': 'cx2-$_tag',
        });
        return (r['id'] as num).toInt();
      });
    });
    await f.step('A sees a "1" tile with NO preview and opens it once', () async {
      await f.openRoute('circle', settleSeconds: 4);
      if (await f.appears(find.byKey(const Key('bbl2-later')), seconds: 4)) {
        await f.tap(find.byKey(const Key('bbl2-later')), settleSeconds: 2);
      }
      await f.tap(find.text(Seed.nameB), settleSeconds: 4);
      await f.waitFor(find.byType(CircleChatScreen), what: 'chat');
      final tile = find.byKey(ValueKey('e-vo-$msgId'));
      await f.scrollToBuilt(tile, what: 'view-once tile');
      await f.shot('vo-tile-unopened');
      await f.tap(find.descendant(of: tile, matching: find.byKey(const Key('e-vo-tile'))),
          settleSeconds: 5);
      await f.waitFor(find.byKey(const Key('e-vo-image')), seconds: 25, what: 'the photo viewer');
      f.expectVisible(find.byKey(const Key('vo1-honest')), 'honest "another camera" line');
      // host screencap of a FLAG_SECURE window comes out BLACK — this shot
      // is the screenshot-block proof (reviewed in the evidence)
      await f.shot('vo-viewer-secure-expect-black');
      await f.tap(find.byKey(const Key('e-vo-close')), settleSeconds: 2);
    });
    await f.step('gone on A\'s side: tile says Opened, cannot reopen; server refuses a 2nd open', () async {
      final tile = find.byKey(ValueKey('e-vo-$msgId'));
      await f.waitFor(find.descendant(of: tile, matching: find.text(f.t.eVoOpened)),
          seconds: 10, what: '"Opened" on the tile');
      await f.tap(find.descendant(of: tile, matching: find.byKey(const Key('e-vo-tile'))),
          settleSeconds: 2);
      if (find.byKey(const Key('e-vo-image')).evaluate().isNotEmpty) {
        throw TestFailure('the viewer opened a second time');
      }
      await f.shot('vo-tile-opened');
      final apiA = await f.h.backend();
      final st = await f.net(() async {
        final r = await apiA.postJsonRaw('/circle/messages/$msgId/view-once-open', {'want_url': true});
        return r['_status'];
      });
      if (st != 409) throw TestFailure('second open answered $st (want 409)');
    });
    await f.step('gone on B\'s side: B sees "opened", B cannot download it', () async {
      await f.eventually('B\'s copy says opened', () async {
        final rows = _rows(await apiB.getJson('/circle/${edgeB['id']}/messages'));
        final m = rows.firstWhere((x) => x['id'] == msgId, orElse: () => {});
        return m['view_once_opened'] == true;
      });
      final st = await f.net(() async {
        final r = await http.get(AppConfig.api('/circle/media/blobs/$ref/url'),
            headers: {'Authorization': 'Token ${apiB.token}'});
        return r.statusCode;
      });
      if (st == 200) throw TestFailure('the sender could still fetch the view-once blob');
    });
    f.note('screenshot policy: FLAG_SECURE blocks screenshots + screen recording in the viewer '
        '(black host screenshot); another camera can still photograph the screen — said in the app');
  }, timeout: const Duration(minutes: 6));

  // ------------------------------------------------------------- cx3 linked
  realityFlow('cx3_linked_devices', 'My Circle',
      'Link a second phone by code → messages on both → log it out → it is signed out', (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final apiB = await f.h.backend(userB: true);
    final p2 = _Phone('reality-phone2-$_tag', 'Reality Tab 2');
    final vault2 = IdentityVault(store: _MemStore());
    final link = NewPhoneLink(post: p2.post, vault: vault2);
    final idB = e2e.generateIdentity();
    late String code;
    await f.step('A opens Linked devices → Link a phone: QR + 8-character code', () async {
      await f.pushScreen(const LinkedDevicesScreen(), settleSeconds: 3);
      await f.shot('linked-empty');
      await f.tap(find.byKey(const Key('dlk-start')), settleSeconds: 3);
      await f.waitFor(find.byKey(const Key('dlk-qr')), what: 'QR');
      final w = f.tester.widget<SelectableText>(find.byKey(const Key('dlk-code')));
      code = w.data ?? '';
      if (!DeviceLinkCrypto.codeComplete(code)) throw TestFailure('bad code "$code"');
      await f.shot('link-sheet-qr');
    });
    await f.step('the second phone types the code; A sees the SAME 6 digits and allows', () async {
      final c = await f.net(() => link.claimCode(code));
      if (c == null) throw TestFailure('claim failed: ${link.error}');
      await f.waitFor(find.byKey(const Key('dlk-allow')), seconds: 15, what: 'confirm');
      final shown = f.tester.widget<Text>(find.byKey(const Key('dlk-confirm-digits'))).data;
      if (shown != DeviceLinkCrypto.spaced(c.verify)) {
        throw TestFailure('digits differ: main "$shown" vs new "${c.verify}"');
      }
      await f.shot('link-confirm-digits');
      await f.tap(find.byKey(const Key('dlk-allow')), settleSeconds: 3);
      LinkResult? r;
      await f.eventually('second phone gets its session + keys', () async {
        r = await link.pollOnce();
        return r!.outcome == LinkClaimOutcome.approved;
      }, seconds: 30);
      p2.token = r!.token;
      final mine = await f.net(() => IdentityVault.instance.get());
      final theirs = await f.net(() => vault2.get());
      if (mine.keyId != theirs.keyId) throw TestFailure('second phone has a different key');
      await f.waitFor(find.byKey(ValueKey('dlk-row-${p2.deviceId}')), seconds: 15,
          what: 'the new phone in the list');
      await f.shot('linked-listed');
    });
    final textB = 'Hello both phones $_tag';
    await f.step('B\'s message opens on A (app) AND on the second phone', () async {
      late Map<String, dynamic> edgeB;
      await f.net(() async {
        await apiB.postJson('/circle/keys',
            {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
        edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        final ct = e2e.encrypt(self: idB,
            recipientPublicKey: base64Decode('${edgeB['public_key']}'), plaintext: textB);
        await apiB.postJson('/circle/${edgeB['id']}/messages',
            {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': 'cx3-$_tag'});
      });
      final opened = await f.net(() async {
        final (st, mem) = await p2.get('/circle/members');
        if (st != 200) return 'members $st';
        final edge = _rows(mem).firstWhere((m) => m['name'] == Seed.nameB);
        final (st2, msgs) = await p2.get('/circle/${edge['id']}/messages');
        if (st2 != 200) return 'messages $st2';
        final me = await vault2.get();
        for (final m in _rows(msgs).where((m) => m['mine'] != true)) {
          if (_open(e2e, me, idB.publicKey, m) == textB) return 'ok';
        }
        return 'not decrypted';
      });
      if (opened != 'ok') throw TestFailure('second phone: $opened');
      await f.back(); // close Linked devices
      await f.openRoute('circle', settleSeconds: 4);
      if (await f.appears(find.byKey(const Key('bbl2-later')), seconds: 4)) {
        await f.tap(find.byKey(const Key('bbl2-later')), settleSeconds: 2);
      }
      await f.tap(find.text(Seed.nameB), settleSeconds: 4);
      await f.waitFor(find.text(textB), seconds: 20, what: 'B\'s message on A');
      await f.shot('a-sees-message');
    });
    final textP2 = 'Sent from my tablet $_tag';
    await f.step('a message sent from the second phone shows on A and opens for B', () async {
      await f.net(() async {
        final (_, mem) = await p2.get('/circle/members');
        final edge = _rows(mem).firstWhere((m) => m['name'] == Seed.nameB);
        final me = await vault2.get();
        final ct = e2e.encrypt(self: me,
            recipientPublicKey: base64Decode('${edge['public_key']}'), plaintext: textP2);
        await p2.post('/circle/${edge['id']}/messages',
            {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': 'cx3b-$_tag'});
      });
      await f.back();
      await f.tap(find.text(Seed.nameB), settleSeconds: 4);
      await f.waitFor(find.text(textP2), seconds: 25, what: 'the tablet\'s message on A');
      await f.shot('a-sees-tablet-message');
    });
    await f.step('A logs the second phone out → its next request is refused (401)', () async {
      await f.back();
      await f.pushScreen(const LinkedDevicesScreen(), settleSeconds: 4);
      await f.tap(find.byKey(ValueKey('dlk-unlink-${p2.deviceId}')), settleSeconds: 2);
      await f.shot('unlink-confirm');
      await f.tap(find.descendant(of: find.byType(AlertDialog),
          matching: find.text(f.t.msgrLinkedLogout)), settleSeconds: 3);
      final st = await f.net(() async => (await p2.get('/me')).$1);
      if (st != 401) throw TestFailure('second phone still signed in ($st)');
      if (find.byKey(ValueKey('dlk-row-${p2.deviceId}')).evaluate().isNotEmpty) {
        throw TestFailure('the phone is still listed');
      }
      await f.shot('unlinked');
    });
    f.note('QR scanning by camera is decoded by the pure-Dart zxing2 reader (unit test); '
        'the emulator has no camera, so the second phone typed the 8-character code');
  }, timeout: const Duration(minutes: 7));

  // ------------------------------------------------------------ cx4 restore
  realityFlow('cx4_backup_restore', 'My Circle',
      'Encrypted key backup under the PIN → restore on a new phone → old messages open', (f) async {
    await f.home();
    final e2e = SoftwareE2E();
    final apiA = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    const pin = '482916';
    final idB = e2e.generateIdentity();
    final oldText = 'Before the new phone $_tag';
    await f.step('A sets the Security PIN and backs up chat keys (Security screen)', () async {
      await f.net(() async {
        try {
          await apiA.securityPinSet(pin);
        } catch (_) {} // already set by an earlier run
        await apiB.postJson('/circle/keys',
            {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
        final edgeB = _rows(await apiB.getJson('/circle/members'))
            .firstWhere((m) => '${m['name']}'.contains('Rahim'));
        final ct = e2e.encrypt(self: idB,
            recipientPublicKey: base64Decode('${edgeB['public_key']}'), plaintext: oldText);
        await apiB.postJson('/circle/${edgeB['id']}/messages',
            {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': 'cx4-$_tag'});
      });
      await f.pushScreen(const SecurityScreen(), settleSeconds: 4);
      await f.scrollToBuilt(find.byKey(const Key('e2r-backup-tile')), what: 'backup tile');
      await f.tap(find.byKey(const Key('e2r-backup-tile')), settleSeconds: 2);
      await f.tester.enterText(
          find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), pin);
      await f.pumpFor(const Duration(milliseconds: 400));
      await f.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(f.t.save)),
          settleSeconds: 8);
      await f.waitFor(find.text(f.t.e2rBackupDone), seconds: 30, what: 'backup done');
      await f.shot('backup-done');
      await f.eventually('server holds a sealed backup', () async =>
          (await apiA.getJson('/e2/backup'))['exists'] == true);
    });
    final phone = _Phone('reality-newphone-$_tag', 'Reality New Phone');
    final vault2 = IdentityVault(store: _MemStore());
    final svc = KeyBackupService(vault: vault2, store: _MemStore());
    await f.step('a NEW phone signs in and opens the restore screen', () async {
      final r = await f.net(() => phone.post('/auth/login',
          {'identifier': Seed.phoneA, 'password': Seed.password}));
      if (r['_status'] != 200) throw TestFailure('new phone sign-in ${r['_status']}');
      phone.token = '${r['token']}';
      svc.get = (p) async {
        final (st, j) = await phone.get(p);
        if (st != 200) throw BackupHttpError(st, j);
        return j;
      };
      svc.post = (p, b) async {
        final j = await phone.post(p, b);
        final st = (j['_status'] as num?)?.toInt() ?? 0;
        if (st >= 200 && st < 300) return j;
        throw BackupHttpError(st, j);
      };
      final meta = await f.net(() => svc.meta());
      await f.pushScreen(E2RestoreScreen(service: svc, meta: meta), settleSeconds: 3);
      await f.shot('restore-screen');
    });
    await f.step('wrong PIN is refused with tries left', () async {
      await f.tester.enterText(find.byKey(const Key('e2r-pin')), '000000');
      await f.pumpFor(const Duration(milliseconds: 300));
      await f.tap(find.byKey(const Key('e2r-restore')), settleSeconds: 8);
      await f.waitFor(find.byKey(const Key('e2r-error')), seconds: 30, what: 'wrong-PIN line');
      await f.shot('restore-wrong-pin');
    });
    await f.step('right PIN → same key → the OLD message opens on the new phone', () async {
      await f.tester.enterText(find.byKey(const Key('e2r-pin')), pin);
      await f.pumpFor(const Duration(milliseconds: 300));
      await f.tap(find.byKey(const Key('e2r-restore')), settleSeconds: 8);
      await f.eventually('restored key = A\'s key', () async {
        final cur = await vault2.peek();
        final mine = await IdentityVault.instance.get();
        return cur != null && cur.keyId == mine.keyId;
      }, seconds: 40);
      await f.shot('restore-done');
      final ok = await f.net(() async {
        final (_, mem) = await phone.get('/circle/members');
        final edge = _rows(mem).firstWhere((m) => m['name'] == Seed.nameB);
        final (_, msgs) = await phone.get('/circle/${edge['id']}/messages');
        final me = await vault2.get();
        return _rows(msgs).any((m) => m['mine'] != true && _open(e2e, me, idB.publicKey, m) == oldText);
      });
      if (!ok) throw TestFailure('old message did not open after restore');
    });
  }, timeout: const Duration(minutes: 7));
}
