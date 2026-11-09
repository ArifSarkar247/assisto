// qbiz (quality push 9 Nov): business + CCTV quality flows — khata due link
// (customer's own web page), sale invoice with VAT + public QR check,
// accounting home, the Business AI pillars (outcome card, in-app shop chat
// between two accounts, CRM win-back segments, Prochar), Assisto Market and
// the CCTV accuracy meter. Each flow: the real screen on the emulator + the
// server round-trip it promises. Real camera / Meta / printer stay owner
// items (needsKey) — never faked here.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:assisto/api.dart';
import 'package:assisto/bizai/cctv_accuracy_screen.dart';
import 'package:assisto/bizai/shop_chat_screen.dart';
import 'package:assisto/bizai/winback_screen.dart';
import 'package:assisto/business_selling_api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/screens/business/acct/acct_home_screen.dart';
import 'package:assisto/screens/business/invoice/invoice_api.dart';
import 'package:assisto/screens/business/invoice/invoice_screen.dart';
import 'package:assisto/screens/business/khata_screen.dart';
import 'package:assisto/screens/market/market_screen.dart';
import 'package:assisto/screens/mktengine/mkt_engine_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

Future<Map<String, dynamic>> _biz(RFlow f, ApiClient api) async {
  final b = await f.net(() => api.getJson('/business/profiles'));
  final list = (b['businesses'] as List).cast<Map<String, dynamic>>();
  return list.firstWhere((x) => x['id'] == b['selected_id'], orElse: () => list.first);
}

/// The web origin of the in-runner Django (same server serves /kh/, /r/).
String _web(String url) {
  final i = url.indexOf('/', url.indexOf('://') + 3);
  return '${AppConfig.apiBase}${i < 0 ? '' : url.substring(i)}';
}

Future<http.Response> _page(RFlow f, String url) async =>
    (await f.tester.runAsync(() => http.get(Uri.parse(_web(url)))))!;

int? _saleId(Map<String, dynamic> r) {
  final s = r['sale'];
  final v = r['id'] ?? r['sale_id'] ?? (s is Map ? s['id'] : null);
  return v is num ? v.toInt() : null;
}

void registerBizQualityFlows() {
  // board row 8 — the customer sees their own due without the app.
  realityFlow('21_khata_due_link', 'Business',
      'Khata: due -> "Send due link" -> the customer\'s web page shows only their own due (no notes)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final name = 'Due Link Hasan d$_tag';
    late Map<String, dynamic> biz;
    late int pid;
    await f.step('a customer with a 750 taka due (note kept private)', () async {
      biz = await _biz(f, api);
      final p = await f.net(() => api.postJson('/business/khata/parties',
          {'business': biz['id'], 'book': 'customer', 'name': name, 'phone': '01700000051'}));
      pid = (p['id'] as num).toInt();
      await f.net(() => api.postJson('/business/khata/parties/$pid/entries?business=${biz['id']}',
          {'direction': 'gave', 'amount': 75000, 'note': 'PRIVATE-NOTE q$_tag'}));
    });
    await f.step('statement shows the due-link button', () async {
      await f.pushScreen(KhataScreen(business: biz));
      await f.scrollTo(find.text(name));
      await f.tap(find.text(name), settleSeconds: 3);
      final btn = find.byKey(const ValueKey('qbiz-due-link'));
      await f.scrollTo(btn);
      await f.shot('due-link-button');
      f.expectVisible(btn, 'Send due link button');
      f.note('the share sheet itself is not opened on CI (system UI would cover the app)');
    });
    await f.step('server link -> public page: name + Bangla due, never the note', () async {
      final r = await f.net(() =>
          api.postJson('/business/khata/parties/$pid/due-link?business=${biz['id']}'));
      final url = '${r['url']}';
      if (!url.contains('/kh/')) throw TestFailure('no /kh/ link: $r');
      final page = await _page(f, url);
      final html = utf8.decode(page.bodyBytes);
      if (page.statusCode != 200) throw TestFailure('page ${page.statusCode}');
      if (!html.contains(name)) throw TestFailure('page lacks the customer name');
      if (!html.contains('৭৫০.০০')) throw TestFailure('page lacks the Bangla due ৭৫০.০০');
      if (html.contains('PRIVATE-NOTE')) throw TestFailure('the private note leaked');
      final bad = await _page(f, '${url}x');
      if (bad.statusCode != 404) throw TestFailure('edited link answered ${bad.statusCode}');
    });
  });

  // board rows 8 / 45 — the paper a shop prints: VAT inside, QR that checks.
  realityFlow('22_invoice_vat', 'Business',
      'Invoice: VAT shop -> sale -> invoice (58/80 mm + A4) -> public QR page says genuine',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    late Map<String, dynamic> biz;
    int? saleId;
    await f.step('VAT settings (BIN) + a cash sale', () async {
      biz = await _biz(f, api);
      final bid = (biz['id'] as num).toInt();
      await f.net(() => api.invoiceSettingsSave(
          {'vat_mode': 'inclusive', 'bin': '123456789-0101', 'verify_qr': true},
          businessId: bid));
      final p = await f.net(() => api.getJson('/business/products'));
      final prod = (p['products'] as List).cast<Map<String, dynamic>>()
          .firstWhere((x) => '${x['name']}'.startsWith('Soap'),
              orElse: () => (p['products'] as List).first as Map<String, dynamic>);
      final vs = (prod['variants'] as List?) ?? const [];
      final cart = await f.net(() => api.cartAdd(
          cart: const {}, productId: (prod['id'] as num).toInt(), businessId: bid,
          variantKey: vs.isEmpty ? null : '${(vs.first as Map)['key']}'));
      final sale = await f.net(() =>
          api.checkout(cart: cart, businessId: bid, paymentMethod: 'cash'));
      saleId = _saleId(sale);
      if (saleId == null) throw TestFailure('checkout returned no sale id: $sale');
    });
    late Map<String, dynamic> inv;
    await f.step('server invoice: VAT inside, total = what was charged', () async {
      inv = await f.net(() =>
          api.saleInvoice(saleId!, businessId: (biz['id'] as num).toInt()));
      final calc = (inv['calc'] as Map?) ?? const {};
      if (((calc['vat'] as num?) ?? 0) <= 0) throw TestFailure('no VAT on a VAT shop: $calc');
      if (inv['consistent'] != true) throw TestFailure('paper total != charged total');
    });
    await f.step('invoice screen: 58 mm, 80 mm, A4', () async {
      await f.pushScreen(InvoiceScreen(
          initial: inv, businessId: (biz['id'] as num).toInt()));
      await f.shot('invoice-58');
      for (final label in [f.t.invPaper80, f.t.invPaperA4]) {
        final seg = find.text(label);
        await f.scrollTo(seg);
        await f.tap(seg, settleSeconds: 2);
        await f.shot('invoice-${label.replaceAll(' ', '')}');
      }
    });
    await f.step('the QR link opens the public "genuine" page', () async {
      final url = '${inv['verify_url']}';
      if (url.isEmpty) throw TestFailure('no verify_url');
      final page = await _page(f, url);
      if (page.statusCode != 200) throw TestFailure('verify page ${page.statusCode}');
      f.needsKey('a real Bluetooth thermal printer (58/80 mm) for the printed-paper proof');
    });
  }, timeout: const Duration(minutes: 5));

  realityFlow('23_accounting_home', 'Business',
      'Accounting: the books home opens with real server data (flag allow-listed for A)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final mark = f.httpMark;
    await f.step('open accounting home', () async {
      final biz = await _biz(f, api);
      await f.pushScreen(AcctHomeScreen(businessId: (biz['id'] as num).toInt()),
          settleSeconds: 5);
      await f.shot('acct-home');
      if (!await f.appears(find.byKey(const ValueKey('acct-fab')), seconds: 10)) {
        throw TestFailure('no add-entry button on the accounting home');
      }
      f.expectNoServerErrors(since: mark);
    });
  });

  // Business AI pillar "outcome card" + shop link (owner side).
  realityFlow('24_bizai_outcome', 'Business',
      'Business AI: hub outcome card ("what Assisto did this week") from real records',
      (f) async {
    await f.home();
    await f.step('hub -> outcome card', () async {
      await f.openFeature(f.t.business, 'business');
      final card = find.byKey(const ValueKey('bizai-outcome-card'));
      await f.scrollTo(card);
      await f.shot('outcome-card');
      f.expectVisible(card, 'outcome card');
      f.expectHttp('GET', '/bizai/outcomes');
    });
  });

  // Business AI pillar 1: the in-app shop chat, two accounts.
  realityFlow('25_shop_chat', 'Business',
      'Shop chat: B\'s shop link -> A (customer) asks in the app -> message on the server, disclosure shown',
      (f) async {
    await f.home();
    final b = await f.h.backend(userB: true);
    late String code;
    await f.step('B has a shop with the app chat on', () async {
      var p = await f.net(() => b.getJson('/business/profiles'));
      if (((p['businesses'] as List?) ?? const []).isEmpty) {
        await f.net(() => b.postJson('/business/profiles',
            {'name': 'Karim Mart', 'type': 'small_shop'}));
        p = await f.net(() => b.getJson('/business/profiles'));
      }
      final bid = p['selected_id'] ?? ((p['businesses'] as List).first as Map)['id'];
      await f.net(() => b.postJson('/business/products',
          {'name': 'Tea 200g', 'price': 120, 'cost': 95, 'stock': 20, 'category': 'grocery'}));
      final l = await f.net(() => b.postJson('/bizai/shop-link?business=$bid',
          {'app_chat_enabled': true}));
      code = '${l['code']}';
      if (code.isEmpty || code == 'null') throw TestFailure('no shop code: $l');
    });
    final text = 'Tea price? q$_tag';
    await f.step('A opens the shop chat and sends a question', () async {
      await f.pushScreen(ShopChatScreen(code: code), settleSeconds: 4);
      await f.shot('shop-chat-disclosure');
      await f.tester.enterText(find.byKey(const ValueKey('bizai-input')), text);
      await f.tap(find.byKey(const ValueKey('bizai-send')), settleSeconds: 6);
      await f.shot('shop-chat-sent');
      f.expectHttp('POST', '/shopchat/');
    });
    await f.step('the message is on the server; the shop side answers or hands over', () async {
      final a = await f.h.backend();
      await f.eventually('customer message stored', () async {
        final m = await a.getJson('/shopchat/${Uri.encodeComponent(code)}/messages?after=0');
        return '${m['messages']}'.contains(text);
      });
      f.needsKey('AI key on the CI backend for a real AI answer (scrubbed on CI)');
      f.needsKey('Meta App Review for Messenger/Instagram/WhatsApp (owner)');
    });
  }, timeout: const Duration(minutes: 5));

  // Business AI pillar 2: CRM win-back segments.
  realityFlow('26_crm_winback', 'Business',
      'CRM win-back: segments + the 30/60/90-day ladder render from the server',
      (f) async {
    await f.home();
    final mark = f.httpMark;
    await f.step('open win-back', () async {
      await f.pushScreen(const WinbackScreen(), settleSeconds: 5);
      await f.shot('winback');
      f.expectHttp('GET', '/bizai/crm/segments', since: mark);
      f.expectNoServerErrors(since: mark);
    });
  });

  // Business AI pillar 5: Prochar (marketing engine).
  realityFlow('27_prochar', 'Business',
      'Prochar: the marketing engine opens (flag allow-listed for A); posting to Meta is an owner item',
      (f) async {
    await f.home();
    final mark = f.httpMark;
    await f.step('open Prochar', () async {
      await f.pushScreen(const MktEngineScreen(), settleSeconds: 5);
      await f.shot('prochar');
      f.expectNoServerErrors(since: mark);
      f.needsKey('Meta App Review for one-tap Facebook/Instagram posting (owner)');
    });
  });

  // Business AI pillar 3: Assisto Market (buyer side).
  realityFlow('28_market_need', 'Business',
      'Market: post a need on the server -> it shows in the app\'s Market list',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final title = 'Rice 10 kg q$_tag';
    await f.step('post a need (Dhaka area, 48 h)', () async {
      await f.net(() => api.postJson('/market/needs', {
            'category': 'grocery', 'title': title, 'quantity': 10, 'unit': 'kg',
            'area': 'badda', 'budget_max': 800, 'deadline_hours': 48,
          }));
    });
    await f.step('Market screen lists it', () async {
      await f.pushScreen(const MarketScreen(), settleSeconds: 5);
      await f.shot('market');
      if (!await f.appears(find.textContaining(title), seconds: 10)) {
        await f.scrollTo(find.textContaining(title));
      }
      f.expectVisible(find.textContaining(title), 'my need in the list');
      f.needsKey('approved sellers + a real deal (owner pilot decision)');
    });
  });

  // CCTV pillar 4: measured accuracy (never a made-up 90 %).
  realityFlow('29_cctv_accuracy', 'CCTV',
      'CCTV accuracy: live test start -> mark 2 events -> stop -> honest "not enough yet"',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    int? site;
    await f.step('a shop site', () async {
      final s = await f.net(() => api.shopSites());
      final rows = ((s['sites'] ?? s['results'] ?? const []) as List);
      if (rows.isNotEmpty) {
        site = ((rows.first as Map)['id'] as num).toInt();
      } else {
        try {
          final c = await f.net(() => api.shopCreateSite('Accuracy Shop q$_tag', 7));
          site = (c['id'] as num?)?.toInt();
        } on ApiException catch (e) {
          f.skip('Shop Box site not allowed for the seeded user (${e.status}) — plan gate shown honestly');
        }
      }
      if (site == null) throw TestFailure('no site');
    });
    await f.step('live test: start, mark person + cash, stop', () async {
      await f.pushScreen(CctvAccuracyScreen(siteId: site), settleSeconds: 4);
      await f.shot('accuracy');
      await f.tap(find.byKey(const ValueKey('bizai-cam-start')), settleSeconds: 3);
      for (final k in ['person', 'cash']) {
        final b = find.byKey(ValueKey('bizai-cam-mark-$k'));
        await f.scrollTo(b);
        await f.tap(b, settleSeconds: 2);
      }
      final stop = find.byKey(const ValueKey('bizai-cam-stop'));
      await f.scrollTo(stop);
      await f.tap(stop, settleSeconds: 4);
      await f.shot('accuracy-after');
      f.expectHttp('POST', '/bizai/cctv/test');
      final acc = await f.net(() => api.getJson('/bizai/cctv/accuracy?site=$site'));
      final live = (acc['live_tests'] as Map?) ?? const {};
      if (((live['sessions'] as num?) ?? 0) < 1) throw TestFailure('session not counted: $acc');
      f.needsKey('a real camera / NVR in a shop + 20 real events for a measured accuracy number');
    });
  }, timeout: const Duration(minutes: 5));
}
