// speedproof: open time of the main screen of every top feature, COLD and
// WARM, on the 2 GB CI emulator profile (.github/workflows/perf2gb.yml, flows
// "s.."; tools/speedproof/guard.py fails a > 20% regression).
//
//   cold = the first open of that screen after the app (re)started: no data
//          of that screen cached, its widgets built for the first time
//   warm = the same screen opened again right after (data/code warm)
//
// Each open records its API calls (client-side ms) in `http`; the server's own
// time + SQL count per request come from core/ci_timing.py (CITIMING lines).
// Labels are the baseline keys in tools/speedproof/baseline.json — keep them
// stable. One screen failing never stops the rest of its flow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/screens/business/invoice/invoices_screen.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/city/city_service_screen.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/journey_start_screen.dart';
import 'package:assisto/screens/language_partner_screen.dart';
import 'package:assisto/screens/mess_accounting_screen.dart';
import 'package:assisto/screens/quran_screen.dart' show QuranReaderScreen, QuranScreen;
import 'package:assisto/widgets/ai_markdown.dart';

import '../support/harness.dart';
import 'perf_probe.dart';

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? r['items'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

Future<void> _pop(RFlow f) async {
  appNavigatorKey.currentState?.maybePop();
  await f.pumpFor(const Duration(milliseconds: 900));
}

/// [open] twice: `<label>_cold` then (after [between]) `<label>_warm`.
Future<void> _twice(PerfFlowCtx p, String label, Future<void> Function(String l) open,
    {Future<void> Function()? between}) async {
  for (final k in const ['cold', 'warm']) {
    try {
      await open('${label}_$k');
    } catch (e) {
      p.notes.add('${label}_$k: ${'$e'.split('\n').first}');
      p.opens['${label}_$k'] = {'ready_ms': null, 'timed_out': true, 'error': '$e'.split('\n').first};
    }
    if (k == 'cold') {
      if (between != null) {
        await between();
      } else {
        await _pop(p.f);
      }
      await p.f.pumpFor(const Duration(milliseconds: 600));
    }
  }
}

/// A route the home / drawer opens (ChatNav), cold + warm.
Future<void> _route(PerfFlowCtx p, String label, String route, {Finder? ready}) =>
    _twice(p, label, (l) => p.openRoute(l, route, ready: ready));

/// A screen pushed directly (no ChatNav route / needs arguments), cold + warm.
Future<void> _push(PerfFlowCtx p, String label, Widget Function() screen, {Finder? ready}) async {
  await p.f.backToHome();
  await _twice(p, label, (l) => p.pushTimed(l, screen(), ready: ready));
}

/// Time from Send to the first assistant text on screen (streaming: the
/// first words; CI has no AI key, so this is the app + server path and the
/// honest "needs the AI key" answer — the model's own time is not in it).
Future<void> _askTimed(PerfFlowCtx p, String label, String q) async {
  final f = p.f;
  // the chat composer = the one TextField whose keyboard action is Send
  // (runs 44002942576 / 44031239103: the Send tap went out with an empty
  // box — no /agent call — so the text now goes in and is SUBMITTED the way
  // the keyboard's Send key does it: onSubmitted -> _send)
  final box = find
      .byWidgetPredicate((w) => w is TextField && w.textInputAction == TextInputAction.send)
      .hitTestable();
  await f.waitFor(box, what: 'chat composer');
  // run 44049733148: enterText left the composer empty on the device, so
  // the text goes straight into its controller and the field's own
  // onSubmitted (= the keyboard's Send key -> _send) is called
  final field = f.tester.widget<TextField>(box.first);
  field.controller?.text = q;
  await f.pumpFor(const Duration(milliseconds: 300));
  final typed = field.controller?.text ?? '?';
  if (typed != q) p.notes.add('$label: composer holds "$typed"');
  final before = find.byType(AiMarkdown).evaluate().length;
  final httpFrom = f.h.recorder.hits.length;
  final sw = Stopwatch()..start();
  field.onSubmitted?.call(q);
  int? at;
  while (sw.elapsedMilliseconds < 30000) {
    await f.tester.pump(const Duration(milliseconds: 16));
    if (find.byType(AiMarkdown).evaluate().length > before) {
      at = sw.elapsedMilliseconds;
      break;
    }
  }
  if (at == null) {
    p.notes.add('$label: no answer text in 30 s; requests: '
        '${f.h.recorder.hits.skip(httpFrom).where((x) => !x.path.startsWith('/rt/')).map((x) => '${x.method} ${x.path} ${x.status}').take(6).join(', ')}');
  }
  p.opens[label] = {
    'first_frame_ms': at,
    'ready_ms': at,
    'timed_out': at == null,
    'http': [
      for (final x in f.h.recorder.hits.skip(httpFrom).take(20))
        {'m': x.method, 'p': x.path, 's': x.status, 'ms': x.ms}
    ],
  };
  await f.pumpFor(const Duration(seconds: 3)); // the answer finishes
}

void registerSpeedproofFlows() {
  // ------------------------------------------------------------- home
  perfFlow('s01_home', '৫. হোম', 'Home: app reopened (cold = first, warm = again)', (p) async {
    final f = p.f;
    // cold = perfFlow's own reopen (fresh AppState + widget tree)
    p.opens['home_cold'] = {'ready_ms': p.out['reopen_to_home_ms'], 'timed_out': false};
    final sw = Stopwatch()..start();
    await f.h.boot(f.tester, settleSeconds: 0);
    await f.home();
    p.opens['home_warm'] = {'ready_ms': sw.elapsedMilliseconds, 'timed_out': false};
  });

  // ------------------------------------------------------------- AI chat
  perfFlow('s02_ai_chat', '১. AI চ্যাট', 'AI chat: open + first answer start', (p) async {
    final f = p.f;
    await _twice(p, 'ai_chat_open', (l) async {
      await f.backToHome();
      await f.pumpFor(const Duration(milliseconds: 600));
      final ask = find.byKey(const ValueKey('hv2_ask'));
      await f.tester.ensureVisible(ask);
      await f.pumpFor(const Duration(milliseconds: 400));
      await p.openTimed(l, () async {
        await f.tester.tap(ask, warnIfMissed: false);
      }, ready: find.text(f.t.inputHint));
    });
    // still on the chat (warm open): two questions = first answer cold / warm
    await _askTimed(p, 'ai_first_answer_cold', 'Speed check one: what is 2 + 2?');
    await _askTimed(p, 'ai_first_answer_warm', 'Speed check two: name a colour.');
  }, timeout: const Duration(minutes: 5));

  // ------------------------------------------------------------- My Circle
  perfFlow('s03_circle', '২. আমার সার্কেল', 'My Circle: chat list + open a chat', (p) async {
    final f = p.f;
    await _route(p, 'circle_list', 'circle', ready: find.text(Seed.nameB));
    // on the list (warm open); a chat cold, back to the list, the chat warm
    await _twice(p, 'circle_chat', (l) => p.openTimed(l, () async {
          await f.tester.tap(find.text(Seed.nameB).first, warnIfMissed: false);
        }, ready: find.byType(CircleChatScreen)));
  });

  // ------------------------------------------------------------- Safe Journey
  perfFlow('s04_journey', '৪. নিরাপদ যাত্রা', 'Safe Journey: start + live screen', (p) async {
    final f = p.f;
    final api = await f.h.backend();
    await f.net(() async {
      final a = await api.getJson('/journey/active');
      if (a['id'] != null) await api.postJson('/journey/${a['id']}/arrived');
    });
    // the Safe Journey hub (what the home tile opens), then the start form
    await _route(p, 'journey_start', 'journey');
    // the emulator never gets a GPS fix: a location spinner may stay, so
    // ready = the destination field is shown
    await f.backToHome();
    await _twice(p, 'journey_form',
        (l) => p.pushTimed(l, const JourneyStartScreen(),
            // the form is a long list: the loaded form = its scroll view
            // (the loading state is a bare spinner); j100_dest may sit
            // below the fold and not be built yet (run 44049733148)
            ready: find.descendant(
                of: find.byType(JourneyStartScreen), matching: find.byType(Scrollable)),
            allowBusy: true));
    int? jid;
    await f.net(() async {
      final r = await api.postJson('/journey/start', {
        'destination': {'name': 'Perf Home', 'lat': 23.7806, 'lng': 90.4070}
      });
      jid = (r['id'] ?? (r['journey'] as Map?)?['id']) as int?;
    });
    if (jid == null) {
      p.notes.add('journey/start gave no id: live screen not measured');
      return;
    }
    await _push(p, 'journey_live', () => JourneyLiveScreen(journeyId: jid!),
        ready: find.byKey(const ValueKey('j100_status')));
    await f.net(() => api.postJson('/journey/$jid/arrived'));
  });

  // ------------------------------------------------------------- SOS
  perfFlow('s05_sos', '৫. SOS', 'SOS sender (Emergency hub)', (p) async {
    await _route(p, 'sos', 'emergency');
  });

  // ------------------------------------------------------------- Family Care
  perfFlow('s06_family', '৪. পরিবারের যত্ন', 'Family Care', (p) async {
    await _route(p, 'family', 'family');
  });

  // ------------------------------------------------------------- notifications
  perfFlow('s07_notifications', '৬. নোটিফিকেশন', 'Notifications list', (p) async {
    await _route(p, 'notifications', 'notifications');
  });

  // ------------------------------------------------------------- plans + credits
  perfFlow('s08_plans', '৭. প্ল্যান ও ক্রেডিট', 'Plans + credits', (p) async {
    await _route(p, 'plans', 'plans');
    await _push(p, 'credits', () => const CreditsScreen());
  });

  // ------------------------------------------------------------- khata
  perfFlow('s09_khata', '৮. খাতা', 'Khata / ledger (500 customers)', (p) async {
    await _route(p, 'khata', 'khata');
  });

  // ------------------------------------------------------------- invoice
  perfFlow('s10_invoice', '৮. ইনভয়েস', 'Invoices list (60 invoices)', (p) async {
    final f = p.f;
    final api = await f.h.backend();
    int? bid;
    var made = 0;
    await f.net(() async {
      final b = await api.getJson('/business/profiles');
      bid = (b['selected_id'] as num?)?.toInt();
      final q = bid == null ? '' : '?business_id=$bid';
      final have = _rows(await api.getJson('/business/invoices$q')).length;
      for (var i = have; i < 60; i++) {
        try {
          await api.postJson('/business/invoices$q', {
            'lines': [
              {'desc': 'Perf item ${i + 1}', 'qty': 1 + i % 3, 'unit': 150 + (i * 37) % 900}
            ],
            'buyer': {'name': 'Perf Buyer ${i + 1}'},
          });
          made++;
        } catch (_) {
          break;
        }
      }
    });
    p.out['invoices_made'] = made;
    await _push(p, 'invoices', () => InvoicesScreen(businessId: bid));
  });

  // ------------------------------------------------------------- CCTV
  perfFlow('s11_cctv', '৯. CCTV', 'CCTV home (watchman + Shop Box)', (p) async {
    await _route(p, 'cctv_home', 'watchman');
    await _route(p, 'shop_box', 'shop_box');
    p.notes.add('live view first picture: ipcam-e2e.yml (real RTSP + WebRTC), not this flow');
  });

  // ------------------------------------------------------------- City Service
  perfFlow('s12_city', '১০. সিটি সার্ভিস', 'City Service: route results (Farmgate -> Motijheel)', (p) async {
    // the CI server's Dhaka network = seed_perf's sample network
    await _push(
        p,
        'city_routes',
        () => const CityServiceScreen(
            debugHere: (lat: 23.7577, lon: 90.3897),
            debugTo: (name: 'Motijheel', address: '', lat: 23.7330, lng: 90.4177),
            debugSimple: false),
        ready: find.byKey(const ValueKey('city_option')));
  });

  // ------------------------------------------------------------- Mess
  perfFlow('s13_mess', '১১. মেস', 'Mess accounting', (p) async {
    await _push(p, 'mess', () => const MessAccountingScreen());
  });

  // ------------------------------------------------------------- Language Partner
  perfFlow('s14_lp', '১২. ভাষা সঙ্গী', 'Language Partner start', (p) async {
    await _push(p, 'language_partner', () => const LanguagePartnerScreen());
  });

  // ------------------------------------------------------------- Quran
  // ------------------------------------------------------------- Today facts
  // homefeed (row 38): cold = no saved copy yet (server answer), warm = the
  // saved copy paints first (cache-first)
  perfFlow('s16_today', '১৪. আজকের তথ্য', 'Today facts (prayer, weather, rates)', (p) async {
    await _route(p, 'today', 'daily_today', ready: find.byKey(const ValueKey('uw_card_prayer')));
  });

  perfFlow('s15_quran', '১৩. কুরআন', 'Quran: list + ayah page (Al-Baqarah, 286 ayas)', (p) async {
    final f = p.f;
    // pushed directly: ChatNav 'quran' left the top route unchanged in run
    // 44031239103 (no first frame); the screen is the same
    await f.backToHome();
    await _twice(p, 'quran_list',
        (l) => p.pushTimed(l, const QuranScreen(), ready: find.byKey(const Key('quran-sura-1')),
            capSeconds: 40));
    await _twice(p, 'quran_ayah', (l) async {
      final s = find.byKey(const Key('quran-sura-2'));
      await f.tester.ensureVisible(s);
      await f.pumpFor(const Duration(milliseconds: 300));
      await p.openTimed(l, () async {
        await f.tester.tap(s, warnIfMissed: false);
      }, ready: find.byType(QuranReaderScreen));
    });
  });
}
