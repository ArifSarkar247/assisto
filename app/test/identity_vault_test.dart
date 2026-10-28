import 'dart:async';
import 'dart:io';

import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/crypto/key_service.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The old Keystore slot, forced into each ColorOS/MIUI failure mode.
class FakeLegacy implements LegacySecrets {
  final Map<String, String> values = {};
  bool hang = false;
  bool fail = false;
  int reads = 0;

  @override
  Future<String?> read(String name) async {
    reads++;
    if (hang) return Completer<String?>().future.timeout(
        const Duration(milliseconds: 200), onTimeout: () => null);
    if (fail) return null; // KeystoreLegacy swallows errors -> null
    return values[name];
  }

  @override
  Future<void> delete(String name) async {
    if (hang) return Completer<void>().future;
    values.remove(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late FakeLegacy legacy;

  SecretStore store() =>
      SecretStore(dir: () async => Directory('${tmp.path}/no_backup/s'), legacy: legacy);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('sec');
    legacy = FakeLegacy();
  });
  tearDown(() async {
    // root cause of the CI flake: get() returns before its background
    // key-ring write finishes; wait for it before removing the directory
    await IdentityVault.backgroundIdle();
    await tmp.delete(recursive: true);
  });

  group('SecretStore (app sandbox, Keystore never required)', () {
    test('write/read/delete round trip, survives a new instance (app restart)', () async {
      expect(await store().write('token', 'abc123'), isTrue);
      expect(await store().read('token'), 'abc123');
      await store().delete('token');
      expect(await store().read('token'), isNull);
    });

    test('Keystore forced to fail: token still saved and read back', () async {
      legacy.fail = true;
      expect(await store().write('token', 't-1'), isTrue);
      expect(await store().read('token'), 't-1');
    });

    test('Keystore hangs: delete (logout) does not wait for it', () async {
      legacy.hang = true;
      await store().write('token', 't-2');
      final sw = Stopwatch()..start();
      await store().delete('token');
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(await store().read('token'), isNull);
    });

    test('old Keystore value is migrated once into the sandbox', () async {
      legacy.values['token'] = 'old-token';
      expect(await store().read('token'), 'old-token');
      legacy.values.clear();
      expect(await store().read('token'), 'old-token', reason: 'now from the file');
    });

    test('files are sealed: no plaintext, tamper detected', () async {
      await store().write('token', 'very-secret-token-value');
      final f = File('${tmp.path}/no_backup/s/token.bin');
      final bytes = await f.readAsBytes();
      expect(String.fromCharCodes(bytes).contains('very-secret'), isFalse);
      bytes[20] ^= 0xFF;
      await f.writeAsBytes(bytes);
      final s = store();
      expect(await s.read('token'), isNull);
      expect(s.lastError, startsWith('file:'));
    });

    test('lives under no_backup (excluded from cloud backup)', () async {
      await store().write('x', 'y');
      expect(Directory('${tmp.path}/no_backup/s').existsSync(), isTrue);
    });
  });

  group('IdentityVault', () {
    test('Keystore forced to fail: identity created, kept across restarts', () async {
      legacy.fail = true;
      final a = await IdentityVault(store: store()).get();
      final b = await IdentityVault(store: store()).get();
      expect(b.keyId, a.keyId);
      expect(b.privateKey, a.privateKey);
    });

    test('existing identity from an older build (Keystore) is migrated, not replaced', () async {
      final seed = await IdentityVault(store: SecretStore(
          dir: () async => Directory('${tmp.path}/seed'), legacy: legacy)).get();
      legacy.values[IdentityVault.slot] =
          (await SecretStore(dir: () async => Directory('${tmp.path}/seed'), legacy: FakeLegacy())
              .read(IdentityVault.slot))!;
      final got = await IdentityVault(store: store()).get();
      expect(got.keyId, seed.keyId);
    });

    test('unreadable stored identity -> safe re-key (never an empty identity)', () async {
      await store().write(IdentityVault.slot, '{broken');
      final v = IdentityVault(store: store());
      final id = await v.get();
      expect(id.publicKey.length, 32);
      expect(v.rekeyed, isTrue);
      expect((await IdentityVault(store: store()).get()).keyId, id.keyId);
    });

    test('concurrent callers get ONE identity', () async {
      final v = IdentityVault(store: store());
      final r = await Future.wait([v.get(), v.get(), v.get()]);
      expect(r.map((e) => e.keyId).toSet().length, 1);
    });

    test('peek() never creates (background isolate)', () async {
      expect(await IdentityVault(store: store()).peek(), isNull);
    });

    test('key publish works with the Keystore forced to fail', () async {
      legacy.fail = true;
      IdentityVault.instance = IdentityVault(store: store());
      final posted = <Map<String, dynamic>>[];
      final ks = KeyService(store: const SecureIdentityStore(), sleep: (_) async {});
      final ok = await ks.publish((path, body) async {
        posted.add(body);
        return <String, dynamic>{};
      }, reason: 'test');
      expect(ok, isTrue);
      expect(posted.single['key_id'], (await IdentityVault.instance.get()).keyId);
      IdentityVault.instance = IdentityVault();
    });
  });
}
