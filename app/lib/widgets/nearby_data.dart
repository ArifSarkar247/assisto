// Curated mock dataset + models for the ADVANCED Nearby module.
//
// Map / Places APIs are KEY-GATED (owner Google Maps key). Until a key + live
// location are enabled, the module runs FULLY on this curated Dhaka-area
// dataset so the whole UX (categories, distance, open/closed, call, directions,
// favourites, search, filter, sort, "nearest X") is testable today. The screen
// shows an honest "mock — live when Maps key + location enabled" banner.
//
// Place names here are romanized proper-noun DATA (not UI copy) so the file
// stays free of Bangla literals; all user-facing labels come from
// AppLocalizations. The full bilingual dataset lives in the backend
// (core/logic/nearby.py) for the live/mock endpoint. We never invent ratings.

import 'package:flutter/material.dart';

/// Categories a Bangladeshi user actually needs nearby.
enum NearbyCat {
  hospital,
  pharmacy,
  atmBank,
  mobileAgent, // bKash / Nagad agent
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
  CatMeta(NearbyCat.hospital, Icons.local_hospital_outlined, Color(0xFFE0485A)),
  CatMeta(NearbyCat.pharmacy, Icons.local_pharmacy_outlined, Color(0xFF2E9E6B)),
  CatMeta(NearbyCat.atmBank, Icons.atm_outlined, Color(0xFF3B6EF6)),
  CatMeta(NearbyCat.mobileAgent, Icons.phone_android_outlined, Color(0xFFE0485A)),
  CatMeta(NearbyCat.police, Icons.local_police_outlined, Color(0xFF2347D9)),
  CatMeta(NearbyCat.fire, Icons.fire_truck_outlined, Color(0xFFE0A500)),
  CatMeta(NearbyCat.transport, Icons.directions_bus_outlined, Color(0xFF9B4DF0)),
  CatMeta(NearbyCat.fuel, Icons.local_gas_station_outlined, Color(0xFFE0A500)),
  CatMeta(NearbyCat.restaurant, Icons.restaurant_outlined, Color(0xFFE0485A)),
  CatMeta(NearbyCat.mosque, Icons.mosque_outlined, Color(0xFF2E9E6B)),
  CatMeta(NearbyCat.govt, Icons.account_balance_outlined, Color(0xFF3B6EF6)),
];

CatMeta catMeta(NearbyCat c) => kNearbyCats.firstWhere((m) => m.cat == c);

/// A single place. `name`/`addr` are romanized data (proper nouns).
class NearbyPlace {
  final String id;
  final NearbyCat cat;
  final String nameEn;
  final String addrEn;
  final double lat;
  final double lon;
  final String? phone;
  final bool open24; // 24h (pharmacy / hospital ER / fuel)
  final int? openMin; // minutes from midnight, local — null = unknown
  final int? closeMin;

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
  });

  // `bn` kept in the signature so callers stay forward-compatible once a
  // localized-name endpoint lands; today both languages show romanized data.
  String name(bool bn) => nameEn;
  String addr(bool bn) => addrEn;

  String get mapsUrl =>
      'https://www.google.com/maps/search/?api=1&query=$lat,$lon';

  /// Directions deep-link (prefilled destination).
  String get directionsUrl =>
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon';

  /// open/closed given a local [now]; null when hours unknown.
  bool? openAt(DateTime now) {
    if (open24) return true;
    if (openMin == null || closeMin == null) return null;
    final m = now.hour * 60 + now.minute;
    if (closeMin! >= openMin!) return m >= openMin! && m < closeMin!;
    return m >= openMin! || m < closeMin!; // wraps past midnight
  }
}

/// Curated dataset — a realistic Dhaka spread across every category.
const List<NearbyPlace> kNearbyMock = [
  // Hospitals / clinics
  NearbyPlace(
      id: 'h1',
      cat: NearbyCat.hospital,
      nameEn: 'Dhaka Medical College Hospital',
      addrEn: 'Secretariat Rd, Shahbag',
      lat: 23.7257,
      lon: 90.3969,
      phone: '+88029661051',
      open24: true),
  NearbyPlace(
      id: 'h2',
      cat: NearbyCat.hospital,
      nameEn: 'Square Hospital',
      addrEn: 'West Panthapath',
      lat: 23.7525,
      lon: 90.3836,
      phone: '+8801713377773',
      open24: true),
  // Pharmacies
  NearbyPlace(
      id: 'p1',
      cat: NearbyCat.pharmacy,
      nameEn: 'Lazz Pharma',
      addrEn: 'Green Rd, Dhanmondi',
      lat: 23.7490,
      lon: 90.3850,
      phone: '+88029676522',
      open24: true),
  NearbyPlace(
      id: 'p2',
      cat: NearbyCat.pharmacy,
      nameEn: 'Tamanna Pharmacy',
      addrEn: 'Shantinagar',
      lat: 23.7380,
      lon: 90.4130,
      phone: '+8801811000111',
      openMin: 480, // 08:00
      closeMin: 1380), // 23:00
  // ATM / bank
  NearbyPlace(
      id: 'a1',
      cat: NearbyCat.atmBank,
      nameEn: 'DBBL ATM — Motijheel',
      addrEn: 'Motijheel C/A',
      lat: 23.7330,
      lon: 90.4172,
      open24: true),
  NearbyPlace(
      id: 'a2',
      cat: NearbyCat.atmBank,
      nameEn: 'BRAC Bank — Dhanmondi',
      addrEn: 'Road 27, Dhanmondi',
      lat: 23.7560,
      lon: 90.3720,
      phone: '+88016221',
      openMin: 600, // 10:00
      closeMin: 1020), // 17:00
  // Mobile money agent
  NearbyPlace(
      id: 'm1',
      cat: NearbyCat.mobileAgent,
      nameEn: 'bKash Agent — New Market',
      addrEn: 'New Market, Azimpur',
      lat: 23.7340,
      lon: 90.3860,
      phone: '+8801700000000',
      openMin: 540, // 09:00
      closeMin: 1320), // 22:00
  NearbyPlace(
      id: 'm2',
      cat: NearbyCat.mobileAgent,
      nameEn: 'Nagad Agent — Farmgate',
      addrEn: 'Farmgate',
      lat: 23.7580,
      lon: 90.3900,
      openMin: 540,
      closeMin: 1290), // 21:30
  // Police
  NearbyPlace(
      id: 'pol1',
      cat: NearbyCat.police,
      nameEn: 'Shahbag Police Station',
      addrEn: 'Shahbag',
      lat: 23.7390,
      lon: 90.3950,
      phone: '999',
      open24: true),
  // Fire
  NearbyPlace(
      id: 'f1',
      cat: NearbyCat.fire,
      nameEn: 'Fire Service — Siddique Bazar',
      addrEn: 'Siddique Bazar',
      lat: 23.7250,
      lon: 90.4100,
      phone: '999',
      open24: true),
  // Transport
  NearbyPlace(
      id: 't1',
      cat: NearbyCat.transport,
      nameEn: 'Kamalapur Railway Station',
      addrEn: 'Kamalapur',
      lat: 23.7320,
      lon: 90.4260,
      phone: '+88029330730',
      open24: true),
  NearbyPlace(
      id: 't2',
      cat: NearbyCat.transport,
      nameEn: 'Sadarghat Launch Terminal',
      addrEn: 'Sadarghat',
      lat: 23.7060,
      lon: 90.4130,
      openMin: 300, // 05:00
      closeMin: 1410), // 23:30
  // Fuel / CNG / gas
  NearbyPlace(
      id: 'fu1',
      cat: NearbyCat.fuel,
      nameEn: 'Padma Filling Station',
      addrEn: 'Kazi Nazrul Islam Ave',
      lat: 23.7480,
      lon: 90.3930,
      open24: true),
  // Restaurant
  NearbyPlace(
      id: 'r1',
      cat: NearbyCat.restaurant,
      nameEn: 'Star Kabab',
      addrEn: 'Dhanmondi 27',
      lat: 23.7555,
      lon: 90.3715,
      phone: '+8801711000000',
      openMin: 420, // 07:00
      closeMin: 150), // 02:30 next day
  // Mosque
  NearbyPlace(
      id: 'mo1',
      cat: NearbyCat.mosque,
      nameEn: 'Baitul Mukarram National Mosque',
      addrEn: 'Purana Paltan',
      lat: 23.7290,
      lon: 90.4120,
      open24: true),
  // Govt office
  NearbyPlace(
      id: 'g1',
      cat: NearbyCat.govt,
      nameEn: 'City Corporation Office — Nagar Bhaban',
      addrEn: 'Fulbaria',
      lat: 23.7210,
      lon: 90.4090,
      phone: '+88029556016',
      openMin: 540, // 09:00
      closeMin: 1020), // 17:00
];
