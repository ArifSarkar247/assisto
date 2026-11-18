import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../business_khata_api.dart';
import 'error_kind.dart';

/// proof-ledger — OFFLINE cashbox rows (cash in = a sale, cash out).
///
/// Before: with no internet a cash-in tap said "failed" and the shopkeeper's
/// sale was simply not written anywhere; a reply lost on a weak line and a
/// second tap booked it twice. Now, like the khata (khata_offline.dart):
/// * every row gets a `client_id` minted ONCE on the phone; the server books
///   a client_id at most once per business (it answers duplicate:true);
/// * no internet / our 5xx / a timeout / 401 / 408 / 429 keep the row on the
///   phone (SharedPreferences: survives the app being killed) and it is sent
///   on the next screen open, app start, back-online or "Sync now";
/// * a real refusal (validation, access) parks it as FAILED with the
///   server's sentence — never retried forever, never silently dropped.
class CashboxOp {
  final String cid;
  final int bizId;
  final String day; // YYYY-MM-DD the shopkeeper saved it for
  final String kind; // in | out
  final int amountPoisha;
  final String note;
  final DateTime createdAt;
  final String state; // pending | failed
  final String error;
  final int attempts;

  const CashboxOp({
    required this.cid,
    required this.bizId,
    required this.day,
    required this.kind,
    required this.amountPoisha,
    required this.createdAt,
    this.note = '',
    this.state = 'pending',
    this.error = '',
    this.attempts = 0,
  });

  bool get isPending => state == 'pending';

  /// Signed effect on the drawer (the "pending" estimate only).
  int get signed => kind == 'out' ? -amountPoisha : amountPoisha;

  CashboxOp copyWith({String? state, String? error, int? attempts}) => CashboxOp(
        cid: cid,
        bizId: bizId,
        day: day,
        kind: kind,
        amountPoisha: amountPoisha,
        createdAt: createdAt,
        note: note,
        state: state ?? this.state,
        error: error ?? this.error,
        attempts: attempts ?? this.attempts,
      );

  Map<String, dynamic> toJson() => {
        'cid': cid,
        'biz': bizId,
        'day': day,
        'kind': kind,
        'amt': amountPoisha,
        'note': note,
        'created': createdAt.toUtc().toIso8601String(),
        'state': state,
        'err': error,
        'tries': attempts,
      };

  static CashboxOp? fromJson(Map<String, dynamic> j) {
    int? i(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');
    final cid = '${j['cid'] ?? ''}';
    final amt = i(j['amt']);
    final kind = '${j['kind'] ?? ''}';
    final day = '${j['day'] ?? ''}';
    if (cid.isEmpty || amt == null || amt <= 0 || day.isEmpty) return null;
    if (kind != 'in' && kind != 'out') return null;
    return CashboxOp(
      cid: cid,
      bizId: i(j['biz']) ?? 0,
      day: day,
      kind: kind,
      amountPoisha: amt,
      note: '${j['note'] ?? ''}',
      createdAt: DateTime.tryParse('${j['created'] ?? ''}')?.toLocal() ?? DateTime.now(),
      state: '${j['state'] ?? 'pending'}' == 'failed' ? 'failed' : 'pending',
      error: '${j['err'] ?? ''}',
      attempts: i(j['tries']) ?? 0,
    );
  }
}

class CashboxSyncResult {
  final int synced, failed, pending;
  final bool offline;
  const CashboxSyncResult(
      {this.synced = 0, this.failed = 0, this.pending = 0, this.offline = false});
}

class CashboxOffline {
  CashboxOffline._();

  static const _qKey = 'cashbox_outbox_v1';
  static const requestTimeout = Duration(seconds: 15);

  static final StreamController<void> _changes = StreamController<void>.broadcast();
  static Stream<void> get changes => _changes.stream;

  static final Random _rng = Random.secure();

  /// Server-safe id ([A-Za-z0-9_.:-]{6,56}).
  static String newClientId() {
    final r = List.generate(10, (_) => _rng.nextInt(36).toRadixString(36)).join();
    return 'cb-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$r';
  }

  /// "Keep it and try later": no answer, our 5xx, a timeout, an expired
  /// session (401, sent after sign-in), a timeout / rate limit (408 / 429).
  static bool isRetryable(Object e) {
    if (e is ApiException) {
      final s = e.status ?? 0;
      if (s == 401 || s == 408 || s == 429) return true;
    }
    return failKindOf(e) != FailKind.refused;
  }

  static Future<List<CashboxOp>> all() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_qKey);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => CashboxOp.fromJson(m.cast<String, dynamic>()))
          .whereType<CashboxOp>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<CashboxOp>> forDay(int bizId, String day) async =>
      (await all()).where((o) => o.bizId == bizId && o.day == day).toList();

  /// Read-modify-write with no await between the read and the write, so a
  /// row saved while a sync is sending is never overwritten by the sync.
  static Future<void> _mutate(void Function(List<CashboxOp> ops) change) async {
    final sp = await SharedPreferences.getInstance();
    List<CashboxOp> ops;
    try {
      final raw = sp.getString(_qKey);
      ops = raw == null || raw.isEmpty
          ? <CashboxOp>[]
          : (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((m) => CashboxOp.fromJson(m.cast<String, dynamic>()))
              .whereType<CashboxOp>()
              .toList();
    } catch (_) {
      ops = <CashboxOp>[];
    }
    change(ops);
    final ok = await sp.setString(_qKey, jsonEncode([for (final o in ops) o.toJson()]));
    if (!ok) throw StateError('cashbox outbox not written');
    _changes.add(null);
  }

  /// Throws when storage refuses (the caller must then say so).
  static Future<void> enqueue(CashboxOp op) => _mutate((ops) {
        if (!ops.any((o) => o.cid == op.cid)) ops.add(op);
      });

  static Future<void> discard(String cid) =>
      _mutate((ops) => ops.removeWhere((o) => o.cid == cid));

  /// Send one row now (the Save tap). Throws like the API does; the caller
  /// keeps it on a retryable failure (same client_id, so a send that did
  /// reach the server is not booked twice by the later replay).
  static Future<Map<String, dynamic>> sendNow(ApiClient api, CashboxOp op) => api
      .cashboxAddEntry(
          businessId: op.bizId,
          day: op.day,
          kind: op.kind,
          amountPoisha: op.amountPoisha,
          note: op.note,
          clientId: op.cid)
      .timeout(requestTimeout);

  static Future<CashboxSyncResult>? _inFlight;

  /// Sync every PENDING row, oldest first. Single-flight.
  static Future<CashboxSyncResult> sync(ApiClient api) =>
      _inFlight ??= _sync(api)
          .catchError((Object _) => const CashboxSyncResult(offline: true))
          .whenComplete(() => _inFlight = null);

  static Future<CashboxSyncResult> _sync(ApiClient api) async {
    var synced = 0, failed = 0;
    var offline = false;
    final order = (await all()).where((o) => o.isPending).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final op in order) {
      if (offline) break;
      try {
        await sendNow(api, op);
        await _mutate((ops) => ops.removeWhere((o) => o.cid == op.cid));
        synced++;
      } catch (e) {
        if (isRetryable(e)) {
          offline = true; // stays pending, retried on the next pass
          await _mutate((ops) {
            final i = ops.indexWhere((o) => o.cid == op.cid);
            if (i >= 0) ops[i] = ops[i].copyWith(attempts: ops[i].attempts + 1);
          });
        } else {
          failed++;
          await _mutate((ops) {
            final i = ops.indexWhere((o) => o.cid == op.cid);
            if (i >= 0) {
              ops[i] = ops[i].copyWith(
                  state: 'failed',
                  error: e is ApiException ? e.message : '$e',
                  attempts: ops[i].attempts + 1);
            }
          });
        }
      }
    }
    final left = (await all()).where((o) => o.isPending).length;
    return CashboxSyncResult(synced: synced, failed: failed, pending: left, offline: offline);
  }
}
