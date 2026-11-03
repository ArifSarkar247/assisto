// learnwire: fixtures for learnwire_test.dart and the gallery shots.
import 'package:assisto/l10n/quran_learn_content.dart';
import 'package:assisto/quran_learn/learn_progress.dart';
import 'package:assisto/quran_learn/qaida_model.dart';

import 'fake_langmulti.dart';

/// A small Chinese mock in the pack format (original items).
Map<String, dynamic> lwZhMock() => {
      'id': 'zh-lw',
      'title_en': 'Chinese writing check',
      'title_bn': 'চীনা লেখা যাচাই',
      'format_en': 'One short writing task',
      'format_bn': 'একটি ছোট লেখা',
      'minutes': 10,
      'sections': [
        {
          'id': 'w',
          'skill': 'writing',
          'title_en': 'Writing',
          'title_bn': 'লেখা',
          'prompts': [
            {
              'id': 'zh-lw-w1',
              'text_en': 'Write 2 sentences about your work (use 因为).',
              'text_bn': 'আপনার কাজ নিয়ে ২টি বাক্য লিখুন (因为 ব্যবহার করুন)।',
              'min_words': 8,
              'max_words': 60,
              'checks': [
                {'any': ['因为'], 'en': 'A reason with 因为', 'bn': '因为 দিয়ে কারণ'},
                {'any': ['工作'], 'en': 'Work (工作)', 'bn': 'কাজ (工作)'},
              ],
            }
          ],
        },
        {
          'id': 's',
          'skill': 'speaking',
          'title_en': 'Speaking',
          'title_bn': 'বলা',
          'read_aloud': ['你好，我叫阿里。'],
          'speak_prompts': [
            {
              'id': 'zh-lw-s1',
              'text_en': 'Introduce yourself: name and country.',
              'text_bn': 'পরিচয় দিন: নাম আর দেশ।',
              'seconds': 30,
              'checks': [
                {'any': ['我叫', '名字'], 'en': 'Name', 'bn': 'নাম'},
                {'any': ['孟加拉'], 'en': 'Country', 'bn': 'দেশ'},
              ],
            }
          ],
        },
      ],
    };

/// A graded Arabic mock (real pack extract) with the server's checklist rows
/// and a certificate offer (Work Arabic level 1).
Map<String, dynamic> lwArResult() {
  final mock = langmultiMock('ar');
  final open = <Map<String, dynamic>>[];
  for (final s in (mock['sections'] as List).cast<Map>()) {
    for (final p in (s['prompts'] as List? ?? const []).cast<Map>()) {
      final n = (p['checks'] as List? ?? const []).length;
      open.add({'id': p['id'], 'checks': [for (var i = 0; i < n; i++) {'ok': i == 0}]});
    }
  }
  return {
    'level': 'W1', 'score_pct': 64, 'correct': 7, 'total': 11, 'weak': ['writing'],
    'rows': <Map>[], 'sections': <Map>[], 'open': open,
    'cert': {'course': 'lang_ar', 'level': 'W1', 'score': 64, 'token': 'lw-shot-token'},
  };
}

/// Every Qaida item learned; Qaida finished on 2 Nov 2026 (Nazera not yet).
QlProgress lwQaidaDone() => QlProgress(
      learned: {
        for (final s in kQlStages.where((s) => s.course == kCourseQaida))
          for (final l in s.lessons)
            for (final i in l.items) i.id
      },
      days: {'2026-11-02': 5},
      done: {kCourseQaida: '2026-11-02'},
    );

/// A two-section JFT-style mock (`no_back`, per-section minutes).
Map<String, dynamic> lwJftMock() => {
      'id': 'jft-lw',
      'title_en': 'JFT-Basic style (short)',
      'title_bn': 'JFT-Basic ধাঁচ (ছোট)',
      'format_en': 'Two sections, own timers',
      'format_bn': 'দুই অংশ, আলাদা সময়',
      'minutes': 10,
      'no_back': true,
      'sections': [
        for (final n in [1, 2])
          {
            'id': 's$n',
            'skill': 'vocab',
            'minutes': 5,
            'title_en': 'Part $n',
            'title_bn': 'অংশ $n',
            'questions': [
              {
                'id': 'lw-q$n',
                'type': 'mcq',
                'skill': 'vocab',
                'text_en': 'lw-q$n: pick 1',
                'text_bn': 'lw-q$n: ১ বাছুন',
                'options': ['1', '2'],
              }
            ],
          }
      ],
    };
