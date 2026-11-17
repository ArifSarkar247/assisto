// train: FakeApi / gallery GET stubs for the Train tracker — the server's
// real response shapes (backend/core/train_views.py). Honest states: an
// unchecked timetable estimate, a live train with 3 sharers, a chat with
// an emergency message and a My Circle request.
Map<String, dynamic> _st(String id, String bn, String en, double lat, double lng) =>
    {'id': id, 'bn': bn, 'en': en, 'lat': lat, 'lng': lng};

final _ctg = _st('n1', 'চট্টগ্রাম', 'Chattogram Railway Station', 22.33402, 91.82956);
final _dhk = _st('n2', 'কমলাপুর', 'Kamalapur Railway Station', 23.73195, 90.42627);
final _bia = _st('n3', 'ঢাকা বিমানবন্দর', 'Dhaka Airport Railway Station', 23.85207, 90.40838);

Map<String, dynamic> trainSummary701() => {
      'no': '701', 'name_bn': 'সুবর্ণ এক্সপ্রেস', 'from': _ctg, 'to': _dhk,
      'dep': '07:00', 'arr': '12:20', 'off_days': [0], 'km': 321.2, 'approved': false,
    };

Map<String, dynamic> trainLive701({bool live = false}) {
  final now = DateTime.now().toUtc();
  return {
    'train': trainSummary701(),
    'date': '2026-11-03',
    'runs': true,
    'mode': live ? 'live' : 'estimate',
    'live': live
        ? {'label': 'live', 'chainage_m': 160000, 'lat': 23.1, 'lng': 91.2, 'sharers': 3,
           'dropped': 1, 'age_s': 25, 'speed_kmh': 62, 'arrived': false, 'delay_min': 18,
           'next_stop': _bia}
        : null,
    'estimate': {'label': 'estimate', 'state': 'running', 'chainage_m': 150000,
        'lat': 23.05, 'lng': 91.25, 'next_stop': _bia, 'approved': false,
        'dep': now.toIso8601String(), 'arr': now.toIso8601String()},
    'stops': [
      {..._ctg, 'km': 0, 'at': now.subtract(const Duration(hours: 2)).toIso8601String(), 'label': 'estimate'},
      {..._bia, 'km': 300.1, 'at': now.add(const Duration(hours: 2)).toIso8601String(), 'label': 'estimate'},
      {..._dhk, 'km': 321.2, 'at': now.add(const Duration(hours: 3)).toIso8601String(), 'label': 'estimate'},
    ],
    'path': [[22.33402, 91.82956], [23.0, 91.3], [23.85207, 90.40838], [23.73195, 90.42627]],
    'sms': {'to': '16318', 'body': 'TR 701', 'cost_bdt': 4},
    'my_share': null,
    'chat_count': 2,
    // sjtrain: the metro-style line (backend train_geo.line_view shape)
    'line': trainLine701(now, live: live),
    'sharers': live ? 3 : 0,
    'delay_min': live ? 18 : null,
    'chat': {'open': true, 'opens_at': now.subtract(const Duration(hours: 3)).toIso8601String(),
        'closes_at': now.add(const Duration(hours: 5)).toIso8601String()},
    'source': {'wiki_title': 'সুবর্ণ এক্সপ্রেস', 'wiki_revid': 1},
    // train-app (V2): how fresh it is (engine contract)
    'freshness': live
        ? {'state': 'live', 'age_s': 25, 'updated_at': now.toIso8601String()}
        : {'state': 'timetable', 'age_s': 0},
  };
}

/// sjtrain: 701's stations (sample subset of the real line, made-up times).
Map<String, dynamic> trainLine701(DateTime now, {bool live = false}) {
  const rows = [
    ['n1', 'চট্টগ্রাম', 'Chattogram', 0.0, true],
    ['o1', 'পাহাড়তলী', 'Pahartoli', 4.2, false],
    ['o2', 'সীতাকুণ্ড', 'Sitakunda', 37.4, false],
    ['o3', 'ফেনী', 'Feni', 90.0, false],
    ['o4', 'নাঙ্গলকোট', 'Nangalkot', 116.8, false],
    ['o5', 'কুমিল্লা', 'Cumilla', 154.1, false],
    ['o6', 'কসবা', 'Kasba', 186.0, false],
    ['o7', 'আখাউড়া', 'Akhaura', 201.6, false],
    ['o8', 'ব্রাহ্মণবাড়িয়া', 'Brahmanbaria', 217.6, false],
    ['o9', 'ভৈরব বাজার', 'Bhairab Bazar', 234.3, false],
    ['o10', 'টঙ্গী জংশন', 'Tongi Junction', 298.7, false],
    ['n3', 'ঢাকা বিমানবন্দর', 'Dhaka Airport', 303.9, false],
    ['n2', 'কমলাপুর', 'Kamalapur', 321.2, true],
  ];
  // the train is just past Cumilla (live) / at Cumilla (estimate)
  final atKm = live ? 156.0 : 154.3;
  final out = <Map<String, dynamic>>[];
  int? nowI, nextI;
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final km = r[3] as double;
    final passed = km * 1000 <= atKm * 1000 + 150;
    if (passed) nowI = i;
    if (!passed && nextI == null) nextI = i;
    final eta = now.add(Duration(minutes: ((km - atKm) * 1.1).round()));
    out.add({'id': r[0], 'bn': r[1], 'en': r[2], 'km': km, 'stop': r[4],
        'lat': 23.0 + i * 0.05, 'lng': 91.0 - i * 0.03,
        'sched': eta.toIso8601String(), 'eta': eta.toIso8601String(), 'passed': passed,
        // train-app (V2): passed stations carry the confirmed time + delay
        if (live && passed) 'actual': eta.add(Duration(minutes: 6 + i * 2)).toIso8601String(),
        if (live && passed) 'delay_min': 6 + i * 2});
  }
  return {'stations': out, 'now_index': nowI, 'passing': live ? null : nowI, 'next_index': nextI};
}

/// sjtrain: the seat card (GET /train/<no>/seat) — 2 of 3 agree on the window,
/// 3 agree on facing (verified), the sun side is calculated.
Map<String, dynamic> trainSeat701({bool empty = false}) => {
      'train': '701', 'coach': 'ঝ', 'seat': '32', 'answers': empty ? 0 : 3,
      'facing': empty ? null : {'value': 'forward', 'n': 3, 'agree': 3, 'verified': true},
      'place': empty ? null : {'value': 'window', 'n': 3, 'agree': 2, 'verified': false},
      'side': empty ? null : {'value': 'left', 'n': 3, 'agree': 2, 'verified': false},
      'coach_pos': empty ? null : {'value': 7, 'n': 2, 'agree': 2, 'verified': false},
      'verify_n': 3,
      'sun': {'left': 39, 'right': 61, 'dark': 0, 'side': 'right', 'label': 'calculated'},
      'sun_on_seat': empty ? null : {'pct': 39, 'label': 'calculated'},
      'mine': null,
    };

Map<String, dynamic> trainChatRoom({bool joined = true, bool bn = true}) => {
      'me': joined ? {'nickname': bn ? 'নীল' : 'Blue'} : null,
      'messages': joined
          ? [
              {'id': 1, 'nick': bn ? 'সবুজ' : 'Green', 'mine': false,
               'text': bn ? 'ট্রেন ভৈরবে থেমে আছে' : 'Train is stopped at Bhairab',
               'at': DateTime.now().toUtc().toIso8601String(), 'emergency': false},
              {'id': 2, 'nick': bn ? 'লাল' : 'Red', 'mine': false,
               'text': bn ? 'কোচ চ-তে একজন অসুস্থ, সাহায্য লাগবে' : 'Someone in coach C is sick, need help',
               'at': DateTime.now().toUtc().toIso8601String(), 'emergency': true},
              {'id': 3, 'nick': bn ? 'নীল' : 'Blue', 'mine': true,
               'text': bn ? 'গার্ডকে জানাচ্ছি' : 'Telling the guard',
               'at': DateTime.now().toUtc().toIso8601String(), 'emergency': false},
            ]
          : [],
      'circle_requests': joined ? [{'id': 9, 'nick': bn ? 'সবুজ' : 'Green'}] : [],
      'ends_at': DateTime.now().toUtc().add(const Duration(hours: 9)).toIso8601String(),
      'hotlines': {'police': '999', 'rail': '131'},
    };

Map<String, dynamic>? fakeTrainGet(String path, {required bool bn, required bool empty}) {
  if (path.startsWith('/train/config')) {
    return {'enabled': true, 'dest_alarm': true, 'map': {'tile_url': ''},
        'attribution': '© OpenStreetMap contributors (ODbL)',
        'sms': {'to': '16318', 'cost_bdt': 4}, 'hotlines': {'police': '999', 'rail': '131'}};
  }
  if (path.startsWith('/train/search')) {
    return {'trains': empty ? [] : [trainSummary701()]};
  }
  if (path.contains('/seat')) return trainSeat701(empty: empty); // sjtrain
  // train-app: offline pack
  if (path.startsWith('/train/offline/meta')) {
    return {'version': '2026-11-17', 'size_bytes': 431000, 'updated_at': '2026-11-17T06:00:00Z'};
  }
  if (path.startsWith('/train/offline/pack')) return trainOfflinePackJson();
  if (path.contains('/live')) return trainLive701(live: !empty);
  if (path.contains('/chat')) return trainChatRoom(joined: !empty, bn: bn);
  return null;
}

// ---------------------------------------------------------------- train-app
/// train-app (V2): a tiny offline pack in the data lane's COMPACT format
/// (train_data.offline_bundle(): st / tr / tw) — 701 with made-up times,
/// a suspended cross-border train (km from coordinates), and two learned
/// towers (sample ids and points, no real data).
Map<String, dynamic> trainOfflinePackJson() => {
      'v': 1,
      'ver': 'a1b2c3d4e5f6',
      'st': [
        ['CTG', 'চট্টগ্রাম', 'Chattogram', 2233402, 9182956],
        ['FEN', 'ফেনী', 'Feni', 2301230, 9139760],
        ['CML', 'কুমিল্লা', 'Cumilla', 2346070, 9118090],
        ['BHB', 'ভৈরব বাজার', 'Bhairab Bazar', 2405250, 9097640],
        ['APT', 'ঢাকা বিমানবন্দর', 'Dhaka Airport', 2385207, 9040838],
        ['DHK', 'কমলাপুর', 'Kamalapur', 2373195, 9042627],
        ['BNP', 'বেনাপোল', 'Benapole', 2304000, 8889000],
      ],
      'tr': [
        ['701', 'সুবর্ণ এক্সপ্রেস', 'Subarna Express', 1, 1, 0, [
          [0, -1, 420, 0], [1, 500, 502, 900], [2, 555, 558, 1541],
          [3, 625, 627, 2343], [4, 700, 702, 3039], [5, 740, -1, 3212],
        ]],
        ['3109', 'মৈত্রী এক্সপ্রেস', 'Maitree Express', 5, 2, 0, [[5, -1, 495, 0], [6, 900, -1, -1]]],
      ],
      'tw': [
        // learned 6 km after Cumilla on the way to Bhairab; one at Bhairab
        [470, 1, 1234, 56789, 12, 640, 14, 2350426, 9116585],
        ['470', '03', 77, 4242, 20, 0, 3, 2405250, 9097640],
      ],
    };

/// train-app (V2): POST stubs — check-in accepted, shared text parsed.
Map<String, dynamic>? fakeTrainPost(String path, Map<String, dynamic> body) {
  if (path.endsWith('/checkin')) return {'ok': true, 'status': 'accepted', 'points': 5};
  if (path.startsWith('/train/text')) {
    return {
      'ok': true,
      'parsed': {'no': '701', 'station_id': 'o5', 'station_bn': 'কুমিল্লা', 'station_en': 'Cumilla',
          'kind': 'left', 'at': DateTime.now().toUtc().toIso8601String(), 'late_min': 18},
      'applied': true,
    };
  }
  if (RegExp(r'^/train/\d+/share$').hasMatch(path)) {
    return {'ok': true, 'share': {'id': 41, 'status': 'active',
        'ends_at': DateTime.now().toUtc().add(const Duration(hours: 6)).toIso8601String()}};
  }
  if (path.startsWith('/train/share/')) return {'ok': true, 'accepted': 1, 'rejected': 0, 'status': 'active'};
  return null;
}
