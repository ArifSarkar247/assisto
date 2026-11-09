// playvideos (owner decision 8, 9 Nov): the two Play declaration videos,
// recorded on a CI emulator as a BACKUP to the owner's own phone recording.
// Run by .github/workflows/play_videos.yml + tools/playvideos/record.sh —
// never on the server. NOTHING is pre-granted: Android's own permission
// dialogs appear and the HOST taps them with UiAutomator (the app cannot tap
// system UI). The app prints `PLAYVID_MARK <name>` (a timeline mark the host
// uses to cut the ≤30 s video) and `PLAYVID_HOST <name>` (the host does
// something — tap a dialog, press Home, open the shade, replay a GPS route —
// then touches acks/<name>.done; we wait WITHOUT pumping frames, because the
// app may be in the background then).
//
//   B  "Hey Assisto": Settings → Assisto Voice (switch off) → switch →
//      disclosure → I agree → microphone dialog → notification dialog →
//      listening → Home → notification shade "Listening for Hey Assisto".
//   A  Location FGS: Safe Journey form → Start → in-app disclosure → Android
//      location dialog → live screen → Home → shade "Safe Journey is on"
//      while `adb emu geo fix` walks a made-up route → back to the app.
//
// Throwaway CI seed accounts only (seed_reality: "Reality Karim" etc.).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/journey_live_screen.dart';
import 'package:assisto/state.dart' show Settings;

import 'support/harness.dart';

void _mark(String m) {
  // ignore: avoid_print
  print('PLAYVID_MARK $m');
}

/// Ask the host to do [name]; wait (no frame pumps) for its ack.
Future<void> _host(RFlow f, String name, {int seconds = 120}) async {
  // ignore: avoid_print
  print('PLAYVID_HOST $name');
  final dir = await f.tester.runAsync(() => f.h.outDir());
  final ack = File('${dir!.path}/acks/$name.done');
  final ok = await f.tester.runAsync(() async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end)) {
      if (await ack.exists()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  });
  if (ok != true) f.note('host step "$name" not acknowledged in ${seconds}s');
}

/// The host answers `lang` by touching acks/lang_<code>.done.
Future<String> _lang(RFlow f) async {
  await _host(f, 'lang', seconds: 60);
  final dir = await f.tester.runAsync(() => f.h.outDir());
  final bn = await f.tester.runAsync(() => File('${dir!.path}/acks/lang_bn.done').exists());
  return bn == true ? 'bn' : 'en';
}

/// Records [body] as video [vid]: rec_start / rec_stop marks even when a
/// step fails (the host stops screenrecord at once), and on a failure the
/// visible texts go to the log (what screen were we really on?).
Future<void> _recorded(RFlow f, String vid, Future<void> Function() body) async {
  _mark('rec_start_$vid');
  await f.pumpFor(const Duration(seconds: 1));
  try {
    await body();
  } catch (_) {
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '')
        .where((x) => x.trim().isNotEmpty).take(40).join(' | ');
    // ignore: avoid_print
    print('PLAYVID_DEBUG on screen: $texts');
    rethrow;
  } finally {
    _mark('rec_stop_$vid');
  }
}

void main() {
  Harness.I.init();

  realityFlow('pv00_prep', 'Play videos', 'Sign in the throwaway CI seed user + language', (f) async {
    final lang = await _lang(f);
    await f.step('language $lang, signed in, onboarded', () async {
      await f.net(() => f.app.setLocale(Locale(lang), syncServer: false));
      if (!f.app.loggedIn) {
        await f.net(() => f.app.login(identifier: Seed.phoneA, password: Seed.password));
      }
      await f.net(() => Settings.setBool('onboarded', true));
      f.app.markOnboarded();
      await f.pumpFor(const Duration(seconds: 2));
      if (!f.app.loggedIn) throw TestFailure('seed login failed');
    });
  }, timeout: const Duration(minutes: 3));

  // ------------------------------------------------ B: "Hey Assisto"
  realityFlow('pv_b_wake', 'Play videos', '"Hey Assisto": disclosure -> mic dialog -> listening notice',
      (f) async {
    await f.home();
    await f.pumpFor(const Duration(seconds: 2));
    await _recorded(f, 'b', () async {
    await f.step('Assisto Voice settings: switch off', () async {
      await f.openRoute('voice_settings', settleSeconds: 2);
      final sw = find.byKey(const Key('va-wake-switch'));
      // the wake card sits below the fold of a lazy list: scroll to it
      for (var i = 0; i < 8 && sw.evaluate().isEmpty; i++) {
        await f.pumpFor(const Duration(seconds: 2));
        await f.scrollTo(sw, maxDrags: 4);
      }
      await f.waitFor(sw, seconds: 10, what: 'Hey Assisto switch');
      await f.tester.ensureVisible(sw);
      await f.pumpFor(const Duration(milliseconds: 800));
      _mark('settings');
      await f.pumpFor(const Duration(seconds: 3));
    });
    await f.step('switch -> disclosure (read slowly) -> I agree', () async {
      await f.tap(find.byKey(const Key('va-wake-switch')), settleSeconds: 1.5);
      _mark('disclosure');
      await f.pumpFor(const Duration(seconds: 2));
      final agree = find.byType(FilledButton);
      await f.waitFor(agree, what: 'I agree button');
      // slow scroll so every line is readable
      final scroll = find.byType(Scrollable).first;
      for (var i = 0; i < 6 && agree.hitTestable().evaluate().isEmpty; i++) {
        await f.tester.drag(scroll, const Offset(0, -220));
        await f.pumpFor(const Duration(milliseconds: 900));
      }
      await f.pumpFor(const Duration(seconds: 1));
      _mark('agree');
      await f.tap(agree.last, settleSeconds: 1);
    });
    await f.step('Android microphone + notification dialogs (host taps them)', () async {
      await _host(f, 'perm_mic', seconds: 40);
      await f.pumpFor(const Duration(seconds: 1));
      await _host(f, 'perm_notif', seconds: 25);
    });
    await f.step('listening (model download + start)', () async {
      await f.pumpFor(const Duration(seconds: 12));
      _mark('listening');
      await f.pumpFor(const Duration(seconds: 3));
    });
    await f.step('Home -> notification shade shows the listening notice', () async {
      await _host(f, 'bg_shade_b', seconds: 60);
      await f.pumpFor(const Duration(seconds: 2));
      _mark('back_b');
      await f.pumpFor(const Duration(seconds: 2));
    });
    });
    await f.step('turn Hey Assisto off again (clean shade for video A)', () async {
      final sw = find.byKey(const Key('va-wake-switch'));
      if (await f.appears(sw, seconds: 5)) {
        final s = f.tester.widget<Switch>(sw);
        if (s.value) await f.tap(sw, settleSeconds: 3);
      }
    });
  }, timeout: const Duration(minutes: 6));

  // ------------------------------------------------ A: Location FGS
  realityFlow('pv_a_journey', 'Play videos', 'Safe Journey: disclosure -> location dialog -> FGS in background',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    await f.net(() async {
      final a = await api.getJson('/journey/active');
      if (a['id'] != null) await api.postJson('/journey/${a['id']}/arrived');
    });
    await f.pumpFor(const Duration(seconds: 1));
    await _recorded(f, 'a', () async {
    await f.step('Safe Journey form: made-up place + watcher', () async {
      await f.openRoute('journey');
      // Safe Journey hub -> "My Trip"
      final trip = find.byKey(const ValueKey('sjl_btn_trip'));
      await f.waitFor(trip, seconds: 20, what: 'My Trip button');
      await f.pumpFor(const Duration(seconds: 1));
      await f.tap(trip, settleSeconds: 2);
      final dest = find.byKey(const ValueKey('j100_dest'));
      await f.waitFor(dest, seconds: 25, what: 'destination field');
      await f.tester.enterText(dest, 'Demo Park');
      await f.pumpFor(const Duration(seconds: 1));
      final b = find.widgetWithText(CheckboxListTile, Seed.nameB);
      await f.waitFor(b, seconds: 10, what: 'watcher ${Seed.nameB}');
      await f.tester.ensureVisible(b);
      await f.tap(b, settleSeconds: 1);
      _mark('form');
      await f.pumpFor(const Duration(seconds: 2));
    });
    await f.step('Start -> in-app location disclosure -> Continue', () async {
      final start = find.byKey(const ValueKey('j100_start'));
      await f.tester.ensureVisible(start);
      await f.tap(start, settleSeconds: 2);
      // no road ETA on CI (no maps key): the app asks for an arrival time once
      final picker = find.byType(TimePickerDialog);
      if (await f.appears(picker, seconds: 3)) {
        await f.tap(find.descendant(of: picker, matching: find.byType(TextButton)).last,
            settleSeconds: 2);
      }
      final skip = find.byKey(const ValueKey('j100b_bg_skip'));
      if (await f.appears(skip, seconds: 3)) await f.tap(skip, settleSeconds: 2);
      final reason = find.byKey(const Key('perm-reason-journey'));
      await f.waitFor(reason, seconds: 15, what: 'location disclosure');
      _mark('disclosure');
      await f.pumpFor(const Duration(seconds: 5));
      await f.tap(find.byKey(const Key('perm-reason-yes')), settleSeconds: 1);
    });
    await f.step('Android location dialog (host taps While using the app)', () async {
      await _host(f, 'perm_loc', seconds: 40);
    });
    await f.step('live journey screen', () async {
      await f.waitFor(find.byType(JourneyLiveScreen), seconds: 30, what: 'live journey screen');
      await f.pumpFor(const Duration(seconds: 1));
      _mark('live');
      await f.pumpFor(const Duration(seconds: 4));
    });
    await f.step('Home -> shade "Safe Journey is on" while the route plays -> back', () async {
      await _host(f, 'bg_route_a', seconds: 90);
      await f.pumpFor(const Duration(seconds: 1));
      _mark('reopen');
      await f.pumpFor(const Duration(seconds: 5));
    });
    await f.step('I\'ve arrived -> notification goes away', () async {
      final btn = find.byKey(const ValueKey('j100_arrived'));
      if (await f.appears(btn, seconds: 5)) {
        await f.tester.ensureVisible(btn);
        await f.tap(btn, settleSeconds: 3);
        _mark('stopped');
        await _host(f, 'shade_after_a', seconds: 30);
      }
    });
    });
  }, timeout: const Duration(minutes: 6));

  // the host stops waiting as soon as this runs (also after a failed flow)
  testWidgets('pv_zz_done', (tester) async => _mark('all_done'));
}
