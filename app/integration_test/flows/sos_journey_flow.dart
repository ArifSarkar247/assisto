// qjourney (quality push 9 Nov): the parts of SOS / Safe Journey that had no
// end-to-end flow yet.
//   14b  a REAL SOS from the Emergency screen: hold the button (the gesture a
//        person uses), the countdown runs out, the SERVER addresses B, A's
//        screen shows the "who has seen it" ladder, A taps "I'm safe now" ->
//        B's SOS card is no longer active. (14_sos_countdown proves Cancel.)
//   16c  Safe Journey's other cards and the Nearby emergency list open with
//        real content or an honest empty state — never a dead end / 4xx / 5xx.
// Push ringing a locked phone still needs two real phones
// (owner_actions/FAMILY_SAFETY_100_BN.md, SAFE_JOURNEY_100_BN.md).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbsorbPointer;
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/screens/train/dest_alarm_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';
import 'package:assisto/family_sos/sos_numbers_sync.dart'; // sos-numbers
import 'package:assisto/screens/emergency_screen.dart' show EmergencyScreen; // sos-numbers
import 'package:assisto/widgets/nearby_place_card.dart';
import 'package:assisto/widgets/skeleton.dart' show StateMessage;

import '../support/harness.dart';

/// Press and HOLD the big SOS button like a person does (a plain tap only
/// shows "hold to send").
// sosfam-crm-proof: the countdown dialog opens while the finger is still on
// SOS. The Navigator then cancels that pointer and blocks taps until the
// cancel arrives. On a phone the engine delivers it; under the integration
// test binding a device-made cancel is never dispatched, so every later tap
// on the page was dead (runs 44213469898..44250231295: "I'm safe now" and
// "Who is on the way" both ignored, button enabled + hit-testable). The
// finger therefore uses a known pointer id, and [releaseSosFinger] ends it
// the way the engine would.
const _sosPointer = 7357;

Future<void> holdSos(RFlow f) async {
  final btn = find.byKey(const ValueKey('sosat-sos-hold'));
  await f.waitFor(btn, what: 'SOS hold button');
  await f.tester.ensureVisible(btn);
  final g = await f.tester.createGesture(pointer: _sosPointer);
  await g.down(f.tester.getCenter(btn));
  await f.pumpFor(const Duration(milliseconds: EmergencySosPanel.holdMs + 600));
  await g.up();
  await f.pumpFor(const Duration(milliseconds: 500));
}

/// End the SOS finger for the Navigator (see [holdSos]) — a touch on the
/// status-bar strip, where nothing reacts.
Future<void> releaseSosFinger(RFlow f) async {
  final g = await f.tester.createGesture(pointer: _sosPointer);
  await g.down(const Offset(4, 4));
  await g.up();
  await f.pumpFor(const Duration(milliseconds: 300));
}

/// Leave [screen] like the system back key (its app bar has its own arrow,
/// not a BackButton, so the harness' back() cannot find one).
Future<void> _pop(RFlow f, Finder screen) async {
  await Navigator.of(f.tester.element(screen)).maybePop();
  await f.pumpFor(const Duration(milliseconds: 1200));
}

// sos-numbers (SAFETY P0): runs FIRST in the family group — right after the
// fresh install's sign-in, before anything could open the emergency card
// screen. The seeded account A has "Ammu 01700000011" on its server card.
void registerSosNumbersFlows() {
  realityFlow('14a_sos_numbers_fresh', 'Family & safety',
      'Fresh install: right after sign-in the SOS call / SMS steps have the saved family numbers (card screen never opened)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    const ammu = '01700000011';
    await f.step('sign-in fetched the card; the card screen was never opened', () async {
      final hits = f.h.recorder.hits;
      if (hits.any((x) => x.method == 'PUT' && x.path.startsWith('/emergency'))) {
        throw TestFailure('the card was edited — not a fresh phone');
      }
      if (find.byType(EmergencyScreen).evaluate().isNotEmpty) {
        throw TestFailure('the card screen is open');
      }
      f.expectHttp('GET', '/emergency');
      await f.eventually('the saved numbers are on the phone', () async {
        final c = await SosNumbersSync.cachedContacts();
        return c.any((x) => x['phone'] == ammu);
      });
      f.note('phone copy: ${(await f.net(SosNumbersSync.cachedContacts)).map((c) => c['name']).join(', ')}');
    });
    await f.step('Emergency at once -> hold SOS -> the call / SMS targets are the saved numbers',
        () async {
      await f.openRoute('emergency');
      final panel = await f.waitFor(find.byType(EmergencySosPanel), what: 'SOS panel');
      await f.eventually('the SOS panel has Ammu', () async {
        final cs = f.tester.widget<EmergencySosPanel>(panel).contacts;
        return cs.any((c) => '${c['phone']}' == ammu);
      });
      if (find.byKey(const ValueKey('sos-numbers-unavailable')).evaluate().isNotEmpty) {
        throw TestFailure('"numbers could not be loaded" shown while online');
      }
      await holdSos(f);
      await f.waitFor(find.byKey(const ValueKey('sosat-ladder')),
          seconds: 30, what: 'SOS ladder card after sending');
      await releaseSosFinger(f);
      final call = find.byKey(const ValueKey('sosat-call-family'));
      await f.scrollTo(call);
      await f.waitFor(find.text(f.t.saLadderCallPerson('Ammu')), what: '"Call Ammu" step');
      final sms = find.byKey(const ValueKey('sosat-sms'));
      await f.scrollTo(sms);
      f.expectVisible(sms, 'SMS step (has numbers)');
      if (find.byKey(const ValueKey('sosat-add-numbers')).evaluate().isNotEmpty) {
        throw TestFailure('"Add emergency numbers" shown — the SOS had nobody to call / SMS');
      }
      await f.shot('ladder_with_family_numbers');
    });
    // leave no active SOS for the next flows
    try {
      await f.net(() => api.postJson('/family/sos/resolve'));
    } catch (_) {}
    await f.backToHome();
  });
}

void registerSosJourneyFlows() {
  realityFlow('14b_sos_send', 'Family & safety',
      'SOS for real: hold -> countdown -> B is alerted -> ladder -> I\'m safe now (two accounts)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final apiB = await f.h.backend(userB: true);
    // an SOS left over from an earlier run would hide the new one
    try {
      await f.net(() => api.postJson('/family/sos/resolve'));
    } catch (_) {} // nothing to resolve: fine
    final mark = f.httpMark;
    await f.step('open Emergency -> hold SOS -> countdown runs out -> sent', () async {
      await f.openRoute('emergency');
      await holdSos(f);
      await f.waitFor(find.text(f.t.sosCancel), seconds: 6, what: 'countdown');
      await f.shot('countdown');
      // let the countdown finish (5 s default) + the bounded location read
      await f.waitFor(find.byKey(const ValueKey('sosat-ladder')),
          seconds: 30, what: 'SOS ladder card after sending');
      await f.shot('ladder');
      f.expectHttp('POST', '/family/sos', since: mark);
      f.expectNoServerErrors(since: mark);
    });
    await f.step('server: B has A\'s SOS', () async {
      await f.eventually('B received an active SOS', () async {
        final b = await apiB.getJson('/family/alerts');
        return (b['received'] as List)
            .cast<Map>()
            .any((x) => x['kind'] == 'sos' && x['active'] == true);
      });
    });
    await f.step('A: I\'m safe now -> B\'s SOS no longer active', () async {
      final safe = find.byKey(const ValueKey('sosat-safe'));
      await f.scrollTo(safe); // below the fold under the ladder
      await f.waitFor(safe, what: '"I\'m safe now" button');
      await f.tester.ensureVisible(safe);
      // sosfam-crm-proof: ensureVisible parks the button at the very top edge
      // under the app bar; a person scrolls it into the middle first. Then
      // wait for the list to stop (a tap on a moving list only stops it).
      final sc = find.byWidgetPredicate((w) =>
          w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical).hitTestable();
      if (sc.evaluate().isNotEmpty) {
        await f.tester.drag(sc.first, const Offset(0, 250), warnIfMissed: false);
      }
      await f.pumpFor(const Duration(milliseconds: 1500));
      await releaseSosFinger(f);
      final m2 = f.httpMark;
      // which pointer blocker sits above the button, and is it on?
      for (final e in find.ancestor(of: safe.first, matching: find.byType(AbsorbPointer)).evaluate()) {
        final w = e.widget as AbsorbPointer;
        final ro = e.renderObject;
        if (ro is RenderAbsorbPointer) f.note('render absorbing=${ro.absorbing}');
        String owner = '?';
        e.visitAncestorElements((a) {
          if (a.widget is Navigator || a.widget is Overlay || a.widget is Scaffold) {
            owner = a.widget.runtimeType.toString();
            return false;
          }
          return true;
        });
        f.note('AbsorbPointer absorbing=${w.absorbing} under $owner');
      }
      final btn = f.tester.widget<ButtonStyleButton>(safe.first);
      f.note('safe buttons: ${safe.evaluate().length}, on screen: '
          '${safe.hitTestable().evaluate().length}, enabled: ${btn.onPressed != null}, '
          'at y=${f.tester.getCenter(safe.first).dy.round()}');
      await f.tap(safe.hitTestable(), settleSeconds: 3);
      if (!f.h.recorder.hits.skip(m2).any((x) => x.path.startsWith('/family/sos/resolve'))) {
        // diagnostics for the owner report — a missed first tap is written down
        f.note('FIRST TAP MISSED (snackbar: ${find.byType(SnackBar).evaluate().length}, '
            'barriers: ${find.byType(ModalBarrier).evaluate().length}, '
            'absorb: ${find.ancestor(of: safe.first, matching: find.byType(AbsorbPointer)).evaluate().length}, '
            'ignore: ${find.ancestor(of: safe.first, matching: find.byType(IgnorePointer)).evaluate().length})');
        // does ANY tap work on this page? the next button opens a page
        final full = find.byKey(const ValueKey('sos-open-full'));
        if (full.hitTestable().evaluate().isNotEmpty) {
          final before = find.byType(Scaffold).evaluate().length;
          await f.tester.tapAt(f.tester.getCenter(full.first));
          await f.pumpFor(const Duration(seconds: 2));
          f.note('open-full tap -> scaffolds $before -> ${find.byType(Scaffold).evaluate().length}');
          if (find.byType(Scaffold).evaluate().length > before) {
            await Navigator.of(f.tester.element(find.byType(Scaffold).last)).maybePop();
            await f.pumpFor(const Duration(seconds: 2));
          }
        }
        await f.tester.tapAt(f.tester.getCenter(safe.first));
        await f.pumpFor(const Duration(seconds: 3));
      }
      await f.shot('safe');
      f.expectHttp('POST', '/family/sos/resolve', since: m2);
      await f.eventually('B: no active SOS from A', () async {
        final b = await apiB.getJson('/family/alerts');
        return !(b['received'] as List)
            .cast<Map>()
            .any((x) => x['kind'] == 'sos' && x['active'] == true);
      });
    });
  });

  realityFlow('16c_journey_cards_nearby', 'Family & safety',
      'Safe Journey cards (destination alarm, train) + Nearby emergency list: real screen, no dead end',
      (f) async {
    await f.home();
    final mark = f.httpMark;
    await f.step('Safe Journey hub -> Destination alarm card -> its screen', () async {
      await f.openRoute('journey');
      final card = find.byKey(const ValueKey('sjl_card_alarm'));
      if (!await f.appears(card, seconds: 8)) {
        throw TestFailure('destination-alarm card missing (flag dest_alarm not on for A?)');
      }
      await f.tap(card, settleSeconds: 2);
      // the card may open its screen at once, or show an "Open" button
      if (!await f.appears(find.byType(DestAlarmScreen), seconds: 3)) {
        final open = find.byKey(const ValueKey('sjl_open_alarm'));
        await f.scrollTo(open);
        await f.tester.ensureVisible(open);
        await f.tap(open, settleSeconds: 3);
      }
      await f.waitFor(find.byType(DestAlarmScreen), what: 'destination alarm screen');
      await f.shot('dest_alarm');
      await _pop(f, find.byType(DestAlarmScreen));
    });
    await f.step('Train card -> train tracker screen', () async {
      final card = find.byKey(const ValueKey('sjl_card_train'));
      await f.waitFor(card, what: 'train card');
      await f.tap(card, settleSeconds: 2);
      // the card may open its screen at once, or show an "Open" button
      if (!await f.appears(find.byType(TrainTrackerScreen), seconds: 3)) {
        final open = find.byKey(const ValueKey('sjl_open_train'));
        await f.scrollTo(open);
        await f.tester.ensureVisible(open);
        await f.tap(open, settleSeconds: 3);
      }
      await f.waitFor(find.byType(TrainTrackerScreen), what: 'train tracker screen');
      await f.shot('train');
      await _pop(f, find.byType(TrainTrackerScreen));
    });
    await f.step('Nearby: places or an honest empty state with a button', () async {
      await f.openRoute('nearby', settleSeconds: 5);
      await f.waitFor(find.byType(NearbyScreen), what: 'nearby screen');
      // places, or any honest state message (no places / location off /
      // offline) that carries a button — never a blank or a dead end
      final empty = find.descendant(
          of: find.byType(NearbyScreen), matching: find.byType(StateMessage));
      final hasList = find.byType(NearbyPlaceCard);
      await f.eventually('nearby shows places or a state message', () async =>
          empty.evaluate().isNotEmpty || hasList.evaluate().isNotEmpty);
      if (hasList.evaluate().isEmpty) {
        final btn = find.descendant(of: empty.first, matching: find.byWidgetPredicate(
            (w) => w is ButtonStyleButton));
        if (btn.evaluate().isEmpty) throw TestFailure('state message without a button');
      }
      await f.shot('nearby');
      f.expectNoServerErrors(since: mark);
    });
  });
}
