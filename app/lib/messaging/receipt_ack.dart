import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../security/secret_store.dart';

/// x2-ticks — DELIVERED acks from THIS phone, from any isolate.
///
/// WhatsApp rule: ✓✓ the moment the message reaches the recipient's phone —
/// app open, in the background or killed. Every path that learns "a message
/// is on this phone" calls [delivered] with its id:
///   * the FCM background isolate (data-only `message` / silent `msg_sync`
///     push) — FIRST thing, before it even pulls / decrypts, using the auth
///     token stored by the app (SecretStore 'token');
///   * the UI isolate's foreground push handler;
///   * the realtime `msg.new` event when the app is open.
/// One tiny request: POST /circle/receipts {delivered:[ids]}. The server
/// pushes a `receipt.update` realtime event to the SENDER, so their tick turns
/// ✓✓ without reloading the chat.
///
/// OFFLINE: when the request fails (no network, timeout, server error) the
/// ids are queued in SharedPreferences ([queueKey], newest [maxQueue] kept)
/// and flushed with the next ack, on app start / resume ([flush]).
class ReceiptAck {
  ReceiptAck({
    Future<String?> Function()? token,
    http.Client? client,
    this.lang = 'bn',
    this.timeout = const Duration(seconds: 10),
  })  : _token = token ?? storedToken,
        _client = client;

  static const queueKey = 'x2_ack_queue_v1';
  static const maxQueue = 500;

  final Future<String?> Function() _token;
  final http.Client? _client;
  final String lang;
  final Duration timeout;


  /// The token the app stored at sign-in (AppState writes key 'token').
  static Future<String?> storedToken() async {
    try {
      return await SecretStore.instance.read('token');
    } catch (_) {
      return null;
    }
  }

  /// Ack [ids] (+ anything queued). [sync] also asks the server to mark
  /// everything addressed to me delivered (a silent ping that may have
  /// collapsed several messages). Returns true when the server accepted.
  Future<bool> delivered(Iterable<int> ids, {bool sync = false}) async {
    final fresh = ids.where((i) => i > 0).toList();
    List<int> all;
    try {
      all = {...await _queue(), ...fresh}.toList();
    } catch (_) {
      all = fresh;
    }
    if (all.isEmpty && !sync) return true;
    String? tok;
    try {
      tok = await _token();
    } catch (_) {
      tok = null;
    }
    if (tok == null || tok.isEmpty) {
      await _save(all);
      return false;
    }
    final c = _client ?? http.Client();
    try {
      if (all.isNotEmpty) {
        final batch = all.length > maxQueue
            ? all.sublist(all.length - maxQueue)
            : all;
        final r = await c
            .post(AppConfig.api('/circle/receipts'),
                headers: _headers(tok),
                body: jsonEncode({'delivered': batch}))
            .timeout(timeout);
        if (r.statusCode < 200 || r.statusCode >= 300) {
          throw StateError('http ${r.statusCode}');
        }
      }
      await _save(const []);
      if (sync) {
        try {
          await c
              .post(AppConfig.api('/circle/receipts/sync'),
                  headers: _headers(tok), body: '{}')
              .timeout(timeout);
        } catch (_) {}
      }
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('x2 ack queued: $e');
      await _save(all);
      return false;
    } finally {
      if (_client == null) c.close();
    }
  }

  /// Send whatever is queued (app start / resume / network back).
  Future<bool> flush() async {
    final q = await _queue();
    if (q.isEmpty) return true;
    return delivered(const []);
  }

  Map<String, String> _headers(String tok) => {
        'Authorization': 'Token $tok',
        'Content-Type': 'application/json',
        'Accept-Language': lang,
      };

  static Future<List<int>> _queue() async {
    try {
      final p = await SharedPreferences.getInstance();
      // another isolate may have written it
      await p.reload();
      return (p.getStringList(queueKey) ?? const [])
          .map(int.tryParse)
          .whereType<int>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<int> ids) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (ids.isEmpty) {
        await p.remove(queueKey);
        return;
      }
      final keep =
          ids.length > maxQueue ? ids.sublist(ids.length - maxQueue) : ids;
      await p.setStringList(queueKey, [for (final i in keep) '$i']);
    } catch (_) {}
  }

  @visibleForTesting
  static Future<List<int>> queued() => _queue();
}

/// Kinds whose arrival means "a message is on this phone".
const kX2AckKinds = {'message', 'msg_sync'};

/// x2-ticks — the FIRST step of every message push (background isolate AND
/// foreground): ack DELIVERED by the push's message id, before any pull /
/// decrypt / drawing can fail. Returns true for the SILENT `msg_sync` ping
/// (muted chat / notifications off): the caller draws nothing.
Future<bool> ackPushDelivery(Map<String, dynamic> data,
    {ReceiptAck? ack}) async {
  final kind = '${data['kind'] ?? ''}'.trim();
  if (!kX2AckKinds.contains(kind)) return false;
  final silent = kind == 'msg_sync';
  try {
    final id = int.tryParse('${data['message_id'] ?? ''}'.trim());
    final lang = '${data['lang'] ?? ''}' == 'en' ? 'en' : 'bn';
    final a = ack ?? ReceiptAck(lang: lang);
    await a.delivered([if (id != null) id], sync: silent);
  } catch (_) {}
  return silent;
}
