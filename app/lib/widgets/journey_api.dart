import '../api.dart';

/// Safe Journey & Personal Safety API surface.
///
/// Implemented as an EXTENSION on ApiClient (built only on its public methods:
/// getJson / postJson / createItem) so this module ships WITHOUT editing the
/// shared api.dart. The integrator SHOULD later fold these into ApiClient
/// proper — the signatures + paths below are authoritative (see report
/// "api.dart methods"). Watchers are circle member ids from GET /circle/members.
extension JourneyApi on ApiClient {
  // ---- item 1/2/4: start, update, end a journey -------------------------

  /// Start a Safe Journey. destination = {name, lat?, lng?}. watcherIds are
  /// circle member ids (the ONLY audience). Returns {id, web_link?, ...}.
  /// POST /journey/start
  Future<Map<String, dynamic>> journeyStart({
    required Map<String, dynamic> destination,
    required String etaIso,
    required List<int> watcherIds,
    Map<String, dynamic>? origin,
    String? mode,
    Map<String, dynamic>? vehicle,
    int? overdueGraceMin,
    bool routeDeviationOn = false,
    int? locationRetentionHours,
  }) =>
      postJson('/journey/start', {
        'destination': destination,
        'eta': etaIso,
        'watcher_ids': watcherIds,
        if (origin != null) 'origin': origin,
        if (mode != null) 'mode': mode,
        if (vehicle != null) 'vehicle': vehicle,
        if (overdueGraceMin != null) 'overdue_grace_min': overdueGraceMin,
        'route_deviation_on': routeDeviationOn,
        if (locationRetentionHours != null)
          'location_retention_hours': locationRetentionHours,
      });

  /// Current active journey for the logged-in traveller (or {} if none).
  /// GET /journey/active
  Future<Map<String, dynamic>> journeyActive() => getJson('/journey/active');

  /// Push a live-location fix during a journey. Fires auto-arrival + low-battery
  /// + route-deviation server-side. POST /journey/<id>/location
  Future<Map<String, dynamic>> journeyLocation(
    int id, {
    required double lat,
    required double lng,
    int? battery,
  }) =>
      postJson('/journey/$id/location', {
        'lat': lat,
        'lng': lng,
        if (battery != null) 'battery': battery,
      });

  /// Mark arrived ("I'm safe") — auto or manual. POST /journey/<id>/arrived
  Future<void> journeyArrived(int id) =>
      postJson('/journey/$id/arrived', const {});

  /// Stop a journey early (not at destination). Starts the privacy
  /// auto-delete clock. POST /journey/<id>/stop {pin?} — pin is validated
  /// server-side for the duress flow (see [journeyStopWithPin]).
  Future<Map<String, dynamic>> journeyStop(int id, {String? pin}) =>
      postJson('/journey/$id/stop', {if (pin != null) 'pin': pin});

  /// Answer the overdue "Are you OK?" prompt to clear the alert path.
  /// POST /journey/<id>/respond {ok:true}
  Future<void> journeyRespondOk(int id) =>
      postJson('/journey/$id/respond', const {'ok': true});

  /// item 5: the full trip timeline watchers see (last known locations +
  /// events). GET /journey/<id>/timeline
  Future<Map<String, dynamic>> journeyTimeline(int id) =>
      getJson('/journey/$id/timeline');

  // ---- item 7/8: SOS + duress -------------------------------------------

  /// Fire an SOS during (or outside) a journey. silent=true is the duress
  /// path: watchers alerted, screen must look normal. POST /journey/sos
  Future<Map<String, dynamic>> journeySos({
    int? journeyId,
    double? lat,
    double? lng,
    bool silent = false,
    bool siren = false,
  }) =>
      postJson('/journey/sos', {
        if (journeyId != null) 'journey_id': journeyId,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        'silent': silent,
        'siren': siren,
      });

  /// Store the hashed normal + duress PINs (server hashes; raw never stored).
  /// A duress PIN that differs from the normal one triggers the silent alert.
  /// POST /journey/duress-pin {pin, duress_pin}
  Future<void> setDuressPin({required String pin, required String duressPin}) =>
      postJson('/journey/duress-pin', {'pin': pin, 'duress_pin': duressPin});

  // ---- item 10: "where are you?" consent — NOT BUILT (m2-reality removed
  // two unused client methods that called routes that never existed:
  // journey/where-are-you[/respond]). Re-add with the backend.

  // ---- item 11: nearest help (reuses the existing /nearby provider) -----

  /// Nearest police + hospitals for SOS/overdue. Reuses the Nearby layer
  /// (Google Places -> OSM). Returns {police:[...], hospital:[...]} each ranked
  /// with distance_m + directions. GET /journey/nearest-help?lat&lon
  Future<Map<String, dynamic>> nearestHelp(double lat, double lon) =>
      getJson('/journey/nearest-help?lat=$lat&lon=$lon');

  // ---- item 13: expiring web link for app-less watchers -----------------

  /// The sharable, expiring web link for the current journey (dies on stop).
  /// GET /journey/<id>/web-link -> {url, token}
  Future<Map<String, dynamic>> journeyWebLink(int id) =>
      getJson('/journey/$id/web-link');

  // ---- item 14: routine/scheduled commutes ------------------------------

  /// List saved routine journeys. GET /journey/routines
  Future<List<Map<String, dynamic>>> journeyRoutines() async {
    final r = await getJson('/journey/routines');
    return ((r['routines'] ?? []) as List).cast<Map<String, dynamic>>();
  }

  /// Save/replace a routine journey. POST /journey/routines
  /// {days:["sun",...], time:"18:00", destination:{...}, watcher_ids:[...], enabled}
  Future<void> saveJourneyRoutine(Map<String, dynamic> routine) =>
      postJson('/journey/routines', routine);

  // ---- item 16: wellness check (parents living alone) -------------------

  /// Read the wellness-watch config. GET /journey/wellness
  Future<Map<String, dynamic>> wellnessConfig() => getJson('/journey/wellness');

  /// Update wellness config. parent_opt_in MUST be true to arm.
  /// POST /journey/wellness
  Future<void> saveWellnessConfig(Map<String, dynamic> cfg) =>
      postJson('/journey/wellness', cfg);

  /// Parent pings "I'm fine" (resets the idle clock / answers a prompt).
  /// POST /journey/wellness/ping
  Future<void> wellnessPing() =>
      postJson('/journey/wellness/ping', const {});

  // ---- saved places (Home / Office / College) ---------------------------

  /// Saved destinations for one-tap journeys. GET /journey/places
  Future<List<Map<String, dynamic>>> savedPlaces() async {
    final r = await getJson('/journey/places');
    return ((r['places'] ?? []) as List).cast<Map<String, dynamic>>();
  }

  /// Save a place {label, name, lat, lng}. POST /journey/places
  Future<void> saveSavedPlace(Map<String, dynamic> place) =>
      postJson('/journey/places', place);
}
