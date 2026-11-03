// p2lang: the on-device IELTS engine must match backend/core/logic/ielts.py.
// ALIGN_VECTORS below == core/tests_p2lang.py ALIGN_VECTORS.
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/screens/ielts_engine.dart';

void main() {
  const vectors = <(String, String, List<String>, int)>[
    ('Students start school in spring.', 'students start is school spring',
        ['ok', 'ok', 'ok', 'miss', 'ok'], 80),
    ('We visited a very wide valley.', 'we visited a berry wide valley',
        ['ok', 'ok', 'ok', 'sub', 'ok', 'ok'], 83),
    ('I think three things are worth it.', '',
        ['miss', 'miss', 'miss', 'miss', 'miss', 'miss', 'miss'], 0),
    ('Please sit on this seat.', 'please seat on this sit', ['ok', 'sub', 'ok', 'ok', 'sub'], 60),
    ('a b c', 'x y z w', ['sub', 'sub', 'sub'], 0),
    ('She works and lives in two cities.', 'She works and lives in two cities',
        ['ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok'], 100),
  ];

  test('alignment vectors match the server engine', () {
    for (final v in vectors) {
      final r = alignWords(v.$1, v.$2);
      expect(r.rows.map((e) => e.status).toList(), v.$3, reason: v.$1);
      expect(r.score, v.$4, reason: v.$1);
    }
  });

  test('substitution keeps what the phone heard', () {
    final r = alignWords('We visited a very wide valley.', 'we visited a berry wide valley');
    expect(r.rows[3].heard, 'berry');
    expect(alignWords('', 'hello').rows, isEmpty);
    expect(alignWords('It’s fine', "it's fine").score, 100);
  });

  test('streak: today or yesterday keeps it, a gap breaks it', () {
    expect(ieltsStreak([], 100).current, 0);
    final s = ieltsStreak([98, 99, 100], 100);
    expect((s.current, s.best, s.todayDone), (3, 3, true));
    expect(ieltsStreak([97, 98, 99], 100).current, 3);
    final g = ieltsStreak([90, 91, 92, 93, 97], 100);
    expect((g.current, g.best), (0, 4));
    expect(ieltsStreak([99, 99, 100], 100).current, 2);
  });

  test('Leitner: pass promotes (max 5), miss resets to box 1', () {
    expect(leitnerNext(1, true, 10), (2, 12));
    expect(leitnerNext(5, true, 10), (5, 25));
    expect(leitnerNext(4, false, 10), (1, 11));
  });

  test('language packs: Korean words, Japanese/Chinese characters, Arabic', () {
    expect(ieltsWords('안녕하세요 반갑습니다'), ['안녕하세요', '반갑습니다']);
    expect(ieltsWords('すみません'), ['す', 'み', 'ま', 'せ', 'ん']);
    expect(alignWords('你好吗', '你好').score, 67);
    expect(alignWords('مرحبا صديقي', 'مرحبا صديقي').score, 100);
    expect(ieltsWords('Guten Tag, wie geht’s?'), ['guten', 'tag', 'wie', "geht's"]);
  });
}
