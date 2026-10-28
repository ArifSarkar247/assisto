import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';

/// billapp (27 Oct) — the app's view of billing v2. Everything here is READ
/// from the server (core/credits.py state(), payments/refunds.py); the app
/// never computes a balance, an unlock, a refund amount or a price itself.
///
///  GET  /credits/state     -> [CreditsState]
///  GET  /credits/history   -> paged ledger (?offset=&limit=)
///  GET  /credits/refunds   -> [RefundsPage]
///  POST /credits/refunds   -> {purchase_id, reason} -> [RefundSubmitResult]

int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
DateTime? _d(Object? v) =>
    v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// One bucket of credits (plan / pack / free / rewarded / referral / legacy /
/// debt) as the server reports it.
class CreditBucket {
  final String bucket;
  final int remaining, locked;
  final DateTime? expiresAt; // null = never expires (packs)
  final DateTime? unlocksAt;
  const CreditBucket(
      {required this.bucket,
      required this.remaining,
      this.locked = 0,
      this.expiresAt,
      this.unlocksAt});

  factory CreditBucket.fromJson(Map<String, dynamic> j) => CreditBucket(
        bucket: '${j['bucket'] ?? ''}',
        remaining: _i(j['remaining']),
        locked: _i(j['locked']),
        expiresAt: _d(j['expires_at']),
        unlocksAt: _d(j['unlocks_at']),
      );
}

class CreditsState {
  final int balance, nowUsable, locked, debt;
  final DateTime? unlocksAt, planExpiresAt, serverTime;
  final bool blocked, purchaseBlocked, withdrawable;
  final List<CreditBucket> buckets;
  final Map<String, int> actionCosts;
  final int unlockPct, unlockHours, refundWindowHours;
  final Map<String, dynamic> raw;

  const CreditsState({
    this.balance = 0,
    this.nowUsable = 0,
    this.locked = 0,
    this.debt = 0,
    this.unlocksAt,
    this.planExpiresAt,
    this.serverTime,
    this.blocked = false,
    this.purchaseBlocked = false,
    this.withdrawable = false,
    this.buckets = const [],
    this.actionCosts = const {},
    this.unlockPct = 0,
    this.unlockHours = 0,
    this.refundWindowHours = 0,
    this.raw = const {},
  });

  factory CreditsState.fromJson(Map<String, dynamic> j) {
    var list = <CreditBucket>[
      for (final r in (j['bucket_detail'] as List?) ?? const [])
        if (r is Map) CreditBucket.fromJson(r.cast<String, dynamic>()),
    ];
    // Older server (no bucket_detail): the plain {bucket: n} map.
    if (list.isEmpty && j['buckets'] is Map) {
      list = [
        for (final e in (j['buckets'] as Map).entries)
          if (_i(e.value) != 0)
            CreditBucket(bucket: '${e.key}', remaining: _i(e.value)),
      ];
    }
    final balance = _i(j['balance']);
    var debt = _i(j['debt']);
    if (debt == 0 && balance < 0) debt = -balance;
    return CreditsState(
      balance: balance,
      nowUsable: _i(j['now_usable']),
      locked: _i(j['locked']),
      debt: debt,
      unlocksAt: _d(j['unlocks_at']),
      planExpiresAt: _d(j['plan_expires_at']),
      serverTime: _d(j['server_time']),
      blocked: j['blocked'] == true || j['negative'] == true,
      purchaseBlocked: j['purchase_blocked'] == true,
      withdrawable: j['withdrawable'] == true,
      buckets: list,
      actionCosts: {
        if (j['action_costs'] is Map)
          for (final e in (j['action_costs'] as Map).entries)
            '${e.key}': _i(e.value),
      },
      unlockPct: _i(j['unlock_pct']),
      unlockHours: _i(j['unlock_hours']),
      refundWindowHours: _i(j['refund_window_hours']),
      raw: j,
    );
  }

  /// Time until the next staged unlock, measured on the SERVER's clock (a
  /// wrong phone clock never changes what we say). Null = nothing locked.
  Duration? untilUnlock([DateTime? deviceNow]) {
    final u = unlocksAt;
    if (locked <= 0 || u == null) return null;
    final now = serverTime ?? deviceNow ?? DateTime.now();
    final d = u.difference(now);
    return d.isNegative ? Duration.zero : d;
  }
}

/// One ledger row.
class LedgerRow {
  final int id, delta;
  final String reason, note, bucket;
  final DateTime? at;
  const LedgerRow(
      {this.id = 0,
      required this.delta,
      required this.reason,
      this.note = '',
      this.bucket = '',
      this.at});
  factory LedgerRow.fromJson(Map<String, dynamic> j) => LedgerRow(
        id: _i(j['id']),
        delta: _i(j['delta'] ?? j['credits'] ?? j['amount']),
        reason: '${j['reason'] ?? ''}',
        note: '${j['note'] ?? ''}',
        bucket: '${j['bucket'] ?? ''}',
        at: _d(j['at'] ?? j['created_at']),
      );
}

class LedgerPage {
  final List<LedgerRow> rows;
  final int? nextOffset;
  const LedgerPage(this.rows, this.nextOffset);
}

class RefundRequestInfo {
  final int id, order;
  final String status; // pending | approved | manual | rejected
  final String note, approvedAmount;
  final DateTime? requestedAt, decidedAt;
  const RefundRequestInfo(
      {required this.id,
      required this.order,
      required this.status,
      this.note = '',
      this.approvedAmount = '0.00',
      this.requestedAt,
      this.decidedAt});
  factory RefundRequestInfo.fromJson(Map<String, dynamic> j) =>
      RefundRequestInfo(
        id: _i(j['id']),
        order: _i(j['order']),
        status: '${j['status'] ?? 'pending'}',
        note: '${j['note'] ?? ''}',
        approvedAmount: '${j['approved_amount'] ?? '0.00'}',
        requestedAt: _d(j['requested_at']),
        decidedAt: _d(j['decided_at']),
      );
}

class Purchase {
  final int id;
  final String channel, orderRef, sku, kind, plan, price, currency;
  final bool test, eligible;
  final String reason; // '' | already_requested | refunded | outside_window
  final DateTime? purchasedAt, windowEndsAt;
  final String? suggested;
  final Map<String, dynamic> usage;
  final RefundRequestInfo? request;
  const Purchase({
    required this.id,
    this.channel = '',
    this.orderRef = '',
    this.sku = '',
    this.kind = '',
    this.plan = '',
    this.price = '0',
    this.currency = 'BDT',
    this.test = false,
    this.eligible = false,
    this.reason = '',
    this.purchasedAt,
    this.windowEndsAt,
    this.suggested,
    this.usage = const {},
    this.request,
  });
  factory Purchase.fromJson(Map<String, dynamic> j) => Purchase(
        id: _i(j['id']),
        channel: '${j['channel'] ?? ''}',
        orderRef: '${j['order_ref'] ?? ''}',
        sku: '${j['sku'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        plan: '${j['plan'] ?? ''}',
        price: '${j['price'] ?? '0'}',
        currency: '${j['currency'] ?? 'BDT'}',
        test: j['test'] == true,
        eligible: j['eligible'] == true,
        reason: '${j['reason'] ?? ''}',
        purchasedAt: _d(j['purchased_at']),
        windowEndsAt: _d(j['window_ends_at']),
        suggested: j['suggested'] == null ? null : '${j['suggested']}',
        usage: (j['usage'] as Map?)?.cast<String, dynamic>() ?? const {},
        request: j['request'] is Map
            ? RefundRequestInfo.fromJson(
                (j['request'] as Map).cast<String, dynamic>())
            : null,
      );
}

class RefundsPage {
  final int windowHours;
  final String policyText;
  final List<Purchase> purchases;
  final List<RefundRequestInfo> requests;
  const RefundsPage(
      {this.windowHours = 0,
      this.policyText = '',
      this.purchases = const [],
      this.requests = const []});
  factory RefundsPage.fromJson(Map<String, dynamic> j) => RefundsPage(
        windowHours: _i(j['window_hours']),
        policyText: '${(j['policy'] as Map?)?['text'] ?? ''}',
        purchases: [
          for (final r in (j['purchases'] as List?) ?? const [])
            if (r is Map) Purchase.fromJson(r.cast<String, dynamic>()),
        ],
        requests: [
          for (final r in (j['requests'] as List?) ?? const [])
            if (r is Map) RefundRequestInfo.fromJson(r.cast<String, dynamic>()),
        ],
      );
}

/// The answer to a refund request: ok (with the new request), or the
/// server's own reason + message (outside_window, already_requested,
/// not_refundable, not_found, rate_limited, network).
class RefundSubmitResult {
  final bool ok;
  final String reason, message;
  final RefundRequestInfo? request;
  const RefundSubmitResult(
      {required this.ok, this.reason = '', this.message = '', this.request});
}

class BillingApi {
  final ApiClient api;
  BillingApi(this.api);

  Future<CreditsState> state() async =>
      CreditsState.fromJson(await api.getJson('/credits/state'));

  Future<LedgerPage> history({int offset = 0, int limit = 30}) async {
    final j = await api.getJson('/credits/history?offset=$offset&limit=$limit');
    final rows = [
      for (final r in (j['ledger'] as List?) ?? (j['items'] as List?) ?? const [])
        if (r is Map) LedgerRow.fromJson(r.cast<String, dynamic>()),
    ];
    final n = j['next_offset'];
    return LedgerPage(rows, n is num ? n.toInt() : null);
  }

  Future<RefundsPage> refunds() async =>
      RefundsPage.fromJson(await api.getJson('/credits/refunds'));

  Future<RefundSubmitResult> requestRefund(int purchaseId, String reason) async {
    try {
      final j = await api.postJson(
          '/credits/refunds', {'purchase_id': purchaseId, 'reason': reason});
      final r = j['request'];
      return RefundSubmitResult(
          ok: j['ok'] != false,
          request: r is Map
              ? RefundRequestInfo.fromJson(r.cast<String, dynamic>())
              : null);
    } on ApiException catch (e) {
      final b = e.body ?? const {};
      return RefundSubmitResult(
          ok: false,
          reason: '${b['reason'] ?? e.reason ?? (e.status == 429 ? 'rate_limited' : 'error')}',
          message: '${b['message'] ?? ''}');
    } catch (_) {
      return const RefundSubmitResult(ok: false, reason: 'network');
    }
  }
}

/// The last good /credits/state, kept on the phone so the screen still shows
/// something true (with its "last updated" time) when offline. Keyed by the
/// signed-in account, so another account on the same phone never sees it.
class CreditsCache {
  static String _k(String uid) => 'billapp.credits_state.v1.$uid';
  static String _kAt(String uid) => 'billapp.credits_state.at.$uid';

  static Future<void> save(String uid, Map<String, dynamic> raw,
      {DateTime? at}) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_k(uid), jsonEncode(raw));
      await p.setString(_kAt(uid), (at ?? DateTime.now()).toIso8601String());
    } catch (_) {}
  }

  static Future<({CreditsState state, DateTime at})?> load(String uid) async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_k(uid));
      final at = DateTime.tryParse(p.getString(_kAt(uid)) ?? '');
      if (s == null || at == null) return null;
      return (
        state: CreditsState.fromJson(
            (jsonDecode(s) as Map).cast<String, dynamic>()),
        at: at
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear(String uid) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_k(uid));
      await p.remove(_kAt(uid));
    } catch (_) {}
  }
}
