// vault100 — PIN lock (hash only, back-off, legacy migration, recovery code),
// encrypted offline copies, recovery + security screens in bn and en.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_lock.dart' show ChatLockAuth;
import 'package:assisto/push/push_payload.dart';
import 'package:assisto/vault/vault_api.dart';
import 'package:assisto/vault/vault_lock.dart';
import 'package:assisto/vault/vault_lock_view.dart';
import 'package:assisto/vault/vault_offline.dart';
import 'package:assisto/vault/vault_recovery_screen.dart';
import 'package:assisto/vault/vault_security_screen.dart';
import 'package:assisto/widgets/vault_doc_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const pin = '482173';

class FakeVault implements VaultBackend {
  Map<String, dynamic>? status;
  bool offline = false;
  final List<Map<String, dynamic>> verifyCalls = [];
  Map<String, dynamic> verifyAnswer = {'ok': true, '_status': 200};
  final Map<int, bool> alerts = {};

  @override
  Future<Map<String, dynamic>> recoveryStatus() async {
    if (offline) throw const SocketException('offline');
    return status ?? {'ok': true, 'sms': false, 'email': false, 'password': true, 'any': true};
  }

  @override
  Future<Map<String, dynamic>> recoveryVerify(Map<String, dynamic> body) async {
    verifyCalls.add(Map.of(body));
    return verifyAnswer;
  }

  @override
  Future<void> setExpiryAlerts(int docId, bool on) async => alerts[docId] = on;
}

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

/// Launches [screen] from a button so it can pop with a result.
class _Launcher extends StatefulWidget {
  final Future<bool> Function(BuildContext) open;
  const _Launcher(this.open);
  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  bool? result;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          TextButton(
              onPressed: () async {
                final r = await widget.open(context);
                setState(() => result = r);
              },
              child: const Text('go')),
          Text('result:$result'),
        ]),
      );
}

void main() {
  group('VaultLock', () {
    late MemoryKv kv;
    late DateTime now;
    late VaultLock lock;
    setUp(() {
      kv = MemoryKv();
      now = DateTime(2026, 11, 2, 11);
      lock = VaultLock(kv: kv, iterations: 50, clock: () => now);
    });

    test('stores only a salted hash, never the PIN', () async {
      expect(await lock.hasPin(), isFalse);
      expect(await lock.setPin('12'), isFalse); // too short
      expect(await lock.setPin(pin), isTrue);
      final blob = jsonEncode(kv.values);
      expect(blob.contains(pin), isFalse);
      expect(kv.values[VaultSlots.pinHash]!.startsWith('v1\$50\$'), isTrue);
      expect(await lock.check(pin), PinCheck.ok);
      expect(await lock.check('000000'), PinCheck.wrong);
    });

    test('two phones with the same PIN get different hashes (salt)', () async {
      final kv2 = MemoryKv();
      await lock.setPin(pin);
      await VaultLock(kv: kv2, iterations: 50).setPin(pin);
      expect(kv.values[VaultSlots.pinHash], isNot(kv2.values[VaultSlots.pinHash]));
    });

    test('legacy plaintext PIN is migrated to a hash on unlock', () async {
      kv.values[VaultSlots.legacyPin] = '1234';
      expect(await lock.hasPin(), isTrue);
      expect(await lock.check('1234'), PinCheck.ok);
      expect(kv.values.containsKey(VaultSlots.legacyPin), isFalse);
      expect(jsonEncode(kv.values).contains('"1234"'), isFalse);
      expect(await lock.check('1234'), PinCheck.ok);
    });

    test('5 wrong tries -> growing lock-out that expires', () async {
      await lock.setPin(pin);
      for (var i = 0; i < 4; i++) {
        expect(await lock.check('111111'), PinCheck.wrong);
      }
      expect(await lock.triesLeftBeforeLockout(), 1);
      expect(await lock.check('111111'), PinCheck.lockedOut);
      expect(await lock.check(pin), PinCheck.lockedOut); // even the right one
      expect((await lock.lockedFor())!.inSeconds, 30);
      now = now.add(const Duration(seconds: 31));
      expect(await lock.lockedFor(), isNull);
      expect(await lock.check('111111'), PinCheck.lockedOut);
      expect((await lock.lockedFor())!.inSeconds, 60); // doubled
      now = now.add(const Duration(minutes: 2));
      expect(await lock.check(pin), PinCheck.ok);
      expect(await lock.triesLeftBeforeLockout(), VaultLock.freeTries);
    });

    test('recovery code: hashed, single use, clears the PIN', () async {
      await lock.setPin(pin);
      final code = await lock.newRecoveryCode();
      expect(code, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$')));
      expect(jsonEncode(kv.values).contains(VaultLock.normalizeCode(code!)), isFalse);
      expect(await lock.useRecoveryCode('AAAA-BBBB-CCCC-DDDD'), PinCheck.wrong);
      expect(await lock.useRecoveryCode(code.toLowerCase().replaceAll('-', ' ')), PinCheck.ok);
      expect(await lock.hasPin(), isFalse);
      expect(await lock.hasRecoveryCode(), isFalse); // burned
      expect(await lock.useRecoveryCode(code), PinCheck.noPin);
    });

    test('a PIN lock-out never blocks the recovery code', () async {
      await lock.setPin(pin);
      final code = await lock.newRecoveryCode();
      for (var i = 0; i < 5; i++) {
        await lock.check('111111');
      }
      expect(await lock.lockedFor(), isNotNull);
      expect(await lock.useRecoveryCode(code!), PinCheck.ok);
      expect(await lock.lockedFor(), isNull); // clearPin reset the PIN back-off
    });

    test('clearPin keeps the recovery code and fingerprint choice', () async {
      await lock.setPin(pin);
      await lock.newRecoveryCode();
      await lock.setBiometric(true);
      await lock.clearPin();
      expect(await lock.hasPin(), isFalse);
      expect(await lock.hasRecoveryCode(), isTrue);
      expect(await lock.biometricEnabled(), isTrue);
    });
  });

  group('VaultOffline', () {
    late Directory dir;
    late MemoryKv kv;
    late VaultOffline off;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vault100_');
      kv = MemoryKv();
      off = VaultOffline(kv: kv, dir: () async => dir);
    });
    tearDown(() => dir.delete(recursive: true));

    final secret = Uint8List.fromList(utf8.encode('PASSPORT AB1234567 ' * 500));
    final doc = {'id': 7, 'title': 'My passport', 'doc_type': 'passport',
      'file_url': '/api/v1/documents/7/file', 'expiry_date': '2027-01-01'};

    test('round trip; the file on disk is ciphertext', () async {
      expect(await off.save(doc, secret), isTrue);
      final onDisk = await File('${dir.path}/7.bin').readAsBytes();
      expect(utf8.decode(onDisk, allowMalformed: true).contains('AB1234567'), isFalse);
      expect(await off.openFile(7), secret);
      expect(await off.isOffline(7), isTrue);
      expect(await off.usageBytes(), onDisk.length);
      // a new instance (app restart) still opens it
      final again = VaultOffline(kv: kv, dir: () async => dir);
      expect(await again.openFile(7), secret);
      expect((await again.index())[7]!.meta['title'], 'My passport');
    });

    test('tampered copy is refused, never shown', () async {
      await off.save(doc, secret);
      final f = File('${dir.path}/7.bin');
      final b = await f.readAsBytes();
      b[40] ^= 1;
      await f.writeAsBytes(b);
      expect(await off.openFile(7), isNull);
    });

    test('remove, removeAll and sync with the server list', () async {
      await off.save(doc, secret);
      await off.save({...doc, 'id': 8}, null); // details-only document
      expect(await off.usageBytes(), greaterThan(0));
      final gone = await off.syncWith([{...doc, 'title': 'Renamed'}]);
      expect(gone, [8]);
      expect((await off.index())[7]!.meta['title'], 'Renamed');
      await off.remove(7);
      expect(await off.openFile(7), isNull);
      expect(File('${dir.path}/7.bin').existsSync(), isFalse);
      await off.save(doc, secret);
      await off.removeAll();
      expect(await off.index(), isEmpty);
      expect(await off.usageBytes(), 0);
    });

    test('key is random per install and not the PIN', () async {
      await off.save(doc, secret);
      final k = base64Decode(kv.values[VaultOffline.keySlot]!);
      expect(k.length, 32);
      final other = MemoryKv();
      await VaultOffline(kv: other, dir: () async => Directory('${dir.path}/b'))
          .save(doc, secret);
      expect(other.values[VaultOffline.keySlot], isNot(kv.values[VaultOffline.keySlot]));
    });
  });

  group('push routing + doc types', () {
    test('doc_expiry opens the vault', () {
      final p = PushPayload.fromData({'kind': 'doc_expiry', 'route': 'vault'});
      expect(PushRouting.targetFor(p)!.chatNavRoute, 'documents');
      expect(PushPayload.fromData({'kind': 'doc_expiry'}).isKnownKind, isTrue);
    });
    test('trade licence + vehicle papers exist', () {
      expect(vaultTypeOf('trade_licence').key, 'trade_licence');
      expect(vaultTypeOf('trade_licence').defaultValidityYears, 1);
      expect(vaultTypeOf('vehicle').key, 'vehicle');
    });
  });

  for (final lang in ['en', 'bn']) {
    group('screens ($lang)', () {
      setUp(() => ChatLockAuth.biometric = (_) async => null);

      testWidgets('set PIN: mismatch then success', (tester) async {
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        var opened = false;
        await tester.pumpWidget(_app(
            Scaffold(body: VaultLockView(lock: lock, mode: VaultLockMode.set,
                onUnlocked: () => opened = true)),
            lang: lang));
        await tester.pumpAndSettle();
        final t = AppLocalizations.of(tester.element(find.byType(VaultLockView)));
        await tester.enterText(find.byKey(const Key('vault_pin')), '4821');
        await tester.enterText(find.byKey(const Key('vault_pin2')), '4822');
        await tester.tap(find.byKey(const Key('vault_pin_submit')));
        await tester.pumpAndSettle();
        expect(find.text(t.vaultPinMismatch), findsOneWidget);
        await tester.enterText(find.byKey(const Key('vault_pin2')), '4821');
        await tester.tap(find.byKey(const Key('vault_pin_submit')));
        await tester.pumpAndSettle();
        expect(opened, isTrue);
        expect(await lock.check('4821'), PinCheck.ok);
        final h = tester.getSize(find.byKey(const Key('vault_pin_submit')));
        expect(h.height, greaterThanOrEqualTo(48));
      });

      testWidgets('wrong PIN shows tries left in the right digits', (tester) async {
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        await lock.setPin('4821');
        var forgot = false;
        await tester.pumpWidget(_app(
            Scaffold(body: VaultLockView(lock: lock, mode: VaultLockMode.enter,
                onUnlocked: () {}, onForgot: () => forgot = true)),
            lang: lang));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('vault_pin')), '1111');
        await tester.tap(find.byKey(const Key('vault_pin_submit')));
        await tester.pumpAndSettle();
        expect(find.textContaining(lang == 'bn' ? '৪' : '4'), findsWidgets);
        await tester.tap(find.byKey(const Key('vault_forgot')));
        expect(forgot, isTrue);
      });

      testWidgets('recovery by password: only proof goes out, PIN cleared', (tester) async {
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        await lock.setPin(pin);
        final be = FakeVault();
        await tester.pumpWidget(_app(
            _Launcher((ctx) => VaultRecoveryScreen.run(ctx, lock: lock, backend: be)),
            lang: lang));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        final t = AppLocalizations.of(tester.element(find.byType(VaultRecoveryScreen)));
        expect(find.text(t.vaultRecoverSafeTitle), findsOneWidget);
        expect(find.byKey(const Key('vault_recover_otp')), findsNothing); // SMS off
        await tester.tap(find.byKey(const Key('vault_recover_pw')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('vault_recover_password')), 'pw-1');
        await tester.tap(find.text(t.vaultVerify));
        await tester.pumpAndSettle();
        expect(be.verifyCalls, [{'method': 'password', 'password': 'pw-1'}]);
        expect(jsonEncode(be.verifyCalls).contains(pin), isFalse);
        expect(find.text('result:true'), findsOneWidget);
        expect(await lock.hasPin(), isFalse);
      });

      testWidgets('recovery: server refusal message shown, PIN kept', (tester) async {
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        await lock.setPin(pin);
        final be = FakeVault()
          ..verifyAnswer = {'ok': false, '_status': 403, 'reason': 'bad_password',
            'message': 'SERVER-SAYS-NO'};
        await tester.pumpWidget(_app(
            _Launcher((ctx) => VaultRecoveryScreen.run(ctx, lock: lock, backend: be)),
            lang: lang));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('vault_recover_pw')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('vault_recover_password')), 'x');
        final t = AppLocalizations.of(tester.element(find.byType(VaultRecoveryScreen)));
        await tester.tap(find.text(t.vaultVerify));
        await tester.pumpAndSettle();
        expect(find.text('SERVER-SAYS-NO'), findsOneWidget);
        expect(await lock.hasPin(), isTrue);
      });

      testWidgets('offline recovery: recovery code works without internet', (tester) async {
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        await lock.setPin(pin);
        final code = await lock.newRecoveryCode();
        final be = FakeVault()..offline = true;
        await tester.pumpWidget(_app(
            _Launcher((ctx) => VaultRecoveryScreen.run(ctx, lock: lock, backend: be)),
            lang: lang));
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        final t = AppLocalizations.of(tester.element(find.byType(VaultRecoveryScreen)));
        expect(find.text(t.vaultRecoverOffline), findsOneWidget);
        expect(find.byKey(const Key('vault_recover_pw')), findsNothing);
        await tester.tap(find.byKey(const Key('vault_recover_rc')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('vault_recover_code')), code!);
        await tester.tap(find.text(t.vaultVerify));
        await tester.pumpAndSettle();
        expect(find.text('result:true'), findsOneWidget);
        expect(be.verifyCalls, isEmpty); // nothing sent anywhere
      });

      testWidgets('no method at all: honest text', (tester) async {
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        final be = FakeVault()
          ..status = {'ok': true, 'sms': false, 'email': false, 'password': false, 'any': false};
        await tester.pumpWidget(_app(
            VaultRecoveryScreen(lock: lock, backend: be), lang: lang));
        await tester.pumpAndSettle();
        final t = AppLocalizations.of(tester.element(find.byType(VaultRecoveryScreen)));
        expect(find.text(t.vaultRecoverNone), findsOneWidget);
      });

      testWidgets('security screen: warning, make code, offline usage', (tester) async {
        final lock = VaultLock(kv: MemoryKv(), iterations: 10);
        final kv = MemoryKv();
        final dir = Directory.systemTemp.createTempSync('vault100w_');
        addTearDown(() => dir.deleteSync(recursive: true));
        final off = VaultOffline(kv: kv, dir: () async => dir);
        await tester.runAsync(() => off.save({'id': 1, 'title': 'P'}, List.filled(2048, 7)));
        final be = FakeVault()
          ..status = {'ok': true, 'sms': false, 'email': false, 'password': false, 'any': false};
        await tester.pumpWidget(_app(
            VaultSecurityScreen(lock: lock, offline: off, backend: be), lang: lang));
        await tester.pumpAndSettle();
        final t = AppLocalizations.of(tester.element(find.byType(VaultSecurityScreen)));
        expect(find.byKey(const Key('vault_no_recovery_warn')), findsOneWidget);
        expect(find.text(t.vaultHowNotE2e), findsOneWidget);
        await tester.scrollUntilVisible(find.byKey(const Key('vault_offline_usage')), 200);
        expect(find.textContaining(lang == 'bn' ? '১টি' : '1 documents'), findsOneWidget);
        await tester.scrollUntilVisible(find.text(t.vaultRecoveryCodeCreate), -200);
        await tester.tap(find.text(t.vaultRecoveryCodeCreate));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('vault_rc_value')), findsOneWidget);
        await tester.tap(find.text(t.vaultRecoveryCodeSaved));
        await tester.pumpAndSettle();
        expect(await lock.hasRecoveryCode(), isTrue);
        expect(find.byKey(const Key('vault_no_recovery_warn')), findsNothing);
      });
    });
  }
}
