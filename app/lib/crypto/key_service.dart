import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'e2e.dart';
import 'identity_vault.dart';

/// e2-keys (owner order 22 Oct, item 1) — the device's PUBLIC key is
/// published to the per-user key directory (POST /circle/keys) so that every
/// accepted contact can text us immediately. Encryption is invisible
/// plumbing: nothing in here ever shows the user a key error.
///
/// When we publish:
///   * every app start (after the first frame, guarded) and at login
///     ([attach] watches AppState), not only when the My Circle hub opens;
///   * when a My Circle request is accepted ([onRequestAccepted]);
///   * when the server asks silently (FCM data `key_request`), in the
///     foreground or in the background isolate ([publishFromBackground]).
/// Every attempt retries with exponential backoff and lands in an honest
/// internal log ([KeyLog]) — never a snackbar.
///
/// The identity (X25519 key pair) lives in secure storage under
/// `circle_identity_v1` (the same slot the chat screens read). The PRIVATE
/// key never leaves the device.
const String kIdentitySlot = 'circle_identity_v1';

/// Where the identity lives (secure storage in the app, memory in tests).
abstract class IdentityStore {
  Future<IdentityKeyPair?> load();
  Future<void> save(IdentityKeyPair id);
}

class SecureIdentityStore implements IdentityStore {
  const SecureIdentityStore();

  /// Goes through [IdentityVault]: secure storage with retry + encrypted
  /// app-private fallback, never null — so a Keystore failure on ColorOS /
  /// MIUI can no longer stop the key from being published.
  @override
  Future<IdentityKeyPair?> load() => IdentityVault.instance.get();

  /// The vault already stored it (both places when possible).
  @override
  Future<void> save(IdentityKeyPair id) async {}
}

class MemoryIdentityStore implements IdentityStore {
  IdentityKeyPair? id;
  MemoryIdentityStore([this.id]);
  @override
  Future<IdentityKeyPair?> load() async => id;
  @override
  Future<void> save(IdentityKeyPair v) async => id = v;
}

/// Honest internal log of key plumbing (last [cap] entries, persisted in
/// SharedPreferences, also printed in debug builds). Not user-facing.
class KeyLog {
  KeyLog({this.cap = 40});
  final int cap;
  static const prefsKey = 'e2_key_log_v1';
  final List<String> entries = [];

  void add(String event) {
    final line = '${DateTime.now().toUtc().toIso8601String()} $event';
    entries.add(line);
    if (entries.length > cap) entries.removeRange(0, entries.length - cap);
    if (kDebugMode) debugPrint('e2-keys: $event');
    unawaited(_persist(line));
  }

  Future<void> _persist(String line) async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = p.getStringList(prefsKey) ?? <String>[];
      l.add(line);
      await p.setStringList(
          prefsKey, l.length > cap ? l.sublist(l.length - cap) : l);
    } catch (_) {}
  }
}

typedef KeyPost = Future<Map<String, dynamic>> Function(
    String path, Map<String, dynamic> body);

/// One publish loop with retry + backoff.
class KeyService {
  KeyService({
    IdentityStore? store,
    Future<void> Function(Duration)? sleep,
    List<Duration>? backoff,
    KeyLog? log,
  })  : store = store ?? const SecureIdentityStore(),
        sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        backoff = backoff ?? defaultBackoff,
        log = log ?? KeyLog();

  static KeyService instance = KeyService();

  /// 2 s, 5 s, 15 s, 30 s, 1 min, 2 min, 5 min, 10 min — then give up for
  /// this trigger (the next app start / request / key_request retries).
  static const defaultBackoff = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  final IdentityStore store;
  final Future<void> Function(Duration) sleep;
  final List<Duration> backoff;
  final KeyLog log;
  final SoftwareE2E _e2e = SoftwareE2E();

  Future<bool>? _inflight;
  DateTime? lastPublishedAt;
  String? lastPublishedKeyId;

  /// Live `key.published` events from the shared real-time loop
  /// ({chat: "member:<id>", user_id, key_id, changed}).
  final StreamController<Map<String, dynamic>> keyEvents =
      StreamController<Map<String, dynamic>>.broadcast();

  /// The stored identity, created (and stored) on first use. Re-reads after
  /// creating so a parallel isolate's identity wins (never two keys).
  Future<IdentityKeyPair> identity() async {
    final have = await store.load();
    if (have != null) return have;
    final id = _e2e.generateIdentity();
    await store.save(id);
    log.add('identity created kid=${id.keyId}');
    return (await store.load()) ?? id;
  }

  /// Publish the PUBLIC key. Concurrent callers share one loop. Returns true
  /// once the server accepted it, false after the backoff ran out.
  Future<bool> publish(KeyPost post, {required String reason}) {
    final f = _inflight;
    if (f != null) return f;
    final run = _run(post, reason);
    _inflight = run;
    run.whenComplete(() => _inflight = null);
    return run;
  }

  Future<bool> _run(KeyPost post, String reason) async {
    for (var attempt = 0;; attempt++) {
      try {
        final id = await identity();
        await post('/circle/keys', {
          'public_key': id.publicKeyB64,
          'key_id': id.keyId,
          'scheme': _e2e.scheme,
        });
        lastPublishedAt = DateTime.now();
        lastPublishedKeyId = id.keyId;
        log.add('published reason=$reason attempt=${attempt + 1}');
        return true;
      } catch (e) {
        log.add('publish failed reason=$reason attempt=${attempt + 1} '
            'error=${e.runtimeType}');
        if (attempt >= backoff.length) {
          log.add('publish gave up reason=$reason (next trigger retries)');
          return false;
        }
        await sleep(backoff[attempt]);
      }
    }
  }

  // ------------------------------------------------------------ triggers
  Object? _publishedFor;
  bool _sawFirst = false;

  /// App start + login: call once after the first frame. [isReady] and
  /// [userId] read AppState; [listen] subscribes to its changes.
  void attach({
    required bool Function() isReady,
    required Object? Function() userId,
    required KeyPost Function() post,
    required void Function(VoidCallback) listen,
  }) {
    void check() {
      try {
        if (!isReady()) {
          _publishedFor = null; // logged out -> next login publishes again
          return;
        }
        final uid = userId();
        if (uid == null || uid == _publishedFor) return;
        _publishedFor = uid;
        final reason = _sawFirst ? 'login' : 'start';
        _sawFirst = true;
        unawaited(publish(post(), reason: reason));
      } catch (_) {}
    }

    listen(check);
    check();
  }

  /// A My Circle request was accepted (either side) — publish now so the
  /// peer can encrypt to us at once.
  Future<bool> onRequestAccepted(KeyPost post) =>
      publish(post, reason: 'accept');

  /// The server asked (silent FCM `key_request`) while the app is open.
  Future<bool> onKeyRequest(KeyPost post) => publish(post, reason: 'request');

  /// Feed one real-time event (topic `key.published`).
  void onRealtime(String topic, Map<String, dynamic> payload) {
    if (topic != 'key.published') return;
    log.add('peer key published chat=${payload['chat']}');
    keyEvents.add(payload);
  }

  // ------------------------------------------------------------ background
  /// FCM background isolate: no AppState, own HTTP + secure storage. Short
  /// backoff (the isolate is time-boxed by Android).
  static Future<bool> publishFromBackground(
      {String? token, http.Client? client}) async {
    try {
      const s = FlutterSecureStorage();
      token ??= await s.read(key: 'token');
      if (token == null || token.isEmpty) return false;
      final c = client ?? http.Client();
      final svc = KeyService(backoff: const [
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 10),
      ]);
      return await svc.publish(
          (path, body) => httpPost(c, token!, path, body),
          reason: 'request-bg');
    } catch (_) {
      return false;
    }
  }
}

/// Minimal authenticated JSON POST for isolates without an ApiClient.
Future<Map<String, dynamic>> httpPost(http.Client c, String token, String path,
    Map<String, dynamic> body) async {
  final r = await c
      .post(AppConfig.api(path),
          headers: {
            'Authorization': 'Token $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body))
      .timeout(const Duration(seconds: 15));
  if (r.statusCode < 200 || r.statusCode >= 300) {
    throw StateError('http ${r.statusCode}');
  }
  return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> httpGet(
    http.Client c, String token, String path) async {
  final r = await c.get(AppConfig.api(path), headers: {
    'Authorization': 'Token $token',
  }).timeout(const Duration(seconds: 15));
  if (r.statusCode < 200 || r.statusCode >= 300) {
    throw StateError('http ${r.statusCode}');
  }
  return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
}

/// Per-chat memory of the peer's key: detects a CHANGE (reinstall / new
/// phone -> WhatsApp-style "security code changed" note in that chat) and
/// keeps older keys so history from before the change still decrypts here.
class PeerKeyBook {
  PeerKeyBook._();
  static final PeerKeyBook instance = PeerKeyBook._();
  static const _keysKey = 'e2_peer_keys_v1';
  static const _notesKey = 'e2_key_notes_v1';
  static const _maxHistory = 5;

  Future<SharedPreferences> _p() async {
    final p = await SharedPreferences.getInstance();
    try {
      await p.reload();
    } catch (_) {}
    return p;
  }

  Map<String, dynamic> _map(SharedPreferences p, String k) {
    try {
      final raw = p.getString(k);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  /// Record [pub] as the current key of [chatKey]. True when it replaced a
  /// DIFFERENT earlier key (a change note is stored for that chat).
  Future<bool> observe(String chatKey, String pub, {DateTime? at}) async {
    if (pub.isEmpty) return false;
    try {
      final p = await _p();
      final keys = _map(p, _keysKey);
      final cur = (keys[chatKey] as Map?)?.cast<String, dynamic>();
      final prev = '${cur?['pub'] ?? ''}';
      if (prev == pub) return false;
      final hist = [
        ...((cur?['history'] as List?) ?? const []).map((e) => '$e'),
        if (prev.isNotEmpty) prev,
      ];
      keys[chatKey] = {
        'pub': pub,
        'history': hist.length > _maxHistory
            ? hist.sublist(hist.length - _maxHistory)
            : hist,
      };
      await p.setString(_keysKey, jsonEncode(keys));
      if (prev.isEmpty) return false;
      final notes = _map(p, _notesKey);
      final list = [
        ...((notes[chatKey] as List?) ?? const []).map((e) => '$e'),
        (at ?? DateTime.now()).toUtc().toIso8601String(),
      ];
      notes[chatKey] = list.length > 20 ? list.sublist(list.length - 20) : list;
      await p.setString(_notesKey, jsonEncode(notes));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Earlier keys of this chat's peer (newest last), for decrypting history.
  Future<List<String>> history(String chatKey) async {
    try {
      final keys = _map(await _p(), _keysKey);
      final cur = (keys[chatKey] as Map?)?.cast<String, dynamic>();
      return ((cur?['history'] as List?) ?? const []).map((e) => '$e').toList();
    } catch (_) {
      return const [];
    }
  }

  /// When the peer's security code changed in this chat (oldest first).
  Future<List<DateTime>> notes(String chatKey) async {
    try {
      final notes = _map(await _p(), _notesKey);
      return ((notes[chatKey] as List?) ?? const [])
          .map((e) => DateTime.tryParse('$e')?.toLocal())
          .whereType<DateTime>()
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
