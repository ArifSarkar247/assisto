import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/e2e.dart' show ChaCha20Poly1305;

/// Where every secret lives (login token, E2E identity, …) — WhatsApp/Signal
/// style: an encrypted file store inside the app's private sandbox, in the
/// `no_backup` directory so it never goes to a cloud backup.
///
/// Why not Android Keystore (flutter_secure_storage) as the primary store:
/// on some ColorOS / MIUI builds (owner bug 22 Oct, OPPO Reno 12 F) it throws
/// or hangs, which silently broke login persistence, the E2E identity and
/// logout. The sandbox works the same on every brand and Android 8–16, so the
/// app never depends on the Keystore. Values an older build left in the
/// Keystore are read ONCE (time-boxed) and migrated here.
///
/// Each secret is one file `<name>.bin` = 12-byte nonce + ChaCha20-Poly1305
/// ciphertext (AAD = name) under a random 32-byte wrap key kept next to it.
/// Honest limit: like WhatsApp's local store, this relies on Android's
/// app sandbox; it protects against other apps and backups, not a rooted
/// device.
class SecretStore {
  SecretStore({Future<Directory> Function()? dir, LegacySecrets? legacy})
      : _dirFn = dir ?? _defaultDir,
        _legacy = legacy ?? const KeystoreLegacy();

  static SecretStore instance = SecretStore();

  /// TESTS ONLY (test/flutter_test_config.dart): back the store with the
  /// mocked flutter_secure_storage plugin, which each test resets — real file
  /// I/O never completes under the widget-test fake clock. Never used in the
  /// app.
  factory SecretStore.forTests() = _PluginBackedForTests;

  final Future<Directory> Function() _dirFn;
  final LegacySecrets _legacy;

  /// Runtime type of the last failure ('' when none). Never secret data.
  String lastError = '';

  Directory? _dir;
  Uint8List? _wk;
  Future<void> _lock = Future.value();

  static Future<Directory> _defaultDir() async {
    final support = await getApplicationSupportDirectory();
    // <data>/files -> <data>/no_backup (Context.getNoBackupFilesDir()).
    return Directory('${support.parent.path}/no_backup/assisto_secrets');
  }

  /// Serialise file operations within this isolate.
  Future<T> _locked<T>(Future<T> Function() op) {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return prev.then((_) => op()).whenComplete(done.complete);
  }

  Future<Directory> _ready() async {
    final d = _dir ??= await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Uint8List> _wrapKey(Directory d) async {
    final have = _wk;
    if (have != null) return have;
    final f = File('${d.path}/wk.bin');
    if (await f.exists()) {
      final b = await f.readAsBytes();
      if (b.length == 32) return _wk = b;
    }
    final k = _random(32);
    final tmp = File('${d.path}/wk.tmp');
    await tmp.writeAsBytes(k, flush: true);
    await tmp.rename(f.path);
    // Another isolate may have won the race: always use what is on disk.
    final onDisk = await f.readAsBytes();
    return _wk = onDisk.length == 32 ? onDisk : k;
  }

  static Uint8List _random(int n) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
  }

  /// The value, or null if none. Never throws; never waits on a hung Keystore
  /// longer than the legacy timeout.
  Future<String?> read(String name) async {
    try {
      final v = await _locked(() => _readFile(name));
      if (v != null) return v;
    } catch (e) {
      lastError = 'file:${e.runtimeType}';
    }
    // One-time migration from the old Keystore-backed slot.
    final old = await _legacy.read(name);
    if (old != null && old.isNotEmpty) {
      await write(name, old);
      return old;
    }
    return null;
  }

  /// Store [value]. Returns false (never throws) if the sandbox write failed.
  Future<bool> write(String name, String value) async {
    try {
      await _locked(() => _writeFile(name, value));
      return true;
    } catch (e) {
      lastError = 'file:${e.runtimeType}';
      return false;
    }
  }

  /// Remove [name] here and (best-effort, in the background) from the legacy
  /// Keystore slot. Never throws, never blocks on the Keystore.
  Future<void> delete(String name) async {
    try {
      await _locked(() async {
        final f = File('${(await _ready()).path}/$name.bin');
        if (await f.exists()) await f.delete();
      });
    } catch (e) {
      lastError = 'file:${e.runtimeType}';
    }
    unawaited(_legacy.delete(name));
  }

  Future<String?> _readFile(String name) async {
    final d = await _ready();
    final f = File('${d.path}/$name.bin');
    if (!await f.exists()) return null;
    final blob = await f.readAsBytes();
    if (blob.length < 12 + 16) throw const FormatException('short');
    final plain = ChaCha20Poly1305.decrypt(
        await _wrapKey(d), blob.sublist(0, 12), blob.sublist(12),
        aad: utf8.encode(name));
    if (plain == null) throw const FormatException('tag mismatch');
    return utf8.decode(plain);
  }

  Future<void> _writeFile(String name, String value) async {
    final d = await _ready();
    final nonce = _random(12);
    final ct = ChaCha20Poly1305.encrypt(await _wrapKey(d), nonce,
        Uint8List.fromList(utf8.encode(value)),
        aad: utf8.encode(name));
    final tmp = File('${d.path}/$name.tmp');
    await tmp.writeAsBytes([...nonce, ...ct], flush: true);
    await tmp.rename('${d.path}/$name.bin');
  }
}

/// Read-only access to secrets older builds kept in the Keystore.
abstract class LegacySecrets {
  Future<String?> read(String name);
  Future<void> delete(String name);
}

/// flutter_secure_storage, time-boxed and failure-proof. Old slot names map
/// 1:1 except the identity, which was 'circle_identity_v1'.
class KeystoreLegacy implements LegacySecrets {
  const KeystoreLegacy();
  static const _s = FlutterSecureStorage();
  static const _timeout = Duration(seconds: 3);

  @override
  Future<String?> read(String name) async {
    try {
      return await _s.read(key: name).timeout(_timeout);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete(String name) async {
    try {
      await _s.delete(key: name).timeout(_timeout);
    } catch (_) {}
  }
}

class _PluginBackedForTests extends SecretStore {
  _PluginBackedForTests() : super();
  static const _s = FlutterSecureStorage();

  @override
  Future<String?> read(String name) async {
    try {
      return await _s.read(key: name);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> write(String name, String value) async {
    try {
      await _s.write(key: name, value: value);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> delete(String name) async {
    try {
      await _s.delete(key: name);
    } catch (_) {}
  }
}
