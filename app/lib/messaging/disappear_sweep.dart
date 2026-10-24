import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/error_report.dart';
import 'media/media_descriptor.dart';
import 'media/media_store.dart';
import 'preview_cache.dart';

/// e-gaps — disappearing messages on THIS phone.
///
/// The server deletes an expired message (row + encrypted blob) and stops
/// returning it, so the chat drops it on the next load/poll. What the server
/// can't reach is what this phone made from it: the decrypted media file in
/// the app's private cache and the chat-list preview text. Every message a
/// chat shows while its timer covers it is registered here with its expiry;
/// [sweep] (chat open, every poll, hub open) deletes those copies once the
/// time has passed.
///
/// [isExpired] is the pure rule both the screen (hide at once, even between
/// polls) and the tests use.
bool isExpired(DateTime sentAt, int ttlSec, DateTime? since, {DateTime? now}) {
  if (ttlSec <= 0 || since == null) return false;
  if (sentAt.isBefore(since)) return false; // older history never expires
  return !(now ?? DateTime.now()).isBefore(sentAt.add(Duration(seconds: ttlSec)));
}

class DisappearSweep {
  DisappearSweep._();
  static final DisappearSweep instance = DisappearSweep._();
  static const _k = 'e_disappear_v1';
  static const _max = 3000;

  /// Tests swap the clock.
  DateTime Function() clock = DateTime.now;

  List<Map<String, dynamic>>? _mem;

  Future<List<Map<String, dynamic>>> _load() async {
    final m = _mem;
    if (m != null) return m;
    final out = <Map<String, dynamic>>[];
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_k);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as List)) {
          if (e is Map) out.add(e.cast<String, dynamic>());
        }
      }
    } catch (_) {}
    return _mem = out;
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_k, jsonEncode(_mem ?? const []));
    } catch (_) {}
  }

  /// Register message [msgId] of [chatKey] expiring at [expiresAt]; [media]
  /// = its decrypted file (if any) to delete then.
  Future<void> track(String chatKey, String msgId, DateTime expiresAt,
      {MediaDescriptor? media}) async {
    if (msgId.isEmpty) return;
    final l = await _load();
    if (l.any((e) => e['c'] == chatKey && e['id'] == msgId)) return;
    l.add({
      'c': chatKey,
      'id': msgId,
      'exp': expiresAt.millisecondsSinceEpoch,
      if (media != null) 'f': MediaCache.fileName(media.ref, media.ext),
    });
    while (l.length > _max) {
      l.removeAt(0);
    }
    await _save();
  }

  /// How many entries are waiting (tests / diagnostics).
  Future<int> pending() async => (await _load()).length;

  /// Delete this phone's copies of everything past its expiry. Returns the
  /// number of messages swept. Never throws.
  Future<int> sweep() async {
    try {
      final l = await _load();
      final now = clock().millisecondsSinceEpoch;
      final due = l.where((e) => (e['exp'] as num? ?? 0) <= now).toList();
      if (due.isEmpty) return 0;
      final root = MediaDirs.rootSync ?? await MediaDirs.root();
      for (final e in due) {
        final f = '${e['f'] ?? ''}';
        if (f.isNotEmpty && !f.contains('/')) {
          try {
            final file = File('$root/files/$f');
            if (file.existsSync()) file.deleteSync();
          } catch (err) {
            reportNonFatal('e_disappear_file', err);
          }
        }
        await PreviewCache.instance.drop('${e['c']}', '${e['id']}');
      }
      l.removeWhere(due.contains);
      await _save();
      return due.length;
    } catch (e) {
      reportNonFatal('e_disappear_sweep', e);
      return 0;
    }
  }

  /// Tests only.
  void resetForTest() => _mem = null;
}
