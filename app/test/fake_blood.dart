// blood (owner 2 Nov): gallery / FakeApi stubs for the Blood donor panel —
// the server's real response shapes (backend/core/blood_views.py), so the
// screenshots show honest states: a listed donor (me), donors near me (one
// with a public number, one "available again on"), my urgent request with a
// responder, a request near me, a private thread, banks "source pending".

String _ago(int minutes) =>
    DateTime.now().toUtc().subtract(Duration(minutes: minutes)).toIso8601String();

String _in(int hours) => DateTime.now().toUtc().add(Duration(hours: hours)).toIso8601String();

String _day(int days) => DateTime.now().add(Duration(days: days)).toIso8601String().substring(0, 10);

List<Map<String, dynamic>> _districts(bool bn) => [
      {'code': 'dhaka', 'name': bn ? 'ঢাকা' : 'Dhaka'},
      {'code': 'gazipur', 'name': bn ? 'গাজীপুর' : 'Gazipur'},
      {'code': 'chattogram', 'name': bn ? 'চট্টগ্রাম' : 'Chattogram'},
    ];

Map<String, dynamic> fakeBloodMe({required bool bn, bool donor = true}) => donor
    ? {
        'enabled': true, 'consented': true, 'consent_version': 1, 'blood_group': 'B+', 'sex': 'm',
        'last_donation': _day(-140), 'available': true, 'district': 'dhaka',
        'district_name': bn ? 'ঢাকা' : 'Dhaka', 'area_text': bn ? 'মিরপুর ১০' : 'Mirpur 10',
        'has_point': true, 'phone_public': false, 'email_public': false, 'verified': true,
        'verification': 'approved', 'eligible': true, 'next_date': _day(-20), 'interval_days': 120,
        'details_checked': _day(-30), 'details_stale': false, // finish1
      }
    : {'enabled': false, 'consented': false};

List<Map<String, dynamic>> fakeBloodDonors(bool bn) => [
      {'id': 3, 'name': bn ? 'আকাশ' : 'Akash', 'blood_group': 'B+', 'area_text': bn ? 'কাজীপাড়া' : 'Kazipara',
       'district_name': bn ? 'ঢাকা' : 'Dhaka', 'km': 2, 'eligible': true, 'next_date': null,
       'verified': true, 'phone': null, 'email': null, 'status': 'available', 'days_left': 0,
       'donated_days_ago': 200},
      {'id': 4, 'name': bn ? 'নুসরাত' : 'Nusrat', 'blood_group': 'B+', 'area_text': bn ? 'পল্লবী' : 'Pallabi',
       'district_name': bn ? 'ঢাকা' : 'Dhaka', 'km': 3, 'eligible': true, 'next_date': null,
       'verified': false, 'phone': '01711000000', 'email': null, 'status': 'available',
       'days_left': 0, 'donated_days_ago': null},
      {'id': 5, 'name': bn ? 'রবিন' : 'Robin', 'blood_group': 'O-', 'area_text': bn ? 'আগারগাঁও' : 'Agargaon',
       'district_name': bn ? 'ঢাকা' : 'Dhaka', 'km': 5, 'eligible': false, 'next_date': _day(38),
       'verified': false, 'phone': null, 'email': null, 'status': 'waiting', 'days_left': 38,
       'donated_days_ago': 82},
      // finish1 (owner final): a paused donor is shown as paused, never hidden
      {'id': 6, 'name': bn ? 'সুমি' : 'Sumi', 'blood_group': 'B+', 'area_text': bn ? 'মিরপুর' : 'Mirpur',
       'district_name': bn ? 'ঢাকা' : 'Dhaka', 'km': 1, 'eligible': true, 'next_date': null,
       'verified': false, 'phone': null, 'email': null, 'status': 'paused', 'days_left': 0,
       'donated_days_ago': null},
    ];

Map<String, dynamic> fakeBloodRequest(int id, {required bool bn}) {
  final base = {
    'id': id, 'state': 'active', 'blood_group': id == 31 ? 'B+' : 'A+', 'units': 2,
    'hospital': bn ? 'ঢাকা মেডিকেল কলেজ হাসপাতাল' : 'Dhaka Medical College Hospital',
    'area_text': bn ? 'শাহবাগ' : 'Shahbag', 'district_name': bn ? 'ঢাকা' : 'Dhaka',
    'radius_km': 5, 'needed_by': _in(5), 'note': bn ? 'রোগী ওয়ার্ড ১০৫-এ' : 'Patient in ward 105',
    'created_at': _ago(40), 'expires_at': _in(11), 'closed_at': null,
    'requester_name': bn ? 'রহিম' : 'Rahim',
  };
  if (id == 31) {
    return {
      ...base, 'role': 'requester', 'pushed': 18, 'listed': 21, 'reports_open': 0,
      'responders': [
        {...fakeBloodDonors(bn)[0], 'response': 'can', 'thread_id': 7, 'responded_at': _ago(12)},
      ],
    };
  }
  return {
    ...base, 'role': 'donor', 'my_response': '', 'reported': false, 'km': 4,
    'compatible': true, 'eligible_by_then': true, 'thread_id': null,
  };
}

Map<String, dynamic> fakeBloodThread(int id, {required bool bn}) => {
      'thread': {
        'id': id, 'side': 'seeker', 'other_name': bn ? 'আকাশ' : 'Akash', 'blood_group': 'B+',
        'verified': true, 'request_id': 31, 'last_at': _ago(5), 'unread': 0, 'blocked': false,
        'blocked_by_me': false, 'circle_ask': '', 'phone': null,
      },
      'messages': [
        {'id': 1, 'mine': false, 'text': bn ? 'আমি রক্ত দিতে পারব।' : 'I can donate.', 'at': _ago(12)},
        {'id': 2, 'mine': true, 'text': bn ? 'অনেক ধন্যবাদ! ঢাকা মেডিকেলের ব্লাড ব্যাংকে কখন আসতে পারবেন?' : 'Thank you so much! When can you come to the DMCH blood bank?', 'at': _ago(9)},
        {'id': 3, 'mine': false, 'text': bn ? 'এক ঘণ্টার মধ্যে আসছি ইনশাআল্লাহ।' : 'Coming within an hour, insha Allah.', 'at': _ago(5)},
      ],
    };

Map<String, dynamic>? fakeBloodGet(String path, {required bool bn, required bool empty}) {
  final p = path.split('?').first;
  if (!p.startsWith('/blood-panel/')) return null;
  if (p == '/blood-panel/config') {
    return {
      'enabled': true, 'districts': _districts(bn), 'groups': ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'],
      'radius_choices': [2, 5, 10, 25], 'default_radius': 5, 'interval_days': {'m': 120, 'f': 120},
      'consent_version': 1, 'max_req_day': 3, 'max_units': 10, 'report_hide_n': 3,
      'site': 'https://lifeassisto.com', 'me': fakeBloodMe(bn: bn, donor: !empty),
    };
  }
  if (p == '/blood-panel/me') return fakeBloodMe(bn: bn, donor: !empty);
  if (p == '/blood-panel/donors') {
    final d = empty ? const <Map<String, dynamic>>[] : fakeBloodDonors(bn);
    return {'ok': true, 'donors': d, 'count': d.length,
      'counts': {'total': d.length, 'available': d.where((x) => x['status'] == 'available').length,
        'soon': d.where((x) => x['status'] == 'waiting').length,
        'paused': d.where((x) => x['status'] == 'paused').length}};
  }
  if (p == '/blood-panel/requests') {
    return {
      'enabled': true,
      'mine': empty ? const [] : [fakeBloodRequest(31, bn: bn)],
      'near': empty ? const [] : [fakeBloodRequest(41, bn: bn)],
    };
  }
  final rq = RegExp(r'^/blood-panel/requests/(\d+)$').firstMatch(p);
  if (rq != null) return fakeBloodRequest(int.parse(rq.group(1)!), bn: bn);
  if (p == '/blood-panel/threads') {
    return {'threads': empty ? const [] : [fakeBloodThread(7, bn: bn)['thread']]};
  }
  final th = RegExp(r'^/blood-panel/threads/(\d+)$').firstMatch(p);
  if (th != null) return fakeBloodThread(int.parse(th.group(1)!), bn: bn);
  if (p == '/blood-panel/banks') return {'banks': const [], 'source': null, 'source_pending': true};
  return null;
}

Map<String, dynamic>? fakeBloodPost(String path, {required bool bn}) {
  final p = path.split('?').first;
  if (!p.startsWith('/blood-panel/')) return null;
  if (p == '/blood-panel/me' || p == '/blood-panel/me/donated') {
    return {'ok': true, 'me': fakeBloodMe(bn: bn), '_status': 200};
  }
  if (p == '/blood-panel/requests') {
    return {'ok': true, 'request': fakeBloodRequest(31, bn: bn), '_status': 201};
  }
  if (p.endsWith('/message')) {
    return {'ok': true, 'thread': fakeBloodThread(7, bn: bn)['thread'], '_status': 201};
  }
  if (p.endsWith('/circle')) {
    return {'ok': true, 'thread': fakeBloodThread(7, bn: bn)['thread'], '_status': 200};
  }
  return {'ok': true, '_status': 200};
}

/// finish1: what the banks screen looks like AFTER the owner imports an
/// official list. Gallery only — clearly labelled examples, never shipped.
Map<String, dynamic> fakeBloodBanksExample(bool bn) => {
      'source': {
        'name': bn ? 'উদাহরণ তালিকা (পরীক্ষা)' : 'Example list (test)',
        'url': 'https://example.gov.bd/blood',
        'date': '2026-10-01',
      },
      'source_pending': false,
      'districts': _districts(bn),
      'total': 2,
      'banks': [
        {'name': bn ? 'উদাহরণ ব্লাড ব্যাংক ১' : 'Example blood bank 1', 'district': 'dhaka',
          'district_name': bn ? 'ঢাকা' : 'Dhaka', 'area': bn ? 'শাহবাগ' : 'Shahbag',
          'address': bn ? 'উদাহরণ সড়ক ১' : 'Example road 1', 'hours': bn ? '২৪ ঘণ্টা' : '24 hours',
          'phone': '01700-000001', 'km': 2.4, 'km_from_district': false},
        {'name': bn ? 'উদাহরণ ব্লাড ব্যাংক ২' : 'Example blood bank 2', 'district': 'chattogram',
          'district_name': bn ? 'চট্টগ্রাম' : 'Chattogram', 'area': '',
          'address': bn ? 'উদাহরণ সড়ক ২' : 'Example road 2', 'hours': '', 'phone': '',
          'km': 214.0, 'km_from_district': true},
      ],
    };
