// missing (owner 2 Nov): gallery / FakeApi stubs for the Missing person
// alert — the server's real response shapes (backend/core/missing_views.py),
// so the screenshots show honest states: one alert near me (adult, GD line
// "not verified"), one of mine (child, tips waiting), my opt-in, an alert
// about me, and the private tip thread.

String _ago(int minutes) =>
    DateTime.now().toUtc().subtract(Duration(minutes: minutes)).toIso8601String();

String _in(int hours) => DateTime.now().toUtc().add(Duration(hours: hours)).toIso8601String();

List<Map<String, dynamic>> _districts(bool bn) => [
      {'code': 'dhaka', 'name': bn ? 'ঢাকা' : 'Dhaka'},
      {'code': 'gazipur', 'name': bn ? 'গাজীপুর' : 'Gazipur'},
      {'code': 'chattogram', 'name': bn ? 'চট্টগ্রাম' : 'Chattogram'},
    ];

Map<String, dynamic> fakeMissingAlert(int id, {required bool bn}) {
  final dhaka = bn ? 'ঢাকা' : 'Dhaka';
  if (id == 21 || id == 22) {
    // mine: a child alert, live, tips waiting (family view)
    return {
      'id': id, 'state': 'active', 'role': 'family',
      'name': bn ? 'রাফি' : 'Rafi', 'age': 9, 'is_child': true,
      'area_text': bn ? 'মিরপুর ১০ বাসস্ট্যান্ড' : 'Mirpur 10 bus stand',
      'district': 'dhaka', 'district_name': dhaka, 'last_seen_at': _ago(150), 'radius_km': 10,
      'created_at': _ago(120), 'activated_at': _ago(118), 'expires_at': _in(160), 'closed_at': null,
      'safe_said': false, 'safe_said_at': null, 'photo_url': null,
      'description': bn
          ? 'নীল স্কুল শার্ট, প্রায় ৪ ফুট'
          : 'Blue school shirt, about 4 feet tall',
      'gd': null, 'basis': 'cosigned', 'pushed': 46, 'listed': 52, 'renewals': 0, 'max_renewals': 4,
      'can_renew': false, 'tips_unread': 2, 'tips': 3, 'cosign_asked': null,
      'cosigner': {'id': 2, 'name': bn ? 'আব্বু' : 'Dad'},
      'relation': 'son', 'share_agreed': false, 'recipients_family': 2,
    };
  }
  // near me: an adult with a police GD (recipient view)
  return {
    'id': id, 'state': 'active', 'role': 'recipient',
    'name': bn ? 'করিম মিয়া' : 'Karim Mia', 'age': 67, 'is_child': false,
    'area_text': bn ? 'গাবতলী বাস টার্মিনাল' : 'Gabtoli bus terminal',
    'district': 'dhaka', 'district_name': dhaka, 'last_seen_at': _ago(300), 'radius_km': 10,
    'created_at': _ago(240), 'activated_at': _ago(240), 'expires_at': _in(150), 'closed_at': null,
    'safe_said': false, 'safe_said_at': null, 'photo_url': null,
    'description': bn
        ? 'সাদা পাঞ্জাবি, স্মৃতিশক্তি কম'
        : 'White panjabi, has memory loss',
    'gd': {'number': '512/2026', 'thana': bn ? 'মিরপুর মডেল' : 'Mirpur Model',
           'date': DateTime.now().toIso8601String().substring(0, 10), 'verified': false},
    'basis': 'gd', 'my_tip_thread': null, 'reported': false, 'distance_km': 3,
  };
}

Map<String, dynamic>? fakeMissingGet(String path, {required bool bn, required bool empty}) {
  final p = path.split('?').first;
  if (p == '/missing-alerts/config') {
    return {
      'enabled': true, 'districts': _districts(bn), 'radius_choices': [5, 10, 25], 'default_radius': 10,
      'expiry_days': 7, 'renew_days': 7, 'max_active': 2, 'max_posts_30d': 3, 'child_under': 18,
      'cooling_days': 7, 'report_hide_n': 3, 'max_push_per_user_day': 3, 'open_location_hours': 12,
      'site': 'https://lifeassisto.com',
      'optin': {'enabled': !empty, 'district': empty ? '' : 'dhaka', 'district_name': empty ? '' : (bn ? 'ঢাকা' : 'Dhaka'),
                'has_point': false, 'use_open_location': false, 'open_fresh': false},
      'family_users': empty ? const [] : [
        {'id': 2, 'name': bn ? 'আব্বু' : 'Dad', 'relation': 'husband'},
        {'id': 5, 'name': bn ? 'রাফি' : 'Rafi', 'relation': 'child'},
      ],
      'cosigners': empty ? const [] : [
        {'id': 2, 'name': bn ? 'আব্বু' : 'Dad', 'relation': 'husband'},
      ],
      'family_members': const [],
    };
  }
  if (p == '/missing-alerts') {
    return {
      'enabled': true,
      'near': empty ? const [] : [fakeMissingAlert(11, bn: bn)],
      'mine': empty ? const [] : [fakeMissingAlert(21, bn: bn)],
      'about_me': const [],
      'cosign': const [],
      'optin': {'enabled': !empty, 'district': empty ? '' : 'dhaka',
                'district_name': empty ? '' : (bn ? 'ঢাকা' : 'Dhaka'),
                'has_point': false, 'use_open_location': false, 'open_fresh': false},
    };
  }
  if (p == '/missing-alerts/nearby') {
    return {
      'ok': true,
      'pref': {'enabled': !empty, 'district': empty ? '' : 'dhaka',
               'district_name': empty ? '' : (bn ? 'ঢাকা' : 'Dhaka'),
               'has_point': false, 'use_open_location': !empty, 'open_fresh': false},
      'districts': _districts(bn),
    };
  }
  final tips = RegExp(r'^/missing-alerts/(\d+)/tips$').firstMatch(p);
  if (tips != null) {
    return {'ok': true, 'family': true, 'threads': [fakeMissingThread(7, bn: bn)]};
  }
  final th = RegExp(r'^/missing-alerts/tips/(\d+)$').firstMatch(p);
  if (th != null) {
    return {'ok': true, 'family': true, 'alert_state': 'active', 'thread': fakeMissingThread(7, bn: bn)};
  }
  final one = RegExp(r'^/missing-alerts/(\d+)$').firstMatch(p);
  if (one != null) {
    return {'ok': true, 'alert': fakeMissingAlert(int.parse(one.group(1)!), bn: bn)};
  }
  return null;
}

Map<String, dynamic> fakeMissingThread(int id, {required bool bn}) => {
      'id': id, 'alert_id': 21,
      'tipster': bn ? 'অজ্ঞাত তথ্যদাতা #০০৭' : 'Anonymous tipster #007',
      'share_identity': false, 'tipster_phone': null, 'unread': 0, 'last_at': _ago(20),
      'messages': [
        {'id': 1, 'by_family': false, 'at': _ago(25), 'point': {'lat': 23.81, 'lng': 90.37},
         'text': bn
             ? 'মিরপুর ১০-এর ফার্মেসীর সামনে নীল শার্ট পরা একটা ছেলেকে দেখেছি।'
             : 'I saw a boy in a blue shirt in front of the pharmacy at Mirpur 10.'},
        {'id': 2, 'by_family': true, 'at': _ago(20),
         'text': bn ? 'কতক্ষণ আগে? অনেক ধন্যবাদ।' : 'How long ago? Thank you so much.'},
      ],
    };

/// Any missing-alert POST in the gallery succeeds (shapes as the server).
Map<String, dynamic>? fakeMissingPost(String path, {required bool bn}) {
  final p = path.split('?').first;
  if (!p.startsWith('/missing-alerts')) return null;
  if (p == '/missing-alerts') {
    return {'ok': true, 'alert': fakeMissingAlert(21, bn: bn), 'needs': null, '_status': 201};
  }
  if (p == '/missing-alerts/nearby') {
    return {'ok': true, 'pref': {'enabled': true, 'district': 'dhaka', 'district_name': 'Dhaka',
            'has_point': false, 'use_open_location': false, 'open_fresh': false}, '_status': 200};
  }
  final th = RegExp(r'^/missing-alerts/tips/(\d+)$').firstMatch(p);
  if (th != null) return {'ok': true, 'thread': fakeMissingThread(7, bn: bn), '_status': 200};
  if (p.endsWith('/tips')) return {'ok': true, 'thread': fakeMissingThread(7, bn: bn), '_status': 201};
  return {'ok': true, '_status': 200};
}
