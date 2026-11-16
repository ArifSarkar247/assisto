// mapapp: City map fakes — MRT Line 6 stations (public names, approximate
// public coordinates) + made-up SAMPLE bus routes and a sample Google transit
// answer in /maps/transit's shape. No real user data.

Map<String, dynamic> _s(String id, String en, String bn, double lat, double lon) =>
    {'id': id, 'name': en, 'name_bn': bn, 'lat': lat, 'lon': lon, 'status': 'verified'};

final _mrt = [
  _s('m_utn', 'Uttara North', 'উত্তরা উত্তর', 23.8690, 90.3672),
  _s('m_utc', 'Uttara Center', 'উত্তরা সেন্টার', 23.8597, 90.3653),
  _s('m_uts', 'Uttara South', 'উত্তরা দক্ষিণ', 23.8456, 90.3632),
  _s('m_pal', 'Pallabi', 'পল্লবী', 23.8263, 90.3644),
  _s('m_m11', 'Mirpur 11', 'মিরপুর ১১', 23.8188, 90.3654),
  _s('m_m10', 'Mirpur 10', 'মিরপুর ১০', 23.8070, 90.3683),
  _s('m_kaz', 'Kazipara', 'কাজীপাড়া', 23.7976, 90.3730),
  _s('m_she', 'Shewrapara', 'শেওড়াপাড়া', 23.7905, 90.3757),
  _s('m_aga', 'Agargaon', 'আগারগাঁও', 23.7780, 90.3800),
  _s('m_bij', 'Bijoy Sarani', 'বিজয় সরণি', 23.7663, 90.3833),
  _s('m_far', 'Farmgate', 'ফার্মগেট', 23.7575, 90.3897),
  _s('m_kar', 'Karwan Bazar', 'কারওয়ান বাজার', 23.7510, 90.3925),
  _s('m_sha', 'Shahbag', 'শাহবাগ', 23.7385, 90.3958),
  _s('m_du', 'Dhaka University', 'ঢাকা বিশ্ববিদ্যালয়', 23.7330, 90.3990),
  _s('m_sec', 'Bangladesh Secretariat', 'বাংলাদেশ সচিবালয়', 23.7302, 90.4080),
  _s('m_mot', 'Motijheel', 'মতিঝিল', 23.7283, 90.4196),
];

Map<String, dynamic> _route(String id, String mode, String en, String bn, List<Map<String, dynamic>> stops,
        {int lo = 0, int hi = 0, String status = 'reported'}) =>
    {
      'id': id,
      'mode': mode,
      'name': en,
      'name_bn': bn,
      'status': status,
      'coords': [
        for (final s in stops) [s['lon'], s['lat']]
      ],
      'stops': stops,
      'fare': {'low': lo, 'high': hi, 'label': mode == 'metro' ? 'official' : 'official'},
    };

final _airport = _s('b_air', 'Airport', 'বিমানবন্দর', 23.8513, 90.4086);
final _khil = _s('b_khi', 'Khilkhet', 'খিলক্ষেত', 23.8295, 90.4207);
final _kuril = _s('b_kur', 'Kuril', 'কুড়িল', 23.8205, 90.4214);
final _badda = _s('b_bad', 'Badda', 'বাড্ডা', 23.7806, 90.4265);
final _ramp = _s('b_ram', 'Rampura', 'রামপুরা', 23.7614, 90.4200);
final _mali = _s('b_mal', 'Malibagh', 'মালিবাগ', 23.7486, 90.4127);
final _motB = _s('b_mot', 'Motijheel Shapla Chattar', 'মতিঝিল শাপলা চত্বর', 23.7290, 90.4210);
final _gul1 = _s('b_gu1', 'Gulshan 1', 'গুলশান ১', 23.7808, 90.4167);
final _moha = _s('b_moh', 'Mohakhali', 'মহাখালী', 23.7781, 90.4053);
final _bana = _s('b_ban', 'Banani', 'বনানী', 23.7937, 90.4066);
final _farB = _s('b_far', 'Farmgate', 'ফার্মগেট', 23.7580, 90.3900);
final _m10B = _s('b_m10', 'Mirpur 10 Golchattar', 'মিরপুর ১০ গোলচত্বর', 23.8068, 90.3688);
final _agaB = _s('b_aga', 'Agargaon', 'আগারগাঁও', 23.7775, 90.3795);
final _shaB = _s('b_sha', 'Shahbag', 'শাহবাগ', 23.7380, 90.3955);
final _m1 = _s('b_m1', 'Mirpur 1', 'মিরপুর ১', 23.7956, 90.3537);
final _gab = _s('b_gab', 'Gabtoli', 'গাবতলী', 23.7830, 90.3440);

/// What OfflineRouter.routeShapes() gives the map (sample network).
List<Map<String, dynamic>> fakeCityMapShapes() => [
      _route('mrt6_s', 'metro', 'MRT Line 6', 'এমআরটি লাইন ৬', _mrt, lo: 20, hi: 100, status: 'verified'),
      _route('bus_s1', 'bus', 'Sample Bus 1', 'নমুনা বাস ১', [_airport, _khil, _kuril, _badda, _ramp, _mali, _motB],
          lo: 10, hi: 45),
      _route('bus_s2', 'bus', 'Sample Bus 2', 'নমুনা বাস ২', [_m10B, _agaB, _farB, _shaB, _motB], lo: 10, hi: 35),
      _route('bus_s3', 'bus', 'Sample Bus 3', 'নমুনা বাস ৩', [_badda, _gul1, _moha, _farB], lo: 10, hi: 25),
      _route('bus_s4', 'bus', 'Sample Bus 4', 'নমুনা বাস ৪', [_airport, _bana, _moha, _farB], lo: 10, hi: 30),
      _route('bus_s5', 'bus', 'Sample Bus 5', 'নমুনা বাস ৫', [_gab, _m1, _m10B], lo: 10, hi: 15),
      _route('bus_w1', 'bus', 'Sample Women Bus', 'নমুনা নারী বাস', [_m10B, _agaB, _farB], lo: 10, hi: 20),
    ];

/// /maps/transit in the server's shape (sample, Google view only).
Map<String, dynamic> fakeGoogleTransit({bool none = false}) => none
    ? {'state': 'none', 'routes': <Map<String, dynamic>>[], 'gmaps_url': 'https://www.google.com/maps/dir/?api=1&travelmode=transit'}
    : {
        'state': 'ok',
        'attribution': 'Google',
        'gmaps_url': 'https://www.google.com/maps/dir/?api=1&travelmode=transit',
        'routes': [
          {
            'minutes': 41,
            'distance_m': 9100,
            'fare_bdt': 60,
            'polyline': '',
            'steps': [
              {'mode': 'walk', 'minutes': 4, 'meters': 250},
              {'mode': 'metro', 'minutes': 25, 'meters': 8000, 'line': 'MRT-6', 'line_name': 'MRT Line 6',
               'agency': 'Sample Metro', 'from': 'Mirpur 10', 'to': 'Motijheel', 'stops': 6},
              {'mode': 'walk', 'minutes': 5, 'meters': 400},
            ],
          },
          {
            'minutes': 58,
            'distance_m': 12100,
            'fare_bdt': null,
            'polyline': '',
            'steps': [
              {'mode': 'bus', 'minutes': 50, 'meters': 11800, 'line': 'Sample Bus 2', 'from': 'Mirpur 10',
               'to': 'Motijheel', 'stops': 14},
            ],
          },
        ],
      };

/// GET hook for fake_api.dart (mapapp). null = not ours.
Map<String, dynamic>? fakeCityMapGet(String path) {
  if (path.startsWith('/maps/transit')) return fakeGoogleTransit();
  if (path.startsWith('/city/trips/mine')) return {'stops_verified': 12, 'rides': 4};
  if (path.startsWith('/city/map')) {
    return {'tiles_base': 'https://example.org/maps/v1/', 'credits': '', 'offline_city': 'dhaka'};
  }
  return null;
}

/// POST hook (mapapp). null = not ours.
Map<String, dynamic>? fakeCityMapPost(String path, [Map<String, dynamic> body = const {}]) {
  if (path == '/city/trips/confirm') return {'ok': true, 'stops_verified': 14, 'rides': 5};
  return null;
}
