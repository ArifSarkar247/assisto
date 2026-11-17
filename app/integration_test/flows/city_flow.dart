// gap-city: City Service on the emulator against the CI backend's made-up
// Dhaka sample (seed_reality -> core/city_sample.py).
//
// 30_city_route — open City Service from its route; Farmgate -> Motijheel
// shows route options with fares; Offices -> "Go by bus / metro" plans the
// trip to the office in City Service; voice ask in romanized Bangla
// ("Farmgate theke Motijheel jabo") plans the trip from our own data.
// The phone position is passed in (the emulator has no real GPS fix).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/city/city_service_screen.dart';

import '../support/harness.dart';

const _farmgate = (lat: 23.7577, lon: 90.3897);
const _motijheel = (name: 'Motijheel', address: '', lat: 23.7330, lng: 90.4177);

void registerCityFlows() {
  realityFlow('30_city_route', 'Daily life',
      'City Service: route options + fares, office -> route here, voice ask (romanized Bangla)', (f) async {
    await f.home();
    await f.step('open City Service from its route', () async {
      await f.openRoute('city');
      await f.waitFor(find.byType(CityServiceScreen), what: 'City Service');
      await f.shot('city_open');
    });
    await f.step('Farmgate -> Motijheel: options, chips, fare', () async {
      await f.pushScreen(const CityServiceScreen(debugHere: _farmgate, debugTo: _motijheel, debugSimple: false),
          settleSeconds: 4);
      await f.waitFor(find.byKey(const ValueKey('city_option')), seconds: 25, what: 'route option');
      expect(find.byKey(const ValueKey('city_chip_cheapest')), findsWidgets);
      expect(find.byKey(const ValueKey('city_start_sj')), findsWidgets);
      await f.shot('city_options');
    });
    await f.step('Offices -> Go by bus / metro -> trip planned to the office', () async {
      // the City Service list itself (the generic scrollTo found no
      // hit-testable Scrollable here: run 44074042981 step 3)
      final list = find.descendant(
          of: find.byKey(const ValueKey('city_list')).last, matching: find.byType(Scrollable)).first;
      final tile = find.byKey(const ValueKey('city_tile_offices'));
      await f.tester.dragUntilVisible(tile, list, const Offset(0, -300), maxIteration: 30);
      await f.pumpFor(const Duration(milliseconds: 600));
      await f.tap(tile.last, settleSeconds: 3);
      final here = find.byKey(const ValueKey('city_route_here_o-ci-passport'));
      await f.waitFor(here, seconds: 20, what: 'sample office with Go by bus / metro');
      await f.shot('city_offices_route_here');
      await f.tap(here.first, settleSeconds: 4);
      // the To field may be scrolled off: look past the viewport
      await f.waitFor(find.text('Sample Passport Office', skipOffstage: false), what: 'office as the destination');
      await f.waitFor(find.byKey(const ValueKey('city_option')), seconds: 25, what: 'route to the office');
      await f.shot('city_routed_to_office');
    });
    await f.step('voice ask: "Farmgate theke Motijheel jabo" -> planned from our data', () async {
      await f.tap(find.byKey(const ValueKey('city_voice_btn')).last, settleSeconds: 2);
      await f.tester.enterText(find.byKey(const ValueKey('city_voice_field')), 'Farmgate theke Motijheel jabo');
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.tap(find.byKey(const ValueKey('city_voice_go')), settleSeconds: 5);
      await f.waitFor(find.byKey(const ValueKey('city_option')), seconds: 25, what: 'voice route');
      expect(find.byKey(const ValueKey('city_voice_field')), findsNothing); // the sheet closed itself
      await f.shot('city_voice_planned');
    });
  }, timeout: const Duration(minutes: 5));
}
