import 'dart:async';
import 'dart:io';

import 'package:assisto/crypto/identity_vault.dart';
import 'package:assisto/crypto/key_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory slot that can be told to throw or hang (ColorOS Keystore modes).
class FakeSlot implements IdentitySlot {
  FakeSlot(this.name);
  @override
  final String name;
  String? value;
  Object? readError;
  Object? writeError;
  bool hang = false;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read() async {
    reads++;
    if (hang) return Completer<String?>().future;
    if (readError != null) throw readError!;
    return value;
  }

  @override
  Future<void> write(String v) async {
    writes++;
    if (hang) return Completer<void>().future;
    if (writeError != null) throw writeError!;
    value = v;
  }
}

class KeystoreError implements Exception {
  @override
  String toString() => 'PlatformException(KeyStoreException)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('idv');
  });
  tearDown(() async => tmp.delete(recursive: true));

  FileSlot fileSlot() => FileSlot(dir: () async => Directory('${tmp.path}/nb'));

  test('healthy secure storage: creates once, stores in both, same key after restart', () async {
    final sec = FakeSlot('secure');
    final v1 = IdentityVault(secure: sec, fallback: fileSlot());
    final a = await v1.get();
    expect(sec.value, isNotNull);
    expect(v1.volatile, isFalse);
    final v2 = IdentityVault(secure: sec, fallback: fileSlot());
    final b = await v2.get();
    expect(b.keyId, a.keyId);
  });

  test('Keystore always throws (OPPO case): identity survives restarts via the encrypted fallback', () async {
    final sec = FakeSlot('secure')..readError = KeystoreError()..writeError = KeystoreError();
    final v1 = IdentityVault(secure: sec, fallback: fileSlot());
    final a = await v1.get();
    expect(v1.volatile, isFalse);
    expect(v1.lastError, contains('secure:'));
    expect(sec.reads, 2, reason: 'one retry after a failure');
    final v2 = IdentityVault(secure: sec, fallback: fileSlot());
    final b = await v2.get();
    expect(b.keyId, a.keyId, reason: 'same identity after app restart');
    expect(b.privateKey, a.privateKey);
  });

  test('Keystore hangs: get() still completes (timeouts) and uses the fallback', () async {
    final sec = FakeSlot('secure')..hang = true;
    final v = IdentityVault(secure: sec, fallback: fileSlot());
    final a = await v.get().timeout(const Duration(seconds: 15));
    final again = await IdentityVault(secure: FakeSlot('secure')..hang = true, fallback: fileSlot())
        .get()
        .timeout(const Duration(seconds: 15));
    expect(again.keyId, a.keyId);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('both stores fail: volatile identity, still returned (chat opens, key publishes)', () async {
    final sec = FakeSlot('secure')..readError = KeystoreError()..writeError = KeystoreError();
    final file = FakeSlot('file')..readError = const FileSystemException('ro')..writeError = const FileSystemException('ro');
    final v = IdentityVault(secure: sec, fallback: file);
    final id = await v.get();
    expect(id.publicKey.length, 32);
    expect(v.volatile, isTrue);
    expect((await v.get()).keyId, id.keyId, reason: 'cached for the session');
  });

  test('existing secure identity is never replaced and is mirrored to the fallback', () async {
    final sec = FakeSlot('secure');
    final seed = await IdentityVault(secure: sec, fallback: FakeSlot('x')).get();
    final file = fileSlot();
    final v = IdentityVault(secure: sec, fallback: file);
    expect((await v.get()).keyId, seed.keyId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Keystore breaks later: the mirror keeps the SAME key.
    final broken = FakeSlot('secure')..readError = KeystoreError();
    expect((await IdentityVault(secure: broken, fallback: fileSlot()).get()).keyId, seed.keyId);
  });

  test('concurrent callers get ONE identity', () async {
    final sec = FakeSlot('secure');
    final v = IdentityVault(secure: sec, fallback: fileSlot());
    final r = await Future.wait([v.get(), v.get(), v.get()]);
    expect(r.map((e) => e.keyId).toSet().length, 1);
    expect(sec.writes, 1);
  });

  test('fallback file is sealed (no plaintext key, tamper detected)', () async {
    final sec = FakeSlot('secure')..readError = KeystoreError()..writeError = KeystoreError();
    final id = await IdentityVault(secure: sec, fallback: fileSlot()).get();
    final f = File('${tmp.path}/nb/id_v1.bin');
    final bytes = await f.readAsBytes();
    expect(String.fromCharCodes(bytes).contains(id.publicKeyB64), isFalse);
    bytes[20] ^= 0xFF;
    await f.writeAsBytes(bytes);
    final v = IdentityVault(secure: sec, fallback: fileSlot());
    expect(await v.peek(), isNull);
    expect(v.lastError, contains('file:'));
  });

  test('peek() never creates an identity (background isolate)', () async {
    final v = IdentityVault(secure: FakeSlot('secure'), fallback: fileSlot());
    expect(await v.peek(), isNull);
  });

  test('key publish works even when the Keystore always throws', () async {
    final sec = FakeSlot('secure')..readError = KeystoreError()..writeError = KeystoreError();
    IdentityVault.instance = IdentityVault(secure: sec, fallback: fileSlot());
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
}
