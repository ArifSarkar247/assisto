// fcscreen — fake /family/v3/* answers for the gallery, fake_api.dart and
// fcscreen_test.dart. Server-shaped (backend/core/family_v3.py board()).
// FcFake.scene picks the state set: 'mixed' (default: SOS-free, one gray
// dashed, one amber, two green), 'ok' (all green), 'sos', 'empty' (only me),
// 'abroad' (mixed + a Probashi member).

class FcFake {
  static String scene = 'mixed';
  static final List<String> posts = [];
}

String _iso(DateTime d) => d.toUtc().toIso8601String();

Map<String, dynamic> fcFakeMember(int id, String name,
    {String label = '',
    String relation = '',
    String role = 'adult',
    bool me = false,
    String phone = '01710000000',
    Duration? ago,
    int? battery,
    bool charging = false,
    String net = 'cell',
    String placeKind = '',
    String placeLabel = '',
    String state = 'ok',
    String reason = 'ok',
    Map<String, dynamic>? chip,
    String abroadTz = '',
    DateTime? now}) {
  final n = now ?? DateTime.now();
  final seen = ago == null ? null : n.subtract(ago);
  return {
    'user_id': id,
    'name': name,
    'label': label,
    'relation': relation,
    'role': role,
    'me': me,
    'phone': me ? '' : phone,
    'abroad_tz': abroadTz,
    'brain': {
      if (seen != null) 'last_seen': _iso(seen),
      if (battery != null) 'battery': battery,
      'charging': charging,
      'net': net,
      if (placeKind.isNotEmpty) 'place_kind': placeKind,
      if (placeLabel.isNotEmpty) 'place_label': placeLabel,
      'brand': 'Realme',
    },
    'status': {
      'state': state,
      'reason': reason,
      'fresh_until': seen == null ? null : _iso(seen.add(const Duration(hours: 3))),
    },
    'chip': chip,
    'carecall': {'done': 0, 'missed': 0, 'pending': 0},
  };
}

List<Map<String, dynamic>> fcFakeMembers({bool bn = false, String? scene, DateTime? now}) {
  final s = scene ?? FcFake.scene;
  final n = now ?? DateTime.now();
  final me = fcFakeMember(1, bn ? 'রিনা' : 'Rina',
      me: true, ago: const Duration(minutes: 1), battery: 76, placeKind: 'home', now: n);
  if (s == 'empty') return [me];
  final ammu = fcFakeMember(2, bn ? 'নাসরিন বেগম' : 'Nasrin Begum',
      label: bn ? 'আম্মু' : 'Ammu', relation: 'mother', role: 'elder',
      ago: const Duration(minutes: 12), battery: 64, placeKind: 'home',
      chip: {'kind': 'carecall_done'}, now: n);
  final son = fcFakeMember(3, bn ? 'রাফি' : 'Rafi',
      relation: 'son', role: 'child', ago: const Duration(minutes: 6), battery: 81,
      placeKind: 'school',
      chip: {'kind': 'arrived', 'at': _iso(n.subtract(const Duration(minutes: 40))),
          'place': bn ? 'স্কুল' : 'School', 'auto': true},
      now: n);
  if (s == 'ok') return [ammu, son, me];
  final abbu = fcFakeMember(4, bn ? 'করিম উদ্দিন' : 'Karim Uddin',
      label: bn ? 'আব্বু' : 'Abbu', relation: 'father', role: 'elder',
      ago: const Duration(hours: 5, minutes: 10), battery: 4, net: 'cell',
      state: 'stale', reason: 'battery_off', chip: {'kind': 'no_news'}, now: n);
  final bhai = fcFakeMember(5, bn ? 'সাকিব' : 'Sakib',
      relation: 'brother', ago: const Duration(minutes: 20), battery: 11,
      placeLabel: bn ? 'মিরপুর ১০' : 'Mirpur 10',
      state: 'check', reason: 'battery_low', now: n,
      abroadTz: s == 'abroad' ? 'Asia/Riyadh' : '');
  if (s == 'sos') {
    bhai['status'] = {'state': 'sos', 'reason': 'sos', 'fresh_until': null};
  }
  return [abbu, bhai, ammu, son, me];
}

Map<String, dynamic> fcFakeBoard({bool bn = false, String? scene, DateTime? now}) {
  final s = scene ?? FcFake.scene;
  final members = fcFakeMembers(bn: bn, scene: s, now: now);
  final n = now ?? DateTime.now();
  return {
    'family': {'id': 10, 'name': bn ? 'আমার পরিবার' : 'My family'},
    'me': {'role': 'admin', 'user_id': 1},
    'members': members,
    'tasks': s == 'empty'
        ? []
        : [
            {'id': 71, 'title': bn ? 'আব্বুর প্রেশারের ওষুধ ফুরিয়ে আসছে' : "Abbu's BP medicine running out",
             'kind': 'medicine', 'due_date': null, 'taken_by': null, 'taken_by_name': '',
             'mine': false, 'done': false, 'created_by_name': bn ? 'আম্মু' : 'Ammu'},
            {'id': 72, 'title': bn ? 'ডেসকো বিদ্যুৎ বিল' : 'DESCO electricity bill', 'kind': 'bill',
             'due_date': '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}',
             'taken_by': 5, 'taken_by_name': bn ? 'সাকিব' : 'Sakib', 'mine': false, 'done': false},
          ],
    'today': {
      'carecalls': s == 'empty' ? {'done': 0, 'missed': 0, 'pending': 0} : {'done': 1, 'missed': 0, 'pending': 1},
      'bills_due': s == 'empty' ? 0 : 1,
      'birthdays': s == 'empty' ? [] : [bn ? 'রাফি' : 'Rafi'],
      'bazar_open': s == 'empty' ? 0 : 4,
    },
    'someone_abroad': s == 'abroad',
    'invited': s == 'empty' ? [] : [{'user_id': 9, 'name': bn ? 'খালা' : 'Khala', 'role': 'adult'}],
    'server_now': _iso(n),
  };
}

Map<String, dynamic> fcFakeFamilies({bool bn = false, String? scene}) => {
      'families': [
        {'id': 10, 'name': bn ? 'আমার পরিবার' : 'My family', 'role': 'admin', 'member_count': 5,
         'someone_abroad': false},
        if ((scene ?? FcFake.scene) != 'empty')
          {'id': 11, 'name': bn ? 'বাবা-মায়ের বাসা' : "Parents' home", 'role': 'adult',
           'member_count': 3, 'someone_abroad': false},
      ],
      'invites': (scene ?? FcFake.scene) == 'empty'
          ? [
              {'membership_id': 31, 'family_id': 12, 'family_name': bn ? 'নানুবাড়ি' : "Nanu's home",
               'invited_by_name': bn ? 'মামা' : 'Mama', 'role': 'adult'}
            ]
          : [],
      'max_families': 5,
    };

Map<String, dynamic> fcFakeMemberPage(int uid, {bool bn = false}) {
  final m = fcFakeMembers(bn: bn).firstWhere((x) => x['user_id'] == uid,
      orElse: () => fcFakeMembers(bn: bn).first);
  final n = DateTime.now();
  return {
    'member': m,
    'timeline': [
      {'at': _iso(n.subtract(const Duration(hours: 2))), 'kind': 'carecall_done', 'text': ''},
      {'at': _iso(n.subtract(const Duration(hours: 4))), 'kind': 'arrived',
       'place': bn ? 'বাসা' : 'Home', 'text': ''},
    ],
    'seen_by': [
      {'user_id': 1, 'name': bn ? 'রিনা' : 'Rina', 'families': [bn ? 'আমার পরিবার' : 'My family'],
       'sees_place': true},
      {'user_id': 5, 'name': bn ? 'সাকিব' : 'Sakib', 'families': [bn ? 'আমার পরিবার' : 'My family'],
       'sees_place': false},
    ],
  };
}

/// fake_api.dart hook: null = not a Family v3 path.
Map<String, dynamic>? fakeFcGet(String path, {bool bn = false, bool empty = false}) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  if (!p.startsWith('family/v3/')) return null;
  final scene = empty ? 'empty' : FcFake.scene;
  if (p == 'family/v3/families') return fcFakeFamilies(bn: bn, scene: scene);
  if (RegExp(r'^family/v3/families/\d+/board$').hasMatch(p)) {
    return fcFakeBoard(bn: bn, scene: scene);
  }
  final mp = RegExp(r'^family/v3/members/(\d+)').firstMatch(p);
  if (mp != null) return fcFakeMemberPage(int.parse(mp.group(1)!), bn: bn);
  if (RegExp(r'^family/v3/families/\d+/tasks$').hasMatch(p)) {
    return {'tasks': fcFakeBoard(bn: bn, scene: scene)['tasks']};
  }
  return null;
}

Map<String, dynamic>? fakeFcPost(String path, Map<String, dynamic> body) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  if (!p.startsWith('family/v3/') && p != 'family/brain/ask') return null;
  FcFake.posts.add(p);
  if (p == 'family/brain/ask') return {'text': ''};
  if (p == 'family/v3/families') {
    return {'ok': true, 'family': {'id': 13, 'name': '${body['name']}', 'role': 'admin'}};
  }
  if (p.endsWith('/invite')) return {'ok': true, 'state': 'invited', 'membership_id': 40};
  return {'ok': true};
}
