// plans-credits (board row 7) — PLANS & CREDITS PROOF on the emulator.
// Run by e2e.yml with group=start+payproof (settings_e2eproof). The payment
// "bank" is backend/ci_e2e/fake_gateway.py: a CI-only PaymentGateway, OFF
// until this flow turns it on — no money, no network, no real keys. Every
// step between the tap and the balance is REAL server code (checkout ->
// order -> server-to-server verify with amount/currency/tx checks -> grant
// -> ledger). A = Reality Rahim (this app), B = Reality Karim (guardian).
//
//   pay01  buy a plan   -> the Plans page shows the new plan (server: /me/usage-summary)
//   pay02  buy credits  -> "Buy credits" in the first card -> packs -> balance + pack credits
//   pay03  failed charge -> honest "not completed, no money taken"; a wrong-amount
//                           "paid" is refused; balance unchanged; refund request path
//   pay04  spend to zero -> the AI chat opens the "credits finished" sheet with
//                           packs; buying there lands credits and re-sends once
//   pay05  safety at zero -> SOS still reaches the guardian with 0 credits
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/billing/refund_screen.dart';
import 'package:assisto/payments/checkout_sheet.dart';
import 'package:assisto/payments/payments_api.dart' show debugPayFlavour;
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/screens/plans_screen.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';

import '../support/harness.dart';

ApiClient _apiA(RFlow f) {
  final c = ApiClient.detached(f.app.api.token ?? '');
  c.lang = 'en';
  return c;
}

/// The merchant tx id of the last "opened" gateway page (the fake bank URL).
String _lastTx = '';

void _hookLauncher() {
  debugPayFlavour = 'apk'; // the gateway channel (the Play build uses Play Billing)
  CheckoutSheet.launcher = (u) async {
    _lastTx = u.queryParameters['tx'] ?? '';
    return u.host == 'ci-fake-pay.invalid' && _lastTx.isNotEmpty;
  };
}

Future<void> _fakePay(RFlow f, ApiClient api, Map<String, dynamic> body) async {
  final r = await f.net(() => api.postJson('/ci-e2e/pay', body));
  if (r['ok'] != true) throw TestFailure('fake gateway refused $body: $r');
}

Future<int> _usable(RFlow f, ApiClient api) async =>
    ((await f.net(() => api.getJson('/credits/state')))['now_usable'] as num).toInt();

Finder _sees(String s) => find.byWidgetPredicate((w) =>
    (w is Text && (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s)) ||
    (w is RichText && w.text.toPlainText().contains(s)));

/// In the open checkout sheet: pay through the gateway, let the fake bank
/// answer [result], tap "I have paid — check now".
Future<void> _checkout(RFlow f, ApiClient api, String result, {String shot = ''}) async {
  await f.waitFor(find.byKey(const ValueKey('pay-option-gateway')), what: 'gateway option');
  _lastTx = '';
  await f.tap(find.byKey(const ValueKey('pay-option-gateway')), settleSeconds: 3);
  await f.waitFor(find.text(f.t.payCheckNow), seconds: 20, what: 'waiting for the payment page');
  if (_lastTx.isEmpty) throw TestFailure('no gateway page was opened');
  if (shot.isNotEmpty) await f.shot('$shot-waiting');
  await _fakePay(f, api, {'tx': _lastTx, 'result': result});
  await f.tap(find.text(f.t.payCheckNow), settleSeconds: 4);
}

void registerPayProofFlows() {
  realityFlow('pay01_buy_plan', 'Plans & credits proof',
      'Buy a plan: Plans -> Choose -> gateway (CI fake bank) -> paid -> the plan shows on the page',
      (f) async {
    await f.home();
    final api = _apiA(f);
    _hookLauncher();
    await _fakePay(f, api, {'op': 'on'});
    await f.step('Plans page: choose Business -> pay -> success', () async {
      await f.pushScreen(const PlansScreen(), settleSeconds: 4);
      final buy = find.byKey(const ValueKey('plan-buy-business'));
      await f.scrollToBuilt(buy, what: 'Business Choose button');
      await f.shot('plans');
      await f.tap(buy, settleSeconds: 3);
      await _checkout(f, api, 'paid', shot: 'plan');
      await f.waitFor(find.text(f.t.paySuccessTitle), seconds: 20, what: 'payment success');
      await f.shot('plan-paid');
      await f.tap(find.text(f.t.payDone), settleSeconds: 4);
    });
    await f.step('server + screen: the plan is Business now', () async {
      await f.eventually('server plan = business', () async =>
          (await api.getJson('/me/usage-summary'))['plan'] == 'business');
      final rows = await f.net(() => api.plansPublic());
      final name = '${rows.firstWhere((r) => r['id'] == 'business')['name']}';
      await f.waitFor(_sees(name), seconds: 15, what: 'current plan name on the page');
      await f.shot('plan-now-business');
    });
  }, timeout: const Duration(minutes: 5));

  realityFlow('pay02_buy_credits', 'Plans & credits proof',
      'Buy credits: "Buy credits" on the first screen -> packs -> pay -> balance grows by the pack',
      (f) async {
    await f.home();
    final api = _apiA(f);
    _hookLauncher();
    await _fakePay(f, api, {'op': 'on'});
    final before = await _usable(f, api);
    final packs = await f.net(() => api.creditsPacks());
    final p50 = packs.firstWhere((p) => '${p['code'] ?? p['id']}' == 'p50');
    final add = (p50['credits'] as num).toInt();
    await f.step('Plans: "Buy credits" is on screen at once (not under the trial card)', () async {
      await f.pushScreen(const PlansScreen(), settleSeconds: 4);
      final b = find.byKey(const Key('plans-buy-credits')).hitTestable();
      await f.waitFor(b, what: 'Buy credits button visible without scrolling');
      await f.shot('buy-credits-visible');
      await f.tap(b, settleSeconds: 4);
    });
    await f.step('Credits page opens ON the packs; buy p50 -> paid', () async {
      final pack = find.byKey(const ValueKey('pack-buy-p50')).hitTestable();
      await f.waitFor(pack, what: 'pack visible without scrolling');
      await f.shot('packs');
      await f.tap(pack, settleSeconds: 3);
      await _checkout(f, api, 'paid', shot: 'pack');
      await f.waitFor(find.text(f.t.paySuccessTitle), seconds: 20, what: 'payment success');
      await f.tap(find.text(f.t.payDone), settleSeconds: 5);
    });
    await f.step('balance = before + the pack (server and screen agree)', () async {
      final after = await _usable(f, api);
      if (after != before + add) throw TestFailure('balance $before -> $after, pack gives $add');
      final shown = f.tester.widget<Text>(find.byKey(const Key('credits-now'))).data ?? '';
      final ascii = shown.split('').map((c) {
        final u = c.codeUnitAt(0);
        return (u >= 0x09E6 && u <= 0x09EF) ? String.fromCharCode(0x30 + u - 0x09E6) : c;
      }).join().replaceAll(',', '');
      if (ascii != '$after') throw TestFailure('screen shows $shown, server $after');
      await f.shot('balance-after');
      f.note('balance $before -> $after (+$add, pack p50)');
    });
  }, timeout: const Duration(minutes: 5));

  realityFlow('pay03_failed_charge', 'Plans & credits proof',
      'Failed charge: honest "not completed, no money taken", wrong amount refused, nothing granted; refund request path',
      (f) async {
    await f.home();
    final api = _apiA(f);
    _hookLauncher();
    await _fakePay(f, api, {'op': 'on'});
    final before = await _usable(f, api);
    await f.step('the bank says FAILED -> the sheet says so (never "still pending")', () async {
      await f.pushScreen(const CreditsScreen(jumpToPacks: true), settleSeconds: 5);
      await f.tap(find.byKey(const ValueKey('pack-buy-p20')).hitTestable(), settleSeconds: 3);
      await _checkout(f, api, 'failed', shot: 'failed');
      await f.waitFor(find.text(f.t.payFailedTitle), seconds: 20, what: 'payment not completed');
      await f.waitFor(find.text(f.t.payFailedBody), what: 'no money taken line');
      await f.shot('charge-failed');
      if (await _usable(f, api) != before) throw TestFailure('credits changed on a failed charge');
      await f.back();
    });
    await f.step('the bank says PAID but for a wrong amount -> refused, nothing granted', () async {
      await f.tap(find.byKey(const ValueKey('pack-buy-p20')).hitTestable(), settleSeconds: 3);
      await _checkout(f, api, 'paid_wrong_amount', shot: 'wrong-amount');
      await f.waitFor(_sees(f.t.payStillPending), seconds: 20, what: 'not confirmed line');
      await f.shot('wrong-amount-refused');
      if (await _usable(f, api) != before) throw TestFailure('credits granted for a wrong amount');
      await f.back();
    });
    await f.step('Refunds: the paid pack from pay02 can be asked back (request sent)', () async {
      await f.pushScreen(const RefundScreen(), settleSeconds: 4);
      final ask = find.byWidgetPredicate((w) =>
          w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('refund-ask-'));
      await f.scrollToBuilt(ask, what: 'a refundable purchase');
      await f.tap(ask.first, settleSeconds: 2);
      await f.enter('CI proof: please refund this test pack', label: f.t.billRefundReasonLabel);
      await f.tap(find.byKey(const Key('refund-send')), settleSeconds: 4);
      await f.eventually('a pending refund request on the server', () async {
        final r = await api.getJson('/credits/refunds');
        return ((r['requests'] as List?) ?? const []).cast<Map>().any((x) => x['status'] == 'pending');
      });
      await f.shot('refund-requested');
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('pay04_zero_credits_sheet_buy', 'Plans & credits proof',
      'Spend to zero -> AI chat opens the honest "credits finished" sheet with packs -> buy -> answer comes',
      (f) async {
    await f.home();
    final api = _apiA(f);
    _hookLauncher();
    await _fakePay(f, api, {'op': 'on'});
    await f.step('spend every credit (real spend path) -> 0', () async {
      final r = await f.net(() => api.postJson('/ci-e2e/pay', {'op': 'drain'}));
      if ((r['now_usable'] as num?)?.toInt() != 0) throw TestFailure('not at zero: $r');
    });
    await f.step('ask the AI at 0 credits -> the "credits finished" sheet, typed text kept', () async {
      await f.pushScreen(const AiChatScreen());
      await f.enter('Explain how compound interest works with a Dhaka example',
          label: f.t.aichatInputHint);
      await f.tapTooltip(f.t.aichatSend, settleSeconds: 5);
      await f.waitFor(find.byKey(const Key('credout-title')), seconds: 25, what: 'credits-out sheet');
      await f.waitFor(find.byKey(const ValueKey('credout-pack-pack_p20')), what: 'a pack to buy');
      await f.shot('credits-finished');
    });
    await f.step('buy a pack from the sheet -> credits land -> the question is answered', () async {
      await f.tap(find.byKey(const ValueKey('credout-pack-pack_p20')), settleSeconds: 3);
      await _checkout(f, api, 'paid', shot: 'credout');
      await f.waitFor(find.text(f.t.paySuccessTitle), seconds: 20, what: 'payment success');
      await f.tap(find.text(f.t.payDone), settleSeconds: 8);
      await f.waitFor(_sees('(CI)'), seconds: 40, what: 'the AI answer after the purchase');
      final left = await _usable(f, api);
      if (left <= 0) throw TestFailure('the bought pack never landed (now $left)');
      f.note('after the sheet purchase + one answer: $left credits');
      await f.shot('answered-after-buy');
    });
  }, timeout: const Duration(minutes: 6));

  realityFlow('pay05_safety_at_zero', 'Plans & credits proof',
      'Safety never paywalled: at 0 credits SOS still reaches guardian B', (f) async {
    await f.home();
    final api = _apiA(f);
    final apiB = await f.h.backend(userB: true);
    final r = await f.net(() => api.postJson('/ci-e2e/pay', {'op': 'drain'}));
    if ((r['now_usable'] as num?)?.toInt() != 0) throw TestFailure('not at zero: $r');
    await f.step('0 credits: hold SOS -> sent', () async {
      await f.openFeature(f.t.moduleEmergency, 'emergency');
      final btn = find.byKey(const ValueKey('sosat-sos-hold'));
      await f.waitFor(btn, what: 'SOS hold button');
      await f.tester.ensureVisible(btn);
      final g = await f.tester.startGesture(f.tester.getCenter(btn));
      await f.pumpFor(const Duration(milliseconds: EmergencySosPanel.holdMs + 600));
      await g.up();
      await f.eventually('SOS sent (POST /family/sos 2xx)', () async =>
          f.h.recorder.hits.any((h) => h.method == 'POST' && h.path.startsWith('/family/sos') &&
              h.status >= 200 && h.status < 300), seconds: 30);
      await f.shot('sos-at-zero');
    });
    await f.step('B received the SOS; A still at 0 (nothing charged)', () async {
      await f.eventually('B received an SOS', () async {
        final b = await apiB.getJson('/family/alerts');
        return (b['received'] as List).cast<Map>().any((x) => x['kind'] == 'sos' && x['active'] != false);
      });
      if (await _usable(f, api) != 0) throw TestFailure('safety charged credits');
    });
    await f.net(() => api.postJson('/family/sos/resolve'));
    await _fakePay(f, api, {'op': 'off'});
  }, timeout: const Duration(minutes: 4));
}
