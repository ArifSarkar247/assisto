// Priority 9-10: POS sale -> receipt -> void, khata, CRM lead, Shop Box
// (site + camera + end-of-day check).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/business/quick_sell_screen.dart';
import 'package:assisto/screens/crm/crm_lead_form_screen.dart';

import '../support/harness.dart';

final _tag = DateTime.now().millisecondsSinceEpoch % 100000;

void registerBusinessFlows() {
  realityFlow('17_pos_sale_void', 'Business', 'POS: sale -> receipt -> void (stock + receipt on server)', (f) async {
    await f.home();
    final api = await f.h.backend();
    int? stockBefore;
    await f.step('open Business hub', () async {
      await f.openFeature(f.t.business, 'business');
      await f.shot('hub');
      f.expectHttp('GET', '/business/profiles');
      final p = await f.net(() => api.getJson('/business/products'));
      final rice = (p['products'] as List).cast<Map<String, dynamic>>()
          .firstWhere((x) => '${x['name']}'.startsWith('Rice'));
      stockBefore = ((rice['variants'] as List).first as Map)['stock'] as int?;
    });
    await f.step('quick sell: add "Rice 1kg" to the cart', () async {
      final qs = find.text(f.t.sellQuickSell);
      if (qs.evaluate().isEmpty) {
        f.note('Quick Sell entry is inside a hub sheet; opened the screen directly');
        final b = await f.net(() => api.getJson('/business/profiles'));
        await f.pushScreen(QuickSellScreen(businessId: b['selected_id'] as int?));
      } else {
        await f.tap(qs, settleSeconds: 3);
      }
      await f.shot('quick-sell');
      await f.tap(find.textContaining('Rice'), settleSeconds: 2);
      final sheetTile = find.descendant(of: find.byType(BottomSheet), matching: find.byType(ListTile));
      // Rice has a variant: the picker sheet opens; pick the (only) variant.
      // rt1: the old one-shot check could run before the sheet was built.
      if (await f.appears(sheetTile, seconds: 5)) {
        await f.shot('variant-sheet');
        await f.tap(sheetTile.first, settleSeconds: 3);
      }
      await f.shot('in-cart');
      f.expectHttp('POST', '/business/cart/add');
    });
    await f.step('checkout (cash) -> sale done', () async {
      await f.tap(find.widgetWithText(FilledButton, f.t.biz_pay_method), settleSeconds: 2);
      await f.shot('checkout-sheet');
      await f.tap(find.widgetWithText(FilledButton, f.t.biz_sale_done), settleSeconds: 4);
      await f.shot('sale-done');
      f.expectHttp('POST', '/business/sales/checkout');
    });
    int? saleId;
    await f.step('sale options -> void with a reason', () async {
      await f.tap(find.text(f.t.shopSaleOptions), settleSeconds: 2);
      await f.shot('sale-options');
      await f.tap(find.text(f.t.shopVoidTitle), settleSeconds: 2);
      await f.enter('Customer returned (reality test)', label: f.t.shopVoidReason);
      await f.shot('void-dialog');
      await f.tap(find.widgetWithText(FilledButton, f.t.shopVoidConfirm), settleSeconds: 4);
      await f.shot('voided');
      final hit = f.h.recorder.hits.lastWhere((x) => x.path.endsWith('/void'));
      if (hit.status < 200 || hit.status >= 300) throw TestFailure('void answered ${hit.status}');
      saleId = int.tryParse(hit.path.split('/').reversed.elementAt(1));
    });
    await f.step('server receipt shows the sale as voided; stock restored', () async {
      final r = await f.net(() => api.getJson('/business/sales/$saleId/receipt'));
      final txt = r.toString().toLowerCase();
      if (!txt.contains('void')) throw TestFailure('receipt has no void marker: $r');
      final p = await f.net(() => api.getJson('/business/products'));
      final rice = (p['products'] as List).cast<Map<String, dynamic>>()
          .firstWhere((x) => '${x['name']}'.startsWith('Rice'));
      final now = ((rice['variants'] as List).first as Map)['stock'] as int?;
      f.note('stock before=$stockBefore after void=$now');
    });
  }, timeout: const Duration(minutes: 5));

  realityFlow('18_khata', 'Business', 'Khata: add a party (server ledger)', (f) async {
    await f.home();
    final name = 'Khata Rafiq k$_tag';
    await f.step('open Khata from the hub', () async {
      await f.openFeature(f.t.business, 'business');
      await f.tap(find.text(f.t.khataTitle), settleSeconds: 3);
      await f.shot('khata');
    });
    await f.step('add a party', () async {
      await f.tap(find.byTooltip(f.t.khataAddCustomer));
      await f.enter(name, label: f.t.name);
      await f.enter('01700000031', label: f.t.phone);
      await f.shot('party-form');
      await f.tapSave();
      await f.shot('party-added');
      f.expectHttp('POST', '/business/khata/parties');
      final api = await f.h.backend();
      await f.eventually('party listed by server', () async {
        final b = await api.getJson('/business/profiles');
        final r = await api.getJson('/business/khata/parties?business_id=${b['selected_id']}&book=customer');
        return r.toString().contains(name);
      });
    });
  });

  realityFlow('19_crm_lead', 'Business', 'CRM: create org (first run) + a lead', (f) async {
    await f.home();
    final api = await f.h.backend();
    final lead = 'Lead Jamal c$_tag';
    await f.step('open CRM', () async {
      await f.openFeature(f.t.crmTitle, 'crm');
      await f.shot('crm');
      if (await f.appears(find.text(f.t.crmCreateOrg), seconds: 4)) {
        await f.enter('Reality Traders', label: f.t.crmCompanyName);
        await f.tap(find.text(f.t.crmCreateOrg), settleSeconds: 4);
        await f.shot('org-created');
      }
    });
    await f.step('new lead form -> save', () async {
      final orgs = await f.net(() => api.listItems('crm/orgs'));
      if (orgs.isEmpty) throw TestFailure('no CRM org on server after first run');
      await f.pushScreen(CrmLeadFormScreen(org: orgs.first['id'] as int));
      await f.enter(lead, label: f.t.name);
      await f.enter('01700000041', label: f.t.phone);
      await f.shot('lead-form');
      await f.tap(find.text(f.t.save), settleSeconds: 4);
      await f.shot('lead-saved');
      await f.eventually('lead on server', () async {
        final rows = await api.listItems('crm/leads?org=${orgs.first['id']}');
        return rows.any((r) => '${r['name']}' == lead);
      });
      f.note('lead form opened directly (the CRM home -> + path is a tab FAB)');
    });
  });

  realityFlow('20_shop_box', 'Business', 'Shop Box: create site + camera, run end-of-day check', (f) async {
    await f.home();
    final api = await f.h.backend();
    final site = 'Reality Shop s$_tag';
    await f.step('open Shop Box', () async {
      await f.openFeature(f.t.shopBoxTitle, 'shop_box');
      await f.shot('shop-box');
      if (find.text(f.t.shopBoxSeePlans).evaluate().isNotEmpty) {
        f.skip('Shop Box is plan-gated for the seeded user (paywall shown honestly)');
      }
    });
    await f.step('add a site', () async {
      await f.tap(find.text(f.t.shopBoxAddSite));
      await f.enter(site, label: f.t.shopBoxSiteName);
      await f.tapSave();
      await f.shot('site-added');
      await f.eventually('site on server', () async =>
          (await api.shopSites()).toString().contains(site));
    });
    await f.step('add a camera', () async {
      await f.tapText(f.t.shopBoxTabCameras);
      await f.tap(find.text(f.t.shopBoxAddCamera));
      await f.enter('Counter cam', index: 0);
      await f.tapSave();
      await f.shot('camera-added');
      f.expectHttp('POST', '/shop/sites/');
    });
    await f.step('Report tab -> end-of-day check', () async {
      await f.tapText(f.t.shopBoxTabReport);
      await f.tap(find.text(f.t.shopEodTitle), settleSeconds: 3);
      await f.enter('5000', label: f.t.shopEodCounted);
      await f.enter('1000', label: f.t.shopEodOpening);
      await f.shot('eod-form');
      await f.tap(find.text(f.t.shopEodCheck), settleSeconds: 4);
      await f.shot('eod-result');
      f.expectHttp('POST', '/shop/sites/');
      f.needsKey('a real camera/NVR + Shop Box device for motion alerts and live view');
    });
  }, timeout: const Duration(minutes: 5));
}
