// train-e2e — app bugs the Train Tracker emulator E2E found (each one a test):
// 1. no internet: the train LIST said "could not load" although every
//    timetable is on the phone (offline pack) — a dead end before the
//    offline train page; now the rows come from the pack;
// 2. the English app showed the Bangla train name (list + header).
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/screens/train/train_tracker_screen.dart' show trainHm;
import 'package:assisto/train/train_offline.dart';
import 'package:assisto/train/train_sms_parse.dart';

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

  test('train times are Dhaka time whatever the phone zone (emulator run 44210347275)', () {
    expect(trainHm('2026-11-18T08:02:00Z'), '14:02');
    expect(trainHm('2026-11-18T14:02:00+06:00'), '14:02');
    expect(trainHm('2026-11-18T19:30:00+00:00'), '01:30');
    expect(trainHm('nonsense'), '');
  });

  test('16318 preview: the train name is not the station (emulator run 44214276829)', () {
    const st = [
      TrainSmsStation('rangpur', '\u09b0\u0982\u09aa\u09c1\u09b0', 'Rangpur'),
      TrainSmsStation('natore', '\u09a8\u09be\u099f\u09cb\u09b0', 'Natore'),
      TrainSmsStation('bogura', '\u09ac\u0997\u09c1\u09dc\u09be', 'Bogura'),
    ];
    final r = parseTrain16318(
        'Train: 771-RANGPUR EXPRESS, Status: Left Natore at 01:55 PM, 18-Nov-2026, Late: 12 Min.',
        stations: st, now: DateTime(2026, 11, 18, 14, 30))!;
    expect((r.no, r.stationId, r.kind, r.lateMin), ('771', 'natore', 'left', 12));
    final b = parseTrain16318('Rangpur Express Bogura chere geche 12:10, 30 min late',
        stations: st, now: DateTime(2026, 11, 18, 12, 30), expectNo: '771')!;
    expect(b.stationId, 'bogura');
    // a real Rangpur report still finds Rangpur
    final c = parseTrain16318('771 arrived at Rangpur 19:05', stations: st,
        now: DateTime(2026, 11, 18, 19, 20))!;
    expect(c.stationId, 'rangpur');
  });
}
