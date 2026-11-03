// p2career: fake /career/* answers for the gallery + widget tests. Shapes
// mirror backend core/views_career.py + core/career_service.py.

Map<String, dynamic> fakeCareerStatus({required bool bn}) => {
      'enabled': true,
      'ai_ready': false,
      'careerjet_ready': false,
      'formats': ['fresher', 'experienced', 'govt'],
      'cv_langs': ['en', 'bn'],
      'roles': fakeCareerRoles(bn: bn),
      'portals': [
        {
          'id': 'bpsc', 'cat': 'govt', 'url': 'https://bpsc.gov.bd', 'feed': false,
          'name': bn ? 'বাংলাদেশ সরকারি কর্ম কমিশন (BPSC)' : 'Bangladesh Public Service Commission (BPSC)',
          'desc': bn ? 'বিসিএস ও নন-ক্যাডার নিয়োগ বিজ্ঞপ্তি, পরীক্ষার সূচি ও ফল।' : 'BCS and non-cadre circulars, exam schedules and results.',
        },
        {
          'id': 'bdjobs', 'cat': 'private', 'url': 'https://www.bdjobs.com', 'feed': false,
          'name': bn ? 'বিডিজবস' : 'Bdjobs.com',
          'desc': bn ? 'দেশের বড় বেসরকারি চাকরির পোর্টাল; সিভি তৈরি ও আবেদন সেখানেই।' : "The country's large private-sector job portal; build your CV and apply there.",
        },
      ],
      'safety': bn
          ? 'চাকরির জন্য কাউকে আগাম টাকা দেবেন না। সরকারি চাকরির আবেদন ফি শুধু অফিশিয়াল পোর্টালে দিন।'
          : 'Never pay anyone upfront for a job. Pay government application fees only on the official portal.',
      'feeds_note': bn
          ? 'শুধু ক্যারিয়ারজেটের অফিশিয়াল পার্টনার API থেকে চাকরি আসে। বাকি সাইটগুলো শুধু লিংক — আমরা কোনো সাইট স্ক্র্যাপ করি না।'
          : "Jobs come only from Careerjet's official partner API. The other sites are links only — we never scrape any site.",
      'ai_caps': {'interview': 20, 'polish': 10},
    };

List<Map<String, dynamic>> fakeCareerRoles({required bool bn}) => [
      {'id': 'fresher', 'name': bn ? 'ফ্রেশার (প্রথম চাকরি)' : 'Fresher (first job)', 'count': 6},
      {'id': 'bank', 'name': bn ? 'ব্যাংক অফিসার' : 'Bank officer', 'count': 6},
      {'id': 'it', 'name': bn ? 'আইটি / সফটওয়্যার' : 'IT / software', 'count': 6},
      {'id': 'govt_viva', 'name': bn ? 'সরকারি চাকরির ভাইভা (BCS-ধাঁচ)' : 'Government job viva (BCS style)', 'count': 6},
    ];

Map<String, dynamic> fakeCareerRole({required bool bn}) => {
      'id': 'bank',
      'name': bn ? 'ব্যাংক অফিসার' : 'Bank officer',
      'questions': [
        {
          'id': 'bk3',
          'text': bn ? 'একজন রাগী গ্রাহককে কীভাবে সামলাবেন?' : 'How would you handle an angry customer?',
          'outline': bn
              ? 'মন দিয়ে শোনা → সহানুভূতি → সমাধান/সময়সীমা → পরে খোঁজ নেওয়া'
              : 'Listen → empathise → solution with a timeline → follow up',
        },
        {
          'id': 'bk1',
          'text': bn ? 'ব্যাংকে কেন চাকরি করতে চান?' : 'Why do you want to work in a bank?',
          'outline': bn ? 'বর্তমান অবস্থা → পড়াশোনা → একটা অর্জন → কেন এই পদ' : 'Present → study → one achievement → why this role',
        },
      ],
    };

Map<String, dynamic> fakeCareerFeedback({required bool ai}) => {
      'rubric': {
        'score': 75, 'words': 52, 'has_example': true, 'fillers': 0,
        'hits': [{'bn': 'শুন', 'en': 'listen'}, {'bn': 'শান্ত', 'en': 'calm'}, {'bn': 'সমাধান', 'en': 'solution'}],
        'missing': [{'bn': 'দুঃখ', 'en': 'apolog'}, {'bn': 'ফলো', 'en': 'follow'}],
        'tips': ['cover_topics'], 'outline': {'bn': '', 'en': ''}, 'rubric': 'career-rubric-1',
      },
      'ai': ai ? {'ai_used': false, 'reason': 'no_key', 'message': 'AI'} : null,
    };

Map<String, dynamic>? fakeCareerGet(String path, {required bool bn, required bool empty}) {
  final p = path.split('?').first;
  if (p == '/career/status') return fakeCareerStatus(bn: bn);
  if (p == '/career/cv/ats') {
    return {
      'score': empty ? 22 : 78,
      'checks': [
        {'id': 'name', 'ok': true}, {'id': 'phone', 'ok': true}, {'id': 'email', 'ok': !empty},
        {'id': 'summary', 'ok': false}, {'id': 'education', 'ok': true}, {'id': 'skills', 'ok': !empty},
        {'id': 'experience', 'ok': true}, {'id': 'numbers', 'ok': false}, {'id': 'length', 'ok': true},
      ],
    };
  }
  if (p == '/career/cv/prefill') return {'name': 'Rahim Uddin', 'phone': '01711000000', 'email': 'rahim@example.com'};
  if (p == '/career/interview/roles') return {'roles': empty ? <Map<String, dynamic>>[] : fakeCareerRoles(bn: bn)};
  if (p.startsWith('/career/interview/roles/')) return fakeCareerRole(bn: bn);
  if (p == '/career/jobs/search') {
    return {
      'jobs': empty
          ? <Map<String, dynamic>>[]
          : [
              {'title': 'Accounts Officer', 'company': 'Acme Foods', 'url': 'https://boards.greenhouse.io/acme/jobs/1',
               'location': bn ? 'ঢাকা' : 'Dhaka', 'posted': '', 'source': 'Acme Foods', 'source_kind': 'greenhouse'},
            ],
      'sources': [
        {'id': 'careerjet', 'label': 'Careerjet', 'kind': 'careerjet', 'ok': false, 'count': 0, 'error': 'not_connected'},
        {'id': 3, 'label': 'Acme Foods', 'kind': 'greenhouse', 'ok': true, 'count': empty ? 0 : 1, 'error': ''},
      ],
    };
  }
  return null;
}

List<Map<String, dynamic>>? fakeCareerList(String path, {required bool bn}) {
  if (path == 'career/searches') {
    return [
      {'id': 1, 'q': bn ? 'হিসাবরক্ষক' : 'accountant', 'loc': bn ? 'ঢাকা' : 'Dhaka', 'saved_at': '2026-11-03'},
    ];
  }
  if (path == 'career/sources') {
    return [
      {'id': 3, 'kind': 'greenhouse', 'value': 'acme', 'label': 'Acme Foods'},
      {'id': 4, 'kind': 'link', 'value': 'https://example.com/careers', 'label': 'Example Ltd'},
    ];
  }
  return null;
}
