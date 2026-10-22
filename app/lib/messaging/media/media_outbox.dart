import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../crypto/e2e.dart';
import '../../services/error_report.dart';
import 'media_api.dart';
import 'media_descriptor.dart';
import 'media_store.dart';

/// md1 — one photo / voice note / document on its way out.
///
/// The persistent MEDIA outbox (sibling of messaging/outbox.dart for text):
/// a send is never lost — it survives offline, app restarts and network drops.
/// Steps, each saved so a restart resumes where it stopped:
///   1. seal the file on the phone (random key; background isolate)
///   2. create the blob on the server (size cap / daily quota checked there)
///   3. upload the CIPHERTEXT in 512 KiB chunks, resuming at the server's
///      offset after a drop; progress ring + cancel in the bubble
///   4. finish (server checks size + sha256)
///   5. encrypt the descriptor (key, nonce, sha, name, thumb) PER RECIPIENT
///      with the normal E2E text encryption and send the message
/// A peer without a published key yet just waits (clock icon, silent key
/// request) exactly like text — never a key error.
class MediaJob {
  final String id; // client_msg_id
  final String chatKind; // member | group
  final int chatId;
  final String kind; // photo | voice | document
  final String srcPath; // the app's own plaintext copy
  final String name;
  final String mime;
  final int plainSize;
  final int? width, height, durationMs;
  final List<int> wave;
  final String thumbB64;
  final String caption;
  final String? replyTo;
  final DateTime at;
  // progress (persisted)
  String encPath;
  String keyB64, nonceB64, sha;
  int cipherSize;
  String ref;
  String state; // queued | failed
  String error; // honest server sentence (or '' = network, will retry)

  MediaJob({
    required this.id,
    required this.chatKind,
    required this.chatId,
    required this.kind,
    required this.srcPath,
    required this.name,
    required this.mime,
    required this.plainSize,
    required this.at,
    this.width,
    this.height,
    this.durationMs,
    this.wave = const [],
    this.thumbB64 = '',
    this.caption = '',
    this.replyTo,
    this.encPath = '',
    this.keyB64 = '',
    this.nonceB64 = '',
    this.sha = '',
    this.cipherSize = 0,
    this.ref = '',
    this.state = 'queued',
    this.error = '',
  });

  bool get failed => state == 'failed';

  Map<String, dynamic> toJson() => {
        'id': id, 'ck': chatKind, 'chat': chatId, 'kind': kind, 'src': srcPath,
        'name': name, 'mime': mime, 'psize': plainSize,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (durationMs != null) 'ms': durationMs,
        if (wave.isNotEmpty) 'wave': wave,
        if (thumbB64.isNotEmpty) 'thumb': thumbB64,
        if (caption.isNotEmpty) 'cap': caption,
        if (replyTo != null) 'reply_to': replyTo,
        'at': at.toUtc().toIso8601String(),
        'enc': encPath, 'k': keyB64, 'n': nonceB64, 'sha': sha,
        'csize': cipherSize, 'ref': ref, 'state': state, 'err': error,
      };

  static MediaJob? fromJson(Map<String, dynamic> j) {
    final id = '${j['id'] ?? ''}';
    final chat = j['chat'] is int ? j['chat'] as int : int.tryParse('${j['chat']}');
    if (id.isEmpty || chat == null) return null;
    int? i(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');
    return MediaJob(
      id: id,
      chatKind: '${j['ck'] ?? 'member'}',
      chatId: chat,
      kind: '${j['kind'] ?? 'document'}',
      srcPath: '${j['src'] ?? ''}',
      name: '${j['name'] ?? ''}',
      mime: '${j['mime'] ?? 'application/octet-stream'}',
      plainSize: i(j['psize']) ?? 0,
      width: i(j['w']),
      height: i(j['h']),
      durationMs: i(j['ms']),
      wave: [for (final w in (j['wave'] as List? ?? const [])) if (w is int) w],
      thumbB64: '${j['thumb'] ?? ''}',
      caption: '${j['cap'] ?? ''}',
      replyTo: j['reply_to'] == null ? null : '${j['reply_to']}',
      at: DateTime.tryParse('${j['at'] ?? ''}')?.toLocal() ?? DateTime.now(),
      encPath: '${j['enc'] ?? ''}',
      keyB64: '${j['k'] ?? ''}',
      nonceB64: '${j['n'] ?? ''}',
      sha: '${j['sha'] ?? ''}',
      cipherSize: i(j['csize']) ?? 0,
      ref: '${j['ref'] ?? ''}',
      state: '${j['state'] ?? 'queued'}',
      error: '${j['err'] ?? ''}',
    );
  }

  /// The descriptor the recipients will get (after a finished upload).
  MediaDescriptor descriptor() => MediaDescriptor(
        kind: kind,
        ref: ref,
        key: Uint8List.fromList(base64Decode(keyB64)),
        nonce: Uint8List.fromList(base64Decode(nonceB64)),
        sha256: sha,
        size: cipherSize,
        plainSize: plainSize,
        mime: mime,
        name: name,
        width: width,
        height: height,
        durationMs: durationMs,
        wave: wave,
        thumb: thumbB64.isEmpty ? null : base64Decode(thumbB64),
        caption: caption,
      );
}

/// Storage seam (SharedPreferences in the app; memory in tests).
abstract class MediaJobStore {
  Future<List<Map<String, dynamic>>> load();
  Future<void> save(List<Map<String, dynamic>> rows);
}

class PrefsMediaJobStore implements MediaJobStore {
  const PrefsMediaJobStore();
  static const key = 'md1_media_outbox_v1';

  @override
  Future<List<Map<String, dynamic>>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(key);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> save(List<Map<String, dynamic>> rows) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(rows));
  }
}

/// Result of one finished send (the screen swaps its echo for the server row).
class MediaSent {
  final String jobId;
  final String serverId;
  final String chatKind;
  final int chatId;
  const MediaSent(this.jobId, this.serverId, this.chatKind, this.chatId);
}

class MediaOutbox {
  MediaOutbox({MediaJobStore? store, MediaTransport? transport, E2E? e2e})
      : store = store ?? const PrefsMediaJobStore(),
        transport = transport ?? HttpMediaTransport(),
        _e2e = e2e ?? SoftwareE2E();

  static MediaOutbox instance = MediaOutbox();

  final MediaJobStore store;
  MediaTransport transport;
  final E2E _e2e;
  static const int chunkBytes = 512 * 1024;

  /// Bumped on every queue change.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// job id -> 0..1 upload progress (-1 = preparing / encrypting).
  final ValueNotifier<Map<String, double>> progress =
      ValueNotifier<Map<String, double>>(const {});

  final StreamController<MediaSent> _sent = StreamController<MediaSent>.broadcast();
  Stream<MediaSent> get sent => _sent.stream;

  final Set<String> _cancelled = {};
  Future<IdentityKeyPair?> Function()? identity;

  Future<List<MediaJob>> all() async =>
      (await store.load()).map(MediaJob.fromJson).whereType<MediaJob>().toList();

  Future<List<MediaJob>> forChat(String kind, int chatId) async =>
      (await all()).where((j) => j.chatKind == kind && j.chatId == chatId).toList();

  Future<void> _put(MediaJob job) async {
    final rows = await store.load();
    final i = rows.indexWhere((r) => '${r['id']}' == job.id);
    if (i >= 0) {
      rows[i] = job.toJson();
    } else {
      rows.add(job.toJson());
    }
    await store.save(rows);
    changes.value++;
  }

  Future<void> _drop(String id) async {
    final rows = await store.load();
    rows.removeWhere((r) => '${r['id']}' == id);
    await store.save(rows);
    _setProgress(id, null);
    changes.value++;
  }

  void _setProgress(String id, double? v) {
    final m = Map<String, double>.from(progress.value);
    if (v == null) {
      m.remove(id);
    } else {
      m[id] = v;
    }
    progress.value = m;
  }

  /// Queue a new send and start it.
  Future<void> add(MediaJob job) async {
    await _put(job);
    unawaited(kick());
  }

  /// Cancel: stops the upload, deletes the local copies + the server blob.
  Future<void> cancel(String id) async {
    _cancelled.add(id);
    final job = (await all()).where((j) => j.id == id).firstOrNull;
    await _drop(id);
    if (job == null) return;
    for (final p in [job.encPath, job.srcPath]) {
      try {
        if (p.isNotEmpty && File(p).existsSync()) File(p).deleteSync();
      } catch (e) {
        reportNonFatal('md1_cancel_cleanup', e);
      }
    }
    if (job.ref.isNotEmpty) await transport.cancelBlob(job.ref);
  }

  /// Try a failed send again (e.g. after a daily-quota day rolled over).
  Future<void> retry(String id) async {
    final job = (await all()).where((j) => j.id == id).firstOrNull;
    if (job == null) return;
    job
      ..state = 'queued'
      ..error = '';
    await _put(job);
    _step = 0;
    unawaited(kick());
  }

  Future<void>? _run;
  bool _again = false;
  Timer? _timer;
  int _step = 0;
  static const retryDelays = <Duration>[
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 80),
    Duration(minutes: 3),
  ];

  /// Process every queued job, one at a time (low RAM / one upload at once).
  /// A kick while a pass runs joins it (and triggers one more pass after it,
  /// so a job added meanwhile is never left behind).
  Future<void> kick() {
    final r = _run;
    if (r != null) {
      _again = true;
      return r;
    }
    return _run = _loop().whenComplete(() => _run = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _pass();
    } while (_again);
  }

  Future<void> _pass() async {
    var waiting = false;
    try {
      final jobs = (await all()).where((j) => !j.failed).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      for (final j in jobs) {
        if (_cancelled.contains(j.id)) continue;
        final r = await process(j);
        if (r == MediaStep.waiting) waiting = true;
      }
    } catch (e, st) {
      reportNonFatal('md1_outbox_kick', e, st);
      waiting = true;
    }
    _timer?.cancel();
    if (waiting) {
      final d = retryDelays[_step.clamp(0, retryDelays.length - 1)];
      _step++;
      _timer = Timer(d, () => unawaited(kick()));
    } else {
      _step = 0;
    }
  }

  @visibleForTesting
  void stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// One job through all its steps. Never throws.
  @visibleForTesting
  Future<MediaStep> process(MediaJob job) async {
    try {
      // 1) seal on the phone
      if (job.encPath.isEmpty || !File(job.encPath).existsSync() || job.sha.isEmpty) {
        _setProgress(job.id, -1);
        if (!File(job.srcPath).existsSync()) {
          job
            ..state = 'failed'
            ..error = 'missing';
          await _put(job);
          return MediaStep.failed;
        }
        final enc = '${(await MediaDirs.sub('up')).path}/${job.id}.enc';
        final seal = await sealForUpload(job.srcPath, enc);
        job
          ..encPath = enc
          ..keyB64 = base64Encode(seal.key)
          ..nonceB64 = base64Encode(seal.nonce)
          ..sha = seal.sha256Hex
          ..cipherSize = seal.cipherSize
          ..ref = '';
        await _put(job);
      }
      if (_cancelled.contains(job.id)) return MediaStep.cancelled;
      // 2) blob
      if (job.ref.isEmpty) {
        final b = await transport.createBlob(job.kind, job.cipherSize, job.sha);
        job.ref = '${b['ref'] ?? ''}';
        await _put(job);
      }
      // 3) upload (resumable)
      var offset = 0;
      try {
        final st = await transport.blobStatus(job.ref);
        if (st['complete'] == true) {
          offset = job.cipherSize;
        } else {
          offset = (st['received'] as num?)?.toInt() ?? 0;
        }
      } on MediaHttpError catch (e) {
        if (e.status == 404) {
          job.ref = ''; // swept / lost: start a fresh blob next round
          await _put(job);
          return MediaStep.waiting;
        }
        rethrow;
      }
      final raf = File(job.encPath).openSync();
      try {
        while (offset < job.cipherSize) {
          if (_cancelled.contains(job.id)) return MediaStep.cancelled;
          _setProgress(job.id, offset / job.cipherSize);
          raf.setPositionSync(offset);
          final chunk = raf.readSync(chunkBytes);
          try {
            final r = await transport.putChunk(job.ref, offset, chunk);
            offset = (r['received'] as num?)?.toInt() ?? (offset + chunk.length);
          } on MediaHttpError catch (e) {
            if (e.status == 409) {
              offset = (e.body['received'] as num?)?.toInt() ?? 0;
              continue;
            }
            rethrow;
          }
        }
      } finally {
        raf.closeSync();
      }
      _setProgress(job.id, 1);
      final fin = await transport.finish(job.ref).catchError((Object e) {
        if (e is MediaHttpError && e.status == 409) return e.body; // re-upload
        throw e;
      });
      if (fin['complete'] != true) return MediaStep.waiting; // sha/size: next round
      if (_cancelled.contains(job.id)) return MediaStep.cancelled;
      // 4) the E2E message
      final me = await identity?.call();
      if (me == null) return MediaStep.waiting;
      final plain = job.descriptor().encode();
      final env = <String, dynamic>{
        'content_type': job.kind,
        'blob_ref': job.ref,
        'client_msg_id': job.id,
        if (job.replyTo != null) 'reply_to': job.replyTo,
        'sender_key_id': me.keyId,
        'scheme': _e2e.scheme,
      };
      Map<String, dynamic> res;
      if (job.chatKind == 'group') {
        final roster = await transport.groupRoster(job.chatId);
        final per = <String, dynamic>{};
        final ids = <int>[];
        for (final m in roster) {
          if (m['is_self'] == true) continue;
          final pk = '${m['public_key'] ?? ''}';
          if (pk.isEmpty || pk == me.publicKeyB64) continue;
          final raw = m['id'] ?? m['member_id'];
          final id = raw is int ? raw : int.tryParse('$raw');
          if (id == null) continue;
          try {
            final ct = _e2e.encrypt(
                self: me,
                recipientPublicKey: Uint8List.fromList(base64Decode(pk)),
                plaintext: plain);
            per['$id'] = {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64};
            ids.add(id);
          } catch (e) {
            reportNonFatal('md1_group_key', e);
          }
        }
        if (per.isEmpty) return MediaStep.waiting; // nobody's key yet: wait
        res = await transport.sendGroup(
            job.chatId, {...env, 'recipient_ids': ids, 'per_recipient': per});
      } else {
        final k = await transport.peerKey(job.chatId);
        final pk = '${k['public_key'] ?? ''}';
        if (pk.isEmpty) return MediaStep.waiting; // silent key request, clock icon
        final ct = _e2e.encrypt(
            self: me,
            recipientPublicKey: Uint8List.fromList(base64Decode(pk)),
            plaintext: plain);
        res = await transport.sendMember(job.chatId, {...env, ...ct.toEnvelopeFields()});
      }
      // 5) done: my plaintext copy becomes the cache file for my own bubble
      await MediaCache.instance.adopt(job.ref, job.descriptor().ext, job.srcPath);
      try {
        if (File(job.encPath).existsSync()) File(job.encPath).deleteSync();
      } catch (e) {
        reportNonFatal('md1_enc_cleanup', e);
      }
      await _drop(job.id);
      _sent.add(MediaSent(job.id, '${res['id'] ?? ''}', job.chatKind, job.chatId));
      return MediaStep.sent;
    } on MediaHttpError catch (e) {
      if (e.permanent) {
        job
          ..state = 'failed'
          ..error = e.detail.isNotEmpty ? e.detail : (e.reason.isNotEmpty ? e.reason : 'refused');
        await _put(job);
        _setProgress(job.id, null);
        return MediaStep.failed;
      }
      _setProgress(job.id, null);
      return MediaStep.waiting;
    } catch (e) {
      // offline / timeout: keep it queued, the retry timer resumes it
      _setProgress(job.id, null);
      return MediaStep.waiting;
    }
  }
}

/// Outcome of one [MediaOutbox.process] pass.
enum MediaStep { sent, waiting, failed, cancelled }
