import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../business_khata_api.dart';
import 'error_kind.dart';

/// ledger100 — OFFLINE khata entry (TallyKhata lost its 1-star war here).
///
/// Every new entry / payment / edit goes into a persistent LOCAL queue first
/// (SharedPreferences, so it survives an app restart) and is then synced:
/// right away when online, else on the next screen open / app resume /
/// pull-to-refresh / "Sync now".
///
/// Safety rules:
/// * each queued entry carries a `client_id` minted ONCE on the phone; the
///   server books a client_id at most once per customer, so a retry after a
///   dropped connection can never double-count (it answers duplicate:true);
/// * an edit carries the entry `version` the phone saw; if the server row
///   changed meanwhile it answers 409 conflict and the op is parked as
///   "conflict" for the owner to look at — never a silent overwrite;
/// * balances are never computed on the phone as truth: the server
///   recomputes them from the rows; the app only shows a "pending" estimate;
/// * no internet / a 5xx keep the op PENDING; a 4xx refusal (validation,
///   access) parks it as FAILED with the server's sentence, never retried
///   forever, and the owner can discard it.
///
/// Also keeps the last good party list + statement per customer so the
/// khata opens offline (marked "saved copy").
class KhataOp {
  final String cid; // client_id
  final int bizId;
  final int partyId;
  final String partyName;
  final String book; // customer | supplier
  final String kind; // entry | payment | edit
  final String direction; // gave | got  (entry only; payment derives it)
  final int amountPoisha;
  final String note;
  final String atIso;
  final int? entryId; // edit only
  final int? baseVersion; // edit only
  final DateTime createdAt;
  final String state; // pending | failed | conflict
  final String error; // server sentence for failed / conflict
  final int attempts;

  const KhataOp({
    required this.cid,
    required this.bizId,
    required this.partyId,
    required this.partyName,
    required this.book,
    required this.kind,
    required this.amountPoisha,
    required this.atIso,
    required this.createdAt,
    this.direction = '',
    this.note = '',
    this.entryId,
    this.baseVersion,
    this.state = 'pending',
    this.error = '',
    this.attempts = 0,
  });

  bool get isPending => state == 'pending';

  /// Signed effect on the party balance (same rule as the server's
  /// khata._signed) — only for the "pending" estimate shown in the UI.
  int get signedDelta {
    if (kind == 'edit') return 0; // shown as "edit pending", no estimate
    final dir = kind == 'payment'
        ? (book == 'customer' ? 'got' : 'gave')
        : direction;
    final up = book == 'customer' ? dir == 'gave' : dir == 'got';
    return up ? amountPoisha : -amountPoisha;
  }

  KhataOp copyWith({String? state, String? error, int? attempts}) => KhataOp(
        cid: cid,
        bizId: bizId,
        partyId: partyId,
        partyName: partyName,
        book: book,
        kind: kind,
        direction: direction,
        amountPoisha: amountPoisha,
        note: note,
        atIso: atIso,
        entryId: entryId,
        baseVersion: baseVersion,
        createdAt: createdAt,
        state: state ?? this.state,
        error: error ?? this.error,
        attempts: attempts ?? this.attempts,
      );

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'biz': bizId,
        'party': partyId,
        'pname': partyName,
        'book': book,
        'kind': kind,
        'dir': direction,
        'amt': amountPoisha,
        'note': note,
        'at': atIso,
        if (entryId != null) 'eid': entryId,
        if (baseVersion != null) 'ver': baseVersion,
        'created': createdAt.toUtc().toIso8601String(),
        'state': state,
        'err': error,
        'tries': attempts,
      };

  static KhataOp? fromJson(Map<String, dynamic> j) {
    int? i(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');
    final cid = '${j['cid'] ?? ''}';
    final party = i(j['party']);
    final amt = i(j['amt']);
    if (cid.isEmpty || party == null || amt == null) return null;
    return KhataOp(
      cid: cid,
      bizId: i(j['biz']) ?? 0,
      partyId: party,
      partyName: '${j['pname'] ?? ''}',
      book: '${j['book'] ?? 'customer'}',
      kind: '${j['kind'] ?? 'entry'}',
      direction: '${j['dir'] ?? ''}',
      amountPoisha: amt,
      note: '${j['note'] ?? ''}',
      atIso: '${j['at'] ?? ''}',
      entryId: i(j['eid']),
      baseVersion: i(j['ver']),
      createdAt:
          DateTime.tryParse('${j['created'] ?? ''}')?.toLocal() ?? DateTime.now(),
      state: '${j['state'] ?? 'pending'}',
      error: '${j['err'] ?? ''}',
      attempts: i(j['tries']) ?? 0,
    );
  }
}

/// What one sync pass did.
class KhataSyncResult {
  final int synced;
  final int failed;
  final int pending;
  final bool offline;
  const KhataSyncResult(
      {this.synced = 0, this.failed = 0, this.pending = 0, this.offline = false});
}

class KhataOffline {
  KhataOffline._();

  static const _qKey = 'khata_outbox_v1';
  static const _cachePrefix = 'khata_cache_v1:';
  static const requestTimeout = Duration(seconds: 15);

  /// Bumped after every queue change so open screens can redraw marks.
  static final StreamController<void> _changes =
      StreamController<void>.broadcast();
  static Stream<void> get changes => _changes.stream;

  static final Random _rng = Random.secure();

  /// A client id the server accepts ([A-Za-z0-9_.:-]{6,64}), unique per op.
  static String newClientId() {
    final r = List.generate(10, (_) => _rng.nextInt(36).toRadixString(36)).join();
    return 'kx-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$r';
  }

  // ----------------------------------------------------------------- queue
  static Future<List<KhataOp>> all() async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    final raw = sp.getString(_qKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((m) => KhataOp.fromJson(m.cast<String, dynamic>()))
          .whereType<KhataOp>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<KhataOp> ops) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_qKey, jsonEncode(ops.map((o) => o.toJson()).toList()));
    _changes.add(null);
  }

  static Future<void> enqueue(KhataOp op) async {
    final ops = await all();
    if (ops.any((o) => o.cid == op.cid)) return; // idempotent locally too
    ops.add(op);
    await _save(ops);
  }

  static Future<List<KhataOp>> forParty(int partyId) async =>
      (await all()).where((o) => o.partyId == partyId).toList();

  static Future<List<KhataOp>> forBusiness(int bizId) async =>
      (await all()).where((o) => o.bizId == bizId).toList();

  /// Drop one op (the owner chose "discard" on a failed/conflict op).
  static Future<void> discard(String cid) async {
    final ops = await all();
    ops.removeWhere((o) => o.cid == cid);
    await _save(ops);
  }

  // ------------------------------------------------------------------ sync
  static Future<KhataSyncResult>? _inFlight;

  /// Sync every PENDING op, oldest first. Single-flight: a second caller
  /// while a pass runs gets the same result.
  static Future<KhataSyncResult> sync(ApiClient api) {
    return _inFlight ??= _sync(api).whenComplete(() => _inFlight = null);
  }

  static Future<KhataSyncResult> _sync(ApiClient api) async {
    var synced = 0, failed = 0;
    var offline = false;
    final ops = await all();
    ops.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final op in ops.where((o) => o.isPending).toList()) {
      if (offline) break; // no point trying the rest this pass
      try {
        await _send(api, op).timeout(requestTimeout);
        final now = await all();
        now.removeWhere((o) => o.cid == op.cid);
        await _save(now);
        synced++;
      } catch (e) {
        final kind = failKindOf(e);
        final now = await all();
        final idx = now.indexWhere((o) => o.cid == op.cid);
        if (idx < 0) continue;
        if (kind == FailKind.refused) {
          final conflict = e is ApiException && e.status == 409;
          now[idx] = now[idx].copyWith(
              state: conflict ? 'conflict' : 'failed',
              error: e is ApiException ? e.message : '$e',
              attempts: now[idx].attempts + 1);
          failed++;
        } else {
          offline = true; // network / our 5xx: stays pending, retried later
          now[idx] = now[idx].copyWith(attempts: now[idx].attempts + 1);
        }
        await _save(now);
      }
    }
    final left = (await all()).where((o) => o.isPending).length;
    return KhataSyncResult(
        synced: synced, failed: failed, pending: left, offline: offline);
  }

  /// Try ONE op right now (the save button). Throws like the API does; the
  /// caller queues it on a network / 5xx failure (same client_id, so a send
  /// that did reach the server is not booked twice by the later replay).
  static Future<Map<String, dynamic>> sendNow(ApiClient api, KhataOp op,
          {bool notifyCustomer = false}) =>
      _send(api, op, notifyCustomer: notifyCustomer).timeout(requestTimeout);

  static Future<Map<String, dynamic>> _send(ApiClient api, KhataOp op,
      {bool notifyCustomer = false}) {
    switch (op.kind) {
      case 'payment':
        return api.khataPayment(
            partyId: op.partyId,
            amountPoisha: op.amountPoisha,
            note: op.note,
            atIso: op.atIso,
            clientId: op.cid);
      case 'edit':
        return api.khataEditEntry(
            businessId: op.bizId,
            entryId: op.entryId ?? 0,
            baseVersion: op.baseVersion ?? 1,
            amountPoisha: op.amountPoisha,
            note: op.note,
            atIso: op.atIso.isEmpty ? null : op.atIso);
      default:
        return api.khataAddEntry(
            partyId: op.partyId,
            direction: op.direction,
            amountPoisha: op.amountPoisha,
            note: op.note,
            atIso: op.atIso,
            notifyCustomer: notifyCustomer,
            clientId: op.cid);
    }
  }

  // ----------------------------------------------------------------- cache
  static Future<void> cachePut(String key, Map<String, dynamic> value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          '$_cachePrefix$key',
          jsonEncode({
            'saved': DateTime.now().toUtc().toIso8601String(),
            'v': value,
          }));
    } catch (_) {/* cache is best-effort */}
  }

  /// The saved copy + when it was saved, or null.
  static Future<({Map<String, dynamic> value, DateTime saved})?> cacheGet(
      String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('$_cachePrefix$key');
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        value: (j['v'] as Map).cast<String, dynamic>(),
        saved: DateTime.tryParse('${j['saved']}')?.toLocal() ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  static String partiesKey(int bizId, String book) => 'parties:$bizId:$book';
  static String statementKey(int partyId) => 'stmt:$partyId';
}
