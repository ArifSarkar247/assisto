import '../api.dart';

/// v1-vehicle: thin typed wrappers over the vehicle-tracking REST surface
/// (backend core/views_vehicle.py, all under /api/v1/vehicle/). Errors come
/// back as [ApiException] whose `message` is the server's machine `reason`
/// code (e.g. 'moving', 'stale_fix', 'bad_pin') — see [vehReasonText].
extension VehicleApi on ApiClient {
  Future<Map<String, dynamic>> vehConfig() => getJson('/vehicle/config');

  Future<Map<String, dynamic>> vehTrackers() => getJson('/vehicle/trackers');

  Future<Map<String, dynamic>> vehPair(String imei,
          {String name = '', int? vehicleRecordId, String protocol = 'auto'}) =>
      postJson('/vehicle/trackers', {
        'imei': imei,
        'name': name,
        'protocol': protocol,
        if (vehicleRecordId != null) 'vehicle_record_id': vehicleRecordId,
      });

  Future<Map<String, dynamic>> vehTracker(int id) =>
      getJson('/vehicle/trackers/$id');

  Future<Map<String, dynamic>> vehUpdate(int id, Map<String, dynamic> body) =>
      patchJson('/vehicle/trackers/$id', body);

  Future<Map<String, dynamic>> vehRemove(int id) =>
      deleteJson('/vehicle/trackers/$id');

  Future<Map<String, dynamic>> vehRoute(int id, {int hours = 24}) =>
      getJson('/vehicle/trackers/$id/route?hours=$hours');

  Future<Map<String, dynamic>> vehCommands(int id) =>
      getJson('/vehicle/trackers/$id/commands');

  Future<Map<String, dynamic>> vehSendCommand(int id, String kind, String pin) =>
      postJson('/vehicle/trackers/$id/commands', {'kind': kind, 'pin': pin});

  Future<Map<String, dynamic>> vehApprove(int commandId, String pin) =>
      postJson('/vehicle/commands/$commandId/approve', {'pin': pin});

  Future<Map<String, dynamic>> vehCancel(int commandId) =>
      postJson('/vehicle/commands/$commandId/cancel');

  Future<Map<String, dynamic>> vehObd(int id) =>
      getJson('/vehicle/trackers/$id/obd');

  Future<Map<String, dynamic>> vehObdDecode(List<String> codes) =>
      postJson('/vehicle/obd/decode', {'codes': codes});

  Future<Map<String, dynamic>> vehAiSummary(int id, String lang) =>
      postJson('/vehicle/trackers/$id/ai-summary', {'lang': lang});

  Future<Map<String, dynamic>> vehGrants(int id) =>
      getJson('/vehicle/trackers/$id/grants');

  Future<Map<String, dynamic>> vehGrantFamily(int id, int memberId,
          {bool canCommand = false}) =>
      postJson('/vehicle/trackers/$id/grants',
          {'kind': 'family', 'member_id': memberId, 'can_command': canCommand});

  Future<Map<String, dynamic>> vehRevokeGrant(int id, int grantId) =>
      deleteJson('/vehicle/trackers/$id/grants/$grantId');

  /// [speedLimitKmh] / [route] make the server replay the same alert engine
  /// over the trip (the app already showed them live).
  Future<Map<String, dynamic>> vehCarModeTrip(List<Map<String, dynamic>> points,
          {int? vehicleRecordId, int speedLimitKmh = 0, Map<String, dynamic>? route}) =>
      postJson('/vehicle/carmode/trip', {
        'points': points,
        if (vehicleRecordId != null) 'vehicle_record_id': vehicleRecordId,
        if (speedLimitKmh > 0) 'speed_limit_kmh': speedLimitKmh,
        if (route != null) 'route': route,
      });

  /// Planned routes (off-route / long-stop alerts) — replaces the list.
  Future<Map<String, dynamic>> vehSetRoutes(int id, List<Map<String, dynamic>> routes) =>
      patchJson('/vehicle/trackers/$id', {'routes': routes});

  Future<Map<String, dynamic>> vehFleet() => getJson('/vehicle/fleet');

  // ---- veh100 ----------------------------------------------------------

  /// The SECOND confirmation of an engine cut (one-time token, 60 s).
  Future<Map<String, dynamic>> vehConfirmCommand(int commandId, String token) =>
      postJson('/vehicle/commands/$commandId/confirm', {'confirm_token': token});

  Future<Map<String, dynamic>> vehShares(int id) => getJson('/vehicle/trackers/$id/share');

  Future<Map<String, dynamic>> vehShareCreate(int id, int hours, {String label = ''}) =>
      postJson('/vehicle/trackers/$id/share', {'hours': hours, 'label': label});

  Future<Map<String, dynamic>> vehShareRevoke(int id, int linkId) =>
      deleteJson('/vehicle/trackers/$id/share/$linkId');

  /// [period] 'day' (with [date] yyyy-MM-dd) or 'month' (with [month] yyyy-MM).
  Future<Map<String, dynamic>> vehReport(int id,
      {String period = 'day', String? date, String? month, int? driverId}) {
    final q = <String>['period=$period'];
    if (date != null) q.add('date=$date');
    if (month != null) q.add('month=$month');
    if (driverId != null) q.add('driver=$driverId');
    return getJson('/vehicle/trackers/$id/report?${q.join('&')}');
  }

  /// The same report as a CSV file (UTF-8 with BOM; headers in [lang]).
  Future<List<int>> vehReportCsv(int id, String lang,
      {String period = 'day', String? date, String? month}) {
    final q = <String>['period=$period', 'export=csv', 'lang=$lang'];
    if (date != null) q.add('date=$date');
    if (month != null) q.add('month=$month');
    return getBytes('/vehicle/trackers/$id/report?${q.join('&')}');
  }

  Future<Map<String, dynamic>> vehDriver(int id) => getJson('/vehicle/trackers/$id/driver');

  /// [driverId] null = nobody is driving now (ends the open shift).
  Future<Map<String, dynamic>> vehAssignDriver(int id, int? driverId) =>
      postJson('/vehicle/trackers/$id/driver', {'driver_id': driverId});

  Future<Map<String, dynamic>> vehDriverReport(int driverId, {String? month}) =>
      getJson('/vehicle/drivers/$driverId/report${month == null ? '' : '?month=$month'}');

  Future<Map<String, dynamic>> vehMaintenance() => getJson('/vehicle/maintenance');

  Future<Map<String, dynamic>> vehSetupGuide(String brand, String operator,
          {String password = ''}) =>
      getJson('/vehicle/setup-guide?brand=$brand&operator=$operator'
          '${password.isEmpty ? '' : '&password=${Uri.encodeQueryComponent(password)}'}');
}

/// Safe accessors for loosely-typed JSON.
double? vehNum(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v');
int? vehInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
Map<String, dynamic> vehMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> vehList(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];
