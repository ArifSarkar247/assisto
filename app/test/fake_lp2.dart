// lpapp: gallery / widget-test fakes for Language Partner V2
// (owner_actions/LANGUAGE_PARTNER_API.md). Made-up sample content only —
// original practice items written for the fakes, nothing from any book.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/screens/ielts_engine.dart' show ieltsToday;

const Map<String, String> _label = {
  'en': 'Practice score — not an official IELTS result.',
  'bn': 'অনুশীলনের স্কোর — অফিসিয়াল IELTS ফল নয়।',
};

/// Records every POST the screens made (tests assert on them).
final List<Map<String, dynamic>> lp2Posts = [];

/// The bundled Life English file (test cwd = app/).
Map<String, dynamic> lp2Life() =>
    jsonDecode(File('assets/lp/life_en_v1.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> lp2Scenario(String id) =>
    ((lp2Life()['scenarios'] as List).cast<Map<String, dynamic>>()).firstWhere((s) => s['id'] == id);

List<Map<String, dynamic>> fakeLp2List(String path) {
  final t = ieltsToday();
  if (path == 'lp/days') {
    return [
      {'id': 1, 'day': t - 2, 'kind': 'vocab', 'minutes': 8},
      {'id': 2, 'day': t - 1, 'kind': 'life:airport', 'minutes': 10},
      {'id': 3, 'day': t, 'kind': 'life:bank', 'minutes': 10},
    ];
  }
  if (path == 'lp/results') {
    return [
      {'id': 1, 'kind': 'mock', 'mock_id': 'ac-001', 'overall': 6.5, 'at': 1, 'weak': ['tfng', 'spelling']},
    ];
  }
  if (path == 'lp/vocab') {
    return [
      {'id': 1, 'card_id': 'ielts_education_curriculum', 'box': 3, 'due': t + 3},
      {'id': 2, 'card_id': 'ielts_education_compulsory', 'box': 1, 'due': t},
    ];
  }
  return const [];
}

Map<String, dynamic> _q(int n, String type, String prompt, {List<String>? options, int? maxWords, String? group}) => {
      'n': n,
      'type': type,
      'prompt': prompt,
      if (options != null) 'options': options,
      if (maxWords != null) 'max_words': maxWords,
      if (group != null) 'group': group,
    };

Map<String, dynamic> fakeLp2Mock({String section = ''}) {
  final all = <String, dynamic>{
    'listening': {
      'duration_sec': 1800,
      'parts': [
        {
          'n': 1,
          'audio_url': 'https://lifeassisto.com/media/lp/sample-part1.mp3',
          'questions': [
            _q(1, 'gap', 'The caller wants to book a room for ______ nights.', maxWords: 1,
                group: 'Questions 1–3: write ONE WORD AND/OR A NUMBER.'),
            _q(2, 'gap', 'The guest\'s surname is ______.', maxWords: 1),
            _q(3, 'mcq', 'Breakfast is served', options: ['A. in the room', 'B. in the garden', 'C. in the main hall']),
          ],
        },
      ],
    },
    'reading': {
      'duration_sec': 3600,
      'passages': [
        {
          'n': 1,
          'title': 'Floating gardens of the delta',
          'text': 'In low-lying river deltas, some farmers grow vegetables on rafts made of water hyacinth. '
              'The rafts rise with flood water, so crops survive the rainy season. Farmers say the method '
              'needs no chemical fertiliser because the rotting plants feed the soil. Researchers are now '
              'testing whether the rafts can also support small fish ponds.',
          'questions': [
            _q(1, 'tfng', 'The rafts sink when the water rises.',
                group: 'Questions 1–3: TRUE, FALSE or NOT GIVEN?'),
            _q(2, 'tfng', 'Floating gardens need chemical fertiliser.'),
            _q(3, 'tfng', 'The government pays farmers to build rafts.'),
            _q(4, 'gap', 'The rafts are made of water ______.', maxWords: 1,
                group: 'Question 4: ONE WORD ONLY.'),
          ],
        },
      ],
    },
    'writing': {
      'duration_sec': 3600,
      'tasks': [
        {'n': 1, 'min_words': 150, 'prompt': 'The chart shows how people in one city travelled to work in 2005 and 2025. Summarise the main features.'},
        {'n': 2, 'min_words': 250, 'prompt': 'Some people think young people should learn a trade instead of going to university. Discuss both views and give your opinion.'},
      ],
    },
    'speaking': {
      'parts': [
        {'n': 1, 'questions': ['Where do you live?', 'Do you like cooking?']},
        {'n': 2, 'cue_card': 'Describe a journey you remember well. You should say where you went, how you travelled, who you were with, and explain why you remember it.', 'prep_sec': 60, 'talk_sec': 120},
        {'n': 3, 'questions': ['Why do people travel more today than in the past?']},
      ],
    },
  };
  return {
    'id': 'ac-001',
    'kind': 'academic',
    'beta': true,
    'version': 1,
    if (section.isEmpty) ...all else section: all[section],
  };
}

Map<String, dynamic> fakeLp2Writing({int task = 2}) => {
      'ai_state': 'used',
      'band': task == 1 ? 6.0 : 6.5,
      'criteria': {if (task == 1) 'TA': 6.0 else 'TR': 6.5, 'CC': 6.5, 'LR': 6.0, 'GRA': 6.5},
      'criteria_notes': {
        'CC': {'en': 'Clear paragraphs; link ideas with more variety.', 'bn': 'অনুচ্ছেদ পরিষ্কার; ভাব জোড়ায় আরও বৈচিত্র্য আনুন।'},
        'LR': {'en': 'Some repetition of "important".', 'bn': '"important" শব্দটা বারবার এসেছে।'},
      },
      'corrected': 'Some people believe that young people should learn a trade rather than go to university.',
      'mistakes': [
        {
          'wrong': 'young peoples',
          'right': 'young people',
          'type': 'grammar',
          'en': '"People" is already plural.',
          'bn': '"People" নিজেই বহুবচন, তাই s লাগবে না।'
        },
      ],
      'credits_used': 2,
      'level': 'normal',
      'practice_label': _label,
      'attempt_id': 11,
    };

Map<String, dynamic> fakeLp2Speaking() => {
      'ai_state': 'used',
      'band': 6.0,
      'criteria': {'FC': 6.0, 'LR': 6.0, 'GRA': 5.5, 'P': 6.5},
      'criteria_notes': {
        'FC': {'en': 'Some long pauses.', 'bn': 'মাঝে মাঝে লম্বা বিরতি।'},
      },
      'corrected': 'I live in Dhaka, near a busy market.',
      'mistakes': [
        {'wrong': 'I am live', 'right': 'I live', 'type': 'grammar', 'en': 'No "am" before a main verb.', 'bn': 'মূল ক্রিয়ার আগে "am" বসে না।'},
      ],
      'credits_used': 2,
      'level': 'normal',
      'practice_label': _label,
      'attempt_id': 12,
    };

Map<String, dynamic> fakeLp2Mark(String section) => section == 'listening'
    ? {
        'raw': 30,
        'total': 40,
        'band': 7.0,
        'attempt_id': 21,
        'items': [
          {'n': 1, 'your': '3', 'key': '3', 'correct': true, 'mistake': null, 'explain_en': '', 'explain_bn': ''},
          {'n': 2, 'your': 'Hasen', 'key': 'Hassan', 'correct': false, 'mistake': 'spelling',
           'explain_en': 'The speaker spells it: H-A-S-S-A-N.', 'explain_bn': 'বক্তা বানান করে বলেছেন: H-A-S-S-A-N।'},
        ],
        'weak': ['spelling'],
        'practice_label': _label,
      }
    : {
        'raw': 27,
        'total': 40,
        'band': 6.5,
        'attempt_id': 22,
        'items': [
          {'n': 1, 'your': 'TRUE', 'key': 'FALSE', 'correct': false, 'mistake': 'tfng',
           'explain_en': 'The text says the rafts RISE with the water.', 'explain_bn': 'লেখায় আছে ভেলাগুলো পানির সাথে ওপরে ওঠে।'},
          {'n': 4, 'your': 'hyacinth', 'key': 'hyacinth', 'correct': true, 'mistake': null, 'explain_en': '', 'explain_bn': ''},
        ],
        'weak': ['tfng'],
        'practice_label': _label,
      };

Map<String, dynamic> fakeLp2Finish() => {
      'ai_state': 'used',
      'overall': 6.5,
      'comment_en': 'Strong listening. Reading loses marks on TRUE/FALSE/NOT GIVEN: check whether the text says the opposite (FALSE) or nothing (NOT GIVEN). Two weeks of daily T/F/NG practice can lift Reading to 7.',
      'comment_bn': 'লিসেনিং ভালো। রিডিংয়ে TRUE/FALSE/NOT GIVEN-এ নম্বর কাটছে: লেখায় উল্টো কথা আছে (FALSE) নাকি কিছুই নেই (NOT GIVEN) — সেটা দেখুন। দুই সপ্তাহ প্রতিদিন অনুশীলন করলে রিডিং ৭-এ উঠতে পারে।',
      'weak_areas': [
        {'tag': 'tfng', 'title_en': 'True / False / Not Given', 'title_bn': 'True / False / Not Given'},
      ],
      'result_id': 31,
      'certificate_url': '/api/v1/lp/certificate/31', // gap-lp: full mock -> certificate offered
      'practice_label': _label,
    };


// lpfinish: a going-abroad track (sample data only)
const _trackKinds = {'jlpt_n5', 'jft_basic', 'eps_topik', 'de_a1', 'hsk1', 'fr_a1', 'ar_work'};

Map<String, dynamic> fakeLpTrackSyllabus(String track) => {
      'items': [
        {
          'id': 'syl-$track', 'track': track, 'beta': true,
          'title': {'en': 'Korean for EPS-TOPIK', 'bn': 'EPS-TOPIK-এর জন্য কোরিয়ান'},
          'summary_bn': 'কারখানার কাজের জন্য কোরিয়ান, বাংলায় বোঝানো।',
          'who_for_bn': 'যাঁরা কোরিয়ায় কাজে যেতে চান।',
          'can_do_bn': ['নিজের পরিচয় দিতে পারবেন।'],
          'exam_format': {
            'sections': [
              {'id': 'reading', 'title': {'en': 'Reading', 'bn': 'পড়া'}, 'minutes': 40, 'questions': 20},
              {'id': 'listening', 'title': {'en': 'Listening', 'bn': 'শোনা'}, 'minutes': 30, 'questions': 20},
            ],
            'scoring_bn': '২০০ নম্বরের পরীক্ষা।',
          },
          'weeks': [
            {'week': 1, 'goal_bn': 'শুভেচ্ছা ও পরিচয়', 'lessons': ['ko-w01-l1']},
            {'week': 5, 'goal_bn': 'পরে', 'lessons': [], 'planned': true},
          ],
          'probashi': {'country': 'KR', 'note_bn': 'প্রবাসী অংশে কাজের পথ দেখুন।'},
          'practice_label': {'en': 'Practice course — not official.', 'bn': 'অনুশীলন কোর্স — অফিসিয়াল নয়।'},
        }
      ]
    };

Map<String, dynamic> fakeLpTrackLessons() => {
      'items': [
        {
          'id': 'ko-w01-l1', 'day': 1, 'minutes': 20, 'lang': 'ko', 'beta': true,
          'title': {'en': 'Hello at work', 'bn': 'কাজে শুভেচ্ছা'},
          'goal_bn': 'বসকে শুভেচ্ছা দিতে শিখবেন।',
          'vocab': [
            {'target': '사장님', 'roman': 'sajangnim', 'bn': 'মালিক',
             'example': {'target': '사장님, 안녕하세요?', 'roman': 'sajangnim, annyeonghaseyo?', 'bn': 'বস, শুভ দিন।'}},
          ],
          'grammar': [
            {'pattern': 'N이에요/예요', 'explain_bn': 'পরিচয় দিতে।',
             'examples': [{'target': '저는 민수예요.', 'roman': 'jeoneun minsuyeyo.', 'bn': 'আমি মিনসু।'}]},
          ],
          'practice': {
            'listening': [
              {'id': 'ko-l1-p1', 'script': {'turns': [{'spk': 'A', 'text': '안녕하세요.'}], 'repeat': 1},
               'prompt_bn': 'কী বলল?', 'options': ['안녕하세요', '감사합니다', '미안합니다'], 'answer': 'A',
               'explain_bn': 'শুভেচ্ছা বলল।'},
            ],
            'reading': [
              {'id': 'ko-l1-r1', 'passage': '저는 민수예요.', 'prompt_bn': 'নাম কী?', 'options': ['민수', '사장님', '회사'],
               'answer': 'A', 'explain_bn': 'মিনসু।'},
            ],
            'writing': [
              {'id': 'ko-l1-w1', 'prompt_bn': 'নিজের নাম লিখুন।', 'model': {'target': '저는 민수예요.', 'bn': 'আমি মিনসু।'}},
            ],
            'speaking': [
              {'id': 'ko-l1-s1', 'prompt_bn': 'জোরে বলুন।', 'model': {'target': '안녕하세요.', 'bn': 'শুভ দিন।'}},
            ],
          },
          'practice_label': {'en': 'Practice course — not official.', 'bn': 'অনুশীলন কোর্স — অফিসিয়াল নয়।'},
        }
      ]
    };

Map<String, dynamic> fakeLpTrackMocks(String track) => {
      'mocks': [
        {'id': 'eps-topik-001', 'title_en': 'EPS-TOPIK practice test 1', 'title_bn': 'EPS-TOPIK অনুশীলন টেস্ট ১',
         'kind': track, 'exam': 'EPS-TOPIK', 'beta': true, 'sections': ['reading', 'listening']},
      ],
      'free_sections_left_week': 1,
      'premium': false,
    };

Map<String, dynamic> fakeLpTrackTest(String section) => {
      'id': 'eps-topik-001', 'kind': 'eps_topik', 'lang': 'ko', 'beta': true,
      'title_en': 'EPS-TOPIK practice test 1', 'title_bn': 'EPS-TOPIK অনুশীলন টেস্ট ১',
      'scoring': {'max': 200, 'per_question': 4, 'pass_hint_bn': 'পাস নম্বর কোম্পানি ঠিক করে।',
                  'note_bn': 'প্র্যাকটিস স্কোর — অফিসিয়াল ফল নয়।'},
      'sections': [
        {
          'id': section, 'kind': section, 'minutes': 40,
          'title': {'en': 'Reading', 'bn': 'পড়া'},
          'parts': [
            {
              'part': 'r1', 'instructions': {'target': '알맞은 것을 고르십시오.', 'bn': 'সঠিকটি বাছুন।'},
              'questions': [
                {'n': 1, 'prompt': '이것은 무엇입니까?', 'options': ['모자', '신발', '가방', '시계'],
                 if (section == 'listening') 'tts': {'lang': 'ko-KR', 'lines': ['이것은 가방입니다.'], 'repeat': 2}},
                {'n': 2, 'prompt': '어디에서 일합니까?', 'options': ['공장', '병원', '학교', '은행']},
              ],
            }
          ],
        }
      ],
    };

Map<String, dynamic>? fakeLp2Get(String path, {bool bn = false}) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  // lpfinish
  final qp = Uri.parse('/$p').queryParameters;
  if (p.startsWith('lp/content/syllabus')) return fakeLpTrackSyllabus(qp['track'] ?? 'eps_topik');
  if (p.startsWith('lp/content/lesson')) return fakeLpTrackLessons();
  if (p.startsWith('lp/mocks?') && _trackKinds.contains(qp['kind'])) return fakeLpTrackMocks(qp['kind']!);
  if (p.startsWith('lp/mocks/eps-topik-001')) return fakeLpTrackTest(qp['section'] ?? 'reading');
  if (p.startsWith('lp/mocks?')) {
    return {
      'mocks': [
        {'id': 'ac-001', 'title_en': 'Academic mock 1', 'title_bn': 'অ্যাকাডেমিক মক ১', 'kind': 'academic', 'beta': true,
         'sections': ['listening', 'reading', 'writing', 'speaking']},
        {'id': 'ac-002', 'title_en': 'Academic mock 2', 'title_bn': 'অ্যাকাডেমিক মক ২', 'kind': 'academic', 'beta': false,
         'sections': ['listening', 'reading', 'writing', 'speaking']},
      ],
      'free_sections_left_week': 1,
      'next_free_at': '2026-11-16T00:00:00+06:00',
      'premium': false,
    };
  }
  if (p.startsWith('lp/mocks/')) {
    final q = Uri.parse('/$p').queryParameters['section'] ?? '';
    return fakeLp2Mock(section: q);
  }
  if (p == 'lp/companion/books') {
    return {
      'books': [for (var b = 20; b >= 10; b--) b],
      'tests': [1, 2, 3, 4],
      'no_content_line': {'en': 'Questions, audio and answers are not kept in the app.', 'bn': 'প্রশ্ন, অডিও আর উত্তর অ্যাপে রাখা হয় না।'},
    };
  }
  if (p == 'lp/content/version') return {'life': 1, 'vocab': 1, 'mocks': 1};
  return null;
}

Map<String, dynamic>? fakeLp2Post(String path, Map<String, dynamic> body) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  if (!p.startsWith('lp/')) return null;
  lp2Posts.add({'path': p, ...body});
  if (p == 'lp/mocks/eps-topik-001/mark') { // lpfinish
    return {
      'raw': 1, 'total': 2, 'score': 4, 'max': 8, 'band': null,
      'items': [
        {'n': 1, 'your': 'C', 'key': 'C', 'correct': true, 'mistake': null, 'explain_bn': 'ব্যাগ।'},
        {'n': 2, 'your': '', 'key': 'A', 'correct': false, 'mistake': 'other', 'explain_bn': 'কারখানা = 공장।'},
      ],
    };
  }
  if (p.endsWith('/mark') && p.startsWith('lp/mocks/')) return fakeLp2Mark('${body['section']}');
  if (p.endsWith('/finish')) return fakeLp2Finish();
  if (p == 'lp/score/writing') return fakeLp2Writing(task: (body['task'] as num?)?.toInt() ?? 2);
  if (p == 'lp/score/speaking') return fakeLp2Speaking();
  if (p == 'lp/life/roleplay') {
    return {
      'ai_state': 'used',
      'reply': 'Thank you. And who will pay for your studies?',
      'fix': {
        'wrong': '${body['message']}',
        'right': 'I want to study for a master\'s degree.',
        'why_en': 'Use "want to" + verb, and "a" before "master\'s degree".',
        'why_bn': '"want to"-এর পরে ক্রিয়া বসে, আর "master\'s degree"-এর আগে "a" লাগে।',
      },
      'ai_left_today': 4,
    };
  }
  if (p == 'lp/weak/practice') {
    return {
      'items': [
        {'id': 'w1', 'type': 'tfng', 'prompt': 'Floating gardens survive floods.',
         'passage': 'Vegetables grown on hyacinth rafts rise with flood water and survive the rainy season.'},
        {'id': 'w2', 'type': 'gap', 'prompt': 'Spell the word you hear: a place to stay — ______.', 'max_words': 1},
      ],
      'tags': body['tags'],
    };
  }
  if (p == 'lp/practice/mark') {
    return {
      'items': [
        {'id': 'w1', 'your': '${(body['answers'] as Map?)?['w1'] ?? ''}', 'key': 'TRUE', 'correct': true, 'mistake': null,
         'explain_en': 'The text says the gardens survive.', 'explain_bn': 'লেখায় আছে বাগানগুলো টিকে থাকে।'},
        {'id': 'w2', 'your': '${(body['answers'] as Map?)?['w2'] ?? ''}', 'key': 'accommodation', 'correct': false,
         'mistake': 'spelling', 'explain_en': 'Double c and double m.', 'explain_bn': 'দুটো c আর দুটো m।'},
      ],
    };
  }
  if (p == 'lp/companion/mark') return {'raw': 0, 'total': 0, 'band': 0, 'items': [], 'mistake_counts': {}, 'sheet_id': 1};
  return {'ok': true};
}
