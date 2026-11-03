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
  if (path == '/learn/catalog') return fakeLearnCatalog();
  if (path == '/learn/pack/en') return fakeLearnPack();
  return null;
}

const _learnLabel = {
  'en': 'Assisto practice estimate — not an official exam result.',
  'bn': 'Assisto অনুশীলনের অনুমান — অফিসিয়াল পরীক্ষার ফল নয়।',
};

/// The 8 cards exactly as backend logic/langpacks.py LANGUAGES (only English
/// has a pack in this branch).
Map<String, dynamic> fakeLearnCatalog() {
  Map<String, dynamic> l(String code, String en, String bn, String native, String exEn, String exBn,
          String purpose, bool on) =>
      {'code': code, 'name_en': en, 'name_bn': bn, 'native': native, 'exams_en': exEn,
       'exams_bn': exBn, 'purpose': purpose, 'available': on};
  return {
    'estimate_label': _learnLabel,
    'ai_left_today': 3,
    'ai_free_per_day': 3,
    'languages': [
      l('en', 'English', 'ইংরেজি', 'English', 'IELTS · PTE style', 'IELTS · PTE ধাঁচ', 'study_work', true),
      l('ko', 'Korean', 'কোরিয়ান', '한국어', 'EPS-TOPIK · TOPIK 1–6', 'EPS-TOPIK · TOPIK ১–৬', 'work_korea', false),
      l('ja', 'Japanese', 'জাপানি', '日本語', 'JFT-Basic · JLPT N5–N1', 'JFT-Basic · JLPT N৫–N১', 'work_japan', false),
      l('ar', 'Arabic', 'আরবি', 'العربية', 'Work Arabic for the Gulf', 'উপসাগরীয় দেশে কাজের আরবি', 'work_gulf', false),
      l('de', 'German', 'জার্মান', 'Deutsch', 'CEFR A1–C2', 'CEFR A১–C২', 'study_work', false),
      l('fr', 'French', 'ফরাসি', 'Français', 'CEFR A1–C2', 'CEFR A১–C২', 'study_work', false),
      l('es', 'Spanish', 'স্প্যানিশ', 'Español', 'CEFR A1–C2', 'CEFR A১–C২', 'study_work', false),
      l('zh', 'Chinese', 'চীনা', '中文', 'HSK 1–6', 'HSK ১–৬', 'study_work', false),
    ],
  };
}

/// A trimmed public English pack (answer keys stripped like the server does).
Map<String, dynamic> fakeLearnPack() => {
      'format': 1, 'lang': 'en', 'stt_locale': 'en-US', 'level_system': 'CEFR', 'ai_ready': true,
      'estimate_label': _learnLabel,
      'levels': [
        {'id': 'A1', 'en': 'A1', 'bn': 'A১'}, {'id': 'A2', 'en': 'A2', 'bn': 'A২'},
        {'id': 'B1', 'en': 'B1', 'bn': 'B১'},
      ],
      'placement': {'pass_pct': 60, 'questions': [
        {'id': 'pl1', 'type': 'mcq', 'skill': 'grammar', 'level': 'A1', 'text': 'She ___ a teacher.',
         'options': ['am', 'is', 'are', 'be']},
        {'id': 'pl4', 'type': 'mcq', 'skill': 'grammar', 'level': 'A2', 'text': 'I ___ to Chattogram last year.',
         'options': ['go', 'goes', 'went', 'going']},
      ]},
      'lessons': [
        {'id': 'l_a1_greet', 'level': 'A1', 'title_en': 'Greetings and introducing yourself',
         'title_bn': 'শুভেচ্ছা ও নিজের পরিচয়',
         'items': [{'kind': 'phrase', 'target': 'Nice to meet you.', 'bn': 'আপনার সাথে দেখা হয়ে ভালো লাগল।',
                    'en': 'Nice to meet you.'}],
         'practice': ['Hello, my name is Karim.']},
      ],
      'scenarios': [
        {'id': 'airport', 'title_en': 'At the airport', 'title_bn': 'বিমানবন্দরে',
         'opening': 'Good morning. May I see your passport, please? What is the purpose of your visit?',
         'goals_en': ['Say why you are travelling'], 'goals_bn': ['কেন যাচ্ছেন বলুন'],
         'useful': [{'target': 'I am here to work. Here is my contract.',
                     'bn': 'আমি কাজ করতে এসেছি। এই যে আমার চুক্তিপত্র।', 'en': 'I am here to work. Here is my contract.'}]},
      ],
      'pron': [
        {'id': 'pr_school', 'text': 'Students start school in spring.',
         'tip_bn': "s দিয়ে শুরু শব্দের আগে 'ই' যোগ করবেন না।", 'tip_en': "Do not add a vowel before s-clusters."},
      ],
      'mock': [
        {'id': 'pte_style_1', 'title_en': 'PTE-style practice test (Reading + Speaking + Writing)',
         'title_bn': 'PTE-ধাঁচের অনুশীলন টেস্ট (রিডিং + স্পিকিং + রাইটিং)',
         'format_en': 'PTE-style task types. Original Assisto questions.',
         'format_bn': 'PTE-ধাঁচের প্রশ্ন। প্রশ্নগুলো Assisto-র নিজস্ব।', 'minutes': 30,
         'sections': [
           {'id': 'reading', 'skill': 'reading', 'title_en': 'Reading: multiple choice', 'title_bn': 'রিডিং: MCQ',
            'passage': ['Not long ago, sending money to a family member in another district usually meant a bus journey.'],
            'questions': [{'id': 'q1', 'type': 'mcq', 'skill': 'reading',
                           'text': 'A smartphone is required to use mobile financial services.',
                           'options': ['True', 'False', 'Not Given']}]},
         ],
         'bands': [{'min_pct': 0, 'level': 'A2'}, {'min_pct': 40, 'level': 'B1'}]},
      ],
      'extras': [{'id': 'ielts'}],
    };

Map<String, dynamic> fakeLearnMockResult() => {
      'ok': true, 'level': 'B1', 'score_pct': 60, 'correct': 3, 'total': 5, 'weak': ['writing'],
      'sections': [{'id': 'reading', 'skill': 'reading', 'correct': 3, 'total': 5, 'pct': 60}],
      'rows': [
        {'id': 'q1', 'skill': 'reading', 'given': 0, 'answer': 1, 'correct': false,
         'explain_bn': "লেখায় আছে 'a basic phone' — False।", 'explain_en': "The text says 'a basic phone' is enough — False."},
      ],
      'timed_out': false, 'estimate': true,
    };

Map<String, dynamic>? fakeIeltsPost(String path, Map body) {
  if (path == '/ielts/writing/check') return fakeIeltsWritingResult();
  if (path == '/learn/en/placement') {
    return {'ok': true, 'level': 'A2', 'score_pct': 50, 'correct': 1, 'total': 2, 'weak': ['grammar'],
            'skills': {'grammar': 50}, 'estimate': true, 'rows': [
      {'id': 'pl1', 'skill': 'grammar', 'given': 1, 'answer': 1, 'correct': true, 'explain_bn': 'is।', 'explain_en': "'She' takes 'is'."},
      {'id': 'pl4', 'skill': 'grammar', 'given': 0, 'answer': 2, 'correct': false, 'explain_bn': 'went।', 'explain_en': "Past: 'went'."},
    ]};
  }
  if (path == '/learn/en/mock') return fakeLearnMockResult();
  if (path == '/learn/en/roleplay') {
    return {'ok': true, 'ai_state': 'used', 'reply': 'How long will you stay?', 'fix_en': "Say 'for work', not 'for working'.",
            'fix_bn': "'for working' নয়, 'for work' বলুন।", 'free': true, 'credits_charged': 0, 'ai_left_today': 2};
  }
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
