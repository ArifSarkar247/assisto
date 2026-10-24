import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'e2e.dart';
import 'group_decrypt.dart';
import 'identity_vault.dart';
import 'key_service.dart' show KeyLog;
import 'plain_cache.dart';
import 'ring_decrypt.dart';

/// e2e-recover items 1 + 2 — PEER-ASSISTED HISTORY RESEND.
///
/// SERVE (this phone helps a contact): when a contact's key changed (or they
/// asked — a Signal-style retry receipt), the server lists a request for us
/// (GET circle/e2/resend). We open every message of that 1:1 chat we can
/// (both directions: our key ring x their old public keys), re-encrypt it to
/// their NEW key and upload it as a per-recipient REPLACEMENT copy keyed by
/// the original message id (POST circle/<chat>/e2/copies). The original
/// ciphertext stays untouched on the server; their phone prefers a copy
/// only when the original does not open. Same send time and sender — the
/// copy is never marked edited. Media: the E2E descriptor (file key) is
/// re-shared, the encrypted file itself is not re-uploaded.
///
/// ASK (this phone needs help): messages we cannot open are reported to the
/// sender's phone (POST circle/<chat>/e2/resend), rate-limited per chat.
///
/// GROUPS (e2e-groups): the same for group chats. A group message is
/// sealed per member, so when a co-member's key changed (or they asked) this
/// phone opens ITS OWN per-member copy (or, for its own sent message, any
/// recipient's), re-encrypts it to the co-member's NEW key and uploads it
/// (POST circle/groups/<g>/e2/copies). The server keeps the FIRST copy per
/// (message, member), so several helpers never produce duplicates, and only
/// lists the ids still missing that this phone received.
///
/// Capped (last [maxMessages] messages / [windowDays] days), throttled,
/// idempotent (the server upserts one copy per message+recipient), single-
/// flight and crash-guarded: nothing here can throw into the app.
typedef ReshareGet = Future<Map<String, dynamic>> Function(String path);
typedef ResharePost = Future<Map<String, dynamic>> Function(
    String path, Map<String, dynamic> body);

class HistoryReshare {
  HistoryReshare({IdentityVault? vault, KeyLog? log, E2E? e2e})
      : _vault = vault,
        log = log ?? KeyLog(),
        _e2e = e2e ?? SoftwareE2E();

  static HistoryReshare instance = HistoryReshare();

  static const maxMessages = 500;
  static const windowDays = 90;
  static const batch = 100;
  static const serveEvery = Duration(seconds: 90);
  static const askEvery = Duration(hours: 6);
  static const _askedKey = 'e2r_asked_v1';
  static const mediaKinds = {'photo', 'voice', 'document', 'video'};

  final IdentityVault? _vault;
  IdentityVault get vault => _vault ?? IdentityVault.instance;
  final KeyLog log;
  final E2E _e2e;

  ReshareGet? get;
  ResharePost? post;

  /// Clock (tests).
  DateTime Function() now = DateTime.now;

  Future<int>? _serving;
  DateTime? _lastServe;
  int served = 0;

  // ================================================================ serve
  /// Serve every waiting request. Returns the number of copies uploaded.
  Future<int> serve({bool force = false}) {
    final f = _serving;
    if (f != null) return f;
    final last = _lastServe;
    if (!force && last != null && now().difference(last) < serveEvery) {
      return Future.value(0);
    }
    _lastServe = now();
    final run = _serveAll().catchError((Object e) {
      log.add('reshare failed ${e.runtimeType}');
      return 0;
    });
    _serving = run;
    run.whenComplete(() => _serving = null);
    return run;
  }

  Future<int> _serveAll() async {
    final g = get, p = post;
    if (g == null || p == null) return 0;
    final r = await g('/circle/e2/resend').timeout(const Duration(seconds: 15));
    var total = 0;
    for (final req in ((r['results'] as List?) ?? const [])) {
      if (req is! Map) continue;
      try {
        total += await _serveOne(req.cast<String, dynamic>(), g, p);
      } catch (e) {
        log.add('reshare chat failed ${e.runtimeType}');
      }
    }
    for (final req in ((r['groups'] as List?) ?? const [])) {
      if (req is! Map) continue;
      try {
        total += await _serveGroup(req.cast<String, dynamic>(), g, p);
      } catch (e) {
        log.add('reshare group failed ${e.runtimeType}');
      }
    }
    served += total;
    return total;
  }

  Future<int> _serveOne(
      Map<String, dynamic> req, ReshareGet g, ResharePost p) async {
    final chatId = (req['chat_id'] as num?)?.toInt();
    final forKid = '${req['key_id'] ?? ''}';
    final newPub = _b64('${req['public_key'] ?? ''}');
    if (chatId == null || forKid.isEmpty || newPub == null) return 0;
    final whole = req['whole'] == true;
    final wanted = <String>{
      for (final i in (req['message_ids'] as List? ?? const [])) '$i'
    };
    final since = DateTime.tryParse('${req['since'] ?? ''}') ??
        now().subtract(const Duration(days: windowDays));

    final ring = await vault.ring();
    if (ring.isEmpty) return 0;
    final me = ring.first;
    // The contact's keys this phone may need to OPEN old messages: their
    // earlier keys (server history) + the current one.
    final keys = await g('/circle/keys/peer/$chatId')
        .timeout(const Duration(seconds: 10));
    final peerKeys = RingDecrypt.keys([
      for (final h in (keys['history'] as List? ?? const []))
        if (h is Map) _b64('${h['public_key'] ?? ''}'),
      _b64('${keys['public_key'] ?? ''}'),
    ]);

    final envs = await _history(
        g, '/circle/$chatId/messages', since, whole ? null : wanted);
    final copies = <Map<String, dynamic>>[];
    var n = 0;
    for (final env in envs) {
      if (++n % 20 == 0) await Future<void>.delayed(Duration.zero); // no jank
      final id = '${env['id'] ?? ''}';
      if (!whole && !wanted.contains(id)) continue;
      final kind = '${env['content_type'] ?? 'text'}';
      if (kind != 'text' && !mediaKinds.contains(kind)) continue;
      if ('${env['deleted'] ?? ''}' == 'everyone') continue;
      if (env['view_once'] == true) continue;
      final cipher = '${env['ciphertext'] ?? ''}';
      if (cipher.isEmpty) continue;
      final ct = Ciphertext(
        scheme: '${env['scheme'] ?? _e2e.scheme}',
        ciphertextB64: cipher,
        nonceB64: '${env['nonce'] ?? ''}',
        senderKeyId: '${env['sender_key_id'] ?? ''}',
      );
      // Already readable with their NEW key (sent after the change): skip.
      if (RingDecrypt.open(ring: ring, peerKeys: [newPub], ct: ct) != null) {
        continue;
      }
      final pt = RingDecrypt.open(ring: ring, peerKeys: peerKeys, ct: ct) ??
          PlainCache.instance.get(id);
      if (pt == null) continue;
      final out =
          _e2e.encrypt(self: me, recipientPublicKey: newPub, plaintext: pt);
      copies.add({
        'message_id': int.tryParse(id) ?? id,
        'ciphertext': out.ciphertextB64,
        'nonce': out.nonceB64,
        'sender_key_id': out.senderKeyId,
        'scheme': out.scheme,
      });
    }
    var stored = 0;
    for (var i = 0; i < copies.length || i == 0; i += batch) {
      final part = copies.sublist(i, (i + batch).clamp(0, copies.length));
      final last = i + batch >= copies.length;
      final r = await p('/circle/$chatId/e2/copies', {
        'for_key_id': forKid,
        'copies': part,
        'done': last,
      }).timeout(const Duration(seconds: 20));
      stored += (r['stored'] as num?)?.toInt() ?? 0;
      if (last) break;
    }
    log.add('reshare chat=$chatId copies=$stored');
    return stored;
  }

  /// e2e-groups: re-share the group messages the server listed (only ids
  /// still missing that THIS phone received) to the co-member's new key.
  Future<int> _serveGroup(
      Map<String, dynamic> req, ReshareGet g, ResharePost p) async {
    final gid = (req['group_id'] as num?)?.toInt();
    final forUid = (req['user_id'] as num?)?.toInt();
    final forKid = '${req['key_id'] ?? ''}';
    final newPub = _b64('${req['public_key'] ?? ''}');
    final wanted = <String>{
      for (final i in (req['message_ids'] as List? ?? const [])) '$i'
    };
    if (gid == null || forUid == null || forKid.isEmpty || newPub == null ||
        wanted.isEmpty) {
      return 0;
    }
    final since = DateTime.tryParse('${req['since'] ?? ''}') ??
        now().subtract(const Duration(days: windowDays));
    final ring = await vault.ring();
    if (ring.isEmpty) return 0;
    final me = ring.first;
    final mem = await g('/circle/groups/$gid/members')
        .timeout(const Duration(seconds: 10));
    final roster = ((mem['results'] ?? mem['members'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    var myMid = '${req['my_member_id'] ?? ''}';
    var myUid = '';
    for (final r in roster) {
      if (r['is_self'] == true) {
        myUid = '${r['user_id'] ?? ''}';
        if (myMid.isEmpty) myMid = '${r['member_id'] ?? ''}';
      }
    }
    final envs =
        await _history(g, '/circle/groups/$gid/messages', since, wanted);
    final copies = <Map<String, dynamic>>[];
    var n = 0;
    for (final env in envs) {
      if (++n % 20 == 0) await Future<void>.delayed(Duration.zero); // no jank
      final id = '${env['id'] ?? ''}';
      if (!wanted.contains(id)) continue;
      final kind = '${env['content_type'] ?? 'text'}';
      if (kind != 'text' && !mediaKinds.contains(kind)) continue;
      if ('${env['deleted'] ?? ''}' == 'everyone') continue;
      if (env['view_once'] == true) continue;
      // MY copy only (never the copy the server keeps for someone else).
      final pt = GroupDecrypt.openOriginal({...env}..remove('copy'),
              ring: ring, myMemberId: myMid, myUserId: myUid,
              roster: roster) ??
          PlainCache.instance.get(id);
      if (pt == null) continue;
      final out =
          _e2e.encrypt(self: me, recipientPublicKey: newPub, plaintext: pt);
      copies.add({
        'message_id': int.tryParse(id) ?? id,
        'ciphertext': out.ciphertextB64,
        'nonce': out.nonceB64,
        'sender_key_id': out.senderKeyId,
        'scheme': out.scheme,
      });
    }
    var stored = 0;
    for (var i = 0; i < copies.length || i == 0; i += batch) {
      final part = copies.sublist(i, (i + batch).clamp(0, copies.length));
      final last = i + batch >= copies.length;
      final r = await p('/circle/groups/$gid/e2/copies', {
        'for_user_id': forUid,
        'for_key_id': forKid,
        'copies': part,
        'done': last,
      }).timeout(const Duration(seconds: 20));
      stored += (r['stored'] as num?)?.toInt() ?? 0;
      if (last) break;
    }
    log.add('reshare group=$gid copies=$stored');
    return stored;
  }

  /// Oldest-first envelopes of the chat at [base], newest [maxMessages],
  /// back to [since] (or until every [only] id was seen).
  Future<List<Map<String, dynamic>>> _history(ReshareGet g, String base,
      DateTime since, Set<String>? only) async {
    final out = <Map<String, dynamic>>[];
    String? before;
    for (var page = 0; page < 10 && out.length < maxMessages; page++) {
      final r = await g('$base?limit=100'
              '${before == null ? '' : '&before=$before'}')
          .timeout(const Duration(seconds: 15));
      final rows = ((r['results'] ?? r['messages'] ?? const []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (rows.isEmpty) break;
      out.insertAll(0, rows);
      final oldest = rows.first;
      final at = DateTime.tryParse('${oldest['created_at'] ?? ''}');
      if (at != null && at.isBefore(since)) break;
      if (only != null &&
          only.every((id) => out.any((e) => '${e['id']}' == id))) {
        break;
      }
      if (r['has_more'] != true) break;
      before = '${oldest['id']}';
    }
    final cut = out.where((e) {
      final at = DateTime.tryParse('${e['created_at'] ?? ''}');
      return at == null || !at.isBefore(since);
    }).toList();
    return cut.length > maxMessages
        ? cut.sublist(cut.length - maxMessages)
        : cut;
  }

  static Uint8List? _b64(String s) {
    if (s.isEmpty) return null;
    try {
      final k = base64Decode(s);
      return k.length == 32 ? Uint8List.fromList(k) : null;
    } catch (_) {
      return null;
    }
  }

  // ================================================================== ask
  /// Messages of 1:1 chat [chatId] this phone cannot open: ask the other
  /// phone to re-share them to our current key. Ids already asked are not
  /// re-sent for [askEvery] (then retried — e.g. on the next app open).
  /// Returns true when a request was sent.
  Future<bool> ask(int chatId, Iterable<String> messageIds) =>
      _ask('$chatId', '/circle/$chatId/e2/resend', messageIds);

  /// e2e-groups: group messages this phone cannot open (original + copy):
  /// ask the other members' phones. Same rate limit as [ask].
  Future<bool> askGroup(int groupId, Iterable<String> messageIds) =>
      _ask('g$groupId', '/circle/groups/$groupId/e2/resend', messageIds);

  Future<bool> _ask(
      String slot, String path, Iterable<String> messageIds) async {
    final p = post;
    if (p == null) return false;
    try {
      final ids = messageIds.where((i) => int.tryParse(i) != null).toSet();
      if (ids.isEmpty) return false;
      final prefs = await SharedPreferences.getInstance();
      Map<String, dynamic> asked = {};
      try {
        asked = (jsonDecode(prefs.getString(_askedKey) ?? '{}') as Map)
            .cast<String, dynamic>();
      } catch (_) {}
      final mine = (asked[slot] as Map?)?.cast<String, dynamic>() ?? {};
      final at = DateTime.tryParse('${mine['at'] ?? ''}');
      final before = {
        for (final i in (mine['ids'] as List? ?? const [])) '$i'
      };
      final fresh = at == null || now().difference(at) >= askEvery;
      final todo = fresh ? ids : ids.difference(before);
      if (todo.isEmpty) return false;
      final list = todo.take(HistoryReshare.maxMessages).toList();
      await p(path, {
        'message_ids': [for (final i in list) int.parse(i)],
      }).timeout(const Duration(seconds: 10));
      final keep = {...(fresh ? <String>{} : before), ...list}.toList();
      asked[slot] = {
        'at': (fresh ? now() : at).toIso8601String(),
        'ids': keep.length > 1000 ? keep.sublist(keep.length - 1000) : keep,
      };
      await prefs.setString(_askedKey, jsonEncode(asked));
      log.add('reshare asked $slot n=${list.length}');
      return true;
    } catch (e) {
      log.add('reshare ask failed ${e.runtimeType}');
      return false;
    }
  }

  /// TESTS
  void resetForTests() {
    _serving = null;
    _lastServe = null;
    served = 0;
    get = null;
    post = null;
    now = DateTime.now;
  }
}
