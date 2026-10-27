// Models for the Nearby module — REAL places only.
//
// truth (owner FINAL ORDER 27 Oct: "no demo or fake data anywhere, real
// licensed data sources"): the curated Dhaka "mock" dataset (made-up phone
// numbers and opening hours) is gone. Places come from the server's live
// layer GET /nearby (backend core/nearby.py): Google Places when the owner's
// key works, otherwise OpenStreetMap Overpass (ODbL, cached, rate-limited);
// the licence line the server returns is shown under the list. No location
// or the source down -> an honest state, never sample rows.
//
// The "mobile money agent" category was dropped: no licensed open source
// lists bKash / Nagad agents. Ratings are never invented.

import 'package:flutter/material.dart';

/// Categories a Bangladeshi user actually needs nearby.
enum NearbyCat {
  hospital,
  pharmacy,
  atmBank,
  police,
  fire,
  transport, // bus / train / launch terminal
  fuel, // petrol / CNG / gas
  restaurant,
  mosque,
  govt,
}

/// Per-category icon + tint. Labels are resolved via AppLocalizations.
class CatMeta {
  final NearbyCat cat;
  final IconData icon;
  final Color tint;
  const CatMeta(this.cat, this.icon, this.tint);
}

const List<CatMeta> kNearbyCats = [
  CatMeta(NearbyCat.hospital, Icons.local_hospital_rounded, Color(0xFFE0485A)),
  CatMeta(NearbyCat.pharmacy, Icons.local_pharmacy_rounded, Color(0xFF2E9E6B)),
  CatMeta(NearbyCat.atmBank, Icons.atm_rounded, Color(0xFF3B6EF6)),
  CatMeta(NearbyCat.police, Icons.local_police_rounded, Color(0xFF2347D9)),
  CatMeta(NearbyCat.fire, Icons.fire_truck_rounded, Color(0xFFE0A500)),
  CatMeta(NearbyCat.transport, Icons.directions_bus_rounded, Color(0xFF9B4DF0)),
  CatMeta(NearbyCat.fuel, Icons.local_gas_station_rounded, Color(0xFFE0A500)),
  CatMeta(NearbyCat.restaurant, Icons.restaurant_rounded, Color(0xFFE0485A)),
  CatMeta(NearbyCat.mosque, Icons.mosque_rounded, Color(0xFF2E9E6B)),
  CatMeta(NearbyCat.govt, Icons.account_balance_rounded, Color(0xFF3B6EF6)),
];

CatMeta catMeta(NearbyCat c) => kNearbyCats.firstWhere((m) => m.cat == c);

/// A single place from the live source. Names/addresses are source DATA.
class NearbyPlace {
  final String id;
  final NearbyCat cat;
  final String nameEn;
  final String addrEn;
  final double lat;
  final double lon;
  final String? phone;
  final bool open24; // kept for the card; the live sources never set it
  final int? openMin; // minutes from midnight — the live sources never set it
  final int? closeMin;
  final bool? openNow; // Places open_now; OSM has none (null = unknown)

  const NearbyPlace({
    required this.id,
    required this.cat,
    required this.nameEn,
    required this.addrEn,
    required this.lat,
    required this.lon,
    this.phone,
    this.open24 = false,
    this.openMin,
    this.closeMin,
    this.openNow,
  });

  /// One row of GET /nearby `places`. Returns null for a row without a
  /// position (never guessed).
  static NearbyPlace? fromServer(Map<String, dynamic> m, NearbyCat cat) {
    final lat = (m['lat'] as num?)?.toDouble();
    final lon = (m['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    final phone = '${m['phone'] ?? ''}'.trim();
    return NearbyPlace(
      id: '${cat.name}:${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}',
      cat: cat,
      nameEn: '${m['name'] ?? ''}',
      addrEn: '${m['address'] ?? ''}',
      lat: lat,
      lon: lon,
      phone: phone.isEmpty ? null : phone,
      openNow: m['open_now'] is bool ? m['open_now'] as bool : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'cat': cat.name,
        'name': nameEn,
        'address': addrEn,
        'lat': lat,
        'lon': lon,
        'phone': phone,
      };

  /// A saved favourite (stored on the phone as the source gave it).
  static NearbyPlace? fromJson(Map<String, dynamic> m) {
    final cat = NearbyCat.values
        .where((c) => c.name == m['cat'])
        .cast<NearbyCat?>()
        .firstWhere((_) => true, orElse: () => null);
    return cat == null ? null : fromServer(m, cat);
  }

  // `bn` kept in the signature so callers stay forward-compatible once a
  // localized-name source lands; both languages show the source's name.
  String name(bool bn) => nameEn;
  String addr(bool bn) => addrEn;

  String get mapsUrl =>
      'https://www.google.com/maps/search/?api=1&query=$lat,$lon';

  /// Directions deep-link (prefilled destination).
  String get directionsUrl =>
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon';

  /// open/closed given a local [now]; null when the source does not say.
  bool? openAt(DateTime now) {
    if (openNow != null) return openNow;
    if (open24) return true;
    if (openMin == null || closeMin == null) return null;
    final m = now.hour * 60 + now.minute;
    if (closeMin! >= openMin!) return m >= openMin! && m < closeMin!;
    return m >= openMin! || m < closeMin!; // wraps past midnight
  }
}

/// The server `type` for a category (backend core/nearby.py _OSM_FILTER).
String nearbyServerType(NearbyCat c) => switch (c) {
      NearbyCat.hospital => 'hospital',
      NearbyCat.pharmacy => 'pharmacy',
      NearbyCat.atmBank => 'atm',
      NearbyCat.police => 'police',
      NearbyCat.fire => 'fire',
      NearbyCat.transport => 'transport',
      NearbyCat.fuel => 'fuel',
      NearbyCat.restaurant => 'restaurant',
      NearbyCat.mosque => 'mosque',
      NearbyCat.govt => 'govt',
    };
