import 'package:assisto/world/world_api.dart';

/// p4-world: an in-memory [WorldApi] for widget tests and the screenshot
/// gallery. Shapes mirror backend/core/world_service.py + views_world.py.
/// Headlines are obviously-sample test text (no real publisher content).
class FakeWorldApi implements WorldApi {
  FakeWorldApi(
      {this.lang = 'en',
      this.searchReady = true,
      this.alertsReady = false,
      this.photoReady = false,
      this.aiReady = true,
      this.sportsReady = false});
  final String lang;
  bool searchReady;
  bool alertsReady;
  bool photoReady;
  bool aiReady;
  bool sportsReady;
  final Map<String, bool> cards = {
    'prayer': true,
    'weather': true,
    'currency': true,
    'gold': true,
    'fuel': true,
    'news_bd': true,
    'news_world': true,
    'cricket': true,
    'football': true,
  };
  final List<Map<String, dynamic>> saved = [];
  int asks = 0;

  bool get _bn => lang == 'bn';
  String _s(String bn, String en) => _bn ? bn : en;

  @override
  Future<Map<String, dynamic>> config() async => {
        '_status': 200,
        'search_ready': searchReady,
        'web_answer_credits': 4,
        'sports': {'cricket': sportsReady, 'football': sportsReady},
        'job_alerts_ready': alertsReady,
        'prefs': {
          'cards': Map<String, bool>.from(cards),
          'city': 'dhaka',
          'job_types': ['it'],
          'job_alerts': false
        },
        'cities': [
          {'id': 'dhaka', 'name': _s('ঢাকা', 'Dhaka')},
          {'id': 'sylhet', 'name': _s('সিলেট', 'Sylhet')},
        ],
      };

  @override
  Future<Map<String, dynamic>> today() async {
    final c = <String, dynamic>{};
    if (cards['prayer']!) {
      c['prayer'] = {
        'times': {
          'fajr': '04:41',
          'sunrise': '05:56',
          'dhuhr': '11:39',
          'asr': '15:51',
          'maghrib': '17:22',
          'isha': '18:37'
        },
        'next': 'maghrib',
        'note': _s(
            'স্থানীয় হিসাব — আপনার মসজিদের সময়ের সাথে কয়েক মিনিট পার্থক্য হতে পারে।',
            'Local calculation — may differ by a few minutes from your mosque.'),
      };
    }
    if (cards['weather']!) {
      c['weather'] = {
        'temp': 28.4,
        'humidity': 64,
        'wind': 2.1,
        'label': _s('আংশিক মেঘলা', 'Partly cloudy'),
        'next': [
          {
            'time': '2026-10-24T00:00:00Z',
            'temp': 25.1,
            'label': _s('পরিষ্কার আকাশ', 'Clear sky')
          },
          {
            'time': '2026-10-24T06:00:00Z',
            'temp': 31.0,
            'label': _s('মোটামুটি পরিষ্কার', 'Fair')
          },
        ],
        'updated': '2026-10-23T13:18:17Z',
        'source': 'MET Norway (CC BY 4.0)',
        'source_url': 'https://api.met.no/',
      };
    }
    if (cards['currency']!) {
      c['currency'] = {
        'rows': [
          {
            'code': 'USD',
            'name': _s('মার্কিন ডলার', 'US dollar'),
            'bdt': 123.71
          },
          {
            'code': 'SAR',
            'name': _s('সৌদি রিয়াল', 'Saudi riyal'),
            'bdt': 32.99
          },
          {
            'code': 'MYR',
            'name': _s('মালয়েশিয়ান রিংগিত', 'Malaysian ringgit'),
            'bdt': 30.3
          },
        ],
        'updated': '2026-10-23T00:02:31+00:00',
        'source': 'ExchangeRate-API',
        'source_url': 'https://www.exchangerate-api.com',
        'note': _s(
            'বাজার দরের নির্দেশক হার — ব্যাংক/মানি এক্সচেঞ্জের হার আলাদা হতে পারে।',
            'Indicative market rate — bank and exchange-house rates differ.'),
      };
    }
    if (cards['gold']!) {
      c['gold'] = {
        'rows': [
          {
            'key': 'gold_22k',
            'label': _s('২২ ক্যারেট সোনা (প্রতি ভরি)', 'Gold 22K (per bhori)'),
            'bdt': 150000.0
          },
        ],
        'updated': '2026-10-20',
        'source': _s('বাংলাদেশ জুয়েলার্স অ্যাসোসিয়েশন (বাজুস)',
            'Bangladesh Jewellers Association (BAJUS)'),
        'source_url': 'https://www.bajus.org/gold-price',
        'entered_by_assisto': true,
      };
    }
    if (cards['news_bd']!) {
      c['news_bd'] = {
        'items': [
          {
            'title': _s('নমুনা শিরোনাম: নতুন সেতুর কাজ শুরু',
                'Sample headline: work begins on a new bridge'),
            'snippet': _s('এটি গ্যালারির নমুনা সারাংশ।',
                'This is a gallery sample summary.'),
            'link': 'https://www.bbc.com/bengali',
            'published': '2026-10-23T12:47:54+00:00',
            'source': _s('বিবিসি বাংলা', 'BBC Bangla')
          },
          {
            'title': _s('নমুনা শিরোনাম: বৃষ্টির পূর্বাভাস',
                'Sample headline: rain forecast for the weekend'),
            'snippet': '',
            'link': 'https://www.prothomalo.com',
            'published': '2026-10-23T10:00:00+00:00',
            'source': _s('প্রথম আলো', 'Prothom Alo')
          },
        ],
      };
    }
    final hidden = <String, String>{};
    if (cards['fuel']!) hidden['fuel'] = 'not_entered';
    if (cards['news_world']!) hidden['news_world'] = 'unavailable';
    if (cards['cricket']!) hidden['cricket'] = 'needs_key';
    if (cards['football']!) hidden['football'] = 'needs_key';
    return {
      '_status': 200,
      'city': {'id': 'dhaka', 'name': _s('ঢাকা', 'Dhaka')},
      'cards': c,
      'hidden': hidden,
      'on': Map<String, bool>.from(cards),
    };
  }

  @override
  Future<Map<String, dynamic>> savePrefs(Map<String, dynamic> body) async {
    saved.add(body);
    final cs = body['cards'];
    if (cs is Map) {
      cs.forEach((k, v) {
        if (cards.containsKey(k) && v is bool) cards['$k'] = v;
      });
    }
    return {'_status': 200, 'cards': cards};
  }

  @override
  Future<Map<String, dynamic>> ask(String question, String lang) async {
    asks++;
    return {
      '_status': 200,
      'ok': true,
      'answer': _s(
          'ই-পাসপোর্ট নবায়নের আবেদন অনলাইনে করা যায় [1]। ফি পাতা ও মেয়াদ অনুযায়ী আলাদা [2]।',
          'You can apply to renew an e-passport online [1]. The fee depends on pages and validity [2].'),
      'sources': [
        {
          'n': 1,
          'title': 'e-Passport Online Registration',
          'url': 'https://www.epassport.gov.bd',
          'site': 'epassport.gov.bd'
        },
        {
          'n': 2,
          'title': 'Passport fees',
          'url': 'https://www.epassport.gov.bd/instructions/passport-fees',
          'site': 'epassport.gov.bd'
        },
      ],
      'caution': <String>[],
      'cited': true,
      'cached': false,
      'charged': 4,
      'balance': 16,
    };
  }

  @override
  Future<Map<String, dynamic>> jobs() async => {
        '_status': 200,
        'categories': [
          {'id': 'govt', 'name': _s('সরকারি', 'Government')},
          {'id': 'bank', 'name': _s('ব্যাংক', 'Bank')},
          {'id': 'private', 'name': _s('বেসরকারি', 'Private')},
          {'id': 'overseas', 'name': _s('বিদেশে চাকরি', 'Overseas')},
          {'id': 'ngo', 'name': _s('এনজিও', 'NGO')},
        ],
        'portals': [
          {
            'id': 'bpsc',
            'cat': 'govt',
            'url': 'https://bpsc.gov.bd',
            'name': _s('বাংলাদেশ সরকারি কর্ম কমিশন (BPSC)',
                'Bangladesh Public Service Commission (BPSC)'),
            'desc': _s(
                'বিসিএস ও নন-ক্যাডার নিয়োগ বিজ্ঞপ্তি, পরীক্ষার সূচি ও ফল।',
                'BCS and non-cadre circulars, exam schedules and results.'),
            'feed': false
          },
          {
            'id': 'bdjobs',
            'cat': 'private',
            'url': 'https://www.bdjobs.com',
            'name': _s('বিডিজবস', 'Bdjobs.com'),
            'desc': _s(
                'দেশের বড় বেসরকারি চাকরির পোর্টাল; সিভি তৈরি ও আবেদন সেখানেই।',
                "The country's large private-sector job portal; build your CV and apply there."),
            'feed': false
          },
          {
            'id': 'boesl',
            'cat': 'overseas',
            'url': 'https://www.boesl.gov.bd',
            'name': _s('বোয়েসেল (সরকারি রিক্রুটিং এজেন্সি)',
                'BOESL (government recruiting agency)'),
            'desc': _s(
                'সরকারি ব্যবস্থাপনায় বিদেশে চাকরি — কম খরচে, প্রতারণার ঝুঁকি কম।',
                'Overseas jobs through the government agency — low cost, less fraud risk.'),
            'feed': false
          },
        ],
        'types': [
          {'id': 'govt', 'name': _s('সরকারি চাকরি', 'Government jobs')},
          {'id': 'it', 'name': _s('আইটি / সফটওয়্যার', 'IT / software')},
        ],
        'safety': _s('চাকরির জন্য কাউকে আগাম টাকা দেবেন না।',
            'Never pay anyone upfront for a job.'),
        'feeds_note': _s(
            'শুধু ক্যারিয়ারজেটের অফিশিয়াল পার্টনার API থেকে সতর্কতা আসে।',
            "Alerts come only from Careerjet's official partner API."),
        'reviewed': '2026-10-23',
        'alerts_ready': alertsReady,
        'prefs': {
          'job_alerts': false,
          'job_types': ['it']
        },
      };

  @override
  Future<Map<String, dynamic>> hub(String id) async {
    Map<String, dynamic> item(String iid, String bn, String en,
            {bool fee = false}) =>
        {
          'id': iid,
          'kind': 'guide',
          'reviewed': '2026-10-23',
          'title': _s(bn, en),
          'body':
              _s('এটি গ্যালারির নমুনা লেখা।', 'This is gallery sample text.'),
          'steps': [
            _s('প্রথম ধাপ', 'First step'),
            _s('দ্বিতীয় ধাপ', 'Second step')
          ],
          if (fee)
            'fee': _s('ফি অফিশিয়াল সাইটে যাচাই করুন।',
                'Verify the fee on the official site.'),
          if (fee) 'fee_source': 'https://www.epassport.gov.bd',
          'links': [
            {
              'label': _s('অফিশিয়াল সাইট', 'Official site'),
              'url': 'https://bangladesh.gov.bd'
            }
          ],
        };
    final sections = switch (id) {
      'expat' => [
          {
            'id': 'steps',
            'title': _s('বিদেশ যাওয়ার ধাপ', 'Steps before you go'),
            'items': [
              item('steps', 'সবার জন্য জরুরি ধাপ', 'Must-do steps for everyone')
            ]
          },
          {
            'id': 'visa',
            'title': _s('দেশভিত্তিক ভিসার মূল কথা', 'Visa basics by country'),
            'items': [
              item('ksa', 'সৌদি আরব', 'Saudi Arabia'),
              item('uae', 'সংযুক্ত আরব আমিরাত', 'United Arab Emirates')
            ]
          },
        ],
      'gov' => [
          {
            'id': 'services',
            'title': _s('সেবাগুলো', 'Services'),
            'items': [
              item('epassport', 'ই-পাসপোর্ট', 'e-Passport', fee: true),
              item('nid', 'জাতীয় পরিচয়পত্র (NID)', 'National ID (NID)',
                  fee: true)
            ]
          },
        ],
      _ => [
          {
            'id': 'help',
            'title': _s('সরাসরি পরামর্শ', 'Talk to an expert'),
            'items': [
              item('call', 'কৃষি কল সেন্টার ১৬১২৩', 'Krishi Call Centre 16123')
            ]
          },
        ],
    };
    return {
      '_status': 200,
      'id': id,
      'intro': _s('গ্যালারির নমুনা পরিচিতি।', 'Gallery sample introduction.'),
      'sections': sections,
      'screens': id == 'farmers'
          ? ['farmer_mode']
          : (id == 'health' ? ['medicine_db'] : <String>[]),
      'photo': id == 'farmers' ? 'crop' : (id == 'health' ? 'rx' : ''),
      'photo_ready': photoReady,
      'ai': id != 'health',
      'ai_ready': aiReady && id != 'health',
      'form_help': id == 'gov',
      'medicine_price_ready': false,
      'verify': _s(
          'তথ্য বদলাতে পারে — সিদ্ধান্তের আগে সরকারি/অফিশিয়াল সাইটে যাচাই করুন।',
          'Details can change — verify on the official site before you act.'),
      'reviewed': '2026-10-23',
    };
  }

  @override
  Future<Map<String, dynamic>> hubAi(
          String id, String question, String lang) async =>
      {
        '_status': 200,
        'ok': true,
        'answer': _s('নমুনা উত্তর।', 'Sample answer.'),
        'note': _s(
            'Assisto কোনো ফর্ম জমা দেয় না।', 'Assisto never submits a form.'),
      };

  @override
  Future<Map<String, dynamic>> mcq(String topic) async => {
        '_status': 200,
        'topics': [
          {
            'id': 'gk',
            'name':
                _s('বাংলাদেশ ও সাধারণ জ্ঞান', 'Bangladesh & general knowledge')
          },
          {'id': 'math', 'name': _s('গণিত', 'Maths')},
          {'id': 'mixed', 'name': _s('সব বিষয় মিলিয়ে', 'All topics mixed')},
        ],
        'topic': topic,
        'questions': [
          {
            'id': 'gk01',
            'topic': 'gk',
            'q': _s('বাংলাদেশের রাজধানী কোনটি?',
                'What is the capital of Bangladesh?'),
            'options': [
              _s('চট্টগ্রাম', 'Chattogram'),
              _s('ঢাকা', 'Dhaka'),
              _s('খুলনা', 'Khulna'),
              _s('রাজশাহী', 'Rajshahi')
            ]
          },
          {
            'id': 'ma05',
            'topic': 'math',
            'q': _s('১৪৪-এর বর্গমূল কত?', 'What is the square root of 144?'),
            'options': [
              _s('১১', '11'),
              _s('১২', '12'),
              _s('১৩', '13'),
              _s('১৪', '14')
            ]
          },
        ],
        'history': [
          {
            'topic': 'gk',
            'total': 10,
            'correct': 7,
            'at': '2026-10-22T15:00:00Z'
          },
        ],
      };

  @override
  Future<Map<String, dynamic>> mcqSubmit(String topic,
          List<Map<String, dynamic>> answers, String lang) async =>
      {
        '_status': 200,
        'total': 2,
        'correct': answers
            .where((a) =>
                (a['id'] == 'gk01' && a['choice'] == 1) ||
                (a['id'] == 'ma05' && a['choice'] == 1))
            .length,
        'results': [
          {
            'id': 'gk01',
            'q': _s('বাংলাদেশের রাজধানী কোনটি?',
                'What is the capital of Bangladesh?'),
            'options': [
              _s('চট্টগ্রাম', 'Chattogram'),
              _s('ঢাকা', 'Dhaka'),
              _s('খুলনা', 'Khulna'),
              _s('রাজশাহী', 'Rajshahi')
            ],
            'answer': 1,
            'choice': 1,
            'correct': true,
            'why': _s('ঢাকা বাংলাদেশের রাজধানী।', 'Dhaka is the capital.')
          },
        ],
        'history': [
          {
            'topic': topic,
            'total': 2,
            'correct': 1,
            'at': '2026-10-23T15:00:00Z'
          },
        ],
      };
}
