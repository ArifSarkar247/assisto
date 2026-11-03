// p2lang: gallery / widget-test fakes for the IELTS practice API. The content
// is a SUBSET copied verbatim from backend/core/logic/ielts.py (original
// Assisto content), so screenshots show the real thing.
import 'package:assisto/screens/ielts_engine.dart';

const _label = {
  'en': 'Practice estimate — not an official IELTS band.',
  'bn': 'অনুশীলনের অনুমান — অফিসিয়াল IELTS ব্যান্ড নয়।',
};

Map<String, dynamic> fakeIeltsContent({bool aiReady = true}) => {
      'ai_ready': aiReady,
      'estimate_label': _label,
      'speaking': {
        'p1': [
          {
            'id': 'p1_food', 'topic_en': 'Food', 'topic_bn': 'খাবার',
            'questions': [
              'What kind of food do you usually eat at home?',
              'Do you prefer cooking or eating out?',
            ],
          },
        ],
        'p2': [
          {
            'id': 'p2_skill',
            'title': 'Describe a skill you learned outside school.',
            'bullets': ['what the skill is', 'who helped you learn it', 'how long it took',
                'and explain how it has been useful to you.'],
            'p3': ['Which skills are not taught well in schools?'],
          },
        ],
      },
      'writing': {
        't1': [
          {'id': 't1_course', 'min_words': 150, 'kind': 'letter',
           'prompt': 'You want to join an evening English course at a local college. Write a letter to the college.'},
        ],
        't2': [
          {'id': 't2_online', 'min_words': 250, 'kind': 'essay',
           'prompt': 'Some people think that studying online is as effective as studying in a classroom. To what extent do you agree or disagree?'},
        ],
      },
      'reading': [
        {
          'id': 'r_floating', 'title': 'Gardens that float',
          'paragraphs': [
            'In the low-lying wetlands of southern Bangladesh, land can stay under water for several months of the year. For generations, farmers there have answered this problem in an unusual way: they build gardens that float.',
          ],
          'questions': [
            {'id': 'q1', 'type': 'tfng', 'text': 'Floating gardens are used when fields are covered by water.',
             'answer': 'true', 'bn': 'মাঠ পানির নিচে থাকলে ভাসমান বাগান ব্যবহার হয় — True।',
             'en': 'The gardens are used while the fields stay flooded — True.'},
            {'id': 'q2', 'type': 'tfng', 'text': 'Water hyacinth grows slowly.',
             'answer': 'false', 'bn': "লেখায় 'fast-growing' — False।",
             'en': "The text says 'fast-growing' — False."},
          ],
        },
      ],
      'vocab': [
        {'id': 'v_benefit', 'en': 'benefit', 'bn': 'উপকার, সুবিধা', 'example': 'Regular exercise has many benefits.'},
        {'id': 'v_decline', 'en': 'decline', 'bn': 'কমে যাওয়া, হ্রাস', 'example': 'The number of visitors began to decline.'},
      ],
      'pron': [
        {'id': 'pr_school', 'text': 'Students start school in spring.',
         'tip_bn': "s দিয়ে শুরু শব্দের আগে 'ই' যোগ করবেন না: 'ইস্কুল' নয়, সরাসরি school।",
         'tip_en': "Do not add a vowel before s-clusters: say 'school', not 'ischool'."},
        {'id': 'pr_vw', 'text': 'We visited a very wide valley.',
         'tip_bn': 'v আর w আলাদা।', 'tip_en': 'v and w differ.'},
      ],
      'official_links': [
        {'id': 'bc_free', 'org': 'British Council', 'url': 'https://takeielts.britishcouncil.org/take-ielts/prepare',
         'en': 'Free official practice tests', 'bn': 'অফিসিয়াল ফ্রি প্র্যাকটিস টেস্ট'},
      ],
      'criteria': {'writing': ['task', 'coherence', 'lexical', 'grammar'],
                   'speaking': ['fluency', 'lexical', 'grammar', 'pronunciation']},
    };

/// A finished Writing Task 2 check with an AI estimate (as the server sends it).
Map<String, dynamic> fakeIeltsWritingResult() => {
      'ok': true,
      'estimate_label': _label,
      'check': {
        'kind': 'checklist', 'task': 't2', 'word_count': 212, 'min_words': 250,
        'passed': 4, 'total': 7, 'estimate': true,
        'items': [
          {'id': 'length', 'ok': false, 'en': '212 words — at least 250 needed.',
           'bn': '212টি শব্দ — কমপক্ষে 250টি লাগবে। কম হলে Task-এর নম্বর কাটা যায়।'},
          {'id': 'paragraphs', 'ok': true, 'en': '4 paragraphs — aim for 4+ (intro, body, end).',
           'bn': '4টি অনুচ্ছেদ — ৪টি বা বেশি রাখুন (শুরু, মূল অংশ, শেষ)।'},
          {'id': 'linkers', 'ok': true, 'en': '5 different linking words used.',
           'bn': '5 রকম linking word — ভালো।'},
          {'id': 'formal', 'ok': false, 'en': "2 contractions (don't, can't) — write them in full in an essay.",
           'bn': "2টি সংক্ষেপ (don't, can't) — প্রবন্ধে পুরো লিখুন।"},
        ],
      },
      'ai_state': 'used',
      'credits_charged': 3,
      'ai': {
        'estimate': true, 'overall': 6.0,
        'criteria': [
          {'id': 'task', 'band': 6.0, 'en': 'You give a clear opinion but one idea needs an example.',
           'bn': 'মত পরিষ্কার, তবে একটা যুক্তিতে উদাহরণ লাগবে।'},
          {'id': 'lexical', 'band': 5.5, 'en': "'good' is repeated; try 'effective' or 'useful'.",
           'bn': "'good' বারবার এসেছে; 'effective' বা 'useful' লিখুন।"},
        ],
        'fixes': [
          {'en': "Write 'do not' instead of 'don't'.", 'bn': "'don't' না লিখে 'do not' লিখুন।"},
        ],
      },
    };

Map<String, dynamic>? fakeIeltsGet(String path, {bool empty = false}) {
  if (path == '/ielts/content') return fakeIeltsContent();
  return null;
}

Map<String, dynamic>? fakeIeltsPost(String path, Map body) {
  if (path == '/ielts/writing/check') return fakeIeltsWritingResult();
  if (path == '/ielts/reading/grade') {
    return {'ok': true, 'correct': 1, 'total': 2, 'rows': [
      {'id': 'q1', 'given': 'true', 'answer': 'true', 'correct': true, 'bn': 'True।', 'en': 'True.'},
      {'id': 'q2', 'given': 'true', 'answer': 'false', 'correct': false, 'bn': 'False।', 'en': 'False.'},
    ]};
  }
  return null;
}

/// Three practice days ending today -> a 3-day streak on the hub.
List<Map<String, dynamic>> fakeIeltsPractice({bool empty = false}) {
  if (empty) return [];
  final t = ieltsToday();
  return [
    for (var i = 0; i < 3; i++) {'id': i + 1, 'day': t - i, 'kind': 'pron', 'score': 80},
  ];
}
