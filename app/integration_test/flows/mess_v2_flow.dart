// messv2 — Mess and bachelor V2 on the CI emulator against the throw-away
// seeded Django (seed_reality). A = the phone under test (UI), B = the second
// account (independent API client, like family_circle_flow).
//
//   A creates "Reality Mess <tag>" (UI) -> adds B from My Circle (UI picker)
//   -> B sees the mess group in My Circle (API) -> B turns off tomorrow's
//   breakfast + enters bazar ৳500 (API, B's own account) -> A enters Wi-Fi
//   ৳700 (UI) -> A closes the month (UI) -> month math checked to the poisha.
//
// Honest limit: the seed has two connected accounts, so this run proves
// A + B; the 4-member owner scenario (3 added members, Wi-Fi 700, rent by
// seat, deposits, carry forward) is proven in backend/core/tests_messv2.py.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/mess_accounting_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void registerMessV2Flows() {
  realityFlow('41_mess_v2', 'Mess and bachelor',
      'Mess V2: create -> add B from My Circle -> group -> meals/bazar (B) + Wi-Fi 700 (A) -> close month math',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    final name = 'Reality Mess $_tag';
    late int mid;
    await f.step('A creates the mess with a name (UI)', () async {
      await f.pushScreen(const MessAccountingScreen());
      await f.tap(find.byKey(const ValueKey('mess-create')));
      final premium = await f.appears(find.byKey(const ValueKey('mess-premium-go')), seconds: 3);
      if (premium) {
        throw TestFailure('A already runs a mess on this DB (free limit) — seed not fresh');
      }
      await f.tester.enterText(find.byKey(const ValueKey('mess-name')), name);
      await f.tap(find.byKey(const ValueKey('mess-settings-save')), settleSeconds: 4);
      f.expectHttp('POST', '/mess/v2');
      final list = await f.net(() => api.getJson('/mess/v2'));
      final m = (list['messes'] as List).cast<Map>().firstWhere((x) => x['name'] == name);
      mid = (m['id'] as num).toInt();
      await f.shot('mess_created');
    });
    await f.step('A adds B from My Circle (UI) -> the mess group appears for B', () async {
      await f.tap(find.text(f.t.mv2TabMembers));
      await f.tap(find.byKey(const ValueKey('mess-add-member')), settleSeconds: 3);
      await f.shot('circle_picker');
      await f.tap(find.text(f.t.mv2Add).first, settleSeconds: 3);
      f.expectHttp('POST', '/mess/v2/$mid/members');
      await f.tap(find.byKey(const ValueKey('mess-pick-done')));
      await f.eventually('B sees the mess group', () async {
        final g = await apiB.getJson('/circle/groups');
        return (g['results'] as List).cast<Map>().any((x) => x['name'] == name);
      });
      await f.shot('member_added');
    });
    await f.step('B (own account) turns off tomorrow breakfast + enters bazar 500', () async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await f.net(() => apiB.postJson('/mess/v2/$mid/meals',
          {'date': _iso(tomorrow), 'b': 0, 'l': 1, 'd': 1, 'client_id': 'r-b-meal-$_tag'}));
      await f.net(() => apiB.postJson('/mess/v2/$mid/entries', {
            'kind': 'bazar', 'date': _iso(DateTime.now()), 'amount': 50000,
            'data': {'items': 'rice, oil'}, 'client_id': 'r-b-bazar-$_tag'}));
    });
    await f.step('A enters Wi-Fi 700 (UI)', () async {
      await f.tap(find.text(f.t.mv2TabMoney));
      await f.tap(find.byKey(const ValueKey('mess-add-charge')));
      await f.tap(find.byKey(const ValueKey('charge-wifi')), settleSeconds: 0.5);
      await f.tester.ensureVisible(find.byKey(const ValueKey('entry-amount')));
      await f.tester.enterText(find.byKey(const ValueKey('entry-amount')), '700');
      await f.tap(find.byKey(const ValueKey('entry-save')), settleSeconds: 3);
      f.expectHttp('POST', '/mess/v2/$mid/entries');
      await f.shot('wifi_added');
    });
    // gap-money: the edit history says WHAT changed, not only who and when
    await f.step('A opens edit history -> sees the Wi-Fi amount (৳700)', () async {
      await f.tapTooltip(f.t.mv2History, settleSeconds: 3);
      f.expectHttp('GET', '/mess/v2/$mid/history');
      await f.waitFor(find.textContaining(RegExp('700|\u09ed\u09e6\u09e6')),
          what: 'history row with the Wi-Fi amount');
      await f.shot('history_what_changed');
      // close the sheet by its barrier (top of the screen), not Back
      await f.tester.tapAt(const Offset(24, 96));
      await f.pumpFor(const Duration(milliseconds: 1200));
    });
    await f.step('A closes the month (UI) -> math checked', () async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      if (tomorrow.day > 28) {
        f.note('month close skipped: a mess month that ends today needs start day ${tomorrow.day} (>28)');
        return;
      }
      // make TODAY the month's last day (start day = tomorrow's date)
      await f.net(() => api.postJson('/mess/v2/$mid/edit', {'month_start_day': tomorrow.day}));
      await f.tap(find.text(f.t.mv2TabMeals));
      await f.tap(find.text(f.t.mv2TabMonth), settleSeconds: 3);
      // gatefix: the per-member cards (design2) push "Close month" below the
      // fold of the lazy list — scroll to it like a finger (run 44061721110)
      final close = find.byKey(const ValueKey('mess-close-month'));
      await f.scrollToBuilt(close, what: 'Close month button');
      await f.tap(close);
      await f.tap(find.byKey(const ValueKey('mess-confirm-yes')), settleSeconds: 4);
      f.expectHttp('POST', '/mess/v2/$mid/close');
      // the closed period started on start-day of the PREVIOUS month
      final now = DateTime.now();
      final prev = DateTime(now.year, now.month - 1, 1);
      final key = _iso(prev).substring(0, 7);
      final d = await f.net(() => api.getJson('/mess/v2/$mid?month=$key'));
      if ((d['month'] as Map)['closed'] != true) throw TestFailure('month $key not closed: ${d['month']}');
      final s = (d['summary'] as Map).cast<String, dynamic>();
      // today only: A 2.5 + B 2.5 meals; bazar 500 -> rate 100/meal;
      // Wi-Fi 700 split 350 each; nobody deposited -> each will pay 600.
      if (s['meals_total_milli'] != 5000 || s['bazar_total'] != 50000) {
        throw TestFailure('totals wrong: $s');
      }
      final dues = (s['members'] as List).cast<Map>().map((r) => r['due']).toList();
      if (dues.length != 2 || dues.any((x) => x != 60000)) throw TestFailure('dues wrong: $dues');
      f.note('month $key closed; each will pay 600; reconciles=${s['reconciles']}');
      final rep = await f.net(() => api.getJson('/mess/v2/$mid/report'));
      f.note('report: ${rep['text']}');
      await f.shot('month_closed');
    });
  });
}
