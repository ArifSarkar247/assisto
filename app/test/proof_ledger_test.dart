// proof-ledger (18 Nov) — business ledger / cashbox / mess proof lane.
// One test per bug this lane found (owner_actions/gaps/ledger_proof_BN.md).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/services/cashbox_offline.dart';
import 'package:assisto/services/khata_offline.dart';
import 'package:assisto/widgets/ladder_common.dart' as ladder;
import 'package:assisto/widgets/subs_common.dart' as subs;

import 'fake_api.dart';

/// Answers every POST with [status] (0 = no network) until it is null; a
/// [gate] holds the answer (to save a row WHILE a sync is sending).
class _Api extends FakeApi {
  _Api() : super(lang: 'en');
  int? status;
  Completer<void>? gate;
  final sent = <Map<String, dynamic>>[];
  final booked = <String>{};

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    final s = status;
    if (s == 0) throw const SocketException('offline');
    if (s != null) throw ApiException('Error $s', s);
    if (gate != null) await gate!.future;
    sent.add(body);
    final cid = '${body['client_id'] ?? ''}';
    final dup = cid.isNotEmpty && !booked.add(cid);
    return {'ok': true, 'duplicate': dup, 'expected_poisha': 0};
  }
}

CashboxOp _cb(String cid, {int amount = 50000, String kind = 'in', int minute = 0}) => CashboxOp(
    cid: cid, bizId: 1, day: '2026-11-18', kind: kind, amountPoisha: amount,
    note: 'sale', createdAt: DateTime(2026, 11, 18, 10, minute));

KhataOp _kh(String cid) => KhataOp(
    cid: cid, bizId: 1, partyId: 1, partyName: 'Karim Store', book: 'customer',
    kind: 'entry', direction: 'gave', amountPoisha: 50000,
    atIso: '2026-11-18T10:00:00', createdAt: DateTime(2026, 11, 18, 10));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('cashbox offline outbox (a sale typed with no internet)', () {
    test('kept through no-network / 5xx / 401 / 408 / 429, then sent ONCE', () async {
      final api = _Api()..status = 0;
      await CashboxOffline.enqueue(_cb('cb-test-0001'));
      await CashboxOffline.enqueue(_cb('cb-test-0001')); // same id twice: one row
      expect(await CashboxOffline.all(), hasLength(1));
      for (final s in [0, 502, 503, 401, 408, 429]) {
        api.status = s;
        final r = await CashboxOffline.sync(api);
        expect(r.offline, isTrue, reason: 'status $s');
        expect((await CashboxOffline.all()).single.isPending, isTrue, reason: 'status $s');
      }
      api.status = null;
      final r = await CashboxOffline.sync(api);
      expect(r.synced, 1);
      expect(api.sent.single['client_id'], 'cb-test-0001');
      expect(api.sent.single['amount'], 50000);
      expect(api.sent.single['kind'], 'in');
      expect(await CashboxOffline.all(), isEmpty);
      await CashboxOffline.sync(api); // nothing left -> nothing re-sent
      expect(api.sent, hasLength(1));
    });

    test('a real refusal (422) is parked as failed, never retried, can be discarded', () async {
      final api = _Api()..status = 422;
      await CashboxOffline.enqueue(_cb('cb-test-0002'));
      final r = await CashboxOffline.sync(api);
      expect(r.failed, 1);
      final op = (await CashboxOffline.all()).single;
      expect(op.state, 'failed');
      expect(op.error, 'Error 422');
      api.status = null;
      await CashboxOffline.sync(api);
      expect(api.sent, isEmpty);
      await CashboxOffline.discard(op.cid);
      expect(await CashboxOffline.all(), isEmpty);
    });

    test('a row saved WHILE a sync is sending is not lost', () async {
      final api = _Api()..gate = Completer<void>();
      await CashboxOffline.enqueue(_cb('cb-test-0003'));
      final pass = CashboxOffline.sync(api);
      await Future<void>.delayed(Duration.zero);
      await CashboxOffline.enqueue(_cb('cb-test-0004', minute: 5));
      api.gate!.complete();
      await pass;
      final left = await CashboxOffline.all();
      expect(left.map((o) => o.cid), ['cb-test-0004']);
      api.gate = null;
      await CashboxOffline.sync(api);
      expect(api.sent.map((b) => b['client_id']), ['cb-test-0003', 'cb-test-0004']);
    });

    test('oldest first; a cash-out counts minus in the pending estimate', () async {
      final api = _Api()..status = 0;
      await CashboxOffline.enqueue(_cb('cb-test-0006', minute: 9, kind: 'out', amount: 12500));
      await CashboxOffline.enqueue(_cb('cb-test-0005', minute: 1));
      final ops = await CashboxOffline.forDay(1, '2026-11-18');
      expect(ops.fold<int>(0, (a, o) => a + o.signed), 50000 - 12500);
      api.status = null;
      await CashboxOffline.sync(api);
      expect(api.sent.map((b) => b['client_id']), ['cb-test-0005', 'cb-test-0006']);
    });

    test('broken stored rows are skipped, never crash the screen', () async {
      SharedPreferences.setMockInitialValues({
        'cashbox_outbox_v1': '[{"cid":"cb-x","amt":-5,"day":"2026-11-18","kind":"in"},'
            '{"cid":"cb-ok-01","amt":100,"day":"2026-11-18","kind":"in","biz":1}]'
      });
      final ops = await CashboxOffline.all();
      expect(ops.map((o) => o.cid), ['cb-ok-01']);
    });

    test('client ids fit the server rule ([A-Za-z0-9_.:-]{6,56})', () {
      final id = CashboxOffline.newClientId();
      expect(RegExp(r'^[A-Za-z0-9_.:-]{6,56}$').hasMatch(id), isTrue, reason: id);
      expect(CashboxOffline.newClientId(), isNot(id));
    });
  });

  group('khata outbox: 401 / 408 / 429 no longer park an entry as failed', () {
    test('rate limit while 30 queued entries go up: stays pending, then sent', () async {
      final api = _Api()..status = 429;
      await KhataOffline.enqueue(_kh('kx-proof-0001'));
      for (final s in [429, 401, 408]) {
        api.status = s;
        final r = await KhataOffline.sync(api);
        expect(r.failed, 0, reason: 'status $s');
        expect((await KhataOffline.all()).single.isPending, isTrue, reason: 'status $s');
      }
      api.status = null;
      final r = await KhataOffline.sync(api);
      expect(r.synced, 1);
      expect(api.sent.single['client_id'], 'kx-proof-0001');
      expect(await KhataOffline.all(), isEmpty);
    });

    test('a real refusal (422) is still final', () async {
      final api = _Api()..status = 422;
      await KhataOffline.enqueue(_kh('kx-proof-0002'));
      final r = await KhataOffline.sync(api);
      expect(r.failed, 1);
      expect((await KhataOffline.all()).single.state, 'failed');
    });

    test('isRetryable: only real refusals are final', () {
      for (final s in [401, 408, 429, 500, 502, 503]) {
        expect(KhataOffline.isRetryable(ApiException('x', s)), isTrue, reason: '$s');
        expect(CashboxOffline.isRetryable(ApiException('x', s)), isTrue, reason: '$s');
      }
      for (final s in [400, 403, 404, 409, 422]) {
        expect(KhataOffline.isRetryable(ApiException('x', s)), isFalse, reason: '$s');
        expect(CashboxOffline.isRetryable(ApiException('x', s)), isFalse, reason: '$s');
      }
      expect(KhataOffline.isRetryable(const SocketException('x')), isTrue);
      expect(CashboxOffline.isRetryable(TimeoutException('x')), isTrue);
    });
  });

  group('the last two copies of the old money parser (subscriptions, ladders, rent, samity)', () {
    // "Tk. 500" became ".500" = 50 poisha, "-500" became +500, 12.345 -> 12.34
    final cases = <String, int>{
      'Tk. 500': 50000, 'Tk.500': 50000, 'Tk500': 50000, '500 tk': 50000,
      '৫০০ টাকা': 50000, // ৫০০ টাকা
      '৫০০/-': 50000, '500/=': 50000,
      '৳1,250.50': 125050, '12.345': 1235, '1,500': 150000,
      '-500': 0, 'abc': 0, '': 0,
    };
    test('subscriptions', () {
      cases.forEach((raw, want) => expect(subs.takaToPoisha(raw), want, reason: raw));
      expect(subs.takaToPoisha(null), 0);
    });
    test('bill ladders / landlord / samity / sell-my-phone', () {
      cases.forEach((raw, want) => expect(ladder.takaToPoisha(raw), want, reason: raw));
      expect(ladder.takaToPoisha(null), 0);
    });
  });
}
