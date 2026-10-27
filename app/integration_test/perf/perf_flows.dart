// perf2gb: the launch-critical flows measured on the 2 GB CI emulator
// (.github/workflows/perf2gb.yml). Data volumes come from
// `manage.py seed_perf` (500 reminders, 500 khata customers, 500 CRM leads,
// 150 AI-sales chats, 300 money entries) + 200 REAL encrypted My Circle
// messages sent here from account B.
//
// Each flow: reopen the app (timed) -> open the screen (timed: first frame +
// ready) -> scroll (FrameTimings) -> memory (dumpsys on the host).
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/crypto/key_wiring.dart';
import 'package:assisto/perf/low_ram.dart';
import 'package:assisto/photo_studio/ps_backend.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_tools.dart';
import 'package:assisto/push/push_service.dart' show appNavigatorKey;
import 'package:assisto/screens/business/bizagent/seller_inbox_screen.dart';
import 'package:assisto/screens/business/customers_screen.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/credits_screen.dart';
import 'package:assisto/screens/crm/crm_leads_screen.dart';
import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:assisto/state.dart' show Settings;

import '../../test/c2_calls_fakes.dart' show FakeSurface, previewController;
import '../support/harness.dart';
import 'perf_png.dart';
import 'perf_probe.dart';

List<Map<String, dynamic>> _rows(Map<String, dynamic> r) =>
    ((r['results'] ?? r['members'] ?? r['threads'] ?? const []) as List)
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

Future<void> _pop(RFlow f) async {
  appNavigatorKey.currentState?.maybePop();
  await f.pumpFor(const Duration(milliseconds: 900));
}

class _FixedPicker implements PhotoPicker {
  _FixedPicker(this.bytes);
  final Uint8List bytes;
  @override
  Future<Uint8List?> pick({required bool camera}) async => bytes;
  @override
  Future<List<Uint8List>> pickMany({int limit = PhotoStudioController.batchMax}) async =>
      [bytes];
}

/// Sign in through AppState (seeded account A), English, onboarded.
void registerPerfSignIn() {
  realityFlow('p00_signin', 'Perf 2 GB', 'Sign in (AppState, seeded account A)', (f) async {
    for (var i = 0; i < 40 && f.app.loading; i++) {
      await f.pumpFor(const Duration(milliseconds: 250));
    }
    if (f.app.locale?.languageCode != 'en') {
      await f.net(() => f.app.setLocale(const Locale('en')));
    }
    if (!f.app.loggedIn) {
      await f.net(() => f.app.login(identifier: Seed.phoneA, password: Seed.password));
    }
    if (!f.app.loggedIn) throw TestFailure('login did not sign in');
    // the app's own startup tuning (lib/main.dart runs it after the first
    // frame; the harness pumps AssistoApp without main())
    await f.net(() => LowRamTuning.apply());
    f.note('image cache budget: ${LowRamTuning.applied ?? 'default (not a 2-3 GB phone)'}');
    // persisted exactly like OnboardingScreen does (the in-memory flag alone
    // was lost on the next app open: run 40584598327)
    await f.net(() => Settings.setBool('onboarded', true));
    f.app.markOnboarded();
    await f.home();
  });
}

void registerPerfFlows({List<String>? only}) {
  perfOnly = only;
  // ------------------------------------------------------------ 1. home + chat
  perfFlow('p01_home_chat', '১৫. অ্যাপের কাঠামো / ৬. AI সহকারী',
      'Home + Assisto chat', (p) async {
    final f = p.f;
    await p.scroll('home', downs: 2, ups: 2);
    if (f.isHomeV2) {
      final ask = find.byKey(const ValueKey('hv2_ask'));
      await f.tester.ensureVisible(ask);
      await f.pumpFor(const Duration(milliseconds: 600));
      await p.openTimed('assisto_chat', () async {
        await f.tester.tap(ask, warnIfMissed: false);
      }, ready: find.text(f.t.inputHint));
    } else {
      p.notes.add('old home: the chat IS the home (no separate screen to open)');
    }
    await p.scroll('assisto_chat', downs: 2, ups: 2, older: true);
    await p.memory('after');
  });

  // ------------------------------------------------- 2. My Circle, 200 messages
  perfFlow('p02_circle_chat', '২. আমার সার্কেল', 'My Circle: chat list -> chat with 200 messages',
      (p) async {
    final f = p.f;
    final apiA = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    // A's app publishes its key (as on a real phone, a few seconds after start)
    await f.net(() async {
      try {
        KeyWiring.instance.start(f.app);
      } catch (_) {}
    });
    await f.pumpFor(const Duration(seconds: 4));
    var sent = 0;
    await f.net(() async {
      final e2e = SoftwareE2E();
      final idB = e2e.generateIdentity();
      await apiB.postJson('/circle/keys',
          {'public_key': idB.publicKeyB64, 'key_id': idB.keyId, 'scheme': e2e.scheme});
      final edgeB = _rows(await apiB.getJson('/circle/members'))
          .firstWhere((m) => '${m['name']}'.contains('Rahim'));
      final pk = '${edgeB['public_key'] ?? ''}';
      if (pk.isEmpty) return;
      final have = _rows(await apiA.getJson('/circle/chats')).length;
      for (var i = 0; i < 200; i++) {
        final text = i % 5 == 0
            ? 'Perf message ${i + 1}: আজ বিকেলে বাজারে যাবো, কিছু লাগলে বলো। Long line to wrap '
                'over several rows like a real chat.'
            : 'Perf message ${i + 1} ঠিক আছে';
        final ct = e2e.encrypt(self: idB, recipientPublicKey: base64Decode(pk), plaintext: text);
        await apiB.postJson('/circle/${edgeB['id']}/messages',
            {...ct.toEnvelopeFields(), 'content_type': 'text', 'client_msg_id': 'perf-${DateTime.now().microsecondsSinceEpoch}-$i'});
        sent++;
      }
      p.out['circle_chats_before'] = have;
    });
    p.out['messages_seeded'] = sent;
    if (sent == 0) p.notes.add('A has no public key on the server: chat measured without the 200 messages');
    await p.openRoute('circle_list', 'circle', ready: find.text(Seed.nameB));
    await p.scroll('circle_list', downs: 1, ups: 1);
    await p.openTimed('chat_open', () async {
      await f.tester.tap(find.text(Seed.nameB).first, warnIfMissed: false);
    }, ready: find.byType(CircleChatScreen));
    await p.scroll('chat_200', downs: 6, ups: 3, older: true);
    await p.memory('chat_open');
  }, timeout: const Duration(minutes: 8));

  // ---------------------------------------------------- 3. call screen (no call)
  perfFlow('p03_call_screen', '১. কল', 'Call screen open (voice + video, frozen controller, no real call)',
      (p) async {
    final f = p.f;
    const member = {'id': 5, 'name': 'Perf Caller'};
    await p.pushTimed('voice_call', CircleCallScreen(
        member: member, kind: 'voice', controller: previewController(
            video: false, outgoing: true, phase: CallPhase.connected)));
    await f.pumpFor(const Duration(seconds: 3)); // the live timer ticks
    await p.memory('voice');
    await _pop(f);
    await p.pushTimed('video_call', CircleCallScreen(
        member: member, kind: 'video', surface: FakeSurface(), controller: previewController(
            video: true, outgoing: true, phase: CallPhase.connected)));
    final w = FrameWindow()..start();
    await f.pumpFor(const Duration(seconds: 4));
    p.jank['video_call_idle_4s'] = await w.stop(f.tester);
    await p.memory('video');
    await _pop(f);
    p.notes.add('frozen controller + fake video surface: no WebRTC/camera on the emulator');
  });

  // ------------------------------------------------------------ 4. Safe Journey
  perfFlow('p04_safe_journey', '৩. নিরাপদ যাত্রা', 'Safe Journey: start screen + live screen', (p) async {
    final f = p.f;
    final api = await f.h.backend();
    await f.net(() async {
      final a = await api.getJson('/journey/active');
      if (a['id'] != null) await api.postJson('/journey/${a['id']}/arrived');
    });
    await p.openRoute('start_screen', 'journey', ready: find.byKey(const ValueKey('j100_dest')));
    await p.scroll('start_screen', downs: 2, ups: 2);
    int? jid;
    await f.net(() async {
      final edge = _rows(await api.getJson('/circle/members'))
          .firstWhere((m) => '${m['name']}' == Seed.nameB, orElse: () => {});
      final r = await api.postJson('/journey/start', {
        'destination': {'name': 'Perf Home'},
        if (edge['id'] != null) 'watcher_ids': [edge['id']],
      });
      jid = (r['id'] ?? (r['journey'] as Map?)?['id']) as int?;
    });
    if (jid == null) {
      p.notes.add('journey/start gave no id: live screen not measured');
      return;
    }
    await f.backToHome();
    await p.pushTimed('live_screen', JourneyLiveScreen(journeyId: jid!),
        ready: find.byKey(const ValueKey('j100_status')));
    final w = FrameWindow()..start();
    await f.pumpFor(const Duration(seconds: 5));
    p.jank['live_idle_5s'] = await w.stop(f.tester);
    await p.memory('live');
    await f.net(() => api.postJson('/journey/$jid/arrived'));
  });

  // ------------------------------------------------------------ 5. Family care
  perfFlow('p05_family', '৪. পরিবারের নিরাপত্তা', 'Family care screen', (p) async {
    await p.openRoute('family', 'family');
    await p.scroll('family', downs: 3, ups: 2);
    await p.memory('after');
  });

  // ------------------------------------------------------- 6. reminders (500)
  perfFlow('p06_reminders', '৫. রিমাইন্ডার ও নোট', 'Reminders list (500 items)', (p) async {
    await p.openRoute('reminders', 'reminders');
    await p.scroll('reminders_500', downs: 8, ups: 3);
    await p.memory('after');
  });

  // ------------------------------------------------- 7. Photo Studio + preview
  perfFlow('p07_photo_studio', '৭. ফটো স্টুডিও', 'Photo Studio open + 12 MP photo + one edit preview',
      (p) async {
    final f = p.f;
    final png = await f.tester.runAsync(() => Isolate.run(() => makeTestPng()));
    p.out['photo_bytes'] = png!.length;
    final c = PhotoStudioController(
        PsDeps(backend: ApiPsBackend(f.app.api), picker: _FixedPicker(png)));
    try {
      await p.pushTimed('studio_open', PhotoStudioScreen(controller: c));
      final initSw = Stopwatch()..start();
      await f.net(() => c.init());
      p.out['studio_init_ms'] = initSw.elapsedMilliseconds;
      await p.memory('open');
      // pick = decode + inspect (faces, size, tool list) of the 12 MP photo
      await p.openTimed('pick_12mp', () async {
        await f.net(() => c.pick(camera: false));
      }, sameRoute: true, capSeconds: 30);
      await p.memory('picked');
      final tool = [PsTool.lowLight, PsTool.denoise].where(c.tools.has).firstOrNull;
      if (tool == null) {
        p.notes.add('no on-device classic tool for this photo (tools=${c.tools.any})');
      } else {
        await p.openTimed('edit_${tool.wire}', () async {
          await f.net(() => c.runTool(tool).timeout(const Duration(seconds: 90)));
        }, sameRoute: true, capSeconds: 95);
        p.out['edit_notice'] = '${c.notice}';
        await p.memory('edited');
      }
      await _pop(f);
    } finally {
      c.dispose();
    }
  }, timeout: const Duration(minutes: 8));

  // ---------------------------------------------- 8. Business + ledger (500)
  perfFlow('p08_business_ledger', '৮. বিজনেস ও ডিজিটাল খাতা', 'Business hub + khata (500 customers) + customers (500)',
      (p) async {
    final f = p.f;
    await p.openRoute('business_hub', 'business');
    await p.openTimed('khata_500', () async {
      final k = find.text(f.t.khataTitle);
      await f.scrollTo(k);
      await f.tester.tap(k.first, warnIfMissed: false);
    });
    await p.scroll('khata_500', downs: 8, ups: 3);
    await p.memory('khata');
    final api = await f.h.backend();
    final b = await f.net(() => api.getJson('/business/profiles'));
    final bid = (b['selected_id'] as num?)?.toInt();
    await f.backToHome();
    await p.pushTimed('customers_500', CustomersScreen(businessId: bid));
    await p.scroll('customers_500', downs: 8, ups: 3);
    await p.memory('customers');
  });

  // --------------------------------------------------------------- 9. CRM
  perfFlow('p09_crm', '৯. CRM', 'CRM home + leads list (500 leads)', (p) async {
    final f = p.f;
    await p.openRoute('crm_home', 'crm');
    final api = await f.h.backend();
    final orgs = await f.net(() => api.listItems('crm/orgs'));
    final org = orgs.firstWhere((o) => o['name'] == 'Perf Sales Org',
        orElse: () => orgs.isEmpty ? <String, dynamic>{} : orgs.first);
    if (org['id'] == null) {
      p.notes.add('no CRM org: leads list not measured');
      return;
    }
    await f.backToHome();
    await p.pushTimed('leads_500', CrmLeadsScreen(org: (org['id'] as num).toInt()));
    await p.scroll('leads_500', downs: 8, ups: 3);
    await p.memory('leads');
  });

  // ------------------------------------------------------ 10. AI sales inbox
  perfFlow('p10_ai_sales_inbox', '১০. AI সেলস সহকারী', 'AI sales assistant + inbox (150 chats)', (p) async {
    final f = p.f;
    await p.openRoute('sales_agent', 'sales_agent');
    await f.backToHome();
    await p.pushTimed('inbox_150', const SellerInboxScreen());
    await p.scroll('inbox_150', downs: 6, ups: 2);
    await p.memory('inbox');
  });

  // ------------------------------------------------------------ 11. CCTV
  perfFlow('p11_cctv', '১১. CCTV', 'CCTV: Shop Box + home watchman screens', (p) async {
    final f = p.f;
    await p.openRoute('shop_box', 'shop_box');
    await p.scroll('shop_box', downs: 2, ups: 1);
    await p.memory('shop_box');
    try {
      await p.openRoute('watchman', 'watchman');
      await p.scroll('watchman', downs: 2, ups: 1);
    } catch (e) {
      p.notes.add('watchman: ${'$e'.split('\n').first}');
    }
    await f.backToHome();
  });

  // ---------------------------------------------------- 12. vehicle map
  perfFlow('p12_vehicle_map', '১২. গাড়ি ট্র্যাকিং', 'Vehicle tracking (map) screen', (p) async {
    final f = p.f;
    await p.openRoute('vehicle_tracking', 'vehicle_tracking');
    final w = FrameWindow()..start();
    await f.pumpFor(const Duration(seconds: 4));
    p.jank['map_idle_4s'] = await w.stop(f.tester);
    await p.scroll('vehicle_tracking', downs: 2, ups: 1);
    await p.memory('after');
  });

  // ------------------------------------------------------------- 13. budget
  perfFlow('p13_budget', '১৩. বাজেট ও রেমিট্যান্স', 'Budget (300 money entries)', (p) async {
    await p.openRoute('budget', 'budget');
    await p.scroll('budget', downs: 3, ups: 2);
    await p.openRoute('money', 'money');
    await p.scroll('money', downs: 4, ups: 2);
    await p.memory('after');
  });

  // ---------------------------------------------------- 14. plans + credits
  perfFlow('p14_plans_credits', '১৪. পেমেন্ট, প্ল্যান, ক্রেডিট', 'Plans + credits screens', (p) async {
    final f = p.f;
    await p.openRoute('plans', 'plans');
    await p.scroll('plans', downs: 3, ups: 2);
    await f.backToHome();
    await p.pushTimed('credits', const CreditsScreen());
    await p.scroll('credits', downs: 2, ups: 1);
    await p.memory('after');
  });

  // ------------------------------------------------------------- end marker
  testWidgets('pzz_done', (tester) async {
    // ignore: avoid_print
    print('PERF_ALL_DONE ${PerfRecorder.I.flows.length}');
  });
}
