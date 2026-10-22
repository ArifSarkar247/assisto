import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/e2e.dart';
import '../crypto/key_service.dart';

/// e2-keys — the persistent LOCAL outbox (owner PRODUCT RULE: the sender is
/// never blocked by encryption).
///
/// When a 1:1 peer has no published key yet, the message is NOT refused and
/// no snackbar is shown: it is stored here (plaintext stays on THIS device
/// only, like any chat history), drawn with the clock icon, and the server
/// is asked (GET /circle/keys/peer/<id> queues a silent FCM `key_request` to
/// the peer). As soon as the key arrives — `key.published` on the real-time
/// loop, a silent `key_ready` push (also in the background isolate), app
/// resume, chat open or the backoff timer — every queued message of that chat
/// is encrypted ON DEVICE and sent with its original client_msg_id (the
/// server dedupes, so a flush racing between isolates never doubles a
/// message). Survives app restarts (SharedPreferences, re-read before every
/// use so the background isolate's writes are seen).
class OutboxItem {
  final String id; // client_msg_id
  final String chatKind; // 'member'
  final int chatId; // MY edge id for the peer
  final String text;
  final String? replyTo;
  final bool forwarded;
  final int forwardHops;
  final DateTime at;

  const OutboxItem({
    required this.id,
    required this.chatId,
    required this.text,
    required this.at,
    this.chatKind = 'member',
    this.replyTo,
    this.forwarded = false,
    this.forwardHops = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': chatKind,
        'chat': chatId,
        'text': text,
        if (replyTo != null) 'reply_to': replyTo,
        if (forwarded) 'fwd': true,
        if (forwardHops > 0) 'hops': forwardHops,
        'at': at.toUtc().toIso8601String(),
      };

  static OutboxItem? fromJson(Map<String, dynamic> j) {
    final id = '${j['id'] ?? ''}';
    final chat = j['chat'] is int ? j['chat'] as int : int.tryParse('${j['chat']}');
    if (id.isEmpty || chat == null) return null;
    return OutboxItem(
      id: id,
      chatKind: '${j['kind'] ?? 'member'}',
      chatId: chat,
      text: '${j['text'] ?? ''}',
      replyTo: j['reply_to'] == null ? null : '${j['reply_to']}',
      forwarded: j['fwd'] == true,
      forwardHops: (j['hops'] as int?) ?? 0,
      at: DateTime.tryParse('${j['at'] ?? ''}')?.toLocal() ?? DateTime.now(),
    );
  }
}

/// Storage seam (SharedPreferences in the app; memory in tests).
abstract class OutboxStore {
  Future<List<Map<String, dynamic>>> load();
  Future<void> save(List<Map<String, dynamic>> rows);
}

class PrefsOutboxStore implements OutboxStore {
  const PrefsOutboxStore();
  static const key = 'e2_outbox_v1';

  @override
  Future<List<Map<String, dynamic>>> load() async {
    final p = await SharedPreferences.getInstance();
    try {
      await p.reload(); // see writes from the other isolate
    } catch (_) {}
    final raw = p.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
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

/// Network seam: the peer key lookup (also queues the silent key request)
/// and the 1:1 send.
abstract class OutboxTransport {
  /// GET /circle/keys/peer/<memberId> -> {public_key, key_id, ...}
  Future<Map<String, dynamic>> peerKey(int memberId);

  /// POST /circle/<memberId>/messages
  Future<Map<String, dynamic>> send(int memberId, Map<String, dynamic> env);
}

class FnOutboxTransport implements OutboxTransport {
  FnOutboxTransport({required this.get, required this.post});
  final Future<Map<String, dynamic>> Function(String path) get;
  final Future<Map<String, dynamic>> Function(String path, Map<String, dynamic> body)
      post;

  @override
  Future<Map<String, dynamic>> peerKey(int memberId) =>
      get('/circle/keys/peer/$memberId');

  @override
  Future<Map<String, dynamic>> send(int memberId, Map<String, dynamic> env) =>
      post('/circle/$memberId/messages', env);
}

class FlushResult {
  final List<String> sent;
  final int waiting;
  const FlushResult(this.sent, this.waiting);
}

class Outbox {
  Outbox({OutboxStore? store}) : store = store ?? const PrefsOutboxStore();

  static Outbox instance = Outbox();

  final OutboxStore store;
  final SoftwareE2E _e2e = SoftwareE2E();

  /// Bumped on every change (screens re-read their chat's queued items).
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// ids sent by the LAST flushes (screens swap the clock echo for the
  /// server copy on their next poll).
  final List<String> recentlySent = [];

  Future<List<OutboxItem>> all() async {
    try {
      return (await store.load())
          .map(OutboxItem.fromJson)
          .whereType<OutboxItem>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<OutboxItem>> forChat(String kind, int chatId) async =>
      (await all()).where((i) => i.chatKind == kind && i.chatId == chatId).toList();

  Future<void> add(OutboxItem item) async {
    final rows = await store.load();
    rows.removeWhere((r) => '${r['id']}' == item.id);
    rows.add(item.toJson());
    await store.save(rows);
    changes.value++;
  }

  Future<void> remove(Iterable<String> ids) async {
    final set = ids.toSet();
    if (set.isEmpty) return;
    final rows = await store.load();
    final before = rows.length;
    rows.removeWhere((r) => set.contains('${r['id']}'));
    if (rows.length != before) {
      await store.save(rows);
      changes.value++;
    }
  }

  bool _flushing = false;

  /// Encrypt + send every queued item whose peer key is now available.
  /// [onlyChat] limits it to one chat. Never throws.
  Future<FlushResult> flush({
    required OutboxTransport transport,
    required Future<IdentityKeyPair?> Function() identity,
    int? onlyChat,
    void Function(String)? log,
  }) async {
    if (_flushing) return const FlushResult([], -1);
    _flushing = true;
    final sent = <String>[];
    var waiting = 0;
    try {
      final items = (await all())
          .where((i) => i.chatKind == 'member')
          .where((i) => onlyChat == null || i.chatId == onlyChat)
          .toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (items.isEmpty) return const FlushResult([], 0);
      final me = await identity();
      if (me == null) return FlushResult(const [], items.length);
      final byChat = <int, List<OutboxItem>>{};
      for (final i in items) {
        byChat.putIfAbsent(i.chatId, () => []).add(i);
      }
      for (final e in byChat.entries) {
        Uint8List? pub;
        try {
          final k = await transport.peerKey(e.key);
          final b64 = '${k['public_key'] ?? ''}';
          if (b64.isNotEmpty) pub = Uint8List.fromList(base64Decode(b64));
        } catch (_) {
          pub = null;
        }
        if (pub == null) {
          waiting += e.value.length;
          continue;
        }
        for (final i in e.value) {
          try {
            final ct = _e2e.encrypt(
                self: me, recipientPublicKey: pub, plaintext: i.text);
            await transport.send(e.key, {
              'content_type': 'text',
              'client_msg_id': i.id,
              if (i.replyTo != null) 'reply_to': i.replyTo,
              if (i.forwarded) 'forwarded': true,
              if (i.forwardHops > 0) 'forward_hops': i.forwardHops,
              ...ct.toEnvelopeFields(),
            });
            sent.add(i.id);
          } catch (_) {
            waiting += 1; // network: keep it, the next trigger retries
            break; // keep order within the chat
          }
        }
      }
      await remove(sent);
      if (sent.isNotEmpty) {
        recentlySent
          ..addAll(sent)
          ..removeRange(0, recentlySent.length > 50 ? recentlySent.length - 50 : 0);
        log?.call('outbox sent=${sent.length} waiting=$waiting');
      }
      return FlushResult(sent, waiting);
    } catch (_) {
      return FlushResult(sent, waiting);
    } finally {
      _flushing = false;
    }
  }

  // ------------------------------------------------------------ driver
  Timer? _timer;
  int _step = 0;
  StreamSubscription<Map<String, dynamic>>? _sub;
  OutboxTransport? _transport;
  Future<IdentityKeyPair?> Function()? _identity;

  /// Retry cadence while something is queued: 10 s, 20 s, 40 s, 80 s, then
  /// every 3 min (a key_ready push / key.published event flushes sooner).
  static const retry = <Duration>[
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 80),
    Duration(minutes: 3),
  ];

  /// Main isolate: wire the flush triggers once (after login).
  void start({
    required OutboxTransport transport,
    required Future<IdentityKeyPair?> Function() identity,
    Stream<Map<String, dynamic>>? keyEvents,
  }) {
    _transport = transport;
    _identity = identity;
    _sub?.cancel();
    _sub = keyEvents?.listen((ev) {
      final chat = '${ev['chat'] ?? ''}';
      final id = chat.startsWith('member:') ? int.tryParse(chat.substring(7)) : null;
      unawaited(kick(onlyChat: id));
    });
    unawaited(kick());
  }

  /// Flush now (chat open, app resume, key event, key_ready push) and keep
  /// the retry timer running while items still wait.
  Future<FlushResult> kick({int? onlyChat}) async {
    final t = _transport, id = _identity;
    if (t == null || id == null) return const FlushResult([], 0);
    final r = await flush(transport: t, identity: id, onlyChat: onlyChat,
        log: KeyService.instance.log.add);
    if (r.sent.isNotEmpty) _step = 0;
    final left = (await all()).length;
    _timer?.cancel();
    if (left > 0) {
      final d = retry[_step.clamp(0, retry.length - 1)];
      _step++;
      _timer = Timer(d, () => unawaited(kick()));
    } else {
      _step = 0;
    }
    return r;
  }

  @visibleForTesting
  void stop() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
    _transport = null;
    _identity = null;
  }

  /// FCM background isolate (`key_ready`): own HTTP + secure storage.
  static Future<int> flushFromBackground({int? chatId, String? token}) async {
    try {
      const store = SecureIdentityStore();
      final svc = KeyService(store: store);
      token ??= await _readToken();
      if (token == null || token.isEmpty) return 0;
      final c = http.Client();
      final tok = token;
      final r = await Outbox().flush(
        transport: FnOutboxTransport(
            get: (p) => httpGet(c, tok, p),
            post: (p, b) => httpPost(c, tok, p, b)),
        identity: () async => store.load(),
        onlyChat: chatId,
        log: svc.log.add,
      );
      return r.sent.length;
    } catch (_) {
      return 0;
    }
  }

  static Future<String?> _readToken() async {
    try {
      return await const FlutterSecureStorage().read(key: 'token');
    } catch (_) {
      return null;
    }
  }
}
