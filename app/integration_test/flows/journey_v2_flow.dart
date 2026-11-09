// qjourney (owner Safe Journey V2, 9 Nov): destination search with the
// Google budget OFF (CI has no Google key = the "budget used up" path): our
// own free Bangladesh list answers from the 2nd letter, in English and
// Bangla script, and the app never shows a limit message. The budget-ON
// merge (Google only under 5 good matches) is proven by backend
// core/tests_qjourney.py with a fake Google.
// The impossible-early "Arrived" is proven in flow 16_safe_journey.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void registerJourneyV2Flows() {
  realityFlow('16d_place_search_v2', 'Family & safety',
      'Destination search: Gai / গাইবান্ধা / Badda / Shahjalal airport from our own list, no limit message',
      (f) async {
    await f.home();
    final mark = f.httpMark;
    await f.step('open the trip form', () async {
      await f.openRoute('journey');
      final trip = find.byKey(const ValueKey('sjl_btn_trip'));
      if (await f.appears(trip, seconds: 8)) {
        await f.tester.ensureVisible(trip);
        await f.tap(trip, settleSeconds: 3);
      }
      await f.waitFor(find.byKey(const ValueKey('j100_dest')), what: 'destination field');
    });
    Future<void> expectRow(String typed, String shows) async {
      final field = find.byKey(const ValueKey('j100_dest'));
      await f.tester.tap(field);
      await f.tester.enterText(field, typed);
      final row = find.ancestor(
          of: find.textContaining(shows), matching: find.byType(ListTile));
      await f.waitFor(row, seconds: 12, what: '"$shows" suggested for "$typed"');
      if (find.text(f.t.mapscSearchCapped).evaluate().isNotEmpty ||
          find.text(f.t.mapscSearchOff).evaluate().isNotEmpty) {
        throw TestFailure('a limit / off message was shown for "$typed"');
      }
    }

    await f.step('Gai -> Gaibandha', () async {
      await expectRow('Gai', 'Gaibandha');
      await f.shot('gai');
      f.expectHttp('GET', '/maps/search', since: mark);
    });
    await f.step('গাইবান্ধা (Bangla script) -> Gaibandha', () async {
      await expectRow('গাইবান্ধা', 'Gaibandha');
      await f.shot('gaibandha_bn');
    });
    await f.step('Badda', () async {
      await expectRow('Badda', 'Badda');
      await f.shot('badda');
    });
    await f.step('Shahjalal airport -> pick -> pinned (no paid details call)', () async {
      await expectRow('Shahjalal airport', 'Shahjalal');
      final before = f.httpMark;
      await f.tap(find.ancestor(
              of: find.textContaining('Shahjalal'), matching: find.byType(ListTile))
          .first, settleSeconds: 3);
      await f.waitFor(find.byKey(const ValueKey('j2_pinned')), what: 'pinned airport');
      await f.shot('airport_pinned');
      final paid = f.h.recorder.hits.skip(before).where((x) => x.path.startsWith('/maps/place'));
      if (paid.isNotEmpty) throw TestFailure('a Place Details call for our own row');
      f.expectNoServerErrors(since: mark);
    });
  });
}
