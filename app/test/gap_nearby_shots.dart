// gap-nearby: gallery shots — Nearby offline with the saved date (server
// down, list from the phone) and an unnamed place / number sources.
import 'dart:convert';

import 'package:assisto/nearby/area_cache.dart';
import 'package:assisto/screens/nearby_screen.dart';
import 'package:flutter/widgets.dart';

AreaCache _savedCache() {
  final saved = DateTime(2026, 11, 18, 10, 5).millisecondsSinceEpoch;
  const area = EmergencyArea(
    key: '23:90', lat0: 22, lat1: 25, lon0: 89, lon1: 92, version: 'BD:1', country: 'BD',
    attribution: '© OpenStreetMap contributors (ODbL)',
    places: [
      AreaPlace(21, 'hospital', 'Sample Hospital One', 'Sample Hospital One', 23.7400, 90.3960, '', 'osm', ''),
      AreaPlace(22, 'hospital', '', '', 23.7450, 90.3990, '', 'osm', ''),
      AreaPlace(23, 'hospital', 'Sample Hospital Two', 'Sample Hospital Two', 23.7500, 90.4000, '10666', 'osm', 'admin'),
    ],
  );
  final store = MemoryAreaStore();
  final raw = jsonEncode(area.toServerShape());
  store.files['area_23:90'] = raw;
  store.files['index'] = jsonEncode([
    {'key': '23:90', 'lat0': 22, 'lat1': 25, 'lon0': 89, 'lon1': 92, 'version': 'BD:1',
     'bytes': raw.length, 'used': saved, 'saved': saved},
  ]);
  return AreaCache(store, clock: () => DateTime(2026, 11, 18, 10, 5));
}

/// Built with FakeMode.fail (server unreachable).
final Map<String, Widget Function(String)> gapNearbyShots = {
  'gapnearby_offline_dated': (l) =>
      NearbyScreen(debugLocation: (lat: 23.738, lon: 90.395), cache: _savedCache()),
};
