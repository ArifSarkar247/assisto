// p3docs — Documents vault end-to-end layer: key wraps (PIN / fingerprint /
// recovery code / trusted person), sealed documents, share-link sealing, and
// the End-to-end lock screen in bn + en. Proves nothing secret leaves the
// phone in clear and that losing every wrap really means "cannot open".
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/vault/vault_e2e.dart';
import 'package:assisto/vault/vault_e2e_screen.dart';
import 'package:assisto/vault/vault_lock.dart';
import 'package:assisto/vault/vault_share_sheet.dart' show sniffMime;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'p3docs_fakes.dart';

const pin = '482173';
const secretTitle = 'PASSPORT A01234567 RAHIM';

VaultE2E _ring([MemoryKv? kv]) =>
    VaultE2E(kv: kv ?? MemoryKv(), pinIters: 1000, codeIters: 1000, rng: Random(7));

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

Map<String, dynamic> _wrapJson(String w) =>
    jsonDecode(utf8.decode(base64Decode(w))) as Map<String, dynamic>;

Widget _app(Widget home, {String lang = 'en'}) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );

void main() {
  group('key wraps', () {
    test('real stretch counts meet the server rule (>= 100000)', () {
      final k = VaultE2E(kv: MemoryKv());
      expect(k.pinIters, greaterThanOrEqualTo(100000));
      expect(k.codeIters, greaterThanOrEqualTo(100000));
    });

    test('PIN wrap opens only with the right PIN; key never stored in clear', () async {
      final kv = MemoryKv();
      final k = _ring(kv);
      final r = await k.setUp(pin);
      final dmk = Uint8List.fromList(k.dmkForTests!);
      k.lock();
      expect(k.unlocked, isFalse);
      expect(await k.unlockWithPin('000000'), isFalse);
      expect(await k.unlockWithPin(pin), isTrue);
      expect(k.dmkForTests, dmk);
      // nothing in the phone store holds the raw key or the PIN
      final all = utf8.encode(kv.values.values.join('|'));
      expect(_contains(all, utf8.encode(pin)), isFalse);
      expect(kv.values.values.any((v) => v.contains(base64Encode(dmk))), isFalse);
      expect(r.code, matches(RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$')));
    });

    test('recovery wrap has the server shape and opens on a NEW phone with the code only', () async {
      final k = _ring();
      final r = await k.setUp(pin);
      final dmk = Uint8List.fromList(k.dmkForTests!);
      final j = _wrapJson(r.recoveryWrap);
      expect(j.keys.toSet(), {'v', 'alg', 'salt', 'iters', 'nonce', 'ct'});
      expect(j['alg'], 'pbkdf2-c20p');
      expect(base64Decode(j['ct'] as String).length, 48); // key + tag, never the bare key
      expect(r.recoveryWrap.contains(r.code), isFalse);
      final fresh = _ring(); // reinstalled phone: empty store
      expect(await fresh.openRecovery(r.recoveryWrap, 'AAAA-BBBB-CCCC-DDDD'), isNull);
      final got = await fresh.openRecovery(r.recoveryWrap, r.code.toLowerCase());
      expect(got, dmk);
      await fresh.adopt(got!, '1111');
      fresh.lock();
      expect(await fresh.unlockWithPin('1111'), isTrue);
    });

    test('offline: the same code opens the local copy after a PIN reset', () async {
      final kv = MemoryKv();
      final k = _ring(kv);
      final r = await k.setUp(pin);
      final dmk = Uint8List.fromList(k.dmkForTests!);
      k.lock();
      expect(await k.unlockWithLocalRecovery('WRONG-CODE'), isFalse);
      expect(await k.unlockWithLocalRecovery(r.code), isTrue);
      expect(k.dmkForTests, dmk);
      expect(await k.rewrapPin('9999'), isTrue);
      k.lock();
      expect(await k.unlockWithPin('9999'), isTrue);
      expect(await k.unlockWithPin(pin), isFalse);
    });

    test('fingerprint wrap opens without the PIN and can be removed', () async {
      final k = _ring();
      await k.setUp(pin, bio: true);
      final dmk = Uint8List.fromList(k.dmkForTests!);
      k.lock();
      expect(await k.unlockWithBio(), isTrue);
      expect(k.dmkForTests, dmk);
      await k.enableBio(false);
      k.lock();
      expect(await k.unlockWithBio(), isFalse);
    });

    test('trusted person: only their key opens it; handback reaches only my new key', () async {
      final k = _ring();
      await k.setUp(pin);
      final dmk = Uint8List.fromList(k.dmkForTests!);
      final helper = SoftwareE2E(Random(1)).generateIdentity();
      final stranger = SoftwareE2E(Random(2)).generateIdentity();
      final wrap = k.sealForHelper(helper.publicKey, kid: helper.keyId);
      final j = _wrapJson(wrap);
      expect(j['alg'], 'x25519-c20p');
      expect(base64Decode(j['ct'] as String).length, 48);
      expect(VaultE2E.openFromPublicKey(wrap, stranger), isNull);
      final opened = VaultE2E.openFromPublicKey(wrap, helper)!;
      expect(opened, dmk);
      final myNewPhone = SoftwareE2E(Random(3)).generateIdentity();
      final handback = VaultE2E.sealToPublicKey(opened, myNewPhone.publicKey);
      expect(VaultE2E.openFromPublicKey(handback, helper), isNull);
      expect(VaultE2E.openFromPublicKey(handback, myNewPhone), dmk);
    });

    test('everything lost = the documents cannot be opened (by design)', () async {
      final k = _ring();
      await k.setUp(pin);
      final sealed = await k.sealDocument({'title': secretTitle});
      final other = _ring(); // new phone, no PIN wrap, no code, no helper
      expect(other.openDocBox(sealed.box), isNull);
      expect(await other.unlockWithPin(pin), isFalse);
      expect(await other.unlockWithBio(), isFalse);
      // even a different random key can't open it
      expect(VaultE2E.openBox(Uint8List(32), sealed.box), isNull);
    });

    test('match code is 8 digits and stable', () {
      final pub = SoftwareE2E(Random(4)).generateIdentity().publicKey;
      final c = VaultE2E.matchCode(pub);
      expect(c, matches(RegExp(r'^\d{4} \d{4}$')));
      expect(VaultE2E.matchCode(pub), c);
    });
  });

  group('sealed documents', () {
    test('server-bound bytes are ciphertext only; the phone opens them', () async {
      final k = _ring();
      await k.setUp(pin);
      final photo = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, ...utf8.encode('JFIF $secretTitle'), ...List.filled(300000, 7)]);
      final s = await k.sealDocument({'title': secretTitle, 'note': 'n', 'details': {'number': 'A01234567'}},
          file: photo, mime: sniffMime(photo));
      final box = base64Decode(s.box);
      expect(String.fromCharCodes(box.sublist(0, 4)), 'AVB1');
      expect(String.fromCharCodes(s.file!.sublist(0, 4)), 'AVE1');
      for (final secret in [secretTitle, 'A01234567', 'JFIF']) {
        expect(_contains(box, utf8.encode(secret)), isFalse, reason: secret);
        expect(_contains(s.file!, utf8.encode(secret)), isFalse, reason: secret);
      }
      final meta = k.openDocBox(s.box)!;
      expect(meta['title'], secretTitle);
      expect(meta['mime'], 'image/jpeg');
      expect(await VaultE2E.openDocFile(meta, s.file!), photo);
      final bad = Uint8List.fromList(s.file!)..[100] ^= 1;
      expect(await VaultE2E.openDocFile(meta, bad), isNull);
    });
  });

  group('share links', () {
    test('the key travels only in the #fragment; the blob opens with it', () async {
      final file = Uint8List.fromList([0x25, 0x50, 0x44, 0x46, ...utf8.encode(' $secretTitle')]);
      final s = await VaultE2E.sealForShare(file, mime: sniffMime(file), name: 'd.pdf', title: secretTitle);
      expect(String.fromCharCodes(s.blob.sublist(0, 4)), 'AVS1');
      expect(_contains(s.blob, utf8.encode(secretTitle)), isFalse);
      expect(_contains(s.blob, utf8.encode('%PDF')), isFalse);
      final key = base64Url.decode(s.fragment + '=' * ((4 - s.fragment.length % 4) % 4));
      expect(key.length, 32);
      expect(_contains(s.blob, key), isFalse);
      final o = VaultE2E.openShare(s.blob, s.fragment)!;
      expect(o.file, file);
      expect(o.header['m'], 'application/pdf');
      expect(o.header['t'], secretTitle);
      final other = await VaultE2E.sealForShare(file, mime: 'application/pdf', name: 'x');
      expect(VaultE2E.openShare(s.blob, other.fragment), isNull);
    });

    test('mime sniffing', () {
      expect(sniffMime(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0])), 'image/png');
      expect(sniffMime(Uint8List.fromList([1, 2, 3])), 'application/octet-stream');
    });
  });

  group('End-to-end lock screen', () {
    for (final lang in ['bn', 'en']) {
      testWidgets('off state: turn-on + plain loss warning ($lang)', (tester) async {
        final be = FakeE2E();
        await tester.pumpWidget(_app(
            VaultE2EScreen(lock: VaultLock(kv: MemoryKv(), iterations: 10), backend: be, keyring: _ring()),
            lang: lang));
        await tester.pumpAndSettle();
        final t = await AppLocalizations.delegate.load(Locale(lang));
        expect(find.byKey(const Key('e2e_turn_on')), findsOneWidget);
        await tester.scrollUntilVisible(find.text(t.vaultE2eLossWarning), 200);
        expect(find.text(t.vaultE2eLossWarning), findsOneWidget);
      });

      testWidgets('locked on a new phone offers the recovery code ($lang)', (tester) async {
        final be = FakeE2E()
          ..st = {'ok': true, 'recovery_wrap': true, 'helpers': [], 'sealed_docs': 3, 'help_inbox': 0};
        await tester.pumpWidget(_app(
            VaultE2EScreen(lock: VaultLock(kv: MemoryKv(), iterations: 10), backend: be, keyring: _ring()),
            lang: lang));
        await tester.pumpAndSettle();
        final t = await AppLocalizations.delegate.load(Locale(lang));
        expect(find.byKey(const Key('e2e_unlock_code')), findsOneWidget);
        expect(find.text(t.vaultE2eLockedCount(lang == 'bn' ? '৩' : '3')), findsOneWidget);
      });
    }

    testWidgets('switching on stores ONE code for PIN reset + a sealed server wrap', (tester) async {
      final be = FakeE2E();
      final lock = VaultLock(kv: MemoryKv(), iterations: 10);
      await lock.setPin(pin);
      final ring = _ring();
      await tester.pumpWidget(_app(VaultE2EScreen(lock: lock, backend: be, keyring: ring)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('e2e_turn_on')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('e2e_understand')));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.tap(find.widgetWithText(FilledButton, t.vaultE2eTurnOn).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('e2e_pin')), pin);
      await tester.tap(find.text(t.ok));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(ring.unlocked, isTrue);
      expect(be.recovery, isNotNull);
      expect(_wrapJson(be.recovery!)['alg'], 'pbkdf2-c20p');
      expect(await lock.hasRecoveryCode(), isTrue);
    });
  });
}
