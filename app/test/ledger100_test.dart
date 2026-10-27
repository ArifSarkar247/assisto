// ledger100 — digital khata to 100 (owner FINAL ORDER 27 Oct; evidence
// BEST_IN_CLASS_BN.md gap #10: TallyKhata's 1-star reviews for losing
// offline mode and a paid tier).
//
//  * offline queue: survives a restart, syncs once, never double-counts,
//    parks 4xx / 409 conflicts honestly;
//  * bulk tagada: ONE separate reminder per customer, a tap per send,
//    sent/skipped/failed tally, Assisto SMS cost confirm, offline fallback;
//  * khata list: pending-sync marks, search, "everyone with a due";
//  * schedule sheet posts the schedule; free-forever promise copy;
//  * bn + en (Bangla digits + ৳), dark, TalkBack 48 dp.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/khata_screen.dart';
import 'package:assisto/screens/business/tagada_schedule_sheet.dart';
import 'package:assisto/screens/business/tagada_send_screen.dart';
import 'package:assisto/services/khata_offline.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/khata_free_promise.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';
import 'fake_khata.dart';

const _biz = {'id': 1, 'name': 'Rahim Store', 'role': 'owner'};

/// FakeApi with switches: offline (khata calls throw like a dead socket),
/// the server's answer for the next entry (ok / 422 / 409), and a log.
class _KhApi extends FakeApi {
  _KhApi({super.lang = 'en'});
  bool offline = false;
  int? refuseStatus; // 422 or 409 for entries / edits
  final posts = <String, List<Map<String, dynamic>>>{};
  final booked = <String>{}; // client_ids the "server" booked
  int partiesCount = 0; // >0: return that many customers

  void _net(String path) {
    if (offline && path.contains('/business/khata')) {
      throw const SocketException('offline');
    }
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    _net(path);
    if (partiesCount > 0 && path.startsWith('/business/khata/parties?')) {
      return {
        'parties': [
          for (var i = 0; i < partiesCount; i++)
            {
              'id': 100 + i, 'name': 'Customer ${i.toString().padLeft(3, '0')}',
              'phone': '0171${i.toString().padLeft(7, '0')}', 'book': 'customer',
              'balance_poisha': i.isEven ? 1000 : 0,
              'balance_display': fmtPair(i.isEven ? 1000 : 0),
            }
        ],
      };
    }
    return super.getJson(path);
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    _net(path);
    posts.putIfAbsent(path.split('?').first, () => []).add(body);
    if (refuseStatus != null &&
        (path.contains('/entries') || path.contains('/payment'))) {
      throw ApiException(
          refuseStatus == 409 ? 'Changed elsewhere (server)' : 'Invalid entry (server)',
          refuseStatus);
    }
    final cid = '${body['client_id'] ?? ''}';
    if (cid.isNotEmpty) booked.add(cid);
    return super.postJson(path, body);
  }

  @override
  Future<Map<String, dynamic>> postJsonRaw(String path,
      [Map<String, dynamic> body = const {}]) async {
    _net(path);
    posts.putIfAbsent(path.split('?').first, () => []).add(body);
    return super.postJsonRaw(path, body);
  }
}

Widget _app(Widget child, {String lang = 'en', bool dark = false}) =>
    MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      darkTheme: AssistoTheme.dark,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: child,
    );

Future<AppLocalizations> _pump(WidgetTester tester, Widget screen, _KhApi api,
    {String lang = 'en', bool dark = false, Map<String, Object>? prefs}) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s, child: _app(screen, lang: lang, dark: dark)));
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byWidget(screen)));
}

KhataOp _op(String cid, {int amount = 50000, String kind = 'entry', int party = 1}) =>
    KhataOp(
        cid: cid, bizId: 1, partyId: party, partyName: 'Karim Store',
        book: 'customer', kind: kind, direction: 'gave', amountPoisha: amount,
        atIso: '2026-10-27T10:00:00', createdAt: DateTime(2026, 10, 27, 10));

Future<void> _talkBack(WidgetTester tester) async {
  final h = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  h.dispose();
}

void main() {
  group('offline queue (services/khata_offline.dart)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('client ids are unique and server-acceptable', () {
      final ids = {for (var i = 0; i < 200; i++) KhataOffline.newClientId()};
      expect(ids.length, 200);
      expect(ids.every((s) => RegExp(r'^[A-Za-z0-9_.:-]{6,64}$').hasMatch(s)), isTrue);
    });

    test('a queued entry survives an app restart', () async {
      await KhataOffline.enqueue(_op('kx-restart1'));
      await KhataOffline.enqueue(_op('kx-restart1')); // same op twice → once
      final raw = (await SharedPreferences.getInstance()).getString('khata_outbox_v1')!;
      // "restart": a fresh read straight from storage
      SharedPreferences.setMockInitialValues({'khata_outbox_v1': raw});
      final ops = await KhataOffline.all();
      expect(ops.length, 1);
      expect(ops.single.cid, 'kx-restart1');
      expect(ops.single.isPending, isTrue);
      expect(ops.single.signedDelta, 50000);
    });

    test('offline keeps it pending; online syncs it once with its client id', () async {
      final api = _KhApi()..offline = true;
      await KhataOffline.enqueue(_op('kx-sync0001'));
      var r = await KhataOffline.sync(api);
      expect((r.offline, r.pending, r.synced), (true, 1, 0));
      api.offline = false;
      r = await KhataOffline.sync(api);
      expect((r.synced, r.pending), (1, 0));
      expect(api.booked, {'kx-sync0001'});
      expect(await KhataOffline.all(), isEmpty);
      r = await KhataOffline.sync(api); // nothing left → nothing re-sent
      expect(api.posts['/business/khata/parties/1/entries']!.length, 1);
    });

    test('a 4xx refusal is parked as failed with the server sentence', () async {
      final api = _KhApi()..refuseStatus = 422;
      await KhataOffline.enqueue(_op('kx-bad00001'));
      final r = await KhataOffline.sync(api);
      expect(r.failed, 1);
      final op = (await KhataOffline.all()).single;
      expect(op.state, 'failed');
      expect(op.error, 'Invalid entry (server)');
      await KhataOffline.sync(api); // never retried forever
      expect(api.posts['/business/khata/parties/1/entries']!.length, 1);
      await KhataOffline.discard(op.cid);
      expect(await KhataOffline.all(), isEmpty);
    });

    test('a stale offline edit becomes a conflict, not an overwrite', () async {
      final api = _KhApi()..refuseStatus = 409;
      await KhataOffline.enqueue(_op('kx-pay00001', kind: 'payment'));
      await KhataOffline.sync(api);
      expect((await KhataOffline.all()).single.state, 'conflict');
    });

    test('payment estimate lowers the customer due', () {
      expect(_op('kx-p0000001', kind: 'payment', amount: 2000).signedDelta, -2000);
    });
  });

  group('bulk tagada — one reminder per customer', () {
    final parties = fakeKhataParties('customer', false);

    testWidgets('separate cards, own amounts, honest tally, skip', (tester) async {
      final api = _KhApi();
      final t = await _pump(tester,
          TagadaSendScreen(business: _biz, parties: parties), api);
      expect(find.byKey(const ValueKey('ldg-row-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('ldg-row-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('ldg-row-2')), findsNothing); // owes 0
      expect(find.textContaining('Your due at Rahim Store is ৳1500.00'), findsOneWidget);
      expect(find.textContaining('৳250.00'), findsWidgets);
      expect(find.text(t.ldgCountSkipped('1')), findsOneWidget); // Rahim: no due
      expect(find.text(t.ldgCountWaiting('2')), findsOneWidget);
      // the picked ids went to the server, one call (not a merged text)
      expect(api.posts['/business/khata/tagada/bulk']!.single['party_ids'], [1, 2, 3]);
      // Salma has no phone → Share instead of WhatsApp
      expect(find.text(t.ldgNoPhone), findsOneWidget);
      await tester.ensureVisible(find.text(t.ldgBtnSkip).first);
      await tester.tap(find.text(t.ldgBtnSkip).first);
      await tester.pumpAndSettle();
      expect(find.text(t.ldgCountSkipped('2')), findsOneWidget);
      expect(find.text(t.ldgCountWaiting('1')), findsOneWidget);
    });

    testWidgets('Assisto SMS shows the cost first and sends only on Send',
        (tester) async {
      final api = _KhApi();
      final t = await _pump(tester,
          TagadaSendScreen(business: _biz, parties: parties), api);
      final btn = find.byKey(const ValueKey('ldg-assisto-1'));
      expect(find.text(t.ldgBtnAssistoSms('2')), findsOneWidget);
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(find.text(t.ldgSmsConfirmBody('Karim Store', '2', '40')), findsOneWidget);
      await tester.tap(find.text(t.cancel));
      await tester.pumpAndSettle();
      expect(api.posts['/business/khata/tagada/sms/1'], isNull); // nothing left
      await tester.tap(btn);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.ldgSmsSendNow));
      await tester.pumpAndSettle();
      expect(api.posts['/business/khata/tagada/sms/1']!.length, 1);
      expect(find.text(t.ldgStatusSmsSent('2')), findsOneWidget);
      expect(find.text(t.ldgCountSent('1')), findsOneWidget);
    });

    testWidgets('pay-to number goes into every message request', (tester) async {
      final api = _KhApi();
      final t = await _pump(tester,
          TagadaSendScreen(business: _biz, parties: parties), api);
      await tester.enterText(find.byKey(const ValueKey('ldg-pay-number')), '01700000000');
      await tester.tap(find.text(t.ldgPayApply));
      await tester.pumpAndSettle();
      expect(api.posts['/business/khata/tagada/bulk']!.last['pay_hint'],
          {'method': 'bKash', 'number': '01700000000'});
    });

    testWidgets('offline: messages from the saved khata, no Assisto SMS (bn)',
        (tester) async {
      final api = _KhApi(lang: 'bn')..offline = true;
      final bnParties = fakeKhataParties('customer', true);
      final t = await _pump(
          tester, TagadaSendScreen(business: _biz, parties: bnParties), api,
          lang: 'bn');
      expect(find.text(t.ldgOfflineBuilt), findsOneWidget);
      expect(find.textContaining('৳১৫০০'), findsWidgets); // Bangla digits
      expect(find.byKey(const ValueKey('ldg-assisto-1')), findsNothing);
      expect(find.text(t.ldgBtnWhatsApp), findsOneWidget);
      expect(find.text(t.ldgCountWaiting('২')), findsOneWidget);
    });

    testWidgets('nothing due → honest empty state; TalkBack 48 dp, dark',
        (tester) async {
      final api = _KhApi();
      final t = await _pump(
          tester,
          TagadaSendScreen(business: _biz, parties: [parties[1]]),
          api,
          dark: true);
      expect(find.text(t.ldgNoDueTitle), findsOneWidget);
      await _talkBack(tester);
    });
  });

  group('khata list', () {
    testWidgets('pending-sync banner + tile mark from the saved queue (bn)',
        (tester) async {
      final api = _KhApi(lang: 'bn')..offline = true;
      final t = await _pump(
        tester,
        const KhataScreen(business: _biz),
        api,
        lang: 'bn',
        prefs: {
          'khata_outbox_v1': jsonEncode([_op('kx-pend0001').toJson()]),
          'khata_cache_v1:parties:1:customer': jsonEncode({
            'saved': '2026-10-27T04:00:00Z',
            'v': {'parties': fakeKhataParties('customer', true)},
          }),
        },
      );
      expect(find.byKey(const ValueKey('ldg-pending-banner')), findsOneWidget);
      expect(find.textContaining(t.ldgPendingSync('১')), findsOneWidget);
      expect(find.textContaining(t.ldgPendingChip), findsWidgets);
      expect(find.textContaining('৳২০০০'), findsOneWidget); // 1500 + 500 pending
      expect(find.textContaining(t.ldgSavedCopy('').split('(').first), findsOneWidget);
    });

    testWidgets('online again: "Sync now" sends it and the banner goes',
        (tester) async {
      final api = _KhApi()..offline = true;
      final t = await _pump(tester, const KhataScreen(business: _biz), api,
          prefs: {
            'khata_outbox_v1': jsonEncode([_op('kx-pend0002').toJson()]),
            'khata_cache_v1:parties:1:customer': jsonEncode({
              'saved': '2026-10-27T04:00:00Z',
              'v': {'parties': fakeKhataParties('customer', false)},
            }),
          });
      api.offline = false;
      await tester.tap(find.text(t.ldgSyncNow));
      await tester.pumpAndSettle();
      expect(api.booked, {'kx-pend0002'});
      expect(find.byKey(const ValueKey('ldg-pending-banner')), findsNothing);
    });

    testWidgets('500 customers: lazy list + search + everyone with a due',
        (tester) async {
      final api = _KhApi()..partiesCount = 500;
      final t = await _pump(tester, const KhataScreen(business: _biz), api);
      // lazily built: far fewer tiles than rows exist
      expect(find.textContaining('Customer 499'), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('ldg-search')), '499');
      await tester.pumpAndSettle();
      expect(find.text('Customer 499'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('ldg-search')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ldg-bulk-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ldg-select-due')));
      await tester.pumpAndSettle();
      expect(find.text(t.ldgSendToN('250')), findsOneWidget);
    });

    testWidgets('scheduled reminders waiting → one-tap send banner', (tester) async {
      final api = _KhApi();
      final t = await _pump(tester, const KhataScreen(business: _biz), api);
      expect(find.byKey(const ValueKey('ldg-awaiting')), findsOneWidget);
      expect(find.text(t.ldgAwaitingTitle('1')), findsOneWidget);
    });
  });

  group('schedule + promise', () {
    testWidgets('schedule sheet posts the schedule (every 7 days, push)',
        (tester) async {
      final api = _KhApi();
      final t = await _pump(
          tester,
          Scaffold(
              body: TagadaScheduleSheet(
                  business: _biz, party: fakeKhataParties('customer', false)[0])),
          api);
      expect(find.text(t.ldgSchedModePush), findsOneWidget);
      expect(find.text(t.ldgSchedQuietAlways), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('ldg-sched-save')));
      await tester.tap(find.byKey(const ValueKey('ldg-sched-save')));
      await tester.pumpAndSettle();
      final body = api.posts['/business/khata/tagada/schedule']!.single;
      expect(body['party'], 1);
      expect(body['interval_days'], 7);
      expect(body['channel'], 'push');
      expect(body['until_paid'], isTrue);
    });

    testWidgets('free-forever promise says what is free AND what is paid (bn/en)',
        (tester) async {
      for (final lang in ['en', 'bn']) {
        final t = await _pump(tester,
            const Scaffold(body: KhataFreePromiseDetails()), _KhApi(lang: lang),
            lang: lang);
        expect(find.text(t.ldgFreeTitle), findsOneWidget);
        expect(find.text(t.ldgFreeL2), findsOneWidget);
        expect(find.text(t.ldgFreePaidSms), findsOneWidget);
      }
    });
  });
}
