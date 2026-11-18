import 'package:assisto/train/dest_alarm_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stop with no Bangla name keeps its name but in Bangla digits', () {
    const s = DestStation('b1', '13 No Bus Stop', '', 23.8, 90.4);
    expect(s.name(true), '১৩ No Bus Stop');
    expect(s.name(false), '13 No Bus Stop');
    const t = DestStation('b2', 'Norda Bus Stop', 'নর্দা বাস স্টপ', 23.8, 90.4);
    expect(t.name(true), 'নর্দা বাস স্টপ');
  });
}
