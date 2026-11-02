// adminsafe: Account status fakes in the server's real shape
// (backend core/admin_safety.standing()).

Map<String, dynamic> fakeStandingRestricted({bool bn = false}) => {
      'status': 'active',
      'until': null,
      'restrictions': [
        {
          'kind': 'stranger_msg',
          'until': '2026-11-10T06:00:00+00:00',
          'reason': bn ? 'অনেকে অনাকাঙ্ক্ষিত মেসেজের রিপোর্ট করেছেন' : 'Many people reported unwanted messages',
        },
      ],
      'notices': [
        {
          'id': 7,
          'kind': 'restrict',
          'reason': bn ? 'অনেকে অনাকাঙ্ক্ষিত মেসেজের রিপোর্ট করেছেন' : 'Many people reported unwanted messages',
          'at': '2026-11-03T06:00:00+00:00',
          'until': '2026-11-10T06:00:00+00:00',
          'appealable': false,
          'appeal': {'state': 'open', 'created_at': '2026-11-03T08:00:00+00:00', 'decision_note': ''},
        },
        {
          'id': 5,
          'kind': 'warn',
          'reason': bn ? 'চ্যানেলে বারবার একই বিজ্ঞাপন' : 'The same advert posted again and again',
          'at': '2026-11-01T06:00:00+00:00',
          'until': null,
          'appealable': true,
          'appeal': null,
        },
      ],
      'can_appeal': true,
    };

Map<String, dynamic> fakeStandingEmpty() => {
      'status': 'active',
      'until': null,
      'restrictions': <Map<String, dynamic>>[],
      'notices': <Map<String, dynamic>>[],
      'can_appeal': false,
    };

/// The sign-in 403 body of a suspended account.
Map<String, dynamic> fakeBlockedBody({bool bn = false, bool banned = false}) => {
      'reason': 'account_blocked',
      'detail': bn ? 'এই অ্যাকাউন্টটি বন্ধ করা হয়েছে।' : 'This account is blocked.',
      'appeal_token': 'tok123',
      'standing': {
        'status': banned ? 'banned' : 'suspended',
        'until': banned ? null : '2026-11-10T06:00:00+00:00',
        'restrictions': <Map<String, dynamic>>[],
        'notices': [
          {
            'id': 9,
            'kind': banned ? 'ban' : 'suspend',
            'reason': bn ? 'প্রতারণার চেষ্টা — একাধিক রিপোর্ট' : 'Scam attempts — several reports',
            'at': '2026-11-03T06:00:00+00:00',
            'until': banned ? null : '2026-11-10T06:00:00+00:00',
            'appealable': true,
            'appeal': null,
          },
        ],
        'can_appeal': true,
      },
    };
