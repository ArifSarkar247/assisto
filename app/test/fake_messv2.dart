// messv2 — fake Mess and bachelor V2 API for the gallery + widget tests.
// Made-up sample data only (no real people).

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> fakeMessV2List({required bool bn, bool empty = false}) => {
      'messes': empty
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 1, 'name': bn ? 'রামপুরা মেস' : 'Rampura Mess', 'address': '',
                'month_start_day': 1, 'breakfast_milli': 500, 'cutoff_hour': 22,
                'status': 'active', 'group_id': 41, 'my_member_id': 11, 'my_role': 'admin',
                'i_am_manager': true, 'can_manage': true, 'is_admin': true,
              }
            ],
      'premium': false,
      'can_create': empty,
      'free_limit': 1,
      'legacy_available': empty,
    };

Map<String, dynamic> fakeMessV2Detail({required bool bn, bool closed = false}) {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, 1);
  final end = DateTime(now.year, now.month + 1, 0);
  final key = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  String n(String b, String e) => bn ? b : e;
  final members = [
    {'id': 11, 'user_id': 1, 'name': n('আমিন', 'Amin'), 'role': 'admin', 'is_manager': true,
     'seat_share': 2, 'status': 'active', 'linked': true},
    {'id': 12, 'user_id': 2, 'name': n('বাবু', 'Babu'), 'role': 'member', 'is_manager': false,
     'seat_share': 1, 'status': 'active', 'linked': true},
    {'id': 13, 'user_id': 3, 'name': n('চয়ন', 'Chayan'), 'role': 'member', 'is_manager': false,
     'seat_share': 1, 'status': 'active', 'linked': true},
    {'id': 14, 'user_id': 4, 'name': n('দীপু', 'Dipu'), 'role': 'member', 'is_manager': false,
     'seat_share': 1, 'status': 'active', 'linked': true},
  ];
  Map<String, dynamic> row(int id, String name, String meals, String cost, String svc,
          String dep, int due, String dueD) =>
      {
        'id': id, 'name': name, 'meals': meals, 'meal_cost_display': cost,
        'service_display': svc, 'deposits_display': dep, 'carry_in': 0,
        'carry_in_display': '৳0.00', 'due': due, 'due_display': dueD,
        'state': due > 0 ? 'will_pay' : (due < 0 ? 'gets_back' : 'clear'),
      };
  return {
    'mess': fakeMessV2List(bn: bn)['messes'][0],
    'members': members,
    'month': {'key': key, 'start': _iso(start), 'end': _iso(end), 'closed': closed,
              'full': true, 'closed_at': null},
    'months_closed': <String>[],
    'summary': {
      'meals_total': '274.5', 'meals_total_milli': 274500,
      'bazar_total_display': '৳10,235.00', 'meal_rate_display': '৳37.29',
      'charges_total_display': '৳12,700.00', 'deposits_total_display': '৳16,371.45',
      'reconciles': true,
      'members': [
        row(11, n('আমিন', 'Amin'), '75', '৳2,796.45', '৳4,975.00', '৳3,000.00', 477145, '৳4,771.45'),
        row(12, n('বাবু', 'Babu'), '74.5', '৳2,777.80', '৳2,575.00', '৳6,000.00', -64720, '৳647.20'),
        row(13, n('চয়ন', 'Chayan'), '75', '৳2,796.45', '৳2,575.00', '৳5,371.45', 0, '৳0.00'),
        row(14, n('দীপু', 'Dipu'), '50', '৳1,864.30', '৳2,575.00', '৳2,000.00', 243930, '৳2,439.30'),
      ],
    },
    'entries': [
      {'id': 101, 'kind': 'bazar', 'member_id': 12, 'member_name': n('বাবু', 'Babu'),
       'date': _iso(start), 'amount': 500000, 'amount_display': '৳5,000.00',
       'data': {'items': n('চাল, ডাল, তেল', 'Rice, lentils, oil')}, 'photo_url': '/api/v1/m/mess/x.jpg'},
      {'id': 102, 'kind': 'bazar', 'member_id': 13, 'member_name': n('চয়ন', 'Chayan'),
       'date': _iso(start.add(const Duration(days: 7))), 'amount': 323500,
       'amount_display': '৳3,235.00', 'data': {'items': n('মাছ, সবজি', 'Fish, vegetables')}},
      {'id': 103, 'kind': 'charge', 'member_id': null, 'member_name': '', 'date': _iso(start),
       'amount': 70000, 'amount_display': '৳700.00', 'data': {'kind': 'wifi', 'split': 'equal'}},
      {'id': 104, 'kind': 'charge', 'member_id': null, 'member_name': '', 'date': _iso(start),
       'amount': 1200000, 'amount_display': '৳12,000.00', 'data': {'kind': 'rent', 'split': 'seat'}},
      {'id': 105, 'kind': 'deposit', 'member_id': 11, 'member_name': n('আমিন', 'Amin'),
       'date': _iso(start), 'amount': 300000, 'amount_display': '৳3,000.00',
       'data': {'advance': true}},
      {'id': 106, 'kind': 'turn', 'member_id': 14, 'member_name': n('দীপু', 'Dipu'),
       'date': _iso(now.add(const Duration(days: 1))), 'amount': 0, 'amount_display': '৳0.00',
       'data': {}},
    ],
    'my_days': [
      for (var i = 0; i < 10; i++)
        {
          'date': _iso(now.add(Duration(days: i))), 'set': i == 2,
          'b': i == 2 ? 0 : 1, 'l': 1, 'd': i == 4 ? 0 : 1, 'gb': 0, 'gl': i == 3 ? 1 : 0, 'gd': 0,
          'locked': false, 'can_edit': i > 0,
        }
    ],
    'today': {
      'mess_id': 1, 'name': n('রামপুরা মেস', 'Rampura Mess'), 'meals_today': '10',
      'bazar_today_display': '৳850.00', 'not_set_tomorrow': [n('দীপু', 'Dipu')],
      'bazar_turn_today': n('বাবু', 'Babu'),
    },
    'premium': false,
  };
}

/// GET hook: null when the path is not a mess V2 path.
Map<String, dynamic>? fakeMessV2Get(String path, {required bool bn, bool empty = false}) {
  if (path == '/mess/v2') return fakeMessV2List(bn: bn, empty: empty);
  if (path.startsWith('/mess/v2/by-group/')) {
    return {'card': (fakeMessV2Detail(bn: bn)['today'])};
  }
  if (RegExp(r'^/mess/v2/\d+/circle-pick').hasMatch(path)) {
    return {
      'results': [
        {'circle_member_id': 7, 'user_id': 2, 'name': bn ? 'বাবু' : 'Babu', 'in_mess': true},
        {'circle_member_id': 8, 'user_id': 5, 'name': bn ? 'ইমন' : 'Emon', 'in_mess': false},
      ],
      'unlinked': <Map<String, dynamic>>[],
    };
  }
  if (RegExp(r'^/mess/v2/\d+/history').hasMatch(path)) {
    return {'results': <Map<String, dynamic>>[]};
  }
  if (RegExp(r'^/mess/v2/\d+/report').hasMatch(path)) return {'month': '', 'text': ''};
  if (RegExp(r'^/mess/v2/\d+').hasMatch(path)) return fakeMessV2Detail(bn: bn);
  return null;
}

/// POST hook: every write succeeds (widget tests check the request body).
Map<String, dynamic>? fakeMessV2Post(String path, Map<String, dynamic> body) {
  if (!path.startsWith('/mess/v2')) return null;
  if (path == '/mess/v2') return {...fakeMessV2List(bn: false)['messes'][0], 'name': body['name']};
  return {'ok': true};
}
