// crm100 reality flow (business group): a price quote from the catalog ->
// the CUSTOMER accepts it on the public web page (no app, no login) -> one
// order on the server with stock taken -> the seller's ONE customer history
// page shows the quote, the order and the khata, and the send sheet offers
// WhatsApp / phone SMS / Assisto SMS with the cost first.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:assisto/api.dart' show ApiException;
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

  // sosfam-crm-proof (board row 15): a customer who said STOP can never be
  // messaged — no WhatsApp link, no phone SMS, no Assisto SMS, no bulk card,
  // nothing logged; the owner sees HOW and WHEN; the customer's own
  // re-consent (the same SMS link) opens the paths again.
  realityFlow('18d_crm_stop_consent', 'Business',
      'CRM STOP: customer taps the SMS stop link -> no path anywhere + owner sees why -> customer turns it back on',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    late int bizId;
    late String link;
    const phone = '01700000021'; // the seeded khata customer "Selim (khata)"
    Future<Map<String, dynamic>> preview() => f.net(() => api.postJson('/crm/send/preview',
        {'phone': phone, 'business': bizId, 'text': 'Eid offer', 'lang': 'en'}));
    Future<void> openSheet() async {
      await f.pushScreen(CustomerHistoryScreen(
          target: const CustomerTarget(phone: phone), name: 'Selim', business: bizId));
      await f.scrollTo(find.text(f.t.c100ActMessage));
      await f.tap(find.text(f.t.c100ActMessage), settleSeconds: 2);
      await f.tap(find.text(f.t.c100ChooseHow), settleSeconds: 3);
    }
    Future<void> closeSheet() async {
      await f.tap(find.byType(OutlinedButton).last, settleSeconds: 2); // Cancel
      await f.back();
    }
    await f.step('before: every path is open; the SMS carries a stop link', () async {
      final b = await f.net(() => api.getJson('/business/profiles'));
      bizId = (b['selected_id'] as num).toInt();
      final pv = await preview();
      if (pv['opted_out'] != false || '${pv['wa_url']}'.isEmpty) {
        throw TestFailure('not open before STOP: $pv');
      }
      final m = RegExp(r'https?://\S+/retention/u/[A-Za-z0-9-]+')
          .firstMatch('${(pv['sms'] as Map)['text']}');
      if (m == null) throw TestFailure('no stop link in the SMS text: ${pv['sms']}');
      link = m.group(0)!;
      f.note('stop link: ${link.replaceAll(RegExp(r'u/.*'), 'u/<token>')}');
    });
    await f.step('the customer opens the link (no app, no login) and taps Stop', () async {
      final g = await f.net(() => http.get(Uri.parse('$link?lang=en')));
      if (g.statusCode != 200 || !g.body.contains('Stop messages')) {
        throw TestFailure('stop page ${g.statusCode}');
      }
      final p = await f.net(() => http.post(Uri.parse('$link?lang=en')));
      if (p.statusCode != 200 || !p.body.contains('Turn messages back on')) {
        throw TestFailure('stop answered ${p.statusCode}');
      }
    });
    await f.step('server: no path at all — WhatsApp, phone SMS, Assisto SMS, bulk, log', () async {
      final pv = await preview();
      if (pv['opted_out'] != true || '${pv['wa_url']}${pv['sms_uri']}'.isNotEmpty) {
        throw TestFailure('a path is still open: $pv');
      }
      if ((pv['sms'] as Map)['available'] == true) throw TestFailure('Assisto SMS offered');
      if ((pv['stop'] as Map?)?['source'] != 'sms_link') throw TestFailure('no reason: $pv');
      final bulk = await f.net(() => api.postJson('/crm/send/bulk', {
            'business': bizId, 'targets': [{'phone': phone}], 'text': '{name}, Eid offer'}));
      if ((bulk['cards'] as List).isNotEmpty || bulk['opted_out'] != 1) {
        throw TestFailure('bulk made a card for a STOP customer: $bulk');
      }
      for (final call in [
        ['/crm/send/sms', {'phone': phone, 'business': bizId, 'text': 'Eid offer'}],
        ['/crm/send/log', {'phone': phone, 'business': bizId, 'text': 'Eid offer',
          'channel': 'whatsapp_link'}],
      ]) {
        // runAsync reports + swallows a throw, so catch INSIDE (run 44213469898)
        final got = await f.net(() async {
          try {
            await api.postJson(call[0] as String, call[1] as Map<String, dynamic>);
            return 'accepted';
          } on ApiException catch (e) {
            return '${e.status} ${e.reason ?? ''}';
          }
        });
        if (!'$got'.startsWith('409')) {
          throw TestFailure('${call[0]} for a STOP customer answered: $got');
        }
        f.note('${call[0]} refused $got');
      }
      final list = await f.net(() => api.getJson('/retention/opt-outs'));
      f.note('owner STOP list: ${list['count']} (${(list['opt_outs'] as List).map((o) => (o as Map)['source']).join(',')})');
    });
    await f.step('app: the send sheet says STOP, how + when, and offers no way', () async {
      await openSheet();
      f.expectHttp('POST', '/crm/send/preview');
      await f.waitFor(find.byKey(const ValueKey('gbz-send-optedout')), what: 'STOP note');
      if (!await f.appears(find.textContaining(f.t.gbzStopUndo), seconds: 4)) {
        throw TestFailure('the note does not say who can undo it');
      }
      final how = (f.t.gbzStopByLink('§').split('§').map((x) => x.trim()).toList()
            ..sort((a, b) => b.length.compareTo(a.length)))
          .first;
      if (!await f.appears(find.textContaining(how), seconds: 2)) {
        throw TestFailure('the note does not say how they stopped');
      }
      await f.shot('stop-reason');
      final mark = f.httpMark;
      await f.tap(find.text(f.t.c100WayWa), settleSeconds: 1);
      if (f.h.recorder.hits.skip(mark).any((x) => x.path.startsWith('/crm/send/log'))) {
        throw TestFailure('the WhatsApp way was opened for a STOP customer');
      }
      await closeSheet();
    });
    await f.step('the customer turns messages back on (same link) -> paths open again', () async {
      final p = await f.net(() => http.post(Uri.parse('$link?lang=en'), body: {'action': 'start'}));
      if (p.statusCode != 200 || !p.body.contains('Messages are on again')) {
        throw TestFailure('re-consent answered ${p.statusCode}');
      }
      final pv = await preview();
      if (pv['opted_out'] != false || '${pv['wa_url']}'.isEmpty) {
        throw TestFailure('still blocked after re-consent: $pv');
      }
      await openSheet();
      if (find.byKey(const ValueKey('gbz-send-optedout')).evaluate().isNotEmpty) {
        throw TestFailure('STOP note still shown after re-consent');
      }
      if (!await f.appears(find.text(f.t.c100WayWa))) throw TestFailure('no WhatsApp way');
      await f.shot('reconsent-open');
      await closeSheet();
    });
  }, timeout: const Duration(minutes: 5));
}
