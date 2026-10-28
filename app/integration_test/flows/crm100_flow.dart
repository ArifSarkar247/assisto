// crm100 reality flow (business group): a price quote from the catalog ->
// the CUSTOMER accepts it on the public web page (no app, no login) -> one
// order on the server with stock taken -> the seller's ONE customer history
// page shows the quote, the order and the khata, and the send sheet offers
// WhatsApp / phone SMS / Assisto SMS with the cost first.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:assisto/config.dart';
import 'package:assisto/screens/crm/crm100_api.dart';
import 'package:assisto/screens/crm/customer_history_screen.dart';

import '../support/harness.dart';

void registerCrm100Flows() {
  realityFlow('18c_crm100_quote_history', 'Business',
      'CRM: quote -> customer accepts on the web page -> order + stock -> one history page',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    late int bizId;
    late int quoteId;
    late String url;
    int? stockBefore;
    late int riceId;
    const phone = '01700000021'; // the seeded khata customer "Selim (khata)"
    await f.step('make a quote from the catalog (server prices)', () async {
      final b = await f.net(() => api.getJson('/business/profiles'));
      bizId = (b['selected_id'] as num).toInt();
      final cat = await f.net(() => api.getJson('/crm/shop-quotes/catalog/?business=$bizId'));
      final rice = (cat['results'] as List).cast<Map<String, dynamic>>()
          .firstWhere((x) => '${x['name']}'.startsWith('Rice'));
      riceId = (rice['id'] as num).toInt();
      stockBefore = ((rice['variants'] as List).first as Map)['stock'] as int?;
      final q = await f.net(() => api.postJson('/crm/shop-quotes/', {
            'business': bizId, 'customer_name': 'Selim', 'customer_phone': phone,
            'items': [{'product_id': riceId, 'qty': 2}], 'valid_days': 3, 'payment': 'cod',
          }));
      quoteId = (q['id'] as num).toInt();
      url = '${q['path']}';
      if ((q['total_poisha'] as num).toInt() <= 0) throw TestFailure('no server price: $q');
      f.note('quote $quoteId total=${q['total_poisha']} path=$url');
    });
    await f.step('the customer opens the link and accepts (no login)', () async {
      final page = Uri.parse('${AppConfig.apiBase}$url?lang=bn');
      final g = await f.net(() => http.get(page));
      if (g.statusCode != 200) throw TestFailure('quote page ${g.statusCode}');
      if (!g.body.contains('noindex')) throw TestFailure('quote page is indexable');
      final csrf = RegExp(r'name="csrfmiddlewaretoken" value="([^"]+)"').firstMatch(g.body);
      final cookie = RegExp(r'csrftoken=([^;]+)').firstMatch(g.headers['set-cookie'] ?? '');
      if (csrf == null || cookie == null) throw TestFailure('no accept form on the page');
      final p = await f.net(() => http.post(page,
          headers: {'Cookie': 'csrftoken=${cookie.group(1)}', 'Referer': page.toString()},
          body: {'csrfmiddlewaretoken': csrf.group(1)!, 'action': 'accept',
                 'name': 'Selim', 'address': 'Mirpur 10, Dhaka'}));
      if (p.statusCode != 302) throw TestFailure('accept answered ${p.statusCode}');
    });
    await f.step('server: accepted, ONE order, stock taken', () async {
      await f.eventually('quote accepted with an order', () async {
        final q = await api.getJson('/crm/shop-quotes/$quoteId/?business=$bizId');
        return q['state'] == 'accepted' && q['order'] != null;
      });
      final cat = await f.net(() => api.getJson('/crm/shop-quotes/catalog/?business=$bizId'));
      final rice = (cat['results'] as List).cast<Map<String, dynamic>>()
          .firstWhere((x) => x['id'] == riceId);
      final now = ((rice['variants'] as List).first as Map)['stock'] as int?;
      f.note('stock before=$stockBefore after=$now');
      if (stockBefore != null && now != stockBefore! - 2) {
        throw TestFailure('stock not taken: $stockBefore -> $now');
      }
    });
    await f.step('the one customer history page shows quote + order + khata', () async {
      await f.pushScreen(CustomerHistoryScreen(
          target: const CustomerTarget(phone: phone), name: 'Selim', business: bizId));
      await f.shot('history');
      f.expectHttp('GET', '/crm/customers/history/');
      if (!await f.appears(find.text(f.t.c100QuoteTitle), seconds: 8)) {
        throw TestFailure('the quote is not on the history page');
      }
      await f.scrollTo(find.textContaining(f.t.c100OrderTitle('').trim()));
      await f.shot('history-order');
    });
    await f.step('message: three ways, the cost first, nothing sent', () async {
      await f.scrollTo(find.text(f.t.c100ActMessage));
      await f.tap(find.text(f.t.c100ActMessage), settleSeconds: 2);
      await f.tap(find.text(f.t.c100ChooseHow), settleSeconds: 3);
      await f.shot('send-sheet');
      f.expectHttp('POST', '/crm/send/preview');
      if (!await f.appears(find.text(f.t.c100WayWa))) throw TestFailure('no WhatsApp way');
      await f.tap(find.byType(OutlinedButton).last, settleSeconds: 2); // Cancel
    });
  }, timeout: const Duration(minutes: 5));
}
