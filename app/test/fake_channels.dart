// channels (2 Nov): gallery + widget-test stubs for My Circle channels /
// communities (directory, my channels, a channel page, communities home, a
// community, a join link). Shapes mirror the server (core.channels_service).

Map<String, dynamic> _ch(int id, String name, String handle, int followers,
        {bool owner = false, bool following = false, bool public = true,
        String desc = ''}) =>
    {
      'id': id, 'channel_id': id, 'name': name, 'handle': handle,
      'description': desc, 'follower_count': followers,
      'is_public': public, 'listed': public, 'is_owner': owner,
      'is_admin': owner, 'can_publish': owner, 'my_following': following,
      'following': following, 'my_muted': false,
      'my_visibility': following ? 'count_only' : null,
      'is_verified': id == 11, 'verification_state': id == 11 ? 'verified' : 'none',
      'category': 'news', 'language': 'bn',
    };

List<Map<String, dynamic>> _dir(bool bn) => [
      _ch(11, bn ? 'ঢাকা বাজারদর' : 'Dhaka Market Prices', 'dhaka_bazar', 12840,
          desc: bn ? 'প্রতিদিন সকালে চাল, ডাল, সবজির দাম' : 'Rice, lentil and vegetable prices every morning'),
      _ch(12, bn ? 'মিরপুর স্কুল নোটিশ' : 'Mirpur School Notices', 'mirpur_school', 2310,
          desc: bn ? 'ছুটি, পরীক্ষা ও ফলাফলের খবর' : 'Holidays, exams and results'),
      _ch(13, bn ? 'নামাজের সময় — ঢাকা' : 'Prayer times — Dhaka', 'namaz_dhaka', 45102),
    ];

Map<String, dynamic>? fakeChannelsGet(String path,
    {required bool bn, required bool empty}) {
  final bare = (path.startsWith('/') ? path.substring(1) : path);
  final p = bare.split('?').first;
  if (p == 'channels') {
    if (empty) {
      return {'owned': [], 'following': [], 'suggested': []};
    }
    return {
      'owned': [
        _ch(21, bn ? 'রহিমের দোকানের অফার' : "Rahim's shop offers", 'rahim_shop', 86,
            owner: true),
        _ch(22, bn ? 'পরিবারের খবর' : 'Family news', 'family_news', 9,
            owner: true, public: false),
      ],
      'following': [_ch(11, bn ? 'ঢাকা বাজারদর' : 'Dhaka Market Prices', 'dhaka_bazar', 12840, following: true)],
      'suggested': _dir(bn).skip(1).toList(),
    };
  }
  if (p == 'channels/discover') {
    final q = bare.contains('q=');
    return {
      'results': q && !empty ? _dir(bn).take(1).toList() : [],
      'suggested': empty ? [] : _dir(bn),
      'categories': ['news', 'religion', 'education', 'local'],
    };
  }
  if (p == 'channels/resolve') {
    return {'channel': _dir(bn).first, ..._dir(bn).first};
  }
  final m = RegExp(r'^channels/(\d+)(/share-link)?$').firstMatch(p);
  if (m != null) {
    final id = int.parse(m.group(1)!);
    if (m.group(2) != null) {
      return {
        'url': 'https://lifeassisto.com/ch/dhaka_bazar',
        'is_public': true, 'handle': 'dhaka_bazar',
      };
    }
    final c = _dir(bn).firstWhere((x) => x['id'] == id,
        orElse: () => _dir(bn).first);
    c['my_following'] = true;
    return {
      'channel': c,
      'can_publish': false,
      'posts': [
        {'id': 501, 'kind': 'text', 'text': bn ? 'আজ আলু ৪০ টাকা, পেঁয়াজ ৯০ টাকা কেজি।' : 'Potato 40 tk, onion 90 tk per kg today.',
         'reactions': {'👍': 214, '❤️': 31}, 'views': 5120, 'pinned': true,
         'created_at': '2026-11-02T03:10:00Z', 'media_refs': [], 'link_url': null},
        {'id': 500, 'kind': 'text', 'text': bn ? 'কাল সকাল ৮টায় নতুন দাম।' : 'New prices tomorrow 8 am.',
         'reactions': {'👍': 98}, 'views': 4410, 'pinned': false,
         'created_at': '2026-11-01T03:10:00Z', 'media_refs': [], 'link_url': null},
      ],
    };
  }
  if (p == 'communities') {
    if (empty) return {'results': [], 'requested': []};
    return {
      'results': [
        {'id': 31, 'name': bn ? 'মিরপুর ১০ প্রতিবেশী' : 'Mirpur 10 neighbours',
         'description': bn ? 'ব্লক সি — বাজার, নিরাপত্তা, পানি-বিদ্যুৎ' : 'Block C — market, security, utilities',
         'viewer_role': 'admin', 'member_count': 124, 'group_count': 4,
         'invite_url': 'https://lifeassisto.com/cm/k7m2p9q4rt'},
        {'id': 32, 'name': bn ? 'ক্লাস ৫ অভিভাবক' : 'Class 5 parents',
         'description': bn ? 'স্কুলের নোটিশ ও হোমওয়ার্ক' : 'School notices and homework',
         'viewer_role': 'member', 'member_count': 38, 'group_count': 2},
      ],
      'requested': [
        {'id': 33, 'name': bn ? 'অফিস ক্রিকেট ক্লাব' : 'Office cricket club',
         'description': '', 'state': 'requested'},
      ],
    };
  }
  if (p == 'communities/preview') {
    return {'id': 34, 'name': bn ? 'বনানী মসজিদ কমিটি' : 'Banani mosque committee',
            'description': bn ? 'নামাজ, দান ও অনুষ্ঠানের খবর' : 'Prayers, charity and events',
            'member_count': 312, 'group_count': 3, 'viewer_role': null,
            'state': 'none'};
  }
  final g = RegExp(r'^community/(\d+)/(groups|invite)$').firstMatch(p);
  if (g != null) {
    if (g.group(2) == 'invite') {
      return {'url': 'https://lifeassisto.com/cm/k7m2p9q4rt', 'code': 'k7m2p9q4rt'};
    }
    return {
      'viewer_role': 'admin',
      'joined': [
        {'id': 41, 'name': bn ? 'ঘোষণা' : 'Announcements', 'kind': 'announcements',
         'join_mode': 'request', 'member_count': 124, 'circle_group_id': 901,
         'announcements_only': true},
        {'id': 42, 'name': bn ? 'বাজার ও দাম' : 'Bazar & prices', 'kind': 'topic',
         'join_mode': 'open', 'member_count': 88, 'circle_group_id': 902},
      ],
      'joinable': [
        {'id': 43, 'name': bn ? 'রাতের পাহারা' : 'Night security', 'kind': 'topic',
         'join_mode': 'request', 'member_count': 17, 'action': 'request'},
      ],
      'requested': [],
      'join_requests': [
        {'id': 71, 'group_id': 41, 'group_name': bn ? 'ঘোষণা' : 'Announcements',
         'requester_name': bn ? 'সালমা আক্তার' : 'Salma Akter'},
      ],
    };
  }
  return null;
}

Map<String, dynamic>? fakeChannelsPost(String path, Map<String, dynamic> body) {
  final p = (path.startsWith('/') ? path.substring(1) : path).split('?').first;
  if (p == 'communities/join') return {'state': 'requested', 'id': 34};
  if (p == 'community/create') {
    return {'id': 35, 'name': body['name'] ?? '', 'viewer_role': 'admin',
            'community': {'id': 35, 'name': body['name'] ?? '', 'viewer_role': 'admin'}};
  }
  if (RegExp(r'^channels/\d+/(follow|unfollow|block|mute)$').hasMatch(p)) {
    return {'ok': true};
  }
  return null;
}
