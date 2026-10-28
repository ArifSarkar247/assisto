// vault100 — "Available offline": an ENCRYPTED copy of chosen vault documents
// on this phone, so a passport opens at the airport with no internet.
//
//  * file   <no_backup>/assisto_vault/<id>.bin = 12-byte nonce || sealed bytes
//           (ChaCha20-Poly1305 in 64 KiB chunks — messaging/media/media_crypto)
//  * key    one random 32-byte key per install, in the encrypted SecretStore
//           (slot vault_offline_key) — NOT derived from the vault PIN, so a PIN
//           reset keeps the copies; deleting the app deletes key and copies.
//  * index  the documents' metadata (title, numbers, expiry) in the SecretStore
//           (encrypted at rest too), so the list shows offline as well.
//  * no_backup dir: never copied to a cloud backup.
//  * opening decrypts into MEMORY only (VaultViewer shows the bytes); nothing
//    plaintext is written to disk.
// Honest limit: like WhatsApp's local store this relies on Android's app
// sandbox; it protects against other apps and backups, not a rooted phone.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../messaging/media/media_crypto.dart' show openBytes, randomBytes, sealBytes;
import 'vault_lock.dart' show SecretKv, VaultKv;

class OfflineEntry {
  final int id;
  final Map<String, dynamic> meta;
  final int size; // bytes on disk (0 = details only, no file)
  final DateTime savedAt;
  const OfflineEntry(this.id, this.meta, this.size, this.savedAt);

  Map<String, dynamic> toJson() =>
      {'meta': meta, 'size': size, 'saved_at': savedAt.toIso8601String()};
}

class VaultOffline {
  VaultOffline({VaultKv? kv, Future<Directory> Function()? dir})
      : _kv = kv ?? const SecretKv(),
        _dirFn = dir ?? _defaultDir;

  static VaultOffline instance = VaultOffline();

  static const keySlot = 'vault_offline_key';
  static const indexSlot = 'vault_offline_index';

  final VaultKv _kv;
  final Future<Directory> Function() _dirFn;
  Map<int, OfflineEntry>? _index;

  static Future<Directory> _defaultDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.parent.path}/no_backup/assisto_vault');
  }

  Future<Directory> _ready() async {
    final d = await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Uint8List> _key() async {
    final have = await _kv.read(keySlot);
    if (have != null) {
      try {
        final k = base64Decode(have);
        if (k.length == 32) return k;
      } catch (_) {}
    }
    final k = randomBytes(32);
    if (!await _kv.write(keySlot, base64Encode(k))) {
      throw const FileSystemException('vault key store unavailable');
    }
    return k;
  }

  /// All offline documents (empty when the store can't be read — never throws).
  Future<Map<int, OfflineEntry>> index() async {
    final have = _index;
    if (have != null) return have;
    final out = <int, OfflineEntry>{};
    try {
      final raw = await _kv.read(indexSlot);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        j.forEach((k, v) {
          final id = int.tryParse(k);
          if (id == null || v is! Map) return;
          out[id] = OfflineEntry(
              id,
              Map<String, dynamic>.from(v['meta'] as Map? ?? const {}),
              (v['size'] as num?)?.toInt() ?? 0,
              DateTime.tryParse('${v['saved_at']}') ?? DateTime.now());
        });
      }
    } catch (_) {}
    return _index = out;
  }

  Future<bool> _writeIndex(Map<int, OfflineEntry> idx) async {
    _index = idx;
    return _kv.write(indexSlot,
        jsonEncode({for (final e in idx.entries) '${e.key}': e.value.toJson()}));
  }

  Future<bool> isOffline(int id) async => (await index()).containsKey(id);

  /// Keep [doc] (+ its file [bytes], when it has one) on this phone.
  Future<bool> save(Map<String, dynamic> doc, List<int>? bytes) async {
    final id = doc['id'];
    if (id is! int) return false;
    try {
      var size = 0;
      if (bytes != null) {
        final key = await _key();
        final nonce = randomBytes(12);
        final plain = Uint8List.fromList(bytes);
        final sealed = await Isolate.run(() => sealBytes(key, nonce, plain));
        final d = await _ready();
        final tmp = File('${d.path}/$id.tmp');
        await tmp.writeAsBytes([...nonce, ...sealed], flush: true);
        await tmp.rename('${d.path}/$id.bin');
        size = nonce.length + sealed.length;
      }
      final idx = Map<int, OfflineEntry>.from(await index());
      idx[id] = OfflineEntry(id, Map<String, dynamic>.from(doc), size, DateTime.now());
      return await _writeIndex(idx);
    } catch (_) {
      return false;
    }
  }

  /// The decrypted file bytes, or null (not saved / tampered / no file).
  Future<Uint8List?> openFile(int id) async {
    try {
      final d = await _ready();
      final f = File('${d.path}/$id.bin');
      if (!await f.exists()) return null;
      final blob = await f.readAsBytes();
      if (blob.length < 12 + 16) return null;
      final key = await _key();
      final nonce = Uint8List.fromList(blob.sublist(0, 12));
      final ct = Uint8List.fromList(blob.sublist(12));
      return await Isolate.run(() => openBytes(key, nonce, ct));
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(int id) async {
    try {
      final d = await _ready();
      for (final n in ['$id.bin', '$id.tmp']) {
        final f = File('${d.path}/$n');
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    final idx = Map<int, OfflineEntry>.from(await index())..remove(id);
    await _writeIndex(idx);
  }

  Future<void> removeAll() async {
    for (final id in (await index()).keys.toList()) {
      await remove(id);
    }
    try {
      final d = await _ready();
      await for (final f in d.list()) {
        if (f is File) await f.delete();
      }
    } catch (_) {}
    await _writeIndex({});
  }

  Future<int> usageBytes() async {
    var total = 0;
    for (final e in (await index()).values) {
      total += e.size;
    }
    return total;
  }

  /// After a successful online load: refresh the saved metadata of offline
  /// documents and drop the ones deleted elsewhere. Returns the ids dropped.
  Future<List<int>> syncWith(List<Map<String, dynamic>> serverDocs) async {
    final idx = Map<int, OfflineEntry>.from(await index());
    if (idx.isEmpty) return const [];
    final byId = {for (final d in serverDocs) if (d['id'] is int) d['id'] as int: d};
    final gone = <int>[];
    for (final id in idx.keys.toList()) {
      final fresh = byId[id];
      if (fresh == null) {
        gone.add(id);
      } else {
        final e = idx[id]!;
        idx[id] = OfflineEntry(id, Map<String, dynamic>.from(fresh), e.size, e.savedAt);
      }
    }
    await _writeIndex(idx);
    for (final id in gone) {
      await remove(id);
    }
    return gone;
  }

  /// TESTS: forget the in-memory index cache.
  void resetCache() => _index = null;
}
