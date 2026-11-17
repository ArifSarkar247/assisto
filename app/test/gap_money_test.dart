// gap-money — feature gap lane for Mess and Money (owner order 17 Nov 10:10).
// One test per fixed gap (owner_actions/gaps/money_BN.md).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/mess/mess_detail_screen.dart' show MessHistoryList;
import 'package:assisto/screens/business/acct/acct_common.dart' show parseTakaToPoisha;
import 'package:assisto/screens/business/business_common.dart' show takaToPoisha;
import 'package:assisto/screens/business/invoice/new_invoice_screen.dart' show typedPoisha;
import 'package:assisto/screens/mess/mess_store.dart';
import 'package:assisto/widgets/num_input.dart';

import 'fake_api.dart';

/// Answers every POST with [status] (0 = no network) until [status] is null.
class _FlakyApi extends FakeApi {
  _FlakyApi() : super(lang: 'en');
  int? status;
  final sent = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    final s = status;
    if (s == 0) throw const SocketException('offline');
    if (s != null) throw ApiException('Error $s', s);
    sent.add(body);
    return {'ok': true};
  }
}

String bn(String s) => String.fromCharCodes(
    s.runes.map((r) => r >= 0x30 && r <= 0x39 ? 0x09E6 + r - 0x30 : r));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('mess offline outbox keeps entries the server could not take yet', () {
    test('a 5xx while syncing keeps the queued bazar (it used to be dropped)', () async {
      final api = _FlakyApi()..status = 0;
      expect(await MessOutbox.write(api, 7, '/mess/v2/7/entries',
          {'kind': 'bazar', 'amount': 50000}), 'queued');
      expect(await MessOutbox.pending(7), 1);
      api.status = 502; // server restarting during a deploy
      var r = await MessOutbox.flush(api);
      expect(r.sent, 0);
      expect(r.refused, isEmpty);
      expect(await MessOutbox.pending(7), 1);
      api.status = 429;
      await MessOutbox.flush(api);
      api.status = 401; // session expired: still not the entry's fault
      await MessOutbox.flush(api);
      expect(await MessOutbox.pending(7), 1);
      api.status = null;
      r = await MessOutbox.flush(api);
      expect(r.sent, 1);
      expect(await MessOutbox.pending(7), 0);
      expect(api.sent.single['amount'], 50000);
      // the phone's saved-at time rides along (offline meal cut-off rule)
      expect(DateTime.tryParse('${api.sent.single['saved_at']}'), isNotNull);
    });

    test('a real refusal (409 closed month) is dropped and reported', () async {
      final api = _FlakyApi()..status = 0;
      await MessOutbox.write(api, 7, '/mess/v2/7/entries', {'kind': 'bazar', 'amount': 100});
      api.status = 409;
      final r = await MessOutbox.flush(api);
      expect(r.refused, hasLength(1));
      expect(await MessOutbox.pending(7), 0);
    });

    test('Save on a 503 is kept on the phone, a 403 is shown at once', () async {
      final api = _FlakyApi()..status = 503;
      expect(await MessOutbox.write(api, 7, '/mess/v2/7/entries', {'amount': 1}), 'queued');
      api.status = 403;
      await expectLater(
          MessOutbox.write(api, 7, '/mess/v2/7/entries', {'amount': 1}),
          throwsA(isA<ApiException>()));
      expect(await MessOutbox.pending(7), 1);
    });

    test('a write queued while a sync runs is not lost by that sync', () async {
      final api = _FlakyApi()..status = 0;
      await MessOutbox.write(api, 7, '/mess/v2/7/entries', {'amount': 1, 'client_id': 'a'});
      api.status = null;
      final f = MessOutbox.flush(api);
      // a second Save while still offline for it (fails, gets queued)
      final api2 = _FlakyApi()..status = 0;
      await MessOutbox.write(api2, 7, '/mess/v2/7/entries', {'amount': 2, 'client_id': 'b'});
      await f;
      expect(await MessOutbox.pending(7), 1); // 'b' is still there
      await MessOutbox.flush(api);
      expect(api.sent.map((b) => b['client_id']), ['a', 'b']);
    });
  });

  group('amounts the way people write them in Bangladesh', () {
    test('mess: Bangla word taka, /- and /=, and the server limit', () {
      expect(messTakaToPoisha(bn('500') + ' টাকা'), 50000);
      expect(messTakaToPoisha('500/-'), 50000);
      expect(messTakaToPoisha(bn('1,200') + '/='), 120000);
      expect(messTakaToPoisha('Tk. 700'), 70000);
      expect(messTakaToPoisha('10000000'), 1000000000); // ৳1 crore: allowed
      expect(messTakaToPoisha('10000001'), isNull); // the server refuses more
    });

    test('shared parser: taka word, /-, Tk.', () {
      expect(takaToPoishaInput(bn('15000') + '/-'), 1500000);
      expect(takaToPoishaInput('10,000 টাকা'), 1000000);
      expect(takaToPoishaInput('Tk. 500'), 50000);
      expect(takaToPoishaInput('Tk500'), 50000);
      expect(takaToPoishaInput('500tk'), 50000);
      expect(takaToPoishaInput('12abc'), isNull);
    });

    test('Account & Finance: "Tk. 500" is ৳500, not 50 poisha', () {
      expect(parseTakaToPoisha('Tk. 500'), 50000);
      expect(parseTakaToPoisha('Tk.1,250.50'), 125050);
      expect(parseTakaToPoisha('৳' + bn('1,250.5')), 125050);
      expect(parseTakaToPoisha('500/-'), 50000);
      expect(parseTakaToPoisha('12abc'), isNull); // was silently ৳12
      expect(parseTakaToPoisha('0'), isNull);
    });

    test('khata / cashbox: "Tk. 500" is ৳500 and a minus is refused', () {
      expect(takaToPoisha('Tk. 500'), 50000);
      expect(takaToPoisha(bn('2,500.75')), 250075);
      expect(takaToPoisha('-500'), isNull); // was silently +৳500
      expect(takaToPoisha('abc'), isNull);
    });

    test('invoice: "৳500" and "500/-" are read', () {
      expect(typedPoisha('৳500'), 50000);
      expect(typedPoisha('500/-'), 50000);
      expect(typedPoisha(''), 0);
      expect(typedPoisha('-1'), isNull);
    });
  });

  group('mess edit history says WHAT changed', () {
    test('amount edit, add, delete and meals', () {
      expect(messHistoryDetail({'amount': 50000, 'date': '2026-11-05'},
          {'amount': 500000, 'date': '2026-11-05'}), '৳500.00 → ৳5,000.00 · 5/11');
      expect(messHistoryDetail(const {}, {'amount': 70000, 'date': '2026-11-03'}),
          '৳700.00 · 3/11');
      expect(messHistoryDetail({'amount': 12345678, 'date': '2026-11-03'}, const {}),
          '৳1,23,456.78 · 3/11');
      expect(messHistoryDetail({'date': '2026-11-02', 'b': 1, 'l': 1, 'd': 1},
          {'date': '2026-11-02', 'b': 0, 'l': 1, 'd': 1}), '1/1/1 → 0/1/1 · 2/11');
      expect(messHistoryDetail({'month': '2026-11'}, null), '');
    });

    test('poisha text uses lakh grouping like the server', () {
      expect(messPoishaText(0), '৳0.00');
      expect(messPoishaText(102355000), '৳10,23,550.00');
      expect(messPoishaText(-5), '-৳0.05');
    });
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('history sheet shows what changed + the offline-sync note ($lang)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(body: SingleChildScrollView(child: MessHistoryList(rows: [
          {'actor': 'Babu', 'action': 'bazar.edit', 'at': '2026-11-05T14:20:00+06:00',
           'before': {'amount': 50000, 'date': '2026-11-05'},
           'after': {'amount': 500000, 'date': '2026-11-05'}},
          {'actor': 'Chaya', 'action': 'meal.set', 'at': '2026-11-02T23:40:00+06:00',
           'before': {'date': '2026-11-03'},
           'after': {'date': '2026-11-03', 'b': 0, 'l': 1, 'd': 1,
                     'offline_saved_at': '2026-11-02T21:30:00+06:00'}},
        ]))),
      ));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(Locale(lang));
      final amounts = lang == 'en' ? '৳500.00 → ৳5,000.00' : '৳৫০০.০০ → ৳৫,০০০.০০';
      expect(find.textContaining(amounts), findsOneWidget);
      expect(find.textContaining(t.mv2SyncedLateNote), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('net-worth fixtures obey hero = assets + receivable − liabilities', () async {
    int p(Object? v) => takaToPoishaInput('$v')!;
    for (final d in [await FakeApi(lang: 'en').moneyNetWorth(),
                     await FakeApi(lang: 'en', mode: FakeMode.empty).moneyNetWorth()]) {
      expect(p(d['net_worth']), p(d['assets']) + p(d['receivable']) - p(d['liabilities']));
      final series = (d['series'] as List).cast<Map>();
      if (series.isNotEmpty) expect(p(series.last['net_worth']), p(d['net_worth']));
      for (var i = 1; i < series.length; i++) {
        expect(p(series[i]['net_worth']) - p(series[i - 1]['net_worth']), p(series[i]['delta']));
      }
    }
  });
}
