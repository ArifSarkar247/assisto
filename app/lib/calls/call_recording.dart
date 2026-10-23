import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/e2e.dart' show ChaCha20Poly1305;
import '../security/secret_store.dart';
import 'call_log.dart';

/// b3-group B5 — call recording ONLY with everyone's consent.
///
/// The SERVER holds the consent state (core.logic.sfu consent_*): the
/// requester asks, every participant gets Accept / Decline, recording runs
/// only while EVERY person present accepted, any decline ends it, a newcomer
/// who has not accepted pauses it. This phone only follows that state:
///   * the requester's phone records while `iRecord` is true (never before,
///     never after) — [ConsentRecorder] starts/stops the [CallRecorderEngine];
///   * everyone sees the red "Recording" banner while status == recording.
/// No silent path exists: the engine is only ever started from
/// [RecordingSession.apply] with a server view that says i_record.
enum RecordStatus { none, pending, recording, paused, declined, stopped }

RecordStatus recordStatusFrom(String s) => switch (s) {
      'pending' => RecordStatus.pending,
      'recording' => RecordStatus.recording,
      'paused' => RecordStatus.paused,
      'declined' => RecordStatus.declined,
      'stopped' => RecordStatus.stopped,
      _ => RecordStatus.none,
    };

/// One phone's view of the consent state (server `consent_view`).
@immutable
class RecordingConsent {
  const RecordingConsent({
    this.id,
    this.status = RecordStatus.none,
    this.requester,
    this.accepted = const [],
    this.declinedBy,
    this.iMustAnswer = false,
    this.iRecord = false,
  });

  factory RecordingConsent.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const RecordingConsent();
    int? i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return RecordingConsent(
      id: i(j['id']),
      status: recordStatusFrom('${j['status'] ?? ''}'),
      requester: i(j['requester']),
      accepted: [
        for (final a in (j['accepted'] as List? ?? const []))
          if (i(a) != null) i(a)!
      ],
      declinedBy: i(j['declined_by']),
      iMustAnswer: j['i_must_answer'] == true,
      iRecord: j['i_record'] == true,
    );
  }

  final int? id;
  final RecordStatus status;
  final int? requester;
  final List<int> accepted;
  final int? declinedBy;
  final bool iMustAnswer;
  final bool iRecord;

  /// The red banner + dot is up for EVERYONE while this is true.
  bool get recordingNow => status == RecordStatus.recording;
  bool get open =>
      status == RecordStatus.pending ||
      status == RecordStatus.recording ||
      status == RecordStatus.paused;
}

/// The native recorder (flutter_webrtc MediaRecorder, audio only: this
/// phone's microphone + what the phone plays = everyone else). A fake in
/// tests. [start] / [stop] are only called by [ConsentRecorder].
abstract class CallRecorderEngine {
  /// Start recording into [dir] (private app storage). Returns the raw
  /// (unencrypted, temporary) file paths it writes.
  Future<List<String>> start(String dir);

  /// Stop; the files given by [start] are complete afterwards.
  Future<void> stop();
}

/// Encrypted call recordings, kept ONLY on this phone: each part file is
/// ChaCha20-Poly1305-encrypted with its own random 32-byte key, the key is
/// kept in [SecretStore] (the app's encrypted secret store with its
/// fallback), the plaintext is deleted at once. The index (who / when) is a
/// SecretStore entry too. Playback / share decrypt into the app's cache only
/// for the moment they are needed.
class RecordingVault {
  RecordingVault({SecretStore? store, Future<Directory> Function()? dir})
      : _store = store ?? SecretStore.instance,
        _dirFn = dir ?? _defaultDir;

  static RecordingVault instance = RecordingVault();

  final SecretStore _store;
  final Future<Directory> Function() _dirFn;
  static const _indexKey = 'callrec_index';

  static Future<Directory> _defaultDir() async {
    final d = await getApplicationSupportDirectory();
    return Directory('${d.path}/call_recordings');
  }

  Future<Directory> dir() async {
    final d = await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> tmpDir() async {
    final d = Directory('${(await dir()).path}/tmp');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Uint8List _rand(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  Future<List<SavedRecording>> list() async {
    try {
      final raw = await _store.read(_indexKey);
      if (raw == null || raw.isEmpty) return [];
      final l = jsonDecode(raw) as List;
      return [
        for (final e in l)
          if (e is Map) SavedRecording.fromJson(e.cast<String, dynamic>())
      ]..sort((a, b) => b.at.compareTo(a.at));
    } catch (e) {
      callLog('recvault#list', e);
      return [];
    }
  }

  Future<void> _saveIndex(List<SavedRecording> l) => _store.write(
      _indexKey, jsonEncode([for (final r in l) r.toJson()]));

  /// Encrypt the raw part files of one consented recording and drop them.
  Future<SavedRecording?> save({
    required List<String> rawFiles,
    required String title,
    required DateTime startedAt,
    required Duration length,
    required List<String> people,
  }) async {
    final id = '${startedAt.millisecondsSinceEpoch}${_rand(2)[0]}';
    final key = _rand(32);
    final parts = <String>[];
    try {
      final d = await dir();
      var n = 0;
      for (final p in rawFiles) {
        final f = File(p);
        if (!await f.exists() || await f.length() == 0) continue;
        final plain = await f.readAsBytes();
        final nonce = _rand(12);
        final out = await compute(_seal, [key, nonce, plain, '$id/$n']);
        final name = '$id.$n.enc';
        await File('${d.path}/$name').writeAsBytes(out, flush: true);
        parts.add(name);
        n++;
      }
    } catch (e) {
      callLog('recvault#save', e);
    } finally {
      for (final p in rawFiles) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    if (parts.isEmpty) return null;
    if (!await _store.write('callrec_$id', base64Encode(key))) return null;
    final rec = SavedRecording(
        id: id,
        title: title,
        at: startedAt,
        seconds: length.inSeconds,
        people: people,
        parts: parts);
    final l = await list();
    await _saveIndex([rec, ...l]);
    return rec;
  }

  /// Decrypt one recording into the cache (for play / share). The caller
  /// deletes the files with [wipe] when done.
  Future<List<String>> open(SavedRecording r) async {
    final k = await _store.read('callrec_${r.id}');
    if (k == null) return const [];
    final key = base64Decode(k);
    final d = await dir();
    final tmp = Directory('${(await getTemporaryDirectory()).path}/callrec');
    if (!await tmp.exists()) await tmp.create(recursive: true);
    final out = <String>[];
    for (var n = 0; n < r.parts.length; n++) {
      final blob = await File('${d.path}/${r.parts[n]}').readAsBytes();
      final plain = await compute(_open, [key, blob, '${r.id}/$n']);
      if (plain == null) continue;
      final f = File('${tmp.path}/${r.id}_$n.m4a');
      await f.writeAsBytes(plain, flush: true);
      out.add(f.path);
    }
    return out;
  }

  Future<void> wipe(List<String> files) async {
    for (final p in files) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> delete(SavedRecording r) async {
    final d = await dir();
    for (final p in r.parts) {
      try {
        final f = File('${d.path}/$p');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await _store.delete('callrec_${r.id}');
    final l = await list();
    await _saveIndex([for (final x in l) if (x.id != r.id) x]);
  }

  static Uint8List _seal(List<Object> a) {
    final key = a[0] as Uint8List, nonce = a[1] as Uint8List;
    final c = ChaCha20Poly1305.encrypt(key, nonce, a[2] as Uint8List,
        aad: utf8.encode(a[3] as String));
    return Uint8List.fromList([...nonce, ...c]);
  }

  static Uint8List? _open(List<Object> a) {
    final key = a[0] as Uint8List, blob = a[1] as Uint8List;
    if (blob.length < 13) return null;
    return ChaCha20Poly1305.decrypt(
        key, blob.sublist(0, 12), blob.sublist(12),
        aad: utf8.encode(a[2] as String));
  }
}

@immutable
class SavedRecording {
  const SavedRecording({
    required this.id,
    required this.title,
    required this.at,
    required this.seconds,
    required this.people,
    required this.parts,
  });

  factory SavedRecording.fromJson(Map<String, dynamic> j) => SavedRecording(
        id: '${j['id']}',
        title: '${j['title'] ?? ''}',
        at: DateTime.tryParse('${j['at']}') ?? DateTime(2000),
        seconds: (j['seconds'] as num?)?.toInt() ?? 0,
        people: [for (final p in (j['people'] as List? ?? const [])) '$p'],
        parts: [for (final p in (j['parts'] as List? ?? const [])) '$p'],
      );

  final String id;
  final String title;
  final DateTime at;
  final int seconds;
  final List<String> people;
  final List<String> parts;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'at': at.toIso8601String(),
        'seconds': seconds,
        'people': people,
        'parts': parts,
      };
}

/// Recording notices for the call screen.
enum RecordNotice { none, declined, paused, saved, failed, requestFailed }

/// One call's consent recording: follows the server view and drives the
/// engine. Shared by the 1:1 call ([CallController]) and group calls.
class RecordingSession extends ChangeNotifier {
  RecordingSession({
    required this.send,
    this.engine,
    RecordingVault? vault,
    this.title = '',
    this.people = const [],
    DateTime Function()? now,
  })  : _vault = vault,
        _now = now ?? DateTime.now;

  /// POST {action} to the call's record endpoint -> {"recording": view}.
  final Future<Map<String, dynamic>> Function(String action) send;

  /// null = this phone can't record (no native recorder): it may still
  /// ACCEPT someone else's request, but never request itself.
  final CallRecorderEngine? engine;
  final RecordingVault? _vault;
  final DateTime Function() _now;
  String title;
  List<String> people;

  RecordingConsent consent = const RecordingConsent();
  RecordNotice notice = RecordNotice.none;
  int noticeSeq = 0;
  bool engineRunning = false;
  bool busy = false;
  DateTime? _clipStart;
  List<String> _raw = const [];
  final List<String> log = [];
  bool _disposed = false;

  bool get canRequest => engine != null && !consent.open && !busy;

  void _notice(RecordNotice n) {
    notice = n;
    noticeSeq++;
  }

  /// A server view arrived (API answer or real-time event).
  Future<void> apply(Map<String, dynamic>? view) async {
    if (view == null || _disposed) return;
    final prev = consent;
    consent = RecordingConsent.fromJson(view);
    if (prev.status != consent.status) {
      if (consent.status == RecordStatus.declined) _notice(RecordNotice.declined);
      if (consent.status == RecordStatus.paused) _notice(RecordNotice.paused);
    }
    notifyListeners();
    await _sync();
  }

  Future<void> _sync() async {
    final want = consent.iRecord && consent.recordingNow;
    if (want && !engineRunning) {
      await _startEngine();
    } else if (!want && engineRunning) {
      await _stopEngine(save: true);
    }
  }

  Future<void> _startEngine() async {
    final e = engine;
    if (e == null) return;
    engineRunning = true;
    log.add('engine:start');
    try {
      final v = _vault ?? RecordingVault.instance;
      final dir = await v.tmpDir();
      _raw = await e.start(dir.path);
      _clipStart = _now();
    } catch (err) {
      callLog('recsession#start', err);
      engineRunning = false;
      _notice(RecordNotice.failed);
      // honest: tell the others it is NOT recording
      unawaited(_act('stop'));
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _stopEngine({required bool save}) async {
    final e = engine;
    engineRunning = false;
    log.add('engine:stop');
    if (e == null) return;
    try {
      await e.stop();
      final started = _clipStart ?? _now();
      if (save) {
        final v = _vault ?? RecordingVault.instance;
        final r = await v.save(
            rawFiles: _raw,
            title: title,
            startedAt: started,
            length: _now().difference(started),
            people: people);
        _notice(r == null ? RecordNotice.failed : RecordNotice.saved);
      }
    } catch (err) {
      callLog('recsession#stop', err);
      _notice(RecordNotice.failed);
    }
    _raw = const [];
    _clipStart = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> _act(String action) async {
    busy = true;
    if (!_disposed) notifyListeners();
    try {
      final r = await send(action);
      final v = r['recording'];
      if (v is Map) await apply(v.cast<String, dynamic>());
    } catch (e) {
      callLog('recsession#$action', e);
      _notice(RecordNotice.requestFailed);
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> request() => _act('request');
  Future<void> accept() => _act('accept');
  Future<void> decline() => _act('decline');
  Future<void> stop() => _act('stop');

  /// The call ended: finish (and keep) what was recorded with consent.
  Future<void> close() async {
    if (engineRunning) await _stopEngine(save: true);
  }

  @override
  void dispose() {
    _disposed = true;
    if (engineRunning) unawaited(_stopEngine(save: true));
    super.dispose();
  }
}
