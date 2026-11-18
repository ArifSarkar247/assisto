// circle-extras (row 50) — link a second phone by QR / code: the crypto
// (seal the key ring to the new phone's one-time key), both halves of the
// protocol against a fake server, the shared 6-digit check (mirrors the
// backend vector), the pure-Dart QR decoder, and the main-phone sheet.
import 'dart:convert';
import 'dart:typed_data';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/device_link.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/messenger/link_phone_sheet.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:assisto/widgets/qr_scan_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zxing2/qrcode.dart';

class _Mem extends SecretStore {
  _Mem() : super();
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

/// The server half (backend/core/device_link.py) in memory: it only relays.
class _FakeServer {
  Map<String, dynamic>? claimRow;
  Map<String, dynamic>? sealed;
  String state = 'waiting';
  final calls = <String>[];

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
    calls.add(path);
    switch (path) {
      case '/e2/link/claim':
        if (body['code'] != 'ABCD-EFGH') {
          return {'_status': 400, 'reason': 'unknown', 'detail': 'This code did not match.'};
        }
        claimRow = {'eph_pub': body['eph_pub'], 'name': 'Pixel 7'};
        state = 'claimed';
        return {'_status': 200, 'pair': 7, 'poll': 'secret', 'verify': '000000'};
      case '/e2/link/poll':
        if (body['poll'] != 'secret') return {'_status': 404, 'state': 'gone'};
        if (state == 'approved') {
          return {
            '_status': 200,
            'state': 'approved',
            'token': 'session-key',
            'user': {'id': 1, 'name': 'Sample Rahim'},
            'sealed': sealed,
          };
        }
        if (state == 'rejected') return {'_status': 200, 'state': 'rejected'};
        return {'_status': 200, 'state': 'waiting'};
    }
    return {'_status': 404};
  }

  Future<Map<String, dynamic>> get(String path) async =>
      {'state': state, 'pair': 7, ...?claimRow};

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    calls.add(path);
    if (path == '/e2/link/approve') {
      if (body['reject'] == true) {
        state = 'rejected';
      } else {
        sealed = (body['sealed'] as Map).cast<String, dynamic>();
        state = 'approved';
      }
    }
    return {'ok': true};
  }
}

void main() {
  group('crypto', () {
    test('6 digits match the backend vector (computed on each phone)', () {
      final pub = base64Encode(Uint8List.fromList(List.generate(32, (i) => i)));
      expect(DeviceLinkCrypto.verifyDigits(pub), '361262'); // tests_device_link.py
      expect(DeviceLinkCrypto.spaced('361262'), '361 262');
    });

    test('sealed ring opens only with the new phone\'s one-time key', () {
      final e2e = SoftwareE2E();
      final ring = [e2e.generateIdentity(), e2e.generateIdentity()];
      final newPhone = e2e.generateIdentity();
      final stranger = e2e.generateIdentity();
      final sealed = DeviceLinkCrypto.seal(ring, newPhone.publicKey);
      expect(sealed['ct']!.contains(ring.first.keyId), isFalse);
      final opened = DeviceLinkCrypto.open(sealed, newPhone)!;
      expect(opened.$1.keyId, ring.first.keyId);
      expect(opened.$1.privateKey, ring.first.privateKey);
      expect(opened.$2.map((k) => k.keyId), ring.map((k) => k.keyId));
      expect(DeviceLinkCrypto.open(sealed, stranger), isNull);
      final ct = base64Decode(sealed['ct']!);
      ct[3] ^= 1;
      expect(DeviceLinkCrypto.open({...sealed, 'ct': base64Encode(ct)}, newPhone), isNull);
    });

    test('code / QR normalising', () {
      expect(DeviceLinkCrypto.normalise(' abcd efgh '), 'ABCD-EFGH');
      expect(DeviceLinkCrypto.normalise('ABCDEFGH'), 'ABCD-EFGH');
      expect(DeviceLinkCrypto.normalise('assisto-link:1:tok'), 'assisto-link:1:tok');
      expect(DeviceLinkCrypto.codeComplete('ABCD-EF'), isFalse);
      expect(DeviceLinkCrypto.codeComplete('abcd-efgh'), isTrue);
      expect(DeviceLinkCrypto.isOurQr('WIFI:S:x;;'), isFalse);
    });
  });

  group('protocol', () {
    late IdentityVault mainVault;
    late IdentityVault newVault;
    setUp(() {
      mainVault = IdentityVault(store: _Mem());
      newVault = IdentityVault(store: _Mem());
    });

    test('link: new phone ends with the main phone\'s CURRENT key + ring', () async {
      final mainKey = await mainVault.get();
      final ownOld = await newVault.get(); // the new phone already had a key
      final srv = _FakeServer();
      final np = NewPhoneLink(post: srv.post, vault: newVault);
      expect(await np.claimCode('abcd efgh'), isNotNull);
      // verify digits are the new phone's own computation, not the server's
      expect(np.claim!.verify, DeviceLinkCrypto.verifyDigits(np.mine.publicKeyB64));
      expect((await np.pollOnce()).outcome, LinkClaimOutcome.waiting);
      final mp = MainPhoneLink(get: srv.get, postJson: srv.postJson, vault: mainVault);
      final st = await mp.status();
      expect(MainPhoneLink.verifyOf(st), np.claim!.verify); // same 6 digits
      expect(await mp.approve(7, st), isTrue);
      final r = await np.pollOnce();
      expect(r.outcome, LinkClaimOutcome.approved);
      expect(r.token, 'session-key');
      expect((await newVault.get()).keyId, mainKey.keyId);
      final ring = await newVault.ring();
      expect(ring.first.keyId, mainKey.keyId);
      expect(ring.map((k) => k.keyId), contains(ownOld.keyId)); // old chats still open
      // a message sealed to the account key now opens on BOTH phones
      final friend = SoftwareE2E().generateIdentity();
      final ct = SoftwareE2E().encrypt(
          self: friend, recipientPublicKey: mainKey.publicKey, plaintext: 'hi both');
      for (final v in [mainVault, newVault]) {
        final me = await v.get();
        expect(SoftwareE2E().decrypt(self: me, senderPublicKey: friend.publicKey, ct: ct),
            'hi both');
      }
    });

    test('wrong code: the server\'s own line, no claim', () async {
      final np = NewPhoneLink(post: _FakeServer().post, vault: newVault);
      expect(await np.claimCode('ZZZZ-ZZZZ'), isNull);
      expect(np.error, contains('did not match'));
    });

    test('rejected on the main phone', () async {
      await mainVault.get();
      final srv = _FakeServer();
      final np = NewPhoneLink(post: srv.post, vault: newVault);
      await np.claimCode('ABCD-EFGH');
      await MainPhoneLink(get: srv.get, postJson: srv.postJson, vault: mainVault).reject(7);
      expect((await np.pollOnce()).outcome, LinkClaimOutcome.rejected);
      expect(await newVault.peek(), isNull);
    });

    test('a ring sealed to another key is refused (nothing adopted)', () async {
      final srv = _FakeServer();
      final np = NewPhoneLink(post: srv.post, vault: newVault);
      await np.claimCode('ABCD-EFGH');
      srv.sealed = DeviceLinkCrypto.seal([SoftwareE2E().generateIdentity()],
          SoftwareE2E().generateIdentity().publicKey);
      srv.state = 'approved';
      expect((await np.pollOnce()).outcome, LinkClaimOutcome.failed);
      expect(await newVault.peek(), isNull);
    });
  });

  test('pure-Dart QR decoder reads a camera-like Y plane (row stride padding)', () {
    const text = 'assisto-link:1:Zq3_sample-token-0123456789ab';
    final qr = Encoder.encode(text, ErrorCorrectionLevel.m);
    final m = qr.matrix!;
    const scale = 6, quiet = 4 * 6, pad = 16;
    final w = m.width * scale + quiet * 2;
    final stride = w + pad;
    final bytes = Uint8List(stride * w)..fillRange(0, stride * w, 235);
    for (var y = 0; y < m.height; y++) {
      for (var x = 0; x < m.width; x++) {
        if (m.get(x, y) != 1) continue;
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            bytes[(quiet + y * scale + dy) * stride + quiet + x * scale + dx] = 20;
          }
        }
      }
    }
    expect(decodeQrFrame(YFrame(bytes, w, w, stride)), text);
    expect(decodeQrFrame(YFrame(Uint8List(stride * w), w, w, stride)), isNull);
  });

  testWidgets('main-phone sheet: QR + code → "Link Pixel 7?" with digits → approve', (tester) async {
    final newPhone = SoftwareE2E().generateIdentity();
    final seen = <String>[];
    var claimed = false;
    Map<String, dynamic>? approved;
    final mock = MockClient((req) async {
      seen.add('${req.method} ${req.url.path}');
      Map<String, dynamic> j = {};
      if (req.url.path.endsWith('/e2/link/start')) {
        j = {'qr': 'assisto-link:1:tok', 'code': 'ABCD-EFGH', 'ttl_sec': 120};
      } else if (req.url.path.endsWith('/e2/link/status')) {
        j = claimed
            ? {'state': 'claimed', 'pair': 5, 'name': 'Pixel 7', 'eph_pub': newPhone.publicKeyB64}
            : {'state': 'waiting', 'pair': 5};
      } else if (req.url.path.endsWith('/e2/link/approve')) {
        approved = jsonDecode(req.body) as Map<String, dynamic>;
        j = {'ok': true};
      }
      return http.Response(jsonEncode(j), 200, headers: {'content-type': 'application/json'});
    });
    await http.runWithClient(() async {
      final api = ApiClient(token: 't');
      String? popped = 'unset';
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (ctx) {
          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await showModalBottomSheet<String>(
                      context: ctx,
                      isScrollControlled: true,
                      builder: (_) => LinkPhoneSheet(
                          api: api,
                          vault: IdentityVault(store: _Mem()),
                          pollEvery: const Duration(milliseconds: 200)));
                },
                child: const Text('open'),
              ),
            ),
          );
        }),
      ));
      await tester.tap(find.text('open'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('dlk-qr')), findsOneWidget);
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      claimed = true;
      for (var i = 0; i < 6 && find.byKey(const Key('dlk-allow')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.text('Link Pixel 7?'), findsOneWidget);
      final digits = DeviceLinkCrypto.spaced(DeviceLinkCrypto.verifyDigits(newPhone.publicKeyB64));
      expect(find.text(digits), findsOneWidget);
      await tester.tap(find.byKey(const Key('dlk-allow')));
      for (var i = 0; i < 6 && approved == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(approved, isNotNull);
      expect(approved!['pair'], 5);
      // the relayed ring opens with the new phone's key
      final opened = DeviceLinkCrypto.open(
          (approved!['sealed'] as Map).cast<String, dynamic>(), newPhone);
      expect(opened, isNotNull);
      expect(popped, 'Pixel 7');
    }, () => mock);
    expect(seen.where((s) => s.endsWith('/e2/link/start')), hasLength(1));
  });
}
