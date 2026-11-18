// proof-ledger (18 Nov) — board rows 8 (business ledger, khata, cashbox,
// mess) and 45 (invoice papers). Opt-in reality group "ledger" ONLY
// (REALITY_ONLY=start,ledger — reality.yml input only=ledger); never part of
// "all". Test accounts on the throw-away CI Django, never the live server.
//
// TWO app processes with a REAL kill between them (tools/reality/run_flows.sh
// runs this group as two `flutter drive` calls and `am force-stop`s the app
// in between, with airplane mode still ON):
//
//   drive 1  ldg1_offline_entries  online setup -> REAL airplane mode ->
//            khata: due "Tk. 1,500" + payment "৫০০ টাকা" for a customer, a NEW
//            customer added offline + due "৭৫০"; cashbox: cash in "Tk. 500",
//            cash in "৳১,২৫০.৫০", cash out "৩০০/-"; mess: bazar "৫০০ টাকা" +
//            "Tk. 400", today's meals corrected (+2 guests) — all typed in
//            the UI, all kept on the phone. Ends with the network still OFF.
//   -- host: am force-stop (the process dies; nothing in memory survives) --
//   drive 2  ldg2_after_kill_sync  a NEW process (pid differs), still offline:
//            every row is still on the phone -> airplane OFF -> the app
//            sends everything BY ITSELF (no screen opened) -> the server has
//            each row EXACTLY ONCE with the exact poisha; a replay of the same
//            client_ids is answered "duplicate" and changes nothing.
//            ldg3_mess_month_close  close the month in the UI -> per-meal
//            rate = bazar ÷ meals to the poisha (৳900 ÷ 4.5 = ৳200).
//            ldg4_invoice_papers  58 mm, 80 mm, A4 (bn) + 80 mm (en) on the
//            emulator: screen shots + the exact PDF/PNG the Share button
//            makes (saved as CI evidence), totals, Bangla digits, widths.
//
// Honest limit: no Bluetooth thermal printer on CI — the PDF/PNG is the
// printer's exact dot width, but real paper is an owner-phone check.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/business_khata_api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/screens/business/cashbox_screen.dart';
import 'package:assisto/screens/business/invoice/invoice_api.dart';
import 'package:assisto/screens/business/invoice/invoice_design.dart';
import 'package:assisto/screens/business/invoice/invoice_doc.dart';
import 'package:assisto/screens/business/invoice/invoice_paper.dart';
import 'package:assisto/screens/business/invoice/invoice_screen.dart';
import 'package:assisto/screens/business/khata_screen.dart';
import 'package:assisto/screens/mess/mess_detail_screen.dart';
import 'package:assisto/screens/mess/mess_store.dart';
import 'package:assisto/services/cashbox_offline.dart';
import 'package:assisto/services/khata_offline.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

/// The mess runs on DHAKA time on the server; the CI emulator may be UTC.
DateTime _dhakaNow() => DateTime.now().toUtc().add(const Duration(hours: 6));

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// What drive 1 typed, for drive 2 (a file in the evidence dir — the
/// harness's own memory dies with the process, which is the point).
const _stateFile = 'ledger_proof_state.json';

// The amounts exactly as a Bangladeshi shopkeeper types them.
const _p1Due = 'Tk. 1,500'; // 150000 poisha
const _p1Pay = '৫০০ টাকা'; // ৫০০ টাকা = 50000
const _p2Due = '৭৫০'; // ৭৫০ = 75000
const _cbIn1 = 'Tk. 500'; // 50000
const _cbIn2 = '৳১,২৫০.৫০'; // ৳১,২৫০.৫০ = 125050
const _cbOut = '৩০০/-'; // ৩০০/- = 30000
const _bz1 = '৫০০ টাকা'; // ৫০০ টাকা = 50000
const _bz2 = 'Tk. 400'; // 40000

Finder _sees(String s) => find.byWidgetPredicate((w) {
      if (w is Text) return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      if (w is RichText) return w.text.toPlainText().contains(s);
      return false;
    });

Future<bool> _reachable() async {
  final u = Uri.parse(AppConfig.apiBase);
  try {
    final s = await Socket.connect(u.host, u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80),
        timeout: const Duration(seconds: 2));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Ask the CI host to switch REAL airplane mode (adb) and wait for its ack;
/// the network state itself is the proof, not the ack.
Future<void> _airplane(RFlow f, bool on) async {
  final file = 'ldg_net_${on ? 'off' : 'on'}_$_tag';
  final d = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${d!.path}/acks/$file');
  // ignore: avoid_print
  print('REALITY_NET ${on ? 'off' : 'on'} $file');
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(end)) {
    await f.tester.pump(const Duration(milliseconds: 250));
    if (await f.tester.runAsync(() => ack.exists()) == true) break;
  }
  await f.eventually(on ? 'the backend is UNREACHABLE (airplane mode on)' : 'the backend is reachable again',
      () async => (await _reachable()) != on,
      seconds: on ? 30 : 90);
}

Future<void> _toRoot(RFlow f) async {
  appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
  await f.pumpFor(const Duration(milliseconds: 1200));
}

Future<Map<String, dynamic>> _biz(RFlow f, ApiClient api) async {
  final b = await f.net(() => api.getJson('/business/profiles'));
  final list = (b['businesses'] as List).cast<Map<String, dynamic>>();
  return list.firstWhere((x) => x['id'] == b['selected_id'], orElse: () => list.first);
}

Future<File> _file(RFlow f, String name) async {
  final d = await f.tester.runAsync(() => f.h.outDir());
  return File('${d!.path}/$name');
}

/// Type [text] into the field with [key] and tap [save].
Future<void> _typeSave(RFlow f, String key, String text, String save,
    {double settle = 3}) async {
  final field = find.byKey(ValueKey(key));
  await f.waitFor(field, what: 'field $key');
  await f.tester.enterText(field, text);
  await f.tester.pump(const Duration(milliseconds: 300));
  await f.tap(find.byKey(ValueKey(save)), settleSeconds: settle);
}

int _pngWidth(Uint8List b) => (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];

void registerLedgerProofFlows() {
  // ------------------------------------------------------------ drive 1
  realityFlow('ldg1_offline_entries', 'Business ledger proof',
      'Offline (real airplane mode): khata due/payment/new customer, cashbox sales, mess bazar + meals typed in the UI -> kept on the phone',
      (f) async {
    if (const String.fromEnvironment('REALITY_SHOT_MODE') == 'inapp') {
      f.skip('real phones (Test Lab): no host adb to switch airplane mode');
    }
    await f.home();
    final api = await f.h.backend();
    late Map<String, dynamic> biz;
    late int bid, p1, mid;
    final p1Name = 'Proof Rafiq $_tag';
    final p2Name = 'Proof Offline Karim $_tag';
    final day = _iso(DateTime.now()); // the cashbox screen's own day key
    await f.step('online setup: a customer, a mess (A is manager)', () async {
      biz = await _biz(f, api);
      bid = (biz['id'] as num).toInt();
      final p = await f.net(() => api.postJson('/business/khata/parties',
          {'business': bid, 'book': 'customer', 'name': p1Name, 'phone': '01700000051'}));
      p1 = (p['id'] as num).toInt();
      await f.net(() => api.postJson('/mess/v2', {'name': 'Proof Mess $_tag'}));
      final list = await f.net(() => api.getJson('/mess/v2'));
      final m = (list['messes'] as List).cast<Map>().firstWhere((x) => x['name'] == 'Proof Mess $_tag');
      mid = (m['id'] as num).toInt();
    });
    await f.step('online: open cashbox + mess once (the phone keeps a copy)', () async {
      await f.pushScreen(CashboxScreen(business: biz), settleSeconds: 4);
      f.expectHttp('GET', '/business/cashbox/$day');
      await _toRoot(f);
      await f.pushScreen(MessDetailScreen(messId: mid, initialTab: 1), settleSeconds: 4);
      f.expectHttp('GET', '/mess/v2/$mid');
      await _toRoot(f);
      await f.pushScreen(KhataScreen(business: biz), settleSeconds: 4);
      await f.scrollToBuilt(find.text(p1Name), what: 'the customer in the khata');
      await f.tap(find.text(p1Name).first, settleSeconds: 4);
      await f.shot('khata_statement_online');
    });
    await f.step('airplane mode ON (real network off)', () async {
      await _airplane(f, true);
    });
    await f.step('khata offline: due "$_p1Due" + payment "৫০০ টাকা"', () async {
      await f.tap(find.text(f.t.entryAddCredit).last, settleSeconds: 1.5);
      await _typeSave(f, 'ldg-entry-amount', _p1Due, 'ldg-entry-save');
      if (!await f.appears(find.text(f.t.ldgSavedOffline), seconds: 2)) {
        f.note('the "Saved on this phone" snack bar had already gone (queue checked below)');
      }
      await f.tap(find.text(f.t.entryReceivePayment).last, settleSeconds: 1.5);
      await _typeSave(f, 'ldg-entry-amount', _p1Pay, 'ldg-entry-save');
      await f.shot('khata_two_offline');
    });
    await f.step('khata offline: a NEW customer + due "৭৫০"', () async {
      await f.back();
      await f.tap(find.byTooltip(f.t.khataAddCustomer));
      await f.enter(p2Name, label: f.t.name);
      await f.enter('01700000052', label: f.t.phone);
      await f.tapSave(settleSeconds: 4);
      // bizbar: straight to the new customer's page
      await f.tap(find.text(f.t.entryAddCredit).last, settleSeconds: 1.5);
      await _typeSave(f, 'ldg-entry-amount', _p2Due, 'ldg-entry-save');
      await f.back();
      await f.waitFor(find.byKey(const ValueKey('ldg-pending-banner')), what: 'khata pending banner');
      await f.shot('khata_pending_banner');
      final ops = await f.net(() => KhataOffline.all());
      final amts = ops.where((o) => !o.isParty).map((o) => o.amountPoisha).toList()..sort();
      if (ops.length != 4 || !ops.every((o) => o.isPending) || '$amts' != '[50000, 75000, 150000]') {
        throw TestFailure('khata queue on the phone: ${ops.map((o) => '${o.kind}:${o.amountPoisha}:${o.state}').toList()}');
      }
    });
    await f.step('cashbox offline (saved copy): cash in "Tk. 500", "৳১,২৫০.৫০", cash out "৩০০/-"', () async {
      await _toRoot(f);
      await f.pushScreen(CashboxScreen(business: biz), settleSeconds: 4);
      await f.waitFor(find.byKey(const ValueKey('cb-offline-banner')), what: 'cashbox offline banner');
      for (final (btn, amt, note) in [
        ('cb-cash-in', _cbIn1, 'Proof sale 1 $_tag'),
        ('cb-cash-in', _cbIn2, 'Proof sale 2 $_tag'),
        ('cb-cash-out', _cbOut, 'Proof bus fare $_tag'),
      ]) {
        await f.tap(find.byKey(ValueKey(btn)), settleSeconds: 1.5);
        await f.tester.enterText(find.byKey(const ValueKey('cb-entry-note')), note);
        await _typeSave(f, 'cb-entry-amount', amt, 'cb-entry-save');
      }
      await f.waitFor(find.byKey(const ValueKey('cb-pending-banner')), what: 'cashbox pending banner');
      await f.shot('cashbox_offline_pending');
      final ops = await f.net(() => CashboxOffline.all());
      final got = ops.map((o) => '${o.kind}${o.amountPoisha}').toList()..sort();
      if ('$got' != '[in125050, in50000, out30000]' || ops.any((o) => o.day != day)) {
        throw TestFailure('cashbox queue on the phone: $got (day ${ops.map((o) => o.day).toSet()})');
      }
    });
    await f.step('mess offline: bazar "৫০০ টাকা" + "Tk. 400"; today\'s meals +2 guests', () async {
      await _toRoot(f);
      await f.pushScreen(MessDetailScreen(messId: mid, initialTab: 1), settleSeconds: 4);
      for (final amt in [_bz1, _bz2]) {
        final add = find.byKey(const ValueKey('mess-add-bazar'));
        await f.scrollToBuilt(add, what: 'Add bazar');
        await f.tap(add, settleSeconds: 1.5);
        await f.tester.ensureVisible(find.byKey(const ValueKey('entry-amount')));
        await _typeSave(f, 'entry-amount', amt, 'entry-save');
      }
      // the manager corrects TODAY (Dhaka) for A: breakfast + lunch + dinner
      // on, one guest at lunch and one at dinner = 0.5 + 1 + 1 + 1 + 1 = 4.5
      await f.tap(find.text(f.t.mv2TabMeals), settleSeconds: 2);
      final fix = find.text(f.t.mv2CorrectMeals);
      await f.scrollToBuilt(fix, what: 'Correct meals');
      await f.tap(fix, settleSeconds: 1.5);
      await f.tap(find.descendant(of: find.byType(BottomSheet), matching: find.byType(ListTile)).first,
          settleSeconds: 2);
      final dhaka = _dhakaNow();
      final cell = find.descendant(of: find.byType(Dialog), matching: find.text('${dhaka.day}'));
      if (cell.evaluate().isNotEmpty) await f.tap(cell.first, settleSeconds: 0.6);
      await f.tap(find.text('OK'), settleSeconds: 1.5);
      await f.tap(find.byKey(const ValueKey('meal-guest-l')), settleSeconds: 0.4);
      await f.tap(find.byKey(const ValueKey('meal-guest-d')), settleSeconds: 0.4);
      await f.tap(find.byKey(const ValueKey('meal-save')), settleSeconds: 3);
      await f.shot('mess_offline_queued');
      final n = await f.net(() => MessOutbox.pending(mid));
      if (n != 3) throw TestFailure('mess rows waiting on the phone: $n, wanted 3 (2 bazar + 1 meal day)');
    });
    await f.step('remember what was typed (for the next app process)', () async {
      final file = await _file(f, _stateFile);
      await f.net(() => file.writeAsString(jsonEncode({
            'pid': pid,
            'tag': _tag,
            'biz': bid,
            'p1': p1,
            'p1_name': p1Name,
            'p2_name': p2Name,
            'mess': mid,
            'cash_day': day,
            'meal_day': _iso(_dhakaNow()),
          })));
      f.note('drive 1 pid $pid: 4 khata + 3 cashbox + 3 mess rows on the phone; network left OFF for the kill');
    });
  }, timeout: const Duration(minutes: 8));

  // ------------------------------------------------------------ drive 2
  realityFlow('ldg2_after_kill_sync', 'Business ledger proof',
      'After a REAL app kill (new process, still offline): rows still on the phone -> online -> synced by the app itself, each EXACTLY once, exact poisha; replays answered duplicate',
      (f) async {
    if (const String.fromEnvironment('REALITY_SHOT_MODE') == 'inapp') {
      f.skip('real phones (Test Lab): no host adb to switch airplane mode');
    }
    late Map<String, dynamic> st;
    await f.step('a NEW app process, network still OFF', () async {
      final file = await _file(f, _stateFile);
      if (await f.net(() => file.exists()) != true) {
        throw TestFailure('no $_stateFile: drive 1 (ldg1_offline_entries) did not finish');
      }
      st = (jsonDecode(await f.net(() => file.readAsString())) as Map).cast<String, dynamic>();
      if (st['pid'] == pid) throw TestFailure('same process id $pid: the app was NOT killed');
      if (await f.net(() => _reachable())) {
        throw TestFailure('the backend is reachable: airplane mode did not survive the kill (harness)');
      }
      await f.home();
      if (!f.app.loggedIn) throw TestFailure('the reopened app is signed out');
      f.note('drive 1 pid ${st['pid']} -> now pid $pid (killed with am force-stop)');
      await f.shot('reopened_offline_home');
    });
    late List<KhataOp> kOps;
    late List<CashboxOp> cOps;
    late List<Map<String, dynamic>> mOps;
    await f.step('every row survived the kill (on the phone, not yet sent)', () async {
      kOps = await f.net(() => KhataOffline.all());
      cOps = await f.net(() => CashboxOffline.all());
      mOps = await f.net(() async {
        final sp = await SharedPreferences.getInstance();
        final raw = sp.getString('mess_v2_outbox') ?? '[]';
        return (jsonDecode(raw) as List).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      });
      if (kOps.length != 4 || cOps.length != 3 || mOps.length != 3) {
        throw TestFailure('after the kill: khata ${kOps.length}/4, cashbox ${cOps.length}/3, mess ${mOps.length}/3');
      }
      final biz = <String, dynamic>{'id': st['biz'], 'name': 'Proof', 'role': 'owner'};
      await f.pushScreen(KhataScreen(business: biz), settleSeconds: 4);
      await f.waitFor(find.byKey(const ValueKey('ldg-pending-banner')), what: 'khata pending banner after the kill');
      await f.shot('khata_after_kill_offline');
      await _toRoot(f);
    });
    await f.step('airplane mode OFF -> the app sends it all BY ITSELF (no money screen open)', () async {
      await _toRoot(f);
      await _airplane(f, false);
      await f.eventually('every queue on the phone is empty', () async {
        final k = await KhataOffline.all();
        final c = await CashboxOffline.all();
        final m = await MessOutbox.pending();
        return k.isEmpty && c.isEmpty && m == 0;
      }, seconds: 90);
      f.note('synced from Home by the app-start / back-online sync (state.dart)');
    });
    final api = await f.h.backend();
    final bid = (st['biz'] as num).toInt();
    final p1 = (st['p1'] as num).toInt();
    final mid = (st['mess'] as num).toInt();
    await f.step('khata on the server: exactly once, exact poisha', () async {
      final s1 = await f.net(() => api.getJson('/business/khata/parties/$p1/statement?business=$bid'));
      final lines = (s1['lines'] as List).length;
      if (s1['balance_poisha'] != 100000 || lines != 2) {
        throw TestFailure('customer 1: balance ${s1['balance_poisha']} (want 100000 = 1500 - 500), lines $lines (want 2)');
      }
      final ps = await f.net(() => api.khataParties(bid, 'customer'));
      final twins = (ps['parties'] as List).cast<Map>().where((x) => x['name'] == st['p2_name']).toList();
      if (twins.length != 1) throw TestFailure('offline customer on the server ${twins.length} times (want 1)');
      final p2 = (twins.single['id'] as num).toInt();
      final s2 = await f.net(() => api.getJson('/business/khata/parties/$p2/statement?business=$bid'));
      if (s2['balance_poisha'] != 75000 || (s2['lines'] as List).length != 1) {
        throw TestFailure('offline customer: balance ${s2['balance_poisha']} (want 75000), lines ${(s2['lines'] as List).length}');
      }
    });
    await f.step('cashbox on the server: 3 rows once each, drawer +৳1,450.50', () async {
      final d = await f.net(() => api.cashboxDay(bid, '${st['cash_day']}'));
      final mine = (d['entries'] as List).cast<Map>().where((e) => '${e['note']}'.contains(_tagOf(st))).toList();
      final got = mine.map((e) => '${e['kind']}${e['amount']}').toList()..sort();
      if ('$got' != '[in125050, in50000, out30000]') throw TestFailure('cashbox rows on the server: $got');
      final ids = mine.map((e) => '${e['client_id']}').toSet();
      if (!cOps.every((o) => ids.contains(o.cid))) throw TestFailure('client ids not booked: $ids');
      f.note('cashbox expected ${d['expected_poisha']} poisha');
    });
    await f.step('mess on the server: 2 bazar rows once each + today = 4.5 meals', () async {
      final d = await f.net(() => api.getJson('/mess/v2/$mid'));
      final bazar = (d['entries'] as List).cast<Map>().where((e) => e['kind'] == 'bazar').toList();
      final amts = bazar.map((e) => e['amount']).toList()..sort((a, b) => (a as num).compareTo(b as num));
      if ('$amts' != '[40000, 50000]') throw TestFailure('bazar rows on the server: $amts');
      final s = (d['summary'] as Map).cast<String, dynamic>();
      if (s['meals_total_milli'] != 4500) throw TestFailure('meals this month ${s['meals_total_milli']} milli, want 4500');
    });
    await f.step('replay the SAME client ids (a lost answer) -> "duplicate", nothing changes', () async {
      final kDue = kOps.firstWhere((o) => o.kind == 'entry' && o.amountPoisha == 150000);
      final r1 = await f.net(() => api.khataAddEntry(
          businessId: bid, partyId: p1, direction: 'gave', amountPoisha: 150000, clientId: kDue.cid));
      if (r1['duplicate'] != true) throw TestFailure('khata replay not a duplicate: $r1');
      final c0 = cOps.first;
      final r2 = await f.net(() => api.cashboxAddEntry(
          businessId: bid, day: c0.day, kind: c0.kind, amountPoisha: c0.amountPoisha,
          note: c0.note, clientId: c0.cid));
      if (r2['duplicate'] != true) throw TestFailure('cashbox replay not a duplicate: ${r2['duplicate']}');
      final mb = mOps.firstWhere((o) => '${o['path']}'.endsWith('/entries'));
      final r3 = await f.net(() => api.postJson('${mb['path']}', (mb['body'] as Map).cast<String, dynamic>()));
      if (r3['dedup'] != true) throw TestFailure('mess replay not de-duplicated: $r3');
      // and a second sync pass of every outbox sends nothing
      await f.net(() => KhataOffline.sync(api));
      await f.net(() => CashboxOffline.sync(api));
      await f.net(() => MessOutbox.flush(api));
      final s1 = await f.net(() => api.getJson('/business/khata/parties/$p1/statement?business=$bid'));
      final d = await f.net(() => api.cashboxDay(bid, '${st['cash_day']}'));
      final mine = (d['entries'] as List).cast<Map>().where((e) => '${e['note']}'.contains(_tagOf(st)));
      final m = await f.net(() => api.getJson('/mess/v2/$mid'));
      final bz = (m['entries'] as List).cast<Map>().where((e) => e['kind'] == 'bazar');
      if ((s1['lines'] as List).length != 2 || mine.length != 3 || bz.length != 2) {
        throw TestFailure('after replays: khata ${(s1['lines'] as List).length}, cashbox ${mine.length}, bazar ${bz.length}');
      }
    });
    await f.step('the screens online: no pending banners, server numbers', () async {
      final biz = <String, dynamic>{'id': bid, 'name': 'Proof', 'role': 'owner'};
      await f.pushScreen(CashboxScreen(business: biz), settleSeconds: 4);
      if (find.byKey(const ValueKey('cb-pending-banner')).evaluate().isNotEmpty) {
        throw TestFailure('cashbox still shows rows waiting');
      }
      await f.shot('cashbox_synced');
      await _toRoot(f);
      await f.pushScreen(KhataScreen(business: biz), settleSeconds: 4);
      if (find.byKey(const ValueKey('ldg-pending-banner')).evaluate().isNotEmpty) {
        throw TestFailure('khata still shows entries waiting');
      }
      await f.shot('khata_synced');
      await _toRoot(f);
    });
  }, timeout: const Duration(minutes: 7));

  realityFlow('ldg3_mess_month_close', 'Business ledger proof',
      'Mess month close in the UI: per-meal rate = bazar ÷ meals to the poisha (৳900 ÷ 4.5 = ৳200), the member owes ৳900',
      (f) async {
    final sf = await _file(f, _stateFile);
    final st = (jsonDecode(await f.net(() => sf.readAsString())) as Map).cast<String, dynamic>();
    final api = await f.h.backend();
    final mid = (st['mess'] as num).toInt();
    await f.home();
    if (!await f.net(() => _reachable())) await _airplane(f, false); // ldg2 died offline
    await f.step('close the month (UI)', () async {
      final tomorrow = _dhakaNow().add(const Duration(days: 1));
      if (tomorrow.day > 28) {
        f.skip('a mess month that ends today needs start day ${tomorrow.day} (>28); run on another day');
      }
      if (st['meal_day'] != _iso(_dhakaNow())) {
        f.skip('the Dhaka day changed between the two drives (${st['meal_day']} -> ${_iso(_dhakaNow())})');
      }
      await f.net(() => api.postJson('/mess/v2/$mid/edit', {'month_start_day': tomorrow.day}));
      await f.pushScreen(MessDetailScreen(messId: mid, initialTab: 3), settleSeconds: 4);
      final close = find.byKey(const ValueKey('mess-close-month'));
      await f.scrollToBuilt(close, what: 'Close month button');
      await f.tap(close);
      await f.tap(find.byKey(const ValueKey('mess-confirm-yes')), settleSeconds: 4);
      f.expectHttp('POST', '/mess/v2/$mid/close');
      await f.shot('mess_month_closed');
    });
    await f.step('server: rate ৳200.00 per meal, A owes ৳900, reconciles', () async {
      final now = _dhakaNow();
      final key = _iso(DateTime(now.year, now.month - 1, 1)).substring(0, 7);
      final d = await f.net(() => api.getJson('/mess/v2/$mid?month=$key'));
      if ((d['month'] as Map)['closed'] != true) throw TestFailure('month $key not closed: ${d['month']}');
      final s = (d['summary'] as Map).cast<String, dynamic>();
      final rate = (s['meal_rate'] as num?)?.toDouble();
      if (s['bazar_total'] != 90000 || s['meals_total_milli'] != 4500 || rate != 20000) {
        throw TestFailure('bazar ${s['bazar_total']} (want 90000), meals ${s['meals_total_milli']} (want 4500), rate $rate (want 20000 poisha)');
      }
      final rows = (s['members'] as List).cast<Map>();
      if (rows.length != 1 || rows.single['due'] != 90000 || s['reconciles'] != true) {
        throw TestFailure('member rows $rows, reconciles ${s['reconciles']}');
      }
      f.note('closed $key: meal rate ${s['meal_rate_display']} = ৳900 ÷ 4.5; A owes ৳900');
      if (await f.appears(_sees('200.00'), seconds: 4)) await f.shot('rate_on_screen');
    });
  }, timeout: const Duration(minutes: 5));

  realityFlow('ldg4_invoice_papers', 'Business ledger proof',
      'Invoices on the emulator: 58 mm, 80 mm, A4 (bn) + 80 mm (en) — screen + the exact PDF/PNG the Share button makes (CI evidence), totals, Bangla digits, widths',
      (f) async {
    await f.home();
    if (!await f.net(() => _reachable())) await _airplane(f, false); // ldg2 died offline
    final api = await f.h.backend();
    late Map<String, dynamic> inv;
    late int bid;
    await f.step('a manual invoice with long Bangla lines (server computes the money)', () async {
      bid = ((await _biz(f, api))['id'] as num).toInt();
      inv = await f.net(() => api.manualInvoiceCreate({
            'template': 'retail',
            'buyer': {
              'name': 'মোছাম্মৎ রোকসানা আক্তার (প্রুফ $_tag)',
              'phone': '01700000061',
              'address': 'বাড়ি ১২, রোড ৫, মিরপুর ১০, ঢাকা ১২১৬',
            },
            'lines': [
              {'desc': 'চাল মিনিকেট ২৫ কেজির বস্তা — প্রিমিয়াম কোয়ালিটি, রাজশাহী থেকে আনা', 'qty': 2, 'unit': 125050},
              {'desc': 'Soybean oil 5 litre (Teer) family pack', 'qty': 3, 'unit': 89000},
              {'desc': 'ডিম (এক ডজন)', 'qty': 1, 'unit': 15000},
            ],
            'discount': 5000,
            'paid': 200000,
            'payment_method': 'cash',
            'no_vat': true,
            'note': 'ধন্যবাদ, আবার আসবেন',
          }, businessId: bid));
      final calc = (inv['calc'] as Map).cast<String, dynamic>();
      // 2 x 1250.50 + 3 x 890 + 150 = 5321.00; - 50 = 5271.00; paid 2000 -> due 3271.00
      if (calc['subtotal'] != 532100 || calc['total'] != 527100 || inv['due'] != 327100) {
        throw TestFailure('server money: subtotal ${calc['subtotal']}, total ${calc['total']}, due ${inv['due']}');
      }
      if (inv['consistent'] == false) throw TestFailure('paper total != charged total');
    });
    final evidence = <String>[];
    for (final (paper, lang) in [
      (InvoicePaper.mm58, 'bn'),
      (InvoicePaper.mm80, 'bn'),
      (InvoicePaper.a4, 'bn'),
      (InvoicePaper.mm80, 'en'),
    ]) {
      await f.step('${paper.code} ($lang): screen + PDF/PNG, totals, digits, widths', () async {
        await f.pushScreen(InvoiceScreen(initial: inv, businessId: bid, paper: paper, lang: lang),
            settleSeconds: 4);
        await f.shot('invoice_${paper.code}_$lang');
        final doc = InvoiceDoc.fromJson(inv);
        final lay = layoutWithDesign(doc, paper, lang);
        final texts = lay.allTexts;
        for (final want in [invMoney(527100, lang), invMoney(327100, lang)]) {
          if (!texts.any((s) => s.contains(want))) {
            throw TestFailure('paper has no "$want" (total / due)');
          }
        }
        if (lang == 'bn') {
          final latinMoney = texts.where((s) => s.contains('৳') && RegExp('[0-9]').hasMatch(s)).toList();
          if (latinMoney.isNotEmpty) throw TestFailure('Bangla paper with English digits in money: $latinMoney');
          final latinAny = texts.where((s) => RegExp('[0-9]').hasMatch(s)).toList();
          if (latinAny.isNotEmpty) f.note('${paper.code} bn: Latin digits kept in ${latinAny.take(4).toList()}');
        }
        final wide = lay.blocks.where((b) => b.usedWidth > lay.contentWidth + 0.5).toList();
        if (wide.isNotEmpty) {
          throw TestFailure('${wide.length} block(s) wider than the paper: ${wide.map((b) => '${b.kind} ${b.usedWidth.round()}>${lay.contentWidth.round()}').toList()}');
        }
        final t = paperLocalizations(lang).$1;
        final pdf = await f.net(() => buildInvoicePdf(lay, t, number: doc.number));
        if (pdf.length < 1000 || String.fromCharCodes(pdf.take(5)) != '%PDF-') {
          throw TestFailure('not a PDF (${pdf.length} bytes)');
        }
        final base = 'invoices/invoice_${paper.code}_$lang';
        final pf = await _file(f, '$base.pdf');
        await f.net(() async {
          await pf.parent.create(recursive: true);
          await pf.writeAsBytes(pdf, flush: true);
        });
        evidence.add('$base.pdf (${pdf.length} B)');
        final pngs = <Uint8List>[];
        if (paper.thermal) {
          pngs.add(await f.net(() => buildInvoicePng(lay, t)));
        } else {
          final imgs = await f.net(() => renderInvoiceImages(lay, t, number: doc.number));
          for (final i in imgs) {
            final bd = await f.net(() => i.toByteData(format: ui.ImageByteFormat.png));
            i.dispose();
            pngs.add(bd!.buffer.asUint8List());
          }
        }
        for (var k = 0; k < pngs.length; k++) {
          final w = _pngWidth(pngs[k]);
          if (w != paper.widthPx.round()) {
            throw TestFailure('${paper.code} picture is $w px wide, the paper is ${paper.widthPx} dots');
          }
          final name = '$base${pngs.length > 1 ? '_p${k + 1}' : ''}.png';
          final png = await _file(f, name);
          await f.net(() => png.writeAsBytes(pngs[k], flush: true));
          evidence.add('$name ($w px)');
        }
        await _toRoot(f);
      });
    }
    f.note('evidence (reality_out/device/reality/): ${evidence.join(', ')}');
    f.needsKey('a real Bluetooth thermal printer (58/80 mm) for printed paper — not tested on CI');
  }, timeout: const Duration(minutes: 7));
}

String _tagOf(Map<String, dynamic> st) => '${st['tag']}';
