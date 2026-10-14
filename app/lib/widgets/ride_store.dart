import 'dart:convert';
import '../state.dart';

/// Ride & food ADVANCED — local, offline-first store (feature SPEC v2.1 §21).
///
/// This module is a DEEP-LINK LAUNCHER only. It never books a trip, never takes
/// payment, and never fabricates fares or availability. The only thing it
/// persists is what the *user* explicitly keeps so their next launch is faster:
///   • saved places (home / work / custom) used to prefill a drop-off
///   • recent trips (destination strings) they launched a ride for
///   • saved restaurants / cravings (food search strings) for one-tap reorder
///
/// All persistence is via [Settings] (SharedPreferences). No server round-trip,
/// no backend model — the backend has no ride/food booking endpoint by design.

/// A saved place the user can reuse as a drop-off. [kind] is one of
/// 'home' | 'work' | 'other' (home/work are singletons; others are free).
class SavedPlace {
  final String kind;
  final String label; // e.g. "Home", or a user nickname
  final String address; // the free-text drop-off we prefill into the provider

  const SavedPlace({
    required this.kind,
    required this.label,
    required this.address,
  });

  static const home = 'home';
  static const work = 'work';
  static const other = 'other';

  bool get isFixed => kind == home || kind == work;

  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(
        kind: '${j['kind'] ?? other}',
        label: '${j['label'] ?? ''}',
        address: '${j['address'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'label': label,
        'address': address,
      };
}

/// A saved restaurant / craving — just the search string the user wants to
/// reopen in a food app. No menu/price is stored (we never have real ones).
class SavedCraving {
  final String query;
  const SavedCraving(this.query);

  factory SavedCraving.fromJson(Map<String, dynamic> j) =>
      SavedCraving('${j['query'] ?? ''}');
  Map<String, dynamic> toJson() => {'query': query};
}

/// Local persistence. Keys are namespaced so they never collide.
class RideStore {
  static const _kPlaces = 'ride_places_v1'; // saved places (json list)
  static const _kTrips = 'ride_recent_trips_v1'; // recent destination strings
  static const _kCravings = 'ride_cravings_v1'; // saved food searches (json list)
  static const _maxTrips = 12;
  static const _maxCravings = 30;

  // ---- saved places -------------------------------------------------------
  Future<List<SavedPlace>> places() async {
    final raw = await Settings.getString(_kPlaces);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SavedPlace.fromJson((e as Map).cast<String, dynamic>()))
          .where((p) => p.address.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Upsert. home/work replace the existing fixed slot; others de-dup by label.
  Future<List<SavedPlace>> savePlace(SavedPlace place) async {
    if (place.address.trim().isEmpty) return places();
    final list = await places();
    if (place.isFixed) {
      list.removeWhere((p) => p.kind == place.kind);
    } else {
      list.removeWhere((p) =>
          p.kind == SavedPlace.other &&
          p.label.toLowerCase() == place.label.toLowerCase());
    }
    list.insert(0, place);
    await _store(_kPlaces, list.map((p) => p.toJson()).toList());
    return list;
  }

  Future<List<SavedPlace>> removePlace(SavedPlace place) async {
    final list = await places();
    list.removeWhere((p) =>
        p.kind == place.kind &&
        p.label == place.label &&
        p.address == place.address);
    await _store(_kPlaces, list.map((p) => p.toJson()).toList());
    return list;
  }

  // ---- recent trips (destination strings) --------------------------------
  Future<List<String>> recentTrips() async {
    final raw = await Settings.getString(_kTrips);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> pushTrip(String dest) async {
    dest = dest.trim();
    if (dest.isEmpty) return recentTrips();
    final list = await recentTrips();
    list.removeWhere((e) => e.toLowerCase() == dest.toLowerCase());
    list.insert(0, dest);
    if (list.length > _maxTrips) list.removeRange(_maxTrips, list.length);
    await Settings.setString(_kTrips, jsonEncode(list));
    return list;
  }

  Future<List<String>> clearTrips() async {
    await Settings.setString(_kTrips, jsonEncode(const []));
    return const [];
  }

  // ---- saved restaurants / cravings --------------------------------------
  Future<List<SavedCraving>> cravings() async {
    final raw = await Settings.getString(_kCravings);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SavedCraving.fromJson((e as Map).cast<String, dynamic>()))
          .where((c) => c.query.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<SavedCraving>> saveCraving(String query) async {
    query = query.trim();
    if (query.isEmpty) return cravings();
    final list = await cravings();
    list.removeWhere((c) => c.query.toLowerCase() == query.toLowerCase());
    list.insert(0, SavedCraving(query));
    if (list.length > _maxCravings) list.removeRange(_maxCravings, list.length);
    await _store(_kCravings, list.map((c) => c.toJson()).toList());
    return list;
  }

  Future<List<SavedCraving>> removeCraving(SavedCraving c) async {
    final list = await cravings();
    list.removeWhere((x) => x.query.toLowerCase() == c.query.toLowerCase());
    await _store(_kCravings, list.map((x) => x.toJson()).toList());
    return list;
  }

  Future<void> _store(String key, List<Map<String, dynamic>> list) =>
      Settings.setString(key, jsonEncode(list));
}
