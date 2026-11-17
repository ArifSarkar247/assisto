// cityapp gallery states for test/screenshots_test.dart (bn/en, light/dark):
// City Service start, route options, step list, CNG overcharge card, no-data
// city, metro guide + station gates, which-gate-now at the metro exit,
// around me, live reports, women options, long distance + water, offices.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/city/city_models.dart';
import 'package:assisto/city/city_offline.dart';
import 'package:assisto/city/city_widgets.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/city/city_around_screen.dart';
import 'package:assisto/screens/city/city_directory_screen.dart';
import 'package:assisto/screens/city/city_field_screen.dart'; // citycov
import 'package:assisto/screens/city/city_journey.dart';
import 'package:assisto/screens/city/city_metro_screen.dart';
import 'package:assisto/screens/city/city_reports_screen.dart';
import 'package:assisto/screens/city/city_service_screen.dart';
import 'package:assisto/screens/city/city_women_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_city.dart';

const _here = (lat: 23.8075, lon: 90.3670);
final _now = DateTime(2026, 11, 9, 14, 30);
CityStore _store() => CityStore(files: MemoryCityFiles());

CityOption _opt(String k) => CityPlan.from(fakeCityPlan()).options[{
      'cheapest': CityPick.cheapest,
      'fastest': CityPick.fastest,
    }[k]!]!;

Widget _steps(CityOption o, {bool simple = false}) => Builder(
      builder: (c) => Scaffold(
        appBar: AppBar(title: Text(AppLocalizations.of(c).cityTitle)),
        body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
          CityOptionSummary(o),
          const Divider(height: Gap.xl),
          CityStepList(o,
              simple: simple,
              onReportLeg: (l) => showCityCorrection(c,
                  api: c.read<AppState>().api, target: 'route', targetId: l.routeId)),
        ]),
      ),
    );

Widget _cng() => Builder(builder: (c) {
      final p = CityPlan.from(fakeCityPlan());
      final w = p.otherWays.firstWhere((w) => w.mode == 'cng');
      return Scaffold(
        appBar: AppBar(title: Text(AppLocalizations.of(c).cityOtherWays)),
        body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
          Card(child: Padding(padding: const EdgeInsets.all(Gap.md), child: CityCngCard(way: w, complaint: p.complaint))),
        ]),
      );
    });

final Map<String, Widget Function(String)> cityShots = {
  'city_start': (l) => CityServiceScreen(debugHere: _here, debugSimple: false, store: _store(), debugNow: _now),
  'city_routes': (l) => CityServiceScreen(
      debugHere: _here,
      debugTo: (name: l == 'bn' ? 'মতিঝিল' : 'Motijheel', address: '', lat: 23.7270, lng: 90.4180),
      debugPick: CityPick.fastest,
      debugSimple: false,
      store: _store(),
      debugNow: _now),
  'city_steps_metro': (l) => _steps(_opt('fastest')),
  'city_steps_bus': (l) => _steps(_opt('cheapest')),
  'city_new_here': (l) => _steps(_opt('fastest'), simple: true),
  'city_cng': (l) => _cng(),
  'city_metro_guide': (l) => CityMetroScreen(store: _store()),
  'city_station': (l) => CityStationScreen(
      city: 'dhaka',
      station: CityStation.from({'id': 'st_mot', 'name': 'Motijheel', 'name_bn': 'মতিঝিল', 'gates': 2}),
      store: _store(),
      dest: (name: l == 'bn' ? 'শাপলা চত্বর' : 'Shapla Chattar', address: '', lat: 23.7290, lng: 90.4210)),
  'city_which_gate': (l) => CityTripScreen(
      option: _opt('fastest'), debugPositions: Stream.value((lat: 23.7284, lon: 90.4197))),
  // gap-city: as City Service opens them — each place has "Go by bus / metro"
  'city_around': (l) => const CityAroundScreen(debugHere: _here, routeHere: true),
  'city_live': (l) => const CityReportsScreen(debugHere: _here),
  'city_women': (l) => const CityWomenScreen(),
  'city_long': (l) => CityDirectoryScreen(kinds: const ['terminals', 'ghats'], routeHere: true, store: _store()),
  'city_offices': (l) => CityDirectoryScreen(kinds: const ['offices'], routeHere: true, store: _store()),
  // gap-city: no GPS + no start chosen -> what is missing + two real buttons
  'city_need_start': (l) => CityServiceScreen(
      debugTo: (name: l == 'bn' ? 'মতিঝিল' : 'Motijheel', address: '', lat: 23.7270, lng: 90.4180),
      debugSimple: false,
      debugLocate: () async => null,
      store: _store(),
      debugNow: _now),
  'city_map_stop': (l) => const CityFieldScreen(debugHere: _here), // citycov
};

/// The no-data city (FakeMode.empty): honest card + Open in Google Maps.
final Map<String, Widget Function(String)> cityEmptyShots = {
  'city_no_data': (l) => CityServiceScreen(debugHere: _here, debugSimple: false, store: _store(), debugNow: _now),
  'city_live_empty': (l) => const CityReportsScreen(debugHere: _here),
  'city_map_stop_empty': (l) => const CityFieldScreen(debugHere: _here), // citycov
};
