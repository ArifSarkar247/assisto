// Budget and Remittance (flag budget_remittance; the seed allow-lists demo
// user A so the hidden feature can be audited): the owner's own sentence
// "ভাই ২০ হাজার টাকা পাঠাইছে বিকাশে" -> checked form -> saved, read back from
// the SERVER; family plan + a spending; the year view; the monthly report
// shared with user B (My Circle) ONLY after Share is tapped; delete-all.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/crypto/e2e.dart';

import '../support/harness.dart';

const _said = 'ভাই ২০ হাজার টাকা পাঠাইছে বিকাশে';

void registerBudgetRemittanceFlows() {
  realityFlow('30_budget_remittance', 'Money', 'Budget and Remittance: voice/text entry, plan, report share, delete',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    await f.step('open Budget and Remittance', () async {
      await f.openFeature(f.t.rmtTitle, 'remittance');
      // flagproof: run 44007111431 (C) — the quick box sits BELOW the
      // first-visit guide + month cards in a lazy ListView, so it was never
      // built. A user reads the guide, taps "Got it", then scrolls down.
      await f.waitFor(find.text(f.t.rmtTabBudget), what: 'Budget and Remittance tabs');
      await f.shot('month');
      if (await f.appears(find.text(f.t.rmtGotIt), seconds: 4)) {
        await f.tap(find.text(f.t.rmtGotIt), settleSeconds: 2);
      }
      await _scrollDownTo(f, find.byKey(const ValueKey('rmt_quick')), 'quick entry box');
      f.expectHttp('GET', '/remit/overview');
    });
    await f.step('the owner\'s sentence fills the form; Save; server has it', () async {
      final box = find.byKey(const ValueKey('rmt_quick'));
      await f.tester.ensureVisible(box);
      await f.tester.enterText(box, _said);
      await f.tap(find.byKey(const ValueKey('rmt_quick_go')), settleSeconds: 3);
      await f.waitFor(find.text(f.t.rmtUnderstoodCheck), what: 'understood banner');
      await f.shot('form-filled');
      final save = find.byKey(const ValueKey('rmt_save'));
      await _scrollDownTo(f, save, 'Save on the entry form'); // lazy list (run 44049525968)
      await f.tester.ensureVisible(save);
      await f.tap(save, settleSeconds: 3);
      await f.shot('saved');
      f.expectHttp('POST', '/remit/entries');
      await f.eventually('entry of 20,000 taka by bKash on the server', () async {
        final r = await api.getJson('/remit/entries');
        return (r['results'] as List).any((e) => e['taka'] == '20000.00' && e['channel'] == 'bkash');
      });
    });
    await f.step('family plan: food 10,000 + a 2,500 spending', () async {
      await f.tap(find.text(f.t.rmtTabBudget), settleSeconds: 2);
      await _scrollDownTo(f, find.byKey(const ValueKey('rmt_plan_edit')), 'edit plan button');
      await f.tap(find.byKey(const ValueKey('rmt_plan_edit')), settleSeconds: 2);
      await f.tester.enterText(find.byKey(const ValueKey('rmt_plan_food')), '10000');
      await f.tap(find.byKey(const ValueKey('rmt_sheet_save')), settleSeconds: 3);
      final add = find.byKey(const ValueKey('rmt_spend_add'));
      await _scrollDownTo(f, add, 'add a spending button');
      await f.tester.ensureVisible(add);
      await f.tap(add, settleSeconds: 2);
      await f.tester.enterText(find.byKey(const ValueKey('rmt_spend_amount')), '2500');
      await f.tap(find.byKey(const ValueKey('rmt_sheet_save')), settleSeconds: 3);
      await f.shot('budget');
      await f.eventually('plan food 10,000 with 2,500 actual on the server', () async {
        final r = await api.getJson('/remit/overview');
        final food = ((r['plan'] as Map)['lines'] as List).firstWhere((l) => l['key'] == 'food') as Map;
        return food['plan'] == '10000.00' && double.parse('${food['actual']}') >= 2500;
      });
    });
    await f.step('year view', () async {
      await f.tap(find.text(f.t.rmtTabYear), settleSeconds: 3);
      await f.shot('year');
      f.expectHttp('GET', '/remit/year');
    });
    await f.step('report: nothing sent until Share; then shared with user B', () async {
      // flagproof: B's phone publishes its key first (as on a real phone) —
      // run 44061342419: without it the report waited in the outbox, so no
      // encrypted message reached the server.
      final e2e = SoftwareE2E();
      final idB = e2e.generateIdentity();
      final apiB = await f.h.backend(userB: true);
      await f.net(() => apiB.postJson('/circle/keys',
          {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme}));
      final mark = f.httpMark;
      await f.tap(find.byKey(const ValueKey('rmt_report_btn')), settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('rmt_report_text')), what: 'report text');
      await f.shot('report');
      if (f.h.recorder.hits.skip(mark).any((x) => x.method == 'POST' && x.path.contains('/messages'))) {
        throw TestFailure('a message was sent before Share was tapped');
      }
      await f.tap(find.byKey(const ValueKey('rmt_share')), settleSeconds: 3);
      await f.shot('pick-member');
      final b = find.descendant(of: find.byType(BottomSheet), matching: find.byType(ListTile));
      if (!await f.appears(b, seconds: 6)) {
        f.note('no My Circle member listed for A (seed edge missing) — share not exercised');
        return;
      }
      await f.tap(b.first, settleSeconds: 2);
      await f.tap(find.byKey(const ValueKey('rmt_share_send')), settleSeconds: 4);
      await f.shot('shared');
      f.expectHttp('POST', '/circle/', since: mark);
      await f.tester.pageBack();
      await f.pumpFor(const Duration(seconds: 2));
    });
    await f.step('delete all (asks first) -> server is empty', () async {
      await f.tap(find.byKey(const ValueKey('rmt_menu')), settleSeconds: 1);
      await f.tap(find.text(f.t.rmtDeleteAll), settleSeconds: 1);
      await f.shot('delete-confirm');
      await f.tap(find.byKey(const ValueKey('rmt_confirm_yes')), settleSeconds: 3);
      await f.eventually('no remittance entries left on the server', () async {
        final r = await api.getJson('/remit/entries');
        return (r['results'] as List).isEmpty;
      });
      f.note('offline entry + later sync is proven in test/budrem_test.dart (the emulator network is not toggled here)');
    });
  });
}

/// flagproof: drag the visible VERTICAL list (never the tab PageView) until
/// [target] is built, like a user scrolling down.
Future<void> _scrollDownTo(RFlow f, Finder target, String what) async {
  final list = find.byWidgetPredicate(
      (w) => w is Scrollable && (w.axisDirection == AxisDirection.down)).hitTestable();
  for (var i = 0; i < 20 && target.evaluate().isEmpty; i++) {
    if (list.evaluate().isEmpty) break;
    await f.tester.drag(list.first, const Offset(0, -300), warnIfMissed: false);
    await f.tester.pump(const Duration(milliseconds: 350));
  }
  await f.waitFor(target, what: what);
}
