// Curated BD travel dataset + models for the ADVANCED Unseen World module.
//
// Source policy (HONEST): destinations are hidden gems / under-visited spots
// sourced from the OWNER's own unseenbangladesh.com plus open data
// (Wikipedia / Wikivoyage / Bangladesh Tourism Board). Every destination carries
// a `source` tag shown in the UI. We NEVER invent facts. Costs and travel times
// are STABLE, widely-published APPROXIMATIONS and are always labelled "approx"
// with their source — they are not live prices and the UI says so.
//
// No photos are bundled; a destination may carry a `photoCredit` string that is
// shown verbatim as attribution. If an image URL is wired later it must keep the
// same credit line. Until then cards show a tinted category hero (no fake image).
//
// Bangla-free: all proper nouns are romanized DATA (not UI copy); every
// user-facing label comes from AppLocalizations. This mirrors the curated-dataset
// pattern already shipped for Nearby (nearby_data.dart). The backend
// (core/unseen.py) holds the bilingual mirror for the live/seed endpoint.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';

/// The eight administrative divisions of Bangladesh (romanized data).
enum Division { dhaka, chattogram, sylhet, khulna, rajshahi, barishal, rangpur, mymensingh }

String divisionId(Division d) => d.name;

/// Category of a destination — drives filter chips + hero tint/icon.
enum TravelCat { nature, historical, beach, hill, religious, island, waterfall }

String catId(TravelCat c) => c.name;

/// Rough season window (for seasonal suggestions). Multiple months allowed.
/// Months are 1..12.
class Season {
  final List<int> months;
  const Season(this.months);
  bool includes(int month) => months.contains(month);
}

/// Per-category icon + tint. Labels resolved via AppLocalizations.
class CatMeta {
  final TravelCat cat;
  final IconData icon;
  final Color tint;
  const CatMeta(this.cat, this.icon, this.tint);
}

const List<CatMeta> kTravelCats = [
  CatMeta(TravelCat.nature, Icons.forest_rounded, Brand.success),
  CatMeta(TravelCat.historical, Icons.account_balance_rounded, Brand.blue),
  CatMeta(TravelCat.beach, Icons.beach_access_rounded, Brand.cyan),
  CatMeta(TravelCat.hill, Icons.terrain_rounded, Brand.purple),
  CatMeta(TravelCat.religious, Icons.mosque_rounded, Brand.success),
  CatMeta(TravelCat.island, Icons.sailing_rounded, Brand.cyan),
  CatMeta(TravelCat.waterfall, Icons.water_drop_rounded, Brand.blue),
];

CatMeta catMeta(TravelCat c) => kTravelCats.firstWhere((m) => m.cat == c);

/// Where a fact came from — kept short so the UI can print it verbatim.
class SourceRef {
  final String label; // e.g. "unseenbangladesh.com", "Wikivoyage"
  const SourceRef(this.label);
}

const kOwnerSource = SourceRef('unseenbangladesh.com');
const kOpenData = SourceRef('Wikivoyage / open data');

/// A single destination. All prose is romanized DATA, not UI copy.
class Destination {
  final String id;
  final String name; // romanized proper noun
  final Division division;
  final TravelCat cat;
  final double lat;
  final double lon;

  /// Best time to visit, as a stable month window + a short romanized label.
  final Season season;
  final String bestTime; // e.g. "Nov-Feb"

  /// How to get there — romanized, high-level, verifiable route note.
  final String howToGet;

  /// APPROX round-trip budget per person in BDT, published-estimate range.
  /// Always rendered with an "approx" marker + source; never a live price.
  final int approxCostLow;
  final int approxCostHigh;

  /// Nearby spots worth pairing (romanized names).
  final List<String> nearby;

  /// One practical, verifiable tip (romanized).
  final String tip;

  /// Attribution shown on the card.
  final SourceRef source;

  /// Photo credit line (shown verbatim if/when an image is wired). Empty = none.
  final String photoCredit;

  const Destination({
    required this.id,
    required this.name,
    required this.division,
    required this.cat,
    required this.lat,
    required this.lon,
    required this.season,
    required this.bestTime,
    required this.howToGet,
    required this.approxCostLow,
    required this.approxCostHigh,
    required this.nearby,
    required this.tip,
    this.source = kOwnerSource,
    this.photoCredit = '',
  });

  String get mapsUrl =>
      'https://www.google.com/maps/search/?api=1&query=$lat,$lon';
  String get directionsUrl =>
      'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon';
}

/// Curated hidden-gem dataset. Facts kept to stable, widely-published basics.
/// Cost ranges are APPROXIMATE published round-trip-from-Dhaka estimates (per
/// person, budget travel) — labelled approx + sourced in the UI, never live.
const List<Destination> kDestinations = [
  Destination(
    id: 'nijhum-dwip',
    name: 'Nijhum Dwip',
    division: Division.chattogram,
    cat: TravelCat.island,
    lat: 22.0167,
    lon: 91.0167,
    season: Season([11, 12, 1, 2]),
    bestTime: 'Nov-Feb',
    howToGet: 'Dhaka to Noakhali, then boat via Hatiya to Nijhum Dwip.',
    approxCostLow: 4000,
    approxCostHigh: 7000,
    nearby: ['Hatiya', 'Namar Bazar beach'],
    tip: 'Go at dawn for spotted deer and mangroves; check tide times.',
    source: kOwnerSource,
  ),
  Destination(
    id: 'jaflong',
    name: 'Jaflong',
    division: Division.sylhet,
    cat: TravelCat.nature,
    lat: 25.1667,
    lon: 92.0167,
    season: Season([7, 8, 9, 10]),
    bestTime: 'Jul-Oct',
    howToGet: 'Dhaka to Sylhet by bus/train, then local CNG/car to Jaflong.',
    approxCostLow: 2500,
    approxCostHigh: 5000,
    nearby: ['Lalakhal', 'Sremangal tea gardens'],
    tip: 'After the monsoon the stone river and Meghalaya hills look best.',
    source: kOwnerSource,
  ),
  Destination(
    id: 'ratargul',
    name: 'Ratargul Swamp Forest',
    division: Division.sylhet,
    cat: TravelCat.nature,
    lat: 25.0030,
    lon: 91.9730,
    season: Season([6, 7, 8, 9]),
    bestTime: 'Jun-Sep',
    howToGet: 'From Sylhet city, CNG/car to Gowainghat, then country boat.',
    approxCostLow: 2500,
    approxCostHigh: 4500,
    nearby: ['Bisnakandi', 'Jaflong'],
    tip: 'Tour by boat in the wet season; do not break the branches.',
    source: kOwnerSource,
  ),
  Destination(
    id: 'nafakhum',
    name: 'Nafakhum Waterfall',
    division: Division.chattogram,
    cat: TravelCat.waterfall,
    lat: 21.7500,
    lon: 92.5330,
    season: Season([10, 11, 12]),
    bestTime: 'Oct-Dec',
    howToGet: 'Bandarban to Thanchi, boat to Remakri, then a guided trek.',
    approxCostLow: 5000,
    approxCostHigh: 9000,
    nearby: ['Remakri', 'Amiakhum'],
    tip: 'Needs a boat from Remakri and a trek; hire a local guide.',
    source: kOwnerSource,
  ),
  Destination(
    id: 'sajek',
    name: 'Sajek Valley',
    division: Division.chattogram,
    cat: TravelCat.hill,
    lat: 23.3820,
    lon: 92.2920,
    season: Season([9, 10, 11, 12, 1, 2, 3]),
    bestTime: 'Sep-Mar',
    howToGet: 'Khagrachari, then Chander Gari (jeep) convoy up to Sajek.',
    approxCostLow: 4000,
    approxCostHigh: 7000,
    nearby: ['Konglak hill', 'Hajachara waterfall'],
    tip: 'Arrive the night before for the morning clouds; carry water.',
    source: kOwnerSource,
  ),
  Destination(
    id: 'kuakata',
    name: 'Kuakata',
    division: Division.barishal,
    cat: TravelCat.beach,
    lat: 21.8170,
    lon: 90.1200,
    season: Season([11, 12, 1, 2, 3]),
    bestTime: 'Nov-Mar',
    howToGet: 'Dhaka to Patuakhali/Kuakata by bus; launch is an option too.',
    approxCostLow: 3000,
    approxCostHigh: 6000,
    nearby: ['Fatrar Char', 'Gangamati forest'],
    tip: 'See both sunrise and sunset from the same beach.',
    source: kOwnerSource,
  ),
  Destination(
    id: 'paharpur',
    name: 'Paharpur (Somapura Mahavihara)',
    division: Division.rajshahi,
    cat: TravelCat.historical,
    lat: 25.0310,
    lon: 88.9770,
    season: Season([11, 12, 1, 2]),
    bestTime: 'Nov-Feb',
    howToGet: 'Dhaka to Naogaon/Jaypurhat, then local transport to Paharpur.',
    approxCostLow: 2500,
    approxCostHigh: 5000,
    nearby: ['Mahasthangarh', 'Kusumba Mosque'],
    tip: 'UNESCO site; go in the cool morning and keep to marked paths.',
    source: kOpenData,
    photoCredit: 'Photo (if shown): Wikimedia Commons, CC BY-SA',
  ),
  Destination(
    id: 'mahasthangarh',
    name: 'Mahasthangarh',
    division: Division.rajshahi,
    cat: TravelCat.historical,
    lat: 24.9670,
    lon: 89.3420,
    season: Season([11, 12, 1, 2]),
    bestTime: 'Nov-Feb',
    howToGet: 'Dhaka to Bogura by bus, then local transport north.',
    approxCostLow: 2000,
    approxCostHigh: 4000,
    nearby: ['Paharpur', 'Bogura town'],
    tip: 'One of the oldest urban sites in the region; visit the museum.',
    source: kOpenData,
    photoCredit: 'Photo (if shown): Wikimedia Commons, CC BY-SA',
  ),
  Destination(
    id: 'srimangal',
    name: 'Srimangal',
    division: Division.sylhet,
    cat: TravelCat.nature,
    lat: 24.3060,
    lon: 91.7300,
    season: Season([10, 11, 12, 1, 2]),
    bestTime: 'Oct-Feb',
    howToGet: 'Dhaka to Srimangal by train or bus (tea-capital line).',
    approxCostLow: 2500,
    approxCostHigh: 5000,
    nearby: ['Lawachara forest', 'Madhabpur lake'],
    tip: 'Try seven-layer tea; the forest is best early for birds.',
    source: kOwnerSource,
  ),
  Destination(
    id: 'sundarbans',
    name: 'Sundarbans',
    division: Division.khulna,
    cat: TravelCat.nature,
    lat: 21.9497,
    lon: 89.1833,
    season: Season([11, 12, 1, 2]),
    bestTime: 'Nov-Feb',
    howToGet: 'Khulna/Mongla, then a licensed launch tour into the forest.',
    approxCostLow: 8000,
    approxCostHigh: 15000,
    nearby: ['Karamjal', 'Kotka'],
    tip: 'Book a registered tour operator; never travel the forest alone.',
    source: kOpenData,
    photoCredit: 'Photo (if shown): Wikimedia Commons, CC BY-SA',
  ),
  Destination(
    id: 'mainamati',
    name: 'Mainamati',
    division: Division.chattogram,
    cat: TravelCat.historical,
    lat: 23.4330,
    lon: 91.1330,
    season: Season([11, 12, 1, 2]),
    bestTime: 'Nov-Feb',
    howToGet: 'Dhaka to Cumilla by bus/train, then a short local hop.',
    approxCostLow: 1500,
    approxCostHigh: 3500,
    nearby: ['Shalban Vihara', 'Cumilla town'],
    tip: 'Buddhist ruins and museum; combine with Shalban Vihara.',
    source: kOpenData,
    photoCredit: 'Photo (if shown): Wikimedia Commons, CC BY-SA',
  ),
  Destination(
    id: 'bisnakandi',
    name: 'Bisnakandi',
    division: Division.sylhet,
    cat: TravelCat.nature,
    lat: 25.1830,
    lon: 91.8670,
    season: Season([6, 7, 8, 9]),
    bestTime: 'Jun-Sep',
    howToGet: 'From Sylhet, CNG to Gowainghat, then boat to Bisnakandi.',
    approxCostLow: 2500,
    approxCostHigh: 4500,
    nearby: ['Ratargul', 'Pangthumai'],
    tip: 'Monsoon fills the stone riverbed below the hills; carry a dry bag.',
    source: kOwnerSource,
  ),
];

double _rad(double d) => d * math.pi / 180;

/// Great-circle distance in metres.
double haversineMeters(double la1, double lo1, double la2, double lo2) {
  const r = 6371000.0;
  final dLa = _rad(la2 - la1), dLo = _rad(lo2 - lo1);
  final a = math.sin(dLa / 2) * math.sin(dLa / 2) +
      math.cos(_rad(la1)) *
          math.cos(_rad(la2)) *
          math.sin(dLo / 2) *
          math.sin(dLo / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Filter + search the curated list. All args optional.
List<Destination> searchDestinations({
  Division? division,
  TravelCat? cat,
  String query = '',
  bool Function(String id)? savedOnly,
}) {
  final q = query.trim().toLowerCase();
  return kDestinations.where((d) {
    if (savedOnly != null && !savedOnly(d.id)) return false;
    if (division != null && d.division != division) return false;
    if (cat != null && d.cat != cat) return false;
    if (q.isNotEmpty) {
      final hay = '${d.name} ${d.howToGet} ${d.nearby.join(' ')}'.toLowerCase();
      if (!hay.contains(q)) return false;
    }
    return true;
  }).toList();
}

/// Destinations whose best-season window includes [month] (1..12).
List<Destination> seasonalFor(int month) =>
    kDestinations.where((d) => d.season.includes(month)).toList();

/// A ready-made multi-stop trip idea (curated, same division pairing).
class TripIdea {
  final String id;
  final TravelCat cat; // hero tint
  final int days;
  final List<String> stopIds; // destination ids
  const TripIdea(this.id, this.cat, this.days, this.stopIds);

  List<Destination> stops() => stopIds
      .map((id) => kDestinations.firstWhere((d) => d.id == id))
      .toList();

  /// APPROX total from the stops' low/high sums (labelled approx in UI).
  (int, int) approxCost() {
    var lo = 0, hi = 0;
    for (final d in stops()) {
      lo += d.approxCostLow;
      hi += d.approxCostHigh;
    }
    return (lo, hi);
  }
}

const List<TripIdea> kTripIdeas = [
  TripIdea('sylhet-green', TravelCat.nature, 3, ['srimangal', 'jaflong', 'ratargul']),
  TripIdea('hill-adventure', TravelCat.hill, 4, ['sajek', 'nafakhum']),
  TripIdea('heritage-north', TravelCat.historical, 3, ['mahasthangarh', 'paharpur']),
  TripIdea('coast-escape', TravelCat.beach, 3, ['kuakata', 'nijhum-dwip']),
];
