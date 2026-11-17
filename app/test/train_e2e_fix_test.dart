// train-e2e — app bugs the Train Tracker emulator E2E found (each one a test):
// 1. no internet: the train LIST said "could not load" although every
//    timetable is on the phone (offline pack) — a dead end before the
//    offline train page; now the rows come from the pack;
// 2. the English app showed the Bangla train name (list + header).
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/train/train_offline.dart';

import 'fake_train.dart' show trainOfflinePackJson;

void main() {
  final pack = TrainOfflinePack.fromJson(trainOfflinePackJson(), savedAt: DateTime.now());

  test('offline list: number (also Bangla digits), names and stops find the train', () {
    for (final q in ['701', '৭০১', 'Subarna', 'সুবর্ণ', 'cumilla', '']) {
      expect(trainOfflineSearch(pack, q).map((r) => r['no']), contains('701'), reason: q);
    }
    expect(trainOfflineSearch(pack, 'Rangpur'), isEmpty);
  });

  test('offline list row has what the list card shows', () {
    final r = trainOfflineSearch(pack, '701').single;
    expect(r['name_en'], 'Subarna Express');
    expect((r['from'] as Map)['en'], 'Chattogram');
    expect((r['to'] as Map)['bn'], 'কমলাপুর');
    expect(r['dep'], '07:00');
    expect(r['arr'], '12:20');
    expect(r['off_days'], isEmpty);
    expect(r['offline'], isTrue);
    // a suspended cross-border train keeps its label offline too
    expect(trainOfflineSearch(pack, 'Maitree').single['suspended'], isTrue);
  });

  test('train name follows the reader language', () {
    const tr = {'name_bn': 'রংপুর এক্সপ্রেস', 'name_en': 'Rangpur Express'};
    expect(trainNameOf(tr, true), 'রংপুর এক্সপ্রেস');
    expect(trainNameOf(tr, false), 'Rangpur Express');
    expect(trainNameOf(const {'name_bn': 'রংপুর এক্সপ্রেস'}, false), 'রংপুর এক্সপ্রেস');
    expect(trainNameOf(null, false), '');
  });
}
