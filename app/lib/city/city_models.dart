// cityapp (owner order 9 Nov 11:45, City Service): the phone's models of the
// City Service API (owner_actions/CITY_SERVICE_API.md, built by citydata).
//
// Every parser is defensive: a missing or odd field becomes an empty value,
// never an exception — a half-filled answer still renders honestly.
library;

double? _d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
int _i(Object? v) => v is num ? v.round() : int.tryParse('${v ?? ''}') ?? 0;
String _s(Object? v) => v == null ? '' : '$v';
List<String> _sl(Object? v) =>
    v is List ? [for (final e in v) if (e != null && '$e'.isNotEmpty) '$e'] : const [];
Map<String, dynamic> _m(Object? v) =>
    v is Map ? v.map((k, e) => MapEntry('$k', e)) : const <String, dynamic>{};

/// Fare labels the app shows (contract table). `mixed` = an option whose
/// legs carry different labels.
enum FareLabel { official, reported, estimate, mixed }

FareLabel fareLabelOf(String s) => switch (s) {
      'official' => FareLabel.official,
      'reported' => FareLabel.reported,
      'mixed' => FareLabel.mixed,
      _ => FareLabel.estimate,
    };

/// `{low, high, label, basis, checked, source, source_url}` (+ metro `card`,
/// CNG `meter` + `overcharge_note`).
class CityFare {
  final int low, high;
  final FareLabel label;
  final String basis, checked, source, sourceUrl;
  final int? card, meter;
  final bool overchargeNote;
  const CityFare(
      {required this.low,
      required this.high,
      this.label = FareLabel.estimate,
      this.basis = '',
      this.checked = '',
      this.source = '',
      this.sourceUrl = '',
      this.card,
      this.meter,
      this.overchargeNote = false});

  static CityFare? from(Object? v) {
    final m = _m(v);
    if (m.isEmpty || m['low'] == null) return null;
    final low = _i(m['low']);
    return CityFare(
        low: low,
        high: m['high'] == null ? low : _i(m['high']),
        label: fareLabelOf(_s(m['label'])),
        basis: _s(m['basis']),
        checked: _s(m['checked']),
        source: _s(m['source']),
        sourceUrl: _s(m['source_url']),
        card: m['card'] == null ? null : _i(m['card']),
        meter: m['meter'] == null ? null : _i(m['meter']),
        overchargeNote: m['overcharge_note'] == true);
  }

  /// One number only when low == high (contract); ride share is always a
  /// range (the server never sends low == high for it).
  bool get single => low == high;
}

/// A stop / station / point on a leg.
class CityPoint {
  final String id, name, nameBn, status;
  final double? lat, lon;
  final bool here, dest;
  const CityPoint(
      {this.id = '',
      this.name = '',
      this.nameBn = '',
      this.status = '',
      this.lat,
      this.lon,
      this.here = false,
      this.dest = false});

  static CityPoint from(Object? v) {
    final m = _m(v);
    return CityPoint(
        id: _s(m['id']),
        name: _s(m['name']),
        nameBn: _s(m['name_bn']),
        status: _s(m['status']),
        lat: _d(m['lat']),
        lon: _d(m['lon']),
        here: m['here'] == true,
        dest: m['dest'] == true);
  }

  /// Bangla name when the app is Bangla and we have one, else the name.
  String label(bool bn) => bn && nameBn.isNotEmpty ? nameBn : name;
}

/// A place near a metro exit: `[name, name_bn, kind, metres]` or a string.
class GateNear {
  final String name, nameBn, kind;
  final int meters;
  const GateNear(this.name, this.nameBn, this.kind, this.meters);
  static GateNear? from(Object? v) {
    if (v is List && v.isNotEmpty) {
      return GateNear(_s(v[0]), v.length > 1 ? _s(v[1]) : '',
          v.length > 2 ? _s(v[2]) : '', v.length > 3 ? _i(v[3]) : 0);
    }
    if (v is Map) {
      final m = _m(v);
      return GateNear(_s(m['name']), _s(m['name_bn']), _s(m['kind']), _i(m['m'] ?? m['meters']));
    }
    if (v is String && v.isNotEmpty) return GateNear(v, '', '', 0);
    return null;
  }

  String label(bool bn) => bn && nameBn.isNotEmpty ? nameBn : name;
}

/// A metro exit gate.
class CityGate {
  final String ref, name, nameBn, side, status;
  final double? lat, lon;
  final List<GateNear> near;
  final List<CityPoint> stands;
  final List<String> buses;
  final bool? lift, escalator, wheelchair;
  const CityGate(
      {this.ref = '',
      this.name = '',
      this.nameBn = '',
      this.side = '',
      this.status = '',
      this.lat,
      this.lon,
      this.near = const [],
      this.stands = const [],
      this.buses = const [],
      this.lift,
      this.escalator,
      this.wheelchair});

  static CityGate? from(Object? v) {
    final m = _m(v);
    if (m.isEmpty) return null;
    bool? b(Object? x) => x == null ? null : (x == true || x == 'yes');
    return CityGate(
        ref: _s(m['ref']),
        name: _s(m['name']),
        nameBn: _s(m['name_bn']),
        side: _s(m['side']),
        status: _s(m['status']),
        lat: _d(m['lat']),
        lon: _d(m['lon']),
        near: [
          for (final e in (m['near'] is List ? m['near'] as List : const []))
            if (GateNear.from(e) case final g?) g
        ],
        stands: [
          for (final e in (m['stands'] is List ? m['stands'] as List : const []))
            if (e is Map) CityPoint.from(e)
        ],
        buses: _sl(m['buses']),
        lift: b(m['lift']),
        escalator: b(m['escalator']),
        wheelchair: b(m['wheelchair']));
  }

  /// "Gate A" style short name: the ref, else the name.
  String title(bool bn) => ref.isNotEmpty ? ref : (bn && nameBn.isNotEmpty ? nameBn : name);
}

/// Leg modes. Vehicle legs: metro, bus, leguna, water.
const kVehicleModes = {'metro', 'bus', 'leguna', 'water'};

class CityLeg {
  final String mode;
  // walk / rickshaw
  final int meters;
  final CityPoint? from, to;
  // vehicle
  final String route, routeBn, ref, routeId, status, source;
  final CityPoint? board, alight, towards;
  final int stops, waitMin, headwayMin;
  final List<String> via, viaBn;
  final double km;
  final CityGate? exitGate;
  // both
  final int minutes;
  final CityFare? fare;
  final bool womenOnly;

  const CityLeg(
      {required this.mode,
      this.meters = 0,
      this.from,
      this.to,
      this.route = '',
      this.routeBn = '',
      this.ref = '',
      this.routeId = '',
      this.status = '',
      this.source = '',
      this.board,
      this.alight,
      this.towards,
      this.stops = 0,
      this.waitMin = 0,
      this.headwayMin = 0,
      this.via = const [],
      this.viaBn = const [],
      this.km = 0,
      this.exitGate,
      this.minutes = 0,
      this.fare,
      this.womenOnly = false});

  bool get isVehicle => kVehicleModes.contains(mode);

  static CityLeg parse(Object? v) {
    final m = _m(v);
    final vehicle = kVehicleModes.contains(_s(m['mode']));
    return CityLeg(
        mode: _s(m['mode']).isEmpty ? 'walk' : _s(m['mode']),
        meters: _i(m['meters']),
        from: m['from'] == null ? null : CityPoint.from(m['from']),
        to: m['to'] == null ? null : CityPoint.from(m['to']),
        route: _s(m['route']),
        routeBn: _s(m['route_bn']),
        ref: _s(m['ref']),
        routeId: _s(m['route_id']),
        status: _s(m['status']),
        source: m['source'] is List ? '' : _s(m['source']),
        board: vehicle && m['board'] != null ? CityPoint.from(m['board']) : null,
        alight: vehicle && m['alight'] != null ? CityPoint.from(m['alight']) : null,
        towards: vehicle && m['towards'] != null ? CityPoint.from(m['towards']) : null,
        stops: _i(m['stops']),
        waitMin: _i(m['wait_min']),
        headwayMin: _i(m['headway_min']),
        via: _sl(m['via']),
        viaBn: _sl(m['via_bn']),
        km: _d(m['km']) ?? 0,
        exitGate: CityGate.from(m['exit_gate']),
        minutes: _i(m['minutes']),
        fare: CityFare.from(m['fare']),
        womenOnly: m['women_only'] == true);
  }

  String routeLabel(bool bn) => bn && routeBn.isNotEmpty ? routeBn : (route.isNotEmpty ? route : ref);
}

/// The four chips, in the owner's order.
enum CityPick { cheapest, fastest, fewestChanges, saferNight }

const kCityPickKeys = {
  CityPick.cheapest: 'cheapest',
  CityPick.fastest: 'fastest',
  CityPick.fewestChanges: 'fewest_changes',
  CityPick.saferNight: 'safer_night',
};

class CityOption {
  final int minutes, changes, walkM;
  final CityFare fare;
  final List<String> modes;
  final String status;
  final List<CityLeg> legs;
  const CityOption(
      {required this.minutes,
      required this.fare,
      this.changes = 0,
      this.walkM = 0,
      this.modes = const [],
      this.status = '',
      this.legs = const []});

  static CityOption? from(Object? v) {
    final m = _m(v);
    if (m.isEmpty) return null;
    final legs = [for (final l in (m['legs'] is List ? m['legs'] as List : const [])) CityLeg.parse(l)];
    return CityOption(
        minutes: _i(m['minutes']),
        fare: CityFare.from(m['fare']) ?? const CityFare(low: 0, high: 0),
        changes: _i(m['changes']),
        walkM: _i(m['walk_m']),
        modes: _sl(m['modes']),
        status: _s(m['status']),
        legs: legs);
  }

  /// The last vehicle leg (where the get-off alarm rings).
  CityLeg? get lastRide {
    for (final l in legs.reversed) {
      if (l.isVehicle) return l;
    }
    return null;
  }
}

/// A direct way (CNG, ride share, rickshaw, walk) with its own fare.
class CityOtherWay {
  final String mode;
  final int minutes;
  final double km;
  final CityFare? fare;
  const CityOtherWay(this.mode, this.minutes, this.km, this.fare);
  static CityOtherWay from(Object? v) {
    final m = _m(v);
    return CityOtherWay(_s(m['mode']), _i(m['minutes']), _d(m['km']) ?? 0, CityFare.from(m['fare']));
  }
}

/// BRTA complaint line: `number` when confirmed, else the national `fallback`.
class CityComplaint {
  final String number, fallback;
  final bool verified;
  final String checked, sourceUrl;
  const CityComplaint(
      {this.number = '', this.fallback = '333', this.verified = false, this.checked = '', this.sourceUrl = ''});
  static CityComplaint from(Object? v) {
    final m = _m(v);
    return CityComplaint(
        number: _s(m['number']),
        fallback: _s(m['fallback']).isEmpty ? '333' : _s(m['fallback']),
        verified: m['verified'] == true,
        checked: _s(m['checked']),
        sourceUrl: _s(m['source_url']));
  }

  String get dial => number.isNotEmpty ? number : fallback;
  bool get usesFallback => number.isEmpty;
}

/// GET city/plan.
class CityPlan {
  final bool ok;
  final String reason; // '' | no_data | no_route | offline
  final String city;
  final Map<CityPick, CityOption> options;
  final List<CityOtherWay> otherWays;
  final List<String> warnings;
  final CityComplaint complaint;
  final String attribution, googleMaps, dataVersion;
  final bool offline;
  const CityPlan(
      {required this.ok,
      this.reason = '',
      this.city = '',
      this.options = const {},
      this.otherWays = const [],
      this.warnings = const [],
      this.complaint = const CityComplaint(),
      this.attribution = '',
      this.googleMaps = '',
      this.dataVersion = '',
      this.offline = false});

  static CityPlan from(Map<String, dynamic> m, {bool offline = false}) {
    final opts = _m(m['options']);
    return CityPlan(
        ok: m['ok'] == true,
        reason: _s(m['reason']),
        city: _s(m['city']),
        options: {
          for (final e in kCityPickKeys.entries)
            if (CityOption.from(opts[e.value]) case final o?) e.key: o
        },
        otherWays: [
          for (final w in (m['other_ways'] is List ? m['other_ways'] as List : const []))
            CityOtherWay.from(w)
        ],
        warnings: _sl(m['warnings']),
        complaint: CityComplaint.from(m['complaint']),
        attribution: _s(m['attribution']),
        googleMaps: _s(m['google_maps']),
        dataVersion: _s(m['data_version']),
        offline: offline);
  }
}

/// GET city/where.
class CityWhere {
  final String city, name, nameBn, googleMaps;
  final bool hasData;
  final int routes, stops, stations;
  final double? coveragePct;
  const CityWhere(
      {this.city = '',
      this.name = '',
      this.nameBn = '',
      this.googleMaps = '',
      this.hasData = false,
      this.routes = 0,
      this.stops = 0,
      this.stations = 0,
      this.coveragePct});
  static CityWhere from(Map<String, dynamic> m) {
    final c = _m(m['counts']);
    return CityWhere(
        city: _s(m['city']),
        name: _s(m['name']),
        nameBn: _s(m['name_bn']),
        googleMaps: _s(m['google_maps']),
        hasData: m['has_data'] == true,
        routes: _i(c['routes']),
        stops: _i(c['stops']),
        stations: _i(c['stations']),
        coveragePct: _d(m['coverage_pct']));
  }

  String label(bool bn) => bn && nameBn.isNotEmpty ? nameBn : name;
}

/// Directory item (terminal / ghat / office).
class CityDirItem {
  final String id, kind, name, nameBn, address, hours, status, checked;
  final double? lat, lon;
  final List<String> papersEn, papersBn, routes, routesBn;
  final List<({String url, String date})> sources;
  const CityDirItem(
      {required this.id,
      required this.kind,
      required this.name,
      this.nameBn = '',
      this.address = '',
      this.hours = '',
      this.status = '',
      this.checked = '',
      this.lat,
      this.lon,
      this.papersEn = const [],
      this.papersBn = const [],
      this.routes = const [],
      this.routesBn = const [],
      this.sources = const []});

  static CityDirItem from(Object? v) {
    final m = _m(v);
    final srcs = [
      for (final s in (m['sources'] is List ? m['sources'] as List : const []))
        if (s is Map) (url: _s(s['url']), date: _s(s['date']))
    ];
    var checked = _s(m['checked']);
    if (checked.isEmpty && srcs.isNotEmpty) checked = srcs.first.date;
    final papers = _sl(m['papers']);
    return CityDirItem(
        id: _s(m['id']),
        kind: _s(m['kind']),
        name: _s(m['name']),
        nameBn: _s(m['name_bn']),
        address: _s(m['address']),
        hours: _s(m['hours']),
        status: _s(m['status']),
        checked: checked,
        lat: _d(m['lat']),
        lon: _d(m['lon']),
        papersEn: m['papers_en'] != null ? _sl(m['papers_en']) : papers,
        papersBn: _sl(m['papers_bn']),
        routes: _sl(m['routes']),
        routesBn: _sl(m['routes_bn']),
        sources: srcs);
  }

  String label(bool bn) => bn && nameBn.isNotEmpty ? nameBn : name;
  /// District / ghat names: Bangla when the server has them (routes_bn).
  List<String> routesFor(bool bn) => bn && routesBn.length == routes.length && routesBn.isNotEmpty ? routesBn : routes;
  List<String> papers(bool bn) => bn && papersBn.isNotEmpty ? papersBn : papersEn;
}

/// Live report kinds (contract §6), in the owner's order.
const kLiveKinds = ['jam', 'road_closed', 'waterlogging', 'bus_not_coming', 'bus_crowded', 'seats_free'];

class CityReport {
  final int id, count, minutesAgo;
  final String kind, routeId;
  final double? lat, lon;
  const CityReport(this.id, this.kind, this.count, this.minutesAgo, this.routeId, this.lat, this.lon);
  static CityReport from(Object? v) {
    final m = _m(v);
    return CityReport(_i(m['id']), _s(m['kind']), _i(m['count']).clamp(1, 1 << 30),
        _i(m['minutes_ago']), _s(m['route_id']), _d(m['lat']), _d(m['lon']));
  }
}

/// A metro station row (GET city/stations).
class CityStation {
  final String id, code, name, nameBn;
  final double? lat, lon;
  final int gates;

  /// gap-nearby: km along the metro line from its first station (null =
  /// unknown; the station-to-station fare then needs the official chart).
  final double? km;
  const CityStation(this.id, this.code, this.name, this.nameBn, this.lat, this.lon, this.gates,
      [this.km]);
  static CityStation from(Object? v) {
    final m = _m(v);
    return CityStation(_s(m['id']), _s(m['code']), _s(m['name']), _s(m['name_bn']), _d(m['lat']),
        _d(m['lon']), _i(m['gates']), _d(m['km']));
  }

  String label(bool bn) => bn && nameBn.isNotEmpty ? nameBn : name;
}

/// Metro service hours (dhaka_metro.json `service`).
class MetroService {
  final String hoursSatThu, hoursFri, status, note;
  final int headwayPeak, headwayOffpeak, headwayFri, endToEnd;
  final String checked;
  const MetroService(
      {this.hoursSatThu = '',
      this.hoursFri = '',
      this.status = '',
      this.note = '',
      this.headwayPeak = 0,
      this.headwayOffpeak = 0,
      this.headwayFri = 0,
      this.endToEnd = 0,
      this.checked = ''});
  static MetroService from(Object? v) {
    final m = _m(v);
    final srcs = m['sources'] is List ? m['sources'] as List : const [];
    return MetroService(
        hoursSatThu: _s(m['hours_sat_thu']),
        hoursFri: _s(m['hours_fri']),
        status: _s(m['status']),
        note: _s(m['note']),
        headwayPeak: _i(m['headway_peak_min']),
        headwayOffpeak: _i(m['headway_offpeak_min']),
        headwayFri: _i(m['headway_fri_min']),
        endToEnd: _i(m['end_to_end_min']),
        checked: srcs.isNotEmpty && srcs.first is Map ? _s((srcs.first as Map)['date']) : '');
  }

  /// "07:10-21:40" -> (first, last).
  static (String, String) split(String hours) {
    final p = hours.split('-');
    return p.length == 2 ? (p[0].trim(), p[1].trim()) : (hours, '');
  }
}

/// Women options (GET city/women — requested from citydata; may be absent).
class CityWomen {
  final List<Map<String, dynamic>> buses;
  final Map<String, dynamic> reservedSeats, metroCoach;
  final List<Map<String, dynamic>> night;
  final bool available;
  const CityWomen(
      {this.buses = const [],
      this.reservedSeats = const {},
      this.metroCoach = const {},
      this.night = const [],
      this.available = false});
  static CityWomen from(Map<String, dynamic> m) => CityWomen(
      buses: [
        for (final e in (m['women_buses'] is List ? m['women_buses'] as List : const []))
          if (e is Map) _m(e)
      ],
      reservedSeats: _m(m['reserved_seats']),
      metroCoach: _m(m['metro_women_coach']),
      night: [
        for (final e in (m['night'] is List ? m['night'] as List : const []))
          if (e is Map) _m(e)
      ],
      available: true);
}

// citycov: field collection ("Add a stop here" / "This bus stops here").
/// A waiting users' stop report near the phone (GET city/field-stops items).
class CityFieldStop {
  final int id, people, need, meters;
  final double? lat, lon;
  final String routeId, route, routeBn;
  final bool confirmed, mine;
  const CityFieldStop(this.id, this.lat, this.lon, this.routeId, this.route, this.routeBn, this.people, this.need,
      this.meters, this.confirmed, this.mine);
  static CityFieldStop from(Object? v, int need) {
    final m = _m(v);
    return CityFieldStop(_i(m['id']), _d(m['lat']), _d(m['lon']), _s(m['route_id']), _s(m['route']),
        _s(m['route_bn']), _i(m['people']), _i(m['need']) > 0 ? _i(m['need']) : need, _i(m['meters']),
        m['confirmed'] == true, m['mine'] == true);
  }

  String routeLabel(bool bn) => bn && routeBn.isNotEmpty ? routeBn : route;
}

/// A bus / leguna that passes near the phone (GET city/field-stops routes).
class CityNearRoute {
  final String id, mode, name, nameBn, status, fromName, fromBn, toName, toBn;
  const CityNearRoute(this.id, this.mode, this.name, this.nameBn, this.status, this.fromName, this.fromBn,
      this.toName, this.toBn);
  static CityNearRoute from(Object? v) {
    final m = _m(v);
    return CityNearRoute(_s(m['id']), _s(m['mode']), _s(m['name']), _s(m['name_bn']), _s(m['status']),
        _s(m['from']), _s(m['from_bn']), _s(m['to']), _s(m['to_bn']));
  }

  String label(bool bn) => bn && nameBn.isNotEmpty ? nameBn : name;
  String ends(bool bn) {
    final a = bn && fromBn.isNotEmpty ? fromBn : fromName, z = bn && toBn.isNotEmpty ? toBn : toName;
    return a.isEmpty || z.isEmpty ? '' : '$a → $z';
  }
}
