// mapapp gallery states for test/screenshots_test.dart (bn/en, light/night
// via the gallery's dark variant): the City map at Badda, Motijheel, Mirpur
// and the airport with layer chips, route results side by side, the Google
// view with sample Google transit, and the trip confirm card.
// The native MapLibre / Google views cannot run in widget tests: the map
// area is the test canvas (our overlay only) and the Google view shows its
// no-key panel; real-tile shots come from the emulator run.
import 'package:flutter/material.dart';

import 'package:assisto/city/city_models.dart';
import 'package:assisto/city/map/assisto_map_view.dart';
import 'package:assisto/city/map/city_map_data.dart';
import 'package:assisto/city/map/city_trip_learn_card.dart';
import 'package:assisto/city/map/google_city_view.dart';
import 'package:assisto/screens/city/city_map_screen.dart';

import 'fake_city.dart';
import 'fake_city_map.dart';

const _badda = (lat: 23.7806, lon: 90.4265);
const _motijheel = (lat: 23.7300, lon: 90.4170);
const _mirpur = (lat: 23.8075, lon: 90.3670);
const _airport = (lat: 23.8513, lon: 90.4086);

Widget _map(({double lat, double lon}) here, Set<CityLayer> layers,
    {bool to = false, CityMapView view = CityMapView.assisto, bool more = false, String l = 'en'}) {
  AssistoMapView.debugCanvas = true;
  GoogleCityView.debugNoSdk = true;
  return CityMapScreen(
    here: here,
    to: to ? (name: l == 'bn' ? 'মতিঝিল' : 'Motijheel', address: '', lat: 23.7270, lng: 90.4180) : null,
    debugShapes: fakeCityMapShapes(),
    debugLayers: layers,
    debugView: view,
    debugMoreRoutes: more,
  );
}

final Map<String, Widget Function(String)> cityMapShots = {
  'citymap_badda': (l) => _map(_badda, {CityLayer.metro, CityLayer.bus}, l: l),
  'citymap_motijheel': (l) =>
      _map(_motijheel, {CityLayer.metro, CityLayer.fares, CityLayer.waterlogging}, l: l),
  'citymap_mirpur_routes': (l) => _map(_mirpur, {CityLayer.metro, CityLayer.bus}, to: true, l: l),
  'citymap_airport': (l) => _map(_airport, {CityLayer.metro, CityLayer.bus}, l: l),
  'citymap_google': (l) =>
      _map(_mirpur, const {}, to: true, view: CityMapView.google, more: true, l: l),
  'citymap_learn_card': (l) => Scaffold(
        body: SafeArea(
          child: CityTripLearnCard(
              rides: learnableRides(CityPlan.from(fakeCityPlan()).options[CityPick.cheapest]!)),
        ),
      ),
};
