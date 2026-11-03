import '../api.dart';

/// mapscost (owner order 3 Nov 18:40, PART 1) — the app's door to PAID maps
/// calls. Everything goes through OUR server proxy (server key never on the
/// phone, per-user + global daily caps). Every answer has `state`; anything
/// but ok / cache means "show the free fallback" (coordinates + Open in
/// Google Maps). SOS never calls any of these.
extension MapsCostApi on ApiClient {
  /// GET /maps/reverse -> {state, address, coords, gmaps_url}. Call only after
  /// the phone's own (free) Geocoder found nothing — see address_resolver.dart.
  Future<Map<String, dynamic>> mapsReverse(double lat, double lng) =>
      getJson('/maps/reverse?lat=${lat.toStringAsFixed(6)}&lng=${lng.toStringAsFixed(6)}');

  /// GET /maps/autocomplete -> {state, results:[{place_id, name, secondary}]}
  Future<Map<String, dynamic>> mapsAutocomplete(String q, String session,
          {double? lat, double? lng}) =>
      getJson('/maps/autocomplete?q=${Uri.encodeQueryComponent(q)}'
          '&session=${Uri.encodeQueryComponent(session)}'
          '${lat != null && lng != null ? '&lat=$lat&lng=$lng' : ''}');

  /// GET /maps/place -> {state, lat, lng, address} (ONE Place Details
  /// Essentials; ends the autocomplete session).
  Future<Map<String, dynamic>> mapsPlace(String placeId, String session) =>
      getJson('/maps/place?id=${Uri.encodeQueryComponent(placeId)}'
          '&session=${Uri.encodeQueryComponent(session)}');

  /// GET /maps/eta -> {state, minutes, distance_m, gmaps_url} — ONE Routes
  /// call, only on the user's tap (cached 10 min on the server).
  Future<Map<String, dynamic>> mapsEta(double oLat, double oLng, double dLat, double dLng,
          {String mode = ''}) =>
      getJson('/maps/eta?olat=${oLat.toStringAsFixed(6)}&olng=${oLng.toStringAsFixed(6)}'
          '&dlat=${dLat.toStringAsFixed(6)}&dlng=${dLng.toStringAsFixed(6)}'
          '&mode=${Uri.encodeQueryComponent(mode)}');
}

/// The free "Open in Google Maps" link for a point (opening the app is free).
String mapsSearchUrl(double lat, double lng) =>
    'https://www.google.com/maps/search/?api=1&query=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

/// Coordinates as text — the always-available fallback "address".
String mapsCoordsText(double lat, double lng) =>
    '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
