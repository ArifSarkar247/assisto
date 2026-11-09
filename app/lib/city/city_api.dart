// cityapp: City Service endpoints (owner_actions/CITY_SERVICE_API.md).
// Zero Google calls: routing, stops, metro, directories and live reports are
// Assisto's own server; "Open in Google Maps" is only a free link.
import '../api.dart';

String _ll(double lat, double lon) => '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}';
String _q(String s) => Uri.encodeQueryComponent(s);

extension CityApi on ApiClient {
  /// §1 which city am I in / is there data.
  Future<Map<String, dynamic>> cityWhere(double lat, double lon) =>
      getJson('/city/where?lat=$lat&lon=$lon');

  /// §2 plan a trip. [at] = "HH:MM" (empty = now on the server).
  Future<Map<String, dynamic>> cityPlan(double fLat, double fLon, double tLat, double tLon,
          {String at = '', List<String> modes = const []}) =>
      getJson('/city/plan?from=${_ll(fLat, fLon)}&to=${_ll(tLat, tLon)}'
          '${at.isNotEmpty ? '&at=${_q(at)}' : ''}'
          '${modes.isNotEmpty ? '&modes=${modes.join(',')}' : ''}');

  /// §3 offline package (gzip JSON, unpacked by the HTTP client) or
  /// `{unchanged: true}` when [have] is current.
  Future<Map<String, dynamic>> cityPackage(String city, {String have = ''}) =>
      getJson('/city/package?city=${_q(city)}${have.isNotEmpty ? '&v=${_q(have)}' : ''}');

  /// §4 metro.
  Future<Map<String, dynamic>> cityStations(String city) => getJson('/city/stations?city=${_q(city)}');
  Future<Map<String, dynamic>> cityStation(String city, String id, {double? lat, double? lon}) =>
      getJson('/city/station/${Uri.encodeComponent(id)}?city=${_q(city)}'
          '${lat != null && lon != null ? '&lat=$lat&lon=$lon' : ''}');
  Future<Map<String, dynamic>> cityMetro(String city) => getJson('/city/metro?city=${_q(city)}');

  /// §5 search / directories.
  Future<Map<String, dynamic>> citySearch(String city, String q) =>
      getJson('/city/search?city=${_q(city)}&q=${_q(q)}');
  Future<Map<String, dynamic>> cityRoute(String city, String id) =>
      getJson('/city/route/${Uri.encodeComponent(id)}?city=${_q(city)}');
  Future<Map<String, dynamic>> cityStopsNear(double lat, double lon) =>
      getJson('/city/stops/near?lat=$lat&lon=$lon');

  /// kind = terminals | ghats | offices
  Future<Map<String, dynamic>> cityDirectory(String city, String kind) =>
      getJson('/city/$kind?city=${_q(city)}');

  /// Women options (requested from citydata 9 Nov; a 404 = not built yet).
  Future<Map<String, dynamic>> cityWomen(String city) => getJson('/city/women?city=${_q(city)}');

  /// §6 live reports.
  Future<Map<String, dynamic>> cityReports(double lat, double lon, {double km = 3}) =>
      getJson('/city/reports?lat=$lat&lon=$lon&km=$km');
  Future<Map<String, dynamic>> cityReport(String kind, double lat, double lon, {String routeId = ''}) =>
      postJson('/city/reports', {
        'kind': kind,
        'lat': lat,
        'lon': lon,
        if (routeId.isNotEmpty) 'route_id': routeId,
      });
  Future<Map<String, dynamic>> cityReportFlag(int id) => postJson('/city/reports/$id/flag', {});

  /// §7 corrections + user facts.
  Future<Map<String, dynamic>> cityCorrection(
          {required String target, String targetId = '', required String kind, String text = '',
          double? lat, double? lon, String city = 'dhaka'}) =>
      postJson('/city/correction', {
        'city': city,
        'target': target,
        'target_id': targetId,
        'kind': kind,
        'text': text,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
      });
  Future<Map<String, dynamic>> cityFareReport(String mode, int paid,
          {double? km, double? fLat, double? fLon, double? tLat, double? tLon, String city = 'dhaka'}) =>
      postJson('/city/fare-report', {
        'city': city,
        'mode': mode,
        'paid': paid,
        if (km != null) 'km': km,
        if (fLat != null && fLon != null) 'from': _ll(fLat, fLon),
        if (tLat != null && tLon != null) 'to': _ll(tLat, tLon),
      });
  Future<Map<String, dynamic>> cityNightRating(String routeId, int stars, {String city = 'dhaka'}) =>
      postJson('/city/night-rating', {'city': city, 'route_id': routeId, 'stars': stars});
}
