// cityapp: City Service fakes in the API contract's shapes
// (owner_actions/CITY_SERVICE_API.md). Made-up sample trips over public
// station names — no real user data. Used by the gallery (fake_api.dart) and
// the City Service tests.

const _checked = '2026-11-09';

Map<String, dynamic> _fare(int lo, int hi, String label, {String source = '', int? card, bool cng = false}) => {
      'low': lo,
      'high': hi,
      'label': label,
      'basis': cng ? 'meter' : (label == 'estimate' ? 'estimate' : 'rate'),
      'checked': _checked,
      'source': source,
      'source_url': label == 'official' ? 'https://brta.gov.bd/' : '',
      if (card != null) 'card': card,
      if (cng) 'meter': lo,
      if (cng) 'overcharge_note': true,
    };

Map<String, dynamic> _pt(String id, String en, String bn, double lat, double lon, [String st = 'verified']) =>
    {'id': id, 'name': en, 'name_bn': bn, 'lat': lat, 'lon': lon, 'status': st};

final _m10 = _pt('st_m10', 'Mirpur 10', 'মিরপুর ১০', 23.8070, 90.3683);
final _far = _pt('st_far', 'Farmgate', 'ফার্মগেট', 23.7575, 90.3897);
final _mot = _pt('st_mot', 'Motijheel', 'মতিঝিল', 23.7283, 90.4196);
final _utn = _pt('st_utn', 'Uttara North', 'উত্তরা উত্তর', 23.8690, 90.3672);
final _busM10 = _pt('b_m10', 'Mirpur 10 Golchattar', 'মিরপুর ১০ গোলচত্বর', 23.8068, 90.3688);
final _busShapla = _pt('b_shapla', 'Shapla Chattar', 'শাপলা চত্বর', 23.7290, 90.4210, 'reported');

Map<String, dynamic> _gateA() => {
      'ref': 'A',
      'name': 'Gate A',
      'name_bn': 'গেট A',
      'side': 'E',
      'lat': 23.7285,
      'lon': 90.4203,
      'near': [
        ['Shapla Chattar', 'শাপলা চত্বর', 'square', 90],
        ['Bangladesh Bank', 'বাংলাদেশ ব্যাংক', 'bank', 160],
      ],
      'status': 'reported',
    };

Map<String, dynamic> _walk(int m, int min, Map<String, dynamic> from, Map<String, dynamic> to) =>
    {'mode': 'walk', 'meters': m, 'minutes': min, 'from': from, 'to': to, 'fare': null};

final _here = {'name': '', 'lat': 23.8075, 'lon': 90.3670, 'here': true};
final _dest = {'name': '', 'lat': 23.7270, 'lon': 90.4180, 'dest': true};

Map<String, dynamic> _metroLeg() => {
      'mode': 'metro',
      'route': 'MRT Line 6',
      'route_bn': 'এমআরটি লাইন ৬',
      'ref': 'MRT-6',
      'route_id': 'mrt6_s',
      'status': 'verified',
      'source': 'dmtcl/wikipedia',
      'board': _m10,
      'alight': _mot,
      'towards': _mot,
      'stops': 11,
      'via': ['Kazipara', 'Shewrapara', 'Agargaon', 'Farmgate', 'Shahbag'],
      'via_bn': ['কাজীপাড়া', 'শেওড়াপাড়া', 'আগারগাঁও', 'ফার্মগেট', 'শাহবাগ'],
      'wait_min': 4,
      'minutes': 27,
      'km': 15.6,
      'fare': _fare(80, 80, 'official', source: 'DTCA metro fare chart (Tk 5/km, min Tk 20, max Tk 100)', card: 72),
      'headway_min': 8,
      'exit_gate': _gateA(),
      'women_only': false,
    };

Map<String, dynamic> _busLeg() => {
      'mode': 'bus',
      'route': 'Shikor Paribahan',
      'route_bn': 'শিকড় পরিবহন',
      'ref': '',
      'route_id': 'bus_shikor_1',
      'status': 'reported',
      'source': 'dhakabusservice.com',
      'board': _busM10,
      'alight': _busShapla,
      'towards': _pt('b_jatra', 'Jatrabari', 'যাত্রাবাড়ী', 23.7104, 90.4348, 'reported'),
      'stops': 14,
      'via': ['Kazipara', 'Farmgate', 'Shahbag', 'Paltan'],
      'via_bn': ['কাজীপাড়া', 'ফার্মগেট', 'শাহবাগ', 'পল্টন'],
      'wait_min': 5,
      'minutes': 62,
      'km': 13.9,
      'fare': _fare(35, 38, 'official', source: 'BRTA city bus fare chart (Dhaka & Chattogram metro area)'),
      'headway_min': 10,
      'women_only': false,
    };

Map<String, dynamic> fakeCityPlan() {
  final metro = {
    'minutes': 41,
    'fare': {'low': 80, 'high': 80, 'label': 'official'},
    'changes': 0,
    'walk_m': 650,
    'modes': ['walk', 'metro', 'walk'],
    'status': 'verified',
    'legs': [_walk(250, 4, _here, _m10), _metroLeg(), _walk(400, 6, _mot, _dest)],
  };
  final bus = {
    'minutes': 78,
    'fare': {'low': 35, 'high': 38, 'label': 'official'},
    'changes': 0,
    'walk_m': 380,
    'modes': ['walk', 'bus', 'walk'],
    'status': 'reported',
    'legs': [_walk(150, 2, _here, _busM10), _busLeg(), _walk(230, 3, _busShapla, _dest)],
  };
  return {
    'ok': true,
    'city': 'dhaka',
    'options': {'cheapest': bus, 'fastest': metro, 'fewest_changes': metro, 'safer_night': metro},
    'other_ways': [
      {'mode': 'cng', 'minutes': 55, 'km': 13.2, 'fare': _fare(174, 266, 'official', source: 'BRTA CNG auto-rickshaw meter rate (Dhaka)', cng: true)},
      {'mode': 'ride_bike', 'minutes': 44, 'km': 13.2, 'fare': _fare(230, 360, 'estimate', source: 'Assisto estimate of app bike fares (no ride-share API is called)')},
      {'mode': 'ride_car', 'minutes': 60, 'km': 13.2, 'fare': _fare(570, 860, 'estimate', source: 'Assisto estimate of app car fares (no ride-share API is called)')},
    ],
    'warnings': <String>[],
    'crow_km': 9.8,
    'ms': 41,
    'complaint': {'number': '', 'fallback': '333', 'verified': false, 'checked': _checked, 'source_url': 'https://brta.gov.bd/'},
    'attribution': '© OpenStreetMap contributors (ODbL)',
    'data_version': 'dhaka-v1',
    'google_maps': 'https://www.google.com/maps/dir/?api=1&travelmode=transit',
  };
}

Map<String, dynamic> fakeCityWhere({bool noData = false}) => noData
    ? {'city': null, 'has_data': false, 'name': '', 'name_bn': '', 'counts': {}, 'coverage_pct': null,
        'google_maps': 'https://www.google.com/maps/dir/?api=1&travelmode=transit'}
    : {
        'city': 'dhaka',
        'has_data': true,
        'name': 'Dhaka',
        'name_bn': 'ঢাকা',
        'counts': {'routes': 312, 'stops': 2140, 'stations': 16},
        'coverage_pct': 78.0,
        'google_maps': 'https://www.google.com/maps/dir/?api=1&travelmode=transit',
        'data_version': 'dhaka-v1',
      };

Map<String, dynamic> fakeCityMetro() => {
      'line': {
        'id': 'mrt6',
        'name': 'MRT Line 6',
        'name_bn': 'এমআরটি লাইন ৬',
        'operator': 'Dhaka Mass Transit Company Limited (DMTCL)',
      },
      'service': {
        'status': 'reported',
        'hours_sat_thu': '07:10-21:40',
        'hours_fri': '15:00-21:40',
        'headway_peak_min': 10,
        'headway_offpeak_min': 8,
        'headway_fri_min': 12,
        'end_to_end_min': 40,
        'sources': [{'url': 'https://en.wikipedia.org/wiki/MRT_Line_6_(Dhaka_Metro_Rail)', 'date': _checked}],
      },
      'recharge': {
        'status': 'reported',
        'text_en': 'MRT Pass / Rapid Pass: buy and top up at the ticket office or the vending machines inside every station (cash).',
        'text_bn': 'এমআরটি পাস / র‍্যাপিড পাস: প্রতিটি স্টেশনের টিকিট অফিস বা ভেন্ডিং মেশিনে কেনা ও রিচার্জ করা যায় (নগদ)।',
      },
      'stations': [
        // gap-nearby: km along the line (station-to-station fare)
        {..._utn, 'code': 'UTN', 'gates': 2, 'km': 0.0},
        {..._m10, 'code': 'M10', 'gates': 4, 'km': 6.6},
        {..._far, 'code': 'FAR', 'gates': 3, 'km': 11.4},
        {..._mot, 'code': 'MOT', 'gates': 2, 'km': 20.1},
      ],
      'fare': {
        'per_km': 5.0, 'min': 20, 'max': 100, 'card_discount_pct': 10, 'label': 'official', 'checked': _checked,
        'source': 'DTCA metro fare chart (Tk 5/km, min Tk 20, max Tk 100)', 'source_url': 'https://dmtc.org.bd/',
        // gap-nearby: official pairs (backend fares.py METRO_CHART)
        'chart': [
          {'a': 'MOT', 'b': 'UTN', 'tk': 100},
          {'a': 'FAR', 'b': 'UTN', 'tk': 70},
          {'a': 'FAR', 'b': 'MOT', 'tk': 40},
        ],
      },
    };

Map<String, dynamic> fakeCityStation() => {
      'station': {..._mot, 'code': 'MOT'},
      'gates': [
        {..._gateA(), 'stands': [_busShapla], 'buses': ['Shikor Paribahan', 'Raida'], 'lift': true},
        {
          'ref': 'B', 'name': 'Gate B', 'name_bn': 'গেট B', 'side': 'W', 'lat': 23.7281, 'lon': 90.4189,
          'near': [['Dilkusha', 'দিলকুশা', 'area', 120]], 'stands': [], 'buses': [], 'lift': null, 'status': 'reported',
        },
      ],
      'which_gate': _gateA(),
      'connecting_buses': ['Raida', 'Shikor Paribahan', 'Torongo Plus'],
      'service': fakeCityMetro()['service'],
      'line': fakeCityMetro()['line'],
    };

List<Map<String, dynamic>> fakeCityDir(String kind) => switch (kind) {
      'terminals' => [
          {'id': 't-gabtoli', 'kind': 'terminal', 'name': 'Gabtoli Bus Terminal', 'name_bn': 'গাবতলী বাস টার্মিনাল',
           'lat': 23.7837, 'lon': 90.3446, 'address': 'Gabtoli, Mirpur Road, Dhaka',
           'routes': ['Rajshahi', 'Rangpur', 'Khulna'], 'routes_bn': ['রাজশাহী', 'রংপুর', 'খুলনা'], 'hours': '', 'status': 'reported', 'checked': _checked,
           'sources': [{'url': 'https://example.org/source', 'date': _checked}]},
          {'id': 't-sayedabad', 'kind': 'terminal', 'name': 'Sayedabad Bus Terminal', 'name_bn': 'সায়েদাবাদ বাস টার্মিনাল',
           'lat': 23.7205, 'lon': 90.4275, 'address': 'Sayedabad, Jatrabari, Dhaka',
           'routes': ['Chattogram', 'Sylhet', 'Cumilla'], 'routes_bn': ['চট্টগ্রাম', 'সিলেট', 'কুমিল্লা'], 'hours': '', 'status': 'verified', 'checked': _checked,
           'sources': [{'url': 'https://example.org/source', 'date': _checked}]},
        ],
      'ghats' => [
          {'id': 'g-sadarghat', 'kind': 'ghat', 'name': 'Sadarghat Launch Terminal', 'name_bn': 'সদরঘাট লঞ্চ টার্মিনাল',
           'lat': 23.7058, 'lon': 90.4077, 'address': 'Sadarghat, Buriganga river, Dhaka (BIWTA)',
           'routes': ['Barishal', 'Bhola', 'Chandpur'], 'routes_bn': ['বরিশাল', 'ভোলা', 'চাঁদপুর'], 'hours': '', 'status': 'reported', 'checked': _checked,
           'sources': [{'url': 'https://example.org/source', 'date': _checked}]},
        ],
      _ => [
          {'id': 'o-passport', 'kind': 'office', 'name': 'Department of Immigration and Passports (Head Office)',
           'name_bn': 'ইমিগ্রেশন ও পাসপোর্ট অধিদপ্তর (প্রধান কার্যালয়)', 'lat': 23.7787, 'lon': 90.3780,
           'address': 'Agargaon, Dhaka', 'hours': 'Sun-Thu 09:00-17:00',
           'papers_en': ['Online application summary', 'Fee payment slip', 'NID card'],
           'papers_bn': ['অনলাইন আবেদনের সারাংশ', 'ফি জমার রসিদ', 'জাতীয় পরিচয়পত্র'],
           'status': 'reported', 'checked': _checked,
           'sources': [{'url': 'https://example.org/source', 'date': _checked}]},
        ],
    };

Map<String, dynamic> fakeCityWomen() => {
      'women_buses': <Map<String, dynamic>>[],
      'reserved_seats': {
        'text': 'City buses keep seats for women, children and people with disabilities near the front.',
        'text_bn': 'সিটি বাসে সামনের দিকে নারী, শিশু ও প্রতিবন্ধী মানুষের জন্য আসন সংরক্ষিত থাকে।',
        'status': 'reported', 'checked': _checked, 'source_url': '',
      },
      'metro_women_coach': {
        'text': 'Every metro train keeps one coach for women only.',
        'text_bn': 'প্রতিটি মেট্রো ট্রেনে একটি কোচ শুধু নারীদের জন্য।',
        'status': 'verified', 'checked': _checked, 'source_url': 'https://example.org/source',
      },
      'night': [
        {'route_id': 'bus_shikor_1', 'route': 'Shikor Paribahan', 'stars': 3.4, 'count': 12},
      ],
    };

Map<String, dynamic> fakeCityReports({bool empty = false}) => {
      'reports': empty
          ? <Map<String, dynamic>>[]
          : [
              {'id': 11, 'kind': 'jam', 'lat': 23.7580, 'lon': 90.3890, 'count': 7, 'minutes_ago': 6, 'route_id': ''},
              {'id': 12, 'kind': 'bus_crowded', 'lat': 23.8068, 'lon': 90.3688, 'count': 3, 'minutes_ago': 14,
               'route_id': 'bus_shikor_1'},
              {'id': 13, 'kind': 'waterlogging', 'lat': 23.7330, 'lon': 90.4170, 'count': 2, 'minutes_ago': 31, 'route_id': ''},
            ],
      'ttl_min': 60,
    };

Map<String, dynamic> fakeCitySearch(String q) => {
      'stops': q.toLowerCase().contains('motijheel') || q.contains('মতিঝিল')
          ? [{..._mot, 'kind': 'metro', 'routes': ['MRT Line 6']}]
          : (q.toLowerCase().contains('mirpur') || q.contains('মিরপুর')
              ? [{..._m10, 'kind': 'metro', 'routes': ['MRT Line 6']}]
              : <Map<String, dynamic>>[]),
      'routes': q.toLowerCase().contains('shikor')
          ? [{'id': 'bus_shikor_1', 'mode': 'bus', 'name': 'Shikor Paribahan', 'name_bn': 'শিকড় পরিবহন', 'ref': '',
              'from': 'Mirpur 1', 'to': 'Jatrabari', 'status': 'reported'}]
          : <Map<String, dynamic>>[],
    };

/// A tiny offline package in the server's network format: MRT stations
/// Mirpur 10 -> Farmgate -> Motijheel, one bus from a stop near Mirpur 1 to
/// Farmgate, and gate A at Motijheel.
Map<String, dynamic> fakeCityPackage() => {
      'v': 'dhaka-v1',
      'city': 'dhaka',
      'net': {
        'stops': {
          'cols': ['id', 'name', 'name_bn', 'lat', 'lon', 'kind', 'st', 'code'],
          'rows': [
            ['st_m10', 'Mirpur 10', 'মিরপুর ১০', 23.8070, 90.3683, 'metro', 'v', 'M10'],
            ['st_far', 'Farmgate', 'ফার্মগেট', 23.7575, 90.3897, 'metro', 'v', 'FAR'],
            ['st_mot', 'Motijheel', 'মতিঝিল', 23.7283, 90.4196, 'metro', 'v', 'MOT'],
            ['b_m1', 'Mirpur 1', 'মিরপুর ১', 23.7956, 90.3537, 'bus', 'r', ''],
            ['b_far', 'Farmgate bus stop', 'ফার্মগেট বাসস্ট্যান্ড', 23.7580, 90.3900, 'bus', 'r', ''],
          ],
        },
        'routes': [
          {'id': 'mrt6_s', 'mode': 'metro', 'name': 'MRT Line 6', 'name_bn': 'এমআরটি লাইন ৬', 'ref': 'MRT-6',
           'st': 'v', 'stops': [0, 1, 2], 'km': [0.0, 6.6, 15.6], 'hw': 8, 'spd': 38.0},
          {'id': 'bus_x', 'mode': 'bus', 'name': 'Sample Bus', 'name_bn': 'নমুনা বাস', 'ref': '',
           'st': 'r', 'stops': [3, 4], 'km': [0.0, 5.4]},
        ],
        'gates': [
          {'st': 2, 'ref': 'A', 'name': 'Gate A', 'name_bn': 'গেট A', 'side': 'E', 'lat': 23.7285, 'lon': 90.4203,
           'near': [['Shapla Chattar', 'শাপলা চত্বর', 'square', 90]], 'stands': [], 'routes': [1], 'status': 'reported'},
          {'st': 2, 'ref': 'B', 'name': 'Gate B', 'name_bn': 'গেট B', 'side': 'W', 'lat': 23.7281, 'lon': 90.4170,
           'near': [], 'stands': [], 'routes': [], 'status': 'reported'},
        ],
        'metro': {'line': fakeCityMetro()['line'], 'service': fakeCityMetro()['service'], 'recharge': fakeCityMetro()['recharge']},
      },
      'overrides': {},
      'rates': {
        'metro': {'label': 'official', 'per_km': 5.0, 'min': 20, 'max': 100, 'round_to': 10, 'card_discount_pct': 10,
                  'checked': _checked, 'source': 'DTCA metro fare chart', 'source_url': 'https://dmtc.org.bd/'},
        'bus': {'label': 'official', 'per_km_low': 2.53, 'per_km_high': 2.70, 'min': 10, 'checked': _checked,
                'source': 'BRTA city bus fare chart', 'source_url': 'https://brta.gov.bd/'},
        'cng': {'label': 'official', 'first_km': 2.0, 'first_tk': 40, 'per_km': 12, 'wait_per_min': 2, 'checked': _checked,
                'source': 'BRTA CNG meter rate', 'source_url': 'https://brta.gov.bd/'},
        'rickshaw': {'label': 'estimate', 'min_low': 30, 'min_high': 40, 'per_km_low': 25, 'per_km_high': 40, 'checked': _checked},
        'leguna': {'label': 'estimate', 'min_low': 10, 'min_high': 15, 'per_km_low': 2.5, 'per_km_high': 4.0, 'checked': _checked},
        'water': {'label': 'estimate', 'min_low': 20, 'min_high': 30, 'per_km_low': 2.0, 'per_km_high': 4.0, 'checked': _checked},
        'ride_bike': {'label': 'estimate', 'base_low': 30, 'base_high': 50, 'per_km_low': 14, 'per_km_high': 22, 'per_min': 1.0, 'checked': _checked},
        'ride_car': {'label': 'estimate', 'base_low': 80, 'base_high': 120, 'per_km_low': 30, 'per_km_high': 45, 'per_min': 3.0, 'checked': _checked},
      },
      'complaint': {'number': '', 'fallback': '333', 'verified': false},
      'attribution': '© OpenStreetMap contributors (ODbL)',
    };

/// GET handler for the gallery / tests. null = not a City Service path.
Map<String, dynamic>? fakeCityGet(String path, {bool empty = false}) {
  if (!path.startsWith('/city/')) return null;
  final p = path.split('?').first;
  final q = Uri.tryParse('https://x$path')?.queryParameters ?? const {};
  if (p == '/city/where') return fakeCityWhere(noData: empty);
  if (p == '/city/plan') {
    return empty
        ? {'ok': false, 'reason': 'no_data', 'google_maps': 'https://www.google.com/maps/dir/?api=1&travelmode=transit'}
        : fakeCityPlan();
  }
  if (p == '/city/package') return fakeCityPackage();
  if (p == '/city/metro') return fakeCityMetro();
  if (p == '/city/stations') return {'city': 'dhaka', 'stations': fakeCityMetro()['stations']};
  if (p.startsWith('/city/station/')) return fakeCityStation();
  if (p == '/city/search') return fakeCitySearch(q['q'] ?? '');
  if (p.startsWith('/city/route/')) {
    return {'id': 'bus_shikor_1', 'mode': 'bus', 'name': 'Shikor Paribahan', 'name_bn': 'শিকড় পরিবহন', 'ref': '',
        'operator': 'Shikor Paribahan', 'status': 'reported', 'stops': [_busM10, _far, _busShapla]};
  }
  for (final k in ['terminals', 'ghats', 'offices']) {
    if (p == '/city/$k') return {'city': 'dhaka', 'items': empty ? const [] : fakeCityDir(k)};
  }
  if (p == '/city/women') return fakeCityWomen();
  if (p == '/city/reports') return fakeCityReports(empty: empty);
  if (p == '/city/trips/consent') return {'on': false, 'keep_days': 7, 'trim_m': 300};
  if (p == '/city/field-stops') return fakeCityField(empty: empty); // citycov
  return {'ok': true};
}

// citycov: "Map a stop" (field collection). Made-up sample reports.
Map<String, dynamic> fakeCityField({bool empty = false}) => {
      'need': 3,
      'items': empty
          ? <Map<String, dynamic>>[]
          : [
              {'id': 41, 'lat': 23.8081, 'lon': 90.3664, 'route_id': 'bus_shikor_1-a', 'route': 'Shikor Paribahan',
               'route_bn': 'শিকড় পরিবহন', 'people': 2, 'need': 3, 'confirmed': false, 'mine': false, 'meters': 90},
              {'id': 42, 'lat': 23.8090, 'lon': 90.3650, 'route_id': '', 'route': '', 'route_bn': '', 'people': 1,
               'need': 3, 'confirmed': false, 'mine': true, 'meters': 260},
            ],
      'routes': empty
          ? <Map<String, dynamic>>[]
          : [
              {'id': 'bus_shikor_1-a', 'mode': 'bus', 'name': 'Shikor Paribahan', 'name_bn': 'শিকড় পরিবহন',
               'status': 'verified', 'from': 'Mirpur 10', 'from_bn': 'মিরপুর ১০', 'to': 'Motijheel', 'to_bn': 'মতিঝিল'},
              {'id': 'leg-mirpur-a', 'mode': 'leguna', 'name': 'Leguna: Mirpur 10 - Kalshi', 'name_bn': 'লেগুনা: মিরপুর ১০ - কালশী',
               'status': 'reported', 'from': 'Mirpur 10', 'from_bn': 'মিরপুর ১০', 'to': 'Kalshi', 'to_bn': 'কালশী'},
            ],
    };

/// POST handler: every City Service write succeeds like the server.
Map<String, dynamic>? fakeCityPost(String path, [Map<String, dynamic> body = const {}]) {
  if (!path.startsWith('/city/')) return null;
  if (path == '/city/trips/consent') return {'on': body['on'] == true, 'keep_days': 7, 'trim_m': 300};
  if (path == '/city/reports') return {'ok': true, 'id': 99, 'count': 1};
  if (path == '/city/field-stops') {
    // citycov: a 3rd "yes" confirms report 41; anything else waits
    return body['id'] == 41
        ? {'ok': true, 'id': 41, 'status': 'confirmed', 'people': 3, 'need': 3}
        : {'ok': true, 'id': 43, 'status': 'reported', 'people': 1, 'need': 3};
  }
  return {'ok': true, 'id': 1};
}
