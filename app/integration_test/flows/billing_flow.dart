// billapp (27 Oct): Plan & credits on the REAL server — the Plan screen's
// status panel, the Credits screen built from GET /credits/state (the number
// on screen is the server's now_usable), the paged ledger, what each task
// costs (server action_costs), and the Refunds screen (GET /credits/refunds;
// nothing is POSTed — no refund is ever asked for in the audit).
import 'package:assisto/screens/plans_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

String _ascii(String s) => s.split('').map((c) {
      final u = c.codeUnitAt(0);
      return (u >= 0x09E6 && u <= 0x09EF) ? String.fromCharCode(0x30 + u - 0x09E6) : c;
    }).join().replaceAll(',', '');

void registerBillingFlows() {
  realityFlow('40_billing', 'Money', 'Plan & credits: server balance, buckets, costs, ledger, refunds',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    await f.step('open Plan & credits', () async {
      await f.pushScreen(const PlansScreen(), settleSeconds: 4);
      await f.waitFor(find.byKey(const Key('plans-open-credits')), what: 'credits entry');
      await f.shot('plans');
      f.expectHttp('GET', '/credits/state');
    });
    await f.step('Credits: the number on screen is the server\'s now_usable', () async {
      final open = find.byKey(const Key('plans-open-credits'));
      await f.tester.ensureVisible(open);
      await f.tap(open, settleSeconds: 4);
      await f.waitFor(find.byKey(const Key('credits-hero')), what: 'credits hero');
      await f.shot('credits');
      f.expectHttp('GET', '/credits/state');
      f.expectHttp('GET', '/credits/history');
      final st = await f.tester.runAsync(() => api.getJson('/credits/state'));
      final shown = f.tester.widget<Text>(find.byKey(const Key('credits-now'))).data ?? '';
      if (_ascii(shown) != '${st?['now_usable']}') {
        throw TestFailure('screen shows $shown, server now_usable=${st?['now_usable']}');
      }
      if ((st?['action_costs'] as Map?)?.isNotEmpty == true &&
          find.byKey(const ValueKey('cost-ai_msg_cheap')).evaluate().isEmpty) {
        throw TestFailure('server action_costs not listed');
      }
    });
    await f.step('Refunds: list from the server, nothing asked', () async {
      final mark = f.httpMark;
      final tile = find.byKey(const Key('credits-refunds'));
      await f.tester.ensureVisible(tile);
      await f.tap(tile, settleSeconds: 4);
      await f.waitFor(
          find.byWidgetPredicate((w) =>
              w.key == const Key('refund-empty') ||
              (w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('refund-purchase-'))),
          what: 'refund list or empty');
      await f.shot('refunds');
      f.expectHttp('GET', '/credits/refunds');
      if (f.h.recorder.hits.skip(mark).any((x) => x.method == 'POST')) {
        throw TestFailure('a POST was sent from the refund list');
      }
      await f.back();
      await f.back();
      await f.backToHome();
    });
  });
}
