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
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/nearby_screen.dart';
import 'package:assisto/screens/train/dest_alarm_screen.dart';
import 'package:assisto/screens/train/train_tracker_screen.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';
import 'package:assisto/widgets/nearby_place_card.dart';
import 'package:assisto/widgets/skeleton.dart' show StateMessage;

import '../support/harness.dart';

/// Press and HOLD the big SOS button like a person does (a plain tap only
/// shows "hold to send").
Future<void> holdSos(RFlow f) async {
  final btn = find.byKey(const ValueKey('sosat-sos-hold'));
  await f.waitFor(btn, what: 'SOS hold button');
  await f.tester.ensureVisible(btn);
  final g = await f.tester.startGesture(f.tester.getCenter(btn));
  await f.pumpFor(const Duration(milliseconds: EmergencySosPanel.holdMs + 600));
  await g.up();
  await f.pumpFor(const Duration(milliseconds: 500));
}

/// Leave [screen] like the system back key (its app bar has its own arrow,
/// not a BackButton, so the harness' back() cannot find one).
Future<void> _pop(RFlow f, Finder screen) async {
  await Navigator.of(f.tester.element(screen)).maybePop();
  await f.pumpFor(const Duration(milliseconds: 1200));
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
      // sosfam-crm-proof: let the list stop moving — a tap on a list that is
      // still flinging only stops the fling (run 44213469898: the button was
      // on screen, no /resolve was sent)
      await f.pumpFor(const Duration(milliseconds: 1500));
      final m2 = f.httpMark;
      // sosfam-crm-proof: tap the button the USER sees — with an older
      // Emergency page still under this one, `first` was the hidden copy
      // (runs 44213469898 + 44226928480: button on screen, no /resolve)
      f.note('safe buttons: ${safe.evaluate().length}, on screen: ${safe.hitTestable().evaluate().length}');
      await f.tap(safe.hitTestable(), settleSeconds: 3);
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
